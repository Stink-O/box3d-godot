class_name RigExtract
extends RefCounted

## Reads an authored Box3D sample scene into a backend-neutral "Rig" (SPEC A):
## plain Dictionaries and Arrays describing bodies, shapes, joints and visuals,
## with no Box3D types left in the result, so a native builder can rebuild the
## same scene on Godot Physics or Jolt.
##
## The scene is instantiated but NEVER added to the tree. instantiate() runs
## _init only, so no Box3DWorld is created, no Box3DBody registers itself with a
## solver and no sample script side effects fire. Two consequences shape this
## file:
##
##  - Node3D.get_global_transform() fails outside the tree, so every transform
##    here is accumulated by hand as the walk descends.
##  - Class tests go through get_class()/ClassDB rather than `is Box3DBody`, so
##    this module still parses and degrades to an empty Rig if the GDExtension
##    is missing.
##
## Shape extraction mirrors godot/src/box3d_body.cpp exactly, including the
## cylinder/cone tessellation: Box3D builds those as cylinder_sides-gon convex
## hulls internally, so an N-gon hull is the exact port, not an approximation.

# Box3DBody.ShapeType. Duplicated as plain ints so this file never has to
# resolve a GDExtension symbol at parse time.
const SHAPE_BOX := 0
const SHAPE_SPHERE := 1
const SHAPE_CAPSULE := 2
const SHAPE_CYLINDER := 3
const SHAPE_CONE := 4
const SHAPE_HULL := 5
const SHAPE_MESH := 6
const SHAPE_FIT_MESH := 7

const BODY_TYPES := ["static", "kinematic", "dynamic"]

const DEFAULT_GRAVITY := Vector3(0, -9.8, 0)
const DEFAULT_SUBSTEPS := 4

# Box3D class name -> Joint.kind.
const JOINT_KINDS := {
	"Box3DBallJoint": "ball",
	"Box3DHingeJoint": "hinge",
	"Box3DDistanceJoint": "distance",
	"Box3DSliderJoint": "slider",
	"Box3DWheelJoint": "wheel",
	"Box3DParallelJoint": "parallel",
	"Box3DFixedJoint": "fixed",
	"Box3DMotorJoint": "motor",
}

# Capability gaps, in display order. One badge per reason, "%d" is the count.
const GAP_ORDER := [
	"wheel_joint", "parallel_joint", "motor_joint", "distance_spring",
	"joint_spring", "fast_rotation", "character", "multimesh",
]
const GAP_TEXT := {
	"wheel_joint": "Box3DWheelJoint x%d: no native equivalent (Godot has no wheel constraint)",
	"parallel_joint": "Box3DParallelJoint x%d: no native equivalent (no parallel-axis spring joint)",
	"motor_joint": "Box3DMotorJoint x%d: no native equivalent (only approximated by Generic6DOFJoint3D motors)",
	"distance_spring": "Box3DDistanceJoint with a spring x%d: no native equivalent (Godot has no distance joint)",
	"joint_spring": "Joint springs x%d: no native equivalent (Godot joints expose softness/bias, not hertz/damping)",
	"fast_rotation": "allow_fast_rotation on %d bodies: no native equivalent (the per-step rotation clamp cannot be lifted)",
	"character": "Box3DCharacterBody x%d: not ported (CharacterBody3D sweeps with a different algorithm)",
	"multimesh": "Box3DMultiMeshRenderer x%d: not ported (no native MultiMesh body renderer)",
}


# --- Entry points -----------------------------------------------------------

