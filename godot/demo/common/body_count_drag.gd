extends Label

## Drag-to-move for the body counter. Same contract as the stats overlay and
## profiler panel: left-drag moves it, it can never leave the screen, and the
## spot sticks across launches via user://ui.cfg. The offset is stored
## relative to the label's bottom-center anchor rather than as an absolute
## position, so a saved spot lands proportionally on a different window size
## instead of off in a corner.

const LAYOUT_PATH := "user://ui.cfg"

var _dragging := false


func _ready() -> void:
	# Labels ignore the mouse by default; a drag target has to catch it (which
	# also keeps a drag over the counter from flying the camera underneath).
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_MOVE
	tooltip_text = "Drag to move"
	var layout := ConfigFile.new()
	# has_section_key first: ConfigFile logs an engine error for a null
	# default, and ui.cfg usually exists without this section.
	if layout.load(LAYOUT_PATH) == OK \
			and layout.has_section_key("body_count", "offset"):
		var saved: Variant = layout.get_value("body_count", "offset")
		if saved is Vector2:
			_place(saved)
	get_viewport().size_changed.connect(_clamp_to_screen)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_dragging = event.pressed
		if not event.pressed:
			var layout := ConfigFile.new()
			layout.load(LAYOUT_PATH)  # keep the other overlays' sections
			layout.set_value("body_count", "offset",
					Vector2(offset_left, offset_top))
			layout.save(LAYOUT_PATH)
		accept_event()
	elif event is InputEventMouseMotion and _dragging:
		_shift(event.relative)
		_clamp_to_screen()
		accept_event()


## Anchors stay put (bottom-center); moving means shifting all four offsets.
func _shift(delta: Vector2) -> void:
	offset_left += delta.x
	offset_right += delta.x
	offset_top += delta.y
	offset_bottom += delta.y


func _place(top_left: Vector2) -> void:
	_shift(top_left - Vector2(offset_left, offset_top))
	_clamp_to_screen()


## Keep the counter reachable: never let it leave the visible viewport.
func _clamp_to_screen() -> void:
	var view: Vector2 = get_viewport().get_visible_rect().size
	var target := position.clamp(Vector2.ZERO, (view - size).max(Vector2.ZERO))
	if target != position:
		_shift(target - position)
