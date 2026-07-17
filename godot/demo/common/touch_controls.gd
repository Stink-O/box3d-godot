extends CanvasLayer

## Touch-control overlay for the sample browser, shown only on touchscreen devices
## (main.gd instantiates it when DisplayServer.is_touchscreen_available()).
## Desktop never sees this layer, so nothing here can affect the desktop demo.
##
## The samples read raw keys (character: WASD + SPACE, car: arrows/WASD,
## bullets: C / B), so instead of teaching every sample about touch, the
## joystick and buttons SYNTHESIZE those key events through
## Input.parse_input_event() — Input.is_key_pressed() then reports them
## exactly as if a keyboard were attached, and every sample works unchanged.
##
## What appears depends on the sample (SAMPLE_CONTROLS below): the joystick
## and JUMP only show where they drive something, so most scenes just get the
## SHOOT button. Camera look / grab / pinch live in fly_camera.gd, not here —
## they need the camera's ray math.

const JOY_RADIUS := 110.0          ## joystick base radius, canvas px
const JOY_KNOB := 44.0             ## knob radius
const JOY_DEAD_ZONE := 0.28        ## fraction of RADIUS before a direction latches
const JOY_MARGIN := Vector2(150.0, 150.0)  ## base centre inset from bottom-left

## Per-sample extra controls, keyed by scene path (matches main.gd's SAMPLES
## values). joystick => virtual WASD stick. jump => SPACE button.
## keys => tap buttons injecting one keycode each.
const SAMPLE_CONTROLS := {
	"res://samples/character.tscn": {"joystick": true, "jump": true},
	"res://samples/car.tscn": {"joystick": true},
	"res://samples/bullets.tscn": {"keys": [["CCD on/off", KEY_C], ["Fire volley", KEY_B]]},
}

var _camera: Camera3D = null

var _joy: Control = null
var _joy_active := false           ## a finger owns the stick
var _joy_pointer := -1             ## which touch index owns it
var _joy_vector := Vector2.ZERO    ## current stick deflection, -1..1 per axis
var _held_keys := {}               ## keycode -> true while synthetically held

var _shoot_btn: Button = null
var _jump_btn: Button = null
var _keys_box: HBoxContainer = null


func setup(camera: Camera3D) -> void:
	_camera = camera


func _ready() -> void:
	layer = 10  # above the shell UI

	# --- Joystick: a Control we draw ourselves (base ring + knob). It owns
	# the bottom-left corner; touches there never reach the camera.
	_joy = Control.new()
	_joy.name = "Joystick"
	_joy.custom_minimum_size = Vector2(JOY_RADIUS, JOY_RADIUS) * 2.4
	_joy.anchor_top = 1.0
	_joy.anchor_bottom = 1.0
	_joy.offset_left = 0.0
	_joy.offset_top = -JOY_MARGIN.y - JOY_RADIUS * 1.2
	_joy.offset_right = JOY_MARGIN.x + JOY_RADIUS * 1.2
	_joy.offset_bottom = 0.0
	_joy.draw.connect(_draw_joystick)
	_joy.gui_input.connect(_on_joy_input)
	_joy.visible = false
	add_child(_joy)

	# --- Action buttons, bottom-right column: SHOOT under JUMP. Big hit
	# targets; button_down/up (not pressed) so holds work.
	_shoot_btn = _make_button("⚪  SHOOT", Vector2(-250.0, -140.0), Vector2(230.0, 92.0))
	_shoot_btn.button_down.connect(_on_shoot_down)
	_shoot_btn.button_up.connect(_on_shoot_up)

	_jump_btn = _make_button("⬆  JUMP", Vector2(-250.0, -250.0), Vector2(230.0, 92.0))
	_jump_btn.button_down.connect(func(): _press_key(KEY_SPACE, true))
	_jump_btn.button_up.connect(func(): _press_key(KEY_SPACE, false))
	_jump_btn.visible = false

	# --- Crosshair: SHOOT fires through the screen centre on touch (the
	# emulated mouse sits on the button you're pressing), so mark the centre.
	var crosshair := Control.new()
	crosshair.set_anchors_preset(Control.PRESET_CENTER)
	crosshair.mouse_filter = Control.MOUSE_FILTER_IGNORE
	crosshair.draw.connect(func():
		crosshair.draw_arc(Vector2.ZERO, 14.0, 0.0, TAU, 24, Color(1, 1, 1, 0.5), 2.5)
		crosshair.draw_circle(Vector2.ZERO, 3.0, Color(1, 1, 1, 0.6)))
	add_child(crosshair)

	# --- Per-sample key pills, centred above the bottom edge.
	_keys_box = HBoxContainer.new()
	_keys_box.anchor_left = 0.5
	_keys_box.anchor_right = 0.5
	_keys_box.anchor_top = 1.0
	_keys_box.anchor_bottom = 1.0
	_keys_box.offset_top = -120.0
	_keys_box.offset_bottom = -40.0
	_keys_box.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_keys_box.add_theme_constant_override("separation", 24)
	add_child(_keys_box)


