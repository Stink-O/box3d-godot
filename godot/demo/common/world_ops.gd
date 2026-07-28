class_name WorldOps
extends RefCounted

## Everything the demo shell BUILDS IN or ASKS OF a physics world, in the one
## place that knows there is more than one backend.
##
## fly_camera.gd used to construct Box3DBody and Box3DMotorJoint nodes inline.
## With the engine selector the same camera has to do the same job against a
## NativeWorld, where bodies are RigidBody3D and there is no motor joint at all.
## Rather than thread `if native` through 600 lines of camera code, every
## construction, every velocity write and every "is this thing draggable" test
## comes through here.
##
## The Box3D branch of each function is the ORIGINAL code, node for node and
## property for property: tests/test_shoot.gd asserts that one _shoot() adds
## exactly one Box3DBody child to the world and that it is moving. Treat those
## branches as frozen and put new behaviour on the native side.
##
## Positions are LOCAL to the world node throughout, because that is what the
## camera always did (it assigned `.position`, never `.global_position`). The
## grab is the one caller that has to convert, and it already did.

# --- Tunables ---------------------------------------------------------------

## Upstream sample.cpp's mouse spring: 7.5 Hz, critically damped, force capped
## at 100 body weights, with an angular friction of ~0.5 * lever * mg. Both
## backends read these, so the grab is tuned in one place.
const GRAB_HERTZ := 7.5
const GRAB_DAMPING_RATIO := 1.0
const GRAB_FORCE_WEIGHTS := 100.0
const GRAB_TORQUE_WEIGHTS := 0.2

## Standard gravity, used as the floor under the grab's weight reference. In a
## zero-g world (the sidebar allows one) weight is zero and a weight-scaled
## force cap would clamp to zero, i.e. grabbing would silently do nothing.
const GRAB_MIN_G := 9.8

## Box3D's per-shape default. Godot's PhysicsMaterial defaults to 1.0 instead,
## so anything built here writes it out, exactly as RigNative does.
const DEFAULT_FRICTION := 0.6

## Shared projectile meshes: one SphereMesh per radius, not one per shot.
static var _sphere_meshes := {}


# --- Backend test -----------------------------------------------------------

## True when `world` is the Godot-Physics / Jolt stand-in rather than a real
## Box3DWorld. Everything below branches on exactly this.
static func is_native(world) -> bool:
	return world is NativeWorld


## Can the camera grab this? Box3D reports a body_type, Godot a freeze flag.
static func is_dynamic_body(node) -> bool:
	if node is Box3DBody:
		return node.body_type == Box3DBody.DYNAMIC
	if node is RigidBody3D:
		return not (node as RigidBody3D).freeze
	return false


# --- Spawning ---------------------------------------------------------------

## The camera's projectile (and the emitter's marble). `pos` is local to
## `world`; `restitution` and `mask` carry the shot's own material and its
## "fly through invisible guards" filter. `friction` only reaches the native
## branch: the Box3D branch below is frozen, and its callers all want the
## Box3D shape default this parameter defaults to anyway.
static func spawn_sphere(world, pos: Vector3, radius: float, density: float,
		mat: Material, continuous: bool, restitution := 0.0,
		mask := 0xFFFFFFFF, friction := DEFAULT_FRICTION) -> Node3D:
	if world == null:
		return null

	if is_native(world):
		var rb := _make_native_sphere(radius, density, mat, continuous,
				restitution, mask, friction)
		rb.position = pos
		world.add_child(rb)
		return rb

	var ball := Box3DBody.new()
	ball.debug_visualize = false  # projectiles keep their real look
	ball.collision_mask = mask
	ball.shape_type = Box3DBody.SPHERE
	ball.sphere_radius = radius
	ball.density = density
	ball.restitution = restitution
	ball.continuous = continuous
	ball.position = pos

	var mesh := MeshInstance3D.new()
	mesh.mesh = _sphere_mesh(radius)
	mesh.material_override = mat
	ball.add_child(mesh)

	world.add_child(ball)
	return ball


