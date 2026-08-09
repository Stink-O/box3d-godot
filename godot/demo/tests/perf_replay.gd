extends Node

## F-R4's acceptance bar, as a rig rather than a claim. Records Cube Pile with a
## bomb in the middle, then measures forward play, backward play and random
## scrub through `ReplayTimeline` exactly as the shell drives them.
##
##     Godot --headless --path godot/demo res://tests/perf_replay.tscn
##     ... -- --sweep     also sweeps the keyframe interval, which is how the
##                        ring was shown NOT to be the lever at this scale
##     ... -- --keep      leave the recording behind for a second run
##     ... -- --huge      record HUGE PYRAMID collapsing instead of Cube Pile:
##                        16,290 shapes, which is the case that overran the
##                        96 MB cache budget and the one F-R5's delta encoding
##                        was measured against. Its recording is kept under a
##                        name of its own, so --huge --keep is worth using.
##     ... -- --frames=N  record N frames instead of the default. F-050 was
##                        reported on ~1200, four times what fits in the budget.
##     ... -- --diag      F-050's repro: index to exhaustion, then ask what a
##                        frame costs and where it came from (memory or disk).
##     ... -- --wait      F-050's interaction half: ask for a frame nothing has
##                        simulated yet and time EVERY `_process` on the way
##                        there. The WORST SINGLE TICK is the answer -- that is
##                        how long the window is unresponsive for -- and the
##                        total is honest work with a progress readout on it.
##
## This is a measurement, not a test: it prints numbers and asserts nothing.
## The mechanism it measures is asserted in `test_features.gd`.
##
## Baseline it was written against (Linux template_debug, 4097 replayed shapes,
## 400 recorded frames), before the frame cache and after:
##
##     forward play, first pass       8.9 ms  ->   8.4 ms
##     forward play, second pass      8.9 ms  ->   0.04 ms
##     backward play, played range  148.9 ms  ->   0.04 ms
##     backward play, cold           79.4 ms  ->   8.7 ms  (0.04 ms indexed)
##     random scrub                 352.4 ms  ->   0.04 ms indexed
##
## F-R5 changed what a cached frame COSTS rather than what it costs to reach, so
## the timings above stand and these are the numbers to watch (same recordings,
## same machine):
##
##     Cube Pile   4,097 shapes  401 frames  131 KB -> 81 KB a frame, 50 -> 31 MB
##     Huge Pyramid 16,290 shapes 301 frames 521 KB -> 328 KB a frame,
##                  149.6 MB and TRUNCATED at 188 frames -> 94.1 MB, whole
##     backward play after the index pass  0.08 ms (Cube Pile) / 0.32 ms (pyramid)
##
## F-050 changed how much of a recording is REACHABLE rather than what a
## reachable frame costs, so those stand too. On the reported case -- Huge
## Pyramid, 1200 frames, `--huge --frames=1200`:
##
##     frames indexed   306 of 1201  ->  1200 of 1201 (95.7 MB memory, 279.6 disk)
##     seek 600 past the band  6,139 ms  ->  0.55 ms
##     backward play past it   818 ms mean / 12,355 max  ->  0.69 / 1.50
##     backward play inside it 0.33 ms mean  ->  0.35 ms mean (unchanged)
##     RSS                     425.6 MB  ->  443.9 MB
##
## It writes ONE recording under a name of its own and deletes it again unless
## --keep is passed; nothing else under user://recordings is touched.

const REC_PATH := "user://recordings/_perf_replay_tmp.b3rec"
const SETTLE_FRAMES := 120
const TOTAL_FRAMES := 400
const SAMPLE_N := 120

