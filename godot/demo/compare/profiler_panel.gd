class_name ProfilerPanel
extends Control

## The upstream box3d sample profiler ("Metrics" drawer, samples/sample.cpp),
## re-drawn as a Godot Control so the same numbers can be shown for Box3D,
## Godot Physics and Jolt side by side.
##
## The statistics are cloned from upstream deliberately: a 512-tick ring, `now`
## as the mean of the last 10 ticks, `avg` over the whole live ring and a `max`
## recomputed from scratch every draw (so spikes age out instead of sticking).
## Anyone who has read the C++ sample app must be able to read this panel
## without re-learning what a column means.
##
## The panel owns all history; a feed (SPEC B) only says what its rows are and
## hands over one value per row per physics tick. Drive it with:
##   set_feed(feed)   once, when the feed is ready
##   poll()           once per physics tick
##   reset()          to drop the history
##
## This is a recording surface — it gets captured on video and scaled down — so
## everything here is big, shadowed and drawn on a near-solid dark panel. No
## hairlines, no small type.

# ---- Statistics (SPEC C; upstream sample.cpp) -----------------------------
const CAP := 512                 ## ring capacity, power of two so the index masks
const MASK := CAP - 1
const NOW_WINDOW := 10           ## ticks averaged into the `now` column

# ---- Layout ---------------------------------------------------------------
## Upstream docks "Metrics" along the bottom edge of the camera — 16 em tall,
## as wide as the view minus the info panel — so the scene above it stays
## watchable. This is that drawer: short, wide, ending where the demo shell's
## sidebar begins, with the counters and the frame-time chart on their own tabs
## instead of stacked under the rows. Type stays big — this is still a
## recording surface.
const PAD := 18.0
const ROW_H := 24.0              ## sized so all 22 Box3D rows fit at 1080p
const ROW_PX := 19
const HEAD_PX := 28
const PROOF_PX := 17
const SMALL_PX := 16
const INDENT_W := 16.0
## Gutter before every label, twisty or not, so leaves line up with parents.
const TWIST_W := 20.0
## Sized to the longest label any feed produces — "integrate velocities" at
## indent 1 (GodotPhysicsFeed) — so no label reaches the `now` column.
const SECTION_W := 226.0
const NUM_W := 70.0              ## holds "%6.2f" up to 999.99 at ROW_PX
const NUM_GAP := 8.0
## The % step bar takes whatever width the drawer has left over (upstream's
## ProgressBar stretches to its column too); this is only the floor, below
## which the columns would start to collide.
const MIN_BAR_W := 120.0
const PLOT_W := 140.0
const PLOT_GAP := 10.0
const STEP_W := 230.0            ## title-line step readout, right-aligned
const STEP_PX := 24
const BTN_H := 28.0
const FLAME_H := 30.0
const COUNTER_H := 24.0
const VAL_W := 120.0             ## counter value column
## Counters tab: a column is one label plus its value, and how many columns fit
## is a question the drawer's width answers.
const CT_COL_W := 300.0
const CT_GAP := 28.0
const TAB_H := 32.0
const TAB_PX := 18
const TAB_PAD := 16.0            ## horizontal padding inside a tab
const TAB_GAP := 6.0
const CHART_H := 176.0
const AXIS_W := 78.0             ## frame-time chart's y-label gutter, "12.3 ms" wide
## Resize grip, top-right. The drawer is anchored bottom-left and grows upward,
## so the top and the right are its free edges and that one corner drives both.
## 26 px rather than the 18 px a mouse needs: this gets recorded and scaled down.
const GRIP := 26.0
const MIN_BODY_ROWS := 3         ## shortest body a manual height may leave
const MIN_CHART_H := 90.0        ## the Frame Time chart scales, it never scrolls
const SCROLL_W := 6.0            ## scroll indicator down the body's right edge
## The shell's sidebar owns the right 320 px (main.tscn UI/Sidebar) and keeps
## 12 px margins, so the drawer stops short of it and matches its edges.
const RIGHT_RESERVE := 320.0
const EDGE_MARGIN := 12.0

const X_SECTION := PAD
const X_NOW := X_SECTION + SECTION_W
const X_AVG := X_NOW + NUM_W + NUM_GAP
const X_MAX := X_AVG + NUM_W + NUM_GAP
const X_PCT := X_MAX + NUM_W + NUM_GAP + 6.0

## Upstream's tab bar, minus "Renderer": no feed has renderer data to put in it.
const TABS := ["Profile", "Counters", "Frame Time"]
const TAB_PROFILE := 0
const TAB_COUNTERS := 1
const TAB_CHART := 2

const LAYOUT_PATH := "user://ui.cfg"  ## remembers the drag and the open rows

## Engine tint: the spine, the proof line and the button highlights.
var accent := Color(0.35, 0.85, 1.0)

var _feed = null                 ## SPEC B ProfileFeed; duck-typed, three classes
var _rows: Array = []            ## Array[Row], frozen copy of feed.rows()
## One flat ring for every row, row r occupying [r * CAP, r * CAP + CAP). Flat
## rather than an Array of PackedFloat32Arrays because reading a packed array
## out of an Array yields a copy-on-write copy — writes to it would be lost.
var _ring := PackedFloat32Array()
var _write := 0                  ## total samples written; index = _write & MASK
var _count := 0                  ## live samples in the ring (<= CAP)

var _now := PackedFloat32Array()
var _avg := PackedFloat32Array()
var _max := PackedFloat32Array()

var _parent: PackedInt32Array = PackedInt32Array()   ## derived from Row.indent
var _has_children: Array[bool] = []
var _row_open: Array[bool] = []
var _visible: PackedInt32Array = PackedInt32Array()

var _engine := ""
var _proof := ""
var _proof_lines: PackedStringArray = PackedStringArray()
var _has_phases := true
var _flame := PackedInt32Array()
var _counters := {}
var _counter_tick := 0

