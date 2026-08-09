class_name ShellRecorder
extends RefCounted

## The shell's record session: what the sidebar's Recording section drives, and
## the whole of the "save a recording of whatever I am looking at" story.
##
## WHY IT IS ITS OWN OBJECT rather than four more members on main.gd. The shell
## runs MANY worlds -- one per sample, rebuilt on every Reset, engine switch and
## worker-count reload -- and a recording binds to exactly one of them. Keeping
## the session, its start step and its save path in one object is what makes
## "the world under me just went away" a single question (`is_recording()` plus
## `is_instance_valid(world)`) instead of a set of flags that can disagree.
## It is also what makes the session testable headlessly, which is where the
## selftests drive it from.
##
## UPSTREAM SHAPE. This mirrors `Sample::StartRecording` / `FinishRecording`
## (`samples/sample.cpp:353-383`) and the two-button Recording panel in
## `samples/sample.cpp:2005-2033`: "Record (restart)" restarts the sample and
## captures a whole clean session from step 0, "Record Now" snapshots the
## running world and logs from there. Both are the SAME call underneath --
## `b3World_StartRecording` seeds the buffer from a snapshot of the live world
## (`src/recording.c:1017`), so capture can begin at any step boundary and the
## bodies already standing there are in the file either way. The restart button
## is not a different capture mode, it is a restart followed by this one.
##
## THE STEP BOUNDARY, which is a real constraint and not a style note.
## `b3World_StartRecording` refuses and asserts on a locked world
## (`src/physics_world.c:2300-2305` -> `:96-106`). With the shell's async-step
## toggle on, the step runs off the main thread and the world IS locked for part
## of every frame. Nothing here has to deal with that: the binding joins the
## step itself before both calls (`godot/src/box3d_world.cpp:1231` in
## `start_recording`, `:1249` in `stop_recording`), which is PARITY P-045's
## resolution. So this object never inspects `async_step`, and the F-key balls,
## bombs, ragdolls, blasts and the grab joint need no special casing either:
## they all mutate the recorded world through ordinary Box3D calls, and every
## world mutation is what the recording stream is made of.
##
## PATHS. Saving goes through `Box3DRecording.save_to_file`, i.e. Godot's
## `FileAccess`, so `user://` works identically in the editor, in an exported
## desktop game, on Android and in the browser. Upstream's own
## `b3SaveRecordingToFile` is plain `fopen` (`src/recording.c:1113-1177`) and is
## deliberately unbound.
##
## WHY STOPPING IS NOT ONE FUNCTION ANY MORE (F-048). "Stop and save" used to do
## everything the click implied on the frame of the click, and on Huge Pyramid
## that measured 113.8 SECONDS -- a freeze the user reported as unprofessional,
## and rightly. The breakdown, measured (300 recorded frames, 16,291 bodies,
## 38.3 MB of recording):
##
##     stop_recording / finalize        0.01 ms
##     get_data (38 MB copy out)       13.9  ms
##     FileAccess write                11.4  ms
##     THE CAPTURE WALK           113,575    ms   <- 99.97% of it
##     sidecar stringify               60.5  ms
##     sidecar write                    0.4  ms
##
## The capture walk was QUADRATIC, and in an unobvious place: `_shading_of` was
## re-derived per body, and it searches the DECLARING node's subtree -- which in
## Huge Pyramid is `Box3DMultiMeshRenderer` with all 16,290 boxes parented under
## it (`samples/huge_pyramid.gd:43-50`). One call costs 12.6 ms, and it was made
## 16,290 times. So three things changed, in order of how much they bought:
##
##  1. `_shading_of` is MEMOISED per declaring node (`_shading_cache`). 113.6 s
##     -> 45 ms. One node's material answer cannot differ between two of its own
##     bodies, so this is a cache of a constant, not an approximation.
##  2. The walk is INCREMENTAL. `poll_capture()` runs it a slice at a time while
##     the session records (the shell drives it from `_physics_process`), so by
##     the time Stop is clicked most bodies are already answered for and the
##     click only sweeps what is left. See `poll_capture` for the one semantic
##     this changes.
##  3. The WRITES go to a background `Thread` -- both files, and the sidecar's
##     JSON encoding with them. The recording Ref itself is handed over rather
##     than its bytes, so the 13.9 ms `get_data` copy happens off the main
##     thread too and the main thread never sees the 38 MB at all. Builds with
##     no threads (the single-threaded web fallback) get the same work sliced
##     across frames instead; `OS.has_feature("threads")` picks.
##
## What the click costs now is a tree walk that skips what it already knows:
## 9.4 ms on that same case, from 113,809 ms, with the whole recording on disk
## and replayable 105 ms after the click instead of 113.8 seconds after it. The
## incremental pass it leans on costs 86 ms spread over those 300 frames (0.29
## ms a frame), with ONE frame at 9.5 ms -- the first, where the declaration is
## collected and `Box3DMultiMeshRenderer.get_replay_body_colors` builds its
## 16,290-entry Dictionary in a single call that cannot be split.
##
## A stop before the pass has been round is the worst case and is bounded: 95.7
## ms on the same recording with NO polling at all, which is what a script that
## drives `stop()` without ever calling `poll_capture` gets. The shell always
## polls, and the pass completes in about a second of recording.
##
## `stop()` returns the path it WILL have written; `save_finished` says when it
## is there, `is_saving()` says whether it is yet, and `flush_save()` is the
## bounded join for the teardown paths that genuinely cannot continue without
## the file.

## Emitted on the MAIN thread when a save started by `stop()` has finished, with
## the path written ("" on failure) and the error ("" on success). The shell
## uses it to take its "Saving..." state down and to re-enable the replay row;
## the selftests await it. Always emitted exactly once per `stop()` that
## returned a path, whether the save went through a thread, through the sliced
## fallback or through `flush_save()`.
signal save_finished(path: String, error: String)

## Where the shell keeps its recordings. `user://` because it is the only
## writable location on every platform the demo ships to.
const DIR := "user://recordings"
const EXT := ".b3rec"

## THE VISUAL SIDECAR (F-042), and why it is a separate file.
##
## `.b3rec` is upstream's format and this fork never writes a byte into it that
## upstream did not put there -- `src/recording.c` owns it, a recording made
## here has to keep validating in upstream's own tooling, and the whole point of
## the additive-fork discipline is that there is nothing to merge. So the
## colours the live scene used ride ALONGSIDE the recording, in
## `<name>.b3rec.visual`, and a replay with no sidecar (an older recording, or
## one from upstream's viewer) simply falls back to the state palette the
## recording does carry.
##
## Keys are `Box3DRecording.get_body_key()` -- the body id, `"<index1>:<gen>"`,
## which is the ONE identity that means the same thing in the live world and in
## the replayed one (the full argument, with upstream cites, is on that method
## in `godot/src/box3d_replay.h`). Values are `RRGGBBAA` hex.
##
## SCOPE, stated so nobody reads more into it: a REPRESENTATIVE appearance per
## body, taken the first time the capture pass reaches that body (F-048 made the
## pass incremental; before that it was taken at stop). A body the pass never
## reached and that no longer exists at stop is absent, and replays in the
## recording's own palette colour, exactly as everything did before this
## existed.
##
## SCHEMA, and the compatibility rule (F-045). The file is
##   { "format": 2, "sample": "Car",
##     "colors":    { "<index1>:<gen>": "RRGGBBAA", ... },
##     "materials": { "<index1>:<gen>": {"r": 0.8, "m": 0.0, "s": 0.5}, ... } }
## `colors` is v1's map and is written UNCHANGED, so a v1 reader opens a v2 file
## and gets exactly what it always got. `materials` is v2's addition -- the PBR
## response that goes with the albedo (roughness, metallic, specular) -- and it
## is OPTIONAL on read, so a v1 file (which has no such key) opens here and
## yields an empty material table rather than an error. Neither direction needs
## the format number to branch; it is there to be read in a bug report.
const VISUAL_EXT := ".visual"
const VISUAL_FORMAT := 2

