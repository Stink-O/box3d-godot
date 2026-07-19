extends Node3D

## Headless correctness harness for the Box3D binding. Not a visual demo — run
## it with:  godot --headless --path . res://tests/test_features.tscn -- --selftest
## Each feature the fork gains should add an assertion here.

var _all_ok := true
var _sensor_hit := false
var _contact_entered: Node = null
var _contact_exited := false


func _ready() -> void:
	await _test_collision_filter()
	await _test_sensor()
	await _test_contact_events()
	await _test_distance_joint()
	await _test_shapes()
	await _test_hull()
	await _test_mesh()
	await _test_ccd()
	await _test_motion_locks()
	await _test_character()
	await _test_queries()
	await _test_ball_limits()
	await _test_wheel_joint()
	await _test_debug_draw()
	await _test_debug_draw_compound()
	await _test_compound()
	await _test_motor()
	await _test_worker_count()
	await _test_teleport()
	await _test_mesh_collider()
	await _test_auto_visual()
	await _test_solver_tuning()
	await _test_async_step()
	await _test_contact_recycling()
	await _test_sync_node_transform_off()
	await _test_compound_cylinder()
	print("[test] ALL -> ", "PASS" if _all_ok else "FAIL")
	get_tree().quit(0 if _all_ok else 1)


func _check(name: String, ok: bool) -> void:
	if not ok:
		_all_ok = false
	print("[test] %s -> %s" % [name, "PASS" if ok else "FAIL"])


func _make_body(world: Box3DWorld, pos: Vector3, layer: int, mask: int) -> Box3DBody:
	var b := Box3DBody.new()
	b.collision_layer = layer
	b.collision_mask = mask
	b.position = pos
	world.add_child(b)
	return b


func _test_collision_filter() -> void:
	var world := Box3DWorld.new()
	add_child(world)

	var floor := Box3DBody.new()
	floor.body_type = Box3DBody.STATIC
	floor.box_size = Vector3(20, 1, 20)
	floor.position = Vector3(0, -0.5, 0)
	floor.collision_layer = 1
	world.add_child(floor)

	# Matching body: mask includes the floor's layer 1 -> should land on it.
	var matching := _make_body(world, Vector3(-2, 3, 0), 2, 1)
	# Non-matching body: mask is layer 4 only -> ignores the floor, falls through.
	var passing := _make_body(world, Vector3(2, 3, 0), 4, 4)

	for i in range(90):
		await get_tree().physics_frame

	_check("layer/mask: matching body rests on floor", matching.position.y > 0.0)
	_check("layer/mask: non-matching body falls through", passing.position.y < -1.0)

	# Masked raycast down through the matching body: mask=1 should skip the
	# layer-2 body and hit the floor.
	var hit := world.raycast(Vector3(-2, 5, 0), Vector3(-2, -5, 0), 1)
	_check("raycast mask skips wrong layer, hits floor",
		hit.get("hit", false) and hit.get("collider") == floor)

	world.free()


func _on_sensor(_visitor: Box3DBody) -> void:
	_sensor_hit = true


func _test_sensor() -> void:
	var world := Box3DWorld.new()
	add_child(world)

	# A static trigger zone: no collision response, just reports overlaps.
	var sensor := Box3DBody.new()
	sensor.body_type = Box3DBody.STATIC
	sensor.is_sensor = true
	sensor.box_size = Vector3(4, 4, 4)
	sensor.position = Vector3(0, 2, 0)
	sensor.area_entered.connect(_on_sensor)
	world.add_child(sensor)

	# A body dropped from above: falls straight through the sensor.
	var faller := Box3DBody.new()
	faller.position = Vector3(0, 8, 0)
	world.add_child(faller)

	for i in range(120):
		await get_tree().physics_frame

	_check("sensor fires area_entered", _sensor_hit)
	_check("body passes through sensor (no collision)", faller.position.y < -2.0)

	world.free()


func _on_contact_entered(other: Box3DBody) -> void:
	_contact_entered = other


func _on_contact_exited(_other: Box3DBody) -> void:
	_contact_exited = true


