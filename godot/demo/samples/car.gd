extends Node3D

## Drivable car on gently bumpy terrain.
##
## Drive with the ARROW KEYS (or W A S D when you're not flying the camera):
## Up/Down accelerate and reverse, Left/Right steer. The car is an ARCADE drive
## -- car.gd pushes the chassis forward and yaws it directly, and the chassis
## has its pitch/roll locked so it always stays upright and controllable. The
## four cylinder wheels are free-rolling: they spin from ground contact as the
## car moves, so it reads as a real car without depending on fiddly wheel-motor
## traction (which box3d doesn't do well). The car sits still until you drive.
##
## Terrain: a single large flat ground box with gentle speed-bump humps
## (half-buried cylinders) scattered by noise. Box3D wheels only roll cleanly on
## ONE continuous collider, so the drivable surface is one flat box and the
## "terrain" is the humps the car rolls over.

const MAX_SPEED := 9.0           # m/s top speed
const ACCEL := 16.0              # m/s^2 how fast throttle reaches top speed
const TURN_RATE := 1.9           # rad/s yaw while steering (~110 deg/s)
const GRIP := 0.82               # 0..1 how much sideways drift is kept per frame (lower = grippier)

const GROUND_SIZE := 120.0       # metres, square flat ground
const HUMP_COUNT := 40           # candidate hump sites sampled from noise
const HUMP_RADIUS := 0.5         # speed-bump cylinder radius (bigger = gentler slope)
const HUMP_RISE := 0.14          # how far the hump pokes above the ground
const SPAWN_CLEAR := 6.0         # keep the spawn pad clear of humps

var _chassis: Box3DBody


func _ready() -> void:
	var world: Box3DWorld = $Box3DWorld
	_build_terrain(world)
	_chassis = world.get_node_or_null("Chassis")


func _physics_process(delta: float) -> void:
	if _chassis == null:
		return
	# Arrow keys always; W A S D too, but only when the camera isn't captured
	# (right mouse held for flying), so the two never fight.
	var driving := Input.mouse_mode != Input.MOUSE_MODE_CAPTURED
	var throttle := 0.0
	if Input.is_key_pressed(KEY_UP) or (driving and Input.is_key_pressed(KEY_W)):
		throttle += 1.0
	if Input.is_key_pressed(KEY_DOWN) or (driving and Input.is_key_pressed(KEY_S)):
		throttle -= 1.0
	var steer := 0.0
	if Input.is_key_pressed(KEY_RIGHT) or (driving and Input.is_key_pressed(KEY_D)):
		steer += 1.0
	if Input.is_key_pressed(KEY_LEFT) or (driving and Input.is_key_pressed(KEY_A)):
		steer -= 1.0

	var fwd := -_chassis.global_transform.basis.z
	fwd.y = 0.0
	if fwd.length() < 0.01:
		return
	fwd = fwd.normalized()

	# Arcade drive by velocity: set the forward speed and yaw rate directly so the
	# car goes exactly where you steer (box3d still resolves collisions, so it
	# stops at walls and rides over the bumps). Vertical velocity is preserved for
	# gravity/bumps; sideways drift is damped for grip.
	var v: Vector3 = _chassis.get_linear_velocity()
	var v_fwd: float = v.dot(fwd)
	v_fwd = move_toward(v_fwd, throttle * MAX_SPEED, ACCEL * delta)
	var lateral: Vector3 = v - fwd * v.dot(fwd)
	lateral.y = 0.0
	var new_v: Vector3 = fwd * v_fwd + lateral * GRIP
	new_v.y = v.y
	_chassis.set_linear_velocity(new_v)

	# Steer: yaw rate straight to the wheel input (0 when not steering, so it
	# tracks precisely instead of drifting).
	_chassis.set_angular_velocity(Vector3(0.0, -steer * TURN_RATE, 0.0))


func _build_terrain(world: Box3DWorld) -> void:
	# One big continuous flat ground box -- wheels roll reliably on it.
	var ground_mat := StandardMaterial3D.new()
	ground_mat.albedo_color = Color(0.24, 0.36, 0.2)
	ground_mat.roughness = 0.95
	var ground := Box3DBody.new()
	ground.name = "Ground"
	ground.body_type = Box3DBody.STATIC
	ground.box_size = Vector3(GROUND_SIZE, 2.0, GROUND_SIZE)
	ground.position = Vector3(0, -1.0, 0)  # top face at y = 0
	ground.friction = 1.0
	var gmi := MeshInstance3D.new()
	var gmesh := BoxMesh.new()
	gmesh.size = Vector3(GROUND_SIZE, 2.0, GROUND_SIZE)
	gmi.mesh = gmesh
	gmi.material_override = ground_mat
	ground.add_child(gmi)
	world.add_child(ground)

	# Gentle speed-bump humps: half-buried horizontal cylinders placed by noise,
	# each rotated a random way in the ground plane, kept off the spawn pad.
	var noise := FastNoiseLite.new()
	noise.seed = 1337
	noise.frequency = 0.09
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260708
	var hump_mat := StandardMaterial3D.new()
	hump_mat.albedo_color = Color(0.3, 0.34, 0.22)
	hump_mat.roughness = 0.9

	var humps := Node3D.new()
	humps.name = "Humps"
	world.add_child(humps)
	for i in range(HUMP_COUNT):
		var x := rng.randf_range(-45.0, 45.0)
		var z := rng.randf_range(-45.0, 45.0)
		if Vector2(x, z).length() < SPAWN_CLEAR:
			continue
		# Only place a hump where the noise field is high enough -> clustered,
		# organic distribution rather than a uniform grid.
		if noise.get_noise_2d(x, z) < 0.05:
			continue
		var length := rng.randf_range(3.0, 7.0)
		var yaw := rng.randf_range(0.0, PI)
		var hump := Box3DBody.new()
		hump.body_type = Box3DBody.STATIC
		hump.shape_type = Box3DBody.CYLINDER
		hump.capsule_radius = HUMP_RADIUS
		hump.capsule_height = length
		hump.cylinder_sides = 20
		hump.friction = 1.0
		# Cylinder axis is local Y; lay it flat (axis in the ground plane) and
		# bury it so only HUMP_RISE pokes up. Rotate about Z to lay down, then
		# yaw about Y for a random heading.
		var basis := Basis(Vector3.UP, yaw) * Basis(Vector3(0, 0, 1), PI / 2.0)
		hump.transform = Transform3D(basis, Vector3(x, HUMP_RISE - HUMP_RADIUS, z))
		var hmi := MeshInstance3D.new()
		var hmesh := CylinderMesh.new()
		hmesh.top_radius = HUMP_RADIUS
		hmesh.bottom_radius = HUMP_RADIUS
		hmesh.height = length
		hmi.mesh = hmesh
		hmi.material_override = hump_mat
		hump.add_child(hmi)
		humps.add_child(hump)