## The invisible probe the grab drags around. Collides with nothing on either
## backend: Box3D needs layer 0 / mask 0 (it ANDs both sides), Godot needs the
## same because it ORs them.
static func spawn_kinematic_sphere(world, pos: Vector3, radius: float) -> Node3D:
	if world == null:
		return null

	if is_native(world):
		# AnimatableBody3D, not a frozen RigidBody3D: it registers as a KINEMATIC
		# body in the server, which is what a body moved by code every tick is.
		# sync_to_physics stays OFF -- it exists so a kinematic body can shove
		# dynamics, and this one collides with nothing; leaving it on would also
		# let the internal physics-process sync fight the camera's own write.
		var probe := AnimatableBody3D.new()
		probe.sync_to_physics = false
		probe.collision_layer = 0
		probe.collision_mask = 0
		var shape := SphereShape3D.new()
		shape.radius = radius
		var cs := CollisionShape3D.new()
		cs.shape = shape
		probe.add_child(cs)
		probe.position = pos
		world.add_child(probe)
		return probe

	var mouse_body := Box3DBody.new()
	mouse_body.body_type = Box3DBody.KINEMATIC
	mouse_body.debug_visualize = false  # invisible helper, no debug shell
	mouse_body.shape_type = Box3DBody.SPHERE
	mouse_body.sphere_radius = radius
	mouse_body.collision_layer = 0  # collides with nothing
	mouse_body.collision_mask = 0
	mouse_body.position = pos  # BEFORE add_child
	world.add_child(mouse_body)
	return mouse_body


## Tie `target` to `mouse_body` at `at` (local to `world`) and hand back the
## node that has to be freed to let go.
##
## Box3D gets upstream's motor joint. The native side gets a bare anchor node
## instead, driven by drive_grab() below, because NEITHER native joint reproduces
## this: Godot has no motor joint, and Generic6DOFJoint3D's linear springs are
## the one 6DOF feature whose behaviour differs between GodotPhysics and Jolt
## (stiffness is not in hertz on either, and GodotPhysics' spring flags are
## unreliable), so a spring joint would feel like a different tool per engine.
## A soft point constraint applied as an impulse is identical on both, uses the
## same hertz/damping numbers as Box3D, and pivots off-centre grabs the same way
## because the anchor is parented to the body it grabbed.
static func make_grab_joint(world, mouse_body: Node3D, target: Node3D,
		at: Vector3) -> Node:
	if world == null or target == null:
		return null

	if is_native(world):
		var anchor := Node3D.new()
		anchor.name = "GrabAnchor"
		target.add_child(anchor)
		# Parented to the body, so it tracks the grabbed point through rotation
		# for free. `at` is world-local; convert once, here.
		anchor.global_position = (world as Node3D).global_transform * at
		return anchor

	var mg: float = (target as Box3DBody).get_mass() \
			* maxf(world.gravity.length(), GRAB_MIN_G)
	var joint := Box3DMotorJoint.new()
	joint.position = at  # joint frame = grab point
	joint.max_force = 0.0  # no velocity drive; the position spring pulls
	joint.linear_hertz = GRAB_HERTZ
	joint.linear_damping = GRAB_DAMPING_RATIO
	joint.max_spring_force = GRAB_FORCE_WEIGHTS * mg
	joint.max_torque = GRAB_TORQUE_WEIGHTS * mg  # angular friction (lever ~0.4 m)
	world.add_child(joint)
	joint.body_a = joint.get_path_to(mouse_body)
	joint.body_b = joint.get_path_to(target)
	return joint


## One tick of the grab. A no-op on Box3D, where the solver owns the joint.
##
## The native path is Box2D/Box3D's own soft-constraint step written out by hand:
## the bias/mass scales below are unconditionally stable at any hertz, which a
## plain PD impulse is not (a 7.5 Hz spring at 60 Hz ticks overshoots its own
## damping term). The impulse is applied at the anchor, so an off-centre grab
## pivots the body instead of re-centring it, and it is capped at the same 100
## weights Box3D caps its spring force at.
##
## Not carried across: Box3D's max_torque dry friction. Nothing native applies a
## capped torque against rotation, so a grabbed body swings a little more freely
## here than it does on Box3D.
static func drive_grab(world, mouse_body: Node3D, target: Node3D,
		joint: Node) -> void:
	if not is_native(world):
		return
	var rb := target as RigidBody3D
	var anchor := joint as Node3D
	if rb == null or anchor == null or mouse_body == null:
		return
	if not (is_instance_valid(rb) and is_instance_valid(anchor)):
		return

	var h := 1.0 / maxf(float(Engine.physics_ticks_per_second), 1.0)
	var omega := TAU * GRAB_HERTZ
	var a1 := 2.0 * GRAB_DAMPING_RATIO + h * omega
	var a2 := h * omega * a1
	var bias_rate := omega / a1
	var mass_scale := a2 / (1.0 + a2)

	var point := anchor.global_position
	var com := rb.global_transform * rb.center_of_mass
	var point_velocity := rb.linear_velocity + rb.angular_velocity.cross(point - com)
	var err := mouse_body.global_position - point

	# Plain mass, not the effective mass at the anchor: computing the latter
	# needs the inverse of the point's 3x3 constraint matrix, and the force cap
	# below already bounds what over-driving an off-centre grab can do.
	var impulse := (err * bias_rate - point_velocity) * (mass_scale * rb.mass)
	var cap := GRAB_FORCE_WEIGHTS * rb.mass * GRAB_MIN_G * h
	if impulse.length() > cap:
		impulse = impulse.normalized() * cap
	rb.apply_impulse(impulse, point - rb.global_position)


