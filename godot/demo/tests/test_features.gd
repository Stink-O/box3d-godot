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
	await _test_point_forces()
	await _test_sleep_controls()
	await _test_body_enabled()
	await _test_live_body_properties()
	await _test_mass_data()
	await _test_body_queries()
	await _test_surface_material_extras()
	await _test_collision_group()
	await _test_wind()
	await _test_shape_handles()
	await _test_filter_joint()
	await _test_contact_query()
	await _test_height_field()
	await _test_mesh_from_data()
	await _test_shape_scale()
	await _test_contact_hit_events()
	await _test_joint_events()
	await _test_world_queries()
	await _test_character_sweep_and_floor()
	await _test_shape_def_extras()
	await _test_space_conversions()
	await _test_shape_geometry()
	await _test_shape_filter_and_events()
	await _test_baked_compound()
	await _test_debug_overlay()
	await _test_world_capacity_and_live_settings()
	await _test_character_soft_collision()
	await _test_live_shape_resize()
	await _test_per_body_queries()
	await _test_live_child_shape_resize()
	await _test_joint_draw_scale()
	await _test_query_categories()
	await _test_live_ball_friction()
	await _test_debug_palette()
	await _test_live_density_and_sensor()
	await _test_shape_rebuild_keeps_body()
	await _test_shape_set_mesh()
	await _test_body_event_enables()
	await _test_body_introspection()
	await _test_static_utility_classes()
	await _test_shape_child_removal()
	await _test_contact_rule_wiring()
	await _test_contact_rules_friction()
	await _test_contact_rules_filter()
	await _test_contact_rules_one_way()
	await _test_contact_handles()
	await _test_proxy_queries()
	await _test_length_units()
	_test_geometry()
	_test_collision()
	await _test_recording_replay()
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


func _test_point_forces() -> void:
	var world := Box3DWorld.new()
	add_child(world)

	# No floor: these are pure velocity-state checks on a free-falling body.
	var body := Box3DBody.new()
	body.box_size = Vector3.ONE
	body.position = Vector3(0, 20, 0)
	world.add_child(body)
	await get_tree().physics_frame

	# An impulse applied one metre off-centre along +X, pointing at +Z, is a
	# torque of r x F = (0, -5, 0): the body spins about -Y.
	body.apply_impulse_at_point(Vector3(0, 0, 5), body.global_position + Vector3(1, 0, 0))
	_check("apply_impulse_at_point off-centre spins the body about -Y",
		body.get_angular_velocity().y < -0.1)

	body.set_angular_velocity(Vector3.ZERO)
	body.apply_angular_impulse(Vector3(0, 2, 0))
	_check("apply_angular_impulse spins the body about +Y",
		body.get_angular_velocity().y > 0.1)

	# A force needs a step to integrate, so push for a few frames.
	body.set_angular_velocity(Vector3.ZERO)
	for i in range(10):
		body.apply_force_at_point(Vector3(0, 0, 50), body.global_position + Vector3(1, 0, 0))
		await get_tree().physics_frame
	_check("apply_force_at_point off-centre accumulates spin",
		body.get_angular_velocity().y < -0.1)

	# Reset the pose so local and world offsets line up, then read the velocity
	# of a point one metre out: omega x r = (0, 2, 0) x (1, 0, 0) = (0, 0, -2).
	body.teleport(Transform3D(Basis(), Vector3(0, 20, 0)))
	body.set_linear_velocity(Vector3.ZERO)
	body.set_angular_velocity(Vector3(0, 2, 0))
	var world_pv: Vector3 = body.get_point_velocity(Vector3(1, 20, 0))
	var local_pv: Vector3 = body.get_local_point_velocity(Vector3(1, 0, 0))
	_check("get_point_velocity / get_local_point_velocity report the rotating point speed",
		world_pv.distance_to(Vector3(0, 0, -2)) < 0.05
		and local_pv.distance_to(Vector3(0, 0, -2)) < 0.05)

	world.free()


func _test_sleep_controls() -> void:
	var world := Box3DWorld.new()
	add_child(world)

	var floor := Box3DBody.new()
	floor.body_type = Box3DBody.STATIC
	floor.box_size = Vector3(20, 1, 20)
	floor.position = Vector3(0, -0.5, 0)
	world.add_child(floor)

	var sleeper := Box3DBody.new()
	sleeper.box_size = Vector3.ONE
	sleeper.position = Vector3(-2, 0.55, 0)
	world.add_child(sleeper)

	# can_sleep off (b3BodyDef.enableSleep) must keep the body simulating even
	# once it has settled.
	var insomniac := Box3DBody.new()
	insomniac.box_size = Vector3.ONE
	insomniac.position = Vector3(2, 0.55, 0)
	insomniac.can_sleep = false
	world.add_child(insomniac)

	for i in range(300):
		await get_tree().physics_frame

	_check("settled body falls asleep; can_sleep off keeps its neighbour awake",
		not sleeper.is_awake() and insomniac.is_awake())

	sleeper.set_awake(true)
	_check("set_awake wakes a sleeping body", sleeper.is_awake())

	sleeper.sleep_threshold = 0.2
	_check("sleep_threshold round-trips", is_equal_approx(sleeper.sleep_threshold, 0.2)
		and sleeper.can_sleep and not insomniac.can_sleep)

	world.free()


func _test_body_enabled() -> void:
	var world := Box3DWorld.new()
	add_child(world)

	# Created disabled (b3BodyDef.isEnabled): removed from the simulation, so
	# gravity never touches it.
	var body := Box3DBody.new()
	body.box_size = Vector3.ONE
	body.position = Vector3(0, 10, 0)
	body.enabled = false
	world.add_child(body)

	for i in range(60):
		await get_tree().physics_frame
	var stayed: bool = body.position.is_equal_approx(Vector3(0, 10, 0))

	body.enabled = true
	for i in range(60):
		await get_tree().physics_frame

	_check("enabled=false freezes the body, re-enabling puts it back in the simulation",
		stayed and body.enabled and body.position.y < 9.0)

	world.free()


func _test_live_body_properties() -> void:
	var world := Box3DWorld.new()
	add_child(world)

	var body := Box3DBody.new()
	body.box_size = Vector3.ONE
	body.position = Vector3(0, 40, 0)
	world.add_child(body)

	for i in range(30):
		await get_tree().physics_frame
	var falling: float = body.get_linear_velocity().y

	# Live gravity_scale: the velocity built up so far must survive the change
	# (a body rebuild would have thrown it away).
	body.gravity_scale = 0.0
	var kept: float = body.get_linear_velocity().y
	for i in range(30):
		await get_tree().physics_frame
	_check("gravity_scale applies live without discarding velocity",
		falling < -1.0 and is_equal_approx(kept, falling)
		and absf(body.get_linear_velocity().y - kept) < 0.5)

	body.set_angular_velocity(Vector3(0, 5, 0))
	body.angular_damping = 8.0
	for i in range(30):
		await get_tree().physics_frame
	_check("angular_damping applies live and slows the spin",
		body.get_angular_velocity().y < 2.0)

	var pose: Vector3 = body.position
	body.body_type = Box3DBody.STATIC
	for i in range(30):
		await get_tree().physics_frame
	var pinned: bool = body.position.is_equal_approx(pose)

	body.body_type = Box3DBody.DYNAMIC
	body.gravity_scale = 1.0
	for i in range(30):
		await get_tree().physics_frame
	_check("body_type switches live to Static in place and back to Dynamic",
		pinned and body.position.y < pose.y - 0.5)

	body.allow_fast_rotation = true
	_check("allow_fast_rotation applies live", body.allow_fast_rotation)

	world.free()


func _test_mass_data() -> void:
	var world := Box3DWorld.new()
	add_child(world)

	var body := Box3DBody.new()
	body.box_size = Vector3.ONE
	body.density = 1.0
	body.position = Vector3(0, 5, 0)
	world.add_child(body)
	await get_tree().physics_frame

	# Unit cube at density 1: mass 1 kg, inertia m*s^2/6 about each axis.
	var inertia: Basis = body.get_inertia_tensor()
	_check("mass / inverse mass / inertia tensor read back from the solver",
		absf(body.get_mass() - 1.0) < 0.01 and absf(body.get_inverse_mass() - 1.0) < 0.01
		and absf(inertia.x.x - 1.0 / 6.0) < 0.01)

	_check("centre of mass reads in both local and world space",
		body.get_local_center_of_mass().length() < 0.01
		and body.get_center_of_mass().distance_to(Vector3(0, 5, 0)) < 0.01)

	# Override: 5 kg, centre of mass shifted to +x, inertia doubled.
	body.set_mass_data(5.0, Vector3(0.25, 0, 0), Basis().scaled(Vector3(2, 2, 2)))
	var data: Dictionary = body.get_mass_data()
	_check("set_mass_data / get_mass_data override the density-derived mass",
		absf(body.get_mass() - 5.0) < 0.01 and absf(float(data["mass"]) - 5.0) < 0.01
		and (data["center"] as Vector3).distance_to(Vector3(0.25, 0, 0)) < 0.01)

	body.apply_mass_from_shapes()
	_check("apply_mass_from_shapes drops the override and recomputes from the shapes",
		absf(body.get_mass() - 1.0) < 0.01
		and body.get_local_center_of_mass().length() < 0.01)

	world.free()


func _test_body_queries() -> void:
	var world := Box3DWorld.new()
	add_child(world)

	var body := Box3DBody.new()
	body.body_type = Box3DBody.STATIC
	body.box_size = Vector3.ONE
	body.position = Vector3(0, 5, 0)
	body.name = "Crate"
	world.add_child(body)
	await get_tree().physics_frame

	var box: AABB = body.get_aabb()
	_check("get_aabb bounds the body's shapes in world space",
		box.position.distance_to(Vector3(-0.5, 4.5, -0.5)) < 0.2
		and box.size.distance_to(Vector3.ONE) < 0.4)

	_check("get_closest_point / get_closest_distance measure to the collider surface",
		body.get_closest_point(Vector3(0, 10, 0)).distance_to(Vector3(0, 5.5, 0)) < 0.05
		and absf(body.get_closest_distance(Vector3(0, 10, 0)) - 4.5) < 0.05)

	# A compound body reports one shape per Box3DCollisionShape child.
	var compound := Box3DBody.new()
	compound.position = Vector3(4, 5, 0)
	for i in range(2):
		var cs := Box3DCollisionShape.new()
		cs.position = Vector3(i, 0, 0)
		compound.add_child(cs)
	world.add_child(compound)
	await get_tree().physics_frame

	_check("get_shape_count / get_joint_count report the body's topology",
		body.get_shape_count() == 1 and compound.get_shape_count() == 2
		and body.get_joint_count() == 0)

	# The node name is fed into b3BodyDef.name at creation.
	var named: bool = body.get_body_name() == "Crate"
	body.set_body_name("Renamed")
	_check("body name round-trips through b3Body_SetName / GetName",
		named and body.get_body_name() == "Renamed")

	world.free()


func _test_surface_material_extras() -> void:
	var world := Box3DWorld.new()
	add_child(world)

	var floor := Box3DBody.new()
	floor.body_type = Box3DBody.STATIC
	floor.box_size = Vector3(60, 1, 20)
	floor.position = Vector3(0, -0.5, 0)
	world.add_child(floor)

	# Rolling resistance only applies to spheres and capsules, so roll two
	# identical spheres and let the resisted one lose ground.
	var free_ball := Box3DBody.new()
	free_ball.shape_type = Box3DBody.SPHERE
	free_ball.position = Vector3(-10, 0.5, -3)
	world.add_child(free_ball)

	var slow_ball := Box3DBody.new()
	slow_ball.shape_type = Box3DBody.SPHERE
	slow_ball.rolling_resistance = 0.5
	slow_ball.position = Vector3(-10, 0.5, 3)
	world.add_child(slow_ball)

	await get_tree().physics_frame
	free_ball.set_linear_velocity(Vector3(8, 0, 0))
	slow_ball.set_linear_velocity(Vector3(8, 0, 0))

	# A conveyor: a static floor patch whose surface drags what rests on it.
	var belt := Box3DBody.new()
	belt.body_type = Box3DBody.STATIC
	belt.box_size = Vector3(10, 1, 4)
	belt.position = Vector3(0, -0.5, 8)
	belt.tangent_velocity = Vector3(3, 0, 0)
	world.add_child(belt)

	var rider := Box3DBody.new()
	rider.box_size = Vector3.ONE
	rider.position = Vector3(0, 0.55, 8)
	world.add_child(rider)

	for i in range(180):
		await get_tree().physics_frame

	_check("rolling_resistance slows a rolling sphere (%.1f m vs %.1f m)"
			% [slow_ball.position.x + 10.0, free_ball.position.x + 10.0],
		slow_ball.position.x < free_ball.position.x - 0.5)

	_check("tangent_velocity drives a conveyor surface (rider moved %.2f m)" % absf(rider.position.x),
		absf(rider.position.x) > 0.3 and is_equal_approx(belt.tangent_velocity.x, 3.0))

	# Live material change: the body keeps its velocity, so no rebuild happened.
	var before: Vector3 = free_ball.get_linear_velocity()
	free_ball.friction = 0.9
	free_ball.restitution = 0.2
	_check("friction / restitution apply live without rebuilding the body",
		free_ball.get_linear_velocity().distance_to(before) < 0.001
		and is_equal_approx(free_ball.friction, 0.9))

	world.free()


func _test_collision_group() -> void:
	var world := Box3DWorld.new()
	add_child(world)

	# Same negative group: never collide, whatever the masks say.
	var floor_a := Box3DBody.new()
	floor_a.body_type = Box3DBody.STATIC
	floor_a.box_size = Vector3(8, 1, 8)
	floor_a.position = Vector3(-20, -0.5, 0)
	floor_a.collision_group = -7
	world.add_child(floor_a)

	var ghost := Box3DBody.new()
	ghost.position = Vector3(-20, 3, 0)
	ghost.collision_group = -7
	world.add_child(ghost)

	# Same positive group: always collide, even though the masks exclude.
	var floor_b := Box3DBody.new()
	floor_b.body_type = Box3DBody.STATIC
	floor_b.box_size = Vector3(8, 1, 8)
	floor_b.position = Vector3(0, -0.5, 0)
	floor_b.collision_layer = 2
	floor_b.collision_mask = 4
	floor_b.collision_group = 7
	world.add_child(floor_b)

	var sticky := Box3DBody.new()
	sticky.position = Vector3(0, 3, 0)
	sticky.collision_layer = 8
	sticky.collision_mask = 16
	sticky.collision_group = 7
	world.add_child(sticky)

	# Categories 33-64 (the high dword of b3Filter): only reachable through the
	# _high properties.
	var floor_c := Box3DBody.new()
	floor_c.body_type = Box3DBody.STATIC
	floor_c.box_size = Vector3(8, 1, 8)
	floor_c.position = Vector3(20, -0.5, 0)
	floor_c.collision_mask = 0
	floor_c.collision_mask_high = 1
	world.add_child(floor_c)

	var high := Box3DBody.new()
	high.position = Vector3(20, 3, 0)
	high.collision_layer = 0
	high.collision_layer_high = 1
	world.add_child(high)

	var low := Box3DBody.new()
	low.position = Vector3(22, 3, 0)
	low.collision_layer = 1
	low.collision_layer_high = 0
	world.add_child(low)

	for i in range(120):
		await get_tree().physics_frame

	_check("collision_group negative: matching bodies never collide",
		ghost.position.y < -2.0)
	_check("collision_group positive: matching bodies always collide despite masks",
		sticky.position.y > 0.2)
	_check("collision_layer_high / collision_mask_high reach categories 33-64",
		high.position.y > 0.2 and low.position.y < -2.0)

	world.free()


func _test_wind() -> void:
	var world := Box3DWorld.new()
	add_child(world)

	var still := Box3DBody.new()
	still.shape_type = Box3DBody.SPHERE
	still.position = Vector3(0, 20, -3)
	world.add_child(still)

	var blown := Box3DBody.new()
	blown.shape_type = Box3DBody.SPHERE
	blown.position = Vector3(0, 20, 3)
	world.add_child(blown)

	for i in range(90):
		blown.apply_wind(Vector3(10, 0, 0), 1.5, 0.0, 10.0)
		await get_tree().physics_frame

	_check("apply_wind pushes a shape downwind (%.2f m vs %.2f m)" % [blown.position.x, still.position.x],
		blown.position.x > 0.5 and absf(still.position.x) < 0.01)

	world.free()


func _test_shape_handles() -> void:
	var world := Box3DWorld.new()
	add_child(world)

	var floor := Box3DBody.new()
	floor.body_type = Box3DBody.STATIC
	floor.box_size = Vector3(20, 1, 20)
	floor.position = Vector3(0, -0.5, 0)
	world.add_child(floor)

	var body := Box3DBody.new()
	body.position = Vector3(0, 5, 0)
	var cs := Box3DCollisionShape.new()
	cs.name = "Chunk"
	cs.box_size = Vector3.ONE
	body.add_child(cs)
	world.add_child(body)
	await get_tree().physics_frame

	_check("collision shape carries a live b3ShapeId and its node name",
		cs.is_shape_valid() and cs.get_shape_name() == "Chunk" and not cs.is_sensor())

	var box: AABB = cs.get_aabb()
	_check("shape AABB and closest point come from the solver",
		box.get_center().distance_to(body.global_position) < 0.3
		and box.size.distance_to(Vector3.ONE) < 0.4
		and cs.get_closest_point(body.global_position + Vector3(0, 5, 0))
			.distance_to(body.global_position + Vector3(0, 0.5, 0)) < 0.1)

	var mass_data: Dictionary = cs.compute_mass_data()
	_check("shape mass data computes from its own geometry and density",
		absf(float(mass_data["mass"]) - 1.0) < 0.01)

	# Live material and density: a rebuild would recreate the body at rest, so
	# an unchanged velocity proves the shape was edited in place.
	var vel: Vector3 = body.get_linear_velocity()
	cs.friction = 0.9
	cs.rolling_resistance = 0.3
	cs.tangent_velocity = Vector3(1, 0, 0)
	cs.density = 2.0
	_check("shape material and density apply live, without rebuilding the body",
		cs.is_shape_valid() and body.get_linear_velocity().distance_to(vel) < 0.001
		and absf(body.get_mass() - 2.0) < 0.02 and is_equal_approx(cs.rolling_resistance, 0.3))

	cs.set_shape_name("Renamed")
	_check("shape name round-trips through b3Shape_SetName / GetName",
		cs.get_shape_name() == "Renamed")

	# A geometry change still rebuilds the body; the handle must be re-wired.
	body.is_sensor = true
	await get_tree().physics_frame
	_check("shape handle is re-wired after a body rebuild",
		cs.is_shape_valid() and cs.is_sensor())

	world.free()


func _test_filter_joint() -> void:
	var world := Box3DWorld.new()
	add_child(world)

	# Two overlapping boxes with no gravity. Without the filter joint the
	# contact shoves them apart; with it they stay where they were put.
	var a := Box3DBody.new()
	a.name = "FilterA"
	a.shape_type = Box3DBody.BOX
	a.box_size = Vector3(1, 1, 1)
	a.gravity_scale = 0.0
	a.position = Vector3(0, 3, 0)
	world.add_child(a)

	var b := Box3DBody.new()
	b.name = "FilterB"
	b.shape_type = Box3DBody.BOX
	b.box_size = Vector3(1, 1, 1)
	b.gravity_scale = 0.0
	b.position = Vector3(0.3, 3, 0)
	world.add_child(b)

	var joint := Box3DFilterJoint.new()
	joint.position = Vector3(0, 3, 0)
	# Both paths are set BEFORE the joint enters the tree, so Box3DJoint's ready
	# handler finds the bodies and creates the b3 joint immediately. Assigning
	# them afterwards leaves one physics tick in which the pair is still
	# unfiltered, and the contact push it trades there never decays.
	joint.body_a = NodePath("../FilterA")
	joint.body_b = NodePath("../FilterB")
	world.add_child(joint)

	var start := a.position.distance_to(b.position)
	for i in range(30):
		await get_tree().physics_frame
	var separation := a.position.distance_to(b.position)
	_check("filter joint keeps two overlapping bodies overlapped (%.3f -> %.3f)" % [start, separation],
		absf(separation - 0.3) < 0.01)
	_check("filter joint reports its box3d type",
		joint.get_joint_type() == Box3DJoint.JOINT_FILTER)

	world.free()


