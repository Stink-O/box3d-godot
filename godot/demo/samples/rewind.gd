extends Node3D

## Rewind -- there is no upstream sample for this one. Box3D reaches its
## recording API from the C side and from its own debug viewer, and the sample
## set never replays a scene, so this is written in the spirit of one: the
## smallest scene that makes the capability visible, with the binding's own
## semantics kept exact.
##
## The loop, every AUTO_PERIOD seconds while the toggle is on, or on Activate:
##  1. RECORD. The world records itself from its first physics tick. A recording
##     is snapshot-seeded (`src/recording.c:1017`), so the wall and the ball are
##     in the buffer even though they were built before `start_recording()` ran.
##  2. FREEZE. `stop_recording()` is what appends the geometry registry and
##     backpatches the header, i.e. what makes the bytes loadable, and
##     `get_data()` REFUSES until it has run. Then `auto_step` goes off and the
##     live world stands still exactly where the recording ended.
##  3. REWIND. The bytes open in a `Box3DReplayPlayer`, the whole recording is
##     played forward once to fill the keyframe ring, and then it is scrubbed
##     BACKWARDS two recorded frames per tick (about 2x real time) with
##     `seek_frame()`. The translucent ghosts are `get_body_transform()` and
##     nothing else.
##  4. REPLAY. Forward again at the same rate with `step_frame()`, then
##     `close()`, reset the wall, and record a fresh take.
##
## The player never touches the live world: it stands up a private world of its
## own and retargets every recorded id onto it, which is why the frozen scene
## behind the ghosts is exactly where it was left when the replay finishes.
##
## Two traps this sample is shaped around:
##  * The replay's worker count is chosen by `open()` and essentially only
##    there. `set_worker_count()` afterwards re-partitions the constraint graph
##    but never creates a scheduler, so a player opened at 1 stays serial. This
##    one opens at 1 deliberately: it is driven and drawn from the main thread,
##    and the browser's single-threaded build has no pthreads to give it. The
##    cross-thread version of this check (replay the same bytes at 2, 4 and 8
##    workers) lives in the selftest, where threads are always available.
##  * `get_data()` and `save_to_file()` refuse while the session is live, so the
##    order in step 2 is not a style choice.
##
## The player hands back transforms, not shapes, so the scene keeps its own
## index table: bodies come back in creation order (with holes where a recorded
## body was destroyed, which this scene never does), so ground, wall, ball is
## the order they were built in.
##
## `has_diverged()` is the verdict. Box3D embeds a state hash of every live
## body's transform and velocity after each step and the player recomputes and
## compares them, so a clean replay means the same bytes reproduced the same
## simulation. It should never fire here; the label mentions it only if it does.

const GROUND_SIZE := Vector3(40.0, 1.0, 40.0)

const BRICK_SIZE := Vector3(0.8, 0.4, 0.5)
const WALL_COLUMNS := 4
const WALL_ROWS := 6

const BALL_RADIUS := 0.45
const BALL_DENSITY := 8.0
const BALL_START := Vector3(0.0, 1.1, 7.0)
const BALL_VELOCITY := Vector3(0.0, 0.0, -17.0)

## Seconds of live simulation before Auto Rewind fires.
const AUTO_PERIOD := 8.0
## Recorded frames per physics tick while scrubbing, in both directions. Two
## frames per 1/60 s tick is twice real time.
const SCRUB_RATE := 2

## Backward seeks restore the nearest keyframe and re-step the gap, so a tight
## keyframe interval is what makes scrubbing backwards cheap. 4 frames costs at
## most four re-steps of a 25-body scene per tick.
const KEYFRAME_BUDGET := 8 << 20
const KEYFRAME_MIN_INTERVAL := 4

## See the header: 1 is not a shortcut, it is the only count safe to draw from
## the main thread on every build the demo ships on.
const REPLAY_WORKERS := 1

enum { PHASE_LIVE, PHASE_REWIND, PHASE_REPLAY }

## Ghost slots: which visual, if any, draws a given replayed body index.
const SLOT_NONE := -2
const SLOT_BALL := -1

var camera_home := Vector3(7.4, 4.6, 10.6)
var camera_look_at := Vector3(0.0, 1.3, 0.0)

var _world: Box3DWorld
var _bricks: Array[Box3DBody] = []
var _brick_home: Array[Transform3D] = []
var _ball: Box3DBody

var _ghosts: MultiMeshInstance3D
var _ball_ghost: MeshInstance3D
var _slot: PackedInt32Array = PackedInt32Array()

var _recording: Box3DRecording
var _player: Box3DReplayPlayer
var _phase := PHASE_LIVE
var _frames := 0
var _live_time := 0.0
var _auto := true
var _diverge_frame := -1

@onready var _label: Label3D = $Status