## --huge. Huge Pyramid is 16,290 boxes, so a recorded frame is four times a
## Cube Pile one; 240 frames is enough to hold a settled stack, the blast and
## the collapse, which is the shape of content the cache has to survive.
const HUGE_REC_PATH := "user://recordings/_perf_replay_huge.b3rec"
const HUGE_SETTLE_FRAMES := 60
const HUGE_TOTAL_FRAMES := 300
const HUGE_SAMPLE_N := 60
## Steps run BEFORE recording starts, so the recording begins on a stack that
## is standing and ASLEEP -- which is how a user meets this sample. A recording
## that opens on 16,000 bodies still settling from their construction poses is
## not the case the cache has to survive.
const HUGE_PRESETTLE := 300

var _huge := false
var _frames := 0


func _ready() -> void:
	await get_tree().process_frame
	await _run()
	get_tree().quit()


func _rec_path() -> String:
	if not _huge:
		return REC_PATH
	if _frames > 0:
		return HUGE_REC_PATH.replace(".b3rec", "_%d.b3rec" % _frames)
	return HUGE_REC_PATH


func _total_frames() -> int:
	if _frames > 0:
		return _frames
	return HUGE_TOTAL_FRAMES if _huge else TOTAL_FRAMES


func _sample_n() -> int:
	return HUGE_SAMPLE_N if _huge else SAMPLE_N


## `--frames=N`, so the rig can record the LENGTH a user actually made rather
## than the length that happened to fit. F-050 was reported on ~1200 frames.
func _read_frames_arg() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--frames="):
			_frames = int(a.substr("--frames=".length()))


func _run() -> void:
	if OS.get_cmdline_user_args().has("--car"):
		await _car_materials()
		return
	_huge = OS.get_cmdline_user_args().has("--huge")
	_read_frames_arg()
	var t0 := Time.get_ticks_msec()
	if not FileAccess.file_exists(_rec_path()):
		await _record()
	print("[perf] recording ready in %d ms" % (Time.get_ticks_msec() - t0))
	if OS.get_cmdline_user_args().has("--wait"):
		_wait_diag()
		if not OS.get_cmdline_user_args().has("--keep"):
			DirAccess.remove_absolute(_rec_path())
		return
	if OS.get_cmdline_user_args().has("--diag"):
		_diag()
		if not OS.get_cmdline_user_args().has("--keep"):
			DirAccess.remove_absolute(_rec_path())
		return
	_measure()
	if not OS.get_cmdline_user_args().has("--keep"):
		DirAccess.remove_absolute(_rec_path())
		print("[perf] removed %s" % _rec_path())


## F-045's renderer half, checked on the case the colour agent documented: the
## Car's chassis is roughness 0.35 / metallic 0.25 / specular 0.50, which is not
## the renderer's own 0.85 / 0 / 0.35, so if the table reaches the renderer the
## difference is visible and if it does not, nothing is.
##
##     Godot --headless --path godot/demo res://tests/perf_replay.tscn -- --car
func _car_materials() -> void:
	var path := "user://recordings/_perf_replay_car.b3rec"
	var inst: Node = load("res://samples/car.tscn").instantiate()
	add_child(inst)
	var world = inst.get_node("Box3DWorld")
	world.auto_step = false
	await get_tree().process_frame
	var rec := ShellRecorder.new()
	if not rec.start(world, "Car", 0):
		push_error("[perf] car recording refused")
		return
	for i in 40:
		world.step(1.0 / 60.0)
	rec.stop(path)
	rec.flush_save()  # F-048: the write is backgrounded; the rig needs the file
	inst.queue_free()
	await get_tree().process_frame

	var host := Node3D.new()
	add_child(host)
	var bar := ReplayTimeline.new()
	bar.auto_pregen = false
	add_child(bar)
	if not bar.open_recording(path, host):
		push_error("[perf] could not open the car recording")
		return
	var rr := bar.get_renderer()
	var table: Dictionary = rr.get_body_material_overrides()
	print("[perf] car: sidecar materials %d, renderer table %d, shapes %d, instances %d"
		% [bar.get_material_override_count(), table.size(), rr.get_shape_count(),
			rr.get_instance_count()])
	var chassis := {}
	for k in table:
		var e: Dictionary = table[k]
		if absf(float(e.get("metallic", 0.0)) - 0.25) < 0.001:
			chassis = e
	print("[perf] car: chassis entry %s (want roughness 0.35 metallic 0.25 specular 0.5)"
		% [chassis])
	# The cached path has to carry it too: the material is per slot, so a frame
	# served from the cache must draw the same instances with the same table.
	bar.seek_to(10)
	var live := rr.get_instance_count()
	bar.seek_to(11)
	var served: bool = rr.draw_cached_frame(10)
	print("[perf] car: cached frame served=%s instances %d vs %d, table still %d"
		% [served, rr.get_instance_count(), live, rr.get_body_material_overrides().size()])
	bar.close_recording()
	DirAccess.remove_absolute(path)


