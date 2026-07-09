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

@onready var _host: Node3D = $SampleHost
@onready var _camera: Camera3D = $Camera3D
@onready var _menu: MenuButton = $UI/Bar/Menu
@onready var _shot_mode: OptionButton = $UI/Bar/ShotMode
@onready var _activate: Button = $UI/Bar/Activate
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
@onready var _sidebar_debug_check: CheckBox = $UI/Sidebar/Margin/VBox/DebugDrawCheck
@onready var _contact_hertz_row: Control = $UI/Sidebar/Margin/VBox/ContactHertzRow
@onready var _contact_hertz_spin: SpinBox = $UI/Sidebar/Margin/VBox/ContactHertzRow/ContactHertzSpin
@onready var _readout: Label = $UI/Sidebar/Margin/VBox/Readout

var _current: Node = null
var _items: Dictionary = {}  ## popup item id -> {path, name}
var _current_path := ""
var _current_name := ""
var _debug_draw := false
var _step_count := 0
var _updating_sidebar := false  ## guard while pushing values into the controls


func _ready() -> void:
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

	# Shot mode: what F fires (a ball, or a fused bomb).
	_shot_mode.focus_mode = Control.FOCUS_NONE
	_shot_mode.add_item("Shot: Ball")
	_shot_mode.add_item("Shot: Bomb")
	_shot_mode.item_selected.connect(_on_shot_mode_selected)

	# Reusable Activate button: calls activate() on samples that define one.
	_activate.focus_mode = Control.FOCUS_NONE
	_activate.pressed.connect(_on_activate)

	_camera.set_charge_bar(_charge_bar)

	_sidebar.visible = false
	_substep_spin.value_changed.connect(_on_substep_changed)
	_worker_spin.value_changed.connect(_on_worker_changed)
	_max_speed_spin.value_changed.connect(_on_max_speed_changed)
	_gravity_spin.value_changed.connect(_on_gravity_changed)
	_continuous_check.toggled.connect(_on_continuous_changed)
	_sidebar_debug_check.toggled.connect(_on_sidebar_debug_changed)
	_contact_hertz_spin.value_changed.connect(_on_contact_hertz_changed)

	var first_cat: String = SAMPLES.keys()[0]
	var first_name: String = SAMPLES[first_cat].keys()[0]
	_load(SAMPLES[first_cat][first_name], first_name)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_TAB:
		_sidebar_toggle.button_pressed = not _sidebar_toggle.button_pressed


func _physics_process(_delta: float) -> void:
	_step_count += 1
	if _sidebar.visible:
		_update_readout()


func _on_reset() -> void:
	# Rebuild the physics demo from scratch but LEAVE THE CAMERA where it is, so
	# a view you flew to survives a reset.
	if _current_path != "":
		_load(_current_path, _current_name, true)


func _on_shot_mode_selected(index: int) -> void:
	if _camera.has_method("set_bomb_mode"):
		_camera.set_bomb_mode(index == 1)


func _on_activate() -> void:
	# Reusable: fire the current sample's activate() action, if it has one.
	if _current != null and _current.has_method("activate"):
		_current.activate()


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
	_with_world(func(world): world.substep_count = int(value))


func _on_worker_changed(value: float) -> void:
	if _updating_sidebar:
		return
	_with_world(func(world): world.worker_count = int(value))


func _on_max_speed_changed(value: float) -> void:
	if _updating_sidebar:
		return
	_with_world(func(world): world.max_linear_speed = value)


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
	_with_world(func(world): world.continuous_collision = pressed)


func _on_sidebar_debug_changed(pressed: bool) -> void:
	if _updating_sidebar:
		return
	_debug_draw = pressed
	_debug_toggle.set_pressed_no_signal(pressed)
	_apply_debug()


func _on_contact_hertz_changed(value: float) -> void:
	if _updating_sidebar:
		return
	_with_world(func(world):
		if "contact_hertz" in world:
			world.contact_hertz = value)


# Pull the just-loaded sample's world settings into the sidebar controls
# without re-triggering the handlers above.
func _refresh_sidebar_from_world(world) -> void:
	_updating_sidebar = true
	if world != null:
		_substep_spin.set_value_no_signal(world.substep_count)
		_worker_spin.set_value_no_signal(world.worker_count)
		_max_speed_spin.set_value_no_signal(world.max_linear_speed)
		_gravity_spin.set_value_no_signal(world.gravity.y)
		_continuous_check.set_pressed_no_signal(world.continuous_collision)
		_sidebar_debug_check.set_pressed_no_signal(_debug_draw)
		var has_hertz: bool = "contact_hertz" in world
		_contact_hertz_row.visible = has_hertz
		if has_hertz:
			_contact_hertz_spin.set_value_no_signal(world.contact_hertz)
	else:
		_contact_hertz_row.visible = false
	_updating_sidebar = false
	_update_readout()


func _update_readout() -> void:
	if _current == null:
		_readout.text = "Physics Steps: %d\nBodies: --" % _step_count
		return
	var world = _current.get_node_or_null("Box3DWorld")
	if world == null:
		_readout.text = "Physics Steps: %d\nBodies: --" % _step_count
		return
	# Samples nest bodies under sub-nodes (e.g. Blocks), so count all descendants.
	_readout.text = "Physics Steps: %d\nBodies: %d" % [_step_count, _count_bodies(world)]


func _count_bodies(node: Node) -> int:
	var n := 0
	for child in node.get_children():
		if child is Box3DBody:
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
	if _current != null:
		_current.queue_free()
		_current = null
	var scene: PackedScene = load(path)
	if scene == null:
		return
	_current = scene.instantiate()
	_current_path = path
	_current_name = sample_name
	_host.add_child(_current)
	_step_count = 0
	var world = _current.get_node_or_null("Box3DWorld")
	if world != null and _camera.has_method("set_world"):
		if keep_camera:
			# Reset: rebuild the world but don't move the camera.
			_camera.set_world_keep_view(world)
		else:
			_camera.set_world(world)
			# A sample can frame its own view by exporting camera_home /
			# camera_look_at (two Vector3s) on its root script.
			if "camera_home" in _current and "camera_look_at" in _current:
				_camera.frame_view(_current.camera_home, _current.camera_look_at)
	_apply_debug()  # carry the debug-draw toggle into the newly loaded sample
	_refresh_sidebar_from_world(world)
	# Show the Activate button only for samples that expose an activate() action.
	_activate.visible = _current != null and _current.has_method("activate")
	_info.text = "%s      Right-click: fly (WASD / Q E, Shift boost)   ·   Left-drag: grab   ·   Hold F: charge shot" % sample_name