## Load `path`, walk the unparented instance and return a Rig (SPEC A).
## Always returns a fully-formed Rig; failures come back empty, not null.
static func from_scene(path: String) -> Dictionary:
	var rig := {
		"source": path,
		"gravity": DEFAULT_GRAVITY,
		"substep_count": DEFAULT_SUBSTEPS,
		"bodies": [],
		"joints": [],
		"unsupported": [],
	}

	var packed: PackedScene = null
	if ResourceLoader.exists(path, "PackedScene"):
		packed = ResourceLoader.load(path, "PackedScene") as PackedScene
	if packed == null:
		push_warning("[rig] not a loadable PackedScene: %s" % path)
		return rig
	var root := packed.instantiate()
	if root == null:
		push_warning("[rig] instantiate() failed: %s" % path)
		return rig

	var world := _find_world(root)
	if world != null:
		rig["gravity"] = _gvec(world, &"gravity", DEFAULT_GRAVITY)
		rig["substep_count"] = _gint(world, &"substep_count", DEFAULT_SUBSTEPS)

	# Bodies are expressed relative to the Box3DWorld node, and only bodies
	# under it simulate at all (Box3DBody finds its world by walking ancestors),
	# so the walk starts there and anything outside is correctly ignored.
	# Scenes with no world fall back to the scene root.
	var origin: Node = world if world != null else root
	var ctx := {
		"rig": rig,
		"index": {},             # body node -> Rig.bodies index
		"pending_joints": [],    # [[joint node, transform], ...], resolved after the walk
		"gaps": {},              # gap key -> count
	}
	_walk(origin, Transform3D.IDENTITY, ctx)
	# Scenes that BUILD their bodies in _ready (huge_pyramid generates 16k
	# blocks in code) have nothing in the .tscn for the walk to find, and
	# _ready never runs on this unparented instance. Such scenes describe the
	# same layout through rig_bodies() instead: an Array of Dictionaries with
	# "position" and optional "size" / "density" / "friction" / "restitution" /
	# "material", each becoming a dynamic box body with a synthesized visual.
	if root.has_method(&"rig_bodies"):
		_add_generated_bodies(root.rig_bodies(), rig)
	_resolve_joints(ctx)
	_write_unsupported(ctx)

	root.free()
	return rig


## One-line summary for the harness UI, e.g.
## "1015 bodies (1014 dynamic, 1 static), 0 joints".
static func describe(rig: Dictionary) -> String:
	var bodies: Array = rig.get("bodies", [])
	var joints: Array = rig.get("joints", [])
	var counts := {"dynamic": 0, "static": 0, "kinematic": 0}
	for b: Dictionary in bodies:
		var t := String(b.get("type", "dynamic"))
		counts[t] = int(counts.get(t, 0)) + 1

	var parts := PackedStringArray()
	for t: String in ["dynamic", "static", "kinematic"]:
		if int(counts[t]) > 0:
			parts.append("%d %s" % [counts[t], t])
	if parts.is_empty():
		parts.append("0 dynamic")
	return "%d bodies (%s), %d joints" % [bodies.size(), ", ".join(parts), joints.size()]


# --- Tree walk --------------------------------------------------------------

static func _find_world(node: Node) -> Node:
	# First Box3DWorld wins; no sample nests more than one.
	for child: Node in node.get_children():
		if _is_class(child, &"Box3DWorld"):
			return child
		var found := _find_world(child)
		if found != null:
			return found
	return null


static func _walk(node: Node, xf: Transform3D, ctx: Dictionary) -> void:
	for child: Node in node.get_children():
		var child_xf := xf
		var n3 := child as Node3D
		if n3 != null:
			child_xf = xf * n3.transform

		# Only Box3D* classes need dispatching, and a GDScript that extends one
		# still reports the native class name, so the prefix test is a safe way
		# to keep the 5050-body scenes cheap.
		var cls := child.get_class()
		if cls.begins_with("Box3D"):
			if ClassDB.is_parent_class(cls, &"Box3DBody"):
				_add_body(child, child_xf, ctx)
			elif ClassDB.is_parent_class(cls, &"Box3DJoint"):
				# Deferred: a joint may name a body that the walk has not
				# reached yet, so indices are resolved once the walk is done.
				var pending: Array = ctx["pending_joints"]
				pending.append([child, child_xf])
			elif ClassDB.is_parent_class(cls, &"Box3DCharacterBody"):
				_bump(ctx["gaps"], "character")
			elif ClassDB.is_parent_class(cls, &"Box3DMultiMeshRenderer"):
				_bump(ctx["gaps"], "multimesh")

		# Descend regardless: containers, multimesh renderers and even nested
		# bodies can all carry more bodies below them.
		_walk(child, child_xf, ctx)