func _test_contact_events() -> void:
	var world := Box3DWorld.new()
	add_child(world)

	var floor := Box3DBody.new()
	floor.body_type = Box3DBody.STATIC
	floor.box_size = Vector3(20, 1, 20)
	floor.position = Vector3(0, -0.5, 0)
	world.add_child(floor)

	# A monitored box dropped onto the floor: body_entered must fire with the
	# floor as the other body (the non-sensor signal path, unlike _test_sensor).
	var box := Box3DBody.new()
	box.contact_monitor = true
	box.position = Vector3(0, 2, 0)
	box.body_entered.connect(_on_contact_entered)
	box.body_exited.connect(_on_contact_exited)
	world.add_child(box)

	for i in range(90):
		await get_tree().physics_frame
	_check("contact_monitor: body_entered fires with the touched body",
		_contact_entered == floor)

	# Yank it off the floor: losing the contact must fire body_exited.
	box.teleport(Transform3D(Basis(), Vector3(0, 6, 0)))
	for i in range(30):
		await get_tree().physics_frame
	_check("contact_monitor: body_exited fires when contact breaks", _contact_exited)

	world.free()


func _test_distance_joint() -> void:
	var world := Box3DWorld.new()
	add_child(world)

	var bob := Box3DBody.new()
	bob.name = "Bob"
	bob.shape_type = Box3DBody.SPHERE
	bob.sphere_radius = 0.3
	bob.position = Vector3(0, 3, 0)
	world.add_child(bob)

	# Rigid rod (spring disabled, the Newton's Cradle configuration) anchored to
	# the world at (0, 5, 0), length 2 = the initial anchor->body separation.
	var joint := Box3DDistanceJoint.new()
	joint.position = Vector3(0, 5, 0)
	joint.length = 2.0
	world.add_child(joint)
	joint.body_a = NodePath("../Bob")

	# Two frames: body created, then the deferred joint.
	await get_tree().physics_frame
	await get_tree().physics_frame
	bob.apply_central_impulse(Vector3(1.5, 0, 0))  # set it swinging
	var max_err := 0.0
	for i in range(90):
		await get_tree().physics_frame
		max_err = maxf(max_err, absf(bob.position.distance_to(Vector3(0, 5, 0)) - 2.0))
	_check("distance joint holds a swinging body at its length (max err %.3f)" % max_err,
		max_err < 0.1)

	world.free()


func _test_shapes() -> void:
	var world := Box3DWorld.new()
	add_child(world)

	var floor := Box3DBody.new()
	floor.body_type = Box3DBody.STATIC
	floor.box_size = Vector3(20, 1, 20)
	floor.position = Vector3(0, -0.5, 0)
	world.add_child(floor)

	var cyl := Box3DBody.new()
	cyl.shape_type = Box3DBody.CYLINDER
	cyl.capsule_radius = 0.5
	cyl.capsule_height = 1.0
	cyl.position = Vector3(-2, 4, 0)
	world.add_child(cyl)

	var cone := Box3DBody.new()
	cone.shape_type = Box3DBody.CONE
	cone.capsule_radius = 0.6
	cone.capsule_height = 1.2
	cone.position = Vector3(2, 4, 0)
	world.add_child(cone)

	for i in range(120):
		await get_tree().physics_frame

	# Centered on the origin, so a resting body sits ~half-height above the floor.
	_check("cylinder collides and rests centered on floor", cyl.position.y > 0.2 and cyl.position.y < 2.0)
	_check("cone collides and rests centered on floor", cone.position.y > 0.2 and cone.position.y < 2.0)

	world.free()


func _test_hull() -> void:
	var world := Box3DWorld.new()
	add_child(world)

	var floor := Box3DBody.new()
	floor.body_type = Box3DBody.STATIC
	floor.box_size = Vector3(20, 1, 20)
	floor.position = Vector3(0, -0.5, 0)
	world.add_child(floor)

	# Convex hull built from a box mesh -> a unit box hull, rests at ~0.5.
	var hull := Box3DBody.new()
	hull.shape_type = Box3DBody.HULL
	var box_mesh := BoxMesh.new()
	box_mesh.size = Vector3(1, 1, 1)
	hull.collision_mesh = box_mesh
	hull.position = Vector3(0, 4, 0)
	world.add_child(hull)

	for i in range(120):
		await get_tree().physics_frame

	_check("convex hull (from mesh) collides and rests on floor",
		hull.position.y > 0.2 and hull.position.y < 2.0)

	world.free()


func _test_mesh() -> void:
	var world := Box3DWorld.new()
	add_child(world)

	# A static triangle-mesh floor built from a box mesh (top surface at y=0).
	var mesh_floor := Box3DBody.new()
	mesh_floor.body_type = Box3DBody.STATIC
	mesh_floor.shape_type = Box3DBody.MESH
	var bm := BoxMesh.new()
	bm.size = Vector3(20, 2, 20)
	mesh_floor.collision_mesh = bm
	mesh_floor.position = Vector3(0, -1, 0)
	world.add_child(mesh_floor)

	var ball := Box3DBody.new()
	ball.shape_type = Box3DBody.SPHERE
	ball.sphere_radius = 0.5
	ball.position = Vector3(0, 5, 0)
	world.add_child(ball)

	for i in range(120):
		await get_tree().physics_frame

	_check("triangle-mesh floor stops a falling body", ball.position.y > 0.2 and ball.position.y < 2.0)

	world.free()