func _test_contact_query() -> void:
	var world := Box3DWorld.new()
	add_child(world)

	var floor := Box3DBody.new()
	floor.body_type = Box3DBody.STATIC
	floor.box_size = Vector3(20, 1, 20)
	floor.position = Vector3(0, -0.5, 0)
	world.add_child(floor)

	var box := Box3DBody.new()
	box.box_size = Vector3.ONE
	box.position = Vector3(0, 2, 0)
	world.add_child(box)

	# A sensor volume the box lands inside, for the overlap poll.
	var zone := Box3DBody.new()
	zone.body_type = Box3DBody.STATIC
	zone.is_sensor = true
	zone.box_size = Vector3(4, 4, 4)
	zone.position = Vector3(0, 1, 0)
	world.add_child(zone)

	for i in range(120):
		await get_tree().physics_frame

	var contacts: Array = box.get_contacts()
	var touching: Array = box.get_touching_bodies()
	var found := {}
	var normal_up := false
	var has_points := false
	for c in contacts:
		found[c["collider"]] = true
		# The manifold normal is reported pointing away from this body, so a box
		# resting on the floor sees it pointing down.
		if c["collider"] == floor:
			normal_up = (c["normal"] as Vector3).y < -0.8
			has_points = (c["points"] as Array).size() > 0 and float(c["impulse"]) > 0.0
	_check("get_contacts reports the resting contact with its normal and impulse",
		found.has(floor) and normal_up and has_points)
	_check("get_touching_bodies lists each toucher once",
		touching.size() == 1 and touching[0] == floor)

	var inside: Array = zone.get_overlapping_bodies()
	_check("get_overlapping_bodies polls the sensor's current overlaps",
		inside.has(box) and box.get_overlapping_bodies().is_empty())

	world.free()


func _test_height_field() -> void:
	var world := Box3DWorld.new()
	add_child(world)

	# b3CreateGrid: a flat 8x8-cell field whose corner sits at the body origin
	# and grows along +X/+Z, so offset the body by -extent/2 to center it.
	var ground := Box3DBody.new()
	ground.body_type = Box3DBody.STATIC
	ground.shape_type = Box3DBody.HEIGHT_FIELD
	ground.height_field_size = Vector2i(9, 9)
	ground.height_field_scale = Vector3(1, 1, 1)
	world.add_child(ground)
	var extent: Vector3 = ground.get_height_field_extent()
	ground.position = -0.5 * extent
	_check("height field extent is scale * (grid lines - 1)",
		extent.is_equal_approx(Vector3(8, 0, 8)))

	var ball := Box3DBody.new()
	ball.shape_type = Box3DBody.SPHERE
	ball.sphere_radius = 0.5
	ball.position = Vector3(0, 3, 0)
	world.add_child(ball)

	for i in range(120):
		await get_tree().physics_frame
	_check("height field grid catches a falling body (%.3f)" % ball.position.y,
		absf(ball.position.y - 0.5) < 0.1)
	world.free()

	# Explicit heights plus a per-cell hole: a 3x3 grid of points is 2x2 cells,
	# and cell 0 (x and z in [0,1]) is punched out with HEIGHT_FIELD_HOLE.
	var world2 := Box3DWorld.new()
	add_child(world2)
	var terrain := Box3DBody.new()
	terrain.body_type = Box3DBody.STATIC
	terrain.shape_type = Box3DBody.HEIGHT_FIELD
	terrain.height_field_size = Vector2i(3, 3)
	terrain.height_field_scale = Vector3(1, 1, 1)
	terrain.height_field_heights = PackedFloat32Array([0, 0, 0, 0, 0, 0, 0, 0, 0])
	terrain.height_field_materials = PackedByteArray([Box3DBody.HEIGHT_FIELD_HOLE, 0, 0, 0])
	world2.add_child(terrain)

	var dropper := Box3DBody.new()
	dropper.shape_type = Box3DBody.SPHERE
	dropper.sphere_radius = 0.3
	dropper.position = Vector3(0.5, 2, 0.5)
	world2.add_child(dropper)

	var lander := Box3DBody.new()
	lander.shape_type = Box3DBody.SPHERE
	lander.sphere_radius = 0.3
	lander.position = Vector3(1.5, 2, 1.5)
	world2.add_child(lander)

	for i in range(120):
		await get_tree().physics_frame
	_check("height field from explicit heights holds a body up (%.3f)" % lander.position.y,
		absf(lander.position.y - 0.3) < 0.1)
	_check("height field hole cell lets a body through (%.3f)" % dropper.position.y,
		dropper.position.y < -1.0)
	world2.free()


func _test_mesh_from_data() -> void:
	var world := Box3DWorld.new()
	add_child(world)

	# b3MeshDef vertices/indices handed over raw. Box3D's winding is CCW by the
	# right-hand rule (upstream's own b3CreateGridMesh winds this way), which is
	# the opposite of what the Godot Mesh path has to flip.
	var ground := Box3DBody.new()
	ground.body_type = Box3DBody.STATIC
	ground.shape_type = Box3DBody.MESH
	ground.mesh_vertices = PackedVector3Array([
		Vector3(-5, 0, -5), Vector3(-5, 0, 5), Vector3(5, 0, 5), Vector3(5, 0, -5)])
	ground.mesh_indices = PackedInt32Array([0, 1, 2, 2, 3, 0])
	# One material index per triangle, indexing surface_materials.
	ground.mesh_materials = PackedByteArray([0, 1])
	ground.surface_materials = [
		{"friction": 0.1, "restitution": 0.0},
		{"friction": 0.9, "restitution": 0.25},
	]
	world.add_child(ground)

	var box := Box3DBody.new()
	box.box_size = Vector3.ONE
	box.position = Vector3(0, 3, 0)
	world.add_child(box)

	for i in range(120):
		await get_tree().physics_frame
	_check("mesh built from raw vertices and indices collides (%.3f)" % box.position.y,
		absf(box.position.y - 0.5) < 0.1)
	_check("per-triangle materials reach the shape",
		ground.get_mesh_material_count() == 2)
	var mat: Dictionary = ground.get_mesh_material(1)
	_check("per-triangle material reads back what was authored",
		absf(float(mat.get("friction", 0.0)) - 0.9) < 0.001
			and absf(float(mat.get("restitution", 0.0)) - 0.25) < 0.001)
	ground.set_mesh_material(0, {"friction": 0.42})
	_check("set_mesh_material updates a live mesh material",
		absf(float(ground.get_mesh_material(0).get("friction", 0.0)) - 0.42) < 0.001)
	world.free()


func _test_shape_scale() -> void:
	var world := Box3DWorld.new()
	add_child(world)

	var floor := Box3DBody.new()
	floor.body_type = Box3DBody.STATIC
	floor.box_size = Vector3(40, 1, 40)
	floor.position = Vector3(0, -0.5, 0)
	world.add_child(floor)

	# A 1 m box scaled 3x: the collider has to be 3 m too, so it rests with its
	# center 1.5 m up instead of 0.5 m.
	var box := Box3DBody.new()
	box.box_size = Vector3.ONE
	box.scale = Vector3(3, 3, 3)
	box.position = Vector3(-4, 4, 0)
	world.add_child(box)

	# Non-uniform scale on a box: only the y factor decides the resting height.
	var flat := Box3DBody.new()
	flat.box_size = Vector3.ONE
	flat.scale = Vector3(4, 0.5, 4)
	flat.position = Vector3(4, 4, 0)
	world.add_child(flat)

	# Spheres have no non-uniform form in Box3D, so they take the largest factor.
	var ball := Box3DBody.new()
	ball.shape_type = Box3DBody.SPHERE
	ball.sphere_radius = 0.5
	ball.scale = Vector3(2, 2, 2)
	ball.position = Vector3(0, 4, 8)
	world.add_child(ball)

	# A scaled compound: the child's offset and its geometry both scale.
	var compound := Box3DBody.new()
	compound.scale = Vector3(2, 2, 2)
	compound.position = Vector3(0, 4, -8)
	var part := Box3DCollisionShape.new()
	part.shape_type = Box3DCollisionShape.BOX
	part.box_size = Vector3.ONE
	part.position = Vector3(0, 1, 0)
	compound.add_child(part)
	world.add_child(compound)

	for i in range(180):
		await get_tree().physics_frame

	_check("uniformly scaled node gets a scaled box collider (%.3f)" % box.position.y,
		absf(box.position.y - 1.5) < 0.1)
	_check("non-uniform scale sizes each box axis (%.3f)" % flat.position.y,
		absf(flat.position.y - 0.25) < 0.05)
	_check("scaled node keeps its scale through the physics sync",
		box.scale.is_equal_approx(Vector3(3, 3, 3)))
	_check("scaled sphere collider grows with the node (%.3f)" % ball.position.y,
		absf(ball.position.y - 1.0) < 0.1)
	# The child sits 1 m above the body origin at scale 1, so 2 m at scale 2,
	# and its 0.5 m half-height becomes 1 m. Its lowest point is then
	# origin + 2 - 1, so a body resting on the floor has its origin at -1.
	_check("scaled compound scales the child offset and geometry (%.3f)" % compound.position.y,
		absf(compound.position.y - (-1.0)) < 0.1)

	world.free()


func _test_contact_hit_events() -> void:
	var world := Box3DWorld.new()
	add_child(world)
	var hits: Array = []
	world.contact_hit.connect(func(h: Dictionary) -> void: hits.append(h))

	var ground := Box3DBody.new()
	ground.name = "HitGround"
	ground.body_type = Box3DBody.STATIC
	ground.shape_type = Box3DBody.BOX
	ground.box_size = Vector3(20, 1, 20)
	ground.position = Vector3(0, -0.5, 0)
	world.add_child(ground)

	var ball := Box3DBody.new()
	ball.name = "HitBall"
	ball.shape_type = Box3DBody.SPHERE
	ball.sphere_radius = 0.5
	ball.position = Vector3(0, 8, 0)
	world.add_child(ball)

	for i in range(180):
		await get_tree().physics_frame

	_check("contact_hit fires on a fast impact (%d)" % hits.size(), hits.size() > 0)
	if hits.size() > 0:
		var h: Dictionary = hits[0]
		_check("contact hit names both bodies",
			h["body_a"] != null and h["body_b"] != null)
		_check("contact hit normal is the ground normal (%.2f)" % absf(h["normal"].y),
			absf(h["normal"].y) > 0.9)
		_check("contact hit reports the approach speed (%.2f)" % h["approach_speed"],
			h["approach_speed"] > 5.0)
		_check("contact hit point is at the impact (%.2f)" % h["point"].y,
			absf(h["point"].y) < 0.5)
	# Raising the threshold above the impact speed suppresses the event.
	world.hit_event_threshold = 50.0
	_check("hit_event_threshold round-trips", is_equal_approx(world.hit_event_threshold, 50.0))
	world.free()


func _test_joint_events() -> void:
	var world := Box3DWorld.new()
	add_child(world)
	var events: Array = []
	world.joint_threshold_exceeded.connect(
		func(j, force: Vector3, torque: Vector3) -> void: events.append([j, force, torque]))

	var anchor := Box3DBody.new()
	anchor.name = "JEAnchor"
	anchor.body_type = Box3DBody.STATIC
	anchor.shape_type = Box3DBody.BOX
	anchor.box_size = Vector3(0.2, 0.2, 0.2)
	anchor.position = Vector3(0, 6, 0)
	world.add_child(anchor)

	var hung := Box3DBody.new()
	hung.name = "JEHung"
	hung.shape_type = Box3DBody.BOX
	hung.box_size = Vector3(1, 1, 1)
	hung.density = 500.0
	hung.position = Vector3(0, 4, 0)
	world.add_child(hung)

	var joint := Box3DDistanceJoint.new()
	joint.position = Vector3(0, 6, 0)
	world.add_child(joint)
	joint.body_a = NodePath("../JEAnchor")
	joint.body_b = NodePath("../JEHung")
	joint.force_threshold = 1.0 # newtons; the load is ~4900 N

	for i in range(60):
		await get_tree().physics_frame

	_check("joint_threshold_exceeded fires for a loaded joint (%d)" % events.size(),
		events.size() > 0)
	if events.size() > 0:
		_check("joint event hands back the joint node", events[0][0] == joint)
		_check("joint event carries the constraint force (%.0f N)" % events[0][1].length(),
			events[0][1].length() > 100.0)
	world.free()


func _test_world_queries() -> void:
	var world := Box3DWorld.new()
	add_child(world)
	for i in range(3):
		var wall := Box3DBody.new()
		wall.name = "QWall%d" % i
		wall.body_type = Box3DBody.STATIC
		wall.shape_type = Box3DBody.BOX
		wall.box_size = Vector3(0.2, 4, 4)
		wall.position = Vector3(2 + 3 * i, 0, 0)
		world.add_child(wall)
	await get_tree().physics_frame
	await get_tree().physics_frame

	var all: Array = world.raycast_all(Vector3(-5, 0, 0), Vector3(15, 0, 0))
	_check("raycast_all reports every wall (%d)" % all.size(), all.size() == 3)
	if all.size() == 3:
		_check("raycast_all is sorted nearest first",
			all[0]["fraction"] < all[1]["fraction"] and all[1]["fraction"] < all[2]["fraction"])
		_check("raycast_all entries name the body", all[0]["collider"] != null)
	var one: Dictionary = world.raycast(Vector3(-5, 0, 0), Vector3(15, 0, 0))
	_check("raycast reports the triangle and child index", one.has("triangle_index") and one.has("child_index"))
	_check("overlap_box finds only the wall it covers (%d)" % world.overlap_box(Vector3(2, 0, 0), Vector3(1, 1, 1)).size(),
		world.overlap_box(Vector3(2, 0, 0), Vector3(1, 1, 1)).size() == 1)
	_check("overlap_aabb finds all three walls (%d)" % world.overlap_aabb(AABB(Vector3(-1, -3, -3), Vector3(10, 6, 6))).size(),
		world.overlap_aabb(AABB(Vector3(-1, -3, -3), Vector3(10, 6, 6))).size() == 3)
	var cast: Dictionary = world.shape_cast_box(Vector3(-5, 0, 0), Vector3(15, 0, 0), Vector3(1, 1, 1))
	_check("shape_cast_box stops at the first wall", cast["hit"] and cast["fraction"] < 0.35)
	_check("get_bounds covers the walls (%.1f)" % world.get_bounds().size.x, world.get_bounds().size.x > 6.0)
	_check("get_awake_body_count counts nothing when all bodies are static",
		world.get_awake_body_count() == 0)
	world.free()


func _test_character_sweep_and_floor() -> void:
	var world := Box3DWorld.new()
	add_child(world)

	var ground := Box3DBody.new()
	ground.body_type = Box3DBody.STATIC
	ground.shape_type = Box3DBody.BOX
	ground.box_size = Vector3(40, 1, 40)
	ground.position = Vector3(0, -0.5, 0)
	world.add_child(ground)

	# 0.1 m thick: thinner than a single fast tick of travel.
	var wall := Box3DBody.new()
	wall.body_type = Box3DBody.STATIC
	wall.shape_type = Box3DBody.BOX
	wall.box_size = Vector3(0.1, 6, 20)
	wall.position = Vector3(5, 2, 0)
	world.add_child(wall)

	var character := Box3DCharacterBody.new()
	character.radius = 0.4
	character.height = 1.8
	character.position = Vector3(0, 0.9, 0)
	world.add_child(character)
	await get_tree().physics_frame

	# 10 m in one tick, straight at the wall: the sweep must stop it.
	character.move_and_slide(Vector3(600, 0, 0), 1.0 / 60.0)
	_check("fast character does not tunnel through a thin wall (%.2f)" % character.position.x,
		character.position.x < 4.7)

	for i in range(60):
		character.move_and_slide(Vector3(0, -9.8, 0), 1.0 / 60.0)
		await get_tree().physics_frame

	_check("character reports standing on the floor", character.is_on_floor())
	_check("character floor normal points up (%.2f)" % character.get_floor_normal().y,
		character.get_floor_normal().y > 0.9)
	_check("character reports the wall it is against", character.is_on_wall())
	_check("character is not on a ceiling", not character.is_on_ceiling())
	_check("character collision list names the bodies it touches (%d)" % character.get_last_collisions().size(),
		character.get_last_collisions().size() >= 2)
	_check("clip_velocity removes the into-floor component",
		absf(character.clip_velocity(Vector3(0, -5, 0)).y) < 0.01)
	world.free()


func _test_shape_def_extras() -> void:
	var world := Box3DWorld.new()
	add_child(world)

	var floor := Box3DBody.new()
	floor.body_type = Box3DBody.STATIC
	floor.box_size = Vector3(40, 1, 40)
	floor.position = Vector3(0, -0.5, 0)
	# Static geometry can skip the contact scan at creation.
	floor.invoke_contact_creation = false
	world.add_child(floor)

	# b3ShapeDef.explosionScale: same blast, two different multipliers.
	var deaf := Box3DBody.new()
	deaf.shape_type = Box3DBody.SPHERE
	deaf.sphere_radius = 0.5
	deaf.explosion_scale = 0.0
	deaf.position = Vector3(-2, 1, 0)
	world.add_child(deaf)

	var loud := Box3DBody.new()
	loud.shape_type = Box3DBody.SPHERE
	loud.sphere_radius = 0.5
	loud.explosion_scale = 2.0
	loud.speculative_contact = false
	loud.position = Vector3(2, 1, 0)
	world.add_child(loud)

	# A compound whose children are created with updateBodyMass = false and get
	# one b3Body_ApplyMassFromShapes at the end: the mass must still be the sum.
	var compound := Box3DBody.new()
	compound.density = 1000.0
	compound.position = Vector3(0, 6, 0)
	for x in [-1.0, 1.0]:
		var cs := Box3DCollisionShape.new()
		cs.shape_type = Box3DCollisionShape.BOX
		cs.box_size = Vector3.ONE
		cs.density = 1000.0
		cs.position = Vector3(x, 0, 0)
		compound.add_child(cs)
	world.add_child(compound)

	await get_tree().physics_frame
	await get_tree().physics_frame
	_check("compound mass is the sum of its children after one recompute (%.0f)" % compound.get_mass(),
		absf(compound.get_mass() - 2000.0) < 1.0)

	world.explode(Vector3(0, 1, 0), 6.0, 400.0, 0.0)
	for i in range(30):
		await get_tree().physics_frame
	_check("explosion_scale 0 ignores the blast (%.3f)" % deaf.position.x,
		absf(deaf.position.x - (-2.0)) < 0.05)
	_check("explosion_scale 2 is thrown by it (%.3f)" % loud.position.x,
		loud.position.x > 3.0)
	_check("invoke_contact_creation and speculative_contact round-trip",
		floor.invoke_contact_creation == false and loud.speculative_contact == false
			and deaf.speculative_contact == true)

	world.free()


func _test_space_conversions() -> void:
	var world := Box3DWorld.new()
	add_child(world)

	# Scaled and rotated: Node3D's to_local divides by the node scale, while
	# Box3D's body frame has no scale at all (the scale lives in the collider).
	var body := Box3DBody.new()
	body.body_type = Box3DBody.STATIC
	body.box_size = Vector3.ONE
	body.scale = Vector3(2, 2, 2)
	body.position = Vector3(3, 1, 0)
	body.rotation = Vector3(0, PI * 0.5, 0)
	world.add_child(body)
	await get_tree().physics_frame

	var world_point: Vector3 = body.get_world_point(Vector3(1, 0, 0))
	_check("get_world_point uses the unscaled solver frame (%v)" % world_point,
		world_point.is_equal_approx(Vector3(3, 1, -1)))
	_check("get_local_point inverts get_world_point",
		body.get_local_point(world_point).is_equal_approx(Vector3(1, 0, 0)))
	_check("get_world_vector rotates without translating",
		body.get_world_vector(Vector3(1, 0, 0)).is_equal_approx(Vector3(0, 0, -1)))
	_check("get_local_vector inverts get_world_vector",
		body.get_local_vector(Vector3(0, 0, -1)).is_equal_approx(Vector3(1, 0, 0)))
	# The divergence this binding exists for: to_local carries the node scale.
	_check("the node's to_local disagrees, as the scale makes it",
		not body.to_local(world_point).is_equal_approx(Vector3(1, 0, 0)))

	world.free()