static func _add_body(node: Node, xf: Transform3D, ctx: Dictionary) -> void:
	var bodies: Array = ctx["rig"]["bodies"]
	var id := bodies.size()

	if _gbool(node, &"allow_fast_rotation", false):
		_bump(ctx["gaps"], "fast_rotation")

	bodies.append({
		"id": id,
		"name": String(node.name),
		"transform": xf,
		"type": _body_type_name(_gint(node, &"body_type", 2)),
		"shapes": _extract_shapes(node),
		"linear_damping": _gfloat(node, &"linear_damping", 0.0),
		"angular_damping": _gfloat(node, &"angular_damping", 0.05),
		"gravity_scale": _gfloat(node, &"gravity_scale", 1.0),
		"continuous": _gbool(node, &"continuous", false),
		# Box3D stores these as uint32 but returns them through a C++ `int`, so
		# the default mask arrives as -1. Mask back to 32 bits: same bit
		# pattern, no sign extension for the builder's filter fix-up to trip on.
		"collision_layer": _gint(node, &"collision_layer", 1) & 0xFFFFFFFF,
		"collision_mask": _gint(node, &"collision_mask", -1) & 0xFFFFFFFF,
		"lock_linear": [
			_gbool(node, &"lock_linear_x", false),
			_gbool(node, &"lock_linear_y", false),
			_gbool(node, &"lock_linear_z", false),
		],
		"lock_angular": [
			_gbool(node, &"lock_angular_x", false),
			_gbool(node, &"lock_angular_y", false),
			_gbool(node, &"lock_angular_z", false),
		],
		"contact_monitor": _gbool(node, &"contact_monitor", false),
		"is_sensor": _gbool(node, &"is_sensor", false),
		"visuals": _extract_visuals(node),
	})
	var index: Dictionary = ctx["index"]
	index[node] = id


static func _body_type_name(v: int) -> String:
	if v >= 0 and v < BODY_TYPES.size():
		return String(BODY_TYPES[v])
	return "dynamic"


# --- Generated bodies -------------------------------------------------------

## Every generated block in a scene shares this one mesh; a 16k-body pyramid
## must not allocate 16k BoxMeshes just to be looked at.
static var _unit_box_mesh: BoxMesh = null


static func _add_generated_bodies(entries: Array, rig: Dictionary) -> void:
	if _unit_box_mesh == null:
		_unit_box_mesh = BoxMesh.new()  # 1x1x1, the generated-block default
	var bodies: Array = rig["bodies"]
	for e in entries:
		if not (e is Dictionary):
			continue
		var size: Vector3 = e.get("size", Vector3.ONE)
		var mesh: Mesh = _unit_box_mesh
		if size != Vector3.ONE:
			var bm := BoxMesh.new()
			bm.size = size
			mesh = bm
		bodies.append({
			"id": bodies.size(),
			"name": String(e.get("name", "block_%d" % bodies.size())),
			"transform": Transform3D(Basis(), e.get("position", Vector3.ZERO)),
			"type": "dynamic",
			"shapes": [{
				"kind": "box",
				"size": size,
				"transform": Transform3D.IDENTITY,
				"density": float(e.get("density", 1.0)),
				"friction": float(e.get("friction", 0.6)),
				"restitution": float(e.get("restitution", 0.0)),
			}],
			"linear_damping": 0.0,
			"angular_damping": 0.05,
			"gravity_scale": 1.0,
			"continuous": false,
			"collision_layer": 1,
			"collision_mask": 0xFFFFFFFF,
			"lock_linear": [false, false, false],
			"lock_angular": [false, false, false],
			"contact_monitor": false,
			"is_sensor": false,
			"visuals": [{
				"mesh": mesh,
				"transform": Transform3D.IDENTITY,
				"material": e.get("material"),
				"layers": 1,
			}],
		})