## Godot's own StandardMaterial3D property defaults, and therefore what a body
## whose material could not be read is assumed to be. Not a taste call: these
## are `roughness`, `metallic` and `metallic_specular` as Godot ships them, so
## a body captured through a route that carries no PBR data lands on the same
## response the engine would have given it.
const DEFAULT_ROUGHNESS := 1.0
const DEFAULT_METALLIC := 0.0
const DEFAULT_SPECULAR := 0.5

## Caps on the two averaging walks below. A representative colour does not get
## better past a few thousand samples and record-stop is a frame the user is
## watching, so both walks stride instead of reading everything: the Car's
## terrain is 6561 vertices and Cube Pile's world is 4096 bodies deep.
const VERTEX_COLOR_SAMPLES := 4096
const TEXTURE_SAMPLE_SIZE := 8

## Mesh averages memoised for the duration of ONE capture, and cleared at the
## start of the next. Record-stop is a frame the user is watching and a mesh is
## shared far more often than not -- Grid Mesh and Big Box Mesh give the same
## ArrayMesh to every body they make -- so without this the same few thousand
## vertices get averaged once per body. Cleared rather than kept because the
## meshes themselves can be freed between sessions.
static var _mesh_avg_cache := {}

## The answer `_shading_of` gives for one declaring node, memoised by object id.
##
## THIS IS THE 113-SECOND BUG (F-048). `_shading_of` searches a node's subtree
## three levels deep for the one material it draws its instances with, and Huge
## Pyramid's declaring node is the parent of all 16,290 boxes, so the search
## costs 12.6 ms -- which was then paid once PER BODY. Memoising is exact rather
## than approximate: a declaring node draws every one of its instances with a
## single material, which is the same premise that lets the colour protocol
## return a flat map in the first place.
static var _shading_cache := {}

## How many nodes `poll_capture` visits per call by default. 512 keeps the slice
## under a tenth of a millisecond on the samples measured while still walking
## Huge Pyramid's 16,291 bodies inside a second of recording.
const CAPTURE_BUDGET := 512

## How many bytes of the recording the no-thread fallback writes per frame
## slice. 4 MiB is about 1.5 ms of `store_buffer` on the machine this was
## measured on, so a 38 MB recording spreads over ten frames instead of
## stalling one.
const SAVE_CHUNK_BYTES := 4 * 1024 * 1024

## The one-method protocol a node implements when it draws bodies ITSELF.
##
## Most bodies wear their colour where you can see it: a MeshInstance3D child
## with a material on it. The interesting ones do not -- Cube Pile's 4096 cubes
## have no MeshInstance3D at all, because `common/cube_grid_multimesh.gd` frees
## them at load and draws the pile as per-instance MultiMesh colours instead,
## and `Box3DMultiMeshRenderer`, `ball_cloud.gd` and `joint_grid.gd` all do the
## same thing for the same reason (draw calls).
##
## A node in that position implements `get_replay_body_colors()` and returns
## `{ Box3DBody: Color }` for the bodies it draws. That is deliberately an ASK
## and not a guess: the alternative was to read the colours back off the
## MultiMesh and map instance k to the k-th body child, which assumes an
## ordering nothing promises AND does not work at all under `--headless`, where
## the dummy renderer stores no multimesh data and every colour reads back
## black. A wrong colour is worse than no colour, and an unverifiable path is
## worse than both.
const COLOR_METHOD := "get_replay_body_colors"

## The shell's one settings file -- the same path `main.gd` names
## `SHELL_LAYOUT_PATH`, and the same `[shell]` section the overlay toggles and
## the sticky-settings handoff already live in. The last save path is persisted
## HERE and not in main.gd's dirty set on purpose: the dirty set records solver
## settings the user has overridden ON TOP OF what a sample authored, so every
## key in it has a sample-authored baseline to be reverted to and a ⟲ button
## that means "follow the scene again". A file path has neither. It is a shell
## preference like the profiler being up, so it is stored the way those are.
const LAYOUT_PATH := "user://ui.cfg"
const LAYOUT_SECTION := "shell"
const LAYOUT_KEY := "last_recording"

## The live session, or null. Held as a Ref so the buffer outlives the world:
## a world being freed stops its own session (`b3DestroyWorld` ->
## `b3StopRecordingInternal`, `src/physics_world.c:414-415`), which leaves the
## bytes complete and saveable even though the world is gone.
var recording: Box3DRecording = null
## The world being recorded. May go invalid under us (sample switch, Reset);
## `stop()` copes.
var world: Node = null
## `_step_count` at the moment recording started, i.e. upstream's
## `m_recordStartStep` -- what the live indicator reports.
var start_step := 0
## Sample the session belongs to, for the default file name and the indicator.
var sample_name := ""
## Set by the last `stop()` that wrote a file; "" if it never has.
var last_saved := ""
## Set by the last `stop()` that failed, for the status line. "" when fine.
var last_error := ""

# --- incremental capture (F-048) ---------------------------------------------
## `body key -> visual`, filled a slice at a time by `poll_capture` while the
## session runs and swept up by `stop()`.
var _visuals := {}
## Body NODES already answered for, so the stop-time sweep is a dictionary
## lookup per body rather than a re-capture. Keyed by node, not by key, so a
## body that is skipped costs no `get_body_key` call either.
var _captured := {}
## `body node -> [Color, declaring node]`, this session's declarations.
var _declared := {}
## The resumable walk: an explicit stack, so a slice can stop anywhere.
var _walk: Array = []
## 0 = collecting declarations, 1 = collecting bodies, 2 = the pass is finished.
var _walk_phase := 2

# --- the background save (F-048) ---------------------------------------------
var _save_thread: Thread = null
var _saving := false
var _save_job := {}
## Written by the worker before it hands back, read after the join. Safe without
## a lock precisely because those two are ordered by the join.
var _save_result_path := ""
var _save_result_error := ""
## Take the sliced path even where threads exist. The single-threaded web build
## is the only thing that reaches it in production, and a path nothing on this
## machine can run is a path nothing on this machine can test -- so the
## selftests set this rather than leaving the fallback to be discovered broken
## in a browser. Nothing in the shell touches it.
var force_sliced_save := false

## The sliced fallback's cursor, for builds with no threads.
var _slice_stage := 0
var _slice_offset := 0
var _slice_bytes := PackedByteArray()


func is_recording() -> bool:
	return recording != null