func _record() -> void:
	var path := "res://samples/huge_pyramid.tscn" if _huge else "res://samples/cube_pile.tscn"
	var scene: PackedScene = load(path)
	var inst: Node = scene.instantiate()
	add_child(inst)
	var world = inst.get_node("Box3DWorld")
	world.auto_step = false
	await get_tree().process_frame

	var total := _total_frames()
	var settle := HUGE_SETTLE_FRAMES if _huge else SETTLE_FRAMES
	if _huge:
		for i in HUGE_PRESETTLE:
			world.step(1.0 / 60.0)
	# ~130 KB a recorded frame at Huge Pyramid's 16,290 bodies, so the capacity
	# has to follow --frames or the buffer spends the session reallocating.
	var cap := (1 << 22)
	if _huge:
		cap = maxi(1 << 26, total * 200 * 1024)
	var rec := Box3DRecording.create(cap)
	if not world.start_recording(rec):
		push_error("[perf] start_recording refused")
		return
	for i in total:
		if i == settle:
			if _huge:
				# Crater the base so the whole stack comes down: the settled
				# half of the recording is what delta encoding is cheap on, the
				# collapse is what it has to pay for.
				world.explode(Vector3(0, 2.0, 0), 40.0, 8000.0, 0.0)
			else:
				world.explode(Vector3(0, 1.0, 0), 12.0, 220.0, 0.0)
		world.step(1.0 / 60.0)
	world.stop_recording()
	DirAccess.make_dir_recursive_absolute("user://recordings")
	rec.save_to_file(_rec_path())
	print("[perf] recorded %d frames, %.1f MiB" % [total,
		float(rec.get_size()) / (1024.0 * 1024.0)])
	inst.queue_free()
	await get_tree().process_frame


## Resident set size in MiB, read straight from the kernel. Godot's own memory
## monitors count Godot allocations; the frame cache and the keyframe ring are
## malloc'd by the extension and by box3d, so only RSS sees all of it.
func _rss_mib() -> float:
	var f := FileAccess.open("/proc/self/status", FileAccess.READ)
	if f == null:
		return -1.0
	while not f.eof_reached():
		var line := f.get_line()
		if line.begins_with("VmRSS:"):
			return float(line.split(":")[1].strip_edges().split(" ")[0]) / 1024.0
	return -1.0