## Instantiate an authored Box3D scene (bomb, ragdoll) into `world` at `xf`,
## which REPLACES the scene root's own transform -- both demo props are authored
## at identity. `props` is written before the node enters the tree, because a
## Box3DBody commits its position and filtering to the solver on enter-tree;
## entries the node does not own are skipped, so the caller never has to ask
## which backend it is talking to.
static func spawn_authored_scene(world, packed: PackedScene, xf: Transform3D,
		props: Dictionary = {}) -> Node3D:
	if world == null or packed == null:
		return null

	if is_native(world):
		return _native_authored_scene(world, packed, xf, props)

	var node := packed.instantiate() as Node3D
	if node == null:
		return null
	node.transform = xf
	_apply_props(node, props)
	world.add_child(node)
	return node


# --- World and body access --------------------------------------------------
#
# Box3DBody and RigidBody3D bind the SAME three names, so these need no backend
# branch -- only a dynamic call, because Node3D (the widened static type the
# shell now carries a world and its bodies as) does not declare them.

## Box3DWorld.raycast and NativeWorld.raycast agree on signature and on return
## shape; this exists only so callers can keep a world typed as Node3D.
static func raycast(world, from: Vector3, to: Vector3,
		mask := 0xFFFFFFFF) -> Dictionary:
	if world == null:
		return {"hit": false}
	var hit = world.call(&"raycast", from, to, mask)
	return hit if hit is Dictionary else {"hit": false}


static func set_body_transform(body: Node3D, xf: Transform3D) -> void:
	if body == null or not is_instance_valid(body):
		return
	body.global_transform = xf


static func linear_velocity(body: Node3D) -> Vector3:
	if body == null or not is_instance_valid(body):
		return Vector3.ZERO
	if not body.has_method(&"get_linear_velocity"):
		return Vector3.ZERO
	var v = body.call(&"get_linear_velocity")
	return v if v is Vector3 else Vector3.ZERO


static func set_linear_velocity(body: Node3D, v: Vector3) -> void:
	if body == null or not is_instance_valid(body):
		return
	# A StaticBody3D in a rebuilt prop simply has nothing to set.
	if body.has_method(&"set_linear_velocity"):
		body.call(&"set_linear_velocity", v)


static func apply_central_impulse(body: Node3D, imp: Vector3) -> void:
	if body == null or not is_instance_valid(body):
		return
	if body.has_method(&"apply_central_impulse"):
		body.call(&"apply_central_impulse", imp)


## Every physics body at or under `root`, whichever backend built it. `root`
## itself counts, because an authored Box3D prop can BE the body (bomb.tscn)
## while its native rebuild is a container. One of the two queries always comes
## back empty, which is cheaper than asking who built it.
static func bodies_in(root: Node) -> Array[Node3D]:
	var out: Array[Node3D] = []
	if root == null:
		return out
	# PhysicsBody3D, not RigidBody3D: a rebuilt prop's anchor is a StaticBody3D,
	# and callers expect the whole body list (set_linear_velocity skips the ones
	# that cannot take it). Box3DBody derives from Node3D, so the two queries
	# never overlap and nothing is counted twice.
	if root is Box3DBody or root is PhysicsBody3D:
		out.append(root as Node3D)
	for node in root.find_children("*", "Box3DBody", true, false):
		out.append(node as Node3D)
	for node in root.find_children("*", "PhysicsBody3D", true, false):
		out.append(node as Node3D)
	return out


# --- Native scene rebuilds --------------------------------------------------

## The authored props are Box3D scenes and cannot be instantiated on a native
## engine at all -- bomb.gd literally `extends Box3DBody` -- so they go through
## the comparison harness's reader/builder pair instead of being hand-ported.
static func _native_authored_scene(world, packed: PackedScene, xf: Transform3D,
		props: Dictionary) -> Node3D:
	var container := Node3D.new()
	container.name = "NativeProp"
	container.transform = xf

	var rig := RigExtract.from_scene(packed.resource_path)
	var rig_bodies: Array = rig.get("bodies", [])
	if rig_bodies.is_empty():
		_native_root_body(packed, container)
	else:
		# Deliberately NOT RigNative.apply_world_settings(): that writes gravity
		# onto the space, and this prop's default would overwrite the gravity of
		# the sample it is being thrown into. Its build warnings are dropped too
		# -- the shell has no panel for them, and the harness already reports the
		# same rig in full.
		RigNative.build(rig, container)

	# On the Box3D side the scene ROOT owns the props (bomb.tscn's root IS the
	# body); here the root is this plain container, so the bodies inside must
	# get the same offer or the camera's blast_impulse / collision_mask writes
	# would silently land on a Node3D that owns none of them.
	_apply_props(container, props)
	for body in bodies_in(container):
		_apply_props(body, props)
	world.add_child(container)
	return container


