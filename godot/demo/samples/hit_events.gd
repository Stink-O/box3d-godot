extends Node3D

## Hit -- a port of upstream's "Events / Hit" sample
## (samples/sample_events.cpp). A 22-segment tower of tilted capsules, welded
## into eight bodies and given a rotational kick, is toppled onto a large
## triangle-mesh floor, and every IMPACT is recorded where it happened.
##
## A hit event is not a contact: box3d reports one only when two shapes meet
## faster than the world's `hit_event_threshold` (1 m/s by default), and it
## carries the impact point, the normal and the approach speed. That is what
## a game hangs a sound, a decal or a damage number on, and this port takes
## them straight off the new `Box3DWorld.contact_hit` signal, keeping the
## last 32 as upstream's e_maxEvents does: a yellow cross at the point and a
## line along the impulse the length of the approach speed.
##
## Reproduced from upstream: the floor is `b3CreateGridMesh(20, 20, 8, 6,
## true)` -- a 160 m field of 800 triangles sharing six materials whose
## userMaterialIds are 1..6, so the event reports which stripe was struck --
## and the tower's r = 0.75 / l = 1.5 / offset = 0.05 capsules, three per
## body, each segment 5% thinner than the one below, welded with
## angularHertz 10 / angularDampingRatio 2 and spun at 0.5 rad/s with the
## kick decaying by 0.75 per segment.
##
## One thing does not carry over: upstream tags the tower's shapes with
## userMaterialId 42, which Box3DCollisionShape cannot express yet, so the
## tower reports material 0. See SPRINT_STATE.md.

const CELLS := 20
const CELL_WIDTH := 8.0
const MATERIAL_COUNT := 6

const SHAPE_COUNT := 22
const SHAPES_PER_BODY := 3
const START_RADIUS := 0.75
const SEGMENT_LENGTH := 1.5
const START_OFFSET := 0.05
const RADIUS_DECAY := 0.95
const START_SPIN := 0.5
const SPIN_DECAY := 0.75
const ROLLING_RESISTANCE := 0.2
const WELD_ANGULAR_HERTZ := 10.0
const WELD_ANGULAR_DAMPING := 2.0

const MAX_EVENTS := 32
const CROSS_SIZE := 0.5

var camera_home := Vector3(0.0, 55.0, 86.6)
var camera_look_at := Vector3(0.0, 5.0, 0.0)

var _events: Array = []
var _lines: ImmediateMesh
var _capsule_material := StandardMaterial3D.new()
@onready var _world: Box3DWorld = $Box3DWorld
@onready var _label: Label3D = $Status


func _ready() -> void:
	_capsule_material.albedo_color = Color(0.8, 0.55, 0.35)
	_capsule_material.roughness = 0.45

	_build_ground()
	_build_tower()

	_lines = ImmediateMesh.new()
	var marks := MeshInstance3D.new()
	marks.name = "HitMarks"
	marks.mesh = _lines
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 0.95, 0.2)  # upstream's yellow
	mat.no_depth_test = true
	marks.material_override = mat
	add_child(marks)

	_world.contact_hit.connect(_on_hit)


func _on_hit(hit: Dictionary) -> void:
	# The event arrays are transient, but this Dictionary is a copy, so it is
	# safe to keep. Upstream stops recording at 32; so does this.
	if _events.size() < MAX_EVENTS:
		_events.append(hit)
		_redraw()


func _redraw() -> void:
	_lines.clear_surfaces()
	if _events.is_empty():
		return
	_lines.surface_begin(Mesh.PRIMITIVE_LINES)
	for e in _events:
		var p: Vector3 = e["point"]
		for axis in [Vector3.RIGHT, Vector3.UP, Vector3.BACK]:
			_lines.surface_add_vertex(p - axis * CROSS_SIZE)
			_lines.surface_add_vertex(p + axis * CROSS_SIZE)
		_lines.surface_add_vertex(p)
		_lines.surface_add_vertex(p - (e["approach_speed"] as float) * (e["normal"] as Vector3))
	_lines.surface_end()
	var last: Dictionary = _events[-1]
	_label.text = "hit events = %d\nlast: %.1f m/s, material %d" % [
		_events.size(), last["approach_speed"], last["user_material_a"]]