func _test_shape_geometry() -> void:
	var world := Box3DWorld.new()
	add_child(world)

	var body := Box3DBody.new()
	body.gravity_scale = 0.0
	body.position = Vector3.ZERO
	# Children go on before the body joins the world: one added afterwards is
	# built from a global transform that has not propagated yet.
	var box_cs := Box3DCollisionShape.new()
	box_cs.name = "GeoBox"
	box_cs.shape_type = Box3DCollisionShape.BOX
	box_cs.box_size = Vector3(2, 2, 2)
	box_cs.position = Vector3(-3, 0, 0)
	body.add_child(box_cs)

	var sphere_cs := Box3DCollisionShape.new()
	sphere_cs.name = "GeoSphere"
	sphere_cs.shape_type = Box3DCollisionShape.SPHERE
	sphere_cs.sphere_radius = 0.5
	body.add_child(sphere_cs)

	var capsule_cs := Box3DCollisionShape.new()
	capsule_cs.name = "GeoCapsule"
	capsule_cs.shape_type = Box3DCollisionShape.CAPSULE
	capsule_cs.capsule_radius = 0.25
	capsule_cs.capsule_height = 2.0
	capsule_cs.position = Vector3(3, 0, 0)
	body.add_child(capsule_cs)

	world.add_child(body)
	await get_tree().physics_frame

	# b3Shape_GetType: the node's authored type is not the solver's — a box is a
	# hull to Box3D.
	_check("get_geometry_type reports what the solver holds",
		box_cs.get_geometry_type() == Box3DCollisionShape.GEOMETRY_HULL
		and sphere_cs.get_geometry_type() == Box3DCollisionShape.GEOMETRY_SPHERE
		and capsule_cs.get_geometry_type() == Box3DCollisionShape.GEOMETRY_CAPSULE)

	var sphere: Dictionary = sphere_cs.get_sphere()
	_check("get_sphere returns the solver's center and radius",
		is_equal_approx(float(sphere["radius"]), 0.5)
		and (sphere["center"] as Vector3).is_equal_approx(Vector3.ZERO))

	var capsule: Dictionary = capsule_cs.get_capsule()
	_check("get_capsule returns both cap centers at the child offset (%v)" % capsule["center1"],
		is_equal_approx(float(capsule["radius"]), 0.25)
		and (capsule["center1"] as Vector3).is_equal_approx(Vector3(3, -0.75, 0))
		and (capsule["center2"] as Vector3).is_equal_approx(Vector3(3, 0.75, 0)))

	var hull: Dictionary = box_cs.get_hull()
	_check("get_hull returns the box's 8 points, 6 faces and its volume (%.2f)" % float(hull["volume"]),
		int(hull["vertex_count"]) == 8 and int(hull["face_count"]) == 6
		and (hull["points"] as PackedVector3Array).size() == 8
		and absf(float(hull["volume"]) - 8.0) < 0.01
		and (hull["center"] as Vector3).is_equal_approx(Vector3(-3, 0, 0)))

	# Every reader is type-guarded: upstream's Get* family asserts on a mismatch.
	_check("a type-mismatched geometry reader returns nothing rather than asserting",
		box_cs.get_sphere().is_empty() and sphere_cs.get_hull().is_empty()
		and box_cs.get_mesh().is_empty())

	# b3Shape_RayCast: straight down the sphere's axis, hit point in world space.
	var ray: Dictionary = sphere_cs.raycast(Vector3(0, 5, 0), Vector3(0, -10, 0))
	_check("shape raycast hits its own geometry at the surface (%v)" % ray["point"],
		bool(ray["hit"]) and absf(float(ray["fraction"]) - 0.45) < 0.02
		and absf((ray["point"] as Vector3).y - 0.5) < 0.02
		and (ray["normal"] as Vector3).y > 0.9)
	_check("shape raycast misses when the ray does not cross the shape",
		not bool(sphere_cs.raycast(Vector3(0, 5, 0), Vector3(0, 1, 0))["hit"]))

	# b3Shape_Set*: retype/resize in place. The body is not rebuilt, so the
	# handle survives; mass only moves because update_mass pays for it.
	var mass_before: float = body.get_mass()
	sphere_cs.set_sphere(Vector3.ZERO, 1.0)
	_check("set_sphere resizes in place and updates the body mass (%.2f -> %.2f)" % [mass_before, body.get_mass()],
		sphere_cs.is_shape_valid()
		and is_equal_approx(float(sphere_cs.get_sphere()["radius"]), 1.0)
		and body.get_mass() - mass_before > 3.0)

	capsule_cs.set_capsule(Vector3(3, -1, 0), Vector3(3, 1, 0), 0.5)
	var grown: Dictionary = capsule_cs.get_capsule()
	_check("set_capsule replaces both cap centers and the radius",
		is_equal_approx(float(grown["radius"]), 0.5)
		and (grown["center2"] as Vector3).is_equal_approx(Vector3(3, 1, 0)))

	# set_hull takes a raw point cloud; the four corners of a tetrahedron.
	box_cs.set_hull(PackedVector3Array([
		Vector3(-3, 0, 0), Vector3(-2, 0, 0), Vector3(-3, 1, 0), Vector3(-3, 0, 1)]))
	var tetra: Dictionary = box_cs.get_hull()
	_check("set_hull rebuilds the geometry from a point cloud (%d points, %d faces)"
			% [int(tetra["vertex_count"]), int(tetra["face_count"])],
		box_cs.get_geometry_type() == Box3DCollisionShape.GEOMETRY_HULL
		and int(tetra["vertex_count"]) == 4 and int(tetra["face_count"]) == 4)

	world.free()


func _test_shape_filter_and_events() -> void:
	var world := Box3DWorld.new()
	add_child(world)

	var ground := Box3DBody.new()
	ground.name = "FilterGround"
	ground.body_type = Box3DBody.STATIC
	ground.shape_type = Box3DBody.BOX
	ground.box_size = Vector3(40, 1, 40)
	ground.position = Vector3(0, -0.5, 0)
	ground.collision_layer = 1
	world.add_child(ground)

	# Two children on one body: the left one inherits the body's filter, the
	# right one overrides it to a mask that cannot see the ground's layer 1.
	var body := Box3DBody.new()
	body.name = "FilterBody"
	body.contact_monitor = false
	body.collision_layer = 2
	body.collision_mask = 1
	body.position = Vector3(0, 4, 0)

	var inherited := Box3DCollisionShape.new()
	inherited.name = "Inherited"
	inherited.box_size = Vector3.ONE
	inherited.position = Vector3(-1, 0, 0)
	body.add_child(inherited)

	var overridden := Box3DCollisionShape.new()
	overridden.name = "Overridden"
	overridden.box_size = Vector3.ONE
	overridden.position = Vector3(1, 0, 0)
	overridden.filter_override = true
	overridden.collision_layer = 4
	overridden.collision_mask = 8  # not the ground's layer 1
	overridden.collision_group = -3
	body.add_child(overridden)

	world.add_child(body)
	await get_tree().physics_frame

	var inherited_filter: Dictionary = inherited.get_filter()
	var override_filter: Dictionary = overridden.get_filter()
	_check("a shape with no override carries the body's filter (%d/%d)"
			% [inherited_filter["layer"], inherited_filter["mask"]],
		int(inherited_filter["layer"]) == 2 and int(inherited_filter["mask"]) == 1
		and int(inherited_filter["group"]) == 0)
	_check("filter_override gives one shape its own layer, mask and group (%d/%d/%d)"
			% [override_filter["layer"], override_filter["mask"], override_filter["group"]],
		int(override_filter["layer"]) == 4 and int(override_filter["mask"]) == 8
		and int(override_filter["group"]) == -3)

	# A body-level filter change must leave the overriding shape alone.
	body.collision_mask = 1 | 16
	_check("a body filter change does not stomp an overriding shape",
		int(overridden.get_filter()["mask"]) == 8
		and int(inherited.get_filter()["mask"]) == (1 | 16))

	# Event enables. Everything inherits at first: contact events follow the
	# body's contact_monitor, sensor and hit events are on.
	_check("event enables inherit the body's answers by default",
		not inherited.are_contact_events_enabled()
		and inherited.are_sensor_events_enabled() and inherited.are_hit_events_enabled())

	# contact_monitor is now pushed live; a rebuild would drop the velocity.
	var vel: Vector3 = body.get_linear_velocity()
	body.contact_monitor = true
	_check("contact_monitor enables shape contact events without rebuilding",
		inherited.is_shape_valid() and inherited.are_contact_events_enabled()
		and body.get_linear_velocity().distance_to(vel) < 0.001)

	overridden.contact_events = Box3DCollisionShape.EVENT_DISABLED
	overridden.hit_events = Box3DCollisionShape.EVENT_DISABLED
	overridden.sensor_events = Box3DCollisionShape.EVENT_DISABLED
	_check("a shape can answer for its own three event enables",
		not overridden.are_contact_events_enabled()
		and not overridden.are_hit_events_enabled()
		and not overridden.are_sensor_events_enabled()
		and inherited.are_contact_events_enabled())

	# And the body must not undo that on its next contact_monitor change.
	body.contact_monitor = false
	overridden.contact_events = Box3DCollisionShape.EVENT_ENABLED
	body.contact_monitor = true
	_check("a body event change leaves an overriding shape's answer alone",
		overridden.are_contact_events_enabled())

	# userMaterialId rides along on query results.
	overridden.user_material_id = 42
	_check("user_material_id round-trips onto the shape's surface material",
		overridden.user_material_id == 42
		and int(world.raycast(Vector3(1, 6, 0), Vector3(1, 3.5, 0)).get("user_material", -1)) == 42)

	# The override's mask cannot see the ground, so only the inherited half of
	# the compound is held up: the body tips instead of resting level.
	for i in range(120):
		await get_tree().physics_frame
	_check("the overriding shape falls through the ground the other one rests on (%.2f)"
			% body.rotation.z,
		absf(body.rotation.z) > 0.15)

	world.free()


func _make_baked_body(world: Box3DWorld, baked: bool, pos: Vector3) -> Box3DBody:
	var body := Box3DBody.new()
	body.body_type = Box3DBody.STATIC
	body.baked_compound = baked
	body.position = pos
	# Children first: a child added after the body joins the world reads an
	# unpropagated global transform.
	for i in range(4):
		var cs := Box3DCollisionShape.new()
		cs.shape_type = Box3DCollisionShape.BOX
		cs.box_size = Vector3(2, 1, 2)
		cs.position = Vector3(i * 2 - 3, 0, 0)
		cs.friction = 0.1 * (i + 1)
		body.add_child(cs)
	var sphere := Box3DCollisionShape.new()
	sphere.shape_type = Box3DCollisionShape.SPHERE
	sphere.sphere_radius = 0.5
	sphere.position = Vector3(0, 0.75, 0)
	body.add_child(sphere)
	var capsule := Box3DCollisionShape.new()
	capsule.shape_type = Box3DCollisionShape.CAPSULE
	capsule.capsule_radius = 0.25
	capsule.capsule_height = 1.5
	capsule.position = Vector3(4, 0.5, 0)
	body.add_child(capsule)
	world.add_child(body)
	return body


func _test_baked_compound() -> void:
	var world := Box3DWorld.new()
	add_child(world)

	var baked := _make_baked_body(world, true, Vector3(0, 0, 0))
	var runtime := _make_baked_body(world, false, Vector3(0, 0, 20))
	await get_tree().physics_frame

	# Six children collapse into ONE shape with one broad-phase proxy, where the
	# runtime compound keeps six.
	_check("a baked compound is a single shape where the runtime one is six (%d vs %d)"
			% [baked.get_shape_count(), runtime.get_shape_count()],
		baked.get_shape_count() == 1 and runtime.get_shape_count() == 6)

	var info: Dictionary = baked.get_compound_info()
	_check("the compound holds every child, sorted by kind (%d hulls, %d spheres, %d capsules)"
			% [info["hull_count"], info["sphere_count"], info["capsule_count"]],
		int(info["hull_count"]) == 4 and int(info["sphere_count"]) == 1
		and int(info["capsule_count"]) == 1)
	# The four boxes are identical geometry at different transforms, so the
	# blob stores one shared hull, and the four distinct frictions plus the two
	# defaults make five materials.
	# The four boxes are identical geometry at different transforms, and the
	# bake keeps the placement in the child transform rather than in the points,
	# so all four share ONE stored hull. The four distinct frictions plus the
	# sphere's and capsule's defaults make five materials.
	_check("identical child hulls are deduplicated into one shared hull (%d of %d)"
			% [info["shared_hull_count"], info["hull_count"]],
		int(info["shared_hull_count"]) == 1 and int(info["material_count"]) == 5
		and int(info["byte_count"]) > 0)
	_check("a runtime compound reports no compound info",
		runtime.get_compound_info().is_empty())

	# The bake really is collidable, at the children's baked-in offsets.
	var on_baked := world.raycast(Vector3(-3, 5, 0), Vector3(-3, -5, 0))
	var past_edge := world.raycast(Vector3(-8, 5, 0), Vector3(-8, -5, 0))
	# Box3DWorld.raycast names the hit position "position" (Box3DCollisionShape
	# .raycast and the contact_hit signal both call it "point").
	_check("a ray hits the baked compound at a child's offset (%.2f)"
			% float(on_baked.get("position", Vector3.ZERO).y),
		on_baked.get("hit", false) and on_baked["collider"] == baked
		and absf((on_baked["position"] as Vector3).y - 0.5) < 0.05)
	_check("and misses beyond the outermost child", not past_edge.get("hit", false))

	# The children of a baked compound hold no shape handle: the compound is one
	# shape, and pointing them at it would let a live setter reach
	# b3Shape_SetSurfaceMaterial, which asserts on a compound.
	var first_child: Box3DCollisionShape = baked.get_child(0)
	_check("children of a baked compound carry no shape handle",
		not first_child.is_shape_valid()
		and first_child.get_geometry_type() == Box3DCollisionShape.GEOMETRY_NONE)
	# Which must stay harmless rather than assert.
	first_child.friction = 0.9
	first_child.set_sphere(Vector3.ZERO, 1.0)
	_check("a live mutator on such a child is inert, not a crash",
		baked.get_shape_count() == 1)

	# A non-static body cannot bake: Box3D asserts on it, so the binding falls
	# back to the runtime compound rather than tripping the assert.
	var dynamic := Box3DBody.new()
	dynamic.body_type = Box3DBody.DYNAMIC
	dynamic.baked_compound = true
	dynamic.gravity_scale = 0.0
	dynamic.position = Vector3(0, 0, -20)
	for i in range(2):
		var cs := Box3DCollisionShape.new()
		cs.box_size = Vector3.ONE
		cs.position = Vector3(i * 2, 0, 0)
		dynamic.add_child(cs)
	world.add_child(dynamic)
	await get_tree().physics_frame
	_check("a dynamic body falls back to a runtime compound instead of asserting",
		dynamic.get_shape_count() == 2 and dynamic.get_compound_info().is_empty())

	world.free()


func _test_debug_overlay() -> void:
	var world := Box3DWorld.new()
	add_child(world)
	world.debug_draw_contacts = true
	world.debug_draw_contact_normals = true
	world.debug_draw_joints = true
	world.debug_draw_body_names = true
	world.debug_draw_shape_bounds = true

	var ground := Box3DBody.new()
	ground.name = "OGround"
	ground.body_type = Box3DBody.STATIC
	ground.shape_type = Box3DBody.BOX
	ground.box_size = Vector3(20, 1, 20)
	ground.position = Vector3(0, -0.5, 0)
	world.add_child(ground)

	for i in range(3):
		var b := Box3DBody.new()
		b.name = "OBox%d" % i
		b.shape_type = Box3DBody.BOX
		b.box_size = Vector3(1, 1, 1)
		b.position = Vector3(0, 0.5 + i * 1.05, 0)
		world.add_child(b)

	for i in range(20):
		await get_tree().physics_frame

	var mi: MeshInstance3D = null
	var labels := 0
	for c in world.get_children():
		if c.name == "Box3DDebugOverlay":
			mi = c
		if c is Label3D and c.visible:
			labels += 1
	_check("b3World_Draw builds a debug overlay node", mi != null)
	if mi != null:
		var mesh: ImmediateMesh = mi.mesh
		_check("debug overlay has a line surface", mesh.get_surface_count() == 1)
		var verts: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		_check("debug overlay draws lines (%d verts)" % verts.size(), verts.size() > 0)
		_check("debug overlay lines are pairs", verts.size() % 2 == 0)
	_check("drawBodyNames produces labels (%d)" % labels, labels >= 4)

	# Turning every option off clears the overlay in the same frame.
	world.debug_draw_contacts = false
	world.debug_draw_contact_normals = false
	world.debug_draw_joints = false
	world.debug_draw_body_names = false
	world.debug_draw_shape_bounds = false
	await get_tree().physics_frame
	await get_tree().physics_frame
	if mi != null:
		_check("debug overlay clears when every option is off",
			(mi.mesh as ImmediateMesh).get_surface_count() == 0 and not mi.visible)
	world.free()


func _test_world_capacity_and_live_settings() -> void:
	var world := Box3DWorld.new()
	world.capacity_static_bodies = 8
	world.capacity_dynamic_bodies = 64
	world.capacity_contacts = 256
	add_child(world)

	var ground := Box3DBody.new()
	ground.body_type = Box3DBody.STATIC
	ground.shape_type = Box3DBody.BOX
	ground.box_size = Vector3(20, 1, 20)
	ground.position = Vector3(0, -0.5, 0)
	world.add_child(ground)
	for i in range(6):
		var b := Box3DBody.new()
		b.shape_type = Box3DBody.BOX
		b.box_size = Vector3(1, 1, 1)
		b.position = Vector3(0, 1.0 + i * 1.2, 0)
		world.add_child(b)
	for i in range(20):
		await get_tree().physics_frame

	_check("capacity properties round-trip",
		world.capacity_dynamic_bodies == 64 and world.capacity_contacts == 256)
	var live: Dictionary = world.get_live_settings()
	_check("get_live_settings reports nine readings (%d)" % live.size(), live.size() == 9)
	_check("live gravity matches the property", live["gravity"].is_equal_approx(world.gravity))
	_check("live sleeping/continuous/warm flags are booleans",
		live["sleepingEnabled"] is bool and live["continuousEnabled"] is bool
			and live["warmStartingEnabled"] is bool)
	# b3World_SetWorkerCount is live now, so the reading follows the property.
	world.worker_count = 3
	_check("worker_count applies live (%d)" % world.get_live_settings()["workerCount"],
		world.get_live_settings()["workerCount"] == 3)
	var cap: Dictionary = world.get_max_capacity()
	_check("get_max_capacity reports the five b3Capacity fields", cap.size() == 5)
	_check("get_max_capacity saw the bodies (%d dynamic)" % cap["dynamicBodyCount"],
		cap["dynamicBodyCount"] >= 6)
	_check("get_world_count sees this world", Box3DWorld.get_world_count() >= 1)
	world.free()


func _test_character_soft_collision() -> void:
	var world := Box3DWorld.new()
	add_child(world)

	var ground := Box3DBody.new()
	ground.name = "SoftGround"
	ground.body_type = Box3DBody.STATIC
	ground.shape_type = Box3DBody.BOX
	ground.box_size = Vector3(40, 1, 40)
	ground.position = Vector3(0, -0.5, 0)
	world.add_child(ground)

	var rigid := Box3DCharacterBody.new()
	rigid.radius = 0.4
	rigid.height = 1.8
	rigid.position = Vector3(0, 3.0, 0)
	world.add_child(rigid)

	var soft := Box3DCharacterBody.new()
	soft.radius = 0.4
	soft.height = 1.8
	soft.position = Vector3(5, 3.0, 0)
	soft.push_limit = 0.002
	soft.clip_plane_velocity = false
	world.add_child(soft)
	await get_tree().physics_frame

	_check("push_limit defaults to 0, i.e. the rigid plane", is_zero_approx(rigid.push_limit))
	_check("clip_plane_velocity defaults on", rigid.clip_plane_velocity)
	for i in range(60):
		rigid.move_and_slide(Vector3(0, -9.8, 0), 1.0 / 60.0)
		soft.move_and_slide(Vector3(0, -9.8, 0), 1.0 / 60.0)
		await get_tree().physics_frame

	_check("rigid character rests on the surface (%.3f)" % rigid.position.y,
		absf(rigid.position.y - 0.9) < 0.02)
	_check("a low push_limit lets the character sink (%.3f vs %.3f)" % [soft.position.y, rigid.position.y],
		soft.position.y < rigid.position.y - 0.1)
	_check("solver iteration count is reported (%d)" % rigid.get_last_solver_iterations(),
		rigid.get_last_solver_iterations() >= 1)

	# b3Body_CollideMover: the ground the character is standing on.
	var planes: Array = rigid.collide_with_body(ground)
	_check("collide_with_body finds the floor (%d)" % planes.size(), planes.size() == 1)
	if planes.size() == 1:
		_check("collide_with_body normal points up (%.2f)" % planes[0]["normal"].y,
			planes[0]["normal"].y > 0.9)
		_check("collide_with_body names the body", planes[0]["collider"] == ground)
	_check("collide_with_body_at reports nothing for a body posed far away",
		rigid.collide_with_body_at(ground, Transform3D(Basis(), Vector3(0, 50, 0))).size() == 0)
	world.free()