var _show_plots := false
var _tab := TAB_PROFILE
var _font: Font
var _dragging := false
var _resizing := false
var _grip_hover := false
## Vector2.ZERO means auto-fit: width from the viewport, height from the content.
## Anything else is a size the user dragged out of the grip, and it outranks both
## derivations until the grip is double-clicked.
var _user_size := Vector2.ZERO
## Cleared the moment the panel is dragged. An undocked drawer keeps the spot it
## was put in; a docked one re-derives its geometry every refresh, so it follows
## a window resize instead of drifting off the edge.
var _docked := true
## Open rows keyed by LABEL rather than index, because the panel is re-fed
## whenever the sample or the engine changes and the row sets differ. Upstream's
## `static bool s_rowOpen[]` survives a sample switch; keying by label gets that
## across a feed swap too, and the config file gets it across a relaunch.
var _open_labels := {}
## Frame Time series, frozen at adopt time (see _pick_chart_rows).
var _chart_rows := PackedInt32Array()

# Layout anchors, recomputed in _refresh() so hit-testing and drawing agree.
var _panel_size := Vector2(560, 200)
var _x_plot := 0.0
var _bar_w := MIN_BAR_W
var _y_title := 0.0
var _y_proof := 0.0
var _y_tabs := 0.0
var _y_flame := -1.0
var _y_colhead := 0.0
var _y_rows := 0.0
var _y_counters := 0.0
var _y_chart := 0.0
var _ct_cols := 1
var _tab_rects: Array[Rect2] = []
var _reset_rect := Rect2()
var _plots_rect := Rect2()
var _grip_rect := Rect2()
var _chart_h := CHART_H
## The body is the part of the drawer a manual height gives and takes: the rows
## on Profile, the counter grid on Counters. It scrolls; everything above it is
## fixed head. `_body_fit` is a count of whole entries, never a pixel height —
## see _refresh for why nothing is ever drawn half.
var _body_top := 0.0
var _body_fit := 1
var _scroll := 0.0
var _scroll_max := 0.0           ## 0 when the body fits, which also hides the bar
var _scroll_step := ROW_H
var _content_h := 0.0
## Recomputed with the rest of the layout so the grip clamps against the same
## numbers the drawing does.
var _min_size := Vector2(560, 200)
var _max_size := Vector2(1920, 1080)


func _ready() -> void:
	# The panel is a drag target and has buttons, so it must consume its own
	# mouse events rather than letting them fall through to the scene.
	mouse_filter = Control.MOUSE_FILTER_STOP
	tooltip_text = "Drag to move. Drag the top-right grip to resize, " \
			+ "double-click the grip to reset it."
	# A pointer that leaves the panel mid-hover would otherwise leave the grip lit.
	mouse_exited.connect(_clear_grip_hover)
	_font = get_theme_default_font()
	var layout := ConfigFile.new()
	# has_section_key first: ConfigFile treats a null default as "no default was
	# given" and pushes an engine error, so a file that exists without our
	# section would log one on every launch.
	if layout.load(LAYOUT_PATH) == OK:
		if layout.has_section_key("profiler_panel", "position"):
			var saved: Variant = layout.get_value("profiler_panel", "position")
			if saved is Vector2:
				position = saved
				# Only a drag ever writes a position, so one on disk means the
				# user placed this panel and the dock must not take it back.
				_docked = false
		if layout.has_section_key("profiler_panel", "size"):
			var saved_size: Variant = layout.get_value("profiler_panel", "size")
			if saved_size is Vector2:
				# Same reasoning as the position, and for the same reason it is
				# only ever re-clamped, never re-derived: _refresh() decides what
				# actually fits, this only says what was asked for.
				_user_size = saved_size
				_docked = false
		if layout.has_section_key("profiler_panel", "open_rows"):
			var open: Variant = layout.get_value("profiler_panel", "open_rows")
			if open is PackedStringArray:
				for label in open:
					_open_labels[label] = true
	_refresh()
	# Not _apply_geometry(): that one preserves the bottom edge across a resize,
	# and the scene's authored size is not an edge worth preserving.
	size = _panel_size
	if _docked:
		position = _dock_position()
	_clamp_to_screen()


# --- Feed plumbing ----------------------------------------------------------

## Adopt a SPEC B ProfileFeed. Clears any previous history: two feeds never
## share a ring, and the row sets differ per engine.
func set_feed(feed) -> void:
	_feed = feed
	_adopt_rows()


func _adopt_rows() -> void:
	_rows.clear()
	_ring.resize(0)
	_parent = PackedInt32Array()
	_has_children.clear()
	_row_open.clear()
	_visible = PackedInt32Array()
	# A new row set is a new list; an offset carried over from the old one would
	# point at nothing in particular.
	_scroll = 0.0
	if _feed == null:
		_now.resize(0)
		_avg.resize(0)
		_max.resize(0)
		reset()
		return
	_rows = _feed.rows()
	_engine = str(_feed.engine_name())
	_proof = str(_feed.source_proof())
	_has_phases = bool(_feed.has_phases())
	_flame = _feed.flame_rows()
	var n := _rows.size()
	_ring.resize(n * CAP)
	_now.resize(n)
	_avg.resize(n)
	_max.resize(n)
	_parent.resize(n)
	_has_children.resize(n)
	_row_open.resize(n)
	for r in n:
		_has_children[r] = false
		# Collapsed unless this label was opened before: upstream's s_rowOpen
		# zero-inits, so a fresh panel shows the five indent-0 rows and nothing
		# else. Never reset here — a feed swap is not a request to re-collapse.
		_row_open[r] = _open_labels.has(_row_label(r))
	_derive_tree()
	_pick_chart_rows()
	reset()


## Upstream's Frame Time tab plots exactly step, collide and solve — which is
## why rows 0/2/3 carry those signature colours. Match by label so the native
## feeds, whose phases are named differently, still get their closest
## equivalents, and freeze the choice here: a series set that tracked the
## numbers would make the legend flicker mid-recording.
func _pick_chart_rows() -> void:
	_chart_rows = PackedInt32Array()
	if _rows.is_empty():
		return
	_chart_rows.append(0)
	if not _has_phases:
		return
	for want in ["collide", "solve"]:
		for r in range(1, _rows.size()):
			if _row_label(r).findn(want) >= 0:
				_chart_rows.append(r)
				break
	if _chart_rows.size() == 1:
		# Nothing named like upstream's two: the flame strip already names the
		# disjoint children of step, so borrow its first two.
		for r in _flame:
			if _chart_rows.size() >= 3:
				break
			if r > 0 and r < _rows.size():
				_chart_rows.append(r)