func _ready() -> void:
	_world = $Box3DWorld

	var ground := Box3DBody.new()
	ground.name = "Ground"
	ground.body_type = Box3DBody.STATIC
	ground.shape_type = Box3DBody.BOX
	ground.box_size = GROUND_SIZE
	ground.position = Vector3(0.0, -0.5 * GROUND_SIZE.y, 0.0)
	ground.add_child(_box_visual(GROUND_SIZE, Color(0.24, 0.26, 0.29)))
	_world.add_child(ground)

	_build_wall()
	_build_ball()
	_build_ghosts()


## The shell's one-shot action: rewind now, without waiting for the timer.
func activate() -> void:
	if _phase == PHASE_LIVE:
		_begin_rewind()


func get_toggle_label() -> String:
	return "Auto Rewind"


## The scene rewinds itself from the start, so the switch reports that rather
## than claiming the effect is off.
func get_toggle_initial() -> bool:
	return _auto


func set_toggled(p_on: bool) -> void:
	_auto = p_on
	if p_on:
		_live_time = 0.0


func _physics_process(delta: float) -> void:
	match _phase:
		PHASE_LIVE:
			if _recording == null:
				_start_recording()
			_live_time += delta
			if _auto and _live_time >= AUTO_PERIOD:
				_begin_rewind()
			else:
				# This node steps before its Box3DWorld child does, so the tick
				# about to be recorded is counted here and nowhere else.
				_frames += 1
		PHASE_REWIND:
			_player.seek_frame(maxi(0, _player.get_frame() - SCRUB_RATE))
			_draw_ghosts()
			if _player.get_frame() == 0:
				_phase = PHASE_REPLAY
		PHASE_REPLAY:
			for i in SCRUB_RATE:
				_player.step_frame()
			_draw_ghosts()
			if _player.is_at_end():
				_finish_replay()
	_update_label()


func _start_recording() -> void:
	# One buffer serves every take: b3World_StartRecording resets it, so a new
	# session cannot be confused with the last one's bytes.
	if _recording == null:
		_recording = Box3DRecording.create()
	_frames = 0
	_live_time = 0.0
	_world.start_recording(_recording)


func _begin_rewind() -> void:
	# Stopping is what makes the bytes loadable, and get_data() refuses before
	# it. Nothing below would work in the other order.
	_world.stop_recording()
	_world.auto_step = false

	_player = Box3DReplayPlayer.new()
	if not _player.open(_recording.get_data(), REPLAY_WORKERS):
		# A refusal prints its own reason. Carry on recording rather than
		# stranding the scene frozen.
		_player = null
		_resume()
		return
	# This clears the keyframe ring and restarts the player, so it has to come
	# before the forward pass that fills the ring.
	_player.set_keyframe_policy(KEYFRAME_BUDGET, KEYFRAME_MIN_INTERVAL)
	_map_ghosts()
	# Play the whole recording forward once: it fills the keyframe ring that
	# makes the backward scrub cheap, and it is already the determinism check,
	# because every embedded state hash is recomputed on the way.
	_player.seek_frame(_player.get_frame_count())

	_ghosts.visible = true
	_ball_ghost.visible = true
	_phase = PHASE_REWIND
	_draw_ghosts()


func _finish_replay() -> void:
	if _player.has_diverged():
		_diverge_frame = _player.get_diverge_frame()
	_player.close()
	_player = null
	_resume()


## Back to a live world with a fresh take. The wall is put back so every
## recording holds the same event rather than a shorter and shorter one.
func _resume() -> void:
	_ghosts.visible = false
	_ball_ghost.visible = false
	for i in _bricks.size():
		_bricks[i].teleport(_brick_home[i])
	_ball.teleport(Transform3D(Basis(), BALL_START))
	_ball.set_linear_velocity(BALL_VELOCITY)
	_world.auto_step = true
	# Left null so the next tick starts the session before the world steps,
	# which is what keeps the frame count exact.
	_recording = null
	_phase = PHASE_LIVE


func _map_ghosts() -> void:
	# Creation order, which is the order get_body_count() reports: ground, then
	# the wall, then the ball. Nothing here is ever destroyed, so there are no
	# holes; is_body_valid() is still what the draw checks.
	var count := _player.get_body_count()
	_slot.resize(count)
	_slot.fill(SLOT_NONE)
	var expected := 2 + _bricks.size()
	if count < expected:
		return
	for i in _bricks.size():
		_slot[1 + i] = i
	_slot[1 + _bricks.size()] = SLOT_BALL


func _draw_ghosts() -> void:
	var mm := _ghosts.multimesh
	for i in _slot.size():
		var slot := _slot[i]
		if slot == SLOT_NONE or not _player.is_body_valid(i):
			continue
		var xform := _player.get_body_transform(i)
		if slot == SLOT_BALL:
			_ball_ghost.global_transform = xform
		else:
			mm.set_instance_transform(slot, xform)


