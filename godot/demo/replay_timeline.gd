class_name ReplayTimeline
extends PanelContainer

## The shell's replay transport (F-R3): a bottom bar that plays a saved
## recording back through `Box3DReplayPlayer` and draws it with
## `Box3DReplayRenderer`.
##
## BEHAVIOUR REFERENCE, not quality bar: upstream's transport row
## (`samples/sample_replay.cpp:780-846`) and its Timeline tab
## (`samples/sample_replay.cpp:1645-1730`) -- first/last, single-step both ways,
## play/pause, a scrubber that seeks in both directions, a frame counter, a
## keyframe readout and a divergence mark drawn on the scrubber track. Two
## things are deliberately different here:
##
##  1. PLAY BACKWARD IS A TRANSPORT STATE, not just a step button. Upstream can
##     only step back one frame at a time; running a recording in reverse is the
##     thing a physics recording is most worth having, so it is a first-class
##     direction.
##
##     AND IT DOES NOT USE THE SOLVER (F-R4). Upstream's backward step is
##     `b3RecPlayer_SeekFrame`, which restores the nearest keyframe and re-steps
##     the gap (`src/recording_replay.c:3148-3194`) -- it RE-SIMULATES every
##     frame it shows you. A displayed frame does not need the solver, only the
##     shape transforms, so `Box3DReplayRenderer` remembers them: every frame
##     the transport displays through the player is captured, and a backward
##     step that finds its frame in that cache is a MultiMesh upload and nothing
##     else. Measured on Cube Pile (4097 shapes, 400 frames, template_debug):
##     backward play went 148 ms/frame -> 0.4 ms/frame, a random scrub
##     334 ms -> 0.4 ms, against 8.7 ms/frame for forward play.
##
##     The old cost model in this file was also simply WRONG at scale, which is
##     worth recording: one Cube Pile keyframe is ~28 MiB, so the 96 MiB budget
##     below holds three of them and the ring doubles its spacing from the
##     requested 8 up to 128. Sweeping the requested interval 1..32 moved
##     neither the effective interval (128 throughout) nor backward play
##     (78 ms throughout). `KEYFRAME_MIN_INTERVAL` is not a lever here; it only
##     governs the fallback for frames the cache does not hold.
##
##  2. NOTHING BLOCKS. Upstream opens a modal and pre-generates the whole
##     keyframe ring behind a progress bar before the recording can be touched
##     (`samples/sample_replay.cpp:400-480`). Here the policy is applied
##     silently, the recording is playable the instant it opens, and the index
##     pass is amortized across frames in small slices. A partly filled ring is
##     not a broken one: it just makes a backward seek into the unfilled tail
##     cost more re-stepping.
##
##     The pass is also the cache's filler now, so it no longer MOVES THE VIEW
##     while it runs (it used to scrub the viewport forward on its own). It
##     steps the player and stores frames without uploading them; the viewer
##     stays exactly where the user parked it. Interaction suspends the pass
##     instead of killing it, and it resumes after half a second of quiet.
##
##     WHAT A NON-BLOCKING PASS OWES THE USER (F-044) is a way to SEE it. It
##     used to report itself as one fragment of a 12 px status strip, which was
##     reported as missable, so the pass is now visible twice: the frames it has
##     indexed are painted on the scrubber's own track as a buffered band, the
##     way a video player paints its buffer, and a 20 px "Indexing NN%" sits in
##     the transport row while the pass is actually running. Both come off the
##     frame cache, so what the number says and what the track shows are the
##     same fact; the band paints the ranges it really holds, so a cache with a
##     hole in it is drawn as two bands and not as one long lie.
##
##     AND NOTHING BLOCKS WAS STILL A LIE PAST THE BAND (F-050). The cache is a
##     memory window, so a long recording of a big scene indexed a quarter of
##     itself and stood down, and a seek past that band went back to the
##     keyframe-and-re-step path INSIDE ONE CALL -- 6.1 seconds, measured, six
##     hundred frames out. Two changes. The renderer writes its overflow to a
##     temp file (`frame_cache_spill_path`), so the coverage is the whole
##     recording and it is a PREFIX. And because it is a prefix, the player is
##     never walked backward again and a seek above the frontier is a WAIT
##     rather than a freeze: the playhead goes where the user put it, the
##     picture stays on the newest frame there is, the index pass is told to
##     hurry, and the bar keeps taking input the whole way. One tick of that
##     wait is one solver step -- 27 ms mean and 161 ms at its worst on the
##     reported scene, which is the physics and not the cache -- and the frames
##     it walks past are kept, so the same seek afterwards is 0.4 ms.
##
## DIVERGENCE IS INFORMATION. `has_diverged()` means the embedded state hashes
## did not reproduce; the player keeps going and so does this bar. It is never a
## dialog and never an error, and nothing here claims a clean pass proves
## bit-exactness -- determinism on the wasm build is unverified, and a matching
## hash covers body transforms and velocities only (`b3HashWorldState`,
## `src/recording.c:1223-1266`).
##
## THE PLAYER NEVER TOUCHES THE LIVE WORLD. `b3RecPlayer_Create` stands up a
## private world and retargets every recorded id onto it, so the paused sample
## behind this bar is untouched by anything the transport does.

## Emitted when the user closes the bar. The shell listens and restores the live
## sample; this node never tears the sample down itself.
signal closed

## Keyframe policy, applied silently at open.
##
## This governs the FALLBACK only: a frame the transform cache does not hold is
## produced by restoring the nearest keyframe and re-stepping the gap. Tighter
## costs memory the ring then evicts (it doubles the spacing to stay under
## budget), and at Cube Pile scale it is already evicting hard -- see the
## measurement in the header. 8 is upstream's own shape of policy and is left
## alone; the cache is what carries reverse playback.
const KEYFRAME_MIN_INTERVAL := 8
## Budget. The web build gets a small one for the same reason everything else is
## smaller there -- a browser tab's heap is not a desktop's -- and it is gated
## on a feature tag, never on a project setting.
const KEYFRAME_BUDGET_DESKTOP := 96 << 20
const KEYFRAME_BUDGET_WEB := 16 << 20

## Milliseconds per frame the amortized index pass may spend. Small enough that
## a 60 Hz frame still has most of itself left.
const PREGEN_SLICE_MS := 3.0
## Frames of quiet before a suspended index pass picks itself back up. Long
## enough that a scrub drag (a stream of value_changed) never competes with it.
const PREGEN_IDLE_FRAMES := 30

## Budget for the displayed-frame cache that carries reverse playback, in bytes.
## A separate pool from the keyframe ring above and a much better-spent one: a
## Cube Pile frame is 131 KiB here (4097 instances x 32 B) against ~28 MiB for
## one keyframe, so this holds the whole of a 400-frame recording where the ring
## holds three snapshots. Web gets a small one for the same reason its keyframe
## budget is small -- a browser tab's heap is not a desktop's -- gated on a
## feature tag, never on a project setting.
const FRAME_CACHE_DESKTOP := 96 << 20
const FRAME_CACHE_WEB := 8 << 20

