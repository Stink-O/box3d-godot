extends Control

## Video-legible HUD for the engine-comparison harness (compare.gd).
##
## The harness pushes engine identity, sample identity and capability notes in;
## the overlay measures frame cost and tick rate itself. The per-phase solver
## breakdown lives in the separate ProfilerPanel; this is the always-on banner
## that makes a recording self-describing, so a clip is still readable when the
## panel is hidden.
##
## Why these numbers and not "physics ms": Godot's TIME_PHYSICS_PROCESS spans
## the whole physics iteration (scripts, server step, queries, message queue)
## and reads roughly double the real solver cost under vsync pacing, which is
## why common/stats_overlay.gd dropped it (see commit 9ea2692). Box3D can be
## timed directly through get_step_time_ms(); Godot Physics and Jolt expose no
## solver timing at all to a running game. So the honest cross-engine numbers
## here are the ones that mean the same thing everywhere: frame cost and how
## many physics ticks per second the loop actually sustained.

const WINDOW := 240  ## frames of self-measured frame time kept for the stats
const PAD := 22.0

## Pushed by the harness (see compare.gd).
var engine_title := "Box3D"
var engine_proof := ""
var sample_title := ""
var bodies := 0
var notes: Array = []              ## capability gaps, drawn as badges
var accent := Color(0.35, 0.85, 1.0)
var alert := ""                    ## non-empty draws a red mismatch banner

var _frame_ms := PackedFloat32Array()
var _head := 0
var _count := 0
var _last_usec := 0
var _text_timer := 0.0
var _font: Font

## Tick rate measured against the wall clock, not against the fixed physics
## delta, which would report 60 no matter how far behind the sim fell.
var _ticks := 0
var _tick_mark_usec := 0
var _ticks_per_sec := 0.0

var _fps_str := "-- fps"
var _frame_str := ""
var _rate_str := ""


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


func _physics_process(_delta: float) -> void:
	var now := Time.get_ticks_usec()
	if _tick_mark_usec == 0:
		# Start the window here rather than counting this tick: loading a
		# 5000-body scene stalls the loop, and Godot then runs catch-up ticks
		# that would make the first reading show more than the target rate.
		_tick_mark_usec = now
		_ticks = 0
		return
	_ticks += 1
	var elapsed := now - _tick_mark_usec
	if elapsed >= 1000000:
		_ticks_per_sec = float(_ticks) * 1000000.0 / float(elapsed)
		_ticks = 0
		_tick_mark_usec = now


## Sorted copy of the live part of the ring, for percentiles.
func _sorted() -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(_count)
	var start := (_head - _count + WINDOW) % WINDOW
	for i in _count:
		out[i] = _frame_ms[(start + i) % WINDOW]
	out.sort()
	return out


func _refresh_strings() -> void:
	if _count >= 10:
		var s := _sorted()
		var total := 0.0
		for v in s:
			total += v
		var avg := total / _count
		# 1% low: the 99th percentile frame, the one users actually feel.
		var p99: float = s[mini(int(_count * 0.99), _count - 1)]
		_fps_str = "%.0f fps" % (1000.0 / maxf(avg, 0.001))
		_frame_str = "frame  avg %.2f   1%% %.2f   max %.2f ms" % [avg, p99, s[_count - 1]]
	else:
		_fps_str = "%.0f fps" % Engine.get_frames_per_second()
		_frame_str = ""
	_rate_str = "%.0f / %d physics ticks per second" % [
			_ticks_per_sec, Engine.physics_ticks_per_second]


func _big(pos: Vector2, text: String, px: int, color: Color) -> void:
	# Drop shadow first so the text survives any background.
	draw_string(_font, pos + Vector2(2, 2), text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, px, Color(0, 0, 0, 0.85))
	draw_string(_font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, px, color)


const PANEL_W := 660.0
const TEXT_W := PANEL_W - PAD * 2.0 - 12.0   ## usable text width inside the panel


## Greedy word wrap to a pixel width. The proof line and the capability badges
## are prose of unbounded length (a badge names every joint type a sample uses),
## and unwrapped they run clear across the screen and over the 3D view, which
## is exactly the thing a recording cannot survive.
func _wrap(text: String, px: int, max_w: float) -> PackedStringArray:
	var out := PackedStringArray()
	if text == "":
		return out
	var line := ""
	for word in text.split(" ", false):
		var candidate := word if line == "" else line + " " + word
		if _font.get_string_size(candidate, HORIZONTAL_ALIGNMENT_LEFT, -1, px).x <= max_w:
			line = candidate
		else:
			if line != "":
				out.append(line)
			line = word
	if line != "":
		out.append(line)
	return out


func _draw() -> void:
	# Lay the whole panel out first so the background can be sized to the
	# content instead of a guessed constant.
	var proof_lines := _wrap(engine_proof, 17, TEXT_W)
	var note_lines: Array[PackedStringArray] = []
	for note in notes:
		note_lines.append(_wrap(str(note), 16, TEXT_W))

	var h := PAD + 50.0
	h += 26.0 + 20.0 * proof_lines.size()
	h += 32.0 + 32.0 + 44.0 + 28.0 + 24.0
	for lines in note_lines:
		h += 19.0 * lines.size() + 7.0
	h += PAD

	draw_rect(Rect2(0, 0, PANEL_W, h), Color(0.04, 0.05, 0.07, 0.76))
	draw_rect(Rect2(0, 0, 10.0, h), accent)  # engine-colored spine

	var x := PAD + 6.0
	var y := PAD + 50.0
	_big(Vector2(x, y), engine_title, 56, Color(1, 1, 1, 0.98))
	y += 26.0
	for line in proof_lines:
		y += 20.0
		_big(Vector2(x, y), line, 17, accent)

	y += 32.0
	_big(Vector2(x, y), sample_title, 26, Color(0.86, 0.9, 0.95, 0.96))
	y += 32.0
	_big(Vector2(x, y), "%d dynamic bodies" % bodies, 22, Color(0.8, 0.84, 0.9, 0.92))
	y += 44.0
	_big(Vector2(x, y), _fps_str, 34, Color(1, 1, 1, 0.96))
	y += 28.0
	_big(Vector2(x, y), _frame_str, 19, Color(0.8, 0.84, 0.9, 0.9))
	y += 24.0
	_big(Vector2(x, y), _rate_str, 19, Color(0.8, 0.84, 0.9, 0.9))

	# Capability badges. These carry as much of the comparison as the timings
	# do: they say what this engine cannot do with this scene.
	for lines in note_lines:
		var block_h := 19.0 * lines.size() + 3.0
		draw_rect(Rect2(x - 6.0, y + 7.0, TEXT_W + 12.0, block_h),
				Color(0.85, 0.55, 0.12, 0.20))
		for line in lines:
			y += 19.0
			_big(Vector2(x, y + 3.0), line, 16, Color(1.0, 0.79, 0.44, 0.98))
		y += 7.0

	if alert != "":
		var bar := 74.0
		draw_rect(Rect2(0, size.y - bar, size.x, bar), Color(0.55, 0.06, 0.06, 0.92))
		_big(Vector2(PAD, size.y - bar + 46.0), alert, 30, Color(1, 0.92, 0.92))