## Upstream's floor: b3CreateGridMesh(20, 20, 8, 6, true), whose cell c takes
## material c % 6 on both of its triangles (src/mesh.c:1256-1285).
func _build_ground() -> void:
	var verts := PackedVector3Array()
	var half := 0.5 * CELL_WIDTH * CELLS
	for ix in CELLS + 1:
		for iz in CELLS + 1:
			verts.append(Vector3(-half + ix * CELL_WIDTH, 0.0, -half + iz * CELL_WIDTH))

	var idx := PackedInt32Array()
	var tri_materials := PackedByteArray()
	var cell := 0
	for ix in CELLS:
		for iz in CELLS:
			var i1 := iz + (CELLS + 1) * ix
			var i2 := i1 + 1
			var i3 := i2 + (CELLS + 1)
			var i4 := i3 - 1
			idx.append_array([i1, i2, i3, i3, i4, i1])
			tri_materials.append(cell % MATERIAL_COUNT)
			tri_materials.append(cell % MATERIAL_COUNT)
			cell += 1

	var materials := []
	for i in MATERIAL_COUNT:
		# Upstream's only change from the default material is the id, which is
		# what the hit event reports back.
		materials.append({"user_material_id": i + 1})

	var ground := Box3DBody.new()
	ground.name = "Ground"
	ground.body_type = Box3DBody.STATIC
	ground.shape_type = Box3DBody.MESH
	ground.mesh_weld_tolerance = 0.0
	ground.mesh_median_split = true
	ground.surface_materials = materials
	ground.mesh_indices = idx
	ground.mesh_materials = tri_materials
	ground.mesh_vertices = verts

	var visual := MeshInstance3D.new()
	visual.name = "GroundVisual"
	visual.mesh = _ground_surface(verts, idx)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.22, 0.25, 0.28)
	mat.roughness = 0.6
	visual.material_override = mat
	ground.add_child(visual)
	_world.add_child(ground)


## Box3D's winding is the opposite of Godot's; Box3DGeometry.make_array_mesh is
## where that is reversed, so the ground is drawn facing the side it collides on.
func _ground_surface(verts: PackedVector3Array, idx: PackedInt32Array) -> ArrayMesh:
	return Box3DGeometry.make_array_mesh({"vertices": verts, "indices": idx})


## Upstream's construction loop, one for one: capsules are accumulated on a
## body until it has three of them, then that body is given its kick and
## welded to the previous one.
func _build_tower() -> void:
	var tower := Node3D.new()
	tower.name = "Tower"
	_world.add_child(tower)

	var r := START_RADIUS
	var y := START_RADIUS
	var offset := START_OFFSET
	var spin := START_SPIN

	var pending: Array = []          # capsules waiting for their body
	var bodies: Array[Box3DBody] = []
	var weld_heights: Array = []

	for i in SHAPE_COUNT:
		pending.append({
			"p1": Vector3(offset, y, 0.0),
			"p2": Vector3(0.0, y + SEGMENT_LENGTH, -offset),
			"r": r,
		})
		if (i + 1) % SHAPES_PER_BODY == 0 or i == SHAPE_COUNT - 1:
			var body := _make_segment(pending, bodies.size())
			tower.add_child(body)
			bodies.append(body)
			pending = []
			# Upstream spins the segment about -z through the world origin,
			# so its centre of mass also gets the matching linear velocity.
			var omega := Vector3(0.0, 0.0, -spin)
			body.set_angular_velocity(omega)
			body.set_linear_velocity(omega.cross(body.get_center_of_mass()))
			if i < SHAPE_COUNT - 1:
				weld_heights.append(y + SEGMENT_LENGTH + r)
				spin *= SPIN_DECAY
		y += SEGMENT_LENGTH + 2.0 * r
		r *= RADIUS_DECAY
		offset = -offset

	for j in weld_heights.size():
		var joint := Box3DFixedJoint.new()
		joint.name = "Weld_%d" % j
		joint.position = Vector3(0.0, weld_heights[j], 0.0)
		joint.angular_hertz = WELD_ANGULAR_HERTZ
		joint.angular_damping = WELD_ANGULAR_DAMPING
		tower.add_child(joint)
		joint.body_a = NodePath("../Segment_%d" % j)
		joint.body_b = NodePath("../Segment_%d" % (j + 1))


func _make_segment(capsules: Array, index: int) -> Box3DBody:
	var body := Box3DBody.new()
	body.name = "Segment_%d" % index
	body.rolling_resistance = ROLLING_RESISTANCE
	for c in capsules:
		var p1: Vector3 = c["p1"]
		var p2: Vector3 = c["p2"]
		var radius: float = c["r"]
		var axis := (p2 - p1).normalized()
		var xform := Transform3D(
				Basis(Quaternion(Vector3.UP, axis)), 0.5 * (p1 + p2))
		var shape := Box3DCollisionShape.new()
		shape.shape_type = 2  # capsule
		shape.capsule_radius = radius
		shape.capsule_height = p1.distance_to(p2) + 2.0 * radius
		shape.rolling_resistance = ROLLING_RESISTANCE
		shape.transform = xform
		body.add_child(shape)

		var visual := MeshInstance3D.new()
		var mesh := CapsuleMesh.new()
		mesh.radius = radius
		mesh.height = p1.distance_to(p2) + 2.0 * radius
		visual.mesh = mesh
		visual.material_override = _capsule_material
		visual.transform = xform
		body.add_child(visual)
	return body
