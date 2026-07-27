extends Node3D

## Box3D sample browser. A dropdown menu lists samples by category; picking
## one instances its scene into SampleHost and points the shared camera at its
## world. Add new samples to SAMPLES and drop the scene in samples/.

const SAMPLES := {
	"Basics": {
		"Cube Pile": "res://samples/cube_pile.tscn",
		"Joint Sampler": "res://samples/joint_sampler.tscn",
		"Body Types": "res://samples/body_types.tscn",
	},
	"Shapes": {
		"Shape Zoo": "res://samples/shape_zoo.tscn",
		"Restitution": "res://samples/restitution.tscn",
	},
	"Stacking & Friction": {
		"Friction Ramp": "res://samples/friction_ramp.tscn",
		"Pyramid": "res://samples/pyramid.tscn",
		"Large Pyramid": "res://samples/large_pyramid.tscn",
		"Huge Pyramid": "res://samples/huge_pyramid.tscn",
		"Mixed Stacks": "res://samples/mixed_stacks.tscn",
	},
	"Constraints": {
		"Motion Locks": "res://samples/motion_locks.tscn",
	},
	"Compound": {
		"Compound Shapes": "res://samples/compound.tscn",
	},
	"Toys": {
		"Pool Break": "res://samples/pool.tscn",
		"Marble Run": "res://samples/marble_run.tscn",
		"Tumbling Tower": "res://samples/tower.tscn",
		"Ball Pit": "res://samples/ball_pit.tscn",
		"Wrecking Ball": "res://samples/wrecking.tscn",
		"Ball Fountain": "res://samples/fountain.tscn",
	},
	"Dynamics": {
		"Dominoes": "res://samples/dominoes.tscn",
		"Bridge": "res://samples/bridge.tscn",
		"Ragdoll": "res://samples/ragdoll.tscn",
		"Motorized": "res://samples/motor.tscn",
		"Newton's Cradle": "res://samples/cradle.tscn",
	},
	"Gyroscopes": {
		"Gyroscopic Torque": "res://samples/gyro_torque.tscn",
		"Gyroscopic Precession": "res://samples/gyro_precession.tscn",
	},
	"Gameplay": {
		"Character Controller": "res://samples/character.tscn",
		"Contact Pit": "res://samples/contacts.tscn",
		"Bowling": "res://samples/bowling.tscn",
	},
	"Queries": {
		"Radar Sweep": "res://samples/raycast.tscn",
		"Explosion": "res://samples/explosion.tscn",
	},
	"Continuous": {
		"Bullets (CCD)": "res://samples/bullets.tscn",
	},
	"Vehicles": {
		"Car": "res://samples/car.tscn",
	},
}

## Which solver runs the samples. Box3D is the default and the tested path; the
## native engines exist so the same shell -- same menu, camera, tools, reset --
## can be pointed at a different solver. Selecting one restarts the process
## (Godot reads physics/3d/physics_engine once at startup and offers no runtime
## switch and no command-line flag), see _restart_with_engine.
const ENGINE_IDS := ["box3d", "godot", "jolt"]
const ENGINE_TITLES := {
	"box3d": "Box3D",
	"godot": "Godot Physics",
	"jolt": "Jolt Physics",
}
## Values for physics/3d/physics_engine. The exact strings matter and are easy
## to get wrong: an unregistered name is NOT an error, Godot falls back to
## DEFAULT silently with nothing on stderr, which is why the live server is
## identified behaviourally instead (_identify_native). Registered values on
## 4.7: DEFAULT, GodotPhysics3D, "Jolt Physics", Dummy. Box3D runs its own
## world, so it takes Dummy rather than pay for a native server stepping an
## empty space -- nothing outside compare/ and common/native_world.gd touches
## the native physics API.
const ENGINE_SETTINGS := {
	"box3d": "Dummy",
	"godot": "GodotPhysics3D",
	"jolt": "Jolt Physics",
}
## Physics ticks to wait before trusting the behavioural engine probe. The
## counters it reads only mean something while bodies are still awake.
const ENGINE_PROBE_TICK := 12
## Where the browser build opens. See the note in _ready().
const WEB_FIRST_SAMPLE := "Pyramid"
## Profiler tint per engine, so a recording is identifiable from a thumbnail.
const ENGINE_ACCENTS := {
	"box3d": Color(0.35, 0.85, 1.0),
	"godot": Color(0.45, 0.7, 1.0),
	"jolt": Color(1.0, 0.62, 0.2),
}

@onready var _host: Node3D = $SampleHost
@onready var _camera: Camera3D = $Camera3D
@onready var _menu: MenuButton = $UI/Bar/Menu
@onready var _engine_option: OptionButton = $UI/Sidebar/Margin/VBox/EngineOption
@onready var _engine_sep: Control = $UI/Sidebar/Margin/VBox/EngineSep
@onready var _engine_label: Label = $UI/Sidebar/Margin/VBox/EngineLabel
@onready var _engine_hint: Label = $UI/Sidebar/Margin/VBox/EngineHint
@onready var _engine_note: Label = $UI/Bar/EngineNote
@onready var _shot_mode: OptionButton = $UI/Bar/ShotMode
@onready var _blast_label: Label = $UI/Bar/BlastLabel
@onready var _blast_slider: HSlider = $UI/Bar/BlastSlider
@onready var _impact_check: CheckBox = $UI/Bar/ImpactCheck
@onready var _activate: Button = $UI/Bar/Activate
@onready var _sample_toggle: CheckButton = $UI/Bar/SampleToggle
@onready var _info: Label = $UI/Bar/Info
@onready var _reset: Button = $UI/Reset
@onready var _debug_toggle: CheckButton = $UI/DebugToggle
@onready var _charge_bar: ProgressBar = $UI/ChargeBar

@onready var _sidebar_toggle: Button = $UI/SettingsToggle
@onready var _sidebar: Control = $UI/Sidebar
@onready var _substep_spin: SpinBox = $UI/Sidebar/Margin/VBox/SubstepRow/SubstepSpin
@onready var _worker_spin: SpinBox = $UI/Sidebar/Margin/VBox/WorkerRow/WorkerSpin
@onready var _max_speed_spin: SpinBox = $UI/Sidebar/Margin/VBox/MaxSpeedRow/MaxSpeedSpin
@onready var _gravity_spin: SpinBox = $UI/Sidebar/Margin/VBox/GravityRow/GravitySpin
@onready var _continuous_check: CheckBox = $UI/Sidebar/Margin/VBox/ContinuousCheck
@onready var _sleep_check: CheckBox = $UI/Sidebar/Margin/VBox/SleepCheck
@onready var _recycling_check: CheckBox = $UI/Sidebar/Margin/VBox/RecyclingCheck
@onready var _sidebar_debug_check: CheckBox = $UI/Sidebar/Margin/VBox/DebugDrawCheck
@onready var _stats_check: CheckBox = $UI/Sidebar/Margin/VBox/StatsCheck
@onready var _async_check: CheckBox = $UI/Sidebar/Margin/VBox/AsyncCheck
@onready var _async_hint: Label = $UI/Sidebar/Margin/VBox/AsyncHint
@onready var _vsync_option: OptionButton = $UI/Sidebar/Margin/VBox/VsyncOption
@onready var _stats_overlay: Control = $UI/StatsOverlay
@onready var _profiler: ProfilerPanel = $UI/Profiler
@onready var _profiler_check: CheckBox = $UI/Sidebar/Margin/VBox/ProfilerCheck
@onready var _contact_hertz_row: Control = $UI/Sidebar/Margin/VBox/ContactHertzRow
@onready var _contact_hertz_spin: SpinBox = $UI/Sidebar/Margin/VBox/ContactHertzRow/ContactHertzSpin
@onready var _contact_damping_row: Control = $UI/Sidebar/Margin/VBox/ContactDampingRow
@onready var _contact_damping_spin: SpinBox = $UI/Sidebar/Margin/VBox/ContactDampingRow/ContactDampingSpin
@onready var _readout: Label = $UI/Sidebar/Margin/VBox/Readout
@onready var _set_start_btn: Button = $UI/Sidebar/Margin/VBox/StartViewRow/SetStartView
@onready var _clear_start_btn: Button = $UI/Sidebar/Margin/VBox/StartViewRow/ClearStartView