## F-050. Where the frame cache puts the chunks the memory budget pushes out.
##
## THE PROBLEM THAT BOUGHT THIS. The budget above is a WINDOW, and on a long
## recording of a big scene it is a small fraction of the whole: Huge Pyramid
## stores 328 KB a frame, so 96 MB is 292 frames, and a user's 1200-frame
## session indexed 306 and stood down. Past that band every frame cost the
## player a keyframe restore and a re-step of the gap -- MEASURED at 0.5 s
## forty frames out, 2.0 s at two hundred and 6.1 s at six hundred, because one
## keyframe of that scene is 30 MB and the ring's spacing had doubled to 256.
##
## A cached frame is quantised transforms. Reading 328 KB back is milliseconds;
## re-simulating 256 frames of 16,290 bodies is seconds. So the overflow is
## written to a temp file the renderer owns, and how many frames the transport
## can reach stops depending on how much memory the cache is allowed.
##
## NOT ON THE WEB, and not as an oversight: `user://` under Emscripten is
## IndexedDB through its own filesystem layer, so "spilling" there moves bytes
## from one part of the wasm heap to another and saves nothing. The browser
## build keeps the memory window it had, and the honest band says so.
const SPILL_DIR := "user://replay_cache"
## Ceiling on that temp file. 2 GiB is 6,400 frames of the worst scene this demo
## can record and 26,000 frames of Cube Pile; past it the spill stands down
## softly and the cache is a window again.
const SPILL_DISK_BUDGET := 2 << 30

## How far below a backward cache MISS to rebuild before showing it. The miss
## costs a keyframe restore plus a re-step of the gap whatever we do, so it is
## paid once for a block instead of once per displayed frame, and the next
## BACKFILL_SPAN backward frames come out of the cache for free.
const BACKFILL_SPAN := 16

## F-050. Frames of a stalled index pass before an outstanding wait gives up and
## takes the blocking seek. Two seconds at 60 Hz -- long enough that a slow
## solver step is never mistaken for a stall, short enough that a wait which
## genuinely cannot be satisfied does not hang the readout forever.
const WAIT_STALL_FRAMES := 120

## F-044, the buffer band. The portion of the recording already held as
## ready-to-draw transforms is painted on the scrubber's track the way a video
## player paints its buffered range, so "the background pass is still working"
## is a thing you SEE rather than a percentage in a 12 px status strip.
##
## Height of the band, in pixels. Matched to the track stylebox below, so the
## band sits exactly on the track and never on the grabber -- the grabber is the
## playhead and has to stay readable through and above the fill.
const FILL_BAND_HEIGHT := 6.0
## How many probes the band may spend locating holes when the cache is NOT one
## contiguous window. The contiguous case -- which is the normal one, because
## eviction only ever takes from the two ENDS of the window
## (`evict_to_budget`, godot/src/box3d_replay_renderer.cpp) -- is answered
## exactly from the count and the range, with no probing at all.
const FILL_PROBES := 128
## The band's colours. The empty track is the shell's own panel gray a shade
## lighter than the bar behind it; the filled part is the box3d accent
## (`main.gd` ENGINE_ACCENTS "box3d"), held under half alpha so the divergence
## tick -- which is drawn AFTER it, and red -- reads straight through.
const TRACK_EMPTY_COLOR := Color(0.17, 0.19, 0.24, 1.0)
## The buffered range. F-050 splits it in two: everything indexed is painted at
## a quarter alpha, and the part still in MEMORY is painted over it at the
## original half. One hue, because both are frames that draw without touching
## the player; two weights, because one of them is 0.3 ms and the other is 4.
const TRACK_CACHED_COLOR := Color(0.35, 0.85, 1.0, 0.24)
const TRACK_RESIDENT_COLOR := Color(0.35, 0.85, 1.0, 0.5)
const INDEX_ACCENT_COLOR := Color(0.35, 0.85, 1.0)

const SPEEDS := [0.25, 0.5, 1.0, 2.0, 4.0]
const SPEED_NAMES := ["0.25x", "0.5x", "1x", "2x", "4x"]
const DEFAULT_SPEED_INDEX := 2

## Set false before `open_recording` to keep the bar from doing anything on its
## own. The headless selftests drive the transport by hand and would otherwise
## be racing the index pass.
##
## Since F-050 this is the ONE switch for "the bar may move the player itself":
## it gates the amortized index pass and the non-blocking wait alike, so a
## hand-driven harness still gets a `seek_to` that has arrived by the time it
## returns instead of a wait it would have to pump `_process` to satisfy.
var auto_pregen := true

var _player: Box3DReplayPlayer = null
var _renderer: Box3DReplayRenderer = null
var _host: Node3D = null
var _path := ""
var _frame_count := 0
var _time_step := 1.0 / 60.0
var _sub_steps := 4

## -1 backward, 0 paused, +1 forward.
var _direction := 0
var _speed := 1.0
var _accum := 0.0
var _syncing := false  ## guard while pushing the frame onto the scrubber
## F-038: the host's debug switch, mirrored onto the renderer, never written to.
var _debug_style := false
## F-042: `{ "index:generation": Color }` read from the recording's sidecar, or
## empty when it has none. Kept for the readout and the tests; the renderer holds
## its own resolved copy.
var _color_overrides := {}
## F-045: `{ "index:generation": {"roughness","metallic","specular"} }` from a v2
## sidecar, for the bodies whose response is not Godot's default. Empty for a v1
## sidecar or none. Forwarded to the renderer only IF it has grown an API for it
## (see `open_recording`); until then this is captured, carried and readable, and
## the renderer keeps shading every body with its one fixed response.
var _material_overrides := {}

## What is ON SCREEN. Not the same as `_player.get_frame()`: a frame served from
## the cache leaves the player wherever it was, and the index pass runs the
## player far ahead of the view on purpose. This is the number the UI shows and
## the one every transport operation is relative to.
var _display_frame := 0

## The amortized index pass: true while it still has work. Interaction suspends
## it (see `_idle_frames`) rather than killing it.
var _pregen := false
var _idle_frames := 0
## Set once anything REPOSITIONS the player out of sequence. A seek breaks the
## contiguous walk the embedded state hashes are checked along, so the pass can
## still fill the cache afterwards but must not claim a verdict.
var _pass_broken := false
## The pass gets one trip back to frame 0 to cover a range it started above.
var _pass_wrapped := false
## The verdict from that pass, kept because `restart()` clears the player's own
## divergence flag and the mark has to survive it.
var _diverge_frame := -1
var _pass_complete := false

## F-R4's hook: what one displayed frame cost, in microseconds, and a smoothed
## average of the same. Cheap enough to keep always on (one `get_ticks_usec`
## pair per advance) and it is the number the smoothness work will optimise.
var _last_advance_usec := 0
var _avg_advance_usec := 0.0
## Whether the last displayed frame came out of the cache. Test-facing.
var _last_was_cached := false

## F-044: the cached ranges the band is currently painting, as inclusive
## [first, last] frame pairs, and the cache signature they were derived from
## (count, first, last). Recomputed only when that signature moves, so the
## per-frame cost of the band is three getters and a comparison -- nothing on
## the 0.04 ms cached-frame path, which is timed around `_advance` / `_show`
## and does not include the UI refresh at all.
var _fill_runs: Array[Vector2i] = []
## F-050: the same, for the frames still IN MEMORY. Painted brighter over the
## band, so the sliding working set is visible inside the coverage rather than
## the two being conflated.
var _resident_runs: Array[Vector2i] = []
var _fill_sig := Vector4i(-2, -2, -2, -2)

