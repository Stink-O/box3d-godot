extends Node3D

## Gear Lift -- a port of upstream's "Joints / Gear Lift" sample
## (samples/sample_joint.cpp:2627). A motorised gear turns a second gear, which
## winds two chains over its rim and hauls a gate up out of a stairwell full of
## rubble. Six of the nine joint types are not needed: this is a revolute joint
## machine, 83 of them, plus one prismatic that keeps the gate upright.
##
## What each piece is doing:
##  * The stairwell is ONE triangle mesh -- the Box2D stairwell silhouette
##    extruded 4 m along z, side walls plus earcut end caps, wound so the
##    collision normals face into the basin. It is the 3D analogue of a Box2D
##    chain loop and it is authored through the node's raw `mesh_vertices` /
##    `mesh_indices` path.
##  * Each gear is one rigid body carrying 35 shapes: a disk at each depth, an
##    axle bridging them, and two 16-tooth rings. Both gears spin about z.
##  * The driver's revolute joint has a 30 kN.m motor at -0.3 rad/s. The
##    follower's has a 0.5 N.m motor and angle limits, so it sweeps rather than
##    spins and the gate stops at the top.
##  * Each chain is 40 capsule links on revolute joints with a 0.05 N.m motor,
##    which is joint friction: without it the chain whips.
##
## Two deliberate deviations from upstream, both forced by the node model:
##  * Upstream offsets the follower joint's frame A by a quarter turn
##    (`localFrameA.q`) and then limits the angle to [-0.3pi, 0.8pi]. A joint
##    NODE derives both frames from one transform, so its angle always starts
##    at zero and the same physical sweep is [-0.05pi, 1.05pi] -- and box3d
##    saturates a revolute limit at +/-0.99pi (types.h:853-857). The upper
##    limit here is 0.99pi, which is 11 degrees short of upstream's sweep.
##  * `b3CreateRock` is not bound, so the debris hull is rebuilt here from its
##    own source: the same 10-point Fibonacci lattice on a sphere
##    (src/hull.c:1859-1892), turned into a mesh so the HULL shape path can
##    hull it back. Same 120 rocks, same 0.3 m radius, same collider.
##
## The shell's toggle is upstream's Motor checkbox.

const GROUND_EXTENT := 20.0  # Sample::AddGroundBox(20)

const GEAR_RADIUS := 1.0
const GEAR_HALF_DEPTH := 0.125
const GEAR_Z := 1.5
const AXLE_RADIUS := 0.2
const TOOTH_HALF_WIDTH := 0.11  # radial half extent
const TOOTH_HALF_HEIGHT := 0.09  # tangential half width at the base
const TOOTH_RADIUS := 0.03  # how much narrower the tip is
const TOOTH_COUNT := 16
const GEAR_SIDES := 24
const AXLE_SIDES := 12

const LINK_HALF_LENGTH := 0.07
const LINK_RADIUS := 0.05
const LINK_COUNT := 40

const DOOR_HALF_HEIGHT := 1.5
const DOOR_HALF_DEPTH := 1.95
const DOOR_HALF_THICK := 0.05

const ROCK_RADIUS := 0.3
const ROCK_COLUMNS := 12
const ROCK_ROWS := 10

## b3DefaultShapeDef's density is 1000 kg/m3 -- the density of water
## (src/types.c:72-73) -- where the Box3DBody / Box3DCollisionShape nodes both
## default to 1. Every force in this sample is an absolute number tuned against
## that: the 200 N brake on the gate, the 0.05 N.m of friction in each chain
## joint, the 30 kN.m at the driver. At density 1 a chain link weighs 1.6 g and
## box3d's joint softness (a spring in Hz, so its stiffness is proportional to
## the constrained mass) cannot transmit 200 N through it -- the chain visibly
## stretches by a quarter of its length instead of hauling the gate. So this
## port sets density explicitly everywhere, which is the value upstream gets
## for free.
const DENSITY := 1000.0

const MOTOR_TORQUE := 30000.0
const MOTOR_SPEED := -0.3

const GEAR1 := Vector3(-4.25, 9.75, 0.0)  # driver
const GEAR2 := Vector3(-2.25, 10.75, 0.0)  # follower