## Start views saved at runtime with the sidebar's "Set Start View" button,
## keyed by sample scene path. Highest-priority spawn view, survives restarts.
const START_VIEWS_PATH := "user://start_views.cfg"
var _start_views := ConfigFile.new()

var _current: Node = null
var _items: Dictionary = {}  ## popup item id -> {path, name}
var _current_path := ""
var _current_name := ""
var _debug_draw := false
var _step_count := 0
var _updating_sidebar := false  ## guard while pushing values into the controls
## Box3D fixes the worker count when the world is created, so the sidebar
## can't live-edit it like the other settings. Instead a change reloads the
## sample with this override applied before the world exists. Sticky across
## Reset, cleared when switching samples (-1 = use the scene's own value).
var _worker_override := -1
## Contact tuning survives Reset the same way (a tuning experiment shouldn't
## be lost to a rebuild); cleared when switching samples (-1 = scene's own).
var _contact_hertz_override := -1.0
var _contact_damping_override := -1.0
## Screenshot-on-tick, see _save_shot.
var _shot_path := ""
var _shot_tick := 200
var _debug_hidden: Array = []  ## MeshInstance3Ds hidden while the debug view is on
var _debug_hidden_node_count := -1  ## tree size at the last hide walk (skip cheaply when unchanged)
## Off by default; sticky across sample loads and resets once turned on.
var _async_step := false

var _touch: TouchControls = null  ## touch overlay, only on touchscreen devices

## Engine selection. `_engine` is what was ASKED for (`--engine=`, written by
## the restart); `_engine_live` is what the behavioural probe actually found,
## and `_engine_alert` holds the message when they disagree.
var _engine := "box3d"
var _engine_live := ""
var _engine_alert := ""
var _engine_probed := false
var _restarting := false
## Port notes for the sample currently loaded on a native engine: what the rig
## could not express (RigExtract.unsupported) plus what the rebuild had to
## approximate (RigNative.warnings). Empty on Box3D, which runs as authored.
var _native_notes: Array = []
var _native_dynamic := 0  ## dynamic bodies in the rebuilt rig; the probe needs some
var _has_recycling := false  ## this build's Box3DBody exposes contact_recycling


func _ready() -> void:
	# Delete a stale override.cfg the moment we are up. Godot read
	# physics/3d/physics_engine once at startup and never looks again, so the
	# file has already done its job; removing it here is what keeps a crash or a
	# kill -9 from leaving the demo silently switched to another engine.
	_sweep_override()
	_parse_engine_arg()
	_setup_touch()
	_build_menu()

	# Keep keyboard focus off every shell button so a click doesn't leave it
	# holding focus and swallowing later keypresses (F / X / etc.) meant for
	# the camera or the loaded sample.
	_reset.focus_mode = Control.FOCUS_NONE
	_reset.pressed.connect(_on_reset)
	_debug_toggle.focus_mode = Control.FOCUS_NONE
	_debug_toggle.toggled.connect(_on_debug_toggled)
	_menu.focus_mode = Control.FOCUS_NONE
	_sidebar_toggle.focus_mode = Control.FOCUS_NONE
	_sidebar_toggle.toggled.connect(_on_sidebar_toggled)

	# Engine selector: same shell, different solver underneath.
	_engine_option.focus_mode = Control.FOCUS_NONE
	_engine_option.add_item("Box3D")
	_engine_option.add_item("Godot Physics")
	_engine_option.add_item("Jolt Physics")
	_engine_option.select(ENGINE_IDS.find(_engine))
	_engine_option.item_selected.connect(_on_engine_selected)
	# Switching engines means relaunching the process, which only desktop can
	# do; elsewhere the control would just close the app.
	# Android / iOS / Web cannot relaunch themselves, so the whole section
	# goes rather than leaving a heading and a hint over nothing.
	var can_switch := _can_restart()
	for node: Control in [_engine_sep, _engine_label, _engine_option, _engine_hint]:
		node.visible = can_switch
	# Labels ignore the mouse, and the full note list lives in the tooltip.
	_engine_note.mouse_filter = Control.MOUSE_FILTER_PASS
	_engine_note.visible = false

	# Shot mode: what F fires (a ball, or a fused bomb).
	_shot_mode.focus_mode = Control.FOCUS_NONE
	_shot_mode.add_item("Shot: Ball")
	_shot_mode.add_item("Shot: Bomb")
	_shot_mode.add_item("Shot: Ragdoll")
	_shot_mode.item_selected.connect(_on_shot_mode_selected)
	_blast_slider.focus_mode = Control.FOCUS_NONE
	_blast_slider.value_changed.connect(_on_blast_changed)
	_impact_check.focus_mode = Control.FOCUS_NONE
	_impact_check.toggled.connect(_on_impact_toggled)
	# The bar can fill up (bomb controls + a sample toggle + the hint text);
	# trim the hint with an ellipsis instead of letting it run under the
	# right-anchored Settings/Debug/Reset cluster.
	_info.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS

	# Reusable Activate button: calls activate() on samples that define one.
	_activate.focus_mode = Control.FOCUS_NONE
	_activate.pressed.connect(_on_activate)

	# Reusable sample toggle: shown for samples that define set_toggled(on),
	# labelled by their get_toggle_label() (the Car's third-person camera).
	_sample_toggle.focus_mode = Control.FOCUS_NONE
	_sample_toggle.toggled.connect(_on_sample_toggle)

	_camera.set_charge_bar(_charge_bar)

	_start_views.load(START_VIEWS_PATH)  # missing on first run, that's fine

	_sidebar.visible = false
	_set_start_btn.focus_mode = Control.FOCUS_NONE
	_set_start_btn.pressed.connect(_on_set_start_view)
	_clear_start_btn.focus_mode = Control.FOCUS_NONE
	_clear_start_btn.pressed.connect(_on_clear_start_view)
	_substep_spin.value_changed.connect(_on_substep_changed)
	_worker_spin.value_changed.connect(_on_worker_changed)
	_max_speed_spin.value_changed.connect(_on_max_speed_changed)
	_gravity_spin.value_changed.connect(_on_gravity_changed)
	_continuous_check.toggled.connect(_on_continuous_changed)
	_sleep_check.focus_mode = Control.FOCUS_NONE
	_sleep_check.toggled.connect(_on_sleep_changed)
	_recycling_check.focus_mode = Control.FOCUS_NONE
	_recycling_check.toggled.connect(_on_recycling_changed)
	# Hide the row on builds whose extension predates the property.
	var body_probe := Box3DBody.new()
	_has_recycling = "contact_recycling" in body_probe
	_recycling_check.visible = _has_recycling
	body_probe.free()
	_sidebar_debug_check.toggled.connect(_on_sidebar_debug_changed)
	_contact_hertz_spin.value_changed.connect(_on_contact_hertz_changed)
	_contact_damping_spin.value_changed.connect(_on_contact_damping_changed)
	_stats_check.focus_mode = Control.FOCUS_NONE
	_stats_check.toggled.connect(_on_stats_toggled)
	_profiler_check.focus_mode = Control.FOCUS_NONE
	_profiler_check.toggled.connect(_on_profiler_toggled)
	_async_check.focus_mode = Control.FOCUS_NONE
	_async_check.toggled.connect(_on_async_toggled)

	# V-Sync mode: a global display setting (never reset on sample load). The
	# control starts from whatever mode the window actually has, and after each
	# change reads the mode back — the platform may refuse one (e.g. mailbox),
	# and the dropdown should show reality, not the request.
	_vsync_option.focus_mode = Control.FOCUS_NONE
	_vsync_option.add_item("VSync: On")
	_vsync_option.add_item("VSync: Off")
	_vsync_option.add_item("VSync: Mailbox")
	_vsync_option.select(_vsync_index(DisplayServer.window_get_vsync_mode()))
	_vsync_option.item_selected.connect(_on_vsync_selected)

	_setup_reverts()

	_restore_overlay_state()
	_add_web_notice()

	# `-- --sample=Ragdoll` (case-insensitive) opens straight to that sample.
	# `-- --profiler` opens with the solver profiler already up, so a recording
	# setup does not have to click through the sidebar every launch.
	var wanted := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--sample="):
			wanted = arg.get_slice("=", 1).to_lower()
		elif arg == "--settings":
			_sidebar.visible = true
		elif arg == "--profiler":
			_profiler_check.set_pressed_no_signal(true)
			_profiler.visible = true
		elif arg.begins_with("--shot="):
			_shot_path = arg.get_slice("=", 1)
		elif arg.begins_with("--shot-tick="):
			_shot_tick = maxi(1, int(arg.get_slice("=", 1)))
	var first_cat: String = SAMPLES.keys()[0]
	var first_name: String = SAMPLES[first_cat].keys()[0]
	# The browser build opens somewhere lighter. Cube Pile is 4096 bodies and
	# asks for 4 solver workers; on web there is one, so it is the single worst
	# scene to land on first and it is the one everyone would land on. Measured
	# on this machine, natively: 0.39 ms/step at 4 workers vs 1.24 ms at 1, and
	# only while the pile is awake -- asleep it costs nothing either way.
	# Every sample is still one menu click away.
	if OS.has_feature("web") and not WEB_FIRST_SAMPLE.is_empty():
		for category in SAMPLES:
			if SAMPLES[category].has(WEB_FIRST_SAMPLE):
				first_cat = category
				first_name = WEB_FIRST_SAMPLE
	for category in SAMPLES:
		for sample_name in SAMPLES[category]:
			if sample_name.to_lower() == wanted:
				first_cat = category
				first_name = sample_name
	_load(SAMPLES[first_cat][first_name], first_name)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_TAB:
		_sidebar_toggle.button_pressed = not _sidebar_toggle.button_pressed