## F-050. What is ON SCREEN, which during a wait is not `_display_frame`.
##
## THE TWO NUMBERS ARE DIFFERENT THINGS and separating them is the whole of the
## honest-UI half. `_display_frame` is where the USER put the playhead; it drives
## the scrubber and the counter and it moves the instant they ask. `_shown_frame`
## is the newest frame the cache can actually draw, which is what the viewport
## gets. They are equal except while the transport is waiting for the index pass
## to reach a frame that has never been simulated -- and during that wait the bar
## says so, keeps taking input, and shows the pass racing toward the mark.
var _shown_frame := 0
## The frame a user asked for that is not indexed yet, or -1. Set by `_show`
## when the cache misses ahead of the frontier; cleared the moment it arrives.
var _want_frame := -1
## Where the wait started, so "how far along is it" is a real fraction rather
## than a spinner with no end in sight.
var _want_from := 0
## Consecutive frames the index pass has failed to move its frontier while a
## wait is outstanding. A wait that is not progressing is not a wait.
var _want_stall := 0

var _slider: HSlider = null
var _fill: Control = null
var _diverge_tick: ColorRect = null
var _counter: Label = null
var _index_label: Label = null
var _index_spinner: ShellSpinner = null  ## F-048: the same state, in motion
var _readout: Label = null
var _speed_option: OptionButton = null
var _play_btn: Button = null
var _rev_btn: Button = null
var _pause_btn: Button = null


func _ready() -> void:
	set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	grow_vertical = Control.GROW_DIRECTION_BEGIN
	offset_left = 12.0
	offset_right = -12.0
	offset_top = -104.0
	offset_bottom = -12.0
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.09, 0.12, 0.94)
	style.set_corner_radius_all(8)
	style.content_margin_left = 12.0
	style.content_margin_right = 12.0
	style.content_margin_top = 8.0
	style.content_margin_bottom = 8.0
	add_theme_stylebox_override("panel", style)
	_build()
	set_process(true)


func _build() -> void:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	add_child(col)

	# --- the track -----------------------------------------------------------
	_slider = HSlider.new()
	_slider.min_value = 0
	_slider.max_value = 1
	_slider.step = 1
	_slider.focus_mode = Control.FOCUS_NONE
	_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_slider.custom_minimum_size = Vector2(0, 22)
	_slider.value_changed.connect(_on_scrub)
	# The track's look is PINNED rather than inherited (F-044). Two reasons: the
	# buffer band below is drawn against these exact colours and at this exact
	# height, and the default theme's `grabber_area` paints its own fill from the
	# left edge up to the grabber -- which on a track that now carries a real
	# buffered range would read as a second, competing progress bar on the same
	# strip. The playhead is the grabber knob and nothing else.
	var track := StyleBoxFlat.new()
	track.bg_color = TRACK_EMPTY_COLOR
	track.set_corner_radius_all(int(FILL_BAND_HEIGHT * 0.5))
	track.content_margin_top = FILL_BAND_HEIGHT * 0.5
	track.content_margin_bottom = FILL_BAND_HEIGHT * 0.5
	_slider.add_theme_stylebox_override("slider", track)
	_slider.add_theme_stylebox_override("grabber_area", StyleBoxEmpty.new())
	_slider.add_theme_stylebox_override("grabber_area_highlight", StyleBoxEmpty.new())
	col.add_child(_slider)

	# F-044's buffer band, drawn over the track. A `draw` signal on a plain
	# Control rather than a script of its own, and it repaints only when the
	# cached ranges actually change -- `_draw_fill` allocates nothing.
	#
	# Added BEFORE the divergence mark on purpose: children paint in order, so
	# the red tick lands on top of the band and stays visible through it.
	_fill = Control.new()
	_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fill.set_anchors_preset(Control.PRESET_FULL_RECT)
	_fill.draw.connect(_draw_fill)
	_slider.add_child(_fill)
	_slider.resized.connect(_fill.queue_redraw)

	# The divergence mark. A ColorRect laid over the track rather than a
	# `_draw` override: the position is the only thing that changes and the
	# slider does not have to be repainted to move it.
	_diverge_tick = ColorRect.new()
	_diverge_tick.color = Color(0.87, 0.30, 0.30, 0.95)
	_diverge_tick.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_diverge_tick.visible = false
	_diverge_tick.size = Vector2(2, 22)
	_slider.add_child(_diverge_tick)

	# --- the transport -------------------------------------------------------
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	col.add_child(row)

	row.add_child(_button("|<", "First frame", func() -> void: _user_seek(0)))
	row.add_child(_button("<", "Step back one frame", func() -> void: _user_step(-1)))
	_rev_btn = _button("Rev", "Play backward", func() -> void: _user_direction(-1))
	row.add_child(_rev_btn)
	_pause_btn = _button("Pause", "Pause", func() -> void: _user_direction(0))
	row.add_child(_pause_btn)
	_play_btn = _button("Play", "Play forward", func() -> void: _user_direction(1))
	row.add_child(_play_btn)
	row.add_child(_button(">", "Step forward one frame", func() -> void: _user_step(1)))
	row.add_child(_button(">|", "Last frame", func() -> void: _user_seek(_frame_count)))

	_speed_option = OptionButton.new()
	_speed_option.focus_mode = Control.FOCUS_NONE
	for label in SPEED_NAMES:
		_speed_option.add_item(label)
	_speed_option.select(DEFAULT_SPEED_INDEX)
	_speed_option.item_selected.connect(func(i: int) -> void: _speed = float(SPEEDS[i]))
	row.add_child(_speed_option)

	_counter = Label.new()
	_counter.custom_minimum_size = Vector2(120, 0)
	_counter.text = "0 / 0"
	row.add_child(_counter)

	# F-044's readout. The percentage already existed, buried in the 12 px status
	# strip at the far end of the row where it was reported as missable; this is
	# the same number at the transport, at 20 px, in the accent colour.
	#
	# It OVERLAYS NOTHING and SHIFTS NOTHING. Its slot in the row is reserved at
	# full width whether or not there is text in it, so appearing and vanishing
	# never reflows the transport or nudges the frame counter beside it, and it
	# ignores the mouse so it cannot get between a click and anything under it.
	# F-048's spinner shares that reserved slot rather than adding to it: the
	# HBox is the 150 x 26 the label used to be, and the label gives up exactly
	# the spinner's width plus the separation. So the transport still does not
	# reflow when the pass starts or finishes -- which was F-044's whole point
	# about this readout -- and the busy motion sits where the number is.
	var index_row := HBoxContainer.new()
	index_row.name = "IndexSlot"
	index_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	index_row.custom_minimum_size = Vector2(150, 26)
	index_row.add_theme_constant_override("separation", 6)
	_index_spinner = ShellSpinner.make(20.0, INDEX_ACCENT_COLOR)
	index_row.add_child(_index_spinner)
	_index_label = Label.new()
	_index_label.name = "IndexReadout"
	_index_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_index_label.add_theme_font_size_override("font_size", 20)
	_index_label.add_theme_color_override("font_color", INDEX_ACCENT_COLOR)
	_index_label.custom_minimum_size = Vector2(124, 26)
	_index_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_index_label.text = ""
	index_row.add_child(_index_label)
	row.add_child(index_row)

	_readout = Label.new()
	_readout.add_theme_color_override("font_color", Color(1, 1, 1, 0.55))
	_readout.add_theme_font_size_override("font_size", 12)
	_readout.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_readout.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	row.add_child(_readout)

	var close_btn := _button("Close", "Back to the live sample",
		func() -> void: closed.emit())
	row.add_child(close_btn)


func _button(p_text: String, tip: String, action: Callable) -> Button:
	var b := Button.new()
	b.text = p_text
	b.tooltip_text = tip
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(action)
	return b