func _ccd_run(ccd: bool) -> float:
	var world := Box3DWorld.new()
	world.gravity = Vector3.ZERO
	world.continuous_collision = ccd
	world.max_linear_speed = 500.0
	add_child(world)

	var wall := Box3DBody.new()
	wall.body_type = Box3DBody.STATIC
	wall.box_size = Vector3(4, 4, 0.05)
	wall.position = Vector3(0, 0, 0)
	world.add_child(wall)

	var bullet := Box3DBody.new()
	bullet.continuous = true
	bullet.shape_type = Box3DBody.SPHERE
	bullet.sphere_radius = 0.2
	bullet.position = Vector3(-6, 0, 0)
	world.add_child(bullet)

	await get_tree().physics_frame
	bullet.set_linear_velocity(Vector3(300, 0, 0)) # very fast, toward the wall
	for i in range(20):
		await get_tree().physics_frame

	var x: float = bullet.position.x
	world.free()
	return x


func _test_ccd() -> void:
	var stopped_x := await _ccd_run(true)
	var tunneled_x := await _ccd_run(false)
	_check("continuous on: fast body stopped by thin wall", stopped_x < 0.5)
	_check("continuous off: fast body tunnels through wall", tunneled_x > 1.0)


func _test_motion_locks() -> void:
	var world := Box3DWorld.new()
	add_child(world)

	# All linear axes locked -> gravity can't move it.
	var pinned := Box3DBody.new()
	pinned.lock_linear_x = true
	pinned.lock_linear_y = true
	pinned.lock_linear_z = true
	pinned.position = Vector3(0, 5, 0)
	world.add_child(pinned)

	# X and Z locked -> a sideways shove can't move it off the Y axis.
	var slider := Box3DBody.new()
	slider.lock_linear_x = true
	slider.lock_linear_z = true
	slider.position = Vector3(3, 5, 0)
	world.add_child(slider)

	await get_tree().physics_frame
	slider.apply_central_impulse(Vector3(50, 0, 20))
	for i in range(60):
		await get_tree().physics_frame

	_check("all-linear-locked body ignores gravity", pinned.position.distance_to(Vector3(0, 5, 0)) < 0.05)
	_check("XZ-locked body stays on its Y axis under a sideways shove",
		absf(slider.position.x - 3.0) < 0.05 and absf(slider.position.z) < 0.05)

	world.free()


func _test_character() -> void:
	var world := Box3DWorld.new()
	add_child(world)

	var floor := Box3DBody.new()
	floor.body_type = Box3DBody.STATIC
	floor.box_size = Vector3(20, 1, 20)
	floor.position = Vector3(0, -0.5, 0) # top at y=0
	world.add_child(floor)

	var wall := Box3DBody.new()
	wall.body_type = Box3DBody.STATIC
	wall.box_size = Vector3(1, 4, 20)
	wall.position = Vector3(3, 1, 0) # left face at x=2.5
	world.add_child(wall)

	var character := Box3DCharacterBody.new()
	character.radius = 0.4
	character.height = 1.8
	character.position = Vector3(0, 2, 0)
	world.add_child(character)

	await get_tree().physics_frame
	# Walk down-and-right for a couple of seconds.
	for i in range(120):
		character.move_and_slide(Vector3(3, -10, 0), 1.0 / 60.0)
		await get_tree().physics_frame

	# Capsule half-height 0.9, so resting on the floor puts the origin near y=0.9.
	_check("character rests on the floor (doesn't sink)",
		character.position.y > 0.5 and character.position.y < 1.4)
	# Radius 0.4, wall left face at x=2.5, so it should stop near x=2.1.
	_check("character is stopped by the wall (slides, no tunnel)", character.position.x < 2.3)

	world.free()