# --- Visuals ----------------------------------------------------------------

static func _extract_visuals(body: Node) -> Array:
	var out: Array = []
	_collect_visuals(body, Transform3D.IDENTITY, out)
	# Materials assigned in _ready (cube.gd picks its palette color there) do
	# not exist on this unparented instance; scripts that color themselves at
	# runtime expose the same choice through rig_visual_material() instead.
	if body.has_method(&"rig_visual_material"):
		for vis: Dictionary in out:
			if vis.get("material") == null:
				vis["material"] = body.rig_visual_material()
	return out


static func _collect_visuals(node: Node, xf: Transform3D, out: Array) -> void:
	for child: Node in node.get_children():
		# A nested Box3DBody owns its own visuals.
		if _is_class(child, &"Box3DBody"):
			continue
		var child_xf := xf
		var n3 := child as Node3D
		if n3 != null:
			child_xf = xf * n3.transform
		var mi := child as MeshInstance3D
		if mi != null and mi.mesh != null:
			out.append({
				"mesh": mi.mesh,
				"transform": child_xf,
				"material": mi.material_override,
				"layers": mi.layers,
			})
		_collect_visuals(child, child_xf, out)


# --- Shapes -----------------------------------------------------------------

static func _extract_shapes(body: Node) -> Array:
	var shapes: Array = []
	# Direct Box3DCollisionShape children replace the body's own shape_type
	# entirely; Box3D does not support mixing the two.
	for child: Node in body.get_children():
		if not _is_class(child, &"Box3DCollisionShape"):
			continue
		var s := _child_shape(child)
		if not s.is_empty():
			shapes.append(s)
	if not shapes.is_empty():
		return shapes

	var own := _own_shape(body)
	if not own.is_empty():
		shapes.append(own)
	return shapes


## One compound member. Box3DCollisionShape carries its own material and spells
## the N-gon count `sides`, not `cylinder_sides`, and offers no hull/mesh kinds.
static func _child_shape(node: Node) -> Dictionary:
	var n3 := node as Node3D
	var s := {
		"kind": "box",
		"transform": n3.transform if n3 != null else Transform3D.IDENTITY,
		"density": _gfloat(node, &"density", 1.0),
		"friction": _gfloat(node, &"friction", 0.6),
		"restitution": _gfloat(node, &"restitution", 0.0),
	}
	return _primitive_shape(node, _gint(node, &"shape_type", SHAPE_BOX),
			_gint(node, &"sides", 16), s)


static func _own_shape(body: Node) -> Dictionary:
	var s := {
		"kind": "box",
		"transform": Transform3D.IDENTITY,
		"density": _gfloat(body, &"density", 1.0),
		"friction": _gfloat(body, &"friction", 0.6),
		"restitution": _gfloat(body, &"restitution", 0.0),
	}
	var shape_type := _gint(body, &"shape_type", SHAPE_BOX)
	match shape_type:
		SHAPE_HULL:
			return _hull_from_mesh(body, s)
		SHAPE_MESH:
			return _mesh_from_mesh(body, s)
		SHAPE_FIT_MESH:
			return _box_from_mesh_aabb(body, s)
	return _primitive_shape(body, shape_type, _gint(body, &"cylinder_sides", 16), s)