const MESH_Z := 2.0  # the stairwell is four metres across z

## The Box2D stairwell silhouette, traced as a closed loop
## (samples/sample_joint.cpp:2723-2733).
const SILHOUETTE := [
	Vector2(-11.3000, -0.2167), Vector2(9.3375, -0.2167), Vector2(9.3375, 7.1917),
	Vector2(8.8083, 7.1917), Vector2(8.8083, 0.3125), Vector2(0.3417, 0.3125),
	Vector2(0.3417, 0.8417), Vector2(-0.1875, 0.8417), Vector2(-0.1875, 1.3708),
	Vector2(-0.7167, 1.3708), Vector2(-0.7167, 1.9000), Vector2(-1.2458, 1.9000),
	Vector2(-1.2458, 2.4292), Vector2(-1.7750, 2.4292), Vector2(-1.7750, 2.9583),
	Vector2(-2.3042, 2.9583), Vector2(-2.3042, 3.4875), Vector2(-2.8333, 3.4875),
	Vector2(-2.8333, 4.0167), Vector2(-3.3625, 4.0167), Vector2(-3.3625, 4.5458),
	Vector2(-3.8917, 4.5458), Vector2(-3.8917, 5.0750), Vector2(-4.4208, 5.0750),
	Vector2(-4.4208, 5.6042), Vector2(-4.9500, 5.6042), Vector2(-4.9500, 6.1333),
	Vector2(-5.4792, 6.1333), Vector2(-5.4792, 6.6625), Vector2(-6.0083, 6.6625),
	Vector2(-6.0083, 7.1917), Vector2(-11.3000, 7.1917),
]

var camera_home := Vector3(3.64, 8.03, 15.82)
var camera_look_at := Vector3(-1.5, 4.5, 0.0)

var _world: Box3DWorld
var _driver_joint: Box3DHingeJoint
var _follower: Box3DBody
var _door: Box3DBody
var _motor_on := true
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.seed = 0x6ea111f7
	_world = $Box3DWorld

	_build_ground()
	_build_stairwell()

	var driver := _build_gear("Driver", GEAR1, GEAR_RADIUS + TOOTH_HALF_HEIGHT)
	_follower = _build_gear("Follower", GEAR2, GEAR_RADIUS + TOOTH_HALF_WIDTH)

	# Driver shaft, motorised. Revolute joints turn about their frame's local z
	# (types.h:829-831), which is already the gear axis here.
	_driver_joint = Box3DHingeJoint.new()
	_driver_joint.name = "DriverJoint"
	_driver_joint.position = GEAR1
	_world.add_child(_driver_joint)
	_driver_joint.body_a = NodePath("../Ground")
	_driver_joint.body_b = NodePath("../Driver")
	_driver_joint.motor_enabled = _motor_on
	_driver_joint.max_motor_torque = MOTOR_TORQUE
	_driver_joint.motor_speed = MOTOR_SPEED

	# Follower shaft, swept between limits. See the note at the top about the
	# quarter-turn frame offset upstream uses to place this range.
	var follower_joint := Box3DHingeJoint.new()
	follower_joint.name = "FollowerJoint"
	follower_joint.position = GEAR2
	_world.add_child(follower_joint)
	follower_joint.body_a = NodePath("../Ground")
	follower_joint.body_b = NodePath("../Follower")
	follower_joint.motor_enabled = true
	follower_joint.max_motor_torque = 0.5
	follower_joint.limit_enabled = true
	follower_joint.lower_limit = -0.05 * PI
	follower_joint.upper_limit = 0.99 * PI

	# One chain at each depth, hanging from the follower's rim.
	var attach := Vector3(
		GEAR2.x + GEAR_RADIUS + 2.0 * TOOTH_HALF_WIDTH + TOOTH_RADIUS, GEAR2.y, 0.0)
	var door_position := Vector3(
		attach.x, attach.y - (2.0 * LINK_COUNT * LINK_HALF_LENGTH + DOOR_HALF_HEIGHT), 0.0)
	var near_link := _build_chain("Near", _follower, Vector3(attach.x, attach.y, -GEAR_Z))
	var far_link := _build_chain("Far", _follower, Vector3(attach.x, attach.y, GEAR_Z))

	_build_door(door_position, near_link, far_link)
	_build_debris()


