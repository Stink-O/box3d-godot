extends Control

## Big, video-legible HUD for the engine-comparison harness (compare.gd).
##
## The harness pushes the engine identity and live body count in; the overlay
## measures FPS and physics-step cost itself and draws them large enough to read
## in a screen recording. Physics cost is the honest cross-engine metric here:
## every scenario runs the SAME fixed 60 Hz timestep with the SAME bodies, so
## the differentiator is how many milliseconds each engine spends per physics
## tick (its headroom), not the rendered frame rate — which a shared vsync cap
## or the identical draw-call load would flatten. Both are shown; physics is the
## headline.

const WINDOW := 120  ## frames of self-measured frame time kept for the FPS avg
const PAD := 22.0

## Pushed by the harness (see compare.gd).
var engine_title := "Box3D"            ## big engine name
var engine_proof := ""                 ## the runtime proof line (setting / extension)
var scenario_title := ""               ## scenario name + body count summary
var bodies := 0                        ## live dynamic body count
var accent := Color(0.45, 0.85, 1.0)   ## engine-colored accent bar

var _frame_ms := PackedFloat32Array()
var _head := 0
var _count := 0
var _last_usec := 0
var _text_timer := 0.0
var _font: Font

## Cached display strings, refreshed 4x/second so the numbers are readable.
var _fps_str := "-- fps"
var _phys_str := "physics -- ms/tick"
var _proc_str := ""


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_font = get_theme_default_font()
	_frame_ms.resize(WINDOW)


func _process(delta: float) -> void:
	var now := Time.get_ticks_usec()
	if _last_usec > 0:
		_frame_ms[_head] = float(now - _last_usec) / 1000.0
		_head = (_head + 1) % WINDOW
		_count = mini(_count + 1, WINDOW)
	_last_usec = now

	_text_timer -= delta
	if _text_timer <= 0.0:
		_text_timer = 0.25
		_refresh_strings()
	queue_redraw()


func _refresh_strings() -> void:
	# Frame rate from our own averaged wall-clock deltas (Godot's fps monitor is
	# a coarse 1 s counter); fall back to the engine counter until the window
	# fills.
	if _count >= 10:
		var total := 0.0
		for i in _count:
			total += _frame_ms[i]
		var avg_ms := total / _count
		_fps_str = "%.0f fps" % (1000.0 / maxf(avg_ms, 0.001))
	else:
		_fps_str = "%.0f fps" % Engine.get_frames_per_second()
	# Physics + process cost are Godot's 1 s TIME_* averages, in ms per frame.
	# At a fixed 60 Hz tick this is effectively ms per physics step.
	_phys_str = "physics  %.2f ms / tick" % (
			Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)
	_proc_str = "process  %.2f ms   ·   %d draw calls" % [
			Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
			int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))]


func _big(pos: Vector2, text: String, px: int, color: Color) -> void:
	# Drop shadow first so the text survives any background.
	draw_string(_font, pos + Vector2(2, 2), text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, px, Color(0, 0, 0, 0.85))
	draw_string(_font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, px, color)


func _draw() -> void:
	# A tall panel down the left so the numbers read on bright and dark scenes.
	var panel_w := 560.0
	var panel_h := 322.0
	draw_rect(Rect2(0, 0, panel_w, panel_h), Color(0.04, 0.05, 0.07, 0.72))
	draw_rect(Rect2(0, 0, 10.0, panel_h), accent)  # engine-colored spine

	var x := PAD + 6.0
	var y := PAD + 52.0
	_big(Vector2(x, y), engine_title, 58, Color(1, 1, 1, 0.98))
	y += 40.0
	_big(Vector2(x, y), engine_proof, 20, accent)
	y += 44.0
	_big(Vector2(x, y), scenario_title, 24, Color(0.86, 0.9, 0.95, 0.95))

	# The headline metric: physics milliseconds per tick, biggest after the name.
	y += 62.0
	_big(Vector2(x, y), _phys_str, 40, Color(0.55, 0.95, 0.6, 0.98))
	y += 44.0
	_big(Vector2(x, y), _fps_str + "     bodies %d" % bodies, 30, Color(1, 1, 1, 0.95))
	y += 34.0
	_big(Vector2(x, y), _proc_str, 20, Color(0.8, 0.84, 0.9, 0.9))