## F-050's repro, and the number it has to move. Opens the recording, lets the
## index pass run itself out, then asks what a frame costs INSIDE the window it
## managed to hold and OUTSIDE it. `--diag` prints; it asserts nothing.
func _diag() -> void:
	var host := Node3D.new()
	add_child(host)
	var bar := ReplayTimeline.new()
	bar.auto_pregen = false
	add_child(bar)
	var rss_open := _rss_mib()
	if not bar.open_recording(_rec_path(), host):
		push_error("[perf] could not open %s" % _rec_path())
		return
	var n := bar.get_frame_count()
	var p := bar.get_player()
	var rr := bar.get_renderer()
	print("[diag] %d frames, %d instances, cache budget %.0f MiB, keyframe ring budget %.0f MiB"
		% [n, rr.get_instance_count(), float(rr.frame_cache_budget) / 1048576.0,
			float(p.get_keyframe_budget()) / 1048576.0])

	# Where the index pass's per-frame cost actually goes: the solver re-step,
	# the draw walk, or the encoder.
	var t_step := 0
	for i in 40:
		var t := Time.get_ticks_usec()
		p.step_frame()
		t_step += Time.get_ticks_usec() - t
	var t_pf := 0
	for i in 40:
		p.step_frame()
		var t := Time.get_ticks_usec()
		rr.prefetch_frame(p.get_frame())
		t_pf += Time.get_ticks_usec() - t
	print("[diag] per frame: step_frame %.2f ms, prefetch_frame %.2f ms"
		% [float(t_step) / 40000.0, float(t_pf) / 40000.0])
	# The worst single solver step in the recording, which is the floor under
	# every "how long can one tick be" answer -- no amount of caching makes a
	# frame that has never been simulated cheaper than simulating it.
	var worst_step := 0
	var worst_at := 0
	p.seek_frame(0)
	for i in mini(160, n):
		var t := Time.get_ticks_usec()
		p.step_frame()
		var us := Time.get_ticks_usec() - t
		if us > worst_step:
			worst_step = us
			worst_at = p.get_frame()
	print("[diag] worst solver step over the first %d frames: %.1f ms at frame %d"
		% [mini(160, n), float(worst_step) / 1000.0, worst_at])
	rr.clear_frame_cache()
	p.seek_frame(0)

	var t_index := Time.get_ticks_msec()
	var slices := 0
	bar._pregen = true
	bar._idle_frames = ReplayTimeline.PREGEN_IDLE_FRAMES
	while bar._pregen and slices < 100000:
		bar._run_pregen_slice()
		slices += 1
	var index_ms := Time.get_ticks_msec() - t_index
	var runs := bar.get_cached_runs()
	print("[diag] index pass: %d slices, %d ms, stopped with player at frame %d"
		% [slices, index_ms, p.get_frame()])
	print("[diag] cache: %d of %d frames (%d resident), %.1f MiB memory, %.1f MiB disk, runs %s"
		% [bar.get_cached_frame_count(), n + 1, rr.get_resident_frame_count(),
			float(bar.get_frame_cache_bytes()) / 1048576.0,
			float(rr.get_frame_cache_disk_bytes()) / 1048576.0, runs])
	print("[diag] spill: path=%s writes %d reads %d, indexed through %d"
		% [rr.frame_cache_spill_path, rr.get_spill_write_count(),
			rr.get_spill_read_count(), rr.get_indexed_through()])
	print("[diag] keyframes: effective interval %d, ring %.1f MiB"
		% [p.get_keyframe_interval(), float(p.get_keyframe_bytes()) / 1048576.0])
	print("[diag] RSS %.1f MiB (%.1f MiB before opening)" % [_rss_mib(), rss_open])

	# What a frame costs at each fifth of the recording -- which after F-050 is
	# a question about where the chunk lives, not about how far the player has
	# to re-simulate.
	var edge := 0
	if runs.size() > 0:
		edge = int(runs[runs.size() - 1].y)
	print("[diag] coverage ends at frame %d of %d" % [edge, n])
	for f in [1, int(n * 0.25), int(n * 0.5), int(n * 0.75), n - 1, int(n * 0.4), n / 2]:
		var reads0: int = rr.get_spill_read_count()
		var t := Time.get_ticks_usec()
		bar.seek_to(f)
		var us := Time.get_ticks_usec() - t
		print("[diag]   seek to %5d : %9.2f ms  cached=%s  disk reads %d"
			% [f, float(us) / 1000.0, bar.was_last_frame_cached(),
				rr.get_spill_read_count() - reads0])
	# Sustained backward play at four points, which is the acceptance bar: it
	# must be cheap EVERYWHERE, not only inside the memory window.
	for start in [n - 1, int(n * 0.75), int(n * 0.5), int(n * 0.25)]:
		bar.seek_to(start)
		var reads0: int = rr.get_spill_read_count()
		var s := _run_dir(bar, -1, 60)
		s.sort()
		var tot := 0
		for v in s:
			tot += v
		print("[diag] backward x60 from %5d : mean %7.2f ms  median %7.2f ms  p95 %7.2f ms  max %7.2f ms  cached %d/60  disk reads %d"
			% [start, float(tot) / 60.0 / 1000.0, float(s[30]) / 1000.0,
				float(s[57]) / 1000.0, float(s[59]) / 1000.0, _cached_hits,
				rr.get_spill_read_count() - reads0])
	var reads1: int = rr.get_spill_read_count()
	_report("random scrub (60 seeks over the whole recording)", _scrub(bar, n, 60))
	print("[diag] random scrub used %d disk reads" % [rr.get_spill_read_count() - reads1])
	print("[diag] RSS at end %.1f MiB, disk %.1f MiB, memory %.1f MiB"
		% [_rss_mib(), float(rr.get_frame_cache_disk_bytes()) / 1048576.0,
			float(bar.get_frame_cache_bytes()) / 1048576.0])
	bar.close_recording()
	print("[diag] after close: spill file still present = %s"
		% FileAccess.file_exists("user://replay_cache/replay_%d.b3fc" % OS.get_process_id()))
	bar.queue_free()
	host.queue_free()