func _build_ground() -> void:
	# Sample::AddGroundBox: a static box at y = -1 whose top face is y = 0.
	var ground_box := Box3DBody.new()
	ground_box.name = "GroundBox"
	ground_box.body_type = Box3DBody.STATIC
	ground_box.shape_type = Box3DBody.BOX
	ground_box.box_size = Vector3(2.0 * GROUND_EXTENT, 2.0, 2.0 * GROUND_EXTENT)
	ground_box.position = Vector3(0.0, -1.0, 0.0)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.22, 0.25, 0.27)
	mat.roughness = 0.95
	_add_box_visual(ground_box, ground_box.box_size, mat)
	_world.add_child(ground_box)


## The stairwell mesh plus the back wall, and the static body the joints anchor
## to. Upstream hangs all of it off one body at the origin.
func _build_stairwell() -> void:
	var verts := PackedVector3Array()
	for p in SILHOUETTE:
		verts.append(Vector3(p.x, p.y, -MESH_Z))
		verts.append(Vector3(p.x, p.y, MESH_Z))

	var idx := PackedInt32Array()
	var n := SILHOUETTE.size()
	# Side walls: two triangles per silhouette edge, normals into the basin.
	for i in n:
		var j := (i + 1) % n
		var a_lo := 2 * i
		var a_hi := 2 * i + 1
		var b_lo := 2 * j
		var b_hi := 2 * j + 1
		idx.append_array([a_lo, b_lo, b_hi, a_lo, b_hi, a_hi])

	# End caps. Godot's Geometry2D.triangulate_polygon is the earcut upstream
	# calls; each triangle is then wound so the cap normal points out of the
	# solid, +z for the zMax cap and -z for the zMin one.
	var ring := PackedVector2Array()
	for p in SILHOUETTE:
		ring.append(p)
	var cap := Geometry2D.triangulate_polygon(ring)
	for k in range(0, cap.size() - 2, 3):
		var r0 := cap[k]
		var r1 := cap[k + 1]
		var r2 := cap[k + 2]
		idx.append_array(_cap_triangle(r0, r1, r2, 1, true))
		idx.append_array(_cap_triangle(r0, r1, r2, 0, false))

	var walls := Box3DBody.new()
	walls.name = "Ground"  # the joints' static anchor, as upstream's groundId is
	walls.body_type = Box3DBody.STATIC
	walls.shape_type = Box3DBody.MESH
	walls.mesh_weld_tolerance = 0.0  # b3MeshDef def = {}
	walls.mesh_indices = idx
	walls.mesh_vertices = verts
	var visual := MeshInstance3D.new()
	visual.name = "StairwellVisual"
	visual.mesh = _surface_from(verts, idx)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.45, 0.55, 0.48)  # b3_colorDarkSeaGreen
	mat.roughness = 0.8
	visual.material_override = mat
	walls.add_child(visual)
	_world.add_child(walls)

	# Back wall: 0.1 m thick, closing the far side over the mesh's full extent.
	var lower := SILHOUETTE[0] as Vector2
	var upper := SILHOUETTE[0] as Vector2
	for p in SILHOUETTE:
		lower = Vector2(minf(lower.x, p.x), minf(lower.y, p.y))
		upper = Vector2(maxf(upper.x, p.x), maxf(upper.y, p.y))
	var wall := Box3DBody.new()
	wall.name = "BackWall"
	wall.body_type = Box3DBody.STATIC
	wall.shape_type = Box3DBody.BOX
	wall.box_size = Vector3(upper.x - lower.x, upper.y - lower.y, 0.1)
	wall.position = Vector3(
		0.5 * (lower.x + upper.x), 0.5 * (lower.y + upper.y), -MESH_Z - 0.05)
	var wall_mat := StandardMaterial3D.new()
	wall_mat.albedo_color = Color(0.3, 0.36, 0.33)
	wall_mat.roughness = 0.9
	_add_box_visual(wall, wall.box_size, wall_mat)
	_world.add_child(wall)