## The shell keeps FOCUS_NONE on every button (see _ready), but the sidebar's
## SpinBox text fields must take focus to be typed in — and a LineEdit holds it
## until something else takes it, so W A S D after editing a field kept typing
## into the field instead of flying the camera. Any mouse press outside the
## focused field commits the edit (focus_exited applies a SpinBox's text) and
## hands the keyboard back to the camera / sample.
func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		var focused := get_viewport().gui_get_focus_owner()
		if focused != null \
				and not focused.get_global_rect().has_point(focused.get_global_mouse_position()):
			focused.release_focus()


# --- Engine selection --------------------------------------------------------
#
# `-- --engine=box3d|godot|jolt`, written by the restart below (and usable by
# hand). The setting itself is never trusted: the live server is identified
# behaviourally a few ticks into the first sample.

func _parse_engine_arg() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--engine="):
			var id := arg.get_slice("=", 1).to_lower()
			if ENGINE_TITLES.has(id):
				_engine = id
			else:
				push_error("[engine] unknown engine '%s', running Box3D" % id)


func _native() -> bool:
	return _engine != "box3d"


## Relaunching is a desktop facility; Android, iOS and Web have no restart, so
## picking an engine there would only close the app.
func _can_restart() -> bool:
	return not (OS.get_name() in ["Android", "iOS", "Web"])


func _override_path() -> String:
	# Exported builds map res:// to the executable's directory, which is exactly
	# where Godot looks for override.cfg, so globalizing works in both layouts.
	return ProjectSettings.globalize_path("res://override.cfg")


func _sweep_override() -> void:
	var path := _override_path()
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)


## Godot ConfigFile: comments are ';', never '#'. Written just before the
## process restarts, consumed at the next startup, swept in _ready.
func _write_override(id: String) -> bool:
	var cfg := ConfigFile.new()
	cfg.set_value("physics", "3d/physics_engine", String(ENGINE_SETTINGS[id]))
	var err := cfg.save(_override_path())
	if err != OK:
		push_error("[engine] could not write %s (error %d)" % [_override_path(), err])
		return false
	return true


func _on_engine_selected(index: int) -> void:
	var id: String = String(ENGINE_IDS[index])
	if id == _engine or _restarting:
		_engine_option.select(ENGINE_IDS.find(_engine))
		return
	_restart_with_engine(id)


## The engine cannot change in-process, so this writes the override and comes
## back as a new process on the same sample.
func _restart_with_engine(id: String) -> void:
	_restarting = true
	_engine_option.disabled = true
	_info.text = "Switching to %s   ·   restarting the demo..." % ENGINE_TITLES[id]
	_info_flash_id += 1  # nothing should overwrite that message now
	# Order matters: a platform that cannot relaunch must not be left holding an
	# override.cfg that would switch the engine behind the user's back.
	if not _can_restart() or not _write_override(id):
		_restarting = false
		_engine_option.disabled = false
		_engine_option.select(ENGINE_IDS.find(_engine))
		_flash_info("Could not switch to %s: the demo cannot restart itself here."
				% ENGINE_TITLES[id])
		return
	var args := _restart_args(id)
	print("[engine] restarting on %s: %s" % [ENGINE_TITLES[id], " ".join(args)])
	if not _spawn_replacement(args):
		_restarting = false
		_engine_option.disabled = false
		_engine_option.select(ENGINE_IDS.find(_engine))
		_flash_info("Could not launch %s. Run the demo from a terminal and try again."
				% ENGINE_TITLES[id])
		return
	# Two frames so the message actually reaches the screen before the window
	# goes away.
	await get_tree().process_frame
	await get_tree().process_frame
	get_tree().quit()


## Start the replacement process, detached from this one.
##
## OS.set_restart_on_exit() looks like the right tool and is not: the process it
## spawns stays in OUR process group, so anything supervising this process takes
## the replacement down with it a moment later. That is exactly what happens
## when the demo is played from the Godot editor -- the editor owns the play
## session and reaps the group when the game exits -- and the symptom is an app
## that closes and never comes back. A shell that cleans up its job control does
## the same.
##
## `setsid` puts the replacement in a fresh session so nothing can reap it by
## association. It is util-linux, present on any Linux desktop, and the BSD/macOS
## layout is close enough to try. If it is missing, or on Windows, fall back to
## spawning directly, which is still correct when nobody is supervising us.
func _spawn_replacement(args: PackedStringArray) -> bool:
	var exe := OS.get_executable_path()
	if OS.get_name() not in ["Windows", "UWP"]:
		var detached := PackedStringArray([exe])
		detached.append_array(args)
		if OS.create_process("setsid", detached) > 0:
			return true
	return OS.create_process(exe, args) > 0