## A scene whose ROOT is the body -- common/bomb.tscn -- reads back as an EMPTY
## rig: RigExtract walks the CHILDREN of its origin node, and with no Box3DWorld
## in the scene that origin is the root itself. Rebuild that single body from
## the root's own properties rather than fork the extractor over one case.
##
## The SCRIPT cannot come across as-is -- bomb.gd extends Box3DBody -- but the
## bomb's behaviour has a hand-written native twin (native_bomb.gd, same fuse /
## blink / impact rules, detonating through ExplosionFX.blast's native branch),
## attached below when the authored root carries bomb.gd. Any other root script
## stays stripped.
static func _native_root_body(packed: PackedScene, parent: Node3D) -> void:
	var src := packed.instantiate()
	if src == null:
		return

	if _gint(src, &"shape_type", RigExtract.SHAPE_SPHERE) != RigExtract.SHAPE_SPHERE:
		push_warning("[world_ops] %s: root body is not a sphere, rebuilt as one"
				% packed.resource_path)

	var body := _make_native_sphere(
			_gfloat(src, &"sphere_radius", 0.5),
			_gfloat(src, &"density", 1.0),
			null,
			_gbool(src, &"continuous", false),
			_gfloat(src, &"restitution", 0.0),
			_gint(src, &"collision_mask", -1) & 0xFFFFFFFF)
	body.name = String(src.name)

	# The authored look comes across as-is; the scripts on it do not, for the
	# same reason compare.gd strips them -- they expect Box3D siblings.
	for child in src.get_children():
		if child is VisualInstance3D:
			var copy := (child as Node3D).duplicate(0) as Node3D
			_strip_scripts(copy)
			body.add_child(copy)

	var src_script := src.get_script() as Script
	if src_script != null and src_script.resource_path == "res://common/bomb.gd":
		# Before add_child, so the twin's _ready runs on tree entry.
		body.set_script(load("res://common/native_bomb.gd"))

	parent.add_child(body)
	src.free()


static func _make_native_sphere(radius: float, density: float, mat: Material,
		continuous: bool, restitution: float, mask: int,
		friction := DEFAULT_FRICTION) -> RigidBody3D:
	var body := RigidBody3D.new()
	# Box3D derives mass from a density and the shape's volume; Godot has
	# neither, so integrate the one shape being built here.
	body.mass = maxf(density * 4.0 / 3.0 * PI * radius * radius * radius, 0.001)
	body.continuous_cd = continuous
	body.collision_mask = mask
	# The same two corrections RigNative applies to every rebuilt body: Box3D
	# damps the body alone (Godot's default mode adds the space's damp on top),
	# and Box3D's shape defaults are friction 0.6 / restitution 0.
	body.linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	body.linear_damp = 0.0
	body.angular_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	body.angular_damp = 0.05
	var pm := PhysicsMaterial.new()
	pm.friction = friction
	pm.bounce = restitution
	pm.rough = false
	pm.absorbent = false
	body.physics_material_override = pm

	var shape := SphereShape3D.new()
	shape.radius = radius
	var cs := CollisionShape3D.new()
	cs.shape = shape
	body.add_child(cs)
	# No explicit inertia, unlike RigNative: a sphere is the one shape both
	# native engines already get exactly right on their own.

	if mat != null:
		var mesh := MeshInstance3D.new()
		mesh.mesh = _sphere_mesh(radius)
		mesh.material_override = mat
		body.add_child(mesh)
	return body


# --- Helpers ----------------------------------------------------------------

static func _sphere_mesh(radius: float) -> SphereMesh:
	var key := snappedf(radius, 0.0001)
	if not _sphere_meshes.has(key):
		var mesh := SphereMesh.new()
		mesh.radius = radius
		mesh.height = radius * 2.0
		_sphere_meshes[key] = mesh
	return _sphere_meshes[key] as SphereMesh


static func _apply_props(node: Node, props: Dictionary) -> void:
	for key in props:
		if key in node:
			node.set(key, props[key])


static func _strip_scripts(node: Node) -> void:
	node.set_script(null)
	for child in node.get_children():
		_strip_scripts(child)


static func _gfloat(node: Object, prop: StringName, def: float) -> float:
	return float(node.get(prop)) if prop in node else def


static func _gint(node: Object, prop: StringName, def: int) -> int:
	return int(node.get(prop)) if prop in node else def


static func _gbool(node: Object, prop: StringName, def: bool) -> bool:
	return bool(node.get(prop)) if prop in node else def