## Upstream's PushCap: flip the winding so the cap's z-normal has the sign we
## want (samples/sample_joint.cpp:2818-2839).
func _cap_triangle(r0: int, r1: int, r2: int, offset: int, want_positive_z: bool) -> PackedInt32Array:
	var p0 := SILHOUETTE[r0] as Vector2
	var p1 := SILHOUETTE[r1] as Vector2
	var p2 := SILHOUETTE[r2] as Vector2
	var cross := (p1.x - p0.x) * (p2.y - p0.y) - (p1.y - p0.y) * (p2.x - p0.x)
	var v0 := 2 * r0 + offset
	var v1 := 2 * r1 + offset
	var v2 := 2 * r2 + offset
	if (cross > 0.0) == want_positive_z:
		return PackedInt32Array([v0, v1, v2])
	return PackedInt32Array([v0, v2, v1])


## One gear shaft: a disk and a tooth ring at each depth, bridged by an axle,
## all on one body so both depths share an angle.
func _build_gear(p_name: String, p_position: Vector3, p_tooth_radius: float) -> Box3DBody:
	var gear := Box3DBody.new()
	gear.name = p_name
	gear.position = p_position
	gear.density = DENSITY
	gear.friction = 0.1
	gear.angular_damping = 0.0  # b3DefaultBodyDef; the node defaults to 0.05

	var metal := StandardMaterial3D.new()
	metal.albedo_color = Color(0.55, 0.35, 0.18)  # b3_colorSaddleBrown
	metal.roughness = 0.5
	var steel := StandardMaterial3D.new()
	steel.albedo_color = Color(0.44, 0.5, 0.56)  # b3_colorSlateGray
	steel.metallic = 0.7
	steel.roughness = 0.35
	var tooth_mat := StandardMaterial3D.new()
	tooth_mat.albedo_color = Color(0.5, 0.5, 0.5)  # b3_colorGray
	tooth_mat.roughness = 0.6

	# The disks and the axle are cylinders along z; the node's cylinder runs
	# along y, so each carries a quarter turn about x.
	var lie_down := Basis(Vector3.RIGHT, 0.5 * PI)
	for depth in [-GEAR_Z, GEAR_Z]:
		_add_cylinder(gear, "Disk%d" % int(signf(depth)), GEAR_RADIUS, 2.0 * GEAR_HALF_DEPTH,
			GEAR_SIDES, Transform3D(lie_down, Vector3(0.0, 0.0, depth)), metal)
	_add_cylinder(gear, "Axle", AXLE_RADIUS, 2.0 * GEAR_Z, AXLE_SIDES,
		Transform3D(lie_down, Vector3.ZERO), steel)

	var tooth_shapes: Array[Box3DCollisionShape] = []
	var tooth_points: Array = []
	for depth in [-GEAR_Z, GEAR_Z]:
		for i in TOOTH_COUNT:
			var angle := i * TAU / TOOTH_COUNT
			var basis := Basis(Vector3.BACK, angle)
			var center: Vector3 = basis * Vector3(p_tooth_radius, 0.0, 0.0)
			center.z = depth
			var shape := Box3DCollisionShape.new()
			shape.name = "Tooth_%d_%d" % [int(signf(depth)), i]
			shape.shape_type = Box3DCollisionShape.BOX
			shape.box_size = Vector3(
				2.0 * TOOTH_HALF_WIDTH, 2.0 * TOOTH_HALF_HEIGHT, 2.0 * GEAR_HALF_DEPTH)
			shape.friction = 0.1
			shape.density = DENSITY
			shape.transform = Transform3D(basis, center)
			gear.add_child(shape)
			tooth_shapes.append(shape)
			tooth_points.append(_tooth_points(basis, center))

			var visual := MeshInstance3D.new()
			visual.mesh = _tooth_mesh()
			visual.material_override = tooth_mat
			visual.transform = shape.transform
			gear.add_child(visual)

	_world.add_child(gear)

	# Box3D has no rounded hulls, so upstream tapers each tooth tangentially
	# toward its tip to clear the meshing teeth. A Box3DCollisionShape cannot
	# AUTHOR a hull, but it can be retyped into one once it is live, and
	# b3Shape_SetHull takes the points in the body frame -- which is where
	# upstream computes them too.
	for i in tooth_shapes.size():
		tooth_shapes[i].set_hull(tooth_points[i], i == tooth_shapes.size() - 1)

	return gear