func _test_live_shape_resize() -> void:
	var world := Box3DWorld.new()
	add_child(world)

	# No gravity and a running velocity: a rebuild would destroy and recreate
	# the body, losing the velocity, so an unchanged one proves the shape was
	# edited in place.
	var body := Box3DBody.new()
	body.shape_type = Box3DBody.BOX
	body.box_size = Vector3(1, 1, 1)
	body.gravity_scale = 0.0
	body.position = Vector3(0, 5, 0)
	world.add_child(body)
	await get_tree().physics_frame
	body.set_linear_velocity(Vector3(2, 0, 0))
	await get_tree().physics_frame

	var mass_before: float = body.get_mass()
	var vel: Vector3 = body.get_linear_velocity()
	body.box_size = Vector3(2, 2, 2)
	_check("box resize keeps the body and its velocity (%.2f -> %.2f kg)"
			% [mass_before, body.get_mass()],
		body.get_shape_count() == 1 and body.get_linear_velocity().distance_to(vel) < 0.001
		and absf(body.get_mass() - 8.0 * mass_before) < 0.01)
	_check("the resized box reports its new AABB (%.2f)" % body.get_aabb().size.x,
		absf(body.get_aabb().size.x - 2.0) < 0.05)

	# Sphere and capsule take the same route through b3Shape_SetSphere/Capsule.
	var ball := Box3DBody.new()
	ball.shape_type = Box3DBody.SPHERE
	ball.sphere_radius = 0.5
	ball.gravity_scale = 0.0
	ball.position = Vector3(10, 5, 0)
	world.add_child(ball)
	await get_tree().physics_frame
	ball.set_linear_velocity(Vector3(0, 0, 3))
	await get_tree().physics_frame
	var ball_vel: Vector3 = ball.get_linear_velocity()
	ball.sphere_radius = 1.0
	_check("sphere resize is live and rescales the mass (%.2f kg)" % ball.get_mass(),
		ball.get_linear_velocity().distance_to(ball_vel) < 0.001
		and absf(ball.get_aabb().size.x - 2.0) < 0.05)

	var pill := Box3DBody.new()
	pill.shape_type = Box3DBody.CAPSULE
	pill.capsule_radius = 0.25
	pill.capsule_height = 2.0
	pill.gravity_scale = 0.0
	pill.position = Vector3(20, 5, 0)
	world.add_child(pill)
	await get_tree().physics_frame
	pill.set_linear_velocity(Vector3(0, 0, 1))
	await get_tree().physics_frame
	var pill_vel: Vector3 = pill.get_linear_velocity()
	pill.capsule_height = 4.0
	_check("capsule resize is live (%.2f tall)" % pill.get_aabb().size.y,
		pill.get_linear_velocity().distance_to(pill_vel) < 0.001
		and absf(pill.get_aabb().size.y - 4.0) < 0.1)

	# A cylinder goes through b3Shape_SetHull, which interns the new hull the
	# same way the create call does.
	var drum := Box3DBody.new()
	drum.shape_type = Box3DBody.CYLINDER
	drum.capsule_radius = 0.5
	drum.capsule_height = 1.0
	drum.gravity_scale = 0.0
	drum.position = Vector3(30, 5, 0)
	world.add_child(drum)
	await get_tree().physics_frame
	drum.set_linear_velocity(Vector3(0, 0, 1))
	await get_tree().physics_frame
	var drum_vel: Vector3 = drum.get_linear_velocity()
	drum.capsule_radius = 1.0
	_check("cylinder resize is live through b3Shape_SetHull (%.2f wide)"
			% drum.get_aabb().size.x,
		drum.get_linear_velocity().distance_to(drum_vel) < 0.001
		and absf(drum.get_aabb().size.x - 2.0) < 0.1)

	# A shape type with no live setter must still fall back to the rebuild.
	var terrain := Box3DBody.new()
	terrain.body_type = Box3DBody.STATIC
	terrain.shape_type = Box3DBody.HEIGHT_FIELD
	terrain.height_field_size = Vector2i(4, 4)
	terrain.position = Vector3(40, 0, 0)
	world.add_child(terrain)
	await get_tree().physics_frame
	terrain.height_field_size = Vector2i(8, 8)
	await get_tree().physics_frame
	_check("a height field still rebuilds and stays valid",
		terrain.get_shape_count() == 1)

	# A compound's own dimensions are unused, so it must take the rebuild path
	# rather than resize a shape it does not have.
	var compound := Box3DBody.new()
	compound.gravity_scale = 0.0
	compound.position = Vector3(50, 5, 0)
	for i in range(2):
		var cs := Box3DCollisionShape.new()
		cs.box_size = Vector3.ONE
		cs.position = Vector3(i * 2, 0, 0)
		compound.add_child(cs)
	world.add_child(compound)
	await get_tree().physics_frame
	compound.box_size = Vector3(3, 3, 3)
	await get_tree().physics_frame
	_check("a compound body keeps both child shapes across the rebuild",
		compound.get_shape_count() == 2)

	world.free()


func _test_per_body_queries() -> void:
	var world := Box3DWorld.new()
	add_child(world)

	var wall := Box3DBody.new()
	wall.name = "QueryWall"
	wall.body_type = Box3DBody.STATIC
	wall.shape_type = Box3DBody.BOX
	wall.box_size = Vector3(1, 4, 4)
	wall.position = Vector3(0, 0, 0)
	world.add_child(wall)

	# A second body the queries must ignore: these are per-BODY, not world
	# queries, so nothing else can answer them.
	var decoy := Box3DBody.new()
	decoy.body_type = Box3DBody.STATIC
	decoy.shape_type = Box3DBody.BOX
	decoy.box_size = Vector3(1, 4, 4)
	decoy.position = Vector3(-3, 0, 0)
	world.add_child(decoy)
	await get_tree().physics_frame

	var hit: Dictionary = wall.cast_ray(Vector3(-5, 0, 0), Vector3(5, 0, 0))
	_check("cast_ray hits the body at its own surface (%.2f)"
			% float(hit.get("position", Vector3.ZERO).x),
		bool(hit["hit"]) and absf((hit["position"] as Vector3).x + 0.5) < 0.02
		and (hit["normal"] as Vector3).x < -0.9)
	_check("cast_ray reports a fraction along the ray (%.2f)" % float(hit["fraction"]),
		absf(float(hit["fraction"]) - 0.45) < 0.02)
	_check("cast_ray answers only for its own body, not the one in front of it",
		not bool(decoy.cast_ray(Vector3(-5, 0, 0), Vector3(-4.6, 0, 0))["hit"]))

	# The hypothetical pose: the same ray against a body imagined 10 m up.
	var moved := Transform3D(Basis(), Vector3(0, 10, 0))
	_check("cast_ray against a hypothetical pose misses where the body is not",
		not bool(wall.cast_ray(Vector3(-5, 0, 0), Vector3(5, 0, 0), moved)["hit"]))
	_check("and hits where that pose puts it",
		bool(wall.cast_ray(Vector3(-5, 10, 0), Vector3(5, 10, 0), moved)["hit"]))
	_check("the body itself never moved", wall.position.is_equal_approx(Vector3.ZERO))

	# Shape cast: sweep a 1 m box at the wall.
	var swept: Dictionary = wall.cast_box(Vector3(-5, 0, 0), Vector3(5, 0, 0), Vector3.ONE)
	_check("cast_box stops at the wall (%.2f)" % float(swept.get("fraction", -1.0)),
		bool(swept["hit"]) and float(swept["fraction"]) < 0.45)
	_check("cast_box misses a body posed out of the way",
		not bool(wall.cast_box(Vector3(-5, 0, 0), Vector3(5, 0, 0), Vector3.ONE, moved)["hit"]))

	# Overlap: the "would I fit here" primitive.
	_check("overlaps_box is true where the body is",
		wall.overlaps_box(Vector3.ZERO, Vector3.ONE))
	_check("overlaps_box is false in clear space",
		not wall.overlaps_box(Vector3(8, 0, 0), Vector3.ONE))
	_check("overlaps_box follows a hypothetical pose, not the real one",
		not wall.overlaps_box(Vector3.ZERO, Vector3.ONE, moved)
		and wall.overlaps_box(Vector3(0, 10, 0), Vector3.ONE, moved))

	# Both halves of the query filter, as on the world queries. Filtering is
	# two-way: the shape has to be in the query's mask AND the query has to be
	# in the shape's mask (src/shape.h:151-155).
	wall.collision_layer = 1 << 1
	wall.collision_mask = 1 << 2
	var ray_from := Vector3(-5, 0, 0)
	var ray_to := Vector3(5, 0, 0)
	var here := Transform3D()
	_check("a per-body query with the default filter still hits",
		bool(wall.cast_ray(ray_from, ray_to)["hit"])
		and bool(wall.cast_box(ray_from, ray_to, Vector3.ONE)["hit"])
		and wall.overlaps_box(Vector3.ZERO, Vector3.ONE))
	_check("a mask that excludes the shape's layer rejects all three",
		not bool(wall.cast_ray(ray_from, ray_to, here, 1 << 5)["hit"])
		and not bool(wall.cast_box(ray_from, ray_to, Vector3.ONE, here, 1 << 5)["hit"])
		and not wall.overlaps_box(Vector3.ZERO, Vector3.ONE, here, 1 << 5))
	_check("a mask that names the shape's layer accepts all three",
		bool(wall.cast_ray(ray_from, ray_to, here, 1 << 1)["hit"])
		and bool(wall.cast_box(ray_from, ray_to, Vector3.ONE, here, 1 << 1)["hit"])
		and wall.overlaps_box(Vector3.ZERO, Vector3.ONE, here, 1 << 1))
	# The category half: the shape's own mask only accepts category 3, so a
	# query that declares any other category is invisible to it. This is the
	# half these three queries did not have.
	_check("a query category the shape's mask rejects misses all three",
		not bool(wall.cast_ray(ray_from, ray_to, here, 1 << 1, 1 << 0)["hit"])
		and not bool(wall.cast_box(ray_from, ray_to, Vector3.ONE, here, 1 << 1, 1 << 0)["hit"])
		and not wall.overlaps_box(Vector3.ZERO, Vector3.ONE, here, 1 << 1, 1 << 0))
	_check("a query category the shape's mask accepts hits all three",
		bool(wall.cast_ray(ray_from, ray_to, here, 1 << 1, 1 << 2)["hit"])
		and bool(wall.cast_box(ray_from, ray_to, Vector3.ONE, here, 1 << 1, 1 << 2)["hit"])
		and wall.overlaps_box(Vector3.ZERO, Vector3.ONE, here, 1 << 1, 1 << 2))
	# Both halves are 64 bits wide, so the high categories Box3DBody exposes as
	# collision_layer_high are reachable from a per-body query too.
	wall.collision_layer = 0
	wall.collision_layer_high = 1 << 3
	_check("a per-body query reaches a category in the high dword",
		bool(wall.cast_ray(ray_from, ray_to)["hit"])
		and bool(wall.cast_ray(ray_from, ray_to, here, 1 << 35)["hit"])
		and not bool(wall.cast_ray(ray_from, ray_to, here, 1 << 34)["hit"]))

	world.free()


func _test_live_child_shape_resize() -> void:
	var world := Box3DWorld.new()
	add_child(world)

	var body := Box3DBody.new()
	body.gravity_scale = 0.0
	body.position = Vector3(0, 5, 0)
	var box_cs := Box3DCollisionShape.new()
	box_cs.name = "ResizeBox"
	box_cs.shape_type = Box3DCollisionShape.BOX
	box_cs.box_size = Vector3.ONE
	box_cs.position = Vector3(-2, 0, 0)
	body.add_child(box_cs)
	var ball_cs := Box3DCollisionShape.new()
	ball_cs.name = "ResizeBall"
	ball_cs.shape_type = Box3DCollisionShape.SPHERE
	ball_cs.sphere_radius = 0.5
	ball_cs.position = Vector3(2, 0, 0)
	body.add_child(ball_cs)
	world.add_child(body)
	await get_tree().physics_frame
	body.set_linear_velocity(Vector3(0, 0, 2))
	await get_tree().physics_frame

	var vel: Vector3 = body.get_linear_velocity()
	var mass_before: float = body.get_mass()
	var box_before: float = box_cs.get_aabb().size.x

	box_cs.box_size = Vector3(2, 2, 2)
	_check("a child box resizes in place, keeping the body and its velocity (%.2f -> %.2f)"
			% [box_before, box_cs.get_aabb().size.x],
		box_cs.is_shape_valid()
		and body.get_linear_velocity().distance_to(vel) < 0.001
		and absf(box_cs.get_aabb().size.x - 2.0) < 0.05
		and body.get_mass() > mass_before + 5.0)
	# The child that was not touched must be untouched, and still at its offset.
	_check("the sibling shape is left alone by the resize",
		is_equal_approx(float(ball_cs.get_sphere()["radius"]), 0.5)
		and (ball_cs.get_sphere()["center"] as Vector3).is_equal_approx(Vector3(2, 0, 0)))

	ball_cs.sphere_radius = 1.0
	var grown: Dictionary = ball_cs.get_sphere()
	_check("a child sphere resizes in place and keeps its offset",
		is_equal_approx(float(grown["radius"]), 1.0)
		and (grown["center"] as Vector3).is_equal_approx(Vector3(2, 0, 0))
		and body.get_linear_velocity().distance_to(vel) < 0.001)

	# A cylinder child goes through b3Shape_SetHull with the placement baked in.
	var drum_cs := Box3DCollisionShape.new()
	drum_cs.shape_type = Box3DCollisionShape.CYLINDER
	drum_cs.capsule_radius = 0.5
	drum_cs.capsule_height = 1.0
	drum_cs.position = Vector3(0, 0, 4)
	var drum_body := Box3DBody.new()
	drum_body.gravity_scale = 0.0
	drum_body.position = Vector3(20, 5, 0)
	drum_body.add_child(drum_cs)
	world.add_child(drum_body)
	await get_tree().physics_frame
	drum_body.set_linear_velocity(Vector3(1, 0, 0))
	await get_tree().physics_frame
	var drum_vel: Vector3 = drum_body.get_linear_velocity()
	drum_cs.capsule_radius = 1.0
	var drum_hull: Dictionary = drum_cs.get_hull()
	_check("a child cylinder resizes in place and stays at its offset (%.2f wide, center %v)"
			% [drum_cs.get_aabb().size.x, drum_hull["center"]],
		drum_cs.is_shape_valid()
		and drum_body.get_linear_velocity().distance_to(drum_vel) < 0.001
		and absf(drum_cs.get_aabb().size.x - 2.0) < 0.1
		and (drum_hull["center"] as Vector3).distance_to(Vector3(0, 0, 4)) < 0.05)

	world.free()


# b3JointDef.drawScale (P-034). The joint gizmo b3World_Draw emits is sized by
# jointScale * drawScale (src/joint.c:1670), so the reach of the overlay's
# vertices from the anchor is the only observable this property has.
func _draw_scale_reach(scale: float) -> float:
	var world := Box3DWorld.new()
	world.debug_draw_joints = true
	add_child(world)

	var anchor := Box3DBody.new()
	anchor.name = "DSAnchor"
	anchor.body_type = Box3DBody.STATIC
	anchor.shape_type = Box3DBody.BOX
	anchor.box_size = Vector3(0.2, 0.2, 0.2)
	anchor.position = Vector3(0, 5, 0)
	world.add_child(anchor)

	var arm := Box3DBody.new()
	arm.name = "DSArm"
	arm.shape_type = Box3DBody.BOX
	arm.box_size = Vector3(1, 0.2, 0.2)
	arm.position = Vector3(0.6, 5, 0)
	world.add_child(arm)

	var joint := Box3DHingeJoint.new()
	# Creation-time: box3d has no b3Joint_SetDrawScale, so this must be set
	# before the node enters the tree and authors the joint.
	joint.draw_scale = scale
	joint.position = Vector3(0, 5, 0)
	world.add_child(joint)
	joint.body_a = NodePath("../DSAnchor")
	joint.body_b = NodePath("../DSArm")

	for i in range(6):
		await get_tree().physics_frame

	var reach := 0.0
	for c in world.get_children():
		if c.name == "Box3DDebugOverlay":
			var mesh: ImmediateMesh = (c as MeshInstance3D).mesh
			if mesh.get_surface_count() == 1:
				var verts: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
				for v in verts:
					reach = maxf(reach, v.distance_to(Vector3(0, 5, 0)))
	world.free()
	return reach


func _test_joint_draw_scale() -> void:
	var small := await _draw_scale_reach(1.0)
	var big := await _draw_scale_reach(4.0)
	_check("a joint gizmo at draw_scale 1.0 reaches 0.10 m (%.3f)" % small,
		absf(small - 0.10) < 0.02)
	_check("a joint gizmo at draw_scale 4.0 reaches 0.40 m (%.3f)" % big,
		absf(big - 0.40) < 0.05)


# Query category filtering (P-027). b3ShouldQueryCollide is two-way: a shape is
# reported only if (shape.categoryBits & query.maskBits) and
# (shape.maskBits & query.categoryBits) are both non-zero, so every query takes
# both halves. These seven are the whole query surface of Box3DWorld.
func _query_hit_count(world: Box3DWorld, mask: int, layer: int) -> int:
	var hits := 0
	if world.raycast(Vector3(-5, 5, 0), Vector3(5, 5, 0), mask, layer)["hit"]:
		hits += 1
	if world.raycast_all(Vector3(-5, 5, 0), Vector3(5, 5, 0), mask, layer).size() > 0:
		hits += 1
	if world.overlap_sphere(Vector3(0, 5, 0), 1.0, mask, layer).size() > 0:
		hits += 1
	if world.overlap_box(Vector3(0, 5, 0), Vector3(1, 1, 1), mask, layer).size() > 0:
		hits += 1
	if world.overlap_aabb(AABB(Vector3(-1, 4, -1), Vector3(2, 2, 2)), mask, layer).size() > 0:
		hits += 1
	if world.shape_cast_box(Vector3(-5, 5, 0), Vector3(5, 5, 0), Vector3(0.4, 0.4, 0.4), mask, layer)["hit"]:
		hits += 1
	if world.shape_cast_sphere(Vector3(-5, 5, 0), Vector3(5, 5, 0), 0.2, mask, layer)["hit"]:
		hits += 1
	return hits