## Parent/child links come from Row.indent by a stack walk, exactly as upstream
## does it, so a feed can hand over any depth-ordered row list without also
## having to describe its own topology.
func _derive_tree() -> void:
	var stack: Array[int] = []
	for i in _rows.size():
		var indent := _row_indent(i)
		while not stack.is_empty() and _row_indent(stack[stack.size() - 1]) >= indent:
			stack.pop_back()
		var p := -1
		if not stack.is_empty():
			p = stack[stack.size() - 1]
		_parent[i] = p
		if p >= 0:
			_has_children[p] = true
		stack.push_back(i)


## One tick, one sample. Call from _physics_process; a paused tick simply never
## calls this, which is what keeps a pause out of the averages.
func poll() -> void:
	if _feed == null:
		return
	# Cheap getters, re-read every tick: the Jolt feed flips has_phases and its
	# proof string once it gives up waiting for job timings (SPEC B).
	_proof = str(_feed.source_proof())
	_has_phases = bool(_feed.has_phases())
	var s: PackedFloat32Array = _feed.sample()
	if s.is_empty():
		return
	if s.size() != _rows.size():
		# A feed that discovered its rows late (Jolt) rather than a bad feed:
		# re-adopt and drop this tick instead of writing a mismatched sample.
		_adopt_rows()
		return
	var i := _write & MASK
	for r in _rows.size():
		_ring[r * CAP + i] = s[r]
	_write += 1
	_count = mini(_count + 1, CAP)
	# Counters are read for a human, not tracked: a native query per tick would
	# be wasted work and the digits would be a blur on video anyway.
	_counter_tick += 1
	if _counter_tick % 10 == 1:
		_counters = _feed.counters()
	# The ring rescan lives in _draw (max is recomputed from scratch there), so
	# this only asks for a redraw, and only every other tick: 30 Hz costs half
	# as much and reads back off a video better than digits churning at 60.
	_apply_geometry()
	if _write % 2 == 0:
		queue_redraw()


## Clear the ring (and with it the max, which is never sticky).
func reset() -> void:
	_write = 0
	_count = 0
	_ring.fill(0.0)
	for r in _now.size():
		_now[r] = 0.0
		_avg[r] = 0.0
		_max[r] = 0.0
	_refresh()
	queue_redraw()


# --- Row accessors (Row is a plain Dictionary; tolerate a partial one) -------

func _row_label(r: int) -> String:
	return str((_rows[r] as Dictionary).get("label", "?"))


func _row_indent(r: int) -> int:
	return int((_rows[r] as Dictionary).get("indent", 0))


func _row_color(r: int) -> Color:
	return (_rows[r] as Dictionary).get("color", Color(0.86, 0.86, 0.86))


# --- Statistics -------------------------------------------------------------

## now / avg / max over the live ring, recomputed whole. 22 rows x 512 samples
## is a few microseconds and it keeps max self-healing (spikes age out).
func _compute_stats() -> void:
	var live := _count
	var recent := mini(live, NOW_WINDOW)
	var head := _write - live
	var recent_head := _write - recent
	for r in _rows.size():
		var base := r * CAP
		var total := 0.0
		var peak := 0.0
		for i in live:
			var v := _ring[base + ((head + i) & MASK)]
			total += v
			if v > peak:
				peak = v
		var sum_now := 0.0
		for i in recent:
			sum_now += _ring[base + ((recent_head + i) & MASK)]
		_now[r] = (sum_now / recent) if recent > 0 else 0.0
		_avg[r] = (total / live) if live > 0 else 0.0
		_max[r] = peak


## The step row is row 0 in every feed; everything proportional divides by it.
func _step_now() -> float:
	if _now.is_empty():
		return 0.001
	return maxf(_now[0], 0.001)


## True when the step time is too small to apportion honestly.
##
## Upstream clamps the divisor to 0.001 ms and leaves it there, which is fine
## in a sample app that never really idles. Here a settled scene (Cube Pile
## asleep: 4096 bodies, nothing awake) drives the real step to a few
## microseconds, and dividing phase times of the same magnitude by it paints a
## full-width rainbow flame strip and wide `% step` bars out of what is only
## clock granularity. At that point the chart is reporting noise as though it
## were structure, while every `now` column honestly reads 0.00 beside it.
##
## The cutoff is the display threshold: %6.2f rounds anything under 0.005 to
## "0.00", so if the step reads as zero, nothing proportional is drawn either
## and the panel stays internally consistent.
const IDLE_MS := 0.005

func _idle() -> bool:
	return _now.is_empty() or _now[0] < IDLE_MS


func _compute_visible() -> void:
	_visible = PackedInt32Array()
	if _rows.is_empty():
		return
	if not _has_phases:
		# No breakdown to show: the step row is the whole story.
		_visible.push_back(0)
		return
	for r in _rows.size():
		var shown := true
		var p := _parent[r]
		while p >= 0:
			if not _row_open[p]:
				shown = false
				break
			p = _parent[p]
		if not shown:
			continue
		# A leaf that never costs anything is noise; parents stay so the
		# structure still reads.
		if not _has_children[r] and _now[r] == 0.0 and _avg[r] == 0.0 and _max[r] == 0.0:
			continue
		_visible.push_back(r)


# --- Layout -----------------------------------------------------------------

