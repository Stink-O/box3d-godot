extends Node3D

## Wave Pile -- a port of upstream's "Determinism / Wave Pile" sample
## (samples/sample_determinism.cpp:112, scene in shared/determinism.c:130-207).
##
## Upstream's Determinism category is the one part of the sample set with no
## Godot analogue, which is awkward for a port whose whole verification story
## leans on determinism. This is that gap closed: 100 convex bodies -- spheres,
## capsules, boxes and rocks, with rolling resistance so the pile settles
## quickly -- dropped onto a wave height field, run until every body is asleep,
## and then CHECKED.
##
## Upstream checks it by hashing the settled transforms and printing the number
## for a human to compare between builds. This port can do better, because the
## binding exposes the recording and replay system (P-045): the world records
## itself from its first tick, and once the pile sleeps the recorded bytes are
## replayed -- at one worker, and then at two, four and eight. Box3D embeds a
## state hash of every body's transform and velocity after each step
## (src/physics_world.c:1173-1180) and the player recomputes and compares them,
## so `has_diverged()` is the verdict. A different worker count re-partitions
## the constraint graph and solves the same island in a different order, so a
## clean replay at 8 workers is a live cross-thread determinism check on the
## property this repo's red lines protect (`-ffp-contract=off`, no `-ffast-math`).
##
## What that does NOT prove, so nobody over-reads a green verdict:
## `b3HashWorldState` covers body transforms and velocities only
## (src/recording.c:1223-1266) -- contacts, joints, impulses and sleep flags are
## not hashed. And the verdict is about THIS build on THIS machine: it says the
## same bytes reproduce the same simulation across worker counts, not that two
## different platforms agree.
##
## Threads are a hard requirement for the multi-worker half. A replay world
## opened with workerCount > 1 builds a scheduler and spawns threads
## (src/physics_world.c:367-386), and on a build without pthreads a refused
## thread aborts rather than erroring, so the extra counts are gated on
## `OS.has_feature("threads")` and the single-threaded web build runs the
## one-worker check alone and says so.
##
## Scene constants are upstream's, verbatim:
##  * 21 x 21 grid lines of `b3CreateWave`, scale (1, 0.6, 1), row frequency
##    0.08 along z and column frequency 0.06 along x, no holes
##    (shared/determinism.c:137-138). A height field grows from the body origin
##    along +x / +z, so the body carries upstream's centring offset of half the
##    span (`-0.5 * 1.0 * (21 - 1)` = -10 m on both axes,
##    shared/determinism.c:141-146).
##  * 4 layers of a 5 x 5 grid at 1.7 m spacing, dropped from
##    `2.5 + 1.6 * layer`, each jittered by +/-0.3 m and given a uniformly
##    random orientation (shared/determinism.c:127-128, :165-181).
##  * Sphere r = 0.5, capsule (0,-0.3,0)..(0,0.3,0) r = 0.35, box hull
##    (0.45, 0.3, 0.55) half extents, rock of radius 0.55, cycled by index % 4
##    (shared/determinism.c:152-155, :183-197).
##  * Rolling resistance 0.3 on every shape (shared/determinism.c:161).
##
## The layout is upstream's, not an approximation of it: upstream's random
## number generator is reproduced here -- XorShift32 seeded 52977
## (shared/determinism.c:134, generator at shared/utils.h:27-60) -- and
## `RandomVec3Uniform` and Shoemake's `RandomQuat` draw from it in the same
## order the C does, including upstream's own `b3ComputeCosSin`, which is a
## normalized Bhaskara approximation rather than libm (src/math_functions.c:216-
## 263) and would otherwise put every body at a slightly different angle. The
## arithmetic here runs in GDScript doubles where upstream runs in floats, so
## the scene reproduces to rounding, not bit for bit.
##
## Two GDExtension defaults would have silently changed the scene and are set
## back explicitly: `density` is 1 on the node where `b3DefaultShapeDef` is 1000
## (src/types.c:72-73), and `angular_damping` is 0.05 where `b3DefaultBodyDef`
## is 0. Gravity is upstream's world default of -10 (src/types.c:16), not the
## demo's usual -9.8.