func _test_queries() -> void:
	var world := Box3DWorld.new()
	world.gravity = Vector3.ZERO
	add_child(world)

	var near := Box3DBody.new()
	near.body_type = Box3DBody.STATIC
	near.box_size = Vector3.ONE
	near.position = Vector3(0, 0, 0)
	world.add_child(near)

	var far := Box3DBody.new()
	far.body_type = Box3DBody.STATIC
	far.box_size = Vector3.ONE
	far.position = Vector3(10, 0, 0)
	world.add_child(far)

	await get_tree().physics_frame

	var hits := world.overlap_sphere(Vector3(0, 0, 0), 2.0)
	_check("overlap_sphere finds the nearby body only", hits.has(near) and not hits.has(far))

	var cast := world.shape_cast_sphere(Vector3(-5, 0, 0), Vector3(5, 0, 0), 0.3)
	_check("shape_cast_sphere hits a body", cast.get("hit", false))

	# A dynamic sphere above an explosion should be blown upward.
	var proj := Box3DBody.new()
	proj.shape_type = Box3DBody.SPHERE
	proj.sphere_radius = 0.4
	proj.position = Vector3(0, 3, 0)
	world.add_child(proj)
	await get_tree().physics_frame

	world.explode(Vector3(0, 1.5, 0), 3.0, 50.0)
	for i in range(20):
		await get_tree().physics_frame

	_check("explode pushes a nearby dynamic body outward", proj.position.y > 3.3)

	world.free()


func _twist_run(limit: bool) -> float:
	var world := Box3DWorld.new()
	world.gravity = Vector3.ZERO
	add_child(world)

	var spinner := Box3DBody.new()
	spinner.name = "Spinner"
	spinner.box_size = Vector3(1, 1, 0.2)
	spinner.position = Vector3(0, 5, 0)
	world.add_child(spinner)

	var joint := Box3DBallJoint.new()
	joint.position = Vector3(0, 5, 0) # pin the spinner's center to the world here
	world.add_child(joint)
	joint.body_a = NodePath("../Spinner")
	if limit:
		joint.twist_limit_enabled = true
		joint.twist_lower = -0.2
		joint.twist_upper = 0.2

	# Two frames: bodies created, then the deferred joint.
	await get_tree().physics_frame
	await get_tree().physics_frame
	spinner.set_angular_velocity(Vector3(0, 0, 4)) # spin about Z (the twist axis)
	for i in range(20):
		await get_tree().physics_frame

	var rot: float = spinner.rotation.z
	world.free()
	return rot


func _test_ball_limits() -> void:
	var free_rot := await _twist_run(false)
	var limited_rot := await _twist_run(true)
	_check("ball twist limit constrains rotation (free=%.2f limited=%.2f)" % [free_rot, limited_rot],
		absf(limited_rot) < 0.6 and absf(free_rot) > 0.8)


func _test_wheel_joint() -> void:
	var world := Box3DWorld.new()
	add_child(world)

	var floor := Box3DBody.new()
	floor.body_type = Box3DBody.STATIC
	floor.box_size = Vector3(60, 1, 20)
	floor.position = Vector3(20, -0.5, 0)
	world.add_child(floor)

	# A minimal wheel-joint vehicle (the Car sample's layout, from upstream's
	# Driving sample): box chassis, four sphere wheels, suspension springs,
	# steering springs up front, spin motors in the rear, and a soft parallel
	# joint holding the chassis upright.
	var chassis := Box3DBody.new()
	chassis.name = "Chassis"
	chassis.box_size = Vector3(4, 1, 2)
	chassis.density = 0.5
	chassis.position = Vector3(0, 1.0, 0)
	world.add_child(chassis)

	var rear: Array = []
	var wheel_index := 0
	for w in [[1.5, 0.8, true], [1.5, -0.8, true], [-1.5, 0.8, false], [-1.5, -0.8, false]]:
		var wheel := Box3DBody.new()
		wheel.name = "Wheel%d" % wheel_index
		wheel_index += 1
		wheel.shape_type = Box3DBody.SPHERE
		wheel.sphere_radius = 0.4
		wheel.density = 2.0
		wheel.friction = 3.0
		wheel.allow_fast_rotation = true
		wheel.position = Vector3(w[0], 0.5, w[1])
		world.add_child(wheel)

		var joint := Box3DWheelJoint.new()
		joint.position = wheel.position  # identity basis: Y = suspension, Z = axle
		joint.suspension_hertz = 4.0
		joint.suspension_damping = 0.7
		joint.suspension_limit_enabled = true
		joint.lower_suspension_limit = -0.2
		joint.upper_suspension_limit = 0.2
		if w[2]:
			joint.steering_enabled = true
			joint.steering_hertz = 10.0
			joint.steering_damping = 0.7
			joint.max_steering_torque = 5.0
		else:
			joint.spin_motor_enabled = true
			joint.max_spin_torque = 5.0
			rear.append(joint)
		world.add_child(joint)
		joint.body_a = NodePath("../Chassis")
		joint.body_b = NodePath("../" + wheel.name)

	var upright := Box3DParallelJoint.new()
	# Local Z (the aligned axis) pointed up: columns X, -Z... world up as Z.
	upright.transform = Transform3D(
		Basis(Vector3(1, 0, 0), Vector3(0, 0, -1), Vector3(0, 1, 0)), Vector3(0, 1.0, 0))
	upright.spring_hertz = 0.5
	upright.spring_damping = 1.0
	world.add_child(upright)
	upright.body_a = NodePath("../Chassis")

	# Two frames: bodies created, then the deferred joints; settle briefly.
	await get_tree().physics_frame
	await get_tree().physics_frame
	for i in range(30):
		await get_tree().physics_frame

	# Floor the rear spin motors and let it drive (negative spin about the +Z
	# axle rolls the vehicle toward +X).
	for joint in rear:
		joint.spin_motor_speed = -30.0
	for i in range(240):
		await get_tree().physics_frame

	var up: Vector3 = chassis.global_transform.basis.y
	_check("wheel joint: rear spin motors drive the vehicle forward (x %.1f)" % chassis.position.x,
		chassis.position.x > 2.0)
	_check("wheel joint: suspension carries the chassis (y %.2f)" % chassis.position.y,
		chassis.position.y > 0.5 and chassis.position.y < 1.4)
	_check("wheel joint: get_spin_speed reads the live spin (%.1f rad/s)" % rear[0].get_spin_speed(),
		absf(rear[0].get_spin_speed()) > 5.0)
	_check("parallel joint keeps the chassis upright (up.y %.2f)" % up.y, up.y > 0.9)

	world.free()