func _refresh() -> void:
	if _rows.size() != _now.size():
		return
	_compute_stats()
	_compute_visible()

	# Width comes from the viewport, not from the columns: this is a strip along
	# the bottom edge and it has to end where the shell's sidebar starts. The
	# column layout only supplies a floor — and it is the same floor a manual
	# width is clamped against, because narrower than this the columns collide.
	var view := _view_size()
	var min_w := (X_PCT + MIN_BAR_W) if _has_phases else (X_MAX + NUM_W)
	if _show_plots:
		min_w += PLOT_GAP + PLOT_W
	min_w += PAD
	# Stop short of the shell's settings sidebar rather than at the window edge.
	# The panel is MOUSE_FILTER_STOP, so any width that reaches under the
	# sidebar swallows clicks meant for the controls there — including the
	# engine selector at its foot, which then looks like a dead dropdown.
	var max_w := maxf(view.x - RIGHT_RESERVE - EDGE_MARGIN * 2.0, min_w)
	var width := maxf(view.x - RIGHT_RESERVE - EDGE_MARGIN * 2.0, min_w)
	if _user_size.x > 0.0:
		width = clampf(_user_size.x, min_w, max_w)
	_x_plot = width - PAD - PLOT_W
	var bar_right := (_x_plot - PLOT_GAP) if _show_plots else (width - PAD)
	_bar_w = maxf(bar_right - X_PCT, MIN_BAR_W)

	var y := PAD
	_y_title = y + float(HEAD_PX)
	y += HEAD_PX + 8.0
	# The proof string is prose and can run long (the native feeds explain why
	# they have no phase breakdown), so wrap it to the panel instead of letting
	# it spill across the 3D view.
	_proof_lines = _wrap(_proof, PROOF_PX, width - PAD * 2.0)
	_y_proof = y + float(PROOF_PX)
	y += float(PROOF_PX + 3) * maxi(_proof_lines.size(), 1) + 9.0

	# Tabs and the two buttons share one line. In a drawer this short a line
	# spent on buttons alone is a line of rows given up, and the buttons only
	# ever act on the tab they sit next to.
	_y_tabs = y
	_tab_rects.clear()
	var tx := PAD
	for tab_name in TABS:
		var tw := _text_w(tab_name, TAB_PX) + TAB_PAD * 2.0
		_tab_rects.append(Rect2(tx, y, tw, TAB_H))
		tx += tw + TAB_GAP
	if _tab == TAB_PROFILE:
		var by := y + (TAB_H - BTN_H) * 0.5
		var plots_w := _text_w("Show plots", SMALL_PX) + 28.0 + BTN_H
		var reset_w := _text_w("Reset", SMALL_PX) + 28.0
		_plots_rect = Rect2(width - PAD - plots_w, by, plots_w, BTN_H)
		_reset_rect = Rect2(_plots_rect.position.x - 12.0 - reset_w, by, reset_w, BTN_H)
	else:
		# Zero-size rects: Rect2.has_point is false for every point, so the hit
		# tests need no second "is this tab showing" condition.
		_reset_rect = Rect2()
		_plots_rect = Rect2()
	y += TAB_H + 10.0

	# Everything above here is head, and a manual height cannot take any of it.
	# What follows is the body: where it starts, how tall it would like to be,
	# and (once the height is settled) how much of it actually shows.
	_y_flame = -1.0
	_scroll_step = ROW_H
	_content_h = 0.0
	var body_h := 0.0
	match _tab:
		TAB_COUNTERS:
			_y_counters = y
			# Long labels ("bodies (Jolt monitors read 0)"), short drawer: spend
			# the spare width on columns rather than on stacking every counter.
			_ct_cols = maxi(1, int(floor(
					(width - 2.0 * PAD + CT_GAP) / (CT_COL_W + VAL_W + CT_GAP))))
			var cn := _counters.size()
			var per := 1 if cn == 0 else int(ceil(float(cn) / float(_ct_cols)))
			_scroll_step = COUNTER_H
			_content_h = per * COUNTER_H
			body_h = _content_h
		TAB_CHART:
			_y_chart = y
			body_h = CHART_H + SMALL_PX + 6.0  # room for the caption under the axis
		_:
			if _has_phases and not _flame.is_empty():
				_y_flame = y
				y += FLAME_H + 14.0
			_y_colhead = y + float(SMALL_PX)
			y += SMALL_PX + 12.0
			_y_rows = y
			_content_h = _visible.size() * ROW_H
			body_h = _content_h
	_body_top = y

	# Auto-fit is still the content's own height; it only gains a ceiling, which
	# it never used to have — a 22-row Box3D panel on a short window ran off the
	# top of the screen, and now that the body scrolls there is somewhere for the
	# overflow to go. A manual height is clamped at both ends instead.
	var min_h := _body_top + _min_body_h() + PAD
	var max_h := maxf(view.y - EDGE_MARGIN * 2.0, min_h)
	var height := minf(_body_top + body_h + PAD, max_h)
	if _user_size.y > 0.0:
		height = clampf(_user_size.y, min_h, max_h)
	_min_size = Vector2(min_w, min_h)
	_max_size = Vector2(max_w, max_h)
	_panel_size = Vector2(width, height)
	_grip_rect = Rect2(width - GRIP - 3.0, 3.0, GRIP, GRIP)

	# Whole entries only. A Control cannot clip one region of its own _draw, so
	# instead of drawing a half row and trimming it, the body draws only the rows
	# that fit entirely and snaps the offset to a row boundary. Same guarantee —
	# nothing lands outside the body — with no clip machinery, and the wheel gets
	# list-like stepping for free. The leftover under the last row is padding.
	var avail := maxf(height - PAD - _body_top, 0.0)
	_body_fit = maxi(int(floor(avail / _scroll_step)), 1)
	_scroll_max = maxf(_content_h - _body_fit * _scroll_step, 0.0)
	_scroll = clampf(snappedf(_scroll, _scroll_step), 0.0, _scroll_max)
	# The chart is a shape, not a list: give it whatever height is going.
	_chart_h = maxf(avail - float(SMALL_PX) - 6.0, MIN_CHART_H)


## The floor a manual height is clamped to: head, plus enough body to be worth
## the space it costs.
func _min_body_h() -> float:
	match _tab:
		TAB_COUNTERS:
			return MIN_BODY_ROWS * COUNTER_H
		TAB_CHART:
			return MIN_CHART_H + float(SMALL_PX) + 6.0
		_:
			return MIN_BODY_ROWS * ROW_H


func _clamp_size(s: Vector2) -> Vector2:
	return Vector2(clampf(s.x, _min_size.x, _max_size.x),
			clampf(s.y, _min_size.y, _max_size.y))


func _view_size() -> Vector2:
	var vp := get_viewport()
	if vp == null:
		return Vector2(1280.0, 720.0)
	return vp.get_visible_rect().size


## Bottom-left, flush with the sidebar's own margins.
func _dock_position() -> Vector2:
	var view := _view_size()
	return Vector2(EDGE_MARGIN, maxf(view.y - _panel_size.y - EDGE_MARGIN, 0.0))