## Upstream's eight tooth corners: base at the inner radius, narrower tip at
## the outer one (samples/sample_joint.cpp:3006-3022).
func _tooth_points(p_basis: Basis, p_center: Vector3) -> PackedVector3Array:
	var hx := TOOTH_HALF_WIDTH
	var hz := GEAR_HALF_DEPTH
	var base_half := TOOTH_HALF_HEIGHT
	var tip_half := TOOTH_HALF_HEIGHT - TOOTH_RADIUS
	var local := [
		Vector3(-hx, -base_half, -hz), Vector3(-hx, base_half, -hz),
		Vector3(-hx, base_half, hz), Vector3(-hx, -base_half, hz),
		Vector3(hx, -tip_half, -hz), Vector3(hx, tip_half, -hz),
		Vector3(hx, tip_half, hz), Vector3(hx, -tip_half, hz),
	]
	var out := PackedVector3Array()
	for v in local:
		out.append(p_center + p_basis * v)
	return out


## A chain of capsule links from a body down to the gate. Returns the last one.
func _build_chain(p_tag: String, p_top: Box3DBody, p_attach: Vector3) -> Box3DBody:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.69, 0.77, 0.87)  # b3_colorLightSteelBlue
	mat.metallic = 0.5
	mat.roughness = 0.4

	var position := Vector3(p_attach.x, p_attach.y - LINK_HALF_LENGTH, p_attach.z)
	var previous := p_top
	for i in LINK_COUNT:
		var link := Box3DBody.new()
		link.name = "Link_%s_%d" % [p_tag, i]
		link.shape_type = Box3DBody.CAPSULE
		link.capsule_radius = LINK_RADIUS
		link.capsule_height = 2.0 * LINK_HALF_LENGTH + 2.0 * LINK_RADIUS
		link.density = DENSITY
		link.position = position
		link.angular_damping = 0.0
		var visual := MeshInstance3D.new()
		var cm := CapsuleMesh.new()
		cm.radius = LINK_RADIUS
		cm.height = link.capsule_height
		cm.radial_segments = 6
		cm.rings = 2
		visual.mesh = cm
		visual.material_override = mat
		link.add_child(visual)
		_world.add_child(link)

		var joint := Box3DHingeJoint.new()
		joint.name = "LinkJoint_%s_%d" % [p_tag, i]
		joint.position = Vector3(position.x, position.y + LINK_HALF_LENGTH, p_attach.z)
		_world.add_child(joint)
		joint.body_a = NodePath("../%s" % previous.name)
		joint.body_b = NodePath("../%s" % link.name)
		# 0.05 N.m of joint friction, which is what stops the chain whipping.
		joint.motor_enabled = true
		joint.max_motor_torque = 0.05

		position.y -= 2.0 * LINK_HALF_LENGTH
		previous = link
	return previous