## b3CreateWave's arguments (shared/determinism.c:137-138). The node takes the
## frequencies x-first, so `height_field_wave` is (column, row) = (0.06, 0.08).
const FIELD_COUNT := 21
const FIELD_SCALE := Vector3(1.0, 0.6, 1.0)
const FIELD_WAVE := Vector2(0.06, 0.08)

const GRID := 5
const LAYERS := 4
const SPACING := 1.7
const JITTER := 0.3
const DENSITY := 1000.0

const SPHERE_RADIUS := 0.5
## Upstream's capsule is two centres 0.6 m apart on y with radius 0.35; the
## node's capsule is always centred on the body origin and runs along y, so it
## is the same shape at height |c2 - c1| + 2r.
const CAPSULE_RADIUS := 0.35
const CAPSULE_HEIGHT := 0.6 + 2.0 * CAPSULE_RADIUS
const BOX_HALF := Vector3(0.45, 0.3, 0.55)
const ROCK_RADIUS := 0.55
const ROLLING_RESISTANCE := 0.3

## Upstream's own seed for this scene (shared/determinism.c:134).
const RANDOM_SEED := 52977
const RAND_LIMIT := 32767

## Give up waiting for sleep after this many steps and verify anyway, so the
## sample always reaches a verdict. The pile settles well inside it.
const MAX_SETTLE_STEPS := 1800
const MIN_SETTLE_STEPS := 10

## Worker counts the recording is replayed at. 1 is always run; the rest need
## real threads (see the header).
const WORKER_COUNTS := [1, 2, 4, 8]

enum { PHASE_SETTLE, PHASE_VERIFY, PHASE_DONE }

var camera_home := Vector3(16.02, 10.57, 16.02)
var camera_look_at := Vector3(0.0, 0.0, 0.0)

var _world: Box3DWorld
var _terrain: Box3DBody
var _bodies: Array[Box3DBody] = []
var _home: Array[Transform3D] = []

var _recording: Box3DRecording
var _phase := PHASE_SETTLE
var _steps := 0
var _sleep_step := -1
var _next_check := 0
var _results: Array[String] = []
var _hashes: PackedInt64Array = PackedInt64Array()
var _diverged := false

var _rand_state := RANDOM_SEED

@onready var _label: Label3D = $Status


func _ready() -> void:
	_world = $Box3DWorld
	_terrain = $Box3DWorld/Terrain

	var terrain_visual := MeshInstance3D.new()
	terrain_visual.name = "TerrainMesh"
	terrain_visual.mesh = _build_terrain_surface()
	var terrain_material := StandardMaterial3D.new()
	terrain_material.albedo_color = Color(0.30, 0.38, 0.34)
	terrain_material.roughness = 0.8
	terrain_visual.material_override = terrain_material
	_terrain.add_child(terrain_visual)

	_build_pile()


## The shell's Activate button: put the pile back where it started and run the
## whole settle-and-verify cycle again.
func activate() -> void:
	if _phase == PHASE_VERIFY:
		return
	for i in _bodies.size():
		var body := _bodies[i]
		body.set_linear_velocity(Vector3.ZERO)
		body.set_angular_velocity(Vector3.ZERO)
		body.teleport(_home[i])
		body.set_awake(true)
	_recording = null
	_phase = PHASE_SETTLE
	_steps = 0
	_sleep_step = -1
	_next_check = 0
	_results.clear()
	_hashes.clear()
	_diverged = false