## Push the geometry _refresh() computed onto the Control. Deliberately not
## called from _draw: resizing a Control inside its own draw re-enters layout.
func _apply_geometry() -> void:
	if size == _panel_size and (not _docked or position == _dock_position()):
		return
	var grew := _panel_size.y - size.y
	size = _panel_size
	if _docked:
		position = _dock_position()
	else:
		# A dragged drawer keeps the bottom edge it was dragged to, so opening a
		# subtree or switching tabs grows it upward into the scene rather than
		# down off the screen.
		position.y -= grew
	_clamp_to_screen()


func _save_layout() -> void:
	var layout := ConfigFile.new()
	layout.load(LAYOUT_PATH)  # keep other sections if the file exists
	if _docked:
		# Re-docked (the grip was double-clicked): a placement left on disk would
		# undock the panel again on the next launch, so it has to go.
		_erase_key(layout, "position")
		_erase_key(layout, "size")
	else:
		layout.set_value("profiler_panel", "position", position)
		if _user_size == Vector2.ZERO:
			_erase_key(layout, "size")
		else:
			layout.set_value("profiler_panel", "size", _user_size)
	var open := PackedStringArray()
	for label in _open_labels:
		open.append(label)
	open.sort()  # stable file: a diff of ui.cfg should mean something changed
	layout.set_value("profiler_panel", "open_rows", open)
	layout.save(LAYOUT_PATH)


## has_section_key first, for the same reason every read here does it: ConfigFile
## complains about a key it was asked to drop and does not have.
func _erase_key(layout: ConfigFile, key: String) -> void:
	if layout.has_section_key("profiler_panel", key):
		layout.erase_section_key("profiler_panel", key)


## Greedy word wrap to a pixel width.
func _wrap(text: String, px: int, max_w: float) -> PackedStringArray:
	var out := PackedStringArray()
	if text == "":
		return out
	var line := ""
	for word in text.split(" ", false):
		var candidate := word if line == "" else line + " " + word
		if _text_w(candidate, px) <= max_w:
			line = candidate
		else:
			if line != "":
				out.append(line)
			line = word
	if line != "":
		out.append(line)
	return out


func _text_w(text: String, px: int) -> float:
	if _font == null:
		return float(text.length() * px) * 0.6
	return _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, px).x


# --- Input ------------------------------------------------------------------

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			var p: Vector2 = event.position
			# The grip owns its corner outright, so it is tested before anything
			# else could claim the point.
			if _grip_rect.has_point(p):
				if event.double_click:
					# The way back. A drawer dragged down to three rows and parked
					# is otherwise a puzzle to undo.
					_reset_size()
				else:
					_resizing = true
				accept_event()
				return
			for i in _tab_rects.size():
				if (_tab_rects[i] as Rect2).has_point(p):
					_tab = i
					# Each tab has its own body; a shared offset is just noise.
					_scroll = 0.0
					_relayout()
					accept_event()
					return
			if _reset_rect.has_point(p):
				reset()
				accept_event()
				return
			if _plots_rect.has_point(p):
				_show_plots = not _show_plots
				_relayout()
				accept_event()
				return
			var hit := _row_at(p)
			if hit >= 0 and _has_phases and _has_children[hit]:
				_row_open[hit] = not _row_open[hit]
				if _row_open[hit]:
					_open_labels[_row_label(hit)] = true
				else:
					_open_labels.erase(_row_label(hit))
				# Written on every twisty rather than at exit: the demo is closed
				# by killing the window as often as not.
				_save_layout()
				_relayout()
				accept_event()
				return
			_dragging = true
		else:
			if _resizing and _user_size != Vector2.ZERO:
				_save_layout()
			elif _dragging and not _docked:
				_save_layout()
			_resizing = false
			_dragging = false
		accept_event()
	elif event is InputEventMouseButton and event.pressed and _scroll_max > 0.0 \
			and (event.button_index == MOUSE_BUTTON_WHEEL_UP
			or event.button_index == MOUSE_BUTTON_WHEEL_DOWN):
		# Consumed only when there is somewhere to scroll to, so a wheel over a
		# drawer that fits still reaches the camera behind it, as it always has.
		var dir := -1.0 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0
		# Three entries a notch, but never a whole screenful: a jump with no
		# overlap leaves nothing to read the new position against.
		var lines := maxf(minf(3.0, float(_body_fit - 1)), 1.0)
		_scroll = clampf(_scroll + dir * _scroll_step * lines, 0.0, _scroll_max)
		queue_redraw()
		accept_event()
	elif event is InputEventMouseMotion and _resizing:
		# The grip drives the two free edges from the size it already has, and
		# _apply_geometry holds the bottom edge, so the anchored corner sits still
		# while the panel changes shape around it. Up is taller, hence the flip.
		_user_size = _clamp_size(_panel_size + Vector2(event.relative.x, -event.relative.y))
		# A manual size has to survive the next refresh, and a docked panel
		# re-derives its geometry on every one of them.
		_docked = false
		_relayout()
		accept_event()
	elif event is InputEventMouseMotion and _dragging:
		position += event.relative
		# A press that never moves is not a placement, so the dock only gives way
		# once the pointer actually travels.
		_docked = false
		_clamp_to_screen()
		accept_event()
	elif event is InputEventMouseMotion:
		var hot := _grip_rect.has_point(event.position)
		if hot != _grip_hover:
			_grip_hover = hot
			queue_redraw()


## Anything that changes the panel's shape from a click: recompute, resize, keep
## the drawer on screen, redraw.
func _relayout() -> void:
	_refresh()
	_apply_geometry()
	queue_redraw()


## Back to auto-fit and back to the dock, with the saved size forgotten, so the
## panel follows the window again the way it did before it was ever touched.
func _reset_size() -> void:
	_user_size = Vector2.ZERO
	_docked = true
	_scroll = 0.0
	_save_layout()
	_relayout()


func _clear_grip_hover() -> void:
	if _grip_hover:
		_grip_hover = false
		queue_redraw()


## Which visible row (if any) a point lands on. The whole section cell is the
## twisty's hit area: a 7 px arrow is not a target anyone can hit on a stream.
func _row_at(p: Vector2) -> int:
	if _tab != TAB_PROFILE:
		return -1
	if p.x < X_SECTION or p.x > X_NOW:
		return -1
	# Only the rows on screen are hittable, and the offset has to come off the
	# same way _draw_rows puts it on, or a scrolled panel toggles the wrong row.
	if p.y < _y_rows or p.y >= _y_rows + _body_fit * ROW_H:
		return -1
	var i := int(floor((p.y - _y_rows + _scroll) / ROW_H))
	if i < 0 or i >= _visible.size():
		return -1
	return _visible[i]