## Is a `stop()` still writing? True from the moment `stop()` returns a path
## until `save_finished` fires. The shell gates "Replay last", the Open popup
## and the arm buttons on this: a recording that is still being written must not
## be opened, and the honest way to say so is to refuse rather than to hand back
## a truncated file.
func is_saving() -> bool:
	return _saving


## Arm a session on `p_world`. `p_step` is the shell's step counter, only ever
## used for the readout. Returns false if a session is already live, if the
## world cannot record, or if the world is not a Box3D one -- the native
## engines have no recording API at all, which is why the section hides there.
func start(p_world: Node, p_sample_name: String, p_step: int) -> bool:
	if recording != null:
		return false
	if p_world == null or not is_instance_valid(p_world):
		return false
	if not p_world.has_method("start_recording"):
		return false
	# One save at a time. Arming again inside the ~80 ms a save takes is only
	# reachable by a script, but two sessions writing through one set of result
	# fields is a race, so the previous one is finished first.
	if _saving:
		flush_save()
	var buffer := Box3DRecording.new()
	if not p_world.start_recording(buffer):
		return false
	recording = buffer
	world = p_world
	sample_name = p_sample_name
	start_step = p_step
	last_error = ""
	_begin_capture_pass(p_world)
	return true


## Stop the session and START writing it. Returns the path it will have written,
## or "" if there is nothing to write (with `last_error` set to something worth
## showing).
##
## THE RETURN IS A PROMISE, NOT A RECEIPT (F-048). The two files are written off
## this frame -- on a `Thread` where there are threads, sliced across frames
## where there are not -- so when this returns, the path is decided and the
## bytes are not on disk yet. `is_saving()` is true until they are,
## `save_finished` fires when they are, and `flush_save()` waits for them. That
## is the whole shape of the fix: the click that stops a 38 MB recording used to
## hold the main thread for 113.8 seconds and now holds it for about 5 ms.
##
## What still HAS to happen here, on the main thread, and why:
##   - `stop_recording()` on the world, because that is what appends the
##     geometry registry and backpatches the header, i.e. what makes the bytes
##     loadable at all (`src/recording.c:1069-1108`) -- and `get_data()` /
##     `save_to_file()` refuse until it has (`godot/src/box3d_replay.cpp:53-58`).
##     It costs 0.01 ms and it must not race the world.
##   - the capture sweep, because it touches the SCENE TREE, which is main-
##     thread-only in Godot. `poll_capture` has usually already done nearly all
##     of it; what is left here is a walk that skips every body it recognises.
func stop(p_path := "") -> String:
	if recording == null:
		return ""
	if _saving:
		# Only reachable by stopping a second session inside the first save.
		flush_save()
	var buffer := recording
	var was_world := world
	recording = null
	world = null
	if was_world != null and is_instance_valid(was_world) and was_world.has_method("stop_recording"):
		was_world.stop_recording()
	# A world that was freed under us already stopped the session itself, so the
	# buffer is complete either way and only the bookkeeping was left.
	if buffer.is_recording():
		last_error = "the session did not close"
		_end_capture_pass()
		return ""
	if buffer.get_size() <= 0:
		last_error = "nothing was recorded"
		_end_capture_pass()
		return ""
	var path := p_path
	if path.is_empty():
		path = suggest_path(sample_name)
	if not ensure_dir():
		last_error = "could not create %s" % DIR
		_end_capture_pass()
		return ""
	# The sidecar is captured from the LIVE world, so it has to happen here and
	# not from the replay side: this is the last moment the bodies that were
	# recorded still exist as nodes with materials on them. A world already
	# freed under us (which `stop()` copes with above) simply yields no sidecar,
	# and the replay falls back to the palette.
	var visuals := {}
	if was_world != null and is_instance_valid(was_world):
		_sweep_uncaptured(was_world)
		visuals = _visuals.duplicate()
	_end_capture_pass()
	last_error = ""
	_begin_save({"recording": buffer, "path": path, "visuals": visuals,
		"sample": sample_name})
	return path


## Drop a live session without writing anything. Used by nothing in the shell
## today -- every teardown path saves, following upstream -- but a session that
## cannot be saved has to be closable, and the selftests exercise it.
func discard() -> void:
	if recording == null:
		return
	if world != null and is_instance_valid(world) and world.has_method("stop_recording"):
		world.stop_recording()
	recording = null
	world = null
	_end_capture_pass()


# --- incremental capture (F-048) ---------------------------------------------


## Walk a slice of the recorded world, answering for the bodies it reaches.
## Called every frame by the shell while a session runs
## (`main.gd:_physics_process`); harmless and free when nothing is recording.
##
## THE ONE SEMANTIC THIS CHANGES, stated rather than discovered later: a body's
## appearance is now captured WHEN THE WALK FIRST REACHES IT, not at the moment
## Stop is clicked. For the sidecar that is a distinction without a difference
## -- it holds one representative colour per body and nothing in the demo
## repaints a body mid-session -- and it is strictly better in one case: a body
## destroyed mid-recording used to be dropped from the sidecar entirely and now
## keeps its colour for the frames it existed in. A body whose material really
## does change during a session would be captured as it first looked; that is
## the accepted price, and it is the same price the pre-F-048 code paid in
## reverse (it captured the last look and lost the first).
##
## The pass runs in two phases for the same reason the one-shot capture did:
## declarations have to be complete before any body is answered for, because a
## node that draws its own bodies outranks whatever material hangs under them,
## and the ball clouds add their bodies to the WORLD rather than to themselves,
## so tree order cannot be relied on.
func poll_capture(p_budget := CAPTURE_BUDGET) -> void:
	if recording == null or _walk_phase >= 2:
		return
	if world == null or not is_instance_valid(world):
		return
	var left := p_budget
	while left > 0:
		if _walk.is_empty():
			if _walk_phase == 0:
				_walk_phase = 1
				_walk = [world]
				continue
			_walk_phase = 2
			return
		# Popped as a Variant on purpose: Record (restart) frees the old scene
		# on a deferred tick, so entries queued before the swap can be dead by
		# the time they are popped, and assigning a freed instance to a typed
		# Node errors BEFORE any guard on the next line could run. Validity is
		# decided first, on the untyped value.
		var node_v: Variant = _walk.pop_back()
		left -= 1
		if node_v == null or not is_instance_valid(node_v):
			continue
		var node: Node = node_v
		if _walk_phase == 0:
			_declare_from(node, _declared)
		elif node is Box3DBody:
			_capture_body(node)
		for child in node.get_children():
			_walk.push_back(child)


## How many bodies the pass has ANSWERED FOR -- which is not the same as how
## many are in the sidecar: a body no route can read (a bare `Box3DBody` with no
## drawable under it and nobody declaring it) is answered for with "nothing",
## and correctly contributes no entry. The shell does not show either number;
## the selftests assert on this one, because "the walk really did run while
## recording" is otherwise invisible.
func captured_count() -> int:
	return _captured.size()


## How many of those have an appearance to write. `captured_count()` minus this
## is the count of bodies that will replay in the recording's own palette.
func visual_count() -> int:
	return _visuals.size()


## True once the incremental pass has been all the way round. A `stop()` from
## here is the cheap one.
func capture_complete() -> bool:
	return _walk_phase >= 2


func _begin_capture_pass(p_world: Node) -> void:
	_visuals.clear()
	_captured.clear()
	_declared.clear()
	_mesh_avg_cache.clear()
	_shading_cache.clear()
	_walk = [p_world]
	_walk_phase = 0