func _test_query_categories() -> void:
	var world := Box3DWorld.new()
	world.gravity = Vector3.ZERO
	add_child(world)

	var target := Box3DBody.new()
	target.name = "QCTarget"
	target.body_type = Box3DBody.STATIC
	target.shape_type = Box3DBody.BOX
	target.box_size = Vector3(1, 1, 1)
	target.position = Vector3(0, 5, 0)
	target.collision_layer = 1 << 1
	target.collision_mask = 1 << 2
	world.add_child(target)
	await get_tree().physics_frame
	await get_tree().physics_frame

	_check("every query finds a filtered body under the default filter (%d/7)"
			% _query_hit_count(world, -1, -1),
		_query_hit_count(world, -1, -1) == 7)
	_check("every query finds it when its own layer is in the body's mask (%d/7)"
			% _query_hit_count(world, -1, 1 << 2),
		_query_hit_count(world, -1, 1 << 2) == 7)
	_check("no query finds it when the body's mask rejects the query's layer (%d/7)"
			% _query_hit_count(world, -1, 1 << 0),
		_query_hit_count(world, -1, 1 << 0) == 0)

	# A body whose only category lives in the high dword: unreachable before the
	# query mask was widened from 32 to 64 bits.
	var high := Box3DBody.new()
	high.name = "QCHigh"
	high.body_type = Box3DBody.STATIC
	high.shape_type = Box3DBody.BOX
	high.box_size = Vector3(1, 1, 1)
	high.position = Vector3(0, 9, 0)
	high.collision_layer = 0
	high.collision_layer_high = 1 << 3 # category 35
	world.add_child(high)
	await get_tree().physics_frame
	await get_tree().physics_frame

	_check("a 64-bit-only category is visible to the default query mask",
		world.overlap_box(Vector3(0, 9, 0), Vector3(1, 1, 1)).size() == 1)
	_check("a 64-bit-only category is visible to an explicit 1 << 35 mask",
		world.overlap_box(Vector3(0, 9, 0), Vector3(1, 1, 1), 1 << 35).size() == 1)
	_check("a 64-bit-only category is invisible to a low-bit mask",
		world.overlap_box(Vector3(0, 9, 0), Vector3(1, 1, 1), 1 << 0).size() == 0)
	world.free()

	# The character mover carries a category of its own through the same test.
	var cworld := Box3DWorld.new()
	add_child(cworld)

	var ground := Box3DBody.new()
	ground.body_type = Box3DBody.STATIC
	ground.shape_type = Box3DBody.BOX
	ground.box_size = Vector3(40, 1, 40)
	ground.position = Vector3(0, -0.5, 0)
	ground.collision_mask = 1 << 2 # rejects a mover whose only layer is 1 << 0
	cworld.add_child(ground)

	var picky := Box3DCharacterBody.new()
	picky.radius = 0.4
	picky.height = 1.8
	picky.position = Vector3(-2, 0.9, 0)
	picky.collision_layer = 1 << 0
	cworld.add_child(picky)

	var plain := Box3DCharacterBody.new()
	plain.radius = 0.4
	plain.height = 1.8
	plain.position = Vector3(2, 0.9, 0)
	cworld.add_child(plain)
	await get_tree().physics_frame

	for i in range(60):
		picky.move_and_slide(Vector3(0, -9.8, 0), 1.0 / 60.0)
		plain.move_and_slide(Vector3(0, -9.8, 0), 1.0 / 60.0)
		await get_tree().physics_frame

	_check("a character whose layer the ground's mask rejects falls through it (%.2f)"
			% picky.position.y,
		picky.position.y < -1.0)
	_check("a default-layer character lands on the same ground (%.2f)" % plain.position.y,
		plain.position.y > 0.5 and plain.is_on_floor())
	cworld.free()


# Largest vertical excursion of each arm over the next ticks: an undamped
# pendulum swings ~0.6 m, a frozen one does not move.
func _ball_arm_swings(a: Box3DBody, b: Box3DBody, ticks: int) -> Array:
	var ya := a.position.y
	var yb := b.position.y
	var da := 0.0
	var db := 0.0
	for i in range(ticks):
		await get_tree().physics_frame
		da = maxf(da, absf(a.position.y - ya))
		db = maxf(db, absf(b.position.y - yb))
	return [da, db]


# Box3DBallJoint.friction_torque is a live setter (P-036), not a rebuild: it and
# the explicit motor drive the SAME box3d motor, so all four setters re-run the
# same decision instead of pushing their own field.
func _test_live_ball_friction() -> void:
	var world := Box3DWorld.new()
	add_child(world)

	var arms: Array[Box3DBody] = []
	var joints: Array[Box3DBallJoint] = []
	for i in range(2):
		var x := float(i) * 6.0
		var anchor := Box3DBody.new()
		anchor.name = "BFAnchor%d" % i
		anchor.body_type = Box3DBody.STATIC
		anchor.shape_type = Box3DBody.BOX
		anchor.box_size = Vector3(0.2, 0.2, 0.2)
		anchor.position = Vector3(x, 5, 0)
		world.add_child(anchor)

		var arm := Box3DBody.new()
		arm.name = "BFArm%d" % i
		arm.shape_type = Box3DBody.BOX
		arm.box_size = Vector3(1, 0.2, 0.2)
		arm.density = 500.0
		# A frozen arm would otherwise fall asleep, and only set_friction_torque
		# wakes its bodies — set_motor_enabled deliberately does not, so the
		# hand-back below needs an arm that is still awake to observe.
		arm.can_sleep = false
		arm.position = Vector3(x + 0.6, 5, 0)
		world.add_child(arm)
		arms.append(arm)

		var joint := Box3DBallJoint.new()
		joint.position = Vector3(x, 5, 0)
		world.add_child(joint)
		joint.body_a = NodePath("../BFAnchor%d" % i)
		joint.body_b = NodePath("../BFArm%d" % i)
		joints.append(joint)

	# Arm 0 is the free control; arm 1 gets friction while it is already loaded.
	for i in range(3):
		await get_tree().physics_frame

	var before := arms[1].position
	joints[1].friction_torque = 400.0
	await get_tree().physics_frame
	var pop := arms[1].position.distance_to(before)
	_check("raising friction_torque on a loaded ball joint does not pop it (%.4f m)" % pop,
		pop < 0.01)

	var swing := await _ball_arm_swings(arms[0], arms[1], 60)
	_check("friction_torque damps the swing to a fraction of the free arm (%.3f vs %.3f m)"
			% [swing[1], swing[0]],
		swing[0] > 0.3 and swing[1] < 0.1 * swing[0])

	joints[1].friction_torque = 0.0
	var released := await _ball_arm_swings(arms[0], arms[1], 60)
	_check("clearing friction_torque frees the joint again (%.3f m)" % released[1],
		released[1] > 0.3)

	# The explicit motor and the friction shorthand share one motor: enabling the
	# motor with a zero budget must take it back, not stack with the friction.
	joints[1].friction_torque = 400.0
	var refrozen := await _ball_arm_swings(arms[0], arms[1], 30)
	_check("friction_torque re-freezes the joint (%.3f m)" % refrozen[1], refrozen[1] < 0.05)
	joints[1].motor_enabled = true
	joints[1].max_motor_torque = 0.0
	var handed := await _ball_arm_swings(arms[0], arms[1], 60)
	_check("an explicit zero-torque motor takes the motor back from friction_torque (%.3f m)"
			% handed[1],
		handed[1] > 0.3)
	world.free()


# Upstream's debug palette reachable from script (P-044).
func _test_debug_palette() -> void:
	var count := Box3DWorld.get_graph_color_count()
	_check("the graph colour palette has one slot per constraint colour (%d)" % count,
		count > 1)
	_check("graph colour 0 is upstream's red (%s)" % Box3DWorld.get_graph_color(0).to_html(false),
		Box3DWorld.get_graph_color(0).to_html(false) == "ff0000")
	_check("graph colour 1 is upstream's orange",
		Box3DWorld.get_graph_color(1).to_html(false) == "ffa500")
	_check("the last graph colour is the overflow silver",
		Box3DWorld.get_graph_color(count - 1).to_html(false) == "c0c0c0")
	# b3GetGraphColor asserts on an out-of-range index; script must not reach it.
	_check("an out-of-range graph colour clamps to the first slot",
		Box3DWorld.get_graph_color(-5) == Box3DWorld.get_graph_color(0))
	_check("an out-of-range graph colour clamps to the overflow slot",
		Box3DWorld.get_graph_color(count + 10) == Box3DWorld.get_graph_color(count - 1))

	var packed: int = Box3DWorld.make_debug_color(Color(1, 0, 0), Box3DWorld.DEBUG_MATERIAL_METALLIC)
	_check("make_debug_color packs the material preset above the colour (0x%08X)" % packed,
		packed == 0x05FF0000)
	_check("make_debug_color leaves a default-material colour as plain RGB",
		Box3DWorld.make_debug_color(Color(0, 1, 0)) == 0x0000FF00)

	# The packed value is what b3SurfaceMaterial.customColor wants, so it has to
	# survive a trip through box3d's own material store.
	var world := Box3DWorld.new()
	add_child(world)
	var ground := Box3DBody.new()
	ground.body_type = Box3DBody.STATIC
	ground.shape_type = Box3DBody.MESH
	ground.mesh_vertices = PackedVector3Array([
		Vector3(-5, 0, -5), Vector3(-5, 0, 5), Vector3(5, 0, 5), Vector3(5, 0, -5)])
	ground.mesh_indices = PackedInt32Array([0, 1, 2, 2, 3, 0])
	ground.mesh_materials = PackedByteArray([0, 0])
	ground.surface_materials = [{"custom_color": packed}]
	world.add_child(ground)
	await get_tree().physics_frame
	await get_tree().physics_frame
	_check("a packed debug colour round-trips through a surface material",
		int(ground.get_mesh_material(0).get("custom_color", 0)) == packed)
	world.free()


func _test_live_density_and_sensor() -> void:
	var world := Box3DWorld.new()
	add_child(world)

	# P-010's tail. density goes through b3Shape_SetDensity (box3d.h:870-872),
	# so the body that owns the shape survives the change: no gravity and a
	# running velocity means a destroy-and-recreate would show up as a stop.
	var body := Box3DBody.new()
	body.box_size = Vector3(1, 1, 1)
	body.density = 1.0
	body.gravity_scale = 0.0
	body.position = Vector3(0, 5, 0)
	world.add_child(body)
	await get_tree().physics_frame
	body.set_body_name("KeepMe")
	body.set_linear_velocity(Vector3(3, 0, 0))
	body.set_angular_velocity(Vector3(0, 2, 0))
	await get_tree().physics_frame
	var vel: Vector3 = body.get_linear_velocity()
	var spin: Vector3 = body.get_angular_velocity()
	var mass_before: float = body.get_mass()
	body.density = 4.0
	_check("density is live and scales the mass 1 -> 4 (%.2f -> %.2f kg)"
			% [mass_before, body.get_mass()],
		absf(body.get_mass() - 4.0 * mass_before) < 0.001)
	_check("a density change keeps the body's velocity and spin",
		body.get_linear_velocity().distance_to(vel) < 0.001
		and body.get_angular_velocity().distance_to(spin) < 0.001)
	# The name is only ever seeded from the node name at creation, so it is
	# proof of identity: a rebuilt body would answer "Box3DBody" again.
	_check("a density change keeps the same b3 body (name survives)",
		body.get_body_name() == "KeepMe")

	# b3Shape_SetDensity does not wake anything, so a sleeping body stays asleep.
	var dozer := Box3DBody.new()
	dozer.box_size = Vector3(1, 1, 1)
	dozer.gravity_scale = 0.0
	dozer.position = Vector3(10, 5, 0)
	world.add_child(dozer)
	await get_tree().physics_frame
	dozer.set_awake(false)
	await get_tree().physics_frame
	dozer.density = 7.0
	_check("a density change does not wake a sleeping body", not dozer.is_awake())

	# A runtime compound's children each author their own density, so the
	# body-level property has nothing to push and must not disturb the shapes.
	var compound := Box3DBody.new()
	compound.gravity_scale = 0.0
	compound.position = Vector3(20, 5, 0)
	for i in range(2):
		var cs := Box3DCollisionShape.new()
		cs.box_size = Vector3.ONE
		cs.density = 2.0
		cs.position = Vector3(i * 2, 0, 0)
		compound.add_child(cs)
	world.add_child(compound)
	await get_tree().physics_frame
	compound.set_linear_velocity(Vector3(0, 0, 5))
	await get_tree().physics_frame
	var cmass: float = compound.get_mass()
	var cvel: Vector3 = compound.get_linear_velocity()
	compound.density = 9.0
	_check("a compound keeps its children's own density (%.2f kg)" % compound.get_mass(),
		absf(compound.get_mass() - cmass) < 0.001 and compound.get_shape_count() == 2
		and compound.get_linear_velocity().distance_to(cvel) < 0.001)

	# is_sensor has no live setter upstream — shape->sensorIndex is assigned
	# once, inside b3CreateShapeInternal (src/shape.c:236-248) — so the SHAPE is
	# built again. The BODY is not: velocity, spin and identity all survive.
	var ghost := Box3DBody.new()
	ghost.box_size = Vector3(1, 1, 1)
	ghost.gravity_scale = 0.0
	ghost.position = Vector3(30, 5, 0)
	world.add_child(ghost)
	await get_tree().physics_frame
	ghost.set_body_name("Ghost")
	ghost.set_linear_velocity(Vector3(0, 0, 4))
	await get_tree().physics_frame
	var gvel: Vector3 = ghost.get_linear_velocity()
	ghost.is_sensor = true
	_check("is_sensor rebuilds the shape and keeps the body (velocity, name)",
		ghost.get_shape_count() == 1 and ghost.get_body_name() == "Ghost"
		and ghost.get_linear_velocity().distance_to(gvel) < 0.001)

	world.free()

	# And the conversion is real, not just bookkeeping: a platform a ball is
	# resting on stops holding it the moment it becomes a sensor.
	var world2 := Box3DWorld.new()
	add_child(world2)
	var platform := Box3DBody.new()
	platform.body_type = Box3DBody.STATIC
	platform.box_size = Vector3(6, 0.5, 6)
	platform.position = Vector3(0, 0, 0)
	world2.add_child(platform)
	var ball := Box3DBody.new()
	ball.shape_type = Box3DBody.SPHERE
	ball.sphere_radius = 0.5
	ball.can_sleep = false
	ball.position = Vector3(0, 3, 0)
	world2.add_child(ball)
	for i in range(90):
		await get_tree().physics_frame
	var rest_y: float = ball.position.y
	_check("the ball rests on the solid platform (%.2f)" % rest_y,
		absf(rest_y - 0.75) < 0.1)
	platform.is_sensor = true
	for i in range(90):
		await get_tree().physics_frame
	_check("flipping the platform to a sensor drops the ball through it (%.2f)"
			% ball.position.y,
		ball.position.y < rest_y - 2.0)
	world2.free()


func _test_shape_rebuild_keeps_body() -> void:
	var world := Box3DWorld.new()
	add_child(world)

	# Re-authoring geometry genuinely needs a new SHAPE (there is no
	# b3Shape_SetHeightField, and a mesh blob is replaced wholesale), but never
	# a new body: recreate_shapes() swaps the shapes under a live body.
	var ground := Box3DBody.new()
	ground.body_type = Box3DBody.STATIC
	ground.shape_type = Box3DBody.MESH
	ground.mesh_vertices = PackedVector3Array([
		Vector3(-5, 0, -5), Vector3(-5, 0, 5), Vector3(5, 0, 5), Vector3(5, 0, -5)])
	ground.mesh_indices = PackedInt32Array([0, 1, 2, 2, 3, 0])
	world.add_child(ground)
	await get_tree().physics_frame
	ground.set_body_name("Ground")

	var box := Box3DBody.new()
	box.box_size = Vector3.ONE
	box.can_sleep = false
	box.position = Vector3(0, 3, 0)
	world.add_child(box)
	for i in range(120):
		await get_tree().physics_frame
	_check("the authored mesh holds the box up (%.2f)" % box.position.y,
		absf(box.position.y - 0.5) < 0.1)

	# Same body, new triangles two metres lower. Box3D's mesh collision is
	# one-sided, so the surface has to move DOWN from under a resting box for
	# the box to meet it again; moving it up would leave the box underneath it.
	ground.mesh_vertices = PackedVector3Array([
		Vector3(-5, -2, -5), Vector3(-5, -2, 5), Vector3(5, -2, 5), Vector3(5, -2, -5)])
	for i in range(120):
		await get_tree().physics_frame
	_check("re-authored mesh geometry takes effect (%.2f)" % box.position.y,
		absf(box.position.y + 1.5) < 0.15)
	_check("re-authoring the mesh kept the same b3 body (name survives)",
		ground.get_body_name() == "Ground" and ground.get_shape_count() == 1)

	# A shape-def flag with no live setter of its own takes the same route, and
	# a dynamic body keeps its motion across it.
	var flyer := Box3DBody.new()
	flyer.box_size = Vector3.ONE
	flyer.gravity_scale = 0.0
	flyer.position = Vector3(20, 5, 0)
	world.add_child(flyer)
	await get_tree().physics_frame
	flyer.set_body_name("Flyer")
	flyer.set_linear_velocity(Vector3(2, 0, 0))
	await get_tree().physics_frame
	var fvel: Vector3 = flyer.get_linear_velocity()
	flyer.explosion_scale = 3.0
	_check("a shape-def-only property keeps the body and its velocity",
		flyer.get_body_name() == "Flyer"
		and flyer.get_linear_velocity().distance_to(fvel) < 0.001
		and absf(flyer.get_explosion_scale() - 3.0) < 0.001)

	world.free()


func _test_shape_set_mesh() -> void:
	var world := Box3DWorld.new()
	add_child(world)

	# P-023's last call. A Box3DCollisionShape authors a box; b3Shape_SetMesh
	# retypes that shape into a triangle mesh in place, and the node takes
	# ownership of the b3MeshData blob the solver keeps a pointer to.
	var ground := Box3DBody.new()
	ground.body_type = Box3DBody.STATIC
	var cs := Box3DCollisionShape.new()
	cs.box_size = Vector3(1, 1, 1)
	ground.add_child(cs)
	# A second child that stays a box, so the body is a real compound and the
	# retyped child has a neighbour to be told apart from.
	var side := Box3DCollisionShape.new()
	side.box_size = Vector3(1, 1, 1)
	side.position = Vector3(20, 0, 0)
	ground.add_child(side)
	world.add_child(ground)
	await get_tree().physics_frame

	# A flat quad 2 m up, wound CCW like Box3DBody.mesh_indices takes it.
	var verts := PackedVector3Array([
		Vector3(-5, 2, -5), Vector3(-5, 2, 5), Vector3(5, 2, 5), Vector3(5, 2, -5)])
	var tris := PackedInt32Array([0, 1, 2, 2, 3, 0])
	_check("set_mesh retypes a live shape into a mesh",
		cs.set_mesh(verts, tris) and cs.get_geometry_type() == Box3DCollisionShape.GEOMETRY_MESH)
	var mesh_info: Dictionary = cs.get_mesh()
	_check("the retyped shape reports its own triangles (%d verts, %d tris)"
			% [int(mesh_info.get("vertex_count", 0)), int(mesh_info.get("triangle_count", 0))],
		int(mesh_info.get("vertex_count", 0)) == 4 and int(mesh_info.get("triangle_count", 0)) == 2)
	_check("the sibling shape is untouched by the retype",
		side.get_geometry_type() == Box3DCollisionShape.GEOMETRY_HULL
		and ground.get_shape_count() == 2)

	var ball := Box3DBody.new()
	ball.shape_type = Box3DBody.SPHERE
	ball.sphere_radius = 0.5
	ball.can_sleep = false
	ball.position = Vector3(0, 6, 0)
	world.add_child(ball)
	for i in range(120):
		await get_tree().physics_frame
	_check("the retyped mesh collides and holds the ball (%.2f)" % ball.position.y,
		absf(ball.position.y - 2.5) < 0.1)

	# b3Shape_SetMesh's scale argument is the only route to moving a mesh
	# collider's scale after creation (P-024 bakes it at creation), so a quarter
	# scale on Y drops the surface from 2 m to 0.5 m and the ball with it.
	_check("set_mesh_scale rescales the mesh in place", cs.set_mesh_scale(Vector3(1, 0.25, 1)))
	for i in range(120):
		await get_tree().physics_frame
	_check("the rescaled mesh is where the scale puts it (%.2f)" % ball.position.y,
		absf(ball.position.y - 1.0) < 0.1)
	_check("a rescaled mesh keeps its triangles",
		int(cs.get_mesh().get("triangle_count", 0)) == 2)

	# The blob is the node's, so a shape rebuild has to free it and go back to
	# the authored box without taking the world with it.
	ground.explosion_scale = 2.0
	await get_tree().physics_frame
	_check("a shape rebuild drops the mesh and restores the authored box",
		cs.get_geometry_type() == Box3DCollisionShape.GEOMETRY_HULL
		and ground.get_shape_count() == 2)

	# Nothing may reach b3Shape_SetMesh with data it would assert on.
	_check("set_mesh refuses a degenerate index list",
		not cs.set_mesh(verts, PackedInt32Array([0, 1])))
	_check("set_mesh refuses an out-of-range index",
		not cs.set_mesh(verts, PackedInt32Array([0, 1, 9])))
	_check("set_mesh refuses a zero scale",
		not cs.set_mesh(verts, tris, Vector3.ZERO))
	_check("set_mesh_scale refuses a shape that is not a mesh",
		not cs.set_mesh_scale(Vector3(2, 2, 2)))

	world.free()