## The gate: hinged to both chains and held upright by a prismatic joint.
func _build_door(p_position: Vector3, p_near: Box3DBody, p_far: Box3DBody) -> void:
	_door = Box3DBody.new()
	_door.name = "Door"
	_door.shape_type = Box3DBody.BOX
	_door.box_size = Vector3(
		2.0 * DOOR_HALF_THICK, 2.0 * DOOR_HALF_HEIGHT, 2.0 * DOOR_HALF_DEPTH)
	_door.position = p_position
	_door.density = 0.5 * DENSITY  # shapeDef.density *= 0.5
	_door.friction = 0.1
	_door.angular_damping = 0.0
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.0, 0.55, 0.55)  # b3_colorDarkCyan
	mat.metallic = 0.8
	mat.roughness = 0.3
	_add_box_visual(_door, _door.box_size, mat)
	_world.add_child(_door)

	var links := [p_near, p_far]
	var depths := [-GEAR_Z, GEAR_Z]
	for i in 2:
		var joint := Box3DHingeJoint.new()
		joint.name = "DoorJoint%d" % i
		joint.position = Vector3(p_position.x, p_position.y + DOOR_HALF_HEIGHT, depths[i])
		_world.add_child(joint)
		joint.body_a = NodePath("../%s" % links[i].name)
		joint.body_b = NodePath("../Door")
		joint.motor_enabled = true
		joint.max_motor_torque = 50.0

	# A prismatic joint slides along its frame's local x (types.h:784-786), so
	# the node is turned to put its x on world up.
	var slider := Box3DSliderJoint.new()
	slider.name = "DoorSlide"
	slider.transform = Transform3D(Basis(Quaternion(Vector3.RIGHT, Vector3.UP)), p_position)
	_world.add_child(slider)
	slider.body_a = NodePath("../Ground")
	slider.body_b = NodePath("../Door")
	slider.collide_connected = true
	slider.motor_enabled = true
	slider.max_motor_force = 200.0
	slider.motor_speed = 0.0


## 120 rocks tumbled into the basin.
func _build_debris() -> void:
	var mesh := _rock_mesh()
	var colors := [
		Color(0.5, 0.5, 0.5), Color(0.86, 0.86, 0.86), Color(0.83, 0.83, 0.83),
		Color(0.47, 0.53, 0.6), Color(0.66, 0.66, 0.66),
	]
	var materials: Array[StandardMaterial3D] = []
	for c in colors:
		var m := StandardMaterial3D.new()
		m.albedo_color = c
		m.roughness = 0.85
		materials.append(m)

	var x := -5.0
	for i in ROCK_COLUMNS:
		var y := 6.5 - 0.25 * i
		for j in ROCK_ROWS:
			var rock := Box3DBody.new()
			rock.name = "Rock_%d_%d" % [i, j]
			rock.shape_type = Box3DBody.HULL
			rock.collision_mesh = mesh
			rock.density = DENSITY
			rock.rolling_resistance = 0.3
			rock.angular_damping = 0.0
			rock.position = Vector3(x, y, _rng.randf_range(-1.65, 0.35))
			rock.quaternion = _random_quat()
			var visual := MeshInstance3D.new()
			visual.mesh = mesh
			visual.material_override = materials[_rng.randi_range(0, 4)]
			rock.add_child(visual)
			_world.add_child(rock)
			y += 0.2
		x += 0.3


## The shell's toggle: upstream's Motor checkbox.
func get_toggle_label() -> String:
	return "Motor"


## The switch reports startup state, it does not impose it: the lift loads with
## its motor running, as upstream does (m_enableMotor = true,
## sample_joint.cpp:2656).
func get_toggle_initial() -> bool:
	return _motor_on


func set_toggled(on: bool) -> void:
	_motor_on = on
	if _driver_joint != null:
		_driver_joint.motor_enabled = on
		_driver_joint.wake_bodies()


func is_toggled() -> bool:
	return _motor_on


func get_door() -> Box3DBody:
	return _door


func get_follower() -> Box3DBody:
	return _follower


func _add_cylinder(p_body: Box3DBody, p_name: String, p_radius: float, p_height: float,
		p_sides: int, p_transform: Transform3D, p_material: Material) -> void:
	var shape := Box3DCollisionShape.new()
	shape.name = p_name
	shape.shape_type = Box3DCollisionShape.CYLINDER
	shape.capsule_radius = p_radius
	shape.capsule_height = p_height
	shape.sides = p_sides
	shape.friction = 0.1
	shape.density = DENSITY
	shape.transform = p_transform
	p_body.add_child(shape)

	var visual := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = p_radius
	cm.bottom_radius = p_radius
	cm.height = p_height
	cm.radial_segments = p_sides
	visual.mesh = cm
	visual.material_override = p_material
	visual.transform = p_transform
	p_body.add_child(visual)


