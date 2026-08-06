extends Node3D

## Character -- a port of upstream's "Character / Mover" sample
## (samples/sample_character.cpp, BasicMover) and of the mover itself
## (samples/mover.cpp + mover.h). Box3DCharacterBody is the geometric half:
## collide -> b3SolvePlanes -> b3World_CastMover, five passes, exactly as
## CharacterMover::SolveMove sweeps. Everything ABOVE that -- Quake-style
## ground friction, the acceleration model, gravity, the jump, and the pogo
## suspension that decides what "on the ground" means -- lives in the mover
## struct upstream, so it lives in this script, number for number:
##
##   jump 5, max speed 6 (x1.5 sprinting), min speed 0.01, stop speed 1,
##   accelerate 30, friction 4, gravity 15 (mover.h:24-32), a capsule of
##   radius 0.3 with its centres +/- 0.5 (mover.cpp:34), and a 4 Hz / 0.7
##   damping pogo spring probing 3 x radius below the capsule's lower centre
##   (mover.cpp:140-172).
##
## The level is upstream's, piece for piece, with two substitutions: its floor
## is `data/meshes/test_map01.obj` and its steps are `data/meshes/stairs.obj`,
## upstream-owned art this repo does not vendor, so the floor is a plain box
## with its top at y = 0 and the stairs are boxes at the same origin
## (-10, 0, 0). Everything else is upstream's own numbers -- the three 2 m
## blocks at z ~ 14, the 50 x 50 wave height field at (20, 0, 0), the
## b3CreateTorusMesh(10, 12, 2, 1) torus scaled (-0.75, 1.5, 0.5), the two
## static capsules, the dynamic ball, the ignored slab and the sprung door on
## a +/-90 degree hinge.
##
## The three capsule-vs-shape behaviours upstream gets from shape user data are
## authored as node metadata (see Box3DCharacterBody's .cpp): the VIOLET enemy
## is a soft plane (push limit 1 m), the GREEN ally is softer still (0.01 m,
## no velocity clipping, and it never blocks the sweep) so you walk through it,
## and the WHITE slab is on the ignore list, so the capsule passes through it
## as if it were not there.

# --- CharacterMover tuning (samples/mover.h:24-32) ---------------------------
const JUMP_SPEED := 5.0
const MAX_SPEED := 6.0
const MIN_SPEED := 0.01
const STOP_SPEED := 1.0
const ACCELERATE := 30.0
const FRICTION := 4.0
const GRAVITY := 15.0
const SPRINT_SCALE := 1.5

# --- capsule + pogo (samples/mover.cpp:34, :140-171) -------------------------
const CAPSULE_RADIUS := 0.3
const CAPSULE_HALF := 0.5 # centre1/centre2 offset, so total height 1.6
const POGO_HERTZ := 4.0
const POGO_ZETA := 0.7
## The pogo ray skips category 2, upstream's "allies" (mover.cpp:144).
const POGO_MASK := 0xFFFFFFFD

const START_POSITION := Vector3(7.5, 0.75, 9.0)

## m_camera->SetView(120, 30, 5, moverPosition) (sample_character.cpp:325).
var camera_home := Vector3(11.25, 3.25, 6.83)
var camera_look_at := START_POSITION

var _world: Box3DWorld
var _char: Box3DCharacterBody
var _cam: Camera3D

var _velocity := Vector3.ZERO
var _pogo_velocity := 0.0
var _on_ground := false
var _sprint := false
## Upstream's "Clip Velocity" checkbox (sample_character.cpp:546).
var _clip_velocity := true


func _ready() -> void:
	_world = $Box3DWorld
	_char = $Box3DWorld/Mover
	_cam = get_viewport().get_camera_3d()
	_build_stairs()
	_build_torus()
	_build_terrain_visual()


## The shell's Activate button: upstream restarts the sample to put the mover
## back at its start (sample_character.cpp:321).
func activate() -> void:
	_char.global_position = START_POSITION
	_velocity = Vector3.ZERO
	_pogo_velocity = 0.0
	_on_ground = false


func get_toggle_label() -> String:
	return "Clip Velocity"


func set_toggled(on: bool) -> void:
	_clip_velocity = on