## THE INTERACTION HALF of F-050, measured the way it is felt: open the
## recording cold, ask for a frame deep in territory nothing has simulated yet,
## and time EVERY `_process` the bar runs on the way there. The number that
## matters is the worst single one -- that is how long the window is
## unresponsive for -- not the total, which is honest work with a progress
## readout on it.
##
##     Godot --headless --path godot/demo res://tests/perf_replay.tscn \
##         -- --huge --frames=1200 --wait
func _wait_diag() -> void:
	var host := Node3D.new()
	add_child(host)
	var bar := ReplayTimeline.new()
	add_child(bar)
	if not bar.open_recording(_rec_path(), host):
		push_error("[wait] could not open %s" % _rec_path())
		return
	var n := bar.get_frame_count()
	var target := int(n * 0.75)
	print("[wait] %d frames, asking for %d with %d indexed"
		% [n, target, bar.get_indexed_through()])
	var t0 := Time.get_ticks_msec()
	bar.seek_to(target)
	print("[wait] the seek call itself returned in %d ms, waiting for %d, showing %d"
		% [Time.get_ticks_msec() - t0, bar.get_wait_frame(), bar.get_shown_frame()])
	var worst := 0
	var worst_at := 0
	var ticks := 0
	var total := 0
	var over_100 := 0
	while bar.get_wait_frame() >= 0 and ticks < 20000:
		var t := Time.get_ticks_usec()
		bar._process(1.0 / 60.0)
		var us := Time.get_ticks_usec() - t
		total += us
		ticks += 1
		if us > worst:
			worst = us
			worst_at = bar.get_shown_frame()
		if us > 100000:
			over_100 += 1
	print("[wait] arrived at %d after %d ticks / %.1f s of work"
		% [bar.get_frame(), ticks, float(total) / 1e6])
	print("[wait] WORST SINGLE TICK %.1f ms (at frame %d); ticks over 100 ms: %d; mean %.1f ms"
		% [float(worst) / 1000.0, worst_at, over_100, float(total) / float(maxi(ticks, 1)) / 1000.0])
	print("[wait] shown=%d display=%d cached through %d, %d frames cached"
		% [bar.get_shown_frame(), bar.get_frame(), bar.get_indexed_through(),
			bar.get_cached_frame_count()])
	# And the second visit, which is the point of paying for the first.
	var t2 := Time.get_ticks_usec()
	bar.seek_to(int(n * 0.3))
	var a := Time.get_ticks_usec() - t2
	t2 = Time.get_ticks_usec()
	bar.seek_to(target)
	print("[wait] afterwards: seek to %d %.2f ms, back to %d %.2f ms"
		% [int(n * 0.3), float(a) / 1000.0, target,
			float(Time.get_ticks_usec() - t2) / 1000.0])
	bar.close_recording()
	bar.queue_free()
	host.queue_free()