## SPACE toggles play/pause, and ONLY while this bar exists -- the shell creates
## it on entering a replay and frees it on leaving, so the key is bound for
## exactly as long as there is a transport to drive. Nothing else in the shell
## claims Space: main.gd's `_unhandled_input` takes TAB alone (main.gd:673-675)
## and `fly_camera.gd:256` handles touch events only. The one other user is the
## Character sample's jump, which POLLS (`Input.is_key_pressed(KEY_SPACE)`,
## samples/character.gd:166) -- polling does not see the event queue, so marking
## the event handled here neither reaches it nor takes anything away from it.
##
## `_unhandled_key_input` rather than `_input`: it runs after the GUI, so a
## focused SpinBox in the sidebar still gets its space bar. Nothing in this bar
## competes for it -- every control it builds is FOCUS_NONE, buttons and slider
## alike, which is the shell's own convention.
func _unhandled_key_input(event: InputEvent) -> void:
	if _player == null:
		return
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	if (event as InputEventKey).keycode != KEY_SPACE:
		return
	get_viewport().set_input_as_handled()
	if _direction != 0:
		_user_direction(0)
		return
	# Paused. Playing forward from the last frame would advance nowhere and read
	# as a dead key, so the end of the recording rewinds first -- the same thing
	# every transport does.
	if _display_frame >= _frame_count:
		_user_seek(0)
	_user_direction(1)


# --- opening and closing ------------------------------------------------------

## F-050. Whether this build can put cache overflow on a real disk. Feature tag,
## never a property: the browser's `user://` is the wasm heap wearing a
## filesystem, and spilling into it would move the bytes the budget exists to
## bound from one part of that heap to another.
func _can_spill() -> bool:
	if OS.has_feature("web"):
		return false
	return _renderer != null and is_instance_valid(_renderer) \
		and _renderer.has_method("set_frame_cache_spill_path")


## The renderer deletes its own temp file on close and on free, so this is for
## the case it never got to run: a crash, or a kill. Everything in the spill
## directory at open belongs to a session that is over -- ours does not exist
## yet -- so the directory is swept rather than aged.
func _sweep_spill_dir() -> void:
	if not DirAccess.dir_exists_absolute(SPILL_DIR):
		return
	for f in DirAccess.get_files_at(SPILL_DIR):
		if f.ends_with(".b3fc"):
			DirAccess.remove_absolute("%s/%s" % [SPILL_DIR, f])


## Open `path` and start drawing it under `host`. Returns false if the file will
## not open, in which case nothing was attached and the caller should tear the
## bar down.
func open_recording(path: String, host: Node3D) -> bool:
	close_recording()
	var player := Box3DReplayPlayer.new()
	# One worker, always, and not as a shortcut: the player is driven and drawn
	# from the main thread, and the single-threaded web build has no pthreads to
	# give it. The cross-thread determinism check that a higher count would buy
	# belongs in the selftests, where threads are guaranteed.
	if not player.open_file(path, 1):
		return false
	# Policy BEFORE anything else: setting it clears the ring and restarts the
	# player, which upstream requires, so doing it later would throw away
	# whatever had been indexed.
	var budget := KEYFRAME_BUDGET_WEB if OS.has_feature("web") else KEYFRAME_BUDGET_DESKTOP
	player.set_keyframe_policy(budget, KEYFRAME_MIN_INTERVAL)

	_player = player
	_path = path
	var info: Dictionary = player.get_info()
	_frame_count = int(info.get("frameCount", 0))
	_time_step = float(info.get("timeStep", 1.0 / 60.0))
	if _time_step <= 0.0:
		_time_step = 1.0 / 60.0
	_sub_steps = int(info.get("subStepCount", 4))

	_host = host
	_renderer = Box3DReplayRenderer.new()
	_renderer.name = "ReplayRenderer"
	# Driven by hand: the bar knows exactly when the frame changed, and a
	# per-frame redraw of a paused recording is pure waste.
	_renderer.auto_update = false
	if host != null:
		host.add_child(_renderer)
	# Attaching installs the debug-shape callbacks, which rebuilds the replay
	# world and rewinds to frame 0 -- upstream's contract (box3d.h:408-410), not
	# a side effect to work around.
	_renderer.player = _player
	_renderer.frame_cache_budget = FRAME_CACHE_WEB if OS.has_feature("web") else FRAME_CACHE_DESKTOP
	# F-050. The memory budget above stops being a coverage limit the moment
	# there is somewhere for the overflow to go. Set BEFORE the first frame is
	# cached, for the same reason the colour table is.
	if _can_spill():
		_sweep_spill_dir()
		_renderer.frame_cache_disk_budget = SPILL_DISK_BUDGET
		_renderer.frame_cache_spill_path = "%s/replay_%d.b3fc" % [SPILL_DIR, OS.get_process_id()]
	# F-042: the recording carries the solver's STATE palette and no art, so
	# every dynamic body in it is the same colour. If the session that produced
	# this file left a sidecar beside it, the live scene's own per-body colours
	# are in there, keyed by body id. No sidecar -> an empty table -> exactly the
	# pre-F-042 look, which is also what an upstream-made recording gets.
	# Set BEFORE the first draw: the table is baked into the frames the renderer
	# caches, so setting it later would throw them away.
	_color_overrides = ShellRecorder.load_colors(path)
	_renderer.body_color_overrides = _color_overrides
	# F-045: the PBR half of the sidecar. Feature-detected rather than assumed,
	# because the renderer's override API takes a Color today and the material
	# table is captured ahead of it; the day it grows `body_material_overrides`
	# this line starts feeding it with no change here. Set before the first draw
	# for the same reason the colours are.
	_material_overrides = ShellRecorder.load_materials(path)
	if not _material_overrides.is_empty() \
			and _renderer.has_method("set_body_material_overrides"):
		_renderer.set("body_material_overrides", _material_overrides)
	# F-038: inherit the host's debug state rather than imposing one. Set before
	# the first draw so the bar never flashes the wrong look.
	_renderer.debug_style = _debug_style
	# Frame 0 is BEFORE the recording's first dispatch, so the replay world is
	# empty there and the bar would open on a blank viewport. One step lands on
	# the first real state, which is what a viewer means by "the start".
	if _frame_count > 0:
		_player.step_frame()
	_display_frame = _player.get_frame()

	# Guarded: shrinking the range clamps the current value, and a clamp emits
	# value_changed, which would arrive as a user scrub of a recording that has
	# only just opened.
	_syncing = true
	_slider.max_value = maxi(1, _frame_count)
	_slider.set_value_no_signal(_display_frame)
	_syncing = false
	_direction = 0
	_speed = SPEEDS[DEFAULT_SPEED_INDEX]
	_speed_option.select(DEFAULT_SPEED_INDEX)
	_accum = 0.0
	_diverge_frame = -1
	_pass_complete = false
	_pass_broken = false
	_pass_wrapped = false
	_idle_frames = PREGEN_IDLE_FRAMES
	_pregen = auto_pregen and _frame_count > 0
	_shown_frame = _display_frame
	_want_frame = -1
	_want_from = _display_frame
	_want_stall = 0
	# F-044: a reopen gets a fresh renderer and therefore a fresh cache, so the
	# band's signature is invalidated by hand rather than left to coincide.
	_fill_sig = Vector4i(-2, -2, -2, -2)
	_fill_runs.clear()
	_resident_runs.clear()
	_renderer.capture_frame(_display_frame)
	_refresh_ui()
	return true


