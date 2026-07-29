extends Label

## Drag-to-move for the body counter. Same contract as the stats overlay and
## profiler panel: left-drag moves it, it can never leave the screen, and the
## spot sticks across launches via user://ui.cfg. The offset is stored
## relative to the label's bottom-center anchor rather than as an absolute
## position, so a saved spot lands proportionally on a different window size
## instead of off in a corner.

const LAYOUT_PATH := "user://ui.cfg"

var _dragging := false
var _hover := false


func _ready() -> void:
	# Labels ignore the mouse by default; a drag target has to catch it (which
	# also keeps a drag over the counter from flying the camera underneath).
	mouse_filter = Control.MOUSE_FILTER_STOP
	# Same cursor treatment as the stats overlay: OS cursor shapes don't show
	# reliably on every display stack, so hide the system pointer while it's
	# over the label and draw the move-cross ourselves in _draw.
	mouse_entered.connect(_set_hover.bind(true))
	mouse_exited.connect(_set_hover.bind(false))
	visibility_changed.connect(_on_visibility_changed)
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


func _set_hover(on: bool) -> void:
	_hover = on
	_update_cursor()
	queue_redraw()


## The system pointer is hidden exactly while it is over (or dragging) the
## visible label; the drawn cross in _draw stands in for it.
func _update_cursor() -> void:
	var hide_os_cursor := visible and (_hover or _dragging)
	if hide_os_cursor and Input.mouse_mode == Input.MOUSE_MODE_VISIBLE:
		Input.mouse_mode = Input.MOUSE_MODE_HIDDEN
	elif not hide_os_cursor and Input.mouse_mode == Input.MOUSE_MODE_HIDDEN:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _on_visibility_changed() -> void:
	if not visible:
		# Never leave the pointer hidden if the counter disappears under it
		# (the Settings checkbox can hide it mid-hover).
		_hover = false
		_dragging = false
		_update_cursor()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_dragging = event.pressed
		_update_cursor()
		if not event.pressed:
			var layout := ConfigFile.new()
			layout.load(LAYOUT_PATH)  # keep the other overlays' sections
			layout.set_value("body_count", "offset",
					Vector2(offset_left, offset_top))
			layout.save(LAYOUT_PATH)
		accept_event()
	elif event is InputEventMouseMotion:
		if _dragging:
			_shift(event.relative)
			_clamp_to_screen()
		# Redraw either way: the drawn cross follows the pointer.
		queue_redraw()
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


func _draw() -> void:
	# The label's own cursor, exactly like the stats overlay's: dark halo
	# first so the cross reads on any background.
	if _hover or _dragging:
		var mp := get_local_mouse_position()
		_draw_move_icon(mp + Vector2.ONE, 11.0, Color(0, 0, 0, 0.8))
		_draw_move_icon(mp, 11.0, Color(1, 1, 1, 0.95))


func _draw_move_icon(center: Vector2, r: float, color: Color) -> void:
	for d: Vector2 in [Vector2.UP, Vector2.DOWN, Vector2.LEFT, Vector2.RIGHT]:
		var tip := center + d * r
		var perp := Vector2(d.y, -d.x)
		draw_line(center, tip - d * (r * 0.4), color, maxf(r * 0.18, 1.5))
		draw_colored_polygon(PackedVector2Array([
			tip, tip - d * (r * 0.45) + perp * (r * 0.32),
			tip - d * (r * 0.45) - perp * (r * 0.32)]), color)
	draw_circle(center, maxf(r * 0.14, 1.2), color)