func _measure() -> void:
	var host := Node3D.new()
	add_child(host)
	var bar := ReplayTimeline.new()
	bar.auto_pregen = false
	add_child(bar)
	if not bar.open_recording(_rec_path(), host):
		push_error("[perf] could not open %s" % _rec_path())
		return
	var n := bar.get_frame_count()
	print("[perf] opened %d frames, keyframe interval %d, ring %.1f MiB"
		% [n, bar.get_player().get_keyframe_interval(),
			float(bar.get_player().get_keyframe_bytes()) / (1024.0 * 1024.0)])
	var rr := bar.get_renderer()
	var drawn := rr.get_instance_count()
	print("[perf] geometries=%d shapes=%d instances=%d"
		% [rr.get_geometry_count(), rr.get_shape_count(), drawn])

	# --- cold forward play, frame 1 -> SAMPLE_N -----------------------------
	bar.seek_to(0)
	var fwd_cold := _run_dir(bar, 1, _sample_n())
	_report("forward play (cold, ring empty)", fwd_cold)

	# --- backward play from where forward stopped ---------------------------
	var bwd_warm := _run_dir(bar, -1, _sample_n())
	_report("backward play (right after forward over the same frames)", bwd_warm)

	# --- backward play over a range never played forward --------------------
	bar.seek_to(n - 1)
	var bwd_cold := _run_dir(bar, -1, _sample_n())
	_report("backward play (cold, from the last frame)", bwd_cold)

	# --- forward play a SECOND time over the same range ----------------------
	bar.seek_to(0)
	_report("forward play (second pass over frames already shown)",
		_run_dir(bar, 1, _sample_n()))

	# --- random scrub -------------------------------------------------------
	_report("random scrub (40 seeks, only the played range indexed)",
		_scrub(bar, n, 40))

	# --- the shipped path: let the index pass finish -------------------------
	var t_index := Time.get_ticks_msec()
	var passes := 0
	bar._pregen = true
	bar._idle_frames = ReplayTimeline.PREGEN_IDLE_FRAMES
	while bar._pregen and passes < 20000:
		bar._run_pregen_slice()
		passes += 1
	var cached := bar.get_cached_frame_count()
	var cbytes := bar.get_frame_cache_bytes()
	print("[perf] index+prefetch pass: %d slices, %d ms of work, %d frames cached, %.1f MiB"
		% [passes, Time.get_ticks_msec() - t_index, cached,
			float(cbytes) / (1024.0 * 1024.0)])
	# THE BUDGET VERDICT, which is what F-R5 is about. bytes/frame is the number
	# to compare across encodings; "whole recording" is the acceptance bar.
	var per_frame := float(cbytes) / float(maxi(cached, 1))
	print("[perf] cache: %d of %d frames (%s), %.0f B/frame, %d instances/frame, %.2f B/instance/frame, projected whole = %.1f MiB vs %.0f MiB budget"
		% [cached, n + 1, "WHOLE RECORDING" if cached >= n + 1 else "TRUNCATED -- over budget",
			per_frame, drawn,
			per_frame / float(maxi(drawn, 1)),
			per_frame * float(n + 1) / (1024.0 * 1024.0),
			float(rr.frame_cache_budget) / (1024.0 * 1024.0)])
	_report("random scrub (40 seeks, after the index pass)", _scrub(bar, n, 40))
	bar.seek_to(n - 1)
	_report("backward play (after the index pass)", _run_dir(bar, -1, _sample_n()))

	_verify(bar, n)

	if OS.get_cmdline_user_args().has("--sweep"):
		_sweep(bar, n)

	bar.close_recording()