## Drop the player and the renderer. Safe to call twice; called by the shell
## before the bar is freed, so nothing is left holding a replay world.
func close_recording() -> void:
	_direction = 0
	_pregen = false
	if _renderer != null and is_instance_valid(_renderer):
		# Detach first: the renderer owns the shape handles it was given and
		# frees them on detach, and destroying the replay world would NOT run
		# the destroy callback for shapes still alive (upstream calls it only
		# from b3DestroyShape, src/shape.c:1025, and from snapshot restore).
		_renderer.player = null
		if _renderer.get_parent() != null:
			_renderer.get_parent().remove_child(_renderer)
		_renderer.free()
	_renderer = null
	if _player != null:
		_player.close()
	_player = null
	_host = null
	_frame_count = 0
	_display_frame = 0
	_last_was_cached = false
	_color_overrides = {}
	_material_overrides = {}
	_shown_frame = 0
	_want_frame = -1
	# F-044: nothing is buffered once there is nothing open, and the big readout
	# must not be left announcing a pass that no longer exists.
	_fill_sig = Vector4i(-2, -2, -2, -2)
	_fill_runs.clear()
	_resident_runs.clear()
	if _fill != null:
		_fill.queue_redraw()
	if _index_label != null:
		_index_label.text = ""
	if _index_spinner != null:
		_index_spinner.visible = false


func _exit_tree() -> void:
	close_recording()


# --- transport ---------------------------------------------------------------

func is_open() -> bool:
	return _player != null and _player.is_open()


func get_player() -> Box3DReplayPlayer:
	return _player


func get_renderer() -> Box3DReplayRenderer:
	return _renderer


func get_frame() -> int:
	return _display_frame if _player != null else 0


## Frames of the recording currently held as ready-to-draw transforms, and the
## bytes they occupy. F-R4's other measurable: a backward step that lands inside
## this range never touches the solver.
func get_cached_frame_count() -> int:
	return _renderer.get_cached_frame_count() if _renderer != null else 0


func get_frame_cache_bytes() -> int:
	return _renderer.get_frame_cache_bytes() if _renderer != null else 0


## True when the last displayed frame came out of the cache rather than the
## player. The selftests assert on this; nothing in the UI reads it.
func was_last_frame_cached() -> bool:
	return _last_was_cached


func get_frame_count() -> int:
	return _frame_count


func get_direction() -> int:
	return _direction


## What one displayed frame cost last time, in microseconds: the transport's
## advance AND the draw that put it on screen, because that whole thing is what
## has to fit in a 60 Hz frame. F-R4's measurement.
func get_last_advance_usec() -> int:
	return _last_advance_usec


func get_average_advance_usec() -> float:
	return _avg_advance_usec


## True once the amortized index pass has walked the whole recording. Until then
## the keyframe ring only covers what has been played.
func is_indexed() -> bool:
	return _pass_complete


## F-044. True while the amortized pass is actually running -- not merely
## pending. Interaction stands the pass down for PREGEN_IDLE_FRAMES and playing
## holds it down for as long as the transport is moving, and in both cases the
## big readout goes away rather than sitting there frozen on a stale number.
## Exactly the condition the small status strip has always used for its own
## "indexing" fragment, so the two can never disagree.
func is_indexing() -> bool:
	return _player != null and _pregen and _idle_frames >= PREGEN_IDLE_FRAMES


## F-044. How much of the recording is indexed, 0..1, sourced from THE CACHE --
## `get_cached_frame_count()` over the frame count -- and not from the pass's
## own player position. That is deliberate: the cache is what the band paints
## and what makes a backward seek free, so the number under the bar and the fill
## on the track are the same fact. It also survives the pass's one trip back to
## frame 0 (`_run_pregen_slice`), which resets the player and would have sent a
## player-derived percentage back to zero in front of the user.
func get_index_progress() -> float:
	if _player == null or _frame_count <= 0:
		return 0.0
	if _pass_complete:
		return 1.0
	return clampf(float(get_cached_frame_count()) / float(maxi(1, _frame_count)), 0.0, 1.0)


## The same as a whole percent. Held at 99 until the pass actually finishes: a
## cache that has rounded up to 100% while the walk is still going would claim a
## completion the bar has not earned.
func get_index_percent() -> int:
	var pct := int(get_index_progress() * 100.0)
	if pct >= 100 and not _pass_complete:
		return 99
	return pct


## F-050. The frame the transport is waiting to be simulated, or -1. While this
## is set, `get_frame()` is where the user put the playhead and
## `get_shown_frame()` is what the viewport is actually showing.
func get_wait_frame() -> int:
	return _want_frame


## What the viewport is showing. Equal to `get_frame()` except during a wait.
func get_shown_frame() -> int:
	return _shown_frame


## How far a wait has come, 0..100, measured over the frames it has to simulate
## rather than over the recording -- the user asked for one frame and this is
## the answer to "how much longer", not to "how indexed is the file".
func get_wait_percent() -> int:
	if _want_frame < 0:
		return 100
	var span := _want_frame - _want_from
	if span <= 0:
		return 99
	var done := _shown_frame - _want_from
	return clampi(int(float(done) / float(span) * 100.0), 0, 99)


## F-050. The highest frame F for which every frame up to F is cached, or 0.
## While this tracks the pass, a seek at or below it is an upload and a seek
## above it is a wait -- which is exactly the promise the buffer band makes.
func get_indexed_through() -> int:
	if _renderer == null or not is_instance_valid(_renderer) \
			or not _renderer.has_method("get_indexed_through"):
		return 0
	return _renderer.get_indexed_through()


## F-050. Bytes of cache overflow living in the temp file, 0 when the spill is
## off (the browser build) or has never been needed.
func get_frame_cache_disk_bytes() -> int:
	if _renderer == null or not is_instance_valid(_renderer) \
			or not _renderer.has_method("get_frame_cache_disk_bytes"):
		return 0
	return _renderer.get_frame_cache_disk_bytes()


## F-044. The ranges the buffer band paints, as inclusive `[first, last]` frame
## pairs. Usually one -- the cached window is contiguous, and with F-050's spill
## file behind it the whole indexed prefix is one run -- but a scrub that jumped
## leaves the frames it landed on stranded, and those are drawn as SEPARATE
## bands. The band never joins two islands into one filled stretch it does not
## have. Since F-050 this counts frames on DISK as well as in memory, because
## both draw without touching the player; `get_resident_runs()` is the memory
## subset the band paints brighter.
func get_cached_runs() -> Array[Vector2i]:
	_update_fill()
	return _fill_runs.duplicate()


## F-050. The subset of `get_cached_runs()` still held in memory.
func get_resident_runs() -> Array[Vector2i]:
	_update_fill()
	return _resident_runs.duplicate()


## The frame the embedded state hashes first failed to reproduce, or -1. Kept
## separately from the player's own flag because `restart()` clears that.
func get_diverge_frame() -> int:
	return _diverge_frame


## F-038. A replay is not automatically a debug view: the renderer's default
## look is an ordinary lit surface, and the flat state-palette treatment that
## matches Box3DWorld's debug shells is what this turns on. The shell drives it
## straight off its own Debug switch, so a timeline inherits exactly what was on
## screen and follows the switch while it is open. This bar never writes back to
## that switch, which is why the checkbox cannot desync from what is drawn.
func set_debug_style(on: bool) -> void:
	_debug_style = on
	if _renderer != null and is_instance_valid(_renderer):
		_renderer.debug_style = on


func is_debug_style() -> bool:
	return _debug_style


