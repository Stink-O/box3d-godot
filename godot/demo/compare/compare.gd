extends Node3D

## Physics-engine comparison harness.
##
## Runs the demo's OWN sample scenes under a chosen 3D physics engine, behind a
## fixed camera and a recording-legible HUD, so three captures of the same
## sample line up and the only variable is the solver.
##
##   godot --path godot/demo res://compare/compare.tscn -- --engine=jolt --sample=pyramid
##
## engine = box3d | godot | jolt
##
## Box3D runs the sample scene AS AUTHORED: Box3DWorld and Box3DBody nodes,
## untouched. The native engines cannot, because 18 of the 32 samples carry
## `: Box3DBody` static annotations and common/cube.gd and common/bomb.gd
## literally `extends Box3DBody`, so swapping nodes breaks type-checking before
## physics is involved. Instead RigExtract reads the authored scene into a
## backend-neutral description and RigNative rebuilds it with RigidBody3D and
## friends. PackedScene.instantiate() runs _init but not _ready, so the read
## happens with no world created and no sample script side effects.
##
## Nothing here touches the samples, the shell, or the GDExtension. This is a
## reader, not a fork of the demo.

const SAMPLE_DIR := "res://samples"

## Per-engine accents, so a clip is identifiable from a thumbnail.
const ACCENTS := {
	"box3d": Color(0.35, 0.85, 1.0),
	"godot": Color(0.45, 0.7, 1.0),
	"jolt": Color(1.0, 0.62, 0.2),
}

const TITLES := {
	"box3d": "Box3D",
	"godot": "Godot Physics",
	"jolt": "Jolt Physics",
}

## Physics ticks to wait before trusting the behavioural engine probe. Bodies
## are still awake this early, which the probe depends on.
const PROBE_TICK := 12

var engine := "box3d"
var sample := "pyramid"

var _names: PackedStringArray = PackedStringArray()
var _index := 0
var _stage: Node3D = null
var _world: Node = null            ## Box3DWorld for box3d runs, else null
var _feed = null
var _dynamic := 0
var _notes: Array = []
var _tick := 0
var _probed := false

## --shot=<png path> --shot-tick=<n>: save one frame and quit. For pulling
## stills out of a run without screen-capturing a window.
var _shot_path := ""
var _shot_tick := 120

@onready var _camera: Camera3D = $Camera3D
@onready var _hud: Control = $UI/Overlay
@onready var _profiler: ProfilerPanel = $UI/Profiler


func _ready() -> void:
	# Delete the launcher's override.cfg the moment we are up. Godot read
	# physics/3d/physics_engine once at startup and never looks again, so the
	# file has already done its job; removing it here is what keeps a crash or
	# a kill -9 from leaving the normal demo silently switched to another
	# engine. compare.sh also traps EXIT, and sweeps on the next launch.
	_sweep_override()
	_parse_args()
	_scan_samples()

	# Vsync would cap the frame rate and flatten exactly the difference this
	# harness exists to show. Headless has no window to configure.
	if DisplayServer.get_name() != "headless":
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)

	_load_sample()


func _parse_args() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--engine="):
			engine = arg.get_slice("=", 1).to_lower()
		elif arg.begins_with("--sample="):
			sample = arg.get_slice("=", 1)
		elif arg.begins_with("--shot="):
			_shot_path = arg.get_slice("=", 1)
		elif arg.begins_with("--shot-tick="):
			_shot_tick = maxi(1, int(arg.get_slice("=", 1)))
	if not ACCENTS.has(engine):
		engine = "box3d"


func _sweep_override() -> void:
	var path := ProjectSettings.globalize_path("res://override.cfg")
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)


## Filesystem enumeration, matching tests/test_samples.gd, so the picker cannot
## drift from what actually ships. Strips the .remap suffix exported builds add.
func _scan_samples() -> void:
	var found := PackedStringArray()
	var dir := DirAccess.open(SAMPLE_DIR)
	if dir != null:
		dir.list_dir_begin()
		var f := dir.get_next()
		while f != "":
			var name := f
			if name.ends_with(".remap"):
				name = name.trim_suffix(".remap")
			if name.ends_with(".tscn"):
				found.append(name.trim_suffix(".tscn"))
			f = dir.get_next()
		dir.list_dir_end()
	found.sort()
	_names = found
	_index = maxi(0, _names.find(sample))
	if _names.is_empty():
		push_error("[compare] no sample scenes found under %s" % SAMPLE_DIR)
	else:
		sample = _names[_index]


# --- Loading -----------------------------------------------------------------