## Command line for the relaunch. OS.get_cmdline_args() holds what the engine
## did NOT consume (the scene path, if one was given), so `--path` is rebuilt
## rather than read back; an exported build carries its own project and must not
## get one. Everything after "--" is ours to rewrite, and that is where
## --engine / --sample live.
func _restart_args(id: String) -> PackedStringArray:
	var args := PackedStringArray()
	args.append_array(OS.get_cmdline_args())
	if OS.has_feature("editor"):
		args.append("--path")
		args.append(ProjectSettings.globalize_path("res://"))
	args.append("--")
	for arg in OS.get_cmdline_user_args():
		if not arg.begins_with("--engine=") and not arg.begins_with("--sample="):
			args.append(arg)
	args.append("--engine=%s" % id)
	if _current_name != "":
		args.append("--sample=%s" % _current_name)
	return args


## Which native server is ACTUALLY running.
##
## The project setting cannot be trusted: an unregistered name falls back to
## DEFAULT silently, so a typo would mislabel the whole session, and
## PhysicsServer3D.get_class() returns "PhysicsServer3D" for both native
## engines. Behaviour discriminates. JoltPhysicsServer3D::get_process_info() is
## literally `return 0;`, so these counters read the real numbers under
## GodotPhysics3D and zero under Jolt. Verified on 4.7.stable.
func _identify_native() -> String:
	if PhysicsServer3D.get_class() == "PhysicsServer3DDummy":
		return "Dummy"
	if _native_dynamic <= 0:
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
	_engine_probed = true
	if not _native():
		return
	var live := _identify_native()
	if live == "":
		return
	_engine_live = live
	var want: String = String(ENGINE_TITLES[_engine])
	if live != want:
		_engine_alert = "ENGINE MISMATCH: asked for %s, running %s" % [want, live]
		push_error("[engine] " + _engine_alert)
		print("[engine] " + _engine_alert)
	else:
		print("[engine] running %s (verified)" % live)
	_update_engine_note()
	var world = null if _current == null else _current.get_node_or_null("Box3DWorld")
	if world != null and "engine_name" in world:
		world.engine_name = live


## The badge beside the hint: what is really stepping the bodies, and how much
## of the sample the rig could not carry across. Box3D runs the scene as
## authored and has nothing to report, so it shows nothing at all.
func _update_engine_note() -> void:
	if not _native():
		_engine_note.visible = false
		return
	var parts := PackedStringArray()
	if _engine_alert != "":
		parts.append(_engine_alert)
	elif _engine_live != "":
		parts.append("Running: " + _engine_live)
	else:
		parts.append("Running: %s (unverified)" % ENGINE_TITLES[_engine])
	if not _native_notes.is_empty():
		parts.append("%d port note%s" % [_native_notes.size(),
				"" if _native_notes.size() == 1 else "s"])
	_engine_note.text = "   ·   ".join(parts)
	_engine_note.tooltip_text = "\n".join(PackedStringArray(_native_notes))
	_engine_note.modulate = Color(1, 0.45, 0.4) if _engine_alert != "" else Color(1, 0.8, 0.4)
	_engine_note.visible = true


## Phones/tablets: scale the whole UI up to a readable physical size, and add
## the touch overlay (virtual joystick / SHOOT / JUMP -- touch_controls.gd).
## Desktop has no touchscreen, so none of this runs there and the demo is
## exactly what it always was.
func _setup_touch() -> void:
	if not DisplayServer.is_touchscreen_available():
		return
	# The project lays the UI out for a 1080p desktop monitor. On a ~6 inch
	# 400+ dpi phone that UI is physically tiny, so scale the canvas by DPI:
	# 160 dpi (Android's mdpi baseline) keeps scale 1; a 420 dpi phone gets
	# ~2x. Capped so the top bar still fits a landscape phone's width.
	var dpi := DisplayServer.screen_get_dpi()
	get_window().content_scale_factor = clampf(dpi / 160.0, 1.0, 2.0)
	# At 2x the bar can outgrow the screen on samples with extra buttons; trim
	# the hint text with an ellipsis instead of letting it run under the
	# right-anchored Settings/Debug/Reset cluster.
	_info.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_touch = TouchControls.new()
	_touch.setup(_camera)
	add_child(_touch)


func _physics_process(_delta: float) -> void:
	_step_count += 1
	if _profiler.visible:
		_profiler.poll()
	if _shot_path != "" and _step_count == _shot_tick:
		_save_shot()
	# Identify the live server once per sample, late enough that its bodies are
	# awake -- that is what the probe reads.
	if _native() and not _engine_probed and _step_count >= ENGINE_PROBE_TICK:
		_check_engine()
	if _sidebar.visible:
		_update_readout()
	# Body counting is a full tree walk, so refresh the overlay's count at 1 Hz.
	if _stats_overlay.visible and _step_count % 60 == 0:
		_push_stats_bodies()
	# Catch bodies spawned after the toggle (emitters, shots): re-hide their
	# visuals every half second while the debug view is on. The walk touches
	# every node (16k+ in the big samples), so skip it while the tree hasn't
	# changed size — nothing new can need hiding then.
	if _debug_draw and _step_count % 30 == 0 and _current != null:
		var node_count := get_tree().get_node_count()
		if node_count != _debug_hidden_node_count:
			_debug_hidden_node_count = node_count
			var world = _current.get_node_or_null("Box3DWorld")
			if world != null:
				_hide_shelled_visuals(world)


func _on_reset() -> void:
	# Rebuild the physics demo from scratch but LEAVE THE CAMERA where it is, so
	# a view you flew to survives a reset.
	if _current_path != "":
		_load(_current_path, _current_name, true)


func _on_shot_mode_selected(index: int) -> void:
	if _camera.has_method("set_shot_kind"):
		_camera.set_shot_kind(index)
	# The blast slider only means something while F fires bombs.
	var bomb_mode := index == 1
	_blast_label.visible = bomb_mode
	_blast_slider.visible = bomb_mode
	_impact_check.visible = bomb_mode


func _on_impact_toggled(pressed: bool) -> void:
	if "bomb_impact_detonation" in _camera:
		_camera.bomb_impact_detonation = pressed


func _on_blast_changed(value: float) -> void:
	_blast_label.text = "Blast: %d" % int(value)
	if "bomb_blast_impulse" in _camera:
		_camera.bomb_blast_impulse = value


func _on_activate() -> void:
	# Reusable: fire the current sample's activate() action, if it has one.
	if _current != null and _current.has_method("activate"):
		_current.activate()


func _on_sample_toggle(pressed: bool) -> void:
	if _current != null and _current.has_method("set_toggled"):
		_current.set_toggled(pressed)


func _on_debug_toggled(pressed: bool) -> void:
	# Global overlay: draw every body's collider wireframe in the current sample.
	_debug_draw = pressed
	_sidebar_debug_check.set_pressed_no_signal(pressed)
	_apply_debug()


func _apply_debug() -> void:
	if _current == null:
		return
	var world = _current.get_node_or_null("Box3DWorld")
	if world != null and "debug_draw" in world:
		world.debug_draw = _debug_draw
	# The debug shells REPLACE the sample's look, like upstream's viewer: hide
	# every shelled body's own visuals so nothing pokes through the shells, and
	# restore them when the toggle goes off.
	if _debug_draw:
		if world != null:
			_hide_shelled_visuals(world)
			_debug_hidden_node_count = get_tree().get_node_count()
	else:
		for mi in _debug_hidden:
			if is_instance_valid(mi):
				mi.visible = true
		_debug_hidden.clear()
		_debug_hidden_node_count = -1