func _physics_process(_delta: float) -> void:
	match _phase:
		PHASE_SETTLE:
			if _recording == null:
				# One buffer per take. b3World_StartRecording is snapshot
				# seeded (src/recording.c:1017), so the terrain and the whole
				# pile are in the bytes even though they were built before this
				# call ran.
				_recording = Box3DRecording.create()
				_world.start_recording(_recording)
			# This node steps before its Box3DWorld child does, so the tick
			# about to be recorded is counted here and nowhere else.
			_steps += 1
			# The floor under the sleep test is not politeness: a world that has
			# not stepped yet reports nothing awake, and accepting that would
			# hand back a verdict on an empty recording.
			if _steps > MIN_SETTLE_STEPS and _world.get_awake_body_count() == 0:
				_sleep_step = _steps
				_begin_verify()
			elif _steps >= MAX_SETTLE_STEPS:
				_begin_verify()
		PHASE_VERIFY:
			_run_one_check()
	_update_label()


func _begin_verify() -> void:
	# Stopping the session is what appends the geometry registry and makes the
	# bytes loadable; get_data() refuses before it has run.
	_world.stop_recording()
	_phase = PHASE_VERIFY
	_next_check = 0


## One worker count per physics tick: a full replay of a 100 body pile is
## thousands of dispatched ops and doing all four in one frame would stall.
func _run_one_check() -> void:
	var counts := _worker_counts()
	if _next_check >= counts.size():
		_phase = PHASE_DONE
		return

	var workers := int(counts[_next_check])
	_next_check += 1

	var player := Box3DReplayPlayer.new()
	# The worker count is chosen HERE and essentially only here: raising it
	# afterwards re-partitions the graph but never creates a scheduler, so the
	# replay would still execute serially and the check would be vacuous.
	if not player.open(_recording.get_data(), workers):
		_results.append("%d worker(s): recording refused" % workers)
		_diverged = true
		return

	# replay_all() steps to the end and reports whether every embedded state
	# hash reproduced; has_diverged() is the same verdict read off the player.
	var matched := player.replay_all()
	var diverged := not matched or player.has_diverged()
	var diverge_frame := player.get_diverge_frame()
	var state := _hash_replay(player)
	# Close promptly: an open player installs the recording's length scale
	# process-wide and only restores it on close.
	player.close()

	var first := state if _hashes.is_empty() else _hashes[0]
	_hashes.append(state)
	if diverged:
		_diverged = true
		_results.append("%d worker(s): DIVERGED at frame %d" % [workers, diverge_frame])
	elif first != state:
		_diverged = true
		_results.append("%d worker(s): final state differs (%08X)" % [workers, state])
	else:
		_results.append("%d worker(s): match, state %08X" % [workers, state])


func _worker_counts() -> Array:
	# A replay world asks b3CreateWorld for this many workers, and without
	# pthreads the refused thread aborts rather than failing, so anything past
	# the first entry is gated on the build actually having threads.
	if OS.has_feature("threads"):
		return WORKER_COUNTS
	return [1]


## A 32-bit digest of every replayed body's final pose, used only to compare one
## replay against another. It is this port's own number and has no relationship
## to the hash upstream's sample prints.
func _hash_replay(p_player: Box3DReplayPlayer) -> int:
	var floats := PackedFloat32Array()
	for i in p_player.get_body_count():
		if not p_player.is_body_valid(i):
			continue
		var xform := p_player.get_body_transform(i)
		var q := xform.basis.get_rotation_quaternion()
		floats.append_array(PackedFloat32Array([
				xform.origin.x, xform.origin.y, xform.origin.z, q.x, q.y, q.z, q.w]))
	return hash(floats)


func _update_label() -> void:
	match _phase:
		PHASE_SETTLE:
			_label.text = "settling (step %d, %d awake)" % [_steps, _world.get_awake_body_count()]
			_label.modulate = Color(0.65, 0.9, 1.0)
		PHASE_VERIFY, PHASE_DONE:
			var head := "asleep at step %d" % _sleep_step
			if _sleep_step < 0:
				head = "still moving after %d steps" % _steps
			var lines := PackedStringArray([head])
			lines.append_array(PackedStringArray(_results))
			if _phase == PHASE_DONE:
				if _diverged:
					lines.append("verdict: DIVERGED")
				elif _worker_counts().size() == 1:
					lines.append("verdict: reproduced (1 worker; no threads on this build)")
				else:
					lines.append("verdict: identical at 1, 2, 4 and 8 workers")
			_label.text = "\n".join(lines)
			_label.modulate = Color(1.0, 0.5, 0.45) if _diverged else Color(0.6, 1.0, 0.7)