func _test_debug_draw() -> void:
	var world := Box3DWorld.new()
	world.debug_draw = true
	add_child(world)

	var body := Box3DBody.new()
	body.body_type = Box3DBody.STATIC
	body.box_size = Vector3.ONE
	body.position = Vector3(0, 2, 0)
	world.add_child(body)

	for i in range(5):
		await get_tree().physics_frame

	# Solid state-colored shells live in per-primitive MultiMeshes; the box
	# body must occupy an instance in the box shell (node suffix 0 = box).
	var mi = world.get_node_or_null("Box3DDebugDraw0")
	var ok: bool = mi != null and mi.multimesh != null and mi.multimesh.visible_instance_count > 0
	_check("debug draw shells the body (box instance present)", ok)

	world.free()


func _test_debug_draw_compound() -> void:
	var world := Box3DWorld.new()
	world.debug_draw = true
	add_child(world)

	# A compound body: its only real collider is a child sphere out at x=3. The
	# debug shells must cover THAT (not the body's own ignored shape_type at
	# the origin), so the sphere shell instance has to sit out at the child.
	var body := Box3DBody.new()
	body.body_type = Box3DBody.STATIC
	var cs := Box3DCollisionShape.new()
	cs.shape_type = Box3DCollisionShape.SPHERE
	cs.sphere_radius = 0.5
	cs.position = Vector3(3, 0, 0)
	body.add_child(cs)
	world.add_child(body)

	for i in range(5):
		await get_tree().physics_frame

	# The headless dummy renderer discards MultiMesh instance data (transforms
	# read back as identity), so assert prim selection via counts instead: the
	# child sphere must be shelled, the body's own ignored box type must not.
	var sphere_mm = world.get_node_or_null("Box3DDebugDraw1") # suffix 1 = sphere
	var box_mm = world.get_node_or_null("Box3DDebugDraw0") # suffix 0 = box
	var sphere_n: int = sphere_mm.multimesh.visible_instance_count if sphere_mm != null and sphere_mm.multimesh != null else -1
	var box_n: int = box_mm.multimesh.visible_instance_count if box_mm != null and box_mm.multimesh != null else -1
	_check("debug draw shells a compound body's child shape, not its own type (sphere %d, box %d)" % [sphere_n, box_n],
		sphere_n == 1 and box_n == 0)

	world.free()