func _load_sample() -> void:
	if _stage != null:
		# Immediate free, not queue_free: a deferred free leaves two 4000-body
		# scenes alive for one frame, which main.gd already learned overflows
		# the per-instance shader parameter buffer.
		_stage.free()
		_stage = null
	_world = null
	_feed = null
	_notes = []
	_dynamic = 0
	_tick = 0
	_probed = false

	var path := "%s/%s.tscn" % [SAMPLE_DIR, sample]
	if not ResourceLoader.exists(path):
		push_error("[compare] no such sample: %s" % path)
		return

	if engine == "box3d":
		_load_box3d(path)
	else:
		_load_native(path)

	_frame_camera(path)
	_feed = ProfileFeeds.make(engine, _world)
	_profiler.accent = ACCENTS[engine]
	_profiler.set_feed(_feed)
	_profiler.reset()
	_push_hud()
	_print_proof()


## Box3D runs the scene exactly as authored. No translation, no adapter.
func _load_box3d(path: String) -> void:
	var packed: PackedScene = load(path)
	var inst := packed.instantiate()
	_stage = Node3D.new()
	_stage.name = "Stage"
	add_child(_stage)
	_stage.add_child(inst)
	_world = inst.get_node_or_null("Box3DWorld")
	if _world == null:
		push_error("[compare] %s has no Box3DWorld child" % path)
		return
	_dynamic = _count_box3d_dynamic(_world)


func _count_box3d_dynamic(root: Node) -> int:
	var n := 0
	for body in root.find_children("*", "Box3DBody", true, false):
		# Box3DBody.DYNAMIC == 2.
		if body.body_type == 2:
			n += 1
	return n


## Native engines get the authored scene read into a neutral rig and rebuilt
## with RigidBody3D / StaticBody3D / Joint3D.
func _load_native(path: String) -> void:
	var rig := RigExtract.from_scene(path)
	_stage = Node3D.new()
	_stage.name = "Stage"
	add_child(_stage)

	var built := RigNative.build(rig, _stage)
	# Per-world gravity has no native node equivalent and 30 of the 32 samples
	# set it (car uses -10, gyro_torque uses zero), so it goes on the space.
	var space := get_viewport().find_world_3d().space
	RigNative.apply_world_settings(rig, space)

	for body in built.get("bodies", []):
		if body is RigidBody3D:
			_dynamic += 1

	_add_decoration(path)

	var notes: Array = []
	notes.append_array(rig.get("unsupported", []))
	notes.append_array(built.get("warnings", []))
	_notes = notes


## Copy non-physics geometry across to the native stage.
##
## Samples park decorative meshes directly under the scene root, OUTSIDE the
## Box3DWorld: wrecking's gantry post and arm, marble_run's chute, the Label3D
## captions. RigExtract only walks the world, so without this the native side
## silently loses them and two recordings of the same sample no longer match.
## Meshes that belong to a body are already carried as that body's visuals, and
## are skipped here by the world check.
func _add_decoration(path: String) -> void:
	var packed: PackedScene = load(path)
	if packed == null:
		return
	var root := packed.instantiate()
	var world := root.get_node_or_null("Box3DWorld")
	var deco := Node3D.new()
	deco.name = "Decoration"
	_stage.add_child(deco)
	for node in root.find_children("*", "VisualInstance3D", true, false):
		if world != null and world.is_ancestor_of(node):
			continue
		var xf := _relative_xform(node as Node3D, root)
		var copy := (node as Node3D).duplicate(0) as Node3D
		_strip_scripts(copy)
		deco.add_child(copy)
		copy.transform = xf
	root.free()


## Transform of `node` relative to `root`, accumulated by walking up. The scene
## is unparented while we read it, and global_transform hard-fails outside the
## tree.
func _relative_xform(node: Node3D, root: Node) -> Transform3D:
	var xf := Transform3D.IDENTITY
	var n: Node = node
	while n != null and n != root:
		if n is Node3D:
			xf = (n as Node3D).transform * xf
		n = n.get_parent()
	return xf


## A duplicated decoration node must not carry its script: those scripts expect
## Box3D siblings that do not exist on this side, and would error on _ready.
func _strip_scripts(node: Node) -> void:
	node.set_script(null)
	for child in node.get_children():
		_strip_scripts(child)


# --- Camera ------------------------------------------------------------------