func _test_body_event_enables() -> void:
	# P-009's last property. A body's own shape had enableSensorEvents and
	# enableHitEvents hardcoded true at every creation site; both are properties
	# now, pushed live through b3Shape_Enable{Sensor,Hit}Events.
	var world := Box3DWorld.new()
	add_child(world)
	var hits: Array = []
	world.contact_hit.connect(func(h: Dictionary) -> void: hits.append(h))

	var ground := Box3DBody.new()
	ground.body_type = Box3DBody.STATIC
	ground.box_size = Vector3(20, 1, 20)
	ground.position = Vector3(0, -0.5, 0)
	world.add_child(ground)

	# Hit events are a property of the PAIR: box3d reports one if either shape
	# has them on (src/contact.c:715), so silencing an impact takes both.
	ground.hit_events = false
	var quiet := Box3DBody.new()
	quiet.shape_type = Box3DBody.SPHERE
	quiet.sphere_radius = 0.5
	quiet.hit_events = false
	quiet.position = Vector3(0, 8, 0)
	world.add_child(quiet)
	for i in range(180):
		await get_tree().physics_frame
	_check("hit_events off on both shapes silences the impact (%d hits, landed %.2f)"
			% [hits.size(), quiet.position.y],
		hits.is_empty() and absf(quiet.position.y - 0.5) < 0.2)

	# Back on, live, on ONE side only: the pair rule says that is enough, and
	# the push must not disturb the body it goes through. The velocity is
	# snapshotted BEFORE the property write, or the check compares a value with
	# itself.
	quiet.set_linear_velocity(Vector3(0, 12, 0))
	quiet.set_body_name("Quiet")
	var vel: Vector3 = quiet.get_linear_velocity()
	quiet.hit_events = true
	_check("turning hit_events on does not disturb the body",
		quiet.get_linear_velocity().distance_to(vel) < 0.001
		and quiet.get_body_name() == "Quiet" and quiet.get_shape_count() == 1)
	for i in range(240):
		await get_tree().physics_frame
	_check("one shape with hit_events on is enough to report the impact (%d)"
			% hits.size(),
		hits.size() > 0)
	world.free()

	# sensor_events is what makes a body visible to somebody else's sensor.
	var world2 := Box3DWorld.new()
	add_child(world2)
	var seen: Array = []
	var trigger := Box3DBody.new()
	trigger.body_type = Box3DBody.STATIC
	trigger.is_sensor = true
	trigger.box_size = Vector3(4, 4, 4)
	trigger.position = Vector3(0, 2, 0)
	trigger.area_entered.connect(func(b: Box3DBody) -> void: seen.append(b))
	world2.add_child(trigger)

	var invisible := Box3DBody.new()
	invisible.sensor_events = false
	invisible.position = Vector3(0, 8, 0)
	world2.add_child(invisible)
	var visible := Box3DBody.new()
	visible.position = Vector3(2, 8, 0)
	world2.add_child(visible)
	for i in range(120):
		await get_tree().physics_frame
	_check("sensor_events off hides a body from a sensor it falls through (%d seen)"
			% seen.size(),
		seen.size() == 1 and seen[0] == visible and invisible.position.y < -2.0)

	# A child shape that answers for itself keeps its answer when the body
	# pushes its own (P-019's EventMode beats the body's inheritance).
	var carrier := Box3DBody.new()
	carrier.gravity_scale = 0.0
	carrier.position = Vector3(30, 2, 0)
	var loud := Box3DCollisionShape.new()
	loud.sensor_events = Box3DCollisionShape.EVENT_ENABLED
	carrier.add_child(loud)
	var inherit := Box3DCollisionShape.new()
	inherit.position = Vector3(3, 0, 0)
	carrier.add_child(inherit)
	world2.add_child(carrier)
	await get_tree().physics_frame
	carrier.sensor_events = false
	_check("a body's sensor_events reaches an inheriting child shape",
		not inherit.are_sensor_events_enabled())
	_check("a child shape that answers for itself keeps its answer",
		loud.are_sensor_events_enabled())
	world2.free()


func _test_body_introspection() -> void:
	# P-001 / P-016's leftovers: b3Shape_GetBody, b3Shape_GetWorld,
	# b3Body_GetJoints and b3Body_GetWorld, resolved back to the scene tree, plus
	# the name a body's own shape never had.
	var world := Box3DWorld.new()
	add_child(world)

	var anchor := Box3DBody.new()
	anchor.name = "Anchor"
	anchor.body_type = Box3DBody.STATIC
	anchor.position = Vector3(0, 4, 0)
	world.add_child(anchor)

	var compound := Box3DBody.new()
	compound.name = "Compound"
	compound.position = Vector3(0, 2, 0)
	var left := Box3DCollisionShape.new()
	left.name = "Left"
	compound.add_child(left)
	var right := Box3DCollisionShape.new()
	right.name = "Right"
	right.position = Vector3(2, 0, 0)
	compound.add_child(right)
	world.add_child(compound)

	var joint := Box3DDistanceJoint.new()
	joint.name = "Tether"
	joint.body_a = NodePath("../Anchor")
	joint.body_b = NodePath("../Compound")
	joint.length = 2.0
	world.add_child(joint)
	await get_tree().physics_frame

	_check("get_shape_nodes hands back the authoring shape nodes",
		compound.get_shape_nodes().size() == 2
		and compound.get_shape_nodes().has(left)
		and compound.get_shape_nodes().has(right))
	_check("get_joints hands back the joint node attached to the body",
		compound.get_joints().size() == 1 and compound.get_joints()[0] == joint
		and compound.get_joint_count() == 1)
	_check("get_world hands back the simulating world node",
		compound.get_world() == world and anchor.get_world() == world)

	# The shape side of the same question, which is what a query result or a
	# contact event hands a script.
	_check("a shape resolves its own body and world",
		left.get_body() == compound and left.get_world() == world)

	# A plain body has no shape NODE, and must not pretend otherwise.
	var plain := Box3DBody.new()
	plain.name = "PlainBox"
	plain.position = Vector3(10, 2, 0)
	world.add_child(plain)
	await get_tree().physics_frame
	_check("a body's own shape has no node to hand back",
		plain.get_shape_count() == 1 and plain.get_shape_nodes().is_empty()
		and plain.get_joints().is_empty())

	# ...but it does have a name now, taken from the node, so upstream's shape
	# names and solver logs read the same for a plain body as for a compound.
	var hit: Dictionary = world.raycast(Vector3(10, 6, 0), Vector3(10, 0, 0))
	_check("a ray finds the plain body", bool(hit.get("hit", false)))
	var names: PackedStringArray = plain.get_shape_names()
	_check("a body's own shape is named after the node (%s)" % str(names),
		names.size() == 1 and names[0] == "PlainBox")
	_check("a compound child's shape keeps its own node name",
		compound.get_shape_names().has("Left") and left.get_shape_name() == "Left")

	# A shape with no live shape behind it answers nothing rather than
	# resolving through a stale id. (A node still parented to a freed world
	# would be freed with it, so this one is deliberately unparented.)
	var orphan := Box3DCollisionShape.new()
	_check("a shape node with no body resolves to nothing",
		orphan.get_body() == null and orphan.get_world() == null
		and not orphan.is_shape_valid())
	orphan.free()
	world.free()


func _test_static_utility_classes() -> void:
	# P-042 / P-043 were bound and compiled but never registered, which makes a
	# class invisible to GDScript however complete its bindings are (the P-037
	# lesson). class_exists is the assertion that would have caught it.
	_check("Box3DGeometry is registered and reachable from script",
		ClassDB.class_exists("Box3DGeometry"))
	_check("Box3DCollision is registered and reachable from script",
		ClassDB.class_exists("Box3DCollision"))

	# And the methods behind the registration do real work. A unit box hull has
	# 8 points and 12 triangles' worth of faces.
	var cube: Dictionary = Box3DGeometry.make_box_hull(Vector3(0.5, 0.5, 0.5))
	var cube_points: PackedVector3Array = cube.get("vertices", PackedVector3Array())
	_check("make_box_hull builds the eight corners of a unit box (%d)" % cube_points.size(),
		cube_points.size() == 8)

	var grid: Dictionary = Box3DGeometry.create_grid_mesh(3, 3, 1.0)
	var grid_idx: PackedInt32Array = grid.get("indices", PackedInt32Array())
	# 3 x 3 CELLS, two triangles each.
	_check("create_grid_mesh tessellates a 3x3 grid into 18 triangles (%d)"
			% (grid_idx.size() / 3),
		grid_idx.size() / 3 == 18)

	# b3ComputeSphereMass: a unit-radius, unit-density ball weighs 4/3 pi.
	var ball_mass: Dictionary = Box3DCollision.compute_sphere_mass(Vector3.ZERO, 1.0, 1.0)
	_check("compute_sphere_mass is 4/3 pi r^3 (%.4f)" % float(ball_mass["mass"]),
		absf(float(ball_mass["mass"]) - 4.18879) < 0.001)

	# A ray from 5 m out at a unit sphere hits its near face at x = -1, two
	# fifths of the way along.
	var shot: Dictionary = Box3DCollision.ray_cast_sphere(
		Vector3.ZERO, 1.0, Vector3(-5, 0, 0), Vector3(10, 0, 0))
	_check("ray_cast_sphere hits the near surface (%.2f at %.2f)"
			% [float(shot["position"].x), float(shot["fraction"])],
		bool(shot["hit"]) and absf(float(shot["position"].x) + 1.0) < 0.01
		and absf(float(shot["fraction"]) - 0.4) < 0.01)

	# b3ShapeDistance between two unit boxes 3 m apart on X: 2 m of gap.
	var gap: Dictionary = Box3DCollision.shape_distance(
		cube_points, 0.0, cube_points, 0.0, Transform3D(Basis(), Vector3(3, 0, 0)))
	_check("shape_distance measures the gap between two hulls (%.3f)"
			% float(gap["distance"]),
		absf(float(gap["distance"]) - 2.0) < 0.01)


func _test_contact_handles() -> void:
	var world := Box3DWorld.new()
	add_child(world)
	var begins: Array = []
	var ends: Array = []
	var hits: Array = []
	world.contact_began.connect(func(c: Dictionary) -> void: begins.append(c))
	world.contact_ended.connect(func(c: Dictionary) -> void: ends.append(c))
	world.contact_hit.connect(func(h: Dictionary) -> void: hits.append(h))

	var ground := Box3DBody.new()
	ground.name = "CHGround"
	ground.body_type = Box3DBody.STATIC
	ground.shape_type = Box3DBody.BOX
	ground.box_size = Vector3(20, 1, 20)
	ground.position = Vector3(0, -0.5, 0)
	ground.contact_monitor = true
	world.add_child(ground)

	var ball := Box3DBody.new()
	ball.name = "CHBall"
	ball.shape_type = Box3DBody.SPHERE
	ball.sphere_radius = 0.5
	ball.position = Vector3(0, 4, 0)
	ball.contact_monitor = true
	world.add_child(ball)

	for i in range(120):
		await get_tree().physics_frame

	_check("contact_began fired (%d)" % begins.size(), begins.size() > 0)
	_check("contact_hit carries a handle", hits.size() > 0 and hits[0].has("contact_id"))
	if begins.size() > 0:
		var c: Dictionary = begins[0]
		print("  handle=%s bodies=%s/%s" % [c["contact_id"], c["body_a"], c["body_b"]])
		_check("begin names both bodies", c["body_a"] != null and c["body_b"] != null)
		_check("handle is a Vector3i", typeof(c["contact_id"]) == TYPE_VECTOR3I)
		var id: Vector3i = c["contact_id"]
		_check("handle is live", world.is_contact_valid(id))
		var data: Dictionary = world.get_contact_data(id)
		print("  data=%s" % data)
		_check("data names the same pair",
			data["body_a"] == c["body_a"] and data["body_b"] == c["body_b"])
		_check("data is touching with points",
			data["touching"] and (data["points"] as Array).size() > 0)
		_check("data normal is vertical (%.2f)" % absf(data["normal"].y),
			absf(data["normal"].y) > 0.9)
		var pt: Dictionary = (data["points"] as Array)[0]
		_check("point is at the resting contact (%.2f)" % pt["position"].y,
			absf(pt["position"].y) < 0.2)
		_check("point carries an impulse (%.3f)" % pt["impulse"], pt["impulse"] > 0.0)
		_check("garbage handle is invalid", not world.is_contact_valid(Vector3i(9999, 0, 0)))
		_check("garbage handle yields an empty dictionary",
			world.get_contact_data(Vector3i(9999, 0, 0)).is_empty())

		# The pair separating must invalidate nothing about the API contract:
		# an end event arrives and the handle stops resolving.
		ball.set_linear_velocity(Vector3(0, 12, 0))
		for i in range(30):
			await get_tree().physics_frame
		_check("contact_ended fired (%d)" % ends.size(), ends.size() > 0)
		if ends.size() > 0:
			var e: Dictionary = ends[0]
			_check("end carries the same handle", e["contact_id"] == id)
			_check("the handle is stale once the contact is gone",
				not world.is_contact_valid(e["contact_id"]))
	world.free()


func _test_proxy_queries() -> void:
	var world := Box3DWorld.new()
	add_child(world)
	# A single static box at the origin, 2 m on a side.
	var box := Box3DBody.new()
	box.name = "ProxyBox"
	box.body_type = Box3DBody.STATIC
	box.shape_type = Box3DBody.BOX
	box.box_size = Vector3(2, 2, 2)
	box.collision_layer = 1 << 1
	box.collision_mask = 1 << 2
	world.add_child(box)
	await get_tree().physics_frame

	# Capsule proxy: a tilted capsule that clips the box, and one that misses.
	var hitres: Array = world.overlap_capsule(Vector3(-3, 0, 0), Vector3(-0.5, 0.5, 0), 0.5)
	var missres: Array = world.overlap_capsule(Vector3(-6, 0, 0), Vector3(-4, 3, 0), 0.5)
	_check("overlap_capsule finds the box (%d)" % hitres.size(), hitres.size() == 1 and hitres[0] == box)
	_check("overlap_capsule misses when clear (%d)" % missres.size(), missres.is_empty())
	# Radius matters: a zero-radius segment ending 0.4 m short misses.
	var thin: Array = world.overlap_capsule(Vector3(-3, 0, 0), Vector3(-1.4, 0, 0), 0.0)
	_check("overlap_capsule respects the radius (%d)" % thin.size(), thin.is_empty())

	# Convex proxy: a tetrahedron poking into the box, then one clear of it.
	var tet := PackedVector3Array([
		Vector3(-2.5, 0, 0), Vector3(-0.5, 0, 0), Vector3(-2.5, 1, 0), Vector3(-2.5, 0, 1)])
	var far_tet := PackedVector3Array([
		Vector3(-9, 0, 0), Vector3(-8, 0, 0), Vector3(-9, 1, 0), Vector3(-9, 0, 1)])
	_check("overlap_convex finds the box", world.overlap_convex(tet).size() == 1)
	_check("overlap_convex misses when clear", world.overlap_convex(far_tet).is_empty())

	# Both filter halves reach the new queries.
	_check("overlap_capsule honours the query mask",
		world.overlap_capsule(Vector3(-3, 0, 0), Vector3(-0.5, 0.5, 0), 0.5, 1 << 0).is_empty())
	_check("overlap_convex honours the query layer",
		world.overlap_convex(tet, ~0, 1 << 0).is_empty())

	# Casts: sweep from the left, hit the -X face at x = -1.
	var cap_hit: Dictionary = world.shape_cast_capsule(
		Vector3(-6, -0.5, 0), Vector3(-6, 0.5, 0), 0.5, Vector3(10, 0, 0))
	_check("shape_cast_capsule hits (%s)" % cap_hit["hit"], cap_hit["hit"])
	if cap_hit["hit"]:
		_check("shape_cast_capsule stops at the face (%.3f)" % cap_hit["position"].x,
			absf(cap_hit["position"].x + 1.0) < 0.05 and cap_hit["collider"] == box)
		_check("shape_cast_capsule normal points back along the sweep (%.2f)" % cap_hit["normal"].x,
			cap_hit["normal"].x < -0.9)
	var conv_hit: Dictionary = world.shape_cast_convex(
		PackedVector3Array([Vector3(-6, 0, 0), Vector3(-5, 0, 0), Vector3(-6, 1, 0), Vector3(-6, 0, 1)]),
		Vector3(10, 0, 0))
	_check("shape_cast_convex hits (%s)" % conv_hit["hit"], conv_hit["hit"])
	var cap_miss: Dictionary = world.shape_cast_capsule(
		Vector3(-6, 8, 0), Vector3(-6, 9, 0), 0.5, Vector3(10, 0, 0))
	_check("shape_cast_capsule misses over the top", not cap_miss["hit"])

	# b3TreeStats: the miss above walked the tree without reaching a leaf.
	var miss_stats: Dictionary = world.get_last_query_stats()
	print("  miss stats=%s" % miss_stats)
	_check("a missed cast reports node visits and no leaf (%d/%d)" % [miss_stats["node_visits"], miss_stats["leaf_visits"]],
		miss_stats["node_visits"] >= 1 and miss_stats["leaf_visits"] == 0)
	world.overlap_convex(tet)
	var hit_stats: Dictionary = world.get_last_query_stats()
	print("  hit stats=%s" % hit_stats)
	_check("a hitting overlap reports a leaf visit (%d/%d)" % [hit_stats["node_visits"], hit_stats["leaf_visits"]],
		hit_stats["leaf_visits"] >= 1)
	world.raycast(Vector3(-6, 0, 0), Vector3(6, 0, 0))
	var ray_stats: Dictionary = world.get_last_query_stats()
	_check("the closest-hit ray reports stats too (%d/%d)" % [ray_stats["node_visits"], ray_stats["leaf_visits"]],
		ray_stats["leaf_visits"] >= 1)
	world.free()


func _test_length_units() -> void:
	_check("length units default to 1 m",
		is_equal_approx(Box3DWorld.get_length_units_per_meter(), 1.0))
	_check("the project setting exists",
		ProjectSettings.has_setting("physics/box3d/length_units_per_meter"))
	print("  setting=%s" % ProjectSettings.get_setting("physics/box3d/length_units_per_meter"))
	var world := Box3DWorld.new()
	add_child(world)
	world.step(1.0 / 60.0)
	_check("a live world blocks a scale change",
		not Box3DWorld.set_length_units_per_meter(2.0)
		and is_equal_approx(Box3DWorld.get_length_units_per_meter(), 1.0))
	world.free()
	_check("a negative scale is refused", not Box3DWorld.set_length_units_per_meter(-1.0))
	if Box3DWorld.get_world_count() == 0:
		_check("with no world alive the scale can be set",
			Box3DWorld.set_length_units_per_meter(1.0)
			and is_equal_approx(Box3DWorld.get_length_units_per_meter(), 1.0))