func _make_button(label: String, offset: Vector2, size: Vector2) -> Button:
	var b := Button.new()
	b.text = label
	b.focus_mode = Control.FOCUS_NONE
	b.anchor_left = 1.0
	b.anchor_right = 1.0
	b.anchor_top = 1.0
	b.anchor_bottom = 1.0
	b.offset_left = offset.x
	b.offset_top = offset.y
	b.offset_right = offset.x + size.x
	b.offset_bottom = offset.y + size.y
	b.add_theme_font_size_override("font_size", 26)
	b.self_modulate = Color(1, 1, 1, 0.85)
	add_child(b)
	return b


# main.gd calls this on every sample load: show only the controls this sample
# can actually use.
func set_sample(path: String) -> void:
	var cfg: Dictionary = SAMPLE_CONTROLS.get(path, {})
	_release_all_keys()
	_joy.visible = cfg.get("joystick", false)
	_jump_btn.visible = cfg.get("jump", false)
	for child in _keys_box.get_children():
		child.queue_free()
	for entry in cfg.get("keys", []):
		var pill := Button.new()
		pill.text = entry[0]
		pill.focus_mode = Control.FOCUS_NONE
		pill.custom_minimum_size = Vector2(210.0, 72.0)
		pill.add_theme_font_size_override("font_size", 24)
		pill.self_modulate = Color(1, 1, 1, 0.85)
		var keycode: Key = entry[1]
		# A tap = one press+release, like striking the key.
		pill.pressed.connect(func():
			_press_key(keycode, true)
			_press_key(keycode, false))
		_keys_box.add_child(pill)


# --- SHOOT: hold to charge, release to fire (the F key's touch twin) ---

func _on_shoot_down() -> void:
	if _camera != null and _camera.has_method("begin_charge"):
		_camera.begin_charge()


func _on_shoot_up() -> void:
	if _camera != null and _camera.has_method("end_charge"):
		_camera.end_charge()


# --- Virtual joystick ---

func _on_joy_input(event: InputEvent) -> void:
	# gui_input hands us the touches that land on the joystick's Control, in
	# its local coordinates. One finger owns the stick until it lifts.
	if event is InputEventScreenTouch:
		if event.pressed and not _joy_active:
			_joy_active = true
			_joy_pointer = event.index
			_update_joy_vector(event.position)
		elif not event.pressed and event.index == _joy_pointer:
			_reset_joystick()
	elif event is InputEventScreenDrag and _joy_active and event.index == _joy_pointer:
		_update_joy_vector(event.position)
	# Mouse fallback so the joystick is also testable on desktop touchscreen
	# emulation and in the editor.
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed and not _joy_active:
			_joy_active = true
			_joy_pointer = -2
			_update_joy_vector(event.position)
		elif not event.pressed and _joy_pointer == -2:
			_reset_joystick()
	elif event is InputEventMouseMotion and _joy_active and _joy_pointer == -2:
		_update_joy_vector(event.position)


func _joy_centre() -> Vector2:
	return _joy.size / 2.0


func _update_joy_vector(local_pos: Vector2) -> void:
	var v := (local_pos - _joy_centre()) / JOY_RADIUS
	if v.length() > 1.0:
		v = v.normalized()
	_joy_vector = v
	_joy.queue_redraw()
	_apply_joy_keys()


func _reset_joystick() -> void:
	_joy_active = false
	_joy_pointer = -1
	_joy_vector = Vector2.ZERO
	_joy.queue_redraw()
	_apply_joy_keys()


# Deflection -> keys, with a dead zone so a resting thumb holds nothing.
# Each direction holds BOTH its WASD key and its arrow key: the character
# walks on WASD, the car steers on arrows (WASD only in third person), and
# holding the pair costs nothing in samples that read neither. Diagonals hold
# two directions, exactly like a keyboard.
func _apply_joy_keys() -> void:
	var v := _joy_vector
	var up := v.y < -JOY_DEAD_ZONE
	var down := v.y > JOY_DEAD_ZONE
	var left := v.x < -JOY_DEAD_ZONE
	var right := v.x > JOY_DEAD_ZONE
	_set_key(KEY_W, up)
	_set_key(KEY_UP, up)
	_set_key(KEY_S, down)
	_set_key(KEY_DOWN, down)
	_set_key(KEY_A, left)
	_set_key(KEY_LEFT, left)
	_set_key(KEY_D, right)
	_set_key(KEY_RIGHT, right)


func _set_key(keycode: Key, down: bool) -> void:
	if _held_keys.get(keycode, false) == down:
		return
	_press_key(keycode, down)


func _press_key(keycode: Key, down: bool) -> void:
	if down:
		_held_keys[keycode] = true
	else:
		_held_keys.erase(keycode)
	var ev := InputEventKey.new()
	ev.keycode = keycode
	ev.physical_keycode = keycode
	ev.pressed = down
	Input.parse_input_event(ev)


func _release_all_keys() -> void:
	for keycode in _held_keys.keys():
		_press_key(keycode, false)
	_reset_joystick()


func _exit_tree() -> void:
	_release_all_keys()  # never leave a synthetic key latched


func _draw_joystick() -> void:
	var c := _joy_centre()
	_joy.draw_circle(c, JOY_RADIUS, Color(1, 1, 1, 0.10))
	_joy.draw_arc(c, JOY_RADIUS, 0.0, TAU, 48, Color(1, 1, 1, 0.35), 3.0)
	var knob := c + _joy_vector * JOY_RADIUS * 0.75
	_joy.draw_circle(knob, JOY_KNOB, Color(1, 1, 1, 0.45 if _joy_active else 0.25))