## Bodies the world shells (primitive shape types or compound children) get
## their MeshInstance3D visuals hidden. Hull/mesh bodies and bodies opted out
## via debug_visualize keep their looks — they have no shell covering them.
func _hide_shelled_visuals(node: Node) -> void:
	if node is Box3DBody and node.debug_visualize:
		var shelled: bool = node.shape_type <= Box3DBody.CONE
		if not shelled:
			for child in node.get_children():
				if child is Box3DCollisionShape:
					shelled = true
					break
		if shelled:
			_hide_visuals_under(node)
			return
	for child in node.get_children():
		_hide_shelled_visuals(child)


func _hide_visuals_under(node: Node) -> void:
	for child in node.get_children():
		if child is MeshInstance3D and child.visible:
			child.visible = false
			_debug_hidden.append(child)
		_hide_visuals_under(child)


func _on_sidebar_toggled(pressed: bool) -> void:
	_sidebar.visible = pressed
	if pressed:
		_update_readout()


# --- Sidebar: live-edit the current sample's Box3DWorld ---

func _with_world(fn: Callable) -> void:
	if _current == null:
		return
	var world = _current.get_node_or_null("Box3DWorld")
	if world != null:
		fn.call(world)


func _on_substep_changed(value: float) -> void:
	if _updating_sidebar:
		return
	_with_world(func(world):
		if "substep_count" in world:
			world.substep_count = int(value))


func _on_worker_changed(value: float) -> void:
	if _updating_sidebar:
		return
	_worker_override = int(value)
	if _current_path != "":
		_load(_current_path, _current_name, true)


func _on_max_speed_changed(value: float) -> void:
	if _updating_sidebar:
		return
	_with_world(func(world):
		if "max_linear_speed" in world:
			world.max_linear_speed = value)


func _on_gravity_changed(value: float) -> void:
	if _updating_sidebar:
		return
	_with_world(func(world):
		var g: Vector3 = world.gravity
		g.y = value
		world.gravity = g)


func _on_continuous_changed(pressed: bool) -> void:
	if _updating_sidebar:
		return
	_with_world(func(world):
		if "continuous_collision" in world:
			world.continuous_collision = pressed)


func _on_sidebar_debug_changed(pressed: bool) -> void:
	if _updating_sidebar:
		return
	_debug_draw = pressed
	_debug_toggle.set_pressed_no_signal(pressed)
	_apply_debug()


func _on_profiler_toggled(pressed: bool) -> void:
	_profiler.visible = pressed
	_save_overlay_state()


func _on_stats_toggled(pressed: bool) -> void:
	_stats_overlay.visible = pressed
	if pressed:
		_push_stats_bodies()
	_save_overlay_state()


func _on_async_toggled(pressed: bool) -> void:
	if _updating_sidebar:
		return
	_async_step = pressed
	_apply_async()


## Dropdown order for the V-Sync control; indices match the items added in
## _ready. Adaptive isn't offered (it behaves like On above the refresh rate),
## so an externally-set adaptive mode just displays as On until changed here.
const _VSYNC_MODES: Array = [
	DisplayServer.VSYNC_ENABLED,
	DisplayServer.VSYNC_DISABLED,
	DisplayServer.VSYNC_MAILBOX,
]


func _vsync_index(mode: int) -> int:
	var i: int = _VSYNC_MODES.find(mode)
	return i if i >= 0 else 0


func _on_vsync_selected(index: int) -> void:
	DisplayServer.window_set_vsync_mode(_VSYNC_MODES[index])
	# Reflect what the platform actually granted (select() doesn't re-signal).
	_vsync_option.select(_vsync_index(DisplayServer.window_get_vsync_mode()))


## async_step toggles live (the world absorbs any in-flight step when turned
## off), so unlike worker_count no reload is needed.
func _apply_async() -> void:
	_with_world(func(world):
		if "async_step" in world:
			world.async_step = _async_step)


func _push_stats_bodies() -> void:
	if _current == null:
		_stats_overlay.bodies = -1
		_stats_overlay.world = null
		return
	var world = _current.get_node_or_null("Box3DWorld")
	_stats_overlay.bodies = _count_bodies(world) if world != null else -1
	# The overlay samples the solver itself every tick; it just needs the handle.
	_stats_overlay.world = world


# --- Start view: fly the camera somewhere, save it as this sample's spawn ---

func _on_set_start_view() -> void:
	if _current_path == "":
		return
	var xform: Transform3D = _camera.global_transform
	_start_views.set_value("views", _current_path, xform)
	_start_views.save(START_VIEWS_PATH)
	# Authoring helper: the same pose as a scene-file line, ready to paste onto
	# a sample's CameraStart node in the editor to ship it in the repo.
	DisplayServer.clipboard_set("transform = " + var_to_str(xform))
	_flash_info("Start view saved for %s   ·   transform also copied to clipboard" % _current_name)


func _on_clear_start_view() -> void:
	if _current_path == "":
		return
	if _start_views.has_section_key("views", _current_path):
		_start_views.erase_section_key("views", _current_path)
		_start_views.save(START_VIEWS_PATH)
	_flash_info("Start view cleared for %s (scene default applies on next load)" % _current_name)


## Show a transient message in the info bar, then restore the controls hint.
## The id check keeps a stale timer from clobbering a newer message or sample.
var _info_flash_id := 0

func _flash_info(msg: String) -> void:
	_info_flash_id += 1
	var id := _info_flash_id
	_info.text = msg
	await get_tree().create_timer(3.0).timeout
	if id == _info_flash_id:
		_show_controls_hint()


func _show_controls_hint() -> void:
	if _touch != null:
		_info.text = "%s      Stick: move   ·   Drag: look   ·   Touch a body: grab   ·   Two fingers: zoom / pan" % _current_name
	else:
		_info.text = "%s      Right-click: fly (WASD / Q E, Shift boost)   ·   Left-drag: grab (scroll: reel)   ·   Hold F: charge shot" % _current_name


func _on_contact_hertz_changed(value: float) -> void:
	if _updating_sidebar:
		return
	_contact_hertz_override = value
	_with_world(func(world):
		if "contact_hertz" in world:
			world.contact_hertz = value)


func _on_contact_damping_changed(value: float) -> void:
	if _updating_sidebar:
		return
	_contact_damping_override = value
	_with_world(func(world):
		if "contact_damping" in world:
			world.contact_damping = value)


func _on_sleep_changed(pressed: bool) -> void:
	if _updating_sidebar:
		return
	_with_world(func(world):
		if "enable_sleep" in world:
			world.enable_sleep = pressed)


func _on_recycling_changed(pressed: bool) -> void:
	if _updating_sidebar:
		return
	_with_world(func(world): _set_recycling(world, pressed))


func _set_recycling(node: Node, on: bool) -> void:
	if node is Box3DBody and "contact_recycling" in node:
		node.contact_recycling = on
	for child in node.get_children():
		_set_recycling(child, on)


## Controls backed by a Box3DWorld property and by nothing else. NativeWorld
## deliberately omits those properties, so one probe decides the whole set --
## and each control's PARENT is its row: the authored HBox for the spin boxes,
## the wrapper _add_revert built around each standalone check.
func _set_box3d_rows_visible(on: bool) -> void:
	for ctrl: Control in [_substep_spin, _worker_spin, _max_speed_spin,
			_continuous_check, _sleep_check, _sidebar_debug_check]:
		var row := ctrl.get_parent()
		if row is Control:
			(row as Control).visible = on
	var recycling_row := _recycling_check.get_parent()
	if recycling_row is Control:
		(recycling_row as Control).visible = on and _has_recycling
	# The debug shells are drawn by the Box3D world itself; there is nothing
	# behind the toggle on a native engine.
	_debug_toggle.visible = on