## Where does a backward seek's time actually go: the keyframe restore, or the
## re-step of the gap? Vary the ring spacing and read the slope.
func _sweep(bar: ReplayTimeline, n: int) -> void:
	var p := bar.get_player()
	for interval in [1, 2, 4, 8, 16, 32]:
		p.set_keyframe_policy(96 << 20, interval)
		# Warm the ring over the range we are about to walk backward.
		bar.seek_to(n - 1)
		var s := _run_dir(bar, -1, 30)
		s.sort()
		var tot := 0
		for v in s:
			tot += v
		print("[perf] sweep interval req %2d -> effective %2d, ring %5.1f MiB : backward mean %7.2f ms  min %7.2f ms"
			% [interval, p.get_keyframe_interval(),
				float(p.get_keyframe_bytes()) / (1024.0 * 1024.0),
				float(tot) / float(s.size()) / 1000.0, float(s[0]) / 1000.0])
	p.set_keyframe_policy(96 << 20, ReplayTimeline.KEYFRAME_MIN_INTERVAL)


## How many of the sampled frames came out of the cache.
var _cached_hits := 0


func _run_dir(bar: ReplayTimeline, dir: int, count: int) -> Array[int]:
	var out: Array[int] = []
	_cached_hits = 0
	for i in count:
		var t := Time.get_ticks_usec()
		bar.step_by(dir)
		out.append(Time.get_ticks_usec() - t)
		if bar.was_last_frame_cached():
			_cached_hits += 1
	return out


func _scrub(bar: ReplayTimeline, n: int, count: int) -> Array[int]:
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345
	var out: Array[int] = []
	_cached_hits = 0
	for i in count:
		var t := Time.get_ticks_usec()
		bar.seek_to(rng.randi_range(0, n - 1))
		out.append(Time.get_ticks_usec() - t)
		if bar.was_last_frame_cached():
			_cached_hits += 1
	return out


## Does a cached frame actually reproduce the frame it was captured from? Draw
## frame k live, read every instance, then reach it from the cache and compare.
func _verify(bar: ReplayTimeline, n: int) -> void:
	var rr := bar.get_renderer()
	var frame := n / 2
	# Live: force the player there and draw from the world.
	rr.clear_frame_cache()
	bar.seek_to(frame)
	var live: Array[Transform3D] = []
	var live_col: Array[Color] = []
	for g in rr.get_geometry_count():
		var info: Dictionary = rr.get_geometry_info(g)
		for i in int(info["instances"]):
			live.append(rr.get_instance_transform(g, i))
			live_col.append(rr.get_instance_color(g, i))
	# Cached: the frame is in the cache now (seek_to captured it); walk away and
	# come back through the cache.
	bar.seek_to(frame + 1)
	var served: bool = rr.draw_cached_frame(frame)
	var worst := 0.0
	var colour_ok := true
	var k := 0
	for g in rr.get_geometry_count():
		var info: Dictionary = rr.get_geometry_info(g)
		for i in int(info["instances"]):
			if k >= live.size():
				break
			var t: Transform3D = rr.get_instance_transform(g, i)
			worst = maxf(worst, (t.origin - live[k].origin).length())
			for axis in 3:
				worst = maxf(worst, (t.basis[axis] - live[k].basis[axis]).length())
			if rr.get_instance_color(g, i) != live_col[k]:
				colour_ok = false
			k += 1
	print("[perf] cached frame %d served=%s over %d instances: worst component error %.9f, colours exact=%s"
		% [frame, served, k, worst, colour_ok])


func _report(label: String, samples: Array[int]) -> void:
	if samples.is_empty():
		return
	var sorted := samples.duplicate()
	sorted.sort()
	var total := 0
	for v in samples:
		total += v
	var mean := float(total) / float(samples.size())
	var median := float(sorted[sorted.size() / 2])
	var p95 := float(sorted[mini(sorted.size() - 1, int(sorted.size() * 0.95))])
	print("[perf] %-56s mean %8.2f ms   median %8.2f ms   p95 %8.2f ms   max %8.2f ms"
		% [label, mean / 1000.0, median / 1000.0, p95 / 1000.0,
			float(sorted[sorted.size() - 1]) / 1000.0])
	print("[perf]     %d of %d frames served from the cache" % [_cached_hits, samples.size()])