## F-042. How many per-body colours the recording's sidecar supplied, and how
## many drawn instances the last displayed frame actually took from them. Zero
## and zero is the supported fallback, not a failure: it is what a recording
## with no sidecar looks like. Nothing in the UI reads these; the selftests do.
func get_color_override_count() -> int:
	return _color_overrides.size()


## F-045. How many per-body PBR responses the sidecar supplied -- zero for a v1
## sidecar, and zero for a v2 one whose scene used default materials throughout,
## since only the differing ones are stored. Selftests only.
func get_material_override_count() -> int:
	return _material_overrides.size()


func get_material_override(p_body_key: String) -> Dictionary:
	return _material_overrides.get(p_body_key, {}) as Dictionary


func get_drawn_override_count() -> int:
	if _renderer == null or not is_instance_valid(_renderer):
		return 0
	return _renderer.get_override_instance_count()


func set_direction(dir: int) -> void:
	_direction = signi(dir)
	_accum = 0.0
	_refresh_ui()


## Seek and redraw. Clamped by the player itself in both directions.
func seek_to(frame: int) -> void:
	if _player == null:
		return
	var t := Time.get_ticks_usec()
	_show(clampi(frame, 0, _frame_count))
	_note_cost(Time.get_ticks_usec() - t)
	_refresh_ui()


## Advance `n` recorded frames in either direction.
func step_by(n: int) -> void:
	if _player == null or n == 0:
		return
	var t := Time.get_ticks_usec()
	for i in range(absi(n)):
		if not _advance(signi(n)):
			break
	_note_cost(Time.get_ticks_usec() - t)
	_refresh_ui()


## Put `frame` on screen. THE WHOLE OF F-R4 IS THE FIRST BRANCH: a frame the
## renderer still remembers is a MultiMesh upload, and the player -- the
## keyframe restore, the re-stepped gap, the rebuilt replay world and the 4097
## debug-shape handles that come with it -- is not touched at all.
func _show(frame: int) -> bool:
	if _renderer != null and is_instance_valid(_renderer) and _renderer.draw_cached_frame(frame):
		_display_frame = frame
		_shown_frame = frame
		_want_frame = -1
		_last_was_cached = true
		return true
	_last_was_cached = false
	# F-050. The frame is not indexed. If the coverage is a PREFIX -- every
	# frame from the first up to a frontier, which is what the spill file makes
	# it -- then the frame is ahead of the player and the only thing that can
	# produce it is the index pass walking forward. So the playhead goes where
	# the user put it, the picture stays on the newest frame there is, and the
	# pass is told to hurry. Nothing blocks: a seek that used to cost six
	# seconds of solver inside one call is now the same work spread over frames
	# the user can still click through, with the band and a readout showing it
	# arrive.
	if _chase_ready(frame):
		if _want_frame != frame:
			_want_from = _shown_frame
		_want_frame = frame
		_display_frame = frame
		_idle_frames = PREGEN_IDLE_FRAMES
		_pregen = true
		_park_on_frontier()
		return false
	# No prefix to chase along: the spill is off (the browser), full, or broken,
	# so the cache is a window again and this is the pre-F-050 path -- a
	# keyframe restore and a re-step of the gap, inside one call.
	_player.seek_frame(frame)
	_pass_broken = true
	_display_frame = _player.get_frame()
	_shown_frame = _display_frame
	_want_frame = -1
	_draw_frame()
	return false


## Can `frame` be reached by walking the index pass FORWARD? Only if everything
## below the frontier is already cached (so nothing has to be re-produced behind
## us) and the frame really is above it.
func _chase_ready(frame: int) -> bool:
	# `auto_pregen` is the one switch for "this bar may drive the player on its
	# own". A harness that has turned it off is stepping the transport by hand
	# and expects `seek_to` to have arrived by the time it returns, so it gets
	# the blocking seek rather than a wait it would have to pump.
	if not auto_pregen:
		return false
	if _renderer == null or not is_instance_valid(_renderer):
		return false
	if not _renderer.has_method("get_indexed_through"):
		return false
	# Only where the overflow has somewhere to go. Without a spill file the
	# pass's own frames are evicted as fast as it stores them, so a wait would
	# be a wait for something that never arrives.
	if String(_renderer.frame_cache_spill_path).is_empty():
		return false
	var through: int = _renderer.get_indexed_through()
	if through <= 0:
		return false
	return frame > through and frame >= _player.get_frame()


## Put the newest indexed frame on screen while a wait runs. Cheap -- it is the
## ordinary cached-frame upload -- and it is what makes the wait legible: the
## viewport fast-forwards toward the mark instead of freezing on a stale image.
func _park_on_frontier() -> void:
	var through: int = _renderer.get_indexed_through()
	if through <= 0 or through == _shown_frame:
		return
	if _renderer.draw_cached_frame(through):
		_shown_frame = through


## One frame in `dir`. Returns false at either end of the recording.
func _advance(dir: int) -> bool:
	var want := _display_frame + dir
	if want < 0 or want > _frame_count:
		return false
	if _renderer != null and is_instance_valid(_renderer) and _renderer.draw_cached_frame(want):
		_display_frame = want
		_shown_frame = want
		_want_frame = -1
		_last_was_cached = true
		return true
	_last_was_cached = false
	# Forward at the frontier: the player is already standing on `_display_frame`
	# and one step IS the frame being asked for. That is the producer, inline,
	# and it costs one solver step -- 11 to 52 ms on the biggest scene here.
	if dir > 0 and _player.get_frame() == _display_frame and not _player.is_at_end():
		if not _player.step_frame():
			return false
		_display_frame = _player.get_frame()
		_shown_frame = _display_frame
		_want_frame = -1
		_draw_frame()
		return true
	# Backward off the cache, with no prefix to chase along: the pre-F-050 block
	# rebuild. With a spill file this is unreachable -- everything below the
	# frontier is cached, so a backward step is an upload -- and it stays for the
	# browser build, which has no disk to put a window's overflow on.
	if dir < 0 and not _chase_ready(want):
		_backfill(want)
		return true
	# Anywhere else off the cache: hand it to `_show`, which either chases along
	# the prefix without blocking or falls back to the pre-F-050 seek.
	_show(want)
	return true


## A backward cache miss. Rebuild a BLOCK ending at `target` rather than the one
## frame, so the restore and the re-stepped gap are paid once for the next
## BACKFILL_SPAN backward frames instead of once each. The intermediate frames
## are stored without being uploaded; only the one being displayed is drawn.
func _backfill(target: int) -> void:
	var base := maxi(0, target - BACKFILL_SPAN + 1)
	_player.seek_frame(base)
	_pass_broken = true
	if _renderer != null and is_instance_valid(_renderer):
		_renderer.prefetch_frame(_player.get_frame())
		while _player.get_frame() < target and _player.step_frame():
			_renderer.prefetch_frame(_player.get_frame())
	else:
		while _player.get_frame() < target and _player.step_frame():
			pass
	_display_frame = _player.get_frame()
	_shown_frame = _display_frame
	_want_frame = -1
	if _renderer == null or not is_instance_valid(_renderer) \
			or not _renderer.draw_cached_frame(_display_frame):
		_draw_frame()


func _note_cost(usec: int) -> void:
	_last_advance_usec = usec
	# A plain exponential average: the number is for a human reading a bar, and
	# a ring buffer would be more machinery than the readout is worth.
	_avg_advance_usec = _avg_advance_usec * 0.9 + float(usec) * 0.1


# --- user intent (everything here cancels the index pass) ---------------------

func _user_seek(frame: int) -> void:
	_suspend_pregen()
	_direction = 0
	seek_to(frame)