## BOX/SPHERE/CAPSULE/CYLINDER/CONE behave identically on Box3DBody and on
## Box3DCollisionShape, so both funnel through here with `s` pre-filled.
static func _primitive_shape(node: Node, shape_type: int, sides: int, s: Dictionary) -> Dictionary:
	match shape_type:
		SHAPE_SPHERE:
			s["kind"] = "sphere"
			s["radius"] = _gfloat(node, &"sphere_radius", 0.5)
		SHAPE_CAPSULE:
			var r := _gfloat(node, &"capsule_radius", 0.5)
			s["kind"] = "capsule"
			s["radius"] = r
			# Box3D clamps the cylindrical half-length at 0 and keeps the radius
			# (a squat capsule degenerates to a sphere); CapsuleShape3D would
			# instead shrink the radius, so normalise the height here.
			s["height"] = maxf(_gfloat(node, &"capsule_height", 2.0), r * 2.0)
		SHAPE_CYLINDER:
			s["kind"] = "hull"
			s["points"] = _cylinder_points(_gfloat(node, &"capsule_height", 2.0),
					_gfloat(node, &"capsule_radius", 0.5), sides)
		SHAPE_CONE:
			s["kind"] = "hull"
			s["points"] = _cone_points(_gfloat(node, &"capsule_height", 2.0),
					_gfloat(node, &"capsule_radius", 0.5), sides)
		_:
			s["kind"] = "box"
			s["size"] = _gvec(node, &"box_size", Vector3.ONE)
	return s


## b3CreateCylinder(height, radius, -height/2, sides): two `sides`-point rings,
## the second `height` above the first, so the prism straddles the body origin.
static func _cylinder_points(height: float, radius: float, sides: int) -> PackedVector3Array:
	var n := maxi(sides, 3)
	var pts := PackedVector3Array()
	pts.resize(n * 2)
	var y0 := -height * 0.5
	var y1 := y0 + height
	var step := TAU / float(n)
	for i in n:
		var a := step * float(i)
		var x := cos(a) * radius
		var z := sin(a) * radius
		pts[2 * i] = Vector3(x, y0, z)
		pts[2 * i + 1] = Vector3(x, y1, z)
	return pts


## b3CreateCone(height, radius, 0, slices) plus the -height/2 shift that
## box3d_body.cpp bakes into the shape transform: base ring at -h/2, apex at
## +h/2. Box3D emits `slices` coincident apex points; one gives the same hull.
static func _cone_points(height: float, radius: float, slices: int) -> PackedVector3Array:
	var n := maxi(slices, 3)
	var pts := PackedVector3Array()
	pts.resize(n + 1)
	var y0 := -height * 0.5
	var step := TAU / float(n)
	for i in n:
		var a := step * float(i)
		pts[i] = Vector3(cos(a) * radius, y0, sin(a) * radius)
	pts[n] = Vector3(0.0, y0 + height, 0.0)
	return pts


static func _hull_from_mesh(body: Node, s: Dictionary) -> Dictionary:
	var src := _resolve_collision_mesh(body)
	if src.is_empty():
		push_warning("[rig] Hull body '%s' has no collision_mesh or child MeshInstance3D" % body.name)
		return {}
	var faces := _mesh_faces(src[0])
	if faces.size() < 4:
		push_warning("[rig] Hull body '%s' has an unusable mesh" % body.name)
		return {}
	var local: Transform3D = src[1]
	# Box3D feeds every triangle vertex to b3CreateHull; deduplicating first
	# yields the identical hull from a fraction of the points.
	var seen := {}
	var pts := PackedVector3Array()
	for v: Vector3 in faces:
		var p := local * v
		if not seen.has(p):
			seen[p] = true
			pts.append(p)
	s["kind"] = "hull"
	s["points"] = pts
	return s