# --- scene -------------------------------------------------------------------


func _build_pile() -> void:
	_rand_state = RANDOM_SEED

	var rock := Box3DGeometry.create_rock(ROCK_RADIUS)
	var rock_mesh := Box3DGeometry.make_array_mesh(rock)

	var sphere_mesh := SphereMesh.new()
	sphere_mesh.radius = SPHERE_RADIUS
	sphere_mesh.height = 2.0 * SPHERE_RADIUS
	var capsule_mesh := CapsuleMesh.new()
	capsule_mesh.radius = CAPSULE_RADIUS
	capsule_mesh.height = CAPSULE_HEIGHT
	var box_mesh := BoxMesh.new()
	box_mesh.size = BOX_HALF * 2.0

	var materials: Array[StandardMaterial3D] = [
		_material(Color(0.90, 0.45, 0.30)),
		_material(Color(0.35, 0.70, 0.90)),
		_material(Color(0.95, 0.80, 0.35)),
		_material(Color(0.60, 0.55, 0.85)),
	]

	var index := 0
	for layer in LAYERS:
		for i in GRID:
			for j in GRID:
				# Upstream draws the jitter first and the orientation second;
				# the order matters, because both come off the same stream.
				var jitter := _random_vec3_uniform(-JITTER, JITTER)
				var pos := Vector3(
						SPACING * (i - 0.5 * (GRID - 1)) + jitter.x,
						2.5 + 1.6 * layer + 0.3 * jitter.y,
						SPACING * (j - 0.5 * (GRID - 1)) + jitter.z)
				var rot := _random_quat()

				var body := Box3DBody.new()
				body.name = "Body%d" % index
				body.body_type = Box3DBody.DYNAMIC
				body.density = DENSITY
				body.rolling_resistance = ROLLING_RESISTANCE
				body.angular_damping = 0.0
				body.auto_visual = false

				var mesh: Mesh
				match index % 4:
					0:
						body.shape_type = Box3DBody.SPHERE
						body.sphere_radius = SPHERE_RADIUS
						mesh = sphere_mesh
					1:
						body.shape_type = Box3DBody.CAPSULE
						body.capsule_radius = CAPSULE_RADIUS
						body.capsule_height = CAPSULE_HEIGHT
						mesh = capsule_mesh
					2:
						body.shape_type = Box3DBody.BOX
						body.box_size = BOX_HALF * 2.0
						mesh = box_mesh
					_:
						body.shape_type = Box3DBody.HULL
						body.collision_mesh = rock_mesh
						mesh = rock_mesh

				var visual := MeshInstance3D.new()
				visual.name = "Visual"
				visual.mesh = mesh
				visual.material_override = materials[index % 4]
				body.add_child(visual)

				var xform := Transform3D(Basis(rot), pos)
				body.transform = xform
				_world.add_child(body)
				_bodies.append(body)
				_home.append(xform)
				index += 1


