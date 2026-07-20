extends Control

## Performance overlay: live FPS + frame-time graph and engine stats, toggled
## from the Settings sidebar. Self-measured wall-clock frame deltas drive the
## graph (Godot's TIME_* monitors only refresh once a second, so those lines
## are labelled as 1 s averages). Draws itself; no children, no theme deps.
## Drag anywhere on the panel to move it (the position is remembered).

const WINDOW := 240  ## frames kept in the graph / percentile window
const GRAPH_H := 64.0
const PAD := 10.0
const LINE_H := 20.0
const LAYOUT_PATH := "user://ui.cfg"  ## remembers the dragged position

## Pushed by the shell once a second (recursive node count); -1 hides the line.
var bodies := -1

var _times := PackedFloat32Array()  ## ms per frame, ring buffer
var _head := 0
var _count := 0
var _last_usec := 0
var _text_timer := 0.0
var _lines: PackedStringArray = []
var _fps_text := ""
var _font: Font
var _dragging := false
var _hover := false


func _ready() -> void:
	# The panel is a drag target: catch its mouse events (so a drag doesn't
	# also grab bodies / fly the camera underneath) and advertise movability
	# with the omnidirectional cursor.
	mouse_filter = Control.MOUSE_FILTER_STOP
	# OS cursor shapes (Control.mouse_default_cursor_shape / Input defaults)
	# don't reliably show on every display stack, so the panel draws its own
	# omnidirectional cursor: hide the system pointer while it's over the
	# panel and render the move-cross at the mouse position in _draw.
	mouse_entered.connect(_set_hover.bind(true))
	mouse_exited.connect(_set_hover.bind(false))
	tooltip_text = "Drag to move"
	_times.resize(WINDOW)
	_font = get_theme_default_font()
	var layout := ConfigFile.new()
	if layout.load(LAYOUT_PATH) == OK:
		var saved = layout.get_value("stats_overlay", "position", null)
		if saved is Vector2:
			position = saved
	visibility_changed.connect(_on_visibility_changed)
	_on_visibility_changed()


func _set_hover(on: bool) -> void:
	_hover = on
	_update_cursor()


## The system pointer is hidden exactly while it is over (or dragging) the
## visible panel; the drawn cursor in _draw stands in for it.
func _update_cursor() -> void:
	var hide_os_cursor := visible and (_hover or _dragging)
	if hide_os_cursor and Input.mouse_mode == Input.MOUSE_MODE_VISIBLE:
		Input.mouse_mode = Input.MOUSE_MODE_HIDDEN
	elif not hide_os_cursor and Input.mouse_mode == Input.MOUSE_MODE_HIDDEN:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _on_visibility_changed() -> void:
	set_process(visible)
	if not visible:
		# Never leave the pointer hidden if the panel disappears under it.
		_hover = false
		_update_cursor()
	if visible:
		# Fresh window: a stale buffer would graph the time we spent hidden.
		_count = 0
		_head = 0
		_last_usec = 0
		_text_timer = 0.0
		_clamp_to_screen()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_dragging = event.pressed
		_update_cursor()
		if not event.pressed:
			var layout := ConfigFile.new()
			layout.load(LAYOUT_PATH)  # keep other sections if the file exists
			layout.set_value("stats_overlay", "position", position)
			layout.save(LAYOUT_PATH)
		accept_event()
	elif event is InputEventMouseMotion and _dragging:
		position += event.relative
		_clamp_to_screen()
		accept_event()


## Keep the panel reachable: never let it leave the visible viewport.
func _clamp_to_screen() -> void:
	var view: Vector2 = get_viewport().get_visible_rect().size
	position = position.clamp(Vector2.ZERO, (view - size).max(Vector2.ZERO))


func _process(delta: float) -> void:
	var now := Time.get_ticks_usec()
	if _last_usec > 0:
		_times[_head] = float(now - _last_usec) / 1000.0
		_head = (_head + 1) % WINDOW
		_count = mini(_count + 1, WINDOW)
	_last_usec = now
	_text_timer -= delta
	if _text_timer <= 0.0:
		_text_timer = 0.25
		_rebuild_text()
		# The hit/drag area tracks the drawn content exactly.
		size.y = PAD * 2.0 + (_lines.size() + 1) * LINE_H + 30.0 + GRAPH_H
	queue_redraw()


func _window_sorted() -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(_count)
	for i in _count:
		out[i] = _times[(_head - _count + i + WINDOW) % WINDOW]
	out.sort()
	return out


static func _vsync_name(mode: int) -> String:
	match mode:
		DisplayServer.VSYNC_DISABLED:
			return "off"
		DisplayServer.VSYNC_ADAPTIVE:
			return "adaptive"
		DisplayServer.VSYNC_MAILBOX:
			return "mailbox"
		_:
			return "on"