func _end_capture_pass() -> void:
	_visuals.clear()
	_captured.clear()
	_declared.clear()
	_walk.clear()
	_walk_phase = 2
	# The meshes and the declaring nodes are about to be freed with their
	# sample; holding Colors keyed on their ids would be a slow leak.
	_mesh_avg_cache.clear()
	_shading_cache.clear()


## Everything `poll_capture` did not reach in time. The expensive half is
## skipped for every body already answered for, which on the case F-048 was
## reported against is all of them.
##
## The declarations are re-collected only when there IS an unanswered body,
## because that call is not free -- `Box3DMultiMeshRenderer.get_replay_body_colors`
## builds a 16,290-entry Dictionary and costs 16.9 ms on Huge Pyramid. A session
## whose pass completed and whose world gained no bodies never pays it.
func _sweep_uncaptured(p_world: Node) -> void:
	var unseen: Array = []
	var stack: Array = [p_world]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children():
			if child is Box3DBody and not _captured.has(child):
				unseen.append(child)
			stack.push_back(child)
	if unseen.is_empty():
		return
	_collect_declared(p_world, _declared)
	for body in unseen:
		_capture_body(body as Node)


func _capture_body(p_body: Node) -> void:
	if _captured.has(p_body):
		return
	_captured[p_body] = true
	var key: String = Box3DRecording.get_body_key(p_body)
	if key.is_empty():
		return
	var visual: Variant = _visual_of(p_body, _declared)
	if visual != null:
		_visuals[key] = visual


# --- the background save (F-048) ---------------------------------------------


func _begin_save(p_job: Dictionary) -> void:
	_saving = true
	_save_job = p_job
	_save_result_path = ""
	_save_result_error = ""
	# `OS.has_feature("threads")` rather than a platform test: it is false on
	# exactly one build this demo ships, the single-threaded web fallback, and
	# true on desktop, Android and the threaded web build itch serves. Nothing
	# else has to know which is which.
	if OS.has_feature("threads") and not force_sliced_save:
		_save_thread = Thread.new()
		if _save_thread.start(_save_worker.bind(p_job)) == OK:
			return
		# A thread that will not start is not a reason to lose the recording.
		_save_thread = null
	_slice_stage = 0
	_slice_offset = 0
	_slice_bytes = PackedByteArray()


## The worker. Touches NO scene tree and no node: a recording Ref, two
## dictionaries and `FileAccess`.
##
## THE RECORDING REF IS HANDED OVER, NOT ITS BYTES, and that is where the last
## of the main-thread cost went. `get_data()` copies the whole 38 MB out of
## upstream's buffer (13.9 ms measured), so marshalling a PackedByteArray to
## hand the thread would have kept that 13.9 ms on the frame of the click.
## `save_to_file` does the copy and the write together, inside the worker
## (`godot/src/box3d_replay.cpp:72-86`), and by then `stop()` has already
## dropped the only other reference to the session, so nothing races it.
func _save_worker(p_job: Dictionary) -> void:
	_save_result_error = _run_save(p_job)
	_save_result_path = String(p_job["path"])
	call_deferred("_on_save_thread_done")


static func _run_save(p_job: Dictionary) -> String:
	var buffer: Box3DRecording = p_job["recording"]
	var path := String(p_job["path"])
	if not buffer.save_to_file(path):
		return "could not write %s" % path
	var visuals: Dictionary = p_job["visuals"]
	if not visuals.is_empty():
		write_visuals(path, visuals, String(p_job["sample"]))
	return ""


## Deferred from the worker, so this runs on the main thread. `wait_to_finish`
## here is not the join the fix exists to avoid: the worker has already reached
## its last statement, so this reaps a thread that is microseconds from
## returning. The main thread never waits on WORK.
func _on_save_thread_done() -> void:
	if _save_thread == null:
		return  # flush_save got there first and already reaped it
	_save_thread.wait_to_finish()
	_save_thread = null
	_finish_save(_save_result_path, _save_result_error)


## Drive the no-thread fallback. Called from the same shell frame hook as
## `poll_capture`; a no-op everywhere a thread is doing the work.
##
## The stages are the two measured costs, one per frame each: the recording's
## bytes (chunked, because a 38 MB `store_buffer` is one 11 ms block) and the
## sidecar (whose 60 ms is a single `JSON.stringify` and cannot be split without
## hand-rolling an encoder, which is not worth it for the fallback build).
func poll_save() -> void:
	if not _saving or _save_thread != null:
		return
	_run_save_slice()


func _run_save_slice() -> void:
	var path := String(_save_job["path"])
	if _slice_stage == 0:
		var buffer: Box3DRecording = _save_job["recording"]
		_slice_bytes = buffer.get_data()
		if _slice_bytes.is_empty():
			_finish_save("", "could not read the recording back")
			return
		var f := FileAccess.open(path, FileAccess.WRITE)
		if f == null:
			_finish_save("", "could not write %s" % path)
			return
		f.close()
		_slice_offset = 0
		_slice_stage = 1
		return
	if _slice_stage == 1:
		var f := FileAccess.open(path, FileAccess.READ_WRITE)
		if f == null:
			_finish_save("", "could not write %s" % path)
			return
		f.seek(_slice_offset)
		var end := mini(_slice_offset + SAVE_CHUNK_BYTES, _slice_bytes.size())
		f.store_buffer(_slice_bytes.slice(_slice_offset, end))
		f.close()
		_slice_offset = end
		if _slice_offset >= _slice_bytes.size():
			_slice_stage = 2
		return
	var visuals: Dictionary = _save_job["visuals"]
	if not visuals.is_empty():
		write_visuals(path, visuals, String(_save_job["sample"]))
	_slice_bytes = PackedByteArray()
	_finish_save(path, "")


## Wait for an in-flight save, however it is being done. For the paths that
## genuinely cannot go on without the file: a sample switch, a Reset, an engine
## switch, entering a replay and quitting.
##
## A BOUNDED STALL RATHER THAN A BLOCKED SWITCH, and the reason is proportion.
## The whole background save measures ~85 ms on the largest recording this demo
## can make, and every caller of this is already rebuilding or tearing down a
## world -- Huge Pyramid alone costs far more than that to construct. Blocking
## the switch instead would mean either refusing a click the user made or
## queueing a second session behind the first, and two recordings in flight
## through one set of result fields is a race for no benefit. The click the fix
## is ABOUT -- Stop -- never comes through here.
func flush_save() -> void:
	if not _saving:
		return
	if _save_thread != null:
		_save_thread.wait_to_finish()
		_save_thread = null
		_finish_save(_save_result_path, _save_result_error)
		return
	while _saving:
		_run_save_slice()


func _finish_save(p_path: String, p_error: String) -> void:
	if not _saving:
		return
	_saving = false
	_save_job = {}
	_slice_stage = 0
	_slice_offset = 0
	_slice_bytes = PackedByteArray()
	last_error = p_error
	if p_error.is_empty():
		last_saved = p_path
		# Remembered only once the bytes are really there. "Replay last" must
		# never point at a file that is still being written.
		remember(p_path)
	save_finished.emit("" if not p_error.is_empty() else p_path, p_error)