## Keep the panel reachable: never let it leave the visible viewport.
func _clamp_to_screen() -> void:
	var view := _view_size()
	position = position.clamp(Vector2.ZERO, (view - size).max(Vector2.ZERO))


# --- Drawing primitives -----------------------------------------------------

## Text with a drop shadow, so it survives whatever the scene puts behind the
## panel (same idiom as compare/overlay.gd).
func _big(pos: Vector2, text: String, px: int, color: Color) -> void:
	draw_string(_font, pos + Vector2(2, 2), text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, px, Color(0, 0, 0, 0.85))
	draw_string(_font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, px, color)


## Right-aligned numeral: the default theme font is proportional, so the columns
## are held by alignment rather than by the "%6.2f" padding.
func _num(x: float, w: float, baseline: float, text: String, px: int, color: Color) -> void:
	draw_string(_font, Vector2(x + 2.0, baseline + 2.0), text,
			HORIZONTAL_ALIGNMENT_RIGHT, w, px, Color(0, 0, 0, 0.85))
	draw_string(_font, Vector2(x, baseline), text,
			HORIZONTAL_ALIGNMENT_RIGHT, w, px, color)


func _twisty(center: Vector2, open: bool, color: Color) -> void:
	var r := 7.0
	var pts := PackedVector2Array()
	if open:
		pts = PackedVector2Array([
			center + Vector2(-r, -r * 0.55), center + Vector2(r, -r * 0.55),
			center + Vector2(0, r * 0.75)])
	else:
		pts = PackedVector2Array([
			center + Vector2(-r * 0.55, -r), center + Vector2(-r * 0.55, r),
			center + Vector2(r * 0.75, 0)])
	var shadow := PackedVector2Array()
	for pt in pts:
		shadow.push_back(pt + Vector2(2, 2))
	draw_colored_polygon(shadow, Color(0, 0, 0, 0.85))
	draw_colored_polygon(pts, color)


## The resize grip: three ticks stacked into the top-right corner over a faint
## wedge. The wedge is not decoration — it says how much of the corner is
## grabbable, which three thin ticks on their own do not.
func _grip(rect: Rect2) -> void:
	var col := accent if (_resizing or _grip_hover) else Color(0.72, 0.78, 0.86, 0.95)
	var tr := rect.position + Vector2(rect.size.x, 0.0)
	draw_colored_polygon(PackedVector2Array([rect.position, tr, rect.end]),
			Color(col.r, col.g, col.b, 0.14))
	for i in 3:
		var d := rect.size.x * (0.34 + 0.28 * i)
		var a := rect.position + Vector2(rect.size.x - d, 0.0)
		var b := rect.position + Vector2(rect.size.x, d)
		draw_line(a + Vector2(2, 2), b + Vector2(2, 2), Color(0, 0, 0, 0.85), 3.0)
		draw_line(a, b, col, 3.0)


## Slim indicator down the body's right edge, drawn only when there is somewhere
## to scroll to — which makes it the discovery hint for the wheel as well as the
## position readout. Sits inside the right padding, clear of the % step bars.
func _scroll_hint(w: float) -> void:
	var view_h := _body_fit * _scroll_step
	var x := w - PAD * 0.5 - SCROLL_W
	# A lit track, not a dark one: on a near-black panel an unlit groove is
	# invisible, and the whole point of drawing it is that it be noticed.
	draw_rect(Rect2(x, _body_top, SCROLL_W, view_h), Color(1, 1, 1, 0.14))
	var thumb := maxf(view_h * clampf(view_h / maxf(_content_h, 1.0), 0.0, 1.0), 26.0)
	var t := clampf(_scroll / _scroll_max, 0.0, 1.0)
	draw_rect(Rect2(x, _body_top + (view_h - thumb) * t, SCROLL_W, thumb),
			Color(accent.r, accent.g, accent.b, 0.85))


func _button(rect: Rect2, label: String, on: bool, checkbox: bool) -> void:
	var edge := accent if on else Color(1, 1, 1, 0.35)
	draw_rect(rect, Color(0.11, 0.13, 0.17, 0.95))
	draw_rect(rect, edge, false, 2.0)
	var tx := rect.position.x + 14.0
	if checkbox:
		var box := Rect2(rect.position.x + 8.0, rect.position.y + 6.0,
				BTN_H - 12.0, BTN_H - 12.0)
		draw_rect(box, Color(0, 0, 0, 0.5))
		draw_rect(box, Color(1, 1, 1, 0.5), false, 2.0)
		if on:
			draw_rect(box.grow(-4.0), accent)
		tx = box.position.x + box.size.x + 10.0
	_big(Vector2(tx, rect.position.y + rect.size.y * 0.72), label, SMALL_PX,
			Color(0.92, 0.95, 1.0, 0.95))


# --- Draw -------------------------------------------------------------------

func _draw() -> void:
	if _font == null:
		_font = get_theme_default_font()
		if _font == null:
			return
	# Stats and layout are refreshed here too so `max` really is recomputed per
	# draw, as the upstream panel does it.
	_refresh()

	var w := _panel_size.x
	var h := _panel_size.y
	draw_rect(Rect2(0, 0, w, h), Color(0.03, 0.04, 0.06, 0.94))
	draw_rect(Rect2(0, 0, w, h), Color(1, 1, 1, 0.10), false, 2.0)
	draw_rect(Rect2(0, 0, 8.0, h), accent)  # engine-colored spine
	# Before the early-outs below: an empty panel still has to be resizable.
	_grip(_grip_rect)

	_big(Vector2(PAD, _y_title), _engine, HEAD_PX, Color(1, 1, 1, 0.98))
	if _now.size() > 0:
		_num(w - PAD - STEP_W, STEP_W, _y_title, "step %6.2f ms" % _now[0], STEP_PX,
				Color(0.55, 0.95, 0.6, 0.98))
	var proof_y := _y_proof
	for line in _proof_lines:
		_big(Vector2(PAD, proof_y), line, PROOF_PX, accent)
		proof_y += float(PROOF_PX + 3)

	_draw_tabs()

	if _rows.is_empty():
		return
	match _tab:
		TAB_COUNTERS:
			_draw_counters(w)
		TAB_CHART:
			_draw_chart(w)
		_:
			_button(_reset_rect, "Reset", false, false)
			_button(_plots_rect, "Show plots", _show_plots, true)
			if _count == 0:
				_big(Vector2(PAD, _y_colhead), "waiting for samples", SMALL_PX,
						Color(0.8, 0.84, 0.9, 0.9))
				return
			if _y_flame >= 0.0:
				_draw_flame(w)
			_draw_header(w)
			_draw_rows(w)
			if _scroll_max > 0.0:
				_scroll_hint(w)