func _update_label() -> void:
	match _phase:
		PHASE_LIVE:
			# get_size() is live during a session and is the one honest progress
			# readout while recording; get_data() is not available yet.
			var bytes: int = 0 if _recording == null else _recording.get_size()
			_label.text = "recording (frame %d, %d KiB)" % [_frames, bytes >> 10]
			_label.modulate = Color(0.65, 0.9, 1.0)
		PHASE_REWIND:
			_label.text = "rewinding (frame %d of %d)" % [_player.get_frame(), _player.get_frame_count()]
			_label.modulate = Color(1.0, 0.78, 0.35)
		PHASE_REPLAY:
			_label.text = "replaying (frame %d of %d)" % [_player.get_frame(), _player.get_frame_count()]
			_label.modulate = Color(0.6, 1.0, 0.7)
	if _diverge_frame >= 0:
		_label.text += "\nreplay diverged at frame %d" % _diverge_frame


func _build_wall() -> void:
	var width := WALL_COLUMNS * BRICK_SIZE.x
	for row in WALL_ROWS:
		# Every other course is offset by half a brick, so the wall breaks up
		# into pieces instead of shearing along one seam.
		var offset: float = 0.0 if row % 2 == 0 else 0.5 * BRICK_SIZE.x
		for column in WALL_COLUMNS:
			var brick := Box3DBody.new()
			brick.name = "Brick%d_%d" % [row, column]
			brick.shape_type = Box3DBody.BOX
			brick.box_size = BRICK_SIZE
			brick.position = Vector3(
					-0.5 * width + (column + 0.5) * BRICK_SIZE.x + offset,
					(row + 0.5) * BRICK_SIZE.y,
					0.0)
			brick.add_child(_box_visual(BRICK_SIZE,
					Color(0.85, 0.55, 0.36) if row % 2 == 0 else Color(0.93, 0.83, 0.6)))
			_world.add_child(brick)
			_bricks.append(brick)
			_brick_home.append(Transform3D(Basis(), brick.position))


func _build_ball() -> void:
	_ball = Box3DBody.new()
	_ball.name = "Ball"
	_ball.shape_type = Box3DBody.SPHERE
	_ball.sphere_radius = BALL_RADIUS
	_ball.density = BALL_DENSITY
	_ball.position = BALL_START
	var visual := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = BALL_RADIUS
	mesh.height = 2.0 * BALL_RADIUS
	visual.mesh = mesh
	visual.material_override = _material(Color(0.4, 0.55, 0.75))
	_ball.add_child(visual)
	_world.add_child(_ball)
	# The box3d body exists once the node is in the tree, so the shot is fired
	# after the add, not before it.
	_ball.set_linear_velocity(BALL_VELOCITY)


## One MultiMesh for the wall's ghosts (every brick is the same box) and one
## mesh for the ball's. They are children of the scene, not of any body: a
## ghost is a replayed transform and has no body behind it.
func _build_ghosts() -> void:
	var brick_mesh := BoxMesh.new()
	brick_mesh.size = BRICK_SIZE
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = brick_mesh
	mm.instance_count = _bricks.size()
	_ghosts = MultiMeshInstance3D.new()
	_ghosts.name = "WallGhosts"
	_ghosts.multimesh = mm
	_ghosts.material_override = _ghost_material(Color(0.95, 0.72, 0.4))
	_ghosts.visible = false
	add_child(_ghosts)

	var ball_mesh := SphereMesh.new()
	ball_mesh.radius = BALL_RADIUS
	ball_mesh.height = 2.0 * BALL_RADIUS
	_ball_ghost = MeshInstance3D.new()
	_ball_ghost.name = "BallGhost"
	_ball_ghost.mesh = ball_mesh
	_ball_ghost.material_override = _ghost_material(Color(0.55, 0.75, 1.0))
	_ball_ghost.visible = false
	add_child(_ball_ghost)


func _box_visual(p_size: Vector3, p_color: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = p_size
	mi.mesh = mesh
	mi.material_override = _material(p_color)
	return mi


func _material(p_color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = p_color
	mat.roughness = 0.45
	return mat


func _ghost_material(p_color: Color) -> StandardMaterial3D:
	var mat := _material(Color(p_color.r, p_color.g, p_color.b, 0.4))
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return mat


## Readouts, for the shell and for tests.
func get_phase() -> int:
	return _phase


func get_recorded_frames() -> int:
	return _frames


func get_replay_player() -> Box3DReplayPlayer:
	return _player


## What the ghosts are showing for a replayed body index, which is what a test
## compares against the recording itself. Identity for an index nothing draws.
func get_ghost_transform(p_index: int) -> Transform3D:
	if p_index < 0 or p_index >= _slot.size():
		return Transform3D()
	var slot := _slot[p_index]
	if slot == SLOT_BALL:
		return _ball_ghost.global_transform
	if slot >= 0:
		return _ghosts.multimesh.get_instance_transform(slot)
	return Transform3D()