func _physics_process(delta: float) -> void:
	# CharacterMover::Step (mover.cpp:263-318): camera-relative throttle, jump
	# and sprint, then one SolveMove.
	var throttle := Vector2.ZERO
	var forward := Vector3.FORWARD
	var right := Vector3.RIGHT
	if _cam != null:
		forward = -_cam.global_transform.basis.z
		right = _cam.global_transform.basis.x
	forward.y = 0.0
	right.y = 0.0
	forward = forward.normalized()
	right = right.normalized()

	# Only steer while the mouse is free; the shell captures it to fly.
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		if Input.is_key_pressed(KEY_W): throttle.x += 1.0
		if Input.is_key_pressed(KEY_S): throttle.x -= 1.0
		if Input.is_key_pressed(KEY_A): throttle.y -= 1.0
		if Input.is_key_pressed(KEY_D): throttle.y += 1.0
		if Input.is_key_pressed(KEY_SPACE) and _on_ground:
			_velocity.y = JUMP_SPEED
			_on_ground = false
		_sprint = _on_ground and Input.is_key_pressed(KEY_SHIFT)
	else:
		_sprint = false

	solve_move(delta, forward, right, throttle)


## CharacterMover::SolveMove (samples/mover.cpp:83-261).
func solve_move(delta: float, forward: Vector3, right: Vector3, throttle: Vector2) -> void:
	# Friction: linear damping above stop speed, a fixed reduction below it.
	var speed := _velocity.length()
	if speed < MIN_SPEED:
		_velocity.x = 0.0
		_velocity.z = 0.0
	else:
		var control := STOP_SPEED if speed < STOP_SPEED else speed
		var drop := control * FRICTION * delta
		var ratio := maxf(0.0, speed - drop) / speed
		_velocity.x *= ratio
		_velocity.z *= ratio

	var max_speed: float = SPRINT_SCALE * MAX_SPEED if _sprint else MAX_SPEED

	var desired_velocity := max_speed * throttle.x * forward + max_speed * throttle.y * right
	var desired_speed := desired_velocity.length()
	var desired_direction := desired_velocity / desired_speed if desired_speed > 0.0 else Vector3.ZERO
	if desired_speed > max_speed:
		desired_speed = max_speed

	if _on_ground:
		_velocity.y = 0.0

	# Accelerate: only ever ADDS speed along the wish direction, capped by how
	# much is missing, which is what makes air control feel like Quake's.
	var current_speed := _velocity.dot(desired_direction)
	var add_speed := desired_speed - current_speed
	if add_speed > 0.0:
		_velocity += minf(ACCELERATE * max_speed * delta, add_speed) * desired_direction

	_velocity.y -= GRAVITY * delta

	_solve_pogo(delta)

	# target = p + dt * velocity + dt * pogoVelocity * up (mover.cpp:175). The
	# pogo is a suspension, not part of the mover's velocity, so it is added to
	# the move and never to _velocity.
	var command := _velocity + Vector3(0.0, _pogo_velocity, 0.0)
	var achieved: Vector3 = _char.move_and_slide(command, delta)

	if _clip_velocity:
		# b3ClipVector against the planes the move solved: keeps the mover from
		# picking up speed out of soft depenetration (mover.cpp:250-255).
		_velocity = _char.clip_velocity(_velocity)
	elif delta > 0.0:
		# The position-delta branch (mover.cpp:256-260): move_and_slide returns
		# exactly (endPosition - startPosition) / timeStep.
		_velocity = achieved


## The pogo suspension (mover.cpp:140-172). A ray from the capsule's lower
## centre looks 3 x radius + radius below it; the mover rides a 4 Hz spring
## against whatever it finds, and "on the ground" IS that ray hitting, not the
## collision planes. It is what carries the capsule up stairs and over lips
## without a step-up hack.
func _solve_pogo(delta: float) -> void:
	var rest_length := 3.0 * CAPSULE_RADIUS
	var ray_length := rest_length + CAPSULE_RADIUS
	var ray_origin := _char.global_position + Vector3(0.0, -CAPSULE_HALF, 0.0)
	var ray_target := ray_origin + Vector3(0.0, -ray_length, 0.0)
	var hit: Dictionary = _world.raycast(ray_origin, ray_target, POGO_MASK)

	# After gravity, a mover still moving up must not be pulled back down.
	var suppress: bool = _velocity.y > 0.0
	if suppress or not hit.get("hit", false):
		_on_ground = false
		_pogo_velocity = 0.0
		return

	_on_ground = true
	var current_length: float = hit["fraction"] * ray_length
	var omega := TAU * POGO_HERTZ
	var omega_h := omega * delta
	_pogo_velocity = (_pogo_velocity - omega * omega_h * (current_length - rest_length)) \
			/ (1.0 + 2.0 * POGO_ZETA * omega_h + omega_h * omega_h)