func _test_geometry() -> void:
	var rock: Dictionary = Box3DGeometry.create_rock(0.3)
	print("  rock=%d verts %d tris" % [rock["vertices"].size(), rock["indices"].size() / 3])
	_check("create_rock returns the 10-point lattice hull (%d)" % rock["vertices"].size(),
		rock["vertices"].size() == 10 and rock["indices"].size() >= 24)
	var far := 0.0
	for v in rock["vertices"]:
		far = maxf(far, v.length())
	_check("rock points sit on the 0.3 m sphere (%.3f)" % far, absf(far - 0.3) < 0.001)

	var cube: Dictionary = Box3DGeometry.make_cube_hull(0.5)
	print("  cube=%d verts %d tris" % [cube["vertices"].size(), cube["indices"].size() / 3])
	_check("make_cube_hull is 8 points and 12 triangles",
		cube["vertices"].size() == 8 and cube["indices"].size() == 36)
	var bx: Dictionary = Box3DGeometry.make_box_hull(Vector3(1, 2, 3))
	var lo := Vector3.INF
	var hi := -Vector3.INF
	for v in bx["vertices"]:
		lo = lo.min(v)
		hi = hi.max(v)
	_check("make_box_hull spans the half extents (%s..%s)" % [lo, hi],
		lo.is_equal_approx(Vector3(-1, -2, -3)) and hi.is_equal_approx(Vector3(1, 2, 3)))
	var off: Dictionary = Box3DGeometry.make_offset_box_hull(Vector3(0.5, 0.5, 0.5), Vector3(10, 0, 0))
	var centre := Vector3.ZERO
	for v in off["vertices"]:
		centre += v
	centre /= off["vertices"].size()
	_check("make_offset_box_hull is centred on the offset (%s)" % centre,
		centre.is_equal_approx(Vector3(10, 0, 0)))

	var xf := Transform3D(Basis(Vector3.UP, PI / 2.0), Vector3(1, 0, 0))
	var tb: Dictionary = Box3DGeometry.make_transformed_box_hull(Vector3(0.5, 0.5, 0.5), xf)
	var tc := Vector3.ZERO
	for v in tb["vertices"]:
		tc += v
	tc /= tb["vertices"].size()
	_check("make_transformed_box_hull carries the transform (%s)" % tc, tc.is_equal_approx(Vector3(1, 0, 0)))
	var sc: Dictionary = Box3DGeometry.make_scaled_box_hull(Vector3(0.5, 0.5, 0.5), Transform3D(), Vector3(4, 1, 1))
	var slo := Vector3.INF
	var shi := -Vector3.INF
	for v in sc["vertices"]:
		slo = slo.min(v)
		shi = shi.max(v)
	_check("make_scaled_box_hull applies the post scale (%s)" % shi,
		absf(shi.x - 2.0) < 0.001 and absf(shi.y - 0.5) < 0.001)
	var resolved: Dictionary = Box3DGeometry.scale_box(Vector3(0.5, 0.5, 0.5), Transform3D(), Vector3(4, 1, 1), 0.005)
	print("  scale_box=%s" % resolved)
	_check("scale_box resolves the scale into half extents (%s)" % resolved["half_extents"],
		absf(resolved["half_extents"].x - 2.0) < 0.001)

	# Hull of a point cloud, and the same cloud transformed.
	var cloud := PackedVector3Array([
		Vector3(-1, -1, -1), Vector3(1, -1, -1), Vector3(1, 1, -1), Vector3(-1, 1, -1),
		Vector3(-1, -1, 1), Vector3(1, -1, 1), Vector3(1, 1, 1), Vector3(-1, 1, 1),
		Vector3.ZERO])
	var hull: Dictionary = Box3DGeometry.create_hull(cloud)
	_check("create_hull drops the interior point (%d)" % hull["vertices"].size(),
		hull["vertices"].size() == 8)
	var moved: Dictionary = Box3DGeometry.transform_hull(cloud, Transform3D(Basis(), Vector3(5, 0, 0)), Vector3(2, 1, 1))
	var mhi := -Vector3.INF
	var mlo := Vector3.INF
	for v in moved["vertices"]:
		mhi = mhi.max(v)
		mlo = mlo.min(v)
	print("  transform_hull=%s..%s" % [mlo, mhi])
	_check("transform_hull scales then places the hull (%s)" % mhi,
		absf(mhi.x - 7.0) < 0.001 and absf(mlo.x - 3.0) < 0.001 and absf(mhi.y - 1.0) < 0.001)

	# Meshes.
	var grid: Dictionary = Box3DGeometry.create_grid_mesh(4, 4, 1.0, 2, true)
	print("  grid=%d verts %d tris mats %d height %d" % [grid["vertices"].size(),
		grid["indices"].size() / 3, grid["materials"].size(), grid["bvh_height"]])
	_check("create_grid_mesh builds a 4x4 grid (%d tris)" % (grid["indices"].size() / 3),
		grid["indices"].size() / 3 == 32 and grid["vertices"].size() == 25)
	_check("create_grid_mesh reports one material per triangle",
		grid["materials"].size() == grid["indices"].size() / 3)
	_check("the grid mesh reports its BVH height (%d)" % grid["bvh_height"], grid["bvh_height"] > 0)
	var wave: Dictionary = Box3DGeometry.create_wave_mesh(8, 8, 1.0, 2.0, 0.25, 0.25)
	var wlo := 1e9
	var whi := -1e9
	for v in wave["vertices"]:
		wlo = minf(wlo, v.y)
		whi = maxf(whi, v.y)
	_check("create_wave_mesh displaces the grid in Y (%.2f..%.2f)" % [wlo, whi],
		absf(whi - 2.0) < 0.01 and absf(wlo + 2.0) < 0.01)
	# A whole number of cycles per cell samples the sine only at its zeros.
	var flat: Dictionary = Box3DGeometry.create_wave_mesh(8, 8, 1.0, 2.0, 1.0, 1.0)
	var flat_max := 0.0
	for v in flat["vertices"]:
		flat_max = maxf(flat_max, absf(v.y))
	_check("wave frequency is cycles per CELL, so 1.0 is flat (%.4f)" % flat_max, flat_max < 0.001)
	var torus: Dictionary = Box3DGeometry.create_torus_mesh(8, 6, 2.0, 0.5)
	_check("create_torus_mesh returns a closed tube (%d tris)" % (torus["indices"].size() / 3),
		torus["indices"].size() / 3 == 96 and torus["vertices"].size() == 48)
	var boxm: Dictionary = Box3DGeometry.create_box_mesh(Vector3.ZERO, Vector3(1, 1, 1), true)
	_check("create_box_mesh is 12 triangles (%d)" % (boxm["indices"].size() / 3),
		boxm["indices"].size() / 3 == 12)
	var hollow: Dictionary = Box3DGeometry.create_hollow_box_mesh(Vector3.ZERO, Vector3(2, 2, 2))
	_check("create_hollow_box_mesh returns a room (%d tris)" % (hollow["indices"].size() / 3),
		hollow["indices"].size() / 3 >= 12)
	var plat: Dictionary = Box3DGeometry.create_platform_mesh(Vector3.ZERO, 1.0, 1.0, 2.0)
	_check("create_platform_mesh returns a truncated pyramid (%d tris)" % (plat["indices"].size() / 3),
		plat["indices"].size() / 3 >= 12)

	# The bridge back to Godot.
	var mesh: ArrayMesh = Box3DGeometry.make_array_mesh(rock)
	_check("make_array_mesh returns a drawable surface",
		mesh != null and mesh.get_surface_count() == 1
		and mesh.get_faces().size() == rock["indices"].size())
	_check("make_array_mesh keeps the hull's extent (%.3f)" % mesh.get_aabb().size.x,
		absf(mesh.get_aabb().size.x - 0.6) < 0.06)


var _cube_points := PackedVector3Array([
	Vector3(-1, -1, -1), Vector3(1, -1, -1), Vector3(1, 1, -1), Vector3(-1, 1, -1),
	Vector3(-1, -1, 1), Vector3(1, -1, 1), Vector3(1, 1, 1), Vector3(-1, 1, 1)])


func _test_collision() -> void:
	# --- rays, analytic answers -------------------------------------------
	var r: Dictionary = Box3DCollision.ray_cast_sphere(Vector3.ZERO, 1.0, Vector3(-5, 0, 0), Vector3(10, 0, 0))
	print("  ray sphere=%s" % r)
	_check("ray_cast_sphere hits the near surface (%.3f)" % r["position"].x,
		r["hit"] and absf(r["position"].x + 1.0) < 0.001 and absf(r["fraction"] - 0.4) < 0.001
		and r["normal"].x < -0.99)
	var inside: Dictionary = Box3DCollision.ray_cast_sphere(Vector3.ZERO, 1.0, Vector3.ZERO, Vector3(5, 0, 0))
	_check("a ray starting inside a solid sphere hits at zero fraction",
		inside["hit"] and absf(inside["fraction"]) < 0.001)
	var shell: Dictionary = Box3DCollision.ray_cast_hollow_sphere(Vector3.ZERO, 1.0, Vector3.ZERO, Vector3(5, 0, 0))
	_check("a hollow sphere lets the same ray through to the far wall (%.3f)" % shell["position"].x,
		shell["hit"] and absf(shell["position"].x - 1.0) < 0.001)
	var rc: Dictionary = Box3DCollision.ray_cast_capsule(
		Vector3(-1, 0, 0), Vector3(1, 0, 0), 0.5, Vector3(0, 5, 0), Vector3(0, -10, 0))
	_check("ray_cast_capsule lands on the barrel (%.3f)" % rc["position"].y,
		rc["hit"] and absf(rc["position"].y - 0.5) < 0.001 and rc["normal"].y > 0.99)
	var rh: Dictionary = Box3DCollision.ray_cast_hull(_cube_points, Vector3(-5, 0, 0), Vector3(10, 0, 0))
	_check("ray_cast_hull lands on the -X face (%.3f)" % rh["position"].x,
		rh["hit"] and absf(rh["position"].x + 1.0) < 0.001)
	_check("is_valid_ray accepts a real ray and rejects NAN",
		Box3DCollision.is_valid_ray(Vector3.ZERO, Vector3(1, 0, 0))
		and not Box3DCollision.is_valid_ray(Vector3.ZERO, Vector3(NAN, 0, 0)))

	# --- shape casts -------------------------------------------------------
	var point := PackedVector3Array([Vector3(-5, 0, 0)])
	var sc: Dictionary = Box3DCollision.shape_cast_sphere(Vector3.ZERO, 1.0, point, 0.5, Vector3(10, 0, 0))
	print("  shape cast sphere=%s" % sc)
	_check("shape_cast_sphere stops a 0.5 m probe 1.5 m out (%.3f)" % sc["fraction"],
		sc["hit"] and absf(sc["fraction"] - 0.35) < 0.005)
	var sch: Dictionary = Box3DCollision.shape_cast_hull(_cube_points, point, 0.5, Vector3(10, 0, 0))
	_check("shape_cast_hull stops at the face (%.3f)" % sch["fraction"],
		sch["hit"] and absf(sch["fraction"] - 0.35) < 0.005)
	var scc: Dictionary = Box3DCollision.shape_cast_capsule(
		Vector3(0, -1, 0), Vector3(0, 1, 0), 0.5, point, 0.5, Vector3(10, 0, 0))
	_check("shape_cast_capsule stops at the barrel (%.3f)" % scc["fraction"],
		scc["hit"] and absf(scc["fraction"] - 0.4) < 0.005)

	# --- overlaps ----------------------------------------------------------
	_check("overlap_sphere sees a point inside",
		Box3DCollision.overlap_sphere(Vector3.ZERO, 1.0, Transform3D(), PackedVector3Array([Vector3(0.5, 0, 0)]), 0.0))
	_check("overlap_sphere rejects a point outside",
		not Box3DCollision.overlap_sphere(Vector3.ZERO, 1.0, Transform3D(), PackedVector3Array([Vector3(2, 0, 0)]), 0.0))
	_check("the overlap transform moves the primitive",
		Box3DCollision.overlap_sphere(Vector3.ZERO, 1.0, Transform3D(Basis(), Vector3(2, 0, 0)),
			PackedVector3Array([Vector3(2, 0, 0)]), 0.0))
	_check("overlap_capsule sees a point on the barrel",
		Box3DCollision.overlap_capsule(Vector3(-1, 0, 0), Vector3(1, 0, 0), 0.5, Transform3D(),
			PackedVector3Array([Vector3(0, 0.4, 0)]), 0.0))
	_check("overlap_hull sees a point inside the cube",
		Box3DCollision.overlap_hull(_cube_points, Transform3D(), PackedVector3Array([Vector3(0.5, 0.5, 0.5)]), 0.0)
		and not Box3DCollision.overlap_hull(_cube_points, Transform3D(), PackedVector3Array([Vector3(3, 0, 0)]), 0.0))

	# --- the generic pair queries ------------------------------------------
	var one := PackedVector3Array([Vector3.ZERO])
	var d: Dictionary = Box3DCollision.shape_distance(one, 1.0, one, 1.0, Transform3D(Basis(), Vector3(5, 0, 0)))
	print("  distance=%s" % d)
	_check("shape_distance subtracts both radii (%.3f)" % d["distance"],
		absf(d["distance"] - 3.0) < 0.001 and d["normal"].x > 0.99
		and absf(d["point_a"].x - 1.0) < 0.001 and absf(d["point_b"].x - 4.0) < 0.001)
	var dn: Dictionary = Box3DCollision.shape_distance(one, 1.0, one, 1.0, Transform3D(Basis(), Vector3(5, 0, 0)), false)
	_check("use_radii false measures the point clouds (%.3f)" % dn["distance"],
		absf(dn["distance"] - 5.0) < 0.001)
	var overlapped: Dictionary = Box3DCollision.shape_distance(one, 1.0, one, 1.0, Transform3D(Basis(), Vector3(1, 0, 0)))
	_check("overlapping proxies report zero distance", absf(overlapped["distance"]) < 0.001)
	var pair: Dictionary = Box3DCollision.shape_cast(one, 1.0, one, 0.5,
		Transform3D(Basis(), Vector3(-5, 0, 0)), Vector3(10, 0, 0))
	_check("shape_cast finds the same 0.35 fraction (%.3f)" % pair["fraction"],
		pair["hit"] and absf(pair["fraction"] - 0.35) < 0.005)
	var toi: Dictionary = Box3DCollision.time_of_impact(one, 1.0, Transform3D(), Transform3D(),
		one, 0.5, Transform3D(Basis(), Vector3(-5, 0, 0)), Transform3D(Basis(), Vector3(5, 0, 0)))
	print("  toi=%s" % toi)
	_check("time_of_impact reports a hit at 0.35 (%s %.3f)" % [toi["state_name"], toi["fraction"]],
		toi["state"] == Box3DCollision.TOI_HIT and absf(toi["fraction"] - 0.35) < 0.01)
	var apart: Dictionary = Box3DCollision.time_of_impact(one, 1.0, Transform3D(), Transform3D(),
		one, 0.5, Transform3D(Basis(), Vector3(-5, 9, 0)), Transform3D(Basis(), Vector3(5, 9, 0)))
	_check("a sweep that misses reports separated (%s)" % apart["state_name"],
		apart["state"] == Box3DCollision.TOI_SEPARATED)
	var mid: Transform3D = Box3DCollision.get_sweep_transform(
		Transform3D(), Transform3D(Basis(), Vector3(10, 0, 0)), 0.5)
	_check("get_sweep_transform interpolates the sweep (%s)" % mid.origin,
		mid.origin.is_equal_approx(Vector3(5, 0, 0)))

	# --- mass and bounds ---------------------------------------------------
	var sm: Dictionary = Box3DCollision.compute_sphere_mass(Vector3.ZERO, 1.0, 1.0)
	print("  sphere mass=%s" % sm)
	_check("compute_sphere_mass is 4/3 pi r^3 (%.4f)" % sm["mass"],
		absf(sm["mass"] - 4.18879) < 0.001 and absf(sm["inertia"][0].x - 1.67552) < 0.001)
	var cm: Dictionary = Box3DCollision.compute_capsule_mass(Vector3(0, -1, 0), Vector3(0, 1, 0), 0.5, 1.0)
	_check("compute_capsule_mass centres on the axis (%.4f at %s)" % [cm["mass"], cm["center"]],
		cm["mass"] > 1.0 and cm["center"].is_equal_approx(Vector3.ZERO))
	var hm: Dictionary = Box3DCollision.compute_hull_mass(_cube_points, 1.0)
	print("  hull mass=%s" % hm)
	_check("compute_hull_mass gives the 2 m cube its 8 kg (%.4f)" % hm["mass"],
		absf(hm["mass"] - 8.0) < 0.01 and absf(hm["inertia"][0].x - 5.3333) < 0.01)
	var sa: AABB = Box3DCollision.compute_sphere_aabb(Vector3.ZERO, 1.0, Transform3D(Basis(), Vector3(3, 0, 0)))
	_check("compute_sphere_aabb follows the transform (%s)" % sa,
		sa.position.is_equal_approx(Vector3(2, -1, -1)) and sa.size.is_equal_approx(Vector3(2, 2, 2)))
	var ca: AABB = Box3DCollision.compute_capsule_aabb(Vector3(0, -1, 0), Vector3(0, 1, 0), 0.5, Transform3D())
	_check("compute_capsule_aabb spans the caps (%s)" % ca.size,
		ca.size.is_equal_approx(Vector3(1, 3, 1)))
	var ha: AABB = Box3DCollision.compute_hull_aabb(_cube_points, Transform3D())
	_check("compute_hull_aabb spans the cube (%s)" % ha.size, ha.size.is_equal_approx(Vector3(2, 2, 2)))

	# --- manifolds ---------------------------------------------------------
	var ms: Dictionary = Box3DCollision.collide_spheres(Vector3.ZERO, 1.0, Vector3.ZERO, 1.0,
		Transform3D(Basis(), Vector3(1.5, 0, 0)))
	print("  spheres manifold=%s" % ms)
	var msp: Array = ms["points"]
	_check("collide_spheres reports one point 0.5 m deep (%d)" % msp.size(),
		msp.size() == 1 and absf(msp[0]["separation"] + 0.5) < 0.001 and ms["normal"].x > 0.99)
	_check("separated spheres report no points",
		(Box3DCollision.collide_spheres(Vector3.ZERO, 1.0, Vector3.ZERO, 1.0,
			Transform3D(Basis(), Vector3(9, 0, 0)))["points"] as Array).is_empty())
	var mc: Dictionary = Box3DCollision.collide_capsules(Vector3(-1, 0, 0), Vector3(1, 0, 0), 0.5,
		Vector3(-1, 0, 0), Vector3(1, 0, 0), 0.5, Transform3D(Basis(), Vector3(0, 0.9, 0)))
	_check("collide_capsules reports a parallel contact (%d points)" % (mc["points"] as Array).size(),
		(mc["points"] as Array).size() >= 2 and mc["normal"].y > 0.99)
	var mcs: Dictionary = Box3DCollision.collide_capsule_and_sphere(Vector3(-1, 0, 0), Vector3(1, 0, 0), 0.5,
		Vector3.ZERO, 0.5, Transform3D(Basis(), Vector3(0, 0.9, 0)))
	_check("collide_capsule_and_sphere reports the overlap (%d)" % (mcs["points"] as Array).size(),
		(mcs["points"] as Array).size() == 1
		and absf((mcs["points"] as Array)[0]["separation"] + 0.1) < 0.01)
	var mhs: Dictionary = Box3DCollision.collide_hull_and_sphere(_cube_points, Vector3.ZERO, 1.0,
		Transform3D(Basis(), Vector3(1.5, 0, 0)))
	_check("collide_hull_and_sphere reports the face contact (%d)" % (mhs["points"] as Array).size(),
		(mhs["points"] as Array).size() == 1 and mhs["normal"].x > 0.99
		and absf((mhs["points"] as Array)[0]["separation"] + 0.5) < 0.01)
	var mhc: Dictionary = Box3DCollision.collide_hull_and_capsule(_cube_points, Vector3(-1, 0, 0), Vector3(1, 0, 0), 0.5,
		Transform3D(Basis(), Vector3(0, 1.4, 0)))
	_check("collide_hull_and_capsule reports two points (%d)" % (mhc["points"] as Array).size(),
		(mhc["points"] as Array).size() >= 1 and mhc["normal"].y > 0.99)
	var mhh: Dictionary = Box3DCollision.collide_hulls(_cube_points, _cube_points, Transform3D(Basis(), Vector3(1.8, 0, 0)))
	print("  hulls manifold=%d points normal %s" % [(mhh["points"] as Array).size(), mhh["normal"]])
	_check("collide_hulls reports a 4-point face manifold (%d)" % (mhh["points"] as Array).size(),
		(mhh["points"] as Array).size() == 4 and mhh["normal"].x > 0.99
		and absf((mhh["points"] as Array)[0]["separation"] + 0.2) < 0.01)
	# Wound so the face normal is +Y: a mesh triangle is SINGLE SIDED, and a
	# shape behind its back face reports nothing.
	var tri := PackedVector3Array([Vector3(-2, 0, -2), Vector3(0, 0, 2), Vector3(2, 0, -2)])
	var back: Dictionary = Box3DCollision.collide_triangle_and_sphere(
		PackedVector3Array([Vector3(-2, 0, -2), Vector3(2, 0, -2), Vector3(0, 0, 2)]),
		Vector3.ZERO, 1.0, Transform3D(Basis(), Vector3(0, 0.9, 0)))
	_check("a triangle wound away from the shape reports nothing",
		(back["points"] as Array).is_empty())
	var mts: Dictionary = Box3DCollision.collide_triangle_and_sphere(tri, Vector3.ZERO, 1.0,
		Transform3D(Basis(), Vector3(0, 0.9, 0)))
	_check("collide_triangle_and_sphere points from the triangle up (%s)" % mts["normal"],
		(mts["points"] as Array).size() == 1 and mts["normal"].y > 0.99
		and absf((mts["points"] as Array)[0]["separation"] + 0.1) < 0.01)
	var mtc: Dictionary = Box3DCollision.collide_triangle_and_capsule(tri,
		Vector3(-0.5, 0, 0), Vector3(0.5, 0, 0), 0.5, Transform3D(Basis(), Vector3(0, 0.4, 0)))
	_check("collide_triangle_and_capsule reports contact (%d)" % (mtc["points"] as Array).size(),
		(mtc["points"] as Array).size() >= 1 and mtc["normal"].y > 0.99)
	var mth: Dictionary = Box3DCollision.collide_triangle_and_hull(tri, _cube_points,
		Transform3D(Basis(), Vector3(0, 0.9, 0)))
	print("  triangle/hull=%d points normal %s" % [(mth["points"] as Array).size(), mth["normal"]])
	_check("collide_triangle_and_hull reports contact (%d)" % (mth["points"] as Array).size(),
		(mth["points"] as Array).size() >= 1 and mth["normal"].y > 0.99)
	# Degenerate input is a clean empty answer, not an assert.
	_check("a 2-point triangle is refused cleanly",
		(Box3DCollision.collide_triangle_and_sphere(PackedVector3Array([Vector3.ZERO, Vector3.ONE]),
			Vector3.ZERO, 1.0, Transform3D())["points"] as Array).is_empty())
	_check("a 3-point hull is refused cleanly",
		(Box3DCollision.collide_hulls(PackedVector3Array([Vector3.ZERO, Vector3.ONE, Vector3.UP]), _cube_points,
			Transform3D())["points"] as Array).is_empty())