# Pull the just-loaded sample's world settings into the sidebar controls
# without re-triggering the handlers above.
func _refresh_sidebar_from_world(world) -> void:
	_updating_sidebar = true
	# Reading these off a NativeWorld would error, and showing them would leave
	# dead controls on screen, so one probe gates both. With no world at all the
	# rows are left exactly as they were, as they always have been.
	var box3d_world: bool = world != null and "substep_count" in world
	if world != null:
		_set_box3d_rows_visible(box3d_world)
		if box3d_world:
			_substep_spin.set_value_no_signal(world.substep_count)
			_worker_spin.set_value_no_signal(world.worker_count)
			_max_speed_spin.set_value_no_signal(world.max_linear_speed)
			_continuous_check.set_pressed_no_signal(world.continuous_collision)
		_gravity_spin.set_value_no_signal(world.gravity.y)
		_sidebar_debug_check.set_pressed_no_signal(_debug_draw)
		if "enable_sleep" in world:
			_sleep_check.set_pressed_no_signal(world.enable_sleep)
		# A fresh sample's bodies start with recycling on (the Box3D default).
		_recycling_check.set_pressed_no_signal(true)
		# The async checkbox reflects the sticky user preference, and hides on
		# builds whose extension predates the property.
		_async_check.visible = "async_step" in world
		_async_hint.visible = _async_check.visible
		_async_check.set_pressed_no_signal(_async_step)
		# contact_hertz / contact_damping arrived together in the binding; show
		# their rows only when the loaded build actually exposes them.
		var has_hertz: bool = "contact_hertz" in world
		_contact_hertz_row.visible = has_hertz
		_contact_damping_row.visible = has_hertz
		if has_hertz:
			_contact_hertz_spin.set_value_no_signal(world.contact_hertz)
			_contact_damping_spin.set_value_no_signal(world.contact_damping)
	else:
		_contact_hertz_row.visible = false
		_contact_damping_row.visible = false
	_updating_sidebar = false
	_update_readout()


## Body counting walks the whole sample tree, which is real work at 16k+
## bodies — refresh the cached count at most once a second.
var _body_count_cache := -1
var _body_count_step := -999


func _update_readout() -> void:
	var world = null if _current == null else _current.get_node_or_null("Box3DWorld")
	if world == null:
		_readout.text = "Physics Steps: %d\nBodies: --" % _step_count
		return
	if _step_count - _body_count_step >= 60 or _body_count_cache < 0:
		# Samples nest bodies under sub-nodes (e.g. Blocks): count descendants.
		_body_count_cache = _count_bodies(world)
		_body_count_step = _step_count
	var text := "Physics Steps: %d\nBodies: %d" % [_step_count, _body_count_cache]
	# On a native engine the readout also answers "which solver is this really",
	# from the behavioural probe rather than from the setting we asked for.
	if _native():
		var live := _engine_live
		if live == "":
			live = "%s (unverified)" % ENGINE_TITLES[_engine]
		text += "\nEngine: %s" % live
	_readout.text = text


func _count_bodies(node: Node) -> int:
	var n := 0
	for child in node.get_children():
		# PhysicsBody3D covers the rebuilt rig on a native engine; no sample has
		# one, so the Box3D count is unchanged.
		if child is Box3DBody or child is PhysicsBody3D:
			n += 1
		n += _count_bodies(child)
	return n


func _build_menu() -> void:
	# One popup with a labeled separator per category, an item per sample.
	var popup: PopupMenu = _menu.get_popup()
	popup.clear()
	_items.clear()
	var id := 0
	for category in SAMPLES:
		popup.add_separator(category)
		for sample_name in SAMPLES[category]:
			popup.add_item(sample_name, id)
			_items[id] = {"path": SAMPLES[category][sample_name], "name": sample_name}
			id += 1
	if not popup.id_pressed.is_connected(_on_menu_id):
		popup.id_pressed.connect(_on_menu_id)


func _on_menu_id(id: int) -> void:
	var entry: Dictionary = _items.get(id, {})
	if entry.is_empty():
		return
	_load(entry["path"], entry["name"])


func _load(path: String, sample_name: String, keep_camera := false) -> void:
	var fresh_sample := path != _current_path
	if fresh_sample:
		_worker_override = -1
		_contact_hertz_override = -1.0
		_contact_damping_override = -1.0
	_debug_hidden.clear()  # the old sample's nodes are freed with it
	if _current != null:
		# Free immediately, not deferred: a queued free would leave both the
		# old and new sample alive within one frame, and two 4096-cube piles
		# overflow the per-instance shader parameter buffer (black cubes).
		_current.free()
		_current = null
	if _native():
		# Native engines cannot run the authored scene at all -- 18 samples
		# carry `: Box3DBody` annotations and common/cube.gd literally extends
		# it -- so the scene is read into a backend-neutral rig and rebuilt with
		# RigidBody3D and friends. _build_native parents the result itself: a
		# body only joins the space once it is in the tree.
		_current_path = path
		_current_name = sample_name
		_current = _build_native(path)
	else:
		var scene: PackedScene = load(path)
		if scene == null:
			return
		_current = scene.instantiate()
		_current_path = path
		_current_name = sample_name
		# worker_count only takes effect at world creation, so apply the override
		# before add_child triggers _ready.
		if _worker_override > 0:
			var override_world = _current.get_node_or_null("Box3DWorld")
			if override_world != null:
				override_world.worker_count = _worker_override
		_host.add_child(_current)
	_step_count = 0
	_body_count_cache = -1
	_engine_probed = false
	var world = _current.get_node_or_null("Box3DWorld")
	if world != null and _camera.has_method("set_world"):
		if keep_camera:
			# Reset: rebuild the world but don't move the camera.
			_camera.set_world_keep_view(world)
		else:
			_camera.set_world(world)
			# Spawn view, by priority:
			# 1. A view saved at runtime with the sidebar's "Set Start View"
			#    button (fly to the shot, click, done).
			# 2. A node named CameraStart at the scene root. Make it a
			#    Camera3D: the editor then shows a frustum, a Preview
			#    checkbox, and View > Align Transform with View (fly the
			#    editor camera to the shot, then snap the node to it). The
			#    spawn view faces the node's -Z; give it a Node3D child named
			#    LookAt and the view aims at that point instead — two
			#    draggable position gizmos, no rotation rings.
			# 3. Script-exported camera_home / camera_look_at Vector3s.
			# (has_section_key first: get_value treats a null default as "no
			# default" and logs an error for samples with no saved view.)
			var saved_view = null
			if _start_views.has_section_key("views", path):
				saved_view = _start_views.get_value("views", path)
			var cam_start = _current.get_node_or_null("CameraStart")
			if saved_view is Transform3D:
				_camera.frame_view(saved_view.origin,
						saved_view.origin - saved_view.basis.z)
			elif cam_start is Node3D:
				var eye: Vector3 = cam_start.global_position
				var target: Vector3 = eye - cam_start.global_basis.z
				var aim = cam_start.get_node_or_null("LookAt")
				if aim is Node3D and not aim.global_position.is_equal_approx(eye):
					target = aim.global_position
				_camera.frame_view(eye, target)
			elif "camera_home" in _current and "camera_look_at" in _current:
				_camera.frame_view(_current.camera_home, _current.camera_look_at)
	# Reapply sticky contact tuning (survives Reset, cleared on sample switch).
	if world != null and _contact_hertz_override > 0.0 and "contact_hertz" in world:
		world.contact_hertz = _contact_hertz_override
	if world != null and _contact_damping_override > 0.0 and "contact_damping" in world:
		world.contact_damping = _contact_damping_override
	_apply_debug()  # carry the debug-draw toggle into the newly loaded sample
	_apply_async()  # same for the async-step preference
	if _stats_overlay.visible:
		_push_stats_bodies()
	_refresh_sidebar_from_world(world)
	_attach_profiler(world)
	# A newly picked sample defines fresh "original" values for the world
	# rows; a Reset of the same sample keeps them (so sticky tuning that
	# survived the reload still shows its revert button).
	if fresh_sample and not _reverts.is_empty():
		_capture_world_baselines()
	_update_all_reverts()
	# Show the Activate button only for samples that expose an activate() action.
	_activate.visible = _current != null and _current.has_method("activate")
	# Same idea for the sample toggle (set_toggled + get_toggle_label). A fresh
	# load always starts un-toggled.
	var has_toggle: bool = _current != null and _current.has_method("set_toggled")
	_sample_toggle.visible = has_toggle
	_sample_toggle.set_pressed_no_signal(false)
	if has_toggle and _current.has_method("get_toggle_label"):
		_sample_toggle.text = _current.get_toggle_label()
	if _touch != null:
		_touch.set_sample(path)  # joystick/JUMP/key pills for samples that use them
	_info_flash_id += 1  # cancel any pending flash from the previous sample
	_show_controls_hint()
	_update_engine_note()  # this sample's port notes, if it is running natively