## Live bytes, i.e. the one honest progress readout while recording
## (`b3Recording_GetSize` works mid-session; `get_data()` does not).
func get_size() -> int:
	return recording.get_size() if recording != null else 0


## Upstream's indicator text, verbatim in spirit: "recording (from step %d)"
## (`samples/sample.cpp:2031`), plus the size, because a shell recording can run
## for minutes and the number climbing is the only sign it is still going.
func status_text() -> String:
	if recording == null:
		return ""
	return "recording (from step %d) - %s" % [start_step, human_size(get_size())]


static func human_size(bytes: int) -> String:
	if bytes < 1024:
		return "%d B" % bytes
	if bytes < 1024 * 1024:
		return "%.1f KB" % (float(bytes) / 1024.0)
	return "%.1f MB" % (float(bytes) / (1024.0 * 1024.0))


static func ensure_dir() -> bool:
	if DirAccess.dir_exists_absolute(DIR):
		return true
	return DirAccess.make_dir_recursive_absolute(DIR) == OK


## `user://recordings/cube_pile-20260808-142530.b3rec`. Sample name plus a
## timestamp: unique without asking, sorts chronologically, and says what it is
## of. Deliberately not `Time.get_datetime_string_from_system()`, whose colons
## are not legal in a Windows filename.
static func suggest_path(p_sample_name: String) -> String:
	var slug := ""
	for c in p_sample_name.to_lower():
		slug += c if (c >= "a" and c <= "z") or (c >= "0" and c <= "9") else "_"
	while slug.contains("__"):
		slug = slug.replace("__", "_")
	slug = slug.strip_edges(true, true).lstrip("_").rstrip("_")
	if slug.is_empty():
		slug = "recording"
	var t := Time.get_datetime_dict_from_system()
	return "%s/%s-%04d%02d%02d-%02d%02d%02d%s" % [DIR, slug,
		t["year"], t["month"], t["day"], t["hour"], t["minute"], t["second"], EXT]


## Every saved recording, newest first. What the sidebar's Open menu lists; the
## shell has no native file dialog to offer on web or Android, and this is the
## only directory it ever writes to.
static func list_saved() -> PackedStringArray:
	var out := PackedStringArray()
	if not DirAccess.dir_exists_absolute(DIR):
		return out
	var names := DirAccess.get_files_at(DIR)
	# `.import`/`.remap` suffixes never appear under user://, but a stray file
	# might; only offer what the player could actually open.
	var keep: Array[String] = []
	for n in names:
		if n.ends_with(EXT):
			keep.append(n)
	keep.sort()
	keep.reverse()  # the names carry a sortable timestamp, so this is newest first
	for n in keep:
		out.append("%s/%s" % [DIR, n])
	return out


## Persist / read the last written path, in main.gd's own settings file. Kept
## static so the shell can offer "Replay last recording" on a fresh launch,
## before any session has existed in this process.
static func remember(p_path: String) -> void:
	var layout := ConfigFile.new()
	layout.load(LAYOUT_PATH)  # keep the overlay and panel sections intact
	layout.set_value(LAYOUT_SECTION, LAYOUT_KEY, p_path)
	layout.save(LAYOUT_PATH)


# --- the visual sidecar (F-042) -----------------------------------------------


## `user://recordings/x.b3rec` -> `user://recordings/x.b3rec.visual`. Beside the
## recording and named after it, so "Replay last" and the Open popup pick it up
## with no bookkeeping at all: the path IS the link. Deleting a recording and
## leaving its sidecar behind is accepted for v1 -- an orphan is a few KB of
## JSON that nothing will ever open.
static func visual_path(p_recording_path: String) -> String:
	return p_recording_path + VISUAL_EXT


## Walk a live world and answer "what did each body LOOK like?", keyed by body
## id. The value is a small Dictionary -- `color`, `roughness`, `metallic`,
## `specular` -- because a replay that matches the live scene needs the PBR
## response and not only the albedo (F-045; the numbers are on `write_visuals`).
##
## THE PRINCIPLE, which is the whole of F-045: the replay INHERITS the scene's
## appearance. Nothing here invents a colour, picks from a palette or falls back
## to white -- every route below reads a value the live renderer was actually
## drawing with, and a body no route can answer for is simply absent from the
## sidecar and replays in the recording's own state palette (the pre-F-042 look,
## a supported outcome rather than a miss).
##
## THE ROUTES, in priority order, most authoritative first:
##
##  1. A DECLARATION. Any node that draws bodies itself is asked, through
##     `COLOR_METHOD` above. That is Cube Pile, the emitter ball clouds, the
##     joint grid and every `Box3DMultiMeshRenderer` scene. Its PBR response
##     comes from the one material that node draws all its instances with.
##  2. `material_override` on a MeshInstance3D under the body -- what actually
##     draws when it is set, so it outranks everything on the mesh. This is what
##     catches the shell's projectiles (`WorldOps.spawn_sphere`,
##     common/world_ops.gd:93-96) and most sample floors.
##  3. A surface override material, then the MESH'S OWN surface material. The
##     third is not a nicety: a mesh authored with its material baked in
##     (`PrimitiveMesh.material`, or a saved ArrayMesh) has nothing on the node
##     at all.
##  4. Instance shader parameters on the GeometryInstance3D, for a scene that
##     tints per instance rather than per material.
##
## Whichever material wins, its albedo is then resolved the way the SHADER
## resolves it, which is where the white bodies came from before F-045: Godot's
## spatial shader multiplies `albedo_color` by the albedo texture and, with
## `vertex_color_use_as_albedo` on, by the vertex colour. A material that leaves
## `albedo_color` at its default white and paints entirely in vertex colours --
## the Car's terrain and its wheels, both of them
## (`samples/car.tscn` TerrainMat/WheelMat, baked by `tools/gen_car_terrain.gd`
## and `tools/gen_car_wheel.gd`) -- reported WHITE when only `albedo_color` was
## read. See `_material_visual` for how the product is taken.
static func capture_visuals(p_world: Node) -> Dictionary:
	var out := {}
	if p_world == null or not is_instance_valid(p_world):
		return out
	_mesh_avg_cache.clear()
	_shading_cache.clear()
	var declared := {}
	_collect_declared(p_world, declared)
	_collect_bodies(p_world, declared, out)
	_mesh_avg_cache.clear()
	_shading_cache.clear()
	return out


## `capture_visuals` reduced to v1's shape, `{ body key: Color }`. Kept because
## the albedo table is what the renderer can currently be handed (its override
## API takes a Color), so this is the call the shell and the selftests make.
static func capture_colors(p_world: Node) -> Dictionary:
	return colors_of(capture_visuals(p_world))


## `{ key: visual }` -> `{ key: Color }`. Split out so a caller that already has
## the visuals does not walk the world twice.
static func colors_of(p_visuals: Dictionary) -> Dictionary:
	var out := {}
	for key in p_visuals:
		out[key] = (p_visuals[key] as Dictionary)["color"] as Color
	return out