func _rebuild_text() -> void:
	_lines.clear()
	var sorted := _window_sorted()
	var n := sorted.size()
	if n < 10:
		_fps_text = "-- fps"
		return
	var total := 0.0
	for v in sorted:
		total += v
	var avg := total / n
	var p99 := sorted[int(n * 0.99)]
	var worst := sorted[n - 1]
	_fps_text = "%.0f fps" % Engine.get_frames_per_second()
	_lines.append("frame  avg %.2f   1%% %.2f   max %.2f ms" % [avg, p99, worst])
	_lines.append("process %.2f ms   physics %.2f ms  (1 s avg)" % [
		Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
	])
	var prims := Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
	_lines.append("draw calls %d   triangles %s" % [
		int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		("%.1f M" % (prims / 1e6)) if prims >= 1e6 else str(int(prims)),
	])
	_lines.append("vram %.0f MB   static mem %.0f MB" % [
		Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0,
		Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0,
	])
	var objects_line := "objects %d   nodes %d" % [
		int(Performance.get_monitor(Performance.OBJECT_COUNT)),
		int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
	]
	if bodies >= 0:
		objects_line += "   bodies %d" % bodies
	_lines.append(objects_line)
	var vp := get_viewport()
	_lines.append("%d x %d @ %.0f Hz   vsync %s" % [
		vp.size.x, vp.size.y,
		DisplayServer.screen_get_refresh_rate(),
		_vsync_name(DisplayServer.window_get_vsync_mode()),
	])


## Omnidirectional move cross: four arrows out from a centre dot. Used for the
## corner grip hint and as the drawn cursor while hovering the panel.
func _draw_move_icon(center: Vector2, r: float, color: Color) -> void:
	for d: Vector2 in [Vector2.UP, Vector2.DOWN, Vector2.LEFT, Vector2.RIGHT]:
		var tip := center + d * r
		var perp := Vector2(d.y, -d.x)
		draw_line(center, tip - d * (r * 0.4), color, maxf(r * 0.18, 1.5))
		draw_colored_polygon(PackedVector2Array([
			tip, tip - d * (r * 0.45) + perp * (r * 0.32),
			tip - d * (r * 0.45) - perp * (r * 0.32)]), color)
	draw_circle(center, maxf(r * 0.14, 1.2), color)


## Text with a 1 px drop shadow so it stays readable over bright scenes even
## through the translucent panel.
func _shadowed(pos: Vector2, text: String, px: int, color: Color) -> void:
	draw_string(_font, pos + Vector2.ONE, text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, px, Color(0, 0, 0, 0.7))
	draw_string(_font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, px, color)


func _draw() -> void:
	var w := size.x
	var h := PAD * 2.0 + (_lines.size() + 1) * LINE_H + 30.0 + GRAPH_H
	draw_rect(Rect2(0, 0, w, h), Color(0.05, 0.06, 0.08, 0.85))

	var y := PAD + 24.0
	_shadowed(Vector2(PAD, y), _fps_text, 24, Color(1, 1, 1, 0.95))
	# Move-grip icon in the corner: a quiet reminder the panel is draggable.
	# (Drawn, not a font glyph — the default font has no move-grip glyph.)
	_draw_move_icon(Vector2(w - PAD - 10.0, PAD + 14.0), 9.0, Color(1, 1, 1, 0.4))
	y += 10.0
	for line in _lines:
		y += LINE_H
		_shadowed(Vector2(PAD, y), line, 14, Color(0.88, 0.91, 0.95, 0.95))

	# --- Frame-time graph: one bar per frame, newest at the right edge. ---
	var gy := h - PAD - GRAPH_H
	var gw := w - PAD * 2.0
	draw_rect(Rect2(PAD, gy, gw, GRAPH_H), Color(0, 0, 0, 0.35))

	# Vertical scale: at least two 60 Hz budgets tall, growing to fit spikes.
	var peak := 0.0
	for i in _count:
		peak = maxf(peak, _times[i])
	var graph_max := maxf(33.4, minf(peak * 1.1, 100.0))

	var budget_ms := 1000.0 / maxf(DisplayServer.screen_get_refresh_rate(), 30.0)
	for guide: float in [budget_ms, 16.67, 33.33]:
		if guide < graph_max - 1.0:
			var guide_y := gy + GRAPH_H * (1.0 - guide / graph_max)
			draw_line(Vector2(PAD, guide_y), Vector2(PAD + gw, guide_y),
					Color(1, 1, 1, 0.14))
			draw_string(_font, Vector2(PAD + gw - 34.0, guide_y - 2.0),
					"%.0f" % guide, HORIZONTAL_ALIGNMENT_LEFT, -1, 10,
					Color(1, 1, 1, 0.4))

	if _count > 1:
		var bar_w := gw / WINDOW
		for i in _count:
			var t := _times[(_head - _count + i + WINDOW) % WINDOW]
			var frac := clampf(t / graph_max, 0.0, 1.0)
			var color := Color(0.35, 0.85, 0.45, 0.9)  # within refresh budget
			if t > 33.33:
				color = Color(0.95, 0.30, 0.25, 0.95)
			elif t > 16.67:
				color = Color(0.95, 0.62, 0.20, 0.95)
			elif t > budget_ms + 0.5:
				color = Color(0.90, 0.88, 0.35, 0.9)
			var x := PAD + gw - (_count - i) * bar_w
			draw_rect(Rect2(x, gy + GRAPH_H * (1.0 - frac), bar_w, GRAPH_H * frac), color)

	# The panel's own cursor: the OS pointer is hidden while hovering (system
	# cursor shapes don't show reliably everywhere), so draw the move cross at
	# the mouse position — dark halo first so it reads on any background.
	if _hover or _dragging:
		var mp := get_local_mouse_position()
		_draw_move_icon(mp + Vector2.ONE, 11.0, Color(0, 0, 0, 0.8))
		_draw_move_icon(mp, 11.0, Color(1, 1, 1, 0.95))