# --- Native engines: the same sample, rebuilt for another solver -------------

## Build one sample for Godot Physics or Jolt.
##
## RigExtract reads the authored scene into a backend-neutral description --
## PackedScene.instantiate() runs _init only, so no Box3DWorld is created and no
## sample script fires -- and RigNative rebuilds it with RigidBody3D /
## CollisionShape3D / Joint3D, correcting mass, inertia, materials and collision
## filtering so the solver is the only thing that differs.
##
## The result is shaped like a sample scene on purpose: a root Node3D whose
## child "Box3DWorld" holds the bodies, because that name is what the shell, the
## camera and tests/test_shoot.gd all reach for.
func _build_native(path: String) -> Node3D:
	var stage := Node3D.new()
	stage.name = "Sample"
	var world := NativeWorld.new()
	world.name = "Box3DWorld"
	world.engine_name = ENGINE_TITLES[_engine]
	stage.add_child(world)
	# In the tree BEFORE the rig is built: a body registers with the space when
	# it enters, and NativeWorld reaches the space through the viewport.
	_host.add_child(stage)

	var rig := RigExtract.from_scene(path)
	var built := RigNative.build(rig, world)
	# Per-world gravity has no native node equivalent; NativeWorld forwards it to
	# the space. 30 of the 32 samples set a value of their own.
	var gravity: Vector3 = rig.get("gravity", Vector3(0, -9.8, 0))
	world.gravity = gravity

	_native_dynamic = 0
	for body in built.get("bodies", []):
		if body is RigidBody3D:
			_native_dynamic += 1
	_native_notes = []
	_native_notes.append_array(rig.get("unsupported", []))
	_native_notes.append_array(built.get("warnings", []))
	for note in _native_notes:
		print("[engine] %s: %s" % [path.get_file(), note])

	_add_native_dressing(path, stage)
	return stage


## Everything the rig does not carry.
##
## Samples park decorative meshes directly under the scene root, OUTSIDE the
## Box3DWorld -- wrecking's gantry post and arm, marble_run's chute, the Label3D
## captions -- and RigExtract only walks the world, so without this they simply
## vanish. Meshes that belong to a body are already rebuilt as that body's
## visuals and are skipped by the world test.
##
## The same throwaway instance also yields a CameraStart marker, which is what
## lets the shell's own spawn-view code below run unchanged on both engines.
func _add_native_dressing(path: String, stage: Node3D) -> void:
	var packed: PackedScene = load(path)
	if packed == null:
		return
	var root := packed.instantiate()
	if root == null:
		return
	var world := root.get_node_or_null("Box3DWorld")
	var deco := Node3D.new()
	deco.name = "Decoration"
	stage.add_child(deco)
	for node in root.find_children("*", "VisualInstance3D", true, false):
		if world != null and world.is_ancestor_of(node):
			continue
		# A nested visual already travelled inside its parent's duplicate;
		# copying it again would draw it twice.
		if _has_visual_ancestor(node, root):
			continue
		var xf := _relative_xform(node as Node3D, root)
		var copy := (node as Node3D).duplicate(0) as Node3D
		_strip_scripts(copy)
		deco.add_child(copy)
		copy.transform = xf
	_add_camera_marker(root, stage)
	root.free()


func _has_visual_ancestor(node: Node, root: Node) -> bool:
	var n: Node = node.get_parent()
	while n != null and n != root:
		if n is VisualInstance3D:
			return true
		n = n.get_parent()
	return false


## Transform of `node` relative to `root`, accumulated by walking up: the scene
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


## Reduce whichever spawn view the sample declares -- a CameraStart node with an
## optional LookAt child, or exported camera_home / camera_look_at Vector3s --
## to the CameraStart form, so _load's framing code needs no native branch. A
## plain Node3D, not a copy of the authored Camera3D: a second Camera3D entering
## the tree can take over the viewport.
func _add_camera_marker(root: Node, stage: Node3D) -> void:
	var marker := Node3D.new()
	marker.name = "CameraStart"
	var cam_start := root.get_node_or_null("CameraStart")
	if cam_start is Node3D:
		marker.transform = _relative_xform(cam_start as Node3D, root)
		var authored_aim := cam_start.get_node_or_null("LookAt")
		if authored_aim is Node3D:
			marker.add_child(_look_at_marker((authored_aim as Node3D).position))
	elif "camera_home" in root and "camera_look_at" in root:
		var home: Vector3 = root.camera_home
		var target: Vector3 = root.camera_look_at
		marker.position = home
		# LookAt is read in the marker's own space, and the marker is unrotated.
		marker.add_child(_look_at_marker(target - home))
	else:
		marker.free()  # never entered the tree, so nothing else will free it
		return
	stage.add_child(marker)


func _look_at_marker(local: Vector3) -> Node3D:
	var aim := Node3D.new()
	aim.name = "LookAt"
	aim.position = local
	return aim


# --- Settings revert buttons: a small "⟲" appears next to any sidebar
# control whose value differs from its baseline (what the sample loaded
# with, or the shell's startup default) and puts it back on click. ---

var _reverts := {}  ## Control -> {"btn": Button, "baseline": Variant}


func _revert_value(ctrl: Control) -> Variant:
	if ctrl is SpinBox:
		return (ctrl as SpinBox).value
	if ctrl is OptionButton:
		return (ctrl as OptionButton).selected
	return (ctrl as BaseButton).button_pressed  # CheckBox / CheckButton


func _revert_apply(ctrl: Control, value: Variant) -> void:
	# Set THROUGH the signal so the normal handler applies the change.
	if ctrl is SpinBox:
		(ctrl as SpinBox).value = value
	elif ctrl is OptionButton:
		(ctrl as OptionButton).selected = value
		(ctrl as OptionButton).item_selected.emit(value)
	else:
		(ctrl as BaseButton).button_pressed = value


func _revert_changed(a: Variant, b: Variant) -> bool:
	if a is float and b is float:
		return not is_equal_approx(a, b)
	return a != b