## `{ key: visual }` -> `{ key: {"r","m","s"} }` for every body whose response
## DIFFERS from `p_material_default` (or, when that is empty, from Godot's own
## defaults). Only the exceptions are stored, which is the whole reason the
## sidecar of a 4096-body scene is not mostly repetition: Cube Pile draws every
## cube with one material, so its modal response goes in the header and this
## returns nothing at all.
static func materials_of(p_visuals: Dictionary, p_material_default := {}) -> Dictionary:
	var out := {}
	var base := _material_or_defaults(p_material_default)
	for key in p_visuals:
		var entry := _material_entry(p_visuals[key] as Dictionary)
		if _same_material(entry, base):
			continue
		out[key] = entry
	return out


## The response the most bodies share, or {} when there is no majority worth
## hoisting. Written as the sidecar's `material_default` and applied on read to
## every body that has no entry of its own.
static func material_default_of(p_visuals: Dictionary) -> Dictionary:
	var tally := {}
	var best := {}
	var best_count := 0
	for key in p_visuals:
		var entry := _material_entry(p_visuals[key] as Dictionary)
		var sig := "%.4f/%.4f/%.4f" % [entry["r"], entry["m"], entry["s"]]
		var count: int = int(tally.get(sig, 0)) + 1
		tally[sig] = count
		if count > best_count:
			best_count = count
			best = entry
	# One body sharing it with nobody is not a default, it is that body's entry.
	if best_count < 2 or _same_material(best, _material_or_defaults({})):
		return {}
	return best


static func _material_entry(p_visual: Dictionary) -> Dictionary:
	return {
		"r": p_visual["roughness"] as float,
		"m": p_visual["metallic"] as float,
		"s": p_visual["specular"] as float,
	}


static func _material_or_defaults(p_material: Dictionary) -> Dictionary:
	if p_material.is_empty():
		return {"r": DEFAULT_ROUGHNESS, "m": DEFAULT_METALLIC, "s": DEFAULT_SPECULAR}
	return p_material


static func _same_material(p_a: Dictionary, p_b: Dictionary) -> bool:
	return is_equal_approx(p_a["r"] as float, p_b["r"] as float) \
		and is_equal_approx(p_a["m"] as float, p_b["m"] as float) \
		and is_equal_approx(p_a["s"] as float, p_b["s"] as float)


## Everything the world's own renderers say they coloured, keyed by body NODE.
## Collected in one pass up front so the per-body walk below is a dictionary
## lookup rather than a search back up the tree.
static func _collect_declared(p_node: Node, r_declared: Dictionary) -> void:
	_declare_from(p_node, r_declared)
	for child in p_node.get_children():
		_collect_declared(child, r_declared)


## One node's contribution to the declaration map. Split out of the recursion so
## the incremental pass, which owns its own traversal, asks exactly the same
## question of exactly the same nodes.
static func _declare_from(p_node: Node, r_declared: Dictionary) -> void:
	if not p_node.has_method(COLOR_METHOD):
		return
	var reported: Variant = p_node.call(COLOR_METHOD)
	if not (reported is Dictionary):
		return
	for body in (reported as Dictionary):
		var color: Variant = (reported as Dictionary)[body]
		if body is Box3DBody and typeof(color) == TYPE_COLOR:
			# The DECLARING NODE is kept alongside the colour: it owns the
			# material the instances are drawn with, and a body's own parent is
			# not always that node (the ball clouds add their bodies to the
			# world, not to themselves).
			r_declared[body] = [color as Color, p_node]


## One body's appearance, given the declarations. The single place either walk
## resolves a body, so the incremental pass and the one-shot capture cannot
## drift apart.
static func _visual_of(p_body: Node, p_declared: Dictionary) -> Variant:
	var declared: Variant = p_declared.get(p_body, null)
	if declared == null:
		return _body_visual(p_body)
	# The declaring node named the albedo; its own material still owns the PBR
	# response, because one material draws all of that node's instances
	# (common/cube_grid_multimesh.gd:65-68 roughness 0.8, common/ball_cloud.gd:
	# 55-58 roughness 0.3 / metallic 0.2). Duplicated because `_shading_of` is
	# memoised now and hands back the node's shared answer.
	var visual: Dictionary = (_shading_of((declared as Array)[1] as Node)).duplicate()
	visual["color"] = (declared as Array)[0] as Color
	return visual


static func _collect_bodies(p_node: Node, p_declared: Dictionary, r_out: Dictionary) -> void:
	for child in p_node.get_children():
		if child is Box3DBody:
			var key: String = Box3DRecording.get_body_key(child)
			if not key.is_empty():
				var visual: Variant = _visual_of(child, p_declared)
				if visual != null:
					r_out[key] = visual
		_collect_bodies(child, p_declared, r_out)


## The appearance of the first drawable under this body, or null. Two levels
## deep: a body's visual is usually its direct child, but several samples wrap
## it in a pivot Node3D.
static func _body_visual(p_body: Node) -> Variant:
	for child in p_body.get_children():
		if child is GeometryInstance3D:
			var v: Variant = _geometry_visual(child)
			if v != null:
				return v
	for child in p_body.get_children():
		for grand in child.get_children():
			if grand is GeometryInstance3D:
				var v: Variant = _geometry_visual(grand)
				if v != null:
					return v
	return null


## Resolve one GeometryInstance3D to `{color, roughness, metallic, specular}`.
##
## The material search order is the engine's own: `material_override` replaces
## everything, then a per-surface override, then the material the MESH carries.
## That last one is the route the Car's wheels and terrain needed -- their
## materials are subresources of `car.tscn` set as `material_override`, but a
## `PrimitiveMesh.material` or a saved ArrayMesh surface material hangs off no
## node at all, and before F-045 a body drawn that way reported nothing.
static func _geometry_visual(p_geom: GeometryInstance3D) -> Variant:
	var mesh: Mesh = null
	if p_geom is MeshInstance3D:
		mesh = (p_geom as MeshInstance3D).mesh
	# `{material, surface}` pairs, most authoritative first.
	var candidates: Array = []
	if p_geom.material_override != null:
		candidates.append([p_geom.material_override, 0])
	if mesh != null:
		for s in mesh.get_surface_count():
			if p_geom is MeshInstance3D:
				var over := (p_geom as MeshInstance3D).get_surface_override_material(s)
				if over != null:
					candidates.append([over, s])
			var own := mesh.surface_get_material(s)
			if own != null:
				candidates.append([own, s])
	if p_geom.material_overlay != null:
		candidates.append([p_geom.material_overlay, 0])
	for pair in candidates:
		var v: Variant = _material_visual(pair[0] as Material, mesh, pair[1] as int)
		if v != null:
			return v
	# No material anywhere: a scene that tints per instance instead.
	var tint: Variant = _instance_param_color(p_geom)
	if tint != null:
		return {"color": tint as Color, "roughness": DEFAULT_ROUGHNESS,
			"metallic": DEFAULT_METALLIC, "specular": DEFAULT_SPECULAR}
	return null