func _test_compound() -> void:
	var world := Box3DWorld.new()
	add_child(world)

	# A static body with two box shapes offset to x=-1 and x=+1 (a gap between).
	var body := Box3DBody.new()
	body.body_type = Box3DBody.STATIC
	body.position = Vector3.ZERO
	for x in [-1.0, 1.0]:
		var cs := Box3DCollisionShape.new()
		cs.shape_type = Box3DCollisionShape.BOX
		cs.box_size = Vector3.ONE
		cs.position = Vector3(x, 0, 0)
		body.add_child(cs)
	world.add_child(body)

	await get_tree().physics_frame

	var hit_box := world.raycast(Vector3(1, 3, 0), Vector3(1, -3, 0))
	var hit_gap := world.raycast(Vector3(0, 3, 0), Vector3(0, -3, 0))
	_check("compound body: ray hits an offset child shape", hit_box.get("hit", false))
	_check("compound body: ray misses the gap between shapes", not hit_gap.get("hit", false))

	world.free()


func _test_motor() -> void:
	var world := Box3DWorld.new()
	world.gravity = Vector3.ZERO
	add_child(world)

	var body := Box3DBody.new()
	body.name = "Driven"
	body.box_size = Vector3.ONE
	body.position = Vector3(0, 0, 0)
	world.add_child(body)

	var joint := Box3DMotorJoint.new()
	joint.position = Vector3(0, 0, 0)
	joint.linear_velocity = Vector3(2, 0, 0)
	joint.max_force = 5000.0
	world.add_child(joint)
	joint.body_a = NodePath("../Driven")

	await get_tree().physics_frame
	await get_tree().physics_frame
	for i in range(30):
		await get_tree().physics_frame

	_check("motor joint drives body along its target velocity", absf(body.position.x) > 0.5)

	world.free()


func _test_worker_count() -> void:
	var world := Box3DWorld.new()
	world.worker_count = 4 # Box3D's internal multithreaded solver
	add_child(world)

	var floor := Box3DBody.new()
	floor.body_type = Box3DBody.STATIC
	floor.box_size = Vector3(30, 1, 30)
	floor.position = Vector3(0, -0.5, 0)
	world.add_child(floor)

	var rng := RandomNumberGenerator.new()
	rng.seed = 99
	var bodies: Array = []
	for i in range(30):
		var b := Box3DBody.new()
		b.box_size = Vector3.ONE
		b.position = Vector3(rng.randf_range(-3, 3), 3.0 + i * 0.6, rng.randf_range(-3, 3))
		world.add_child(b)
		bodies.append(b)

	for i in range(150):
		await get_tree().physics_frame

	# With correct multithreaded stepping every body has settled above the
	# floor — none fell through or went NaN.
	var all_ok := world.worker_count == 4
	for b in bodies:
		var y: float = b.position.y
		if is_nan(y) or y < -0.5 or y > 25.0:
			all_ok = false
	_check("multithreaded stepping (worker_count=4) simulates correctly", all_ok)

	world.free()


func _test_teleport() -> void:
	var world := Box3DWorld.new()
	add_child(world)

	var floor := Box3DBody.new()
	floor.body_type = Box3DBody.STATIC
	floor.box_size = Vector3(20, 1, 20)
	floor.position = Vector3(0, -0.5, 0)
	world.add_child(floor)

	var body := Box3DBody.new()
	body.box_size = Vector3.ONE
	body.position = Vector3(0, 5, 0)
	world.add_child(body)

	# Let it fall and build up downward velocity.
	for i in range(30):
		await get_tree().physics_frame
	var fell: bool = body.position.y < 4.0

	# Teleport it back up; velocity should be cleared so it starts from rest.
	body.teleport(Transform3D(Basis(), Vector3(3, 8, 0)))
	await get_tree().physics_frame
	var landed_at_target: bool = body.position.distance_to(Vector3(3, 8, 0)) < 0.5
	var slow_after: bool = body.get_linear_velocity().length() < 2.0
	_check("teleport repositions the body and clears momentum",
		fell and landed_at_target and slow_after)

	world.free()


func _mesh_inst(mesh: Mesh) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	return mi


func _test_mesh_collider() -> void:
	var world := Box3DWorld.new()
	add_child(world)

	# FIT_MESH: a static floor whose box collider is auto-sized from a child
	# MeshInstance3D's mesh bounds (no box_size set).
	var floor := Box3DBody.new()
	floor.body_type = Box3DBody.STATIC
	floor.shape_type = Box3DBody.FIT_MESH
	floor.position = Vector3(0, -0.5, 0)
	var fm := BoxMesh.new()
	fm.size = Vector3(10, 1, 10)
	floor.add_child(_mesh_inst(fm))
	world.add_child(floor)

	var box := Box3DBody.new()
	box.box_size = Vector3.ONE
	box.position = Vector3(0, 3, 0)
	box.add_child(_mesh_inst(BoxMesh.new()))
	world.add_child(box)

	# HULL sourced from a child MeshInstance3D (no collision_mesh assigned).
	var hull := Box3DBody.new()
	hull.shape_type = Box3DBody.HULL
	hull.position = Vector3(3, 3, 0)
	var hm := BoxMesh.new()
	hm.size = Vector3(2, 2, 2)
	hull.add_child(_mesh_inst(hm))
	world.add_child(hull)

	for i in range(120):
		await get_tree().physics_frame

	_check("FIT_MESH floor sizes its collider from the child mesh",
		absf(box.position.y - 0.5) < 0.2)
	_check("HULL collider sourced from a child MeshInstance3D",
		absf(hull.position.y - 1.0) < 0.25)

	world.free()