## Same spawn-view priority as the demo shell (main.gd:677): a CameraStart node
## at the scene root, optionally aimed at a LookAt child, else exported
## camera_home / camera_look_at. Identical for every engine so the clips
## register when laid side by side.
func _frame_camera(path: String) -> void:
	var eye := Vector3(0, 9.5, 27)
	var target := Vector3(0, 3, 0)

	var probe: Node = null
	if engine == "box3d" and _stage != null and _stage.get_child_count() > 0:
		probe = _stage.get_child(0)
	else:
		# The native rig carries physics only, so read the view off a throwaway
		# instance of the authored scene. instantiate() runs no _ready.
		var packed: PackedScene = load(path)
		if packed != null:
			probe = packed.instantiate()

	if probe != null:
		var cam_start := probe.get_node_or_null("CameraStart")
		if cam_start is Node3D:
			eye = cam_start.transform.origin
			target = eye - cam_start.transform.basis.z
			var aim = cam_start.get_node_or_null("LookAt")
			if aim is Node3D and not aim.position.is_equal_approx(Vector3.ZERO):
				target = eye + cam_start.transform.basis * aim.position
		elif "camera_home" in probe and "camera_look_at" in probe:
			eye = probe.camera_home
			target = probe.camera_look_at
		if probe.get_parent() == null:
			probe.free()

	_camera.position = eye
	if not eye.is_equal_approx(target):
		_camera.look_at(target, Vector3.UP)


# --- Engine identity ---------------------------------------------------------

## Which native server is ACTUALLY running.
##
## The project setting cannot be trusted: an unregistered name is not an error,
## Godot falls back to DEFAULT silently with nothing on stderr, so a typo in the
## launcher would mislabel a whole recording. PhysicsServer3D.get_class() does
## not help either, it returns "PhysicsServer3D" for both native engines.
##
## What does discriminate is behaviour. JoltPhysicsServer3D::get_process_info()
## is literally `return 0;`, so the active-object count reads 0 under Jolt and
## the real count under GodotPhysics3D. Verified on 4.7.stable.
func _identify_native() -> String:
	if PhysicsServer3D.get_class() == "PhysicsServer3DDummy":
		return "Dummy"
	if _dynamic <= 0:
		return ""  # nothing to probe with; stay honest rather than guess
	# All three counters, not just active objects: a scene that has already
	# settled reports 0 awake bodies under GodotPhysics too, but keeps a live
	# collision-pair count. Under Jolt every one of them is 0 always.
	var signals := 0
	signals += PhysicsServer3D.get_process_info(PhysicsServer3D.INFO_ACTIVE_OBJECTS)
	signals += PhysicsServer3D.get_process_info(PhysicsServer3D.INFO_COLLISION_PAIRS)
	signals += PhysicsServer3D.get_process_info(PhysicsServer3D.INFO_ISLAND_COUNT)
	return "Godot Physics" if signals > 0 else "Jolt Physics"


func _check_engine() -> void:
	_probed = true
	if engine == "box3d":
		return
	var live := _identify_native()
	if live == "":
		return
	var want: String = TITLES[engine]
	if live != want:
		var msg := "ENGINE MISMATCH: asked for %s, running %s" % [want, live]
		_hud.alert = msg
		push_error("[compare] " + msg)
		print("[compare] " + msg)


func _engine_proof() -> String:
	if _feed != null:
		return _feed.source_proof()
	return ""


func _print_proof() -> void:
	print("[compare] engine=%s sample=%s dynamic_bodies=%d ticks/s=%d" % [
			engine, sample, _dynamic, Engine.physics_ticks_per_second])
	for note in _notes:
		print("[compare] note: %s" % note)


# --- Per-tick ----------------------------------------------------------------

func _physics_process(_delta: float) -> void:
	_tick += 1
	if _profiler != null:
		_profiler.poll()
	if not _probed and _tick >= PROBE_TICK:
		_check_engine()
		_push_hud()
	if _shot_path != "" and _tick == _shot_tick:
		_save_shot()


func _save_shot() -> void:
	# Wait for the frame to actually be drawn; the viewport texture is a frame
	# behind at this point in the physics tick.
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var err := img.save_png(_shot_path)
	print("[compare] shot %s -> %s" % [_shot_path, "ok" if err == OK else str(err)])
	get_tree().quit()


func _push_hud() -> void:
	_hud.accent = ACCENTS[engine]
	_hud.engine_title = TITLES[engine]
	_hud.engine_proof = _engine_proof()
	_hud.sample_title = "%s   (%d/%d)" % [sample, _index + 1, _names.size()]
	_hud.bodies = _dynamic
	_hud.notes = _notes


# --- Input -------------------------------------------------------------------
#
# Sample switching is live; engine switching is not. Godot reads
# physics/3d/physics_engine once at startup and offers no runtime switch and no
# command-line flag, so changing engine means relaunching through compare.sh.

func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	match event.keycode:
		KEY_RIGHT, KEY_BRACKETRIGHT:
			_step_sample(1)
		KEY_LEFT, KEY_BRACKETLEFT:
			_step_sample(-1)
		KEY_R:
			_load_sample()
		KEY_TAB:
			_profiler.visible = not _profiler.visible
		KEY_ESCAPE:
			get_tree().quit()


func _step_sample(delta: int) -> void:
	if _names.is_empty():
		return
	_index = (_index + delta + _names.size()) % _names.size()
	sample = _names[_index]
	_load_sample()