## What one material would actually paint, on this mesh surface.
##
## THE ALBEDO IS A PRODUCT, not a property. Godot's spatial shader multiplies
## `albedo_color` by the albedo texture, and again by the vertex colour when
## `vertex_color_use_as_albedo` is set; reading `albedo_color` alone is exactly
## the bug F-045 fixes, because a vertex-painted material leaves that property
## at its default WHITE and every such body replayed white.
##
## The product is taken in LINEAR light and converted back at the end, because
## linear is where the renderer averages: a black-and-tan checkerboard wheel
## blurs to the tan-ward grey a camera sees, not to the darker midpoint an sRGB
## average would give. The no-texture, no-vertex-colour case short-circuits to
## `albedo_color` untouched, so an ordinary material's captured value is bit-for
## -bit what it was before F-045.
static func _material_visual(p_material: Material, p_mesh: Mesh, p_surface: int) -> Variant:
	if p_material is ShaderMaterial:
		var sm := p_material as ShaderMaterial
		for name in ["albedo", "albedo_color", "color", "modulate"]:
			var v: Variant = sm.get_shader_parameter(name)
			if typeof(v) == TYPE_COLOR:
				return {"color": v as Color, "roughness": DEFAULT_ROUGHNESS,
					"metallic": DEFAULT_METALLIC, "specular": DEFAULT_SPECULAR}
		return null
	if not (p_material is BaseMaterial3D):
		return null
	var mat := p_material as BaseMaterial3D
	var albedo := mat.albedo_color
	var tex_tint: Variant = _texture_average(mat.albedo_texture)
	var vert_tint: Variant = null
	if mat.vertex_color_use_as_albedo:
		vert_tint = _vertex_color_average(p_mesh, p_surface, mat.vertex_color_is_srgb)
	var color := albedo
	if tex_tint != null or vert_tint != null:
		var lin := albedo.srgb_to_linear()
		if tex_tint != null:
			var t := (tex_tint as Color).srgb_to_linear()
			lin = Color(lin.r * t.r, lin.g * t.g, lin.b * t.b, lin.a)
		if vert_tint != null:
			# Already linear: `_vertex_color_average` averages in the space the
			# renderer multiplies in.
			var v := vert_tint as Color
			lin = Color(lin.r * v.r, lin.g * v.g, lin.b * v.b, lin.a * v.a)
		color = lin.linear_to_srgb()
		color.a = albedo.a
	return {
		"color": color,
		"roughness": mat.roughness,
		"metallic": mat.metallic,
		"specular": mat.metallic_specular,
	}


## Mean vertex colour of a mesh surface, in LINEAR light, or null if the surface
## paints none. `p_is_srgb` is the material's `vertex_color_is_srgb`, i.e.
## whether the stored colours are sRGB the shader linearises or linear already;
## getting it wrong shifts the result by a whole gamma curve.
static func _vertex_color_average(p_mesh: Mesh, p_surface: int, p_is_srgb: bool) -> Variant:
	if p_mesh == null or p_surface < 0 or p_surface >= p_mesh.get_surface_count():
		return null
	var cache_key := "%d:%d:%d" % [p_mesh.get_instance_id(), p_surface, int(p_is_srgb)]
	if _mesh_avg_cache.has(cache_key):
		return _mesh_avg_cache[cache_key]
	var result: Variant = _vertex_color_average_uncached(p_mesh, p_surface, p_is_srgb)
	_mesh_avg_cache[cache_key] = result
	return result


static func _vertex_color_average_uncached(p_mesh: Mesh, p_surface: int,
		p_is_srgb: bool) -> Variant:
	var arrays: Array = p_mesh.surface_get_arrays(p_surface)
	if arrays.size() <= Mesh.ARRAY_COLOR:
		return null
	var colors: Variant = arrays[Mesh.ARRAY_COLOR]
	if not (colors is PackedColorArray):
		return null
	var packed := colors as PackedColorArray
	var n := packed.size()
	if n == 0:
		return null
	var stride := maxi(1, int(ceil(float(n) / float(VERTEX_COLOR_SAMPLES))))
	var acc := Color(0, 0, 0, 0)
	var taken := 0
	var i := 0
	while i < n:
		var c := packed[i]
		if p_is_srgb:
			c = c.srgb_to_linear()
		acc += Color(c.r, c.g, c.b, c.a)
		taken += 1
		i += stride
	var inv := 1.0 / float(taken)
	return Color(acc.r * inv, acc.g * inv, acc.b * inv, acc.a * inv)


## Mean albedo of a texture, in sRGB, or null. The image is squeezed to
## TEXTURE_SAMPLE_SIZE square first, which is the cheap way to get an
## area-weighted mean and is all a representative colour needs.
##
## NOTHING IN THE DEMO TAKES THIS ROUTE TODAY -- no sample uses `albedo_texture`
## -- so it is written defensively and is unexercised by the selftests. It is
## here because a textured body is the one remaining way to draw a body whose
## colour is not in a property, and the alternative for one is replaying white.
static func _texture_average(p_texture: Texture2D) -> Variant:
	if p_texture == null:
		return null
	var img: Image = p_texture.get_image()
	if img == null or img.is_empty():
		return null
	img = img.duplicate()
	if img.is_compressed() and img.decompress() != OK:
		return null
	img.resize(TEXTURE_SAMPLE_SIZE, TEXTURE_SAMPLE_SIZE, Image.INTERPOLATE_BILINEAR)
	var acc := Color(0, 0, 0, 0)
	for y in TEXTURE_SAMPLE_SIZE:
		for x in TEXTURE_SAMPLE_SIZE:
			acc += img.get_pixel(x, y)
	var inv := 1.0 / float(TEXTURE_SAMPLE_SIZE * TEXTURE_SAMPLE_SIZE)
	return Color(acc.r * inv, acc.g * inv, acc.b * inv, acc.a * inv)


## A per-instance tint set on the GeometryInstance3D itself, or null. The names
## are the ones Godot's own docs and the demo's shaders use for an albedo
## uniform; an instance parameter that is not a Color is not an albedo.
static func _instance_param_color(p_geom: GeometryInstance3D) -> Variant:
	for name in ["albedo", "albedo_color", "color", "modulate", "tint"]:
		var v: Variant = p_geom.get_instance_shader_parameter(name)
		if typeof(v) == TYPE_COLOR:
			return v as Color
	return null


## The PBR response of the one material a self-drawing node paints all its
## instances with, as a visual with no colour in it yet. Falls back to Godot's
## defaults, so a declaring node with no reachable material is exactly as it was
## before F-045.
## MEMOISED, and that memo is the whole of F-048's first order of magnitude: the
## search below is three levels of a subtree, and Huge Pyramid's declaring node
## has 16,290 children, so one answer costs 12.6 ms and the old code asked for
## it once per body (113.6 seconds). The answer cannot differ between two bodies
## of the same node -- one material draws all of that node's instances -- so
## this caches a constant.
static func _shading_of(p_node: Node) -> Dictionary:
	var cache_key := p_node.get_instance_id() if p_node != null else 0
	if _shading_cache.has(cache_key):
		return _shading_cache[cache_key]
	var out := {"color": Color.WHITE, "roughness": DEFAULT_ROUGHNESS,
		"metallic": DEFAULT_METALLIC, "specular": DEFAULT_SPECULAR}
	# MultiMesh first, and not as an optimisation: a self-drawing node's bodies
	# may still own the MeshInstance3D it stopped using (Cube Pile frees
	# theirs, but nothing in the protocol requires that), and reading the
	# abandoned material instead of the one being drawn with would be a wrong
	# answer dressed as a found one.
	var mat: Variant = _first_material(p_node, 0, true)
	if mat == null:
		mat = _first_material(p_node, 0, false)
	if mat is BaseMaterial3D:
		out["roughness"] = (mat as BaseMaterial3D).roughness
		out["metallic"] = (mat as BaseMaterial3D).metallic
		out["specular"] = (mat as BaseMaterial3D).metallic_specular
	_shading_cache[cache_key] = out
	return out