func _update_revert(ctrl: Control) -> void:
	var info: Dictionary = _reverts.get(ctrl, {})
	if info.is_empty():
		return
	(info["btn"] as Button).visible = _revert_changed(_revert_value(ctrl), info["baseline"])


func _set_revert_baseline(ctrl: Control, value: Variant) -> void:
	if ctrl in _reverts:
		_reverts[ctrl]["baseline"] = value
		_update_revert(ctrl)


func _add_revert(ctrl: Control) -> void:
	var btn := Button.new()
	btn.text = "\u27F2"
	btn.focus_mode = Control.FOCUS_NONE
	btn.visible = false
	btn.tooltip_text = "Revert to the original value"
	btn.pressed.connect(func() -> void:
		_revert_apply(ctrl, _reverts[ctrl]["baseline"])
		_update_revert(ctrl))
	var parent := ctrl.get_parent()
	if parent is HBoxContainer:
		parent.add_child(btn)
	else:
		# Standalone checkbox in the VBox: wrap it in a row so the button
		# can sit beside it. Node identity survives, signals stay wired.
		var row := HBoxContainer.new()
		var idx := ctrl.get_index()
		parent.remove_child(ctrl)
		parent.add_child(row)
		parent.move_child(row, idx)
		row.add_child(ctrl)
		ctrl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(btn)
	_reverts[ctrl] = {"btn": btn, "baseline": _revert_value(ctrl)}
	# Any user change re-evaluates the button (set_*_no_signal paths are
	# handled by _update_all_reverts after a sidebar refresh instead).
	if ctrl is SpinBox:
		(ctrl as SpinBox).value_changed.connect(func(_v: float) -> void: _update_revert(ctrl))
	elif ctrl is OptionButton:
		(ctrl as OptionButton).item_selected.connect(func(_i: int) -> void: _update_revert(ctrl))
	else:
		(ctrl as BaseButton).toggled.connect(func(_on: bool) -> void: _update_revert(ctrl))


func _setup_reverts() -> void:
	for c in [_substep_spin, _worker_spin, _max_speed_spin, _gravity_spin,
			_continuous_check, _sleep_check, _recycling_check,
			_sidebar_debug_check, _stats_check, _async_check, _vsync_option,
			_contact_hertz_spin, _contact_damping_spin]:
		_add_revert(c)


## Fresh sample load: the values just pushed into the world controls ARE the
## originals for this sample. Shell-level controls (debug, stats, async,
## vsync) keep their startup baselines.
func _capture_world_baselines() -> void:
	for c in [_substep_spin, _worker_spin, _max_speed_spin, _gravity_spin,
			_continuous_check, _sleep_check, _recycling_check,
			_contact_hertz_spin, _contact_damping_spin]:
		_set_revert_baseline(c, _revert_value(c))


func _update_all_reverts() -> void:
	for c in _reverts:
		_update_revert(c)


## Point the solver profiler at the freshly loaded world.
##
## The feed differs per engine and the row set differs with it (Box3D reports
## all 22 b3Profile phases; the native servers expose no solver timing to a
## running game at all, so theirs is a single wall-clock total). Re-attaching
## per sample is also what clears the ring, so two samples never share history.
func _attach_profiler(world) -> void:
	if _profiler == null:
		return
	_profiler.accent = ENGINE_ACCENTS.get(_engine, Color(0.35, 0.85, 1.0))
	_profiler.set_feed(ProfileFeeds.make(_engine, world if not _native() else null))
	_profiler.reset()


## `-- --shot=out.png --shot-tick=200` renders one frame and quits. Captures the
## game viewport only, never the desktop, so it is safe to run on a machine that
## is streaming, and it lands the same physics tick on every engine, which is
## what makes three captures of a sample directly comparable.
func _save_shot() -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var err := img.save_png(_shot_path)
	print("[shot] %s -> %s" % [_shot_path, "ok" if err == OK else str(err)])
	get_tree().quit()


## Whether the two overlays are up, remembered across launches.
##
## Switching engine relaunches the process, so anything not on disk is lost --
## and having the profiler vanish every time you change solver is exactly wrong
## for the one workflow it exists to serve, which is comparing the same scene on
## two engines. The panels already persist their own geometry to this file
## (stats_overlay.gd on drag, profiler_panel.gd on drag, resize and expand), so
## this only adds whether they are shown.
const SHELL_LAYOUT_PATH := "user://ui.cfg"


func _restore_overlay_state() -> void:
	var layout := ConfigFile.new()
	if layout.load(SHELL_LAYOUT_PATH) != OK:
		return
	# has_section_key first: a null default makes ConfigFile log an engine error
	# for any file that lacks the section.
	if layout.has_section_key("shell", "stats_overlay"):
		var on := bool(layout.get_value("shell", "stats_overlay"))
		_stats_check.set_pressed_no_signal(on)
		_stats_overlay.visible = on
	if layout.has_section_key("shell", "solver_profiler"):
		var on := bool(layout.get_value("shell", "solver_profiler"))
		_profiler_check.set_pressed_no_signal(on)
		_profiler.visible = on


func _save_overlay_state() -> void:
	var layout := ConfigFile.new()
	layout.load(SHELL_LAYOUT_PATH)  # keep the panels' own sections intact
	layout.set_value("shell", "stats_overlay", _stats_overlay.visible)
	layout.set_value("shell", "solver_profiler", _profiler.visible)
	layout.save(SHELL_LAYOUT_PATH)


## Browser-only banner. The web build exists so people can try the project
## before installing anything, and it is slower than the real thing twice over:
## wasm costs something across the board, and the solver is single-threaded
## because a threaded module cannot link without cross-origin isolation, which
## static hosting does not provide. Someone judging performance from the page
## would be judging the wrong build, so the page says so itself. Dismissible,
## and never built on any other platform.
func _add_web_notice() -> void:
	if not OS.has_feature("web"):
		return
	var panel := PanelContainer.new()
	panel.name = "WebNotice"
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.09, 0.12, 0.92)
	style.border_color = Color(1.0, 0.78, 0.42, 0.9)
	style.set_border_width_all(0)
	style.border_width_top = 2
	style.content_margin_left = 14.0
	style.content_margin_right = 8.0
	style.content_margin_top = 7.0
	style.content_margin_bottom = 7.0
	panel.add_theme_stylebox_override("panel", style)
	panel.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	panel.grow_vertical = Control.GROW_DIRECTION_BEGIN

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	panel.add_child(row)

	var label := Label.new()
	# The threaded build (hosted with real COOP/COEP headers) runs the solver
	# on multiple workers; the single-threaded fallback does not. Same banner,
	# honest wording for each.
	if OS.has_feature("threads"):
		label.text = "Browser preview on WebGL2. Faster than the fallback build, still not how the project is meant to run -- for real performance, run the demo natively in Godot."
	else:
		label.text = "Browser preview: single-threaded solver on WebGL2. This is not how the project is meant to run -- for real performance, run the demo natively in Godot."
	label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.6))
	label.add_theme_font_size_override("font_size", 15)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	row.add_child(label)

	var link := LinkButton.new()
	link.text = "Get the native demo"
	link.underline = LinkButton.UNDERLINE_MODE_ALWAYS
	link.add_theme_font_size_override("font_size", 15)
	link.focus_mode = Control.FOCUS_NONE
	link.pressed.connect(func() -> void:
		OS.shell_open("https://github.com/Stink-O/box3d-godot"))
	row.add_child(link)

	var close := Button.new()
	close.text = "X"
	close.flat = true
	close.focus_mode = Control.FOCUS_NONE
	close.pressed.connect(panel.queue_free)
	row.add_child(close)

	$UI.add_child(panel)