# --- level pieces built in code ---------------------------------------------

## Stand-in for upstream's `data/meshes/stairs.obj` at (-10, 0, 0)
## (sample_character.cpp:364-374), which this repo does not vendor. Ten 0.25 m
## steps: high enough that the pogo spring, not a step-up hack, is what gets
## the capsule up them.
func _build_stairs() -> void:
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.46, 0.48, 0.44)
	material.roughness = 0.8
	for i in range(10):
		var rise := 0.25 * (i + 1)
		var step := Box3DBody.new()
		step.name = "Step%d" % i
		step.body_type = Box3DBody.STATIC
		step.box_size = Vector3(4.0, rise, 0.6)
		step.position = Vector3(-10.0, 0.5 * rise, 0.3 + 0.6 * i)
		var mesh := BoxMesh.new()
		mesh.size = step.box_size
		var visual := MeshInstance3D.new()
		visual.mesh = mesh
		visual.material_override = material
		step.add_child(visual)
		_world.add_child(step)


## b3CreateTorusMesh(10, 12, 2, 1) at (-10, 1, -8), turned a quarter turn about
## Y and given upstream's (-0.75, 1.5, 0.5) mesh scale
## (sample_character.cpp:377-387). b3CreateMeshShape applies that scale to the
## points without re-winding, so it is baked into the vertices here the same
## way -- including the mirroring negative x.
func _build_torus() -> void:
	var geometry: Dictionary = Box3DGeometry.create_torus_mesh(10, 12, 2.0, 1.0)
	var scale := Vector3(-0.75, 1.5, 0.5)
	var points: PackedVector3Array = geometry["vertices"]
	for i in points.size():
		points[i] = points[i] * scale
	geometry["vertices"] = points

	var torus := Box3DBody.new()
	torus.name = "Torus"
	torus.body_type = Box3DBody.STATIC
	torus.shape_type = Box3DBody.MESH
	torus.mesh_vertices = points
	torus.mesh_indices = geometry["indices"]
	torus.transform = Transform3D(Basis(Vector3.UP, 0.5 * PI), Vector3(-10.0, 1.0, -8.0))

	var visual := MeshInstance3D.new()
	visual.mesh = Box3DGeometry.make_array_mesh(geometry)
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.55, 0.35, 0.7)
	material.roughness = 0.5
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	visual.material_override = material
	torus.add_child(visual)
	_world.add_child(torus)


## The wave height field is authored on the Terrain node; this is the matching
## surface to look at. height(i, j) = sin(2*PI*rowFreq*i) * sin(2*PI*colFreq*j)
## with the grid point at scale * (j, height, i) (src/height_field.c:1384-1444),
## and b3CreateWave punches out every 16th cell when makeHoles is on (:1417).
func _build_terrain_visual() -> void:
	var terrain: Box3DBody = $Box3DWorld/Terrain
	var count_x: int = terrain.height_field_size.x
	var count_z: int = terrain.height_field_size.y
	var scale: Vector3 = terrain.height_field_scale
	var wave: Vector2 = terrain.height_field_wave

	var verts := PackedVector3Array()
	verts.resize(count_x * count_z)
	for i in count_z:
		var row := sin(TAU * wave.y * i)
		for j in count_x:
			verts[i * count_x + j] = Vector3(j * scale.x, row * sin(TAU * wave.x * j) * scale.y, i * scale.z)

	var indices := PackedInt32Array()
	for i in count_z - 1:
		for j in count_x - 1:
			var cell := i * (count_x - 1) + j
			if terrain.height_field_holes and cell > 0 and cell % 16 == 0:
				continue
			var i11 := i * count_x + j
			var i12 := i11 + 1
			var i21 := i11 + count_x
			var i22 := i21 + 1
			indices.append_array([i11, i21, i12, i12, i21, i22])

	# Wound box3d's way and handed to the one bridge that knows how to turn
	# that into a Godot surface, as every other hand-built surface in the demo
	# now is.
	var visual := MeshInstance3D.new()
	visual.name = "TerrainMesh"
	visual.mesh = Box3DGeometry.make_array_mesh({"vertices": verts, "indices": indices})
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.35, 0.45, 0.38)
	material.roughness = 0.75
	visual.material_override = material
	terrain.add_child(visual)