func _material(p_color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = p_color
	m.roughness = 0.6
	return m


## The same wave box3d generates, as a Godot surface: height(i, j) is
## sin(2 * PI * rowFrequency * i) * sin(2 * PI * columnFrequency * j) and the
## grid point sits at scale * (j, height, i) (src/height_field.c:1384-1444).
## Box3D quantizes every height into a uint16 over +/-256, so the collision
## surface and this analytic one can never agree closer than that step.
func _build_terrain_surface() -> ArrayMesh:
	var verts := PackedVector3Array()
	verts.resize(FIELD_COUNT * FIELD_COUNT)
	for i in FIELD_COUNT:
		var row := sin(TAU * FIELD_WAVE.y * i)
		for j in FIELD_COUNT:
			var h := row * sin(TAU * FIELD_WAVE.x * j)
			verts[i * FIELD_COUNT + j] = Vector3(
					j * FIELD_SCALE.x, h * FIELD_SCALE.y, i * FIELD_SCALE.z)

	var indices := PackedInt32Array()
	for i in FIELD_COUNT - 1:
		for j in FIELD_COUNT - 1:
			var i11 := i * FIELD_COUNT + j
			var i12 := i11 + 1
			var i21 := i11 + FIELD_COUNT
			var i22 := i21 + 1
			indices.append_array([i11, i21, i12, i12, i21, i22])

	return Box3DGeometry.make_array_mesh({"vertices": verts, "indices": indices})


# --- upstream's random number generator (shared/utils.h:27-60) ----------------
# Reproduced rather than approximated, because the whole point of this scene is
# that it is the same scene upstream builds. GDScript integers are 64-bit and
# signed, so every shift is masked back to 32 bits.


func _random_int() -> int:
	var x := _rand_state
	x = (x ^ (x << 13)) & 0xFFFFFFFF
	x = x ^ (x >> 17)
	x = (x ^ (x << 5)) & 0xFFFFFFFF
	_rand_state = x
	return x % (RAND_LIMIT + 1)


func _random_float_range(p_lo: float, p_hi: float) -> float:
	var r := float(_random_int() & RAND_LIMIT) / float(RAND_LIMIT)
	return (p_hi - p_lo) * r + p_lo


func _random_vec3_uniform(p_lo: float, p_hi: float) -> Vector3:
	# x, y, z in that order -- the draw order is part of the sequence.
	var x := _random_float_range(p_lo, p_hi)
	var y := _random_float_range(p_lo, p_hi)
	var z := _random_float_range(p_lo, p_hi)
	return Vector3(x, y, z)


## Shoemake's uniform random rotation, exactly as upstream spells it
## (shared/utils.h:113-135) -- including the fact that it converts its angles
## with `b3ComputeCosSin` rather than libm.
func _random_quat() -> Quaternion:
	var u1 := _random_float_range(0.0, 1.0)
	var u2 := _random_float_range(0.0, TAU)
	var u3 := _random_float_range(0.0, TAU)
	var sqrt1_minus_u1 := sqrt(1.0 - u1)
	var sqrt_u1 := sqrt(u1)
	var cs2 := _cos_sin(u2)
	var cs3 := _cos_sin(u3)
	return Quaternion(
			sqrt1_minus_u1 * cs2.y,
			sqrt1_minus_u1 * cs2.x,
			sqrt_u1 * cs3.y,
			sqrt_u1 * cs3.x)


## `b3ComputeCosSin` (src/math_functions.c:216-263), returned as (cos, sin).
## Box3D does not call libm here: it evaluates a pair of Bhaskara rational
## approximations and normalizes the result, which is off by up to about a fifth
## of a degree. Reproducing it is what makes the orientations upstream's rather
## than merely drawn from upstream's numbers.
func _cos_sin(p_radians: float) -> Vector2:
	# b3UnwindAngle is remainderf(radians, 2 * PI): the residue toward the
	# NEAREST multiple of a turn, which lands in [-PI, PI], not fmod's [0, TAU).
	var x: float = p_radians - TAU * roundf(p_radians / TAU)
	var pi2 := PI * PI

	var c := 0.0
	if x < -0.5 * PI:
		var y := x + PI
		c = -(pi2 - 4.0 * y * y) / (pi2 + y * y)
	elif x > 0.5 * PI:
		var y := x - PI
		c = -(pi2 - 4.0 * y * y) / (pi2 + y * y)
	else:
		c = (pi2 - 4.0 * x * x) / (pi2 + x * x)

	var s := 0.0
	if x < 0.0:
		var y := x + PI
		s = -16.0 * y * (PI - y) / (5.0 * pi2 - 4.0 * y * (PI - y))
	else:
		s = 16.0 * x * (PI - x) / (5.0 * pi2 - 4.0 * x * (PI - x))

	var mag := sqrt(s * s + c * c)
	var inv_mag := 1.0 / mag if mag > 0.0 else 0.0
	return Vector2(c * inv_mag, s * inv_mag)