static func _mesh_from_mesh(body: Node, s: Dictionary) -> Dictionary:
	var src := _resolve_collision_mesh(body)
	if src.is_empty():
		push_warning("[rig] Mesh body '%s' has no collision_mesh or child MeshInstance3D" % body.name)
		return {}
	var faces := _mesh_faces(src[0])
	if faces.size() < 3 or faces.size() % 3 != 0:
		push_warning("[rig] Mesh body '%s' has an unusable mesh" % body.name)
		return {}
	var local: Transform3D = src[1]
	var tris := faces.size() / 3
	var out := PackedVector3Array()
	out.resize(faces.size())
	for t in tris:
		# Reversed winding, matching box3d_body.cpp's (0, 2, 1) index order:
		# Godot winds normals outward, Box3D's one-sided mesh collision wants
		# the opposite.
		out[t * 3] = local * faces[t * 3]
		out[t * 3 + 1] = local * faces[t * 3 + 2]
		out[t * 3 + 2] = local * faces[t * 3 + 1]
	s["kind"] = "mesh"
	s["faces"] = out
	return s


## FIT_MESH: the mesh AABB's 8 corners taken into body space, emitted as a box
## at the resulting centre via Shape.transform. The body itself never moves.
static func _box_from_mesh_aabb(body: Node, s: Dictionary) -> Dictionary:
	var src := _resolve_collision_mesh(body)
	if src.is_empty():
		push_warning("[rig] Fit Mesh body '%s' has no child MeshInstance3D" % body.name)
		return {}
	var mesh: Mesh = src[0]
	var local: Transform3D = src[1]
	var aabb := mesh.get_aabb()
	var fitted := AABB(local * aabb.get_endpoint(0), Vector3.ZERO)
	for c in range(1, 8):
		fitted = fitted.expand(local * aabb.get_endpoint(c))
	s["kind"] = "box"
	s["size"] = fitted.size
	s["transform"] = Transform3D(Basis(), fitted.position + fitted.size * 0.5)
	return s


## Mirrors Box3DBody::resolve_collision_mesh: `collision_mesh` at identity,
## otherwise the first direct child MeshInstance3D at its transform relative to
## the body. Returns [Mesh, Transform3D], or [] when nothing usable is found.
static func _resolve_collision_mesh(body: Node) -> Array:
	var cm: Variant = body.get(&"collision_mesh")
	if cm is Mesh:
		return [cm, Transform3D.IDENTITY]
	for child: Node in body.get_children():
		var mi := child as MeshInstance3D
		if mi != null and mi.mesh != null:
			return [mi.mesh, mi.transform]
	return []


## Triangle soup for any Mesh. get_faces() is what Box3D itself calls, so the
## point sets agree exactly, and it covers ArrayMesh and the primitive meshes
## (BoxMesh, SphereMesh, CapsuleMesh, CylinderMesh, PrismMesh) alike.
static func _mesh_faces(mesh: Mesh) -> PackedVector3Array:
	if mesh == null:
		return PackedVector3Array()
	return mesh.get_faces()


# --- Joints -----------------------------------------------------------------

static func _resolve_joints(ctx: Dictionary) -> void:
	var out: Array = ctx["rig"]["joints"]
	var index: Dictionary = ctx["index"]
	var skip := _inherited_property_names()

	for entry: Array in ctx["pending_joints"]:
		var node: Node = entry[0]
		var kind := _joint_kind(node.get_class())
		var params := _joint_params(node, skip)
		out.append({
			"kind": kind,
			"name": String(node.name),
			"body_a": _resolve_body(node, &"body_a", index),
			"body_b": _resolve_body(node, &"body_b", index),
			"transform": entry[1],
			"params": params,
		})
		_flag_joint_gaps(kind, params, ctx["gaps"])


static func _joint_kind(cls: String) -> String:
	if JOINT_KINDS.has(cls):
		return String(JOINT_KINDS[cls])
	return cls.trim_prefix("Box3D").trim_suffix("Joint").to_snake_case()