func _user_step(n: int) -> void:
	_suspend_pregen()
	_cancel_wait()
	_direction = 0
	step_by(n)


func _user_direction(dir: int) -> void:
	_suspend_pregen()
	_cancel_wait()
	set_direction(dir)


## F-050. Step and play mean "from HERE", and while a wait is outstanding here
## is the frame on screen rather than the mark the playhead is parked on. So an
## explicit transport action lands the playhead on what the user is looking at
## and drops the wait, instead of queueing behind it and appearing to do
## nothing. A new SEEK does not come through this: it retargets the wait, which
## is what asking for a different frame means.
func _cancel_wait() -> void:
	if _want_frame < 0:
		return
	_want_frame = -1
	_want_stall = 0
	_display_frame = _shown_frame
	_refresh_ui()


func _on_scrub(value: float) -> void:
	if _syncing or _player == null:
		return
	# A drag arrives as a stream of value_changed, so this IS the live seek in
	# both directions; there is no drag-end to wait for.
	_suspend_pregen()
	_direction = 0
	seek_to(int(value))


## Interaction no longer CANCELS the pass -- with the cache behind it the pass
## is worth finishing, and it no longer moves the view, so finishing it costs
## the user nothing. It just stands down until the bar has been quiet for
## PREGEN_IDLE_FRAMES.
func _suspend_pregen() -> void:
	_idle_frames = 0


# --- the frame loop -----------------------------------------------------------

func _process(delta: float) -> void:
	if _player == null:
		return
	# F-050. A wait outranks everything: the user has asked for a frame that has
	# never been simulated, so the pass gets this frame whether the transport is
	# paused or not, and the picture follows the frontier until the mark
	# arrives. One slice is one solver step at this scale, so the bar keeps
	# taking input the whole way -- which is the difference between this and the
	# six-second freeze it replaces.
	if _want_frame >= 0:
		var before := get_indexed_through()
		_run_pregen_slice()
		if _renderer != null and is_instance_valid(_renderer) \
				and _renderer.has_cached_frame(_want_frame):
			var t := Time.get_ticks_usec()
			_show(_want_frame)
			_note_cost(Time.get_ticks_usec() - t)
		elif get_indexed_through() <= before:
			# The frontier did not move. A pass that is standing still is a wait
			# that will never end -- the recording ran out, or the spill did --
			# so after WAIT_STALL_FRAMES of it the bar stops promising and takes
			# the old blocking seek instead. Bounded, and it says which it did.
			_want_stall += 1
			if _want_stall >= WAIT_STALL_FRAMES:
				var target := _want_frame
				_want_frame = -1
				_player.seek_frame(target)
				_pass_broken = true
				_display_frame = _player.get_frame()
				_shown_frame = _display_frame
				_draw_frame()
		else:
			_want_stall = 0
			_park_on_frontier()
		_refresh_ui()
		_update_fill()
		_place_diverge_tick()
		return
	if _direction != 0:
		_idle_frames = 0
		_accum += delta * _speed
		var advanced := false
		# Bounded: a frame that took a long time must not turn into a hundred
		# replay frames and a stall.
		var budget := 8
		while _accum >= _time_step and budget > 0:
			_accum -= _time_step
			budget -= 1
			var t := Time.get_ticks_usec()
			var ok := _advance(_direction)
			_note_cost(Time.get_ticks_usec() - t)
			if not ok:
				_direction = 0
				break
			advanced = true
		if advanced:
			_refresh_ui()
	elif _pregen:
		# Paused: the pass gets the frame. It never touches the view, so the
		# user is looking at a still image while the recording indexes itself.
		_idle_frames += 1
		if _idle_frames >= PREGEN_IDLE_FRAMES:
			_run_pregen_slice()
	# F-044: the band polls here, beside the tick, because the renderer
	# publishes no "the cache moved" signal and this is the cadence the bar
	# already runs at. Three getters and a comparison unless something in the
	# cache actually changed.
	_update_fill()
	_place_diverge_tick()


## One slice of the amortized index-and-prefetch pass: step forward in
## wall-clock bites, storing every frame it passes so reverse playback over that
## range is free, until the recording ends. The recording is playable
## throughout, the view never moves, and interaction stands the pass down rather
## than killing it. This is the whole of what upstream's modal progress bar did,
## minus the modal.
func _run_pregen_slice() -> void:
	var started := Time.get_ticks_usec()
	while not _player.is_at_end():
		if not _player.step_frame():
			break
		if _renderer != null and is_instance_valid(_renderer) \
				and not _renderer.prefetch_frame(_player.get_frame()):
			# The frame the pass just stored was evicted on the spot: the window
			# is full in the direction it is walking, and more stepping would
			# only throw away frames nearer the playhead.
			#
			# F-050 is what this line is now the FALLBACK for. With a spill file
			# an evicted chunk is written out rather than thrown away, so the
			# store still succeeds and the pass walks the whole recording; this
			# only fires where there is nowhere to spill to -- the browser build,
			# a full disk budget, a failed write -- which is exactly where the
			# sliding window is still the truth.
			_pregen = false
			break
		if float(Time.get_ticks_usec() - started) / 1000.0 >= PREGEN_SLICE_MS:
			break
	if _player.has_diverged() and _diverge_frame < 0:
		_diverge_frame = _player.get_diverge_frame()
	if _player.is_at_end():
		# A pass that started above frame 0, or that a seek jumped over the
		# middle of, has holes. It gets one trip back from the top to fill them;
		# if the budget cannot hold the whole recording the walk hits an
		# eviction and stops itself.
		if not _pass_wrapped and _renderer != null and is_instance_valid(_renderer) \
				and _renderer.get_cached_frame_count() < _frame_count:
			_pass_wrapped = true
			# `restart()` starts a fresh contiguous walk from frame 0 and clears
			# the player's divergence flag with it, so the wrap does not spoil
			# the verdict -- it is the one reposition that EARNS one.
			_player.restart()
			_pass_broken = false
		else:
			_pregen = false
			# The hash check only means something along a contiguous walk; a
			# seek in the middle of one makes the verdict unearned.
			_pass_complete = not _pass_broken
			# `restart()` returns to frame 0 in place and KEEPS the ring, which
			# is the whole point of the pass. It also clears the divergence
			# flag, which is why the verdict was copied out above.
			_player.restart()
	_refresh_ui()


## Draw the player's current state AND remember it, so the next visit to this
## frame -- which for a reverse pass is one frame away -- is an upload.
func _draw_frame() -> void:
	if _renderer != null and is_instance_valid(_renderer):
		_renderer.capture_frame(_display_frame)


func _refresh_ui() -> void:
	if _player == null or _counter == null:
		return
	var frame := _display_frame
	_syncing = true
	_slider.set_value_no_signal(frame)
	_syncing = false
	_counter.text = "%d / %d" % [frame, _frame_count]
	_play_btn.disabled = _direction == 1
	_rev_btn.disabled = _direction == -1
	_pause_btn.disabled = _direction == 0
	if _index_label != null:
		# The spinner and the number read the SAME predicate, so the bar can
		# never be turning while it claims to be idle, or vice versa. F-050 adds
		# one state ahead of it: while a frame is being WAITED for, the readout
		# is about that frame and not about the recording, because that is the
		# question the user just asked.
		var indexing := is_indexing()
		if _want_frame >= 0:
			_index_label.text = "Frame %d  %d%%" % [_want_frame, get_wait_percent()]
		else:
			_index_label.text = ("Indexing %d%%" % get_index_percent()) if indexing else ""
		if _index_spinner != null:
			_index_spinner.visible = indexing or _want_frame >= 0
	_readout.text = _status_text()
	_update_fill()
	_place_diverge_tick()