func _test_shape_child_removal() -> void:
	# A Box3DCollisionShape removed from a live body must take its collider with
	# it. Godot 4.7 still lists the leaving node among its parent's children when
	# NOTIFICATION_UNPARENTED fires, so a rebuild driven from there used to build
	# a shape FOR THE DEPARTING NODE and store it as that shape's userData --
	# leaving a collider behind and, once the node was freed, a dangling pointer
	# on every contact and event dispatch.
	var world := Box3DWorld.new()
	add_child(world)

	var body := Box3DBody.new()
	body.body_type = Box3DBody.STATIC
	body.position = Vector3(0, 0, 0)
	var keep := Box3DCollisionShape.new()
	keep.box_size = Vector3.ONE
	body.add_child(keep)
	var doomed := Box3DCollisionShape.new()
	doomed.box_size = Vector3.ONE
	doomed.position = Vector3(4, 0, 0)
	body.add_child(doomed)
	world.add_child(body)
	await get_tree().physics_frame
	_check("the compound starts with both child shapes",
		body.get_shape_count() == 2
		and bool(world.raycast(Vector3(4, 5, 0), Vector3(4, -5, 0))["hit"]))

	body.remove_child(doomed)
	doomed.free()
	await get_tree().physics_frame
	_check("removing a shape child removes its collider (%d shapes)"
			% body.get_shape_count(),
		body.get_shape_count() == 1
		and not bool(world.raycast(Vector3(4, 5, 0), Vector3(4, -5, 0))["hit"]))
	_check("the shape that stayed is still there and still resolves",
		bool(world.raycast(Vector3(0, 5, 0), Vector3(0, -5, 0))["hit"])
		and keep.get_body() == body and body.get_shape_nodes().size() == 1)

	# Nothing may still point at the freed node: a step, a filter push and an
	# event dispatch all walk the shape userData.
	body.collision_layer = 1 << 3
	body.contact_monitor = true
	var ball := Box3DBody.new()
	ball.shape_type = Box3DBody.SPHERE
	ball.sphere_radius = 0.5
	ball.position = Vector3(0, 4, 0)
	world.add_child(ball)
	for i in range(60):
		await get_tree().physics_frame
	_check("the world keeps stepping and dispatching after the removal (%.2f)"
			% ball.position.y,
		ball.position.y < 4.0 and body.get_shape_count() == 1)
	world.free()


func _test_contact_rule_wiring() -> void:
	# engineer-K's Box3DContactRules needs three things from this side: the
	# registration, the two per-shape opt-ins, and a material id on a body's own
	# shape. This covers the wiring only -- K's three behavioural selftests are
	# NOT landed: they crash the harness (free(): invalid size) inside
	# Box3DContactRules itself, which is K's file, not this one. See the board.
	_check("Box3DContactRules is registered and reachable from script",
		ClassDB.class_exists("Box3DContactRules"))

	# The opt-ins, on a shape with no world behind it: enabling pre-solve events
	# on a stepping world with no rule table installed is exactly the upstream
	# hazard K documents (src/solver.c:445-451 calls the callback unchecked).
	var loose := Box3DCollisionShape.new()
	loose.custom_filtering = true
	loose.pre_solve_events = true
	_check("the two contact-rule opt-ins round-trip on a shape",
		loose.custom_filtering and loose.pre_solve_events)
	loose.free()

	var world := Box3DWorld.new()
	add_child(world)
	# A plain body with no shape children: its own shape now carries a material
	# id, which is what a rule table keys on. Observable through a query.
	var ground := Box3DBody.new()
	ground.body_type = Box3DBody.STATIC
	ground.box_size = Vector3(10, 1, 10)
	ground.user_material_id = 77
	world.add_child(ground)
	await get_tree().physics_frame
	var hits: Array = world.raycast_all(Vector3(0, 5, 0), Vector3(0, -5, 0))
	_check("a plain body's own shape carries its user_material_id (%d hits)" % hits.size(),
		hits.size() > 0 and int((hits[0] as Dictionary).get("user_material", 0)) == 77)

	# And it stays live: the setter goes through b3Shape_SetSurfaceMaterial.
	ground.user_material_id = 5
	var again: Array = world.raycast_all(Vector3(0, 5, 0), Vector3(0, -5, 0))
	_check("the material id is a live setter, not a rebuild",
		again.size() > 0 and int((again[0] as Dictionary).get("user_material", 0)) == 5
		and ground.get_shape_count() == 1)
	world.free()


# --- P-007: the contact rule table (engineer-K) -----------------------------
# Behaviour, not wiring: the three things the rule table promises, each proved
# against a control that has no rule. Bodies do not exist in the solver until
# NOTIFICATION_READY, so every helper below is followed by a physics frame
# before anything is asked of the body.

func _rules_shape(material: int, size: Vector3, filtering := false, presolve := false) -> Box3DCollisionShape:
	var shape := Box3DCollisionShape.new()
	shape.shape_type = Box3DCollisionShape.BOX
	shape.box_size = size
	shape.user_material_id = material
	shape.friction = 0.8
	shape.custom_filtering = filtering
	shape.pre_solve_events = presolve
	return shape

func _rules_body(world: Box3DWorld, type: int, material: int, size: Vector3, at: Vector3,
		filtering := false, presolve := false) -> Box3DBody:
	# The collider is a CHILD shape: custom_filtering and pre_solve_events are
	# per-shape opt-ins, and a child must be added before the body joins the
	# world (engineer-A's compound gotcha).
	var body := Box3DBody.new()
	body.body_type = type
	body.add_child(_rules_shape(material, size, filtering, presolve))
	body.position = at
	world.add_child(body)
	return body

# Mixing rules apply to EVERY contact (src/contact.c:646-649), so this needs no
# per-shape flag. Two identical boxes slide on two identical floors; the pair
# with a 0-friction override keeps its speed, the pair mixed by upstream's
# sqrt(fA * fB) is braked.
func _test_contact_rules_friction() -> void:
	var world := Box3DWorld.new()
	add_child(world)
	var rules := Box3DContactRules.new()
	rules.set_friction_rule(11, 12, 0.0)
	rules.install(world)
	_check("a table with a mixing rule claims a bank slot (%d)" % rules.get_mixing_slot(),
		rules.get_mixing_slot() >= 0)
	_check("the friction rule reads back", float(rules.get_rule(11, 12)["friction"]) == 0.0)

	_rules_body(world, Box3DBody.STATIC, 11, Vector3(40, 1, 8), Vector3(0, 0, 0))
	_rules_body(world, Box3DBody.STATIC, 21, Vector3(40, 1, 8), Vector3(0, 0, 20))
	var slick := _rules_body(world, Box3DBody.DYNAMIC, 12, Vector3.ONE, Vector3(-15, 1.0, 0))
	var grippy := _rules_body(world, Box3DBody.DYNAMIC, 22, Vector3.ONE, Vector3(-15, 1.0, 20))
	await get_tree().physics_frame
	await get_tree().physics_frame
	slick.set_linear_velocity(Vector3(6, 0, 0))
	grippy.set_linear_velocity(Vector3(6, 0, 0))
	for i in range(120):
		await get_tree().physics_frame
	var va: float = slick.get_linear_velocity().x
	var vb: float = grippy.get_linear_velocity().x
	print("  friction rule: override=%.3f default=%.3f" % [va, vb])
	_check("a 0-friction pair keeps sliding (%.2f m/s)" % va, va > 4.0)
	_check("the default pair is braked by sqrt(fA*fB) (%.2f m/s)" % vb, vb < va * 0.5)
	world.free()

# A never-collide pair. Needs custom_filtering on at least one shape of the pair
# (src/broad_phase.c:284); the control body differs only in its material id.
func _test_contact_rules_filter() -> void:
	var world := Box3DWorld.new()
	add_child(world)
	var rules := Box3DContactRules.new()
	rules.set_collision_rule(31, 32, false)
	rules.install(world)
	_check("a never-collide rule reads back", not rules.get_collision_rule(31, 32))
	_check("an unauthored pair still collides", rules.get_collision_rule(31, 99))

	_rules_body(world, Box3DBody.STATIC, 31, Vector3(40, 1, 40), Vector3(0, 0, 0), true)
	var ghost := _rules_body(world, Box3DBody.DYNAMIC, 32, Vector3.ONE, Vector3(0, 4, 0), true)
	var solid := _rules_body(world, Box3DBody.DYNAMIC, 99, Vector3.ONE, Vector3(6, 4, 0), true)
	for i in range(120):
		await get_tree().physics_frame
	print("  filter rule: ghost y=%.2f solid y=%.2f" % [ghost.position.y, solid.position.y])
	_check("the filtered pair falls straight through (%.2f)" % ghost.position.y,
		ghost.position.y < -2.0)
	_check("an unruled body lands on the same floor (%.2f)" % solid.position.y,
		solid.position.y > 0.0)
	world.free()

# The one-way platform, with no script in the solver. Needs pre_solve_events on
# at least one shape of the pair (src/contact.c:325). The normal points from
# shape A to shape B (types.h:2627) and the rule is authored platform-first, so
# "within 90 degrees of UP" keeps the resting contact and drops the rising one.
func _test_contact_rules_one_way() -> void:
	var world := Box3DWorld.new()
	add_child(world)
	var rules := Box3DContactRules.new()
	rules.set_one_way_rule(41, 42, Vector3.UP, 90.0)
	rules.install(world)
	var rule: Dictionary = rules.get_rule(41, 42)
	_check("the one-way rule reads back oriented",
		int(rule["one_way_from"]) == 41 and (rule["one_way_axis"] as Vector3).is_equal_approx(Vector3.UP))
	_check("a one-way rule with one material on both sides is refused",
		rules.get_rule(41, 41).is_empty())

	_rules_body(world, Box3DBody.STATIC, 41, Vector3(20, 0.5, 20), Vector3(0, 4, 0), false, true)
	var rider := _rules_body(world, Box3DBody.DYNAMIC, 42, Vector3.ONE, Vector3(0, 1, 0), false, true)
	await get_tree().physics_frame
	await get_tree().physics_frame
	rider.set_linear_velocity(Vector3(0, 14, 0))
	var passed := false
	for i in range(60):
		await get_tree().physics_frame
		if rider.position.y > 5.0:
			passed = true
	_check("the rider passes upward through the one-way platform", passed)
	for i in range(180):
		await get_tree().physics_frame
	print("  one-way: rider settled at y=%.2f" % rider.position.y)
	_check("and lands on top of it coming down (%.2f)" % rider.position.y,
		rider.position.y > 4.2 and rider.position.y < 6.0)
	world.free()

func _build_heavy(world: Box3DWorld) -> void:
	var ground := Box3DBody.new()
	ground.name = "RecGround"
	ground.body_type = Box3DBody.STATIC
	ground.shape_type = Box3DBody.BOX
	ground.box_size = Vector3(40, 1, 40)
	ground.position = Vector3(0, -0.5, 0)
	world.add_child(ground)
	# A pyramid pile: plenty of contacts, plenty of islands, so the constraint
	# graph has something to re-partition at a different worker count.
	var n := 10
	for level in range(n):
		for x in range(n - level):
			for z in range(n - level):
				var b := Box3DBody.new()
				b.name = "B_%d_%d_%d" % [level, x, z]
				b.shape_type = Box3DBody.BOX
				b.box_size = Vector3(0.5, 0.5, 0.5)
				b.position = Vector3(
					float(x) * 0.55 - 2.5 + level * 0.275,
					0.3 + level * 0.55,
					float(z) * 0.55 - 2.5 + level * 0.275)
				world.add_child(b)


func _test_recording_replay() -> void:
	var world := Box3DWorld.new()
	world.name = "RecWorld"
	world.auto_step = false
	world.worker_count = 1
	add_child(world)
	_build_heavy(world)
	await get_tree().physics_frame

	var rec := Box3DRecording.new()
	_check("a fresh recording is not recording", not rec.is_recording())
	_check("start_recording takes", world.start_recording(rec))
	_check("the world reports recording", world.is_recording() and rec.is_recording())
	_check("the buffer names the world back", world.get_recording() == rec)
	_check("a second start is refused", not world.start_recording(rec))
	_check("mid-session bytes are refused", rec.get_data().is_empty())

	var frames := 150
	for i in range(frames):
		world.step(1.0 / 60.0)
	_check("the buffer grew while recording (%d bytes)" % rec.get_size(), rec.get_size() > 0)

	_check("stop_recording takes", world.stop_recording())
	_check("stopping clears the flags", not world.is_recording() and not rec.is_recording())
	_check("a second stop reports nothing to stop", not world.stop_recording())

	var bytes: PackedByteArray = rec.get_data()
	print("  recording = %d bytes over %d frames" % [bytes.size(), frames])
	_check("the stopped buffer yields bytes", bytes.size() > 0)
	_check("the file magic is B3RC",
		bytes.size() > 4 and bytes[0] == 0x42 and bytes[1] == 0x33 and bytes[2] == 0x52 and bytes[3] == 0x43)

	var path := "user://_test_features.b3rec"
	_check("save_to_file writes it", rec.save_to_file(path))
	_check("the file is on disk with the same size",
		FileAccess.file_exists(path) and FileAccess.get_file_as_bytes(path).size() == bytes.size())

	# --- replay at the RECORDED worker count: the control -------------------
	var p1 := Box3DReplayPlayer.new()
	_check("open at 1 worker", p1.open(bytes, 1))
	var info: Dictionary = p1.get_info()
	print("  info = %s" % info)
	_check("the info reports the frames (%d)" % info["frameCount"], info["frameCount"] == frames)
	_check("the info reports the recorded time step (%.5f)" % info["timeStep"],
		absf(info["timeStep"] - 1.0 / 60.0) < 1e-6)
	_check("the info reports the length scale (%.2f)" % info["lengthScale"],
		absf(info["lengthScale"] - 1.0) < 1e-6)
	_check("the info reports the requested worker count (%d)" % info["workerCount"],
		info["workerCount"] == 1)
	_check("the recording has bodies (%d)" % p1.get_body_count(), p1.get_body_count() > 0)
	_check("frame starts at 0 and has not diverged",
		p1.get_frame() == 0 and not p1.has_diverged() and p1.get_diverge_frame() == -1)
	_check("one step advances the frame", p1.step_frame() and p1.get_frame() == 1)
	p1.restart()
	_check("restart rewinds to 0", p1.get_frame() == 0 and not p1.has_diverged())
	var ok1: bool = p1.replay_all()
	print("  1-worker replay: frame=%d diverged=%s at=%d" % [p1.get_frame(), p1.has_diverged(), p1.get_diverge_frame()])
	_check("replay at the recorded worker count reproduces every hash", ok1)
	_check("the replay ran to the end", p1.is_at_end() and p1.get_frame() == frames)

	# Transforms are readable off the replay world.
	var moved := false
	for i in range(p1.get_body_count()):
		if p1.is_body_valid(i) and p1.get_body_transform(i).origin.length() > 0.0:
			moved = true
			break
	_check("the replay world exposes body transforms", moved)

	# --- THE PRIZE: replay at a DIFFERENT worker count ----------------------
	# A different worker count re-partitions the constraint graph, so the
	# embedded state hashes become a cross-thread determinism test
	# (box3d.h:322-327). The count MUST be passed to open(): raising it with
	# set_worker_count() afterwards never creates a scheduler, so the replay
	# would still run serially and the test would be vacuous.
	for wc in [2, 4, 8]:
		var p := Box3DReplayPlayer.new()
		_check("open at %d workers" % wc, p.open(bytes, wc))
		var okn: bool = p.replay_all()
		print("  %d-worker replay: frame=%d diverged=%s at=%d" % [wc, p.get_frame(), p.has_diverged(), p.get_diverge_frame()])
		_check("cross-thread determinism: replay at %d workers matches the 1-worker recording (diverge frame %d)"
			% [wc, p.get_diverge_frame()], okn)
		p.close()

	# open_file round trip
	var pf := Box3DReplayPlayer.new()
	_check("open_file reads the saved recording", pf.open_file(path, 4))
	_check("the file replays clean at 4 workers", pf.replay_all())
	pf.close()

	# Seek and keyframes.
	p1.restart()
	p1.seek_frame(60)
	_check("seek_frame lands on the frame (%d)" % p1.get_frame(), p1.get_frame() == 60)
	p1.seek_frame(10)
	_check("a backward seek lands too (%d)" % p1.get_frame(), p1.get_frame() == 10)
	p1.seek_frame(-5)
	_check("a negative seek clamps to 0 (%d)" % p1.get_frame(), p1.get_frame() == 0)
	p1.seek_frame(frames + 1000)
	_check("a seek past the end stops at the end (%d)" % p1.get_frame(), p1.is_at_end())
	print("  keyframes: budget=%d min=%d interval=%d bytes=%d"
		% [p1.get_keyframe_budget(), p1.get_keyframe_min_interval(), p1.get_keyframe_interval(), p1.get_keyframe_bytes()])
	_check("the keyframe ring reports a policy",
		p1.get_keyframe_budget() > 0 and p1.get_keyframe_min_interval() > 0)
	p1.set_keyframe_policy(1 << 20, 8)
	_check("set_keyframe_policy takes and restarts (%d/%d)" % [p1.get_keyframe_budget(), p1.get_keyframe_min_interval()],
		p1.get_keyframe_budget() == (1 << 20) and p1.get_keyframe_min_interval() == 8 and p1.get_frame() == 0)
	p1.close()
	_check("a closed player is closed", not p1.is_open())
	_check("a closed player steps nowhere", not p1.step_frame())

	# Garbage in. Both refusals print an ERROR line: that is the API working.
	var junk := Box3DReplayPlayer.new()
	_check("garbage bytes are refused", not junk.open(PackedByteArray([1, 2, 3, 4, 5, 6, 7, 8])))
	_check("empty bytes are refused", not junk.open(PackedByteArray()))
	_check("the length scale survived the refusals (%.3f)" % Box3DWorld.get_length_units_per_meter(),
		absf(Box3DWorld.get_length_units_per_meter() - 1.0) < 1e-6)

	world.free()