## First material under `p_node`, three levels deep. MultiMeshInstance3D is
## searched too and is the case that matters: the self-drawing nodes hang their
## one material off the MultiMesh's mesh (`box.material` / `sphere.material`),
## not off any node property.
static func _first_material(p_node: Node, p_depth: int, p_multimesh_only: bool) -> Variant:
	if p_node == null or not is_instance_valid(p_node) or p_depth > 2:
		return null
	var eligible: bool = (p_node is MultiMeshInstance3D) if p_multimesh_only \
			else (p_node is GeometryInstance3D)
	if eligible:
		var geom := p_node as GeometryInstance3D
		if geom.material_override is BaseMaterial3D:
			return geom.material_override
		var mesh: Mesh = null
		if geom is MultiMeshInstance3D and (geom as MultiMeshInstance3D).multimesh != null:
			mesh = (geom as MultiMeshInstance3D).multimesh.mesh
		elif geom is MeshInstance3D:
			mesh = (geom as MeshInstance3D).mesh
		if mesh != null:
			for s in mesh.get_surface_count():
				var own := mesh.surface_get_material(s)
				if own is BaseMaterial3D:
					return own
	for child in p_node.get_children():
		var m: Variant = _first_material(child, p_depth + 1, p_multimesh_only)
		if m != null:
			return m
	return null


## Write the sidecar beside `p_recording_path`. JSON rather than ConfigFile
## because the payload is one flat map of thousands of short entries, which is
## what JSON is smallest and fastest at; the file is never hand-edited.
static func write_colors(p_recording_path: String, p_colors: Dictionary,
		p_sample_name: String, p_materials := {}, p_material_default := {}) -> bool:
	var encoded := {}
	for key in p_colors:
		encoded[key] = (p_colors[key] as Color).to_html(true)
	var doc := {
		"format": VISUAL_FORMAT,
		"sample": p_sample_name,
		"colors": encoded,
	}
	# Written only when there is something to say -- see `materials_of`. An
	# absent key and an empty one read the same, so this costs a v1 reader
	# nothing either way.
	if not p_material_default.is_empty():
		doc["material_default"] = p_material_default
	if not p_materials.is_empty():
		doc["materials"] = p_materials
	var f := FileAccess.open(visual_path(p_recording_path), FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(doc))
	f.close()
	return true


## Write a whole capture -- albedo table and material table together. What
## `stop()` calls; `write_colors` remains the albedo-only entry point.
##
## THE NUMBERS THIS EXISTS FOR (F-045). The replay renderer's lit shader is a
## fixed ROUGHNESS 0.85 / SPECULAR 0.35 / metallic 0
## (godot/src/box3d_replay_renderer.cpp, `ensure_material`). The Car's live
## materials are not: the chassis is roughness 0.35, metallic 0.25, specular 0.5
## and reads as automotive paint, the wheels are roughness 0.8, and the terrain
## is roughness 1.0 with `metallic_specular` driven to 0.0 so the ground has no
## sheen at all. Albedo alone cannot express any of that -- a metallic 0.25
## chassis rendered at metallic 0 is a different-coloured object under the same
## light -- so the numbers are captured now, ahead of a renderer that can take
## them, and the file is version 2 because of it.
static func write_visuals(p_recording_path: String, p_visuals: Dictionary,
		p_sample_name: String) -> bool:
	var material_default := material_default_of(p_visuals)
	return write_colors(p_recording_path, colors_of(p_visuals), p_sample_name,
		materials_of(p_visuals, material_default), material_default)


## Read a sidecar back as `{ "index:generation": Color }`, or an empty
## Dictionary for a recording that has none. Every failure is silent and lands
## on the same empty result, because "no sidecar" is a supported state and not
## an error: a recording made before this feature, or one made by upstream's
## own tooling, must open and play exactly as it always did.
static func load_colors(p_recording_path: String) -> Dictionary:
	var out := {}
	var path := visual_path(p_recording_path)
	if not FileAccess.file_exists(path):
		return out
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		return out
	var doc: Variant = JSON.parse_string(text)
	if typeof(doc) != TYPE_DICTIONARY:
		return out
	var colors: Variant = (doc as Dictionary).get("colors", null)
	if typeof(colors) != TYPE_DICTIONARY:
		return out
	for key in (colors as Dictionary):
		var value: Variant = (colors as Dictionary)[key]
		if typeof(value) == TYPE_STRING and Color.html_is_valid(value):
			out[String(key)] = Color.html(value)
	return out


## Read the v2 material table back as `{ "index:generation":
## {"roughness","metallic","specular"} }`. A v1 sidecar, a v2 one whose scene
## was all default materials, and no sidecar at all every land on the same empty
## Dictionary -- which is the compatibility promise, not a swallowed error.
##
## Only bodies whose response DIFFERS from Godot's defaults are in here, so a
## consumer must treat a missing key as "the defaults", never as "no material".
static func load_materials(p_recording_path: String) -> Dictionary:
	var out := {}
	var path := visual_path(p_recording_path)
	if not FileAccess.file_exists(path):
		return out
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		return out
	var doc: Variant = JSON.parse_string(text)
	if typeof(doc) != TYPE_DICTIONARY:
		return out
	var mats: Variant = (doc as Dictionary).get("materials", null)
	var fallback: Variant = (doc as Dictionary).get("material_default", null)
	var has_mats := typeof(mats) == TYPE_DICTIONARY
	var has_fallback := typeof(fallback) == TYPE_DICTIONARY
	if not has_mats and not has_fallback:
		return out
	# The hoisted default is expanded back out here rather than left for every
	# caller to remember: what comes out of this function is a straight
	# per-body table, and only the bytes on disk know the majority trick.
	if has_fallback:
		var colors: Variant = (doc as Dictionary).get("colors", null)
		if typeof(colors) == TYPE_DICTIONARY:
			var expanded := _decode_material(fallback as Dictionary)
			for key in (colors as Dictionary):
				out[String(key)] = expanded.duplicate()
	if has_mats:
		for key in (mats as Dictionary):
			var value: Variant = (mats as Dictionary)[key]
			if typeof(value) == TYPE_DICTIONARY:
				out[String(key)] = _decode_material(value as Dictionary)
	return out


static func _decode_material(p_entry: Dictionary) -> Dictionary:
	return {
		"roughness": float(p_entry.get("r", DEFAULT_ROUGHNESS)),
		"metallic": float(p_entry.get("m", DEFAULT_METALLIC)),
		"specular": float(p_entry.get("s", DEFAULT_SPECULAR)),
	}


static func last_path() -> String:
	var layout := ConfigFile.new()
	if layout.load(LAYOUT_PATH) != OK:
		return ""
	# has_section_key first: a null default makes ConfigFile log an engine error
	# for any file that lacks the section.
	if not layout.has_section_key(LAYOUT_SECTION, LAYOUT_KEY):
		return ""
	var path := str(layout.get_value(LAYOUT_SECTION, LAYOUT_KEY))
	# A remembered path whose file is gone is worse than no memory at all: the
	# button would offer a replay that cannot open.
	return path if FileAccess.file_exists(path) else ""