func _test_auto_visual() -> void:
	var world := Box3DWorld.new()
	add_child(world)

	# auto_visual=true, no MeshInstance3D child -> the body generates its own,
	# sized from the same box_size that drives the collider.
	var auto_box := Box3DBody.new()
	auto_box.auto_visual = true
	auto_box.box_size = Vector3(2, 3, 4)
	world.add_child(auto_box)

	# Same idea for a sphere, to check the shape->mesh-type mapping.
	var auto_sphere := Box3DBody.new()
	auto_sphere.auto_visual = true
	auto_sphere.shape_type = Box3DBody.SPHERE
	auto_sphere.sphere_radius = 1.5
	world.add_child(auto_sphere)

	# auto_visual=true, but a real MeshInstance3D child is present -> defers to
	# it and generates nothing of its own.
	var manual := Box3DBody.new()
	manual.auto_visual = true
	manual.add_child(_mesh_inst(BoxMesh.new()))
	world.add_child(manual)

	# auto_visual=false (the default) -> no mesh is generated; backward compat.
	var off := Box3DBody.new()
	off.box_size = Vector3.ONE
	world.add_child(off)

	await get_tree().physics_frame

	var auto_mi := auto_box.get_node_or_null("Box3DAutoVisual")
	var box_ok: bool = auto_mi != null and auto_mi.mesh is BoxMesh \
		and (auto_mi.mesh as BoxMesh).size.is_equal_approx(Vector3(2, 3, 4))
	_check("auto_visual generates a BoxMesh matching box_size", box_ok)

	var sphere_mi := auto_sphere.get_node_or_null("Box3DAutoVisual")
	var sphere_ok: bool = sphere_mi != null and sphere_mi.mesh is SphereMesh \
		and is_equal_approx((sphere_mi.mesh as SphereMesh).radius, 1.5)
	_check("auto_visual generates a SphereMesh matching sphere_radius", sphere_ok)

	_check("auto_visual defers to an existing MeshInstance3D child",
		manual.get_node_or_null("Box3DAutoVisual") == null)
	_check("auto_visual off (default) generates nothing",
		off.get_node_or_null("Box3DAutoVisual") == null)

	world.free()


func _test_solver_tuning() -> void:
	var world := Box3DWorld.new()
	world.contact_hertz = 45.0
	world.contact_damping = 4.0
	world.enable_sleep = false
	world.enable_warm_starting = true
	add_child(world)

	_check("contact_hertz / contact_damping / enable_sleep round-trip",
		is_equal_approx(world.contact_hertz, 45.0) and is_equal_approx(world.contact_damping, 4.0)
		and world.enable_sleep == false and world.enable_warm_starting == true)

	var floor := Box3DBody.new()
	floor.body_type = Box3DBody.STATIC
	floor.box_size = Vector3(20, 1, 20)
	floor.position = Vector3(0, -0.5, 0)
	world.add_child(floor)

	var box := Box3DBody.new()
	box.box_size = Vector3.ONE
	box.position = Vector3(0, 3, 0)
	world.add_child(box)

	for i in range(90):
		await get_tree().physics_frame

	_check("custom solver tuning still simulates correctly (body rests on floor)",
		box.position.y > 0.2 and box.position.y < 2.0)

	world.free()