## Upstream's drawer is a tab bar, not a stack: Profile, Counters and Frame Time
## are alternatives, and only one of them costs height at a time.
func _draw_tabs() -> void:
	for i in _tab_rects.size():
		var rect: Rect2 = _tab_rects[i]
		var on := i == _tab
		if on:
			# Tinted fill plus a 4 px accent underline. On a scaled-down capture a
			# lighter grey alone is not a difference anyone can see, and an outline
			# would just read as another button.
			draw_rect(rect, Color(accent.r, accent.g, accent.b, 0.26))
			draw_rect(Rect2(rect.position.x, rect.end.y - 4.0, rect.size.x, 4.0), accent)
		else:
			draw_rect(rect, Color(0.06, 0.07, 0.10, 0.9))
			draw_rect(rect, Color(1, 1, 1, 0.12), false, 2.0)
		var label := str(TABS[i])
		var tx := rect.position.x + (rect.size.x - _text_w(label, TAB_PX)) * 0.5
		_big(Vector2(tx, rect.position.y + rect.size.y * 0.68), label, TAB_PX,
				Color(1, 1, 1, 0.98) if on else Color(0.72, 0.78, 0.86, 0.9))


## Step subdivided by its disjoint top-level children, plus whatever the feed
## does not account for. One glance says where the tick went.
func _draw_flame(w: float) -> void:
	var avail := w - 2.0 * PAD
	var step := _step_now()
	draw_rect(Rect2(PAD, _y_flame, avail, FLAME_H), Color(0, 0, 0, 0.45))
	if _idle():
		# Empty track plus a word, rather than a rainbow made of clock jitter.
		draw_string(_font, Vector2(PAD + 8.0, _y_flame + FLAME_H * 0.72), "idle",
				HORIZONTAL_ALIGNMENT_LEFT, -1, SMALL_PX, Color(0.6, 0.64, 0.7, 0.85))
		return
	var x := PAD
	var used := 0.0
	for r in _flame:
		if r < 0 or r >= _now.size():
			continue
		var v := _now[r]
		used += v
		var seg := avail * (v / step)
		if seg <= 0.0:
			continue
		seg = minf(seg, PAD + avail - x)
		if seg <= 0.0:
			break
		var col := _row_color(r)
		draw_rect(Rect2(x, _y_flame, seg, FLAME_H), col)
		var label := _row_label(r)
		if seg > _text_w(label, SMALL_PX) + 16.0:
			draw_string(_font, Vector2(x + 8.0, _y_flame + FLAME_H * 0.72), label,
					HORIZONTAL_ALIGNMENT_LEFT, -1, SMALL_PX, Color(0.05, 0.05, 0.07, 0.9))
		x += seg
	var other := maxf(step - used, 0.0)
	var other_w := minf(avail * (other / step), PAD + avail - x)
	if other_w > 0.0:
		draw_rect(Rect2(x, _y_flame, other_w, FLAME_H), Color(0.35, 0.35, 0.35))


func _draw_header(w: float) -> void:
	var dim := Color(0.72, 0.78, 0.86, 0.95)
	_big(Vector2(X_SECTION, _y_colhead), "section", SMALL_PX, dim)
	_num(X_NOW, NUM_W, _y_colhead, "now", SMALL_PX, dim)
	_num(X_AVG, NUM_W, _y_colhead, "avg", SMALL_PX, dim)
	_num(X_MAX, NUM_W, _y_colhead, "max", SMALL_PX, dim)
	if _has_phases:
		_big(Vector2(X_PCT, _y_colhead), "% step", SMALL_PX, dim)
	if _show_plots:
		_big(Vector2(_x_plot, _y_colhead), "history", SMALL_PX, dim)
	# A 2 px rule, not a hairline: 1 px lines vanish when the capture is scaled.
	draw_rect(Rect2(PAD, _y_colhead + 6.0, w - 2.0 * PAD, 2.0), Color(1, 1, 1, 0.25))


func _draw_rows(w: float) -> void:
	var step := _step_now()
	var idle := _idle()
	# Whole rows only, from the first one the offset uncovers (see _refresh).
	var first := int(_scroll / ROW_H)
	for vi in range(first, mini(first + _body_fit, _visible.size())):
		var r := _visible[vi]
		var top := _y_rows + vi * ROW_H - _scroll
		if vi % 2 == 1:
			draw_rect(Rect2(8.0, top, w - 8.0, ROW_H), Color(1, 1, 1, 0.05))
		var base := top + ROW_H * 0.72
		var col := _row_color(r)
		var lx := X_SECTION + _row_indent(r) * INDENT_W
		if _has_phases and _has_children[r]:
			_twisty(Vector2(lx + 9.0, top + ROW_H * 0.5), _row_open[r], col)
		_big(Vector2(lx + TWIST_W, base), _row_label(r), ROW_PX, col)

		var white := Color(1, 1, 1, 0.95)
		_num(X_NOW, NUM_W, base, "%6.2f" % _now[r], ROW_PX, white)
		_num(X_AVG, NUM_W, base, "%6.2f" % _avg[r], ROW_PX, Color(0.86, 0.9, 0.95, 0.92))
		_num(X_MAX, NUM_W, base, "%6.2f" % _max[r], ROW_PX, Color(0.86, 0.9, 0.95, 0.92))

		if _has_phases:
			var bar := Rect2(X_PCT, top + 4.0, _bar_w, ROW_H - 8.0)
			draw_rect(bar, Color(1, 1, 1, 0.10))
			# Empty track while idle, for the same reason the flame strip is
			# blank: a proportion of nothing is not a proportion.
			var frac := 0.0 if idle else clampf(_now[r] / step, 0.0, 1.0)
			if frac > 0.0:
				draw_rect(Rect2(bar.position, Vector2(bar.size.x * frac, bar.size.y)), col)
		if _show_plots:
			_draw_plot(Rect2(_x_plot, top + 3.0, PLOT_W, ROW_H - 6.0), r, col)