func _status_text() -> String:
	var hz := 0.0 if _time_step <= 0.0 else 1.0 / _time_step
	var parts: Array[String] = []
	parts.append("%.0f Hz, %d sub-steps" % [hz, _sub_steps])
	parts.append("keyframes every %d frames, %.1f MB"
		% [_player.get_keyframe_interval(),
			float(_player.get_keyframe_bytes()) / (1024.0 * 1024.0)])
	if _renderer != null and is_instance_valid(_renderer):
		# F-050: the two tiers are named rather than summed. "Cached" is what
		# draws without the player; the memory figure is the working set inside
		# it, and the disk figure is where the rest of it went.
		var cached := "%d frames cached, %.1f MB in memory" \
			% [_renderer.get_cached_frame_count(),
				float(_renderer.get_frame_cache_bytes()) / (1024.0 * 1024.0)]
		if _renderer.has_method("get_frame_cache_disk_bytes"):
			var disk: int = _renderer.get_frame_cache_disk_bytes()
			if disk > 0:
				cached += " + %.1f MB on disk" % (float(disk) / (1024.0 * 1024.0))
		parts.append(cached)
	parts.append("frame %.2f ms" % (float(_last_advance_usec) / 1000.0))
	# The one thing the bar must never leave the user to guess at: it is showing
	# a frame other than the one the playhead is on, and why.
	if _want_frame >= 0:
		parts.append("simulating to frame %d, showing %d" % [_want_frame, _shown_frame])
	# F-044: the small fragment and the big readout are the SAME number from
	# the same source now, so the strip can never contradict the thing the
	# user is actually looking at.
	if is_indexing():
		parts.append("indexing %d%%" % get_index_percent())
	# Wording is careful on purpose: a clean pass means the recorded state
	# hashes reproduced, which covers body transforms and velocities only. It is
	# not a claim of bit-exactness, and on the browser build nothing about
	# determinism is verified at all.
	if _diverge_frame >= 0:
		parts.append("state hash first differed at frame %d" % _diverge_frame)
	elif _pass_complete:
		parts.append("no hash mismatch over the whole recording")
	return "   ".join(parts)


## F-044. Work out what the buffer band should be showing, and repaint it only
## if that changed. Called at the bar's existing cadences -- every `_process`
## frame beside the divergence tick, and every `_refresh_ui` -- rather than from
## a timer of its own; the renderer publishes no "cache changed" signal, so the
## cheap signature below IS the poll.
##
## THE FAST PATH IS THE HONEST ONE. `evict_to_budget`
## (godot/src/box3d_replay_renderer.cpp) only ever drops the frame FURTHEST from
## the playhead, which is always one of the two ends of the window, so a cache
## whose frame count fills its own range has no holes in it and the band is
## exactly that range -- three getters, no probing. Holes only appear when
## something jumped (a scrub into cold territory caches the single frame it
## landed on), and only then does the probe walk below run.
func _update_fill() -> void:
	var count := 0
	var resident := 0
	var lo := -1
	var hi := -1
	if _renderer != null and is_instance_valid(_renderer):
		count = _renderer.get_cached_frame_count()
		resident = count
		if _renderer.has_method("get_resident_frame_count"):
			resident = _renderer.get_resident_frame_count()
		var window: Vector2i = _renderer.get_cached_frame_range()
		lo = window.x
		hi = window.y
	var sig := Vector4i(count, resident, lo, hi)
	if sig == _fill_sig:
		return
	_fill_sig = sig
	_fill_runs.clear()
	_resident_runs.clear()
	if count > 0 and lo >= 0 and hi >= lo:
		# F-050: the renderer answers this exactly now -- it holds the chunk
		# table, so it knows the runs without anyone guessing at them -- and the
		# probe walk below is the fallback for a build whose extension predates
		# the getter.
		if _renderer.has_method("get_cached_runs"):
			for r in _renderer.get_cached_runs():
				_fill_runs.append(r as Vector2i)
			for r in _renderer.get_resident_runs():
				_resident_runs.append(r as Vector2i)
		elif count == hi - lo + 1:
			_fill_runs.append(Vector2i(lo, hi))
		else:
			_probe_runs(lo, hi)
	if _fill != null:
		_fill.queue_redraw()


## The hole case. Walks the cached window looking for the gaps, at most
## FILL_PROBES times -- so on a recording longer than that the band is drawn at
## probe resolution rather than frame resolution. That is an approximation of
## WHERE a gap ends, never an invention of one: a stride only ever runs over
## holes narrower than itself, and a hole is a jump, which is wide.
func _probe_runs(lo: int, hi: int) -> void:
	var stride := maxi(1, ceili(float(hi - lo + 1) / float(FILL_PROBES)))
	var start := -1
	var last := -1
	var frame := lo
	while frame <= hi:
		if _renderer.has_cached_frame(frame):
			if start < 0:
				start = frame
			last = frame
		elif start >= 0:
			_fill_runs.append(Vector2i(start, last))
			start = -1
		frame += stride
	if start >= 0:
		_fill_runs.append(Vector2i(start, last))


## Paint the band. Allocation-free by construction -- the runs were computed in
## `_update_fill` and this only ever reads them -- because it rides the same
## redraw cadence as the rest of the bar and must not cost the cached-frame path
## anything.
func _draw_fill() -> void:
	if _fill == null or _frame_count <= 0 or _fill_runs.is_empty():
		return
	var w := _fill.size.x
	if w <= 0.0:
		return
	var span := float(_frame_count)
	var y := (_fill.size.y - FILL_BAND_HEIGHT) * 0.5
	for run in _fill_runs:
		var x0 := clampf(float(run.x) / span, 0.0, 1.0) * w
		var x1 := clampf(float(run.y) / span, 0.0, 1.0) * w
		_fill.draw_rect(Rect2(x0, y, maxf(2.0, x1 - x0), FILL_BAND_HEIGHT),
			TRACK_CACHED_COLOR)
	# F-050's second tier, painted over the first: the frames still in memory.
	# Same hue, more of it, so the band reads as one buffered range with a
	# brighter working set sliding inside it -- both are frames that draw
	# without the player, and the difference between them is 0.3 ms and 4 ms.
	for run in _resident_runs:
		var x0 := clampf(float(run.x) / span, 0.0, 1.0) * w
		var x1 := clampf(float(run.y) / span, 0.0, 1.0) * w
		_fill.draw_rect(Rect2(x0, y, maxf(2.0, x1 - x0), FILL_BAND_HEIGHT),
			TRACK_RESIDENT_COLOR)


## The divergence mark rides the track, so its position depends on the slider's
## width and has to be refreshed as the bar is laid out.
func _place_diverge_tick() -> void:
	if _diverge_tick == null:
		return
	var show := _diverge_frame >= 0 and _frame_count > 0
	_diverge_tick.visible = show
	if not show:
		return
	var t := clampf(float(_diverge_frame) / float(_frame_count), 0.0, 1.0)
	_diverge_tick.size = Vector2(2, maxf(12.0, _slider.size.y))
	_diverge_tick.position = Vector2(t * _slider.size.x - 1.0, 0.0)
	# The tooltip lives on the SLIDER: the mark ignores the mouse so it cannot
	# get between a drag and the track it is drawn on.
	_slider.tooltip_text = "The replayed state hash first differed at frame %d. Informational." % _diverge_frame