func _tooth_mesh() -> ArrayMesh:
	# The same tapered block the collider is, in the tooth's own frame.
	var hx := TOOTH_HALF_WIDTH
	var hz := GEAR_HALF_DEPTH
	var base_half := TOOTH_HALF_HEIGHT
	var tip_half := TOOTH_HALF_HEIGHT - TOOTH_RADIUS
	var p := PackedVector3Array([
		Vector3(-hx, -base_half, -hz), Vector3(-hx, base_half, -hz),
		Vector3(-hx, base_half, hz), Vector3(-hx, -base_half, hz),
		Vector3(hx, -tip_half, -hz), Vector3(hx, tip_half, -hz),
		Vector3(hx, tip_half, hz), Vector3(hx, -tip_half, hz),
	])
	# Each quad is wound Box3D's way: counter-clockwise by the right-hand rule,
	# so the face normal points OUT of the block. _surface_from reverses that
	# for Godot. Handing these straight to SurfaceTool (which is what this used
	# to do) drew every tooth inside out -- 64 of them, all lit from behind.
	var faces := [
		[0, 3, 2, 1],  # -x base
		[4, 5, 6, 7],  # +x tip
		[0, 1, 5, 4],  # -z
		[3, 7, 6, 2],  # +z
		[1, 2, 6, 5],  # +y
		[0, 4, 7, 3],  # -y
	]
	var idx := PackedInt32Array()
	for f in faces:
		idx.append_array([f[0], f[1], f[2], f[0], f[2], f[3]])
	return _surface_from(p, idx)


## b3CreateRock's 10-point Fibonacci lattice (src/hull.c:1859-1892), turned
## into a closed convex mesh: the HULL shape path hulls the mesh's vertices, so
## the collider is exactly the hull upstream builds, and the same mesh draws it.
func _rock_mesh() -> ArrayMesh:
	var points := PackedVector3Array()
	var phi := (1.0 + sqrt(5.0)) / 2.0
	var theta := TAU / phi
	for i in 10:
		var z := 1.0 - (2.0 * i + 1.0) / 10.0
		var r_xy := sqrt(1.0 - z * z)
		points.append(Vector3(
			ROCK_RADIUS * r_xy * cos(i * theta),
			ROCK_RADIUS * r_xy * sin(i * theta),
			ROCK_RADIUS * z))

	# Brute-force convex hull over ten points: a triple is a face when every
	# other point is on one side of its plane. Faces come out wound Box3D's way
	# (right-hand normal pointing out of the hull); _surface_from reverses them
	# for Godot.
	var idx := PackedInt32Array()
	var count := points.size()
	for a in count:
		for b in range(a + 1, count):
			for c in range(b + 1, count):
				var normal := (points[b] - points[a]).cross(points[c] - points[a])
				if normal.length_squared() < 1e-12:
					continue
				normal = normal.normalized()
				var d := normal.dot(points[a])
				var positive := 0
				var negative := 0
				for k in count:
					if k == a or k == b or k == c:
						continue
					var side := normal.dot(points[k]) - d
					if side > 1e-6:
						positive += 1
					elif side < -1e-6:
						negative += 1
				if positive > 0 and negative > 0:
					continue
				# Wind the face so its normal points away from the interior.
				if positive > 0:
					idx.append_array([a, c, b])
				else:
					idx.append_array([a, b, c])
	return _surface_from(points, idx)


func _random_quat() -> Quaternion:
	return Quaternion(
		Vector3(_rng.randf_range(-1.0, 1.0), _rng.randf_range(-1.0, 1.0),
			_rng.randf_range(-1.0, 1.0)).normalized(),
		_rng.randf_range(-PI, PI))


## Box3D's mesh winding is the opposite of Godot's, and reversing it is
## Box3DGeometry.make_array_mesh's job: the walls then face the same way the
## collision normals do, into the basin, and the camera sees past the near ones.
func _surface_from(p_verts: PackedVector3Array, p_idx: PackedInt32Array) -> ArrayMesh:
	return Box3DGeometry.make_array_mesh({"vertices": p_verts, "indices": p_idx})


func _add_box_visual(p_body: Box3DBody, p_size: Vector3, p_material: Material) -> void:
	var visual := MeshInstance3D.new()
	visual.name = "Visual"
	var bm := BoxMesh.new()
	bm.size = p_size
	visual.mesh = bm
	visual.material_override = p_material
	p_body.add_child(visual)