## Per-row sparkline, autoscaled to that row's own max (upstream uses
## rowMax * 1.05) so a cheap phase still shows its shape.
func _draw_plot(rect: Rect2, r: int, col: Color) -> void:
	draw_rect(rect, Color(0, 0, 0, 0.4))
	if _count < 2:
		return
	var top := _max[r] * 1.05 + 0.001
	var base := r * CAP
	var head := _write - _count
	var pts := PackedVector2Array()
	pts.resize(_count)
	var dx := rect.size.x / float(_count - 1)
	for i in _count:
		var v := _ring[base + ((head + i) & MASK)]
		pts[i] = Vector2(rect.position.x + i * dx,
				rect.position.y + rect.size.y * (1.0 - clampf(v / top, 0.0, 1.0)))
	draw_polyline(pts, col, 2.0)


## Counters tab. Upstream fetches b3Counters fresh every draw and prints every
## field; a feed here hands over whatever its engine can answer, so this is the
## same table with the field list left to the feed.
func _draw_counters(w: float) -> void:
	var keys := _counters.keys()
	if keys.is_empty():
		_big(Vector2(PAD, _y_counters + SMALL_PX), "this feed reports no counters",
				SMALL_PX, Color(0.8, 0.84, 0.9, 0.9))
		return
	var col_w := (w - 2.0 * PAD - (_ct_cols - 1) * CT_GAP) / float(_ct_cols)
	var per := int(ceil(float(keys.size()) / float(_ct_cols)))
	var first := int(_scroll / COUNTER_H)
	var last := first + _body_fit
	for i in keys.size():
		# Column-major: a counter list is read down, not across.
		var col := i / per
		var row := i % per
		if row < first or row >= last:
			continue  # scrolled out; whole entries only, as on the Profile tab
		var x := PAD + col * (col_w + CT_GAP)
		var top := _y_counters + row * COUNTER_H - _scroll
		if row % 2 == 1:
			draw_rect(Rect2(x, top, col_w, COUNTER_H), Color(1, 1, 1, 0.05))
		var base := top + COUNTER_H * 0.72
		_big(Vector2(x + 6.0, base), str(keys[i]), SMALL_PX, Color(0.8, 0.85, 0.92, 0.95))
		_num(x + col_w - VAL_W - 6.0, VAL_W, base, _fmt_value(_counters[keys[i]]),
				SMALL_PX, Color(1, 1, 1, 0.95))
	if _scroll_max > 0.0:
		_scroll_hint(w)


## Frame Time tab: upstream's ImPlot line chart, three series over the live
## ring, y range 0 .. max(maxStep, 1) * 1.05 (recomputed every draw, like max).
func _draw_chart(w: float) -> void:
	# _chart_h, not CHART_H: the chart is the one body that stretches to the room
	# a manual height gives it instead of scrolling inside it.
	var rect := Rect2(PAD + AXIS_W, _y_chart, w - 2.0 * PAD - AXIS_W, _chart_h)
	draw_rect(rect, Color(0, 0, 0, 0.45))
	var top := maxf(_max[0] if _max.size() > 0 else 0.0, 1.0) * 1.05
	# Three gridlines only. The chart is here to show shape and relative cost;
	# anyone reading exact numbers has the Profile tab for that.
	for i in 3:
		var f := float(i) * 0.5
		var gy := rect.end.y - rect.size.y * f
		draw_rect(Rect2(rect.position.x, gy - 1.0, rect.size.x, 2.0), Color(1, 1, 1, 0.12))
		# Only the top tick carries the unit — three "ms" in a gutter is noise.
		var tick := ("%.1f ms" % top) if i == 2 else ("%.1f" % (top * f))
		_num(PAD, AXIS_W - 10.0, gy + 5.0, tick, SMALL_PX, Color(0.72, 0.78, 0.86, 0.95))
	if _count < 2:
		_big(Vector2(rect.position.x + 12.0, rect.position.y + 28.0),
				"waiting for samples", SMALL_PX, Color(0.8, 0.84, 0.9, 0.9))
		return
	var head := _write - _count
	# Upstream pins the x axis to the ring's full 512 and leaves a partial buffer
	# occupying part of the plot; stretching to the samples in hand fills the
	# drawer instead, and the tick count under the axis says how many that is.
	var dx := rect.size.x / float(_count - 1)
	var legend_w := 0.0
	for r in _chart_rows:
		if r >= 0 and r < _now.size():
			legend_w += 14.0 + 10.0 + _text_w(_row_label(r), SMALL_PX) + 18.0
	var lx := rect.end.x - 12.0 - legend_w
	for r in _chart_rows:
		if r < 0 or r >= _now.size():
			continue
		var base := r * CAP
		var pts := PackedVector2Array()
		pts.resize(_count)
		for i in _count:
			var v := _ring[base + ((head + i) & MASK)]
			pts[i] = Vector2(rect.position.x + i * dx,
					rect.end.y - rect.size.y * clampf(v / top, 0.0, 1.0))
		draw_polyline(pts, Color(0, 0, 0, 0.7), 5.0)  # shadow, not an outline
		draw_polyline(pts, _row_color(r), 3.0)
		# Legend along the top right, in series order: the lines themselves start
		# at the left edge and climb, so that corner is the one they leave alone.
		draw_rect(Rect2(lx, rect.position.y + 8.0, 14.0, 14.0), _row_color(r))
		lx += 14.0 + 10.0
		var label := _row_label(r)
		_big(Vector2(lx, rect.position.y + 20.0), label, SMALL_PX, _row_color(r))
		lx += _text_w(label, SMALL_PX) + 18.0
	_big(Vector2(rect.position.x + 4.0, rect.end.y + SMALL_PX + 2.0),
			"%d ticks" % _count, SMALL_PX, Color(0.72, 0.78, 0.86, 0.8))


func _fmt_value(v) -> String:
	if v is float:
		return "%.2f" % v
	return str(v)