func _test_async_step() -> void:
	var world := Box3DWorld.new()
	world.async_step = true
	world.worker_count = 4
	add_child(world)

	var floor := Box3DBody.new()
	floor.body_type = Box3DBody.STATIC
	floor.box_size = Vector3(30, 1, 30)
	floor.position = Vector3(0, -0.5, 0)
	world.add_child(floor)

	var bodies: Array = []
	for i in range(20):
		var b := Box3DBody.new()
		b.box_size = Vector3.ONE
		b.position = Vector3((i % 5) * 1.5 - 3.0, 2.0 + (i / 5) * 1.5, 0)
		world.add_child(b)
		bodies.append(b)

	# Queries and impulses every frame race the background step unless the
	# join guards work; NaN/fall-through would surface a torn world state.
	var ray_hits := 0
	for i in range(150):
		await get_tree().physics_frame
		var hit := world.raycast(Vector3(0, 5, 0), Vector3(0, -5, 0))
		if hit.get("hit", false):
			ray_hits += 1
		if i == 30:
			bodies[0].apply_central_impulse(Vector3(0, 2, 0))

	var all_ok := world.async_step
	for b in bodies:
		var y: float = b.position.y
		if is_nan(y) or y < -0.5 or y > 25.0:
			all_ok = false
	_check("async_step: background stepping settles a stack (rays %d/150)" % ray_hits,
		all_ok and ray_hits > 100)

	# Toggling async off mid-run absorbs the in-flight step and keeps going.
	world.async_step = false
	var before: float = bodies[1].position.y
	for i in range(30):
		await get_tree().physics_frame
	var after: float = bodies[1].position.y
	_check("async_step: toggling off mid-run stays consistent",
		not world.async_step and not is_nan(after) and absf(after - before) < 5.0)

	world.free()


func _test_contact_recycling() -> void:
	var world := Box3DWorld.new()
	add_child(world)

	var floor := Box3DBody.new()
	floor.body_type = Box3DBody.STATIC
	floor.box_size = Vector3(20, 1, 20)
	floor.position = Vector3(0, -0.5, 0)
	world.add_child(floor)

	# Default mirrors Box3D (recycling on); a live toggle round-trips and the
	# body keeps simulating normally either way.
	var box := Box3DBody.new()
	box.position = Vector3(0, 2, 0)
	world.add_child(box)
	var default_on: bool = box.contact_recycling
	box.contact_recycling = false
	var toggled_off: bool = not box.contact_recycling
	box.contact_recycling = true

	for i in range(90):
		await get_tree().physics_frame

	_check("contact_recycling: default on, live toggle round-trips, body rests",
		default_on and toggled_off and box.contact_recycling
		and box.position.y > 0.2 and box.position.y < 2.0)

	world.free()


func _test_sync_node_transform_off() -> void:
	var world := Box3DWorld.new()
	add_child(world)

	var floor := Box3DBody.new()
	floor.body_type = Box3DBody.STATIC
	floor.box_size = Vector3(20, 1, 20)
	floor.position = Vector3(0, -0.5, 0)
	world.add_child(floor)

	# With node sync off the body still simulates (the solver moves it, world
	# queries see it fall) but the Godot node stays at its spawn pose — the
	# contract Box3DMultiMeshRenderer relies on at 16k bodies.
	var box := Box3DBody.new()
	box.position = Vector3(0, 4, 0)
	box.sync_node_transform = false
	world.add_child(box)

	for i in range(90):
		await get_tree().physics_frame

	var found_at_floor := false
	for hit in world.overlap_sphere(Vector3(0, 0.5, 0), 1.0):
		if hit == box:
			found_at_floor = true
	_check("sync_node_transform off: solver moves body (query hits it at floor), node stays at spawn",
		not box.sync_node_transform and found_at_floor
		and box.position.is_equal_approx(Vector3(0, 4, 0)))

	world.free()


func _test_compound_cylinder() -> void:
	var world := Box3DWorld.new()
	add_child(world)

	var floor := Box3DBody.new()
	floor.body_type = Box3DBody.STATIC
	floor.box_size = Vector3(20, 1, 20)
	floor.position = Vector3(0, -0.5, 0)
	world.add_child(floor)

	# A dynamic body whose only collider is a CYLINDER child shape (the
	# compound path through b3CreateCylinder + b3CreateTransformedHullShape).
	var body := Box3DBody.new()
	body.position = Vector3(0, 3, 0)
	var cs := Box3DCollisionShape.new()
	cs.shape_type = Box3DCollisionShape.CYLINDER
	cs.capsule_radius = 0.5
	cs.capsule_height = 1.0
	cs.sides = 24
	body.add_child(cs)
	world.add_child(body)

	for i in range(120):
		await get_tree().physics_frame

	# Centered on the child origin, so it rests half its height above the floor.
	_check("compound cylinder child collides (rests at y %.2f) and round-trips sides/type" % body.position.y,
		absf(body.position.y - 0.5) < 0.15
		and cs.sides == 24 and cs.shape_type == Box3DCollisionShape.CYLINDER)

	world.free()