## Empty or unresolvable body paths mean "the world": Box3D anchors those to an
## implicit static body at the joint node's own origin.
static func _resolve_body(joint: Node, prop: StringName, index: Dictionary) -> int:
	var v: Variant = joint.get(prop)
	if not (v is NodePath):
		return -1
	var path: NodePath = v
	# Absolute paths cannot resolve in an unparented tree, and asking would only
	# spam errors.
	if path.is_empty() or path.is_absolute():
		return -1
	var target := joint.get_node_or_null(path)
	if target == null:
		push_warning("[rig] joint '%s' %s -> '%s' does not resolve" % [joint.name, prop, path])
		return -1
	return int(index.get(target, -1))


## Every storage property the concrete joint class adds on top of Node3D, read
## verbatim, so a new joint property is picked up without editing this file.
## body_a/body_b are left out because they are promoted to Rig body indices.
static func _joint_params(node: Node, skip: Dictionary) -> Dictionary:
	var out := {}
	for p: Dictionary in node.get_property_list():
		if (int(p["usage"]) & PROPERTY_USAGE_STORAGE) == 0:
			continue
		var pname := String(p["name"])
		if pname == "body_a" or pname == "body_b" or skip.has(pname):
			continue
		out[pname] = node.get(pname)
	return out


static func _inherited_property_names() -> Dictionary:
	var out := {}
	for p: Dictionary in ClassDB.class_get_property_list(&"Node3D", false):
		out[String(p["name"])] = true
	return out


static func _flag_joint_gaps(kind: String, params: Dictionary, gaps: Dictionary) -> void:
	match kind:
		"wheel":
			_bump(gaps, "wheel_joint")
			return  # already reported whole; its springs add no information
		"parallel":
			_bump(gaps, "parallel_joint")
			return
		"motor":
			_bump(gaps, "motor_joint")
			return
	if kind == "distance" and bool(params.get("spring_enabled", false)):
		_bump(gaps, "distance_spring")
	elif _has_active_spring(params):
		_bump(gaps, "joint_spring")


## SPEC A says "spring_hertz > 0", but every Box3D joint ships a non-zero
## default hertz, so a bare hertz test would badge joints whose spring is
## switched off. Gate on spring_enabled wherever the class has it; the weld and
## motor style joints have no enable and use hertz == 0 to mean rigid.
static func _has_active_spring(params: Dictionary) -> bool:
	if params.has("spring_enabled"):
		return bool(params["spring_enabled"]) and float(params.get("spring_hertz", 0.0)) > 0.0
	for key: String in ["spring_hertz", "linear_hertz", "angular_hertz"]:
		if float(params.get(key, 0.0)) > 0.0:
			return true
	return false


# --- Capability gaps --------------------------------------------------------

static func _bump(gaps: Dictionary, key: String) -> void:
	gaps[key] = int(gaps.get(key, 0)) + 1


static func _write_unsupported(ctx: Dictionary) -> void:
	var gaps: Dictionary = ctx["gaps"]
	var out: Array = ctx["rig"]["unsupported"]
	for key: String in GAP_ORDER:
		var n := int(gaps.get(key, 0))
		if n > 0:
			out.append(String(GAP_TEXT[key]) % n)


# --- Property readers -------------------------------------------------------
#
# Object.get() returns null for a property the node does not have, which keeps
# the extractor alive against older builds of the GDExtension.

static func _is_class(node: Object, type: StringName) -> bool:
	return ClassDB.is_parent_class(node.get_class(), type)


static func _gfloat(o: Object, prop: StringName, fallback: float) -> float:
	var v: Variant = o.get(prop)
	return fallback if v == null else float(v)


static func _gint(o: Object, prop: StringName, fallback: int) -> int:
	var v: Variant = o.get(prop)
	return fallback if v == null else int(v)


static func _gbool(o: Object, prop: StringName, fallback: bool) -> bool:
	var v: Variant = o.get(prop)
	return fallback if v == null else bool(v)


static func _gvec(o: Object, prop: StringName, fallback: Vector3) -> Vector3:
	var v: Variant = o.get(prop)
	if not (v is Vector3):
		return fallback
	var out: Vector3 = v
	return out
