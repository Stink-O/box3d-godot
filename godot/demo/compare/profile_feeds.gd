class_name ProfileFeeds
extends RefCounted

## Profiler data sources for the three-engine comparison harness (SPEC B).
##
## One panel, three sources. A feed only answers "here are my rows" and "here
## are this tick's numbers, in milliseconds"; every ring buffer, average and
## pixel belongs to the panel.
##
## All of it lives in this one file because GDScript allows exactly one
## `class_name` per file and the three feeds have to share things: the row
## helper, upstream's colour set, and — for the two native feeds — a SINGLE
## EngineProfiler tap on the "servers" channel, which may only be registered
## once per process. Inner classes are reachable from outside as
## `ProfileFeeds.Box3DFeed`, `ProfileFeeds.ProfileFeed`, and so on; the file
## statics and the factory sit at the bottom, after the classes they build.
##
## Readiness. SPEC B says `rows()` is "called once after the feed reports
## ready" but the frozen interface has no readiness call, so this file adds one
## — `is_ready()`, additive, never replacing anything. It is true from
## construction for every feed that can settle its row set up front; only the
## Jolt feed starts false, because its rows are discovered from the first
## payload rather than authored. Contract:
##
##   * while `is_ready()` is false, `rows()` is empty and `sample()` skips;
##   * the tick a feed becomes ready, `rows()` is final and never changes again;
##   * `sample()` always returns either nothing or exactly `rows().size()`
##     values, so a panel that refetches rows whenever the lengths disagree
##     self-heals.
##
## Usage:
##   var feed := ProfileFeeds.make("box3d", world)   # or "godot" / "jolt"


## Abstract base. See SPEC B; every method here is overridden by at least one
## feed, and the defaults are the "I have nothing" answers.
class ProfileFeed extends RefCounted:
	# Upstream's profiler palette (samples/sample.cpp, 0-255 in the comments) so
	# the Box3D panel and the native panels read as the same instrument.
	const COLOR_STEP := Color(0.4, 0.6, 1.0)                    ## 102,153,255
	const COLOR_DEFAULT := Color(0.862745, 0.862745, 0.862745)  ## 220,220,220
	const COLOR_COLLIDE := Color(1.0, 0.549020, 0.2)            ## 255,140,51
	const COLOR_SOLVE := Color(0.4, 0.8, 0.4)                   ## 102,204,102
	const COLOR_SENSORS := Color(0.784314, 0.470588, 0.862745)  ## 200,120,220

	## Stable row definitions, in display order. Empty until `is_ready()`.
	func rows() -> Array:
		return []

	## One value per row, same order and length as rows(), in MILLISECONDS.
	## Called exactly once per physics tick; empty means "skip this tick".
	func sample() -> PackedFloat32Array:
		return PackedFloat32Array()

	## Simulation size counters, free-form label -> int.
	func counters() -> Dictionary:
		return {}

	func engine_name() -> String:
		return ""

	## Proof string naming the actual data source, shown under the title.
	func source_proof() -> String:
		return ""

	## False when the feed can only supply a total step time.
	func has_phases() -> bool:
		return false

	## Row indices forming the flame strip, left to right. Mutually disjoint
	## children of the step row; empty disables the strip.
	func flame_rows() -> PackedInt32Array:
		return PackedInt32Array()

	## Additive readiness signal (see the file header).
	func is_ready() -> bool:
		return true

	func _mk_row(label: String, indent: int, color: Color) -> Dictionary:
		return {"label": label, "indent": indent, "color": color}


## Box3D: 22 rows cloned from upstream's Profile drawer.
##
## `Box3DWorld.get_profile()` / `get_counters()` are newer bindings than
## `get_step_time_ms()`, so this probes for them rather than assuming: an older
## libbox3d_godot still yields a usable single-row step feed instead of a
## crash.
class Box3DFeed extends ProfileFeed:
	## b3Profile field names in DISPLAY order, which is deliberately not struct
	## order: rows 19/20 put sleepIslands ahead of bullets, and sensorHits is
	## not shown at all. Cloned from samples/sample.cpp so the Box3D panel and
	## upstream's can be read row for row.
	const FIELDS := [
		"step", "pairs", "collide", "solve",
		"solverSetup", "constraints",
		"prepareConstraints", "integrateVelocities", "warmStart", "solveImpulses",
		"integratePositions", "relaxImpulses", "applyRestitution", "storeImpulses",
		"splitIslands",
		"transforms", "jointEvents", "hitEvents", "refit", "sleepIslands", "bullets",
		"sensors",
	]
	## Upstream's labels, which rename three fields: solverSetup reads "setup",
	## solveImpulses reads "bias" (it is the biased-impulse pass) and
	## sleepIslands reads "sleep".
	const LABELS := [
		"step", "pairs", "collide", "solve",
		"setup", "constraints",
		"prepare", "velocities", "warm start", "bias",
		"positions", "relax", "restitution", "store",
		"split islands",
		"transforms", "joint events", "hit events", "refit BVH", "sleep", "bullets",
		"sensors",
	]
	const INDENTS := [
		0, 0, 0, 0,
		1, 1,
		2, 2, 2, 2,
		2, 2, 2, 2,
		2,
		1, 1, 1, 1, 1, 1,
		0,
	]

	## b3Counters fields worth a table row, in display order, with the divisor
	## that turns bytes into K. colorCounts and manifoldCounts are arrays rather
	## than ints, so they have no place in a label -> int table.
	const COUNTERS := [
		["bodyCount", "bodies", 1],
		["shapeCount", "shapes", 1],
		["contactCount", "contacts", 1],
		["jointCount", "joints", 1],
		["islandCount", "islands", 1],
		["awakeContactCount", "awake contacts", 1],
		["recycledContactCount", "recycled contacts", 1],
		["taskCount", "tasks", 1],
		["treeHeight", "tree height", 1],
		["staticTreeHeight", "static tree height", 1],
		["stackUsed", "stack used K", 1024],
		["arenaCapacity", "arena capacity K", 1024],
		["byteCount", "total allocation K", 1024],
	]

	var _world: Node = null
	var _has_profile := false
	var _has_counters := false
	var _has_step_time := false

	func _init(world) -> void:
		_world = world as Node
		if _world == null:
			return
		_has_profile = _world.has_method("get_profile")
		_has_counters = _world.has_method("get_counters")
		_has_step_time = _world.has_method("get_step_time_ms")

	func rows() -> Array:
		if not _has_profile:
			return [_mk_row("step", 0, COLOR_STEP)]
		var out: Array = []
		for i in FIELDS.size():
			out.append(_mk_row(LABELS[i], INDENTS[i], _color_for(i)))
		return out

	func sample() -> PackedFloat32Array:
		var out := PackedFloat32Array()
		if _world == null:
			return out
		if not _has_profile:
			if _has_step_time:
				out.append(float(_world.get_step_time_ms()))
			return out
		# b3Profile values are already milliseconds; the binding forwards them
		# verbatim, keyed by the C field names.
		var p = _world.get_profile()
		if typeof(p) != TYPE_DICTIONARY or p.is_empty():
			return out
		out.resize(FIELDS.size())
		for i in FIELDS.size():
			out[i] = float(p.get(FIELDS[i], 0.0))
		return out

	func counters() -> Dictionary:
		var out := {}
		# The same guard sample() carries, and for the same reason: a feed can
		# outlive its world by a frame when a sample is swapped, and a freed
		# Object compares equal to null but calling into it is a hard crash,
		# not a script error.
		if not _has_counters or _world == null:
			return out
		var c = _world.get_counters()
		if typeof(c) != TYPE_DICTIONARY:
			return out
		for e in COUNTERS:
			if c.has(e[0]):
				out[e[1]] = floori(float(c[e[0]]) / float(e[2]))
		return out

	func engine_name() -> String:
		return "Box3D"

	func source_proof() -> String:
		if _has_profile:
			return "b3World_GetProfile  ·  %d phases" % FIELDS.size()
		return "Box3DWorld.get_step_time_ms  ·  wall clock around b3World_Step, no breakdown"

	func has_phases() -> bool:
		return _has_profile

	func flame_rows() -> PackedInt32Array:
		if not _has_profile:
			return PackedInt32Array()
		# pairs, collide, solve, sensors — upstream's four disjoint children of
		# the step row.
		return PackedInt32Array([1, 2, 3, 21])

	func _color_for(i: int) -> Color:
		match i:
			0:
				return COLOR_STEP
			2:
				return COLOR_COLLIDE
			3:
				return COLOR_SOLVE
			21:
				return COLOR_SENSORS
		return COLOR_DEFAULT


## The one subscriber on the "servers" debugger channel, shared by both native
## feeds. Both GodotPhysics3D and Jolt push their per-phase timings here and
## nowhere else — there is no PhysicsServer3D timing API of any kind.
class ServersTap extends EngineProfiler:
	## Most recent physics_3d payload: phase name -> SECONDS (the panel's
	## consumers convert).
	var frame := {}
	## Phase names in payload order. Jolt's row set is frozen from this.
	var order := PackedStringArray()
	## Bumped once per payload so a feed can tell a fresh tick from a stale one.
	var stamp := 0

	func _toggle(_enable: bool, _options: Array) -> void:
		pass

	func _add_frame(data: Array) -> void:
		# The "servers" channel also carries "physics_2d" (and other server)
		# payloads; only the 3D physics one is ours.
		if data.is_empty() or str(data[0]) != "physics_3d":
			return
		frame.clear()
		order.clear()
		# Flat array: ["physics_3d", name, secs, name, secs, ...].
		var i := 1
		while i + 1 < data.size():
			var key := str(data[i])
			# Jolt can emit the same job name more than once in a step, so sum
			# rather than overwrite or the phase total silently under-reports.
			if frame.has(key):
				frame[key] = float(frame[key]) + float(data[i + 1])
			else:
				frame[key] = float(data[i + 1])
				order.append(key)
			i += 2
		stamp += 1


## Godot 4.7 SIGABRTs during engine teardown if a GDScript-registered
## EngineProfiler is still registered -- silently, with no message and no
## backtrace. It reproduces with any profiler name and with nothing but a bare
## register_profiler() call, so it is the registration itself and not this tap.
##
## Unregistering before shutdown avoids it, which means something has to
## remember to. Leaving that to the harness means a forgotten call turns every
## recorded session into a core dump, so the tap brings its own undertaker: a
## node parked on the scene root whose exit-tree notification fires as the tree
## is torn down at quit.
class TapGuard extends Node:
	func _notification(what: int) -> void:
		if what == NOTIFICATION_EXIT_TREE or what == NOTIFICATION_PREDELETE:
			ProfileFeeds.release_servers_tap()


## Shared machinery for the two native feeds: the tap, the discovery watchdog
## and the wall-clock fallback. Not useful on its own.
class NativeFeed extends ProfileFeed:
	## SPEC B: give the source this many physics ticks to produce something
	## before admitting we only have a wall clock.
	const FALLBACK_TICKS := 120

	var _root: Node = null          ## harness scene root, for body counting
	var _requested := ""            ## the engine the launcher asked for
	var _setting := "DEFAULT"       ## physics/3d/physics_engine, verbatim
	var _tap: ServersTap = null
	var _last_stamp := 0
	var _waited := 0
	var _settled := false
	var _fallback := false

	func _init(root, requested: String, setting: String, tap: ServersTap) -> void:
		_root = root as Node
		_requested = requested
		_setting = setting
		_tap = tap
		if _tap == null:
			# ServersDebugger already owns the name (an editor --remote-debug
			# session). There is no second subscriber slot, so a wall clock is
			# all this run can have; settle now rather than waiting 120 ticks
			# for data that provably cannot arrive.
			_settle_fallback()

	func is_ready() -> bool:
		return _settled

	func has_phases() -> bool:
		return not _fallback

	func sample() -> PackedFloat32Array:
		var out := PackedFloat32Array()
		if _fallback:
			out.append(_wall_clock_ms())
			return out
		var fresh := _take_fresh()
		if not _settled:
			if fresh and not _tap.order.is_empty():
				_settle_phases()
			elif not _channel_live():
				# Provably dead (see _channel_live), so do not spend two seconds
				# of every recording showing "waiting for the first payload".
				_settle_fallback()
				out.append(_wall_clock_ms())
				return out
			else:
				_waited += 1
				if _waited >= FALLBACK_TICKS:
					_settle_fallback()
					out.append(_wall_clock_ms())
				return out
		if not fresh:
			return out
		return _phase_sample()

	func source_proof() -> String:
		if not _settled:
			return "EngineProfiler \"servers\"  ·  waiting for the first payload  ·  " + _setting_line()
		if _fallback:
			return "wall clock only  ·  %s  ·  %s%s" % [
					_fallback_reason(), _setting_line(), _mismatch_note()]
		return "EngineProfiler \"servers\"  ·  %s  ·  %s%s" % [
				_phase_proof(), _setting_line(), _mismatch_note()]

	# --- overridden by the concrete feeds ---

	## Freeze the row set now that a payload has arrived.
	func _settle_phases() -> void:
		_settled = true

	## Build one tick's values from `_tap.frame`.
	func _phase_sample() -> PackedFloat32Array:
		return PackedFloat32Array()

	func _phase_proof() -> String:
		return ""

	# --- shared helpers ---

	func _settle_fallback() -> void:
		_fallback = true
		_settled = true

	## True when the tap holds a payload this feed has not consumed yet.
	func _take_fresh() -> bool:
		if _tap == null or _tap.stamp == _last_stamp:
			return false
		_last_stamp = _tap.stamp
		return true

	## The fallback number. Deliberately labelled "wall clock" and not "solver
	## time": TIME_PHYSICS_PROCESS spans the whole tick — script
	## `_physics_process`, the server step, flush_queries and the message queue
	## — so it reads high. It is the only physics-ish clock GDScript can see
	## when the per-phase channel is silent.
	func _wall_clock_ms() -> float:
		return float(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)) * 1000.0

	## The live project setting, quoted, so a run can never be mislabelled by a
	## launcher whose override.cfg went missing.
	func _setting_line() -> String:
		return "physics/3d/physics_engine = \"%s\"" % _setting

	func _is_jolt_live() -> bool:
		return _setting == "Jolt Physics"

	## Non-empty only when the launcher asked for an engine other than the one
	## this process actually created.
	func _mismatch_note() -> String:
		if _requested != "jolt" and _requested != "godot":
			return ""
		if (_requested == "jolt") == _is_jolt_live():
			return ""
		return "  ·  requested %s (override.cfg missing?)" % _requested

	## Registering a profiler is not the same as enabling one. Measured on 4.7
	## stable: EngineDebugger.profiler_enable() never calls _toggle and never
	## flips is_profiling() unless a debug session is live, and every engine-side
	## emitter is wrapped in is_profiling(), so a false here means no payload can
	## ever arrive. profiler_add_frame_data() still reaches the tap, which is why
	## the plumbing looks fine right up until you wait for data.
	func _channel_live() -> bool:
		return _tap != null and EngineDebugger.is_profiling("servers")

	func _fallback_reason() -> String:
		if _tap == null:
			return "the \"servers\" profiler name is taken (editor debug session)"
		if not _channel_live():
			return "the \"servers\" channel is registered but the engine never " \
					+ "enables it outside a debug session, so nothing is emitted"
		return "no physics_3d payload in %d ticks" % FALLBACK_TICKS


## GodotPhysics3D: 7 fixed rows. The timers run in every build; only the emit is
## gated on the profiler being enabled, so this path works in release templates.
class GodotPhysicsFeed extends NativeFeed:
	## Payload keys, verbatim from godot_physics_server_3d.cpp.
	const PHASES := [
		"integrate_forces", "generate_islands", "setup_constraints",
		"solve_constraints", "integrate_velocities", "flush_queries",
	]
	const LABELS := [
		"integrate forces", "generate islands", "setup constraints",
		"solve constraints", "integrate velocities", "flush queries",
	]
	## Distinct hues, three of them borrowed from upstream's palette, so the
	## flame strip stays readable and the two panels rhyme.
	const PHASE_COLORS := [
		Color(1.0, 0.549020, 0.2),        ## collide orange
		Color(0.35, 0.78, 0.78),
		Color(0.94, 0.78, 0.35),
		Color(0.4, 0.8, 0.4),             ## solve green
		Color(0.47, 0.7, 0.94),
		Color(0.784314, 0.470588, 0.862745),  ## sensors purple
	]

	func rows() -> Array:
		if not _settled:
			return []
		if _fallback:
			return [_mk_row("step", 0, COLOR_STEP)]
		var out: Array = [_mk_row("step", 0, COLOR_STEP)]
		for i in PHASES.size():
			out.append(_mk_row(LABELS[i], 1, PHASE_COLORS[i]))
		return out

	func counters() -> Dictionary:
		return {
			"active objects": int(Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS)),
			"collision pairs": int(Performance.get_monitor(Performance.PHYSICS_3D_COLLISION_PAIRS)),
			"islands": int(Performance.get_monitor(Performance.PHYSICS_3D_ISLAND_COUNT)),
		}

	func engine_name() -> String:
		return "Godot Physics"

	func flame_rows() -> PackedInt32Array:
		# Before the feed settles rows() is empty, so quoting row indices into it
		# would name rows that do not exist yet.
		if _fallback or not _settled:
			return PackedInt32Array()
		return PackedInt32Array([1, 2, 3, 4, 5, 6])

	func _phase_sample() -> PackedFloat32Array:
		var out := PackedFloat32Array()
		out.resize(PHASES.size() + 1)
		# There is no "step" entry in the payload; the six phases ARE the step.
		var total := 0.0
		for i in PHASES.size():
			var ms := float(_tap.frame.get(PHASES[i], 0.0)) * 1000.0
			out[i + 1] = ms
			total += ms
		out[0] = total
		return out

	func _phase_proof() -> String:
		return "%d phases" % PHASES.size()


## Jolt: rows discovered at runtime. Jolt emits per-JOB timings, not named
## phases, and only under DEBUG_ENABLED — so a template_release build produces
## nothing at all here and the feed degrades to the wall clock.
class JoltFeed extends NativeFeed:
	## Panels have finite room and a runaway job list would be unreadable; Jolt's
	## real set is comfortably under this.
	const MAX_PHASES := 31

	var _job_names := PackedStringArray()
	var _job_colors: Array[Color] = []
	var _bodies := 0
	var _bodies_stamp := -1000000

	func rows() -> Array:
		if not _settled:
			return []
		if _fallback:
			return [_mk_row("step", 0, COLOR_STEP)]
		var out: Array = [_mk_row("step", 0, COLOR_STEP)]
		for i in _job_names.size():
			out.append(_mk_row(_job_names[i], 1, _job_colors[i]))
		return out

	func counters() -> Dictionary:
		# JoltPhysicsServer3D::get_process_info() is literally `return 0;`, so
		# all three PHYSICS_3D_* monitors read zero under Jolt. Showing them
		# would be a lie dressed as data; count the scene's bodies instead.
		return {"bodies (Jolt monitors read 0)": _body_count()}

	func engine_name() -> String:
		return "Jolt Physics"

	func flame_rows() -> PackedInt32Array:
		var out := PackedInt32Array()
		if _fallback:
			return out
		for i in _job_names.size():
			out.append(i + 1)
		return out

	func _settle_phases() -> void:
		for job in _tap.order:
			if _job_names.size() >= MAX_PHASES:
				break
			_job_names.append(job)
		# Job names are not known ahead of time, so the palette has to be
		# generated. Golden-ratio hue stepping keeps neighbours distinguishable
		# however many rows turn up.
		for i in _job_names.size():
			_job_colors.append(Color.from_hsv(fmod(float(i) * 0.618034, 1.0), 0.55, 0.95))
		_settled = true

	func _phase_sample() -> PackedFloat32Array:
		var out := PackedFloat32Array()
		out.resize(_job_names.size() + 1)
		# Row 0 is the sum of the frozen rows. A job name that first appears
		# after discovery is dropped on purpose — a row set that grew mid-run
		# would invalidate every history the panel holds.
		var total := 0.0
		for i in _job_names.size():
			var ms := float(_tap.frame.get(_job_names[i], 0.0)) * 1000.0
			out[i + 1] = ms
			total += ms
		out[0] = total
		return out

	func _phase_proof() -> String:
		return "%d Jolt jobs" % _job_names.size()

	func _fallback_reason() -> String:
		# A dead channel outranks the debug-build story: it is the reason no Jolt
		# build of any kind would produce numbers here.
		if _tap == null or not _channel_live():
			return super()
		return "Jolt job timings need a debug build"

	## Recounted at most once a second: walking a several-thousand-node tree on
	## every draw would show up in the very numbers this harness measures.
	func _body_count() -> int:
		var now := Time.get_ticks_msec()
		if now - _bodies_stamp < 1000:
			return _bodies
		_bodies_stamp = now
		var scope: Node = _root
		if scope == null or not scope.is_inside_tree():
			scope = null
			var loop := Engine.get_main_loop() as SceneTree
			if loop != null:
				scope = loop.current_scene
		if scope != null:
			# owned = false, so bodies created at runtime are counted too.
			_bodies = scope.find_children("*", "PhysicsBody3D", true, false).size()
		return _bodies


# --- File statics and factory ----------------------------------------------
# Declared after the classes they refer to so the parser never has to look
# ahead for an inner class type.

static var _tap_instance: ServersTap = null
static var _tap_tried := false


## Build the feed for `engine` ("box3d" | "godot" | "jolt") reading `world`
## (the Box3DWorld for box3d, the harness stage node otherwise).
##
## Native runs dispatch on the server that is ACTUALLY live, not on the
## requested name: physics/3d/physics_engine is read once at startup and cannot
## be changed afterwards, so a launcher whose override.cfg went missing would
## otherwise paint a Jolt-shaped panel over GodotPhysics numbers. The
## disagreement is warned about here and repeated in the feed's proof line.
static func make(engine: String, world) -> ProfileFeed:
	if engine == "box3d":
		return Box3DFeed.new(world)

	var setting := physics_engine_setting()
	var live := native_engine_name()
	if engine == "jolt" and live != "Jolt Physics":
		push_warning("[profile] requested jolt but the live server is %s (override.cfg missing?)" % live)
	elif engine == "godot" and live == "Jolt Physics":
		push_warning("[profile] requested godot but the live server is Jolt Physics")

	var tap := acquire_servers_tap()
	if live == "Jolt Physics":
		return JoltFeed.new(world, engine, setting, tap)
	return GodotPhysicsFeed.new(world, engine, setting, tap)


## physics/3d/physics_engine, verbatim. Valid values are "DEFAULT",
## "GodotPhysics3D", "Jolt Physics" and "Dummy".
static func physics_engine_setting() -> String:
	return str(ProjectSettings.get_setting("physics/3d/physics_engine", "DEFAULT"))


## Which native 3D server this process actually created. In Godot 4.7 the
## engine's "DEFAULT" still resolves to GodotPhysics3D — it is the NEW-PROJECT
## template that writes "Jolt Physics" explicitly — so anything that is not
## literally "Jolt Physics" is the built-in server. ("Dummy" steps nothing at
## all; the raw setting is surfaced by `physics_engine_setting()` and printed in
## every native feed's proof line, so that case is visible rather than silent.)
static func native_engine_name() -> String:
	if physics_engine_setting() == "Jolt Physics":
		return "Jolt Physics"
	return "Godot Physics"


## The single "servers" tap, registered at most once per process. Returns null
## when the name is unavailable, which is the caller's cue to fall back.
static func acquire_servers_tap() -> ServersTap:
	if _tap_tried:
		return _tap_instance
	_tap_tried = true
	# ServersDebugger claims "servers" only when EngineDebugger.is_active(),
	# i.e. under --remote-debug from the editor. Registering over it would break
	# the editor's own profiler, so leave it alone and degrade instead.
	if EngineDebugger.has_profiler("servers"):
		return null
	var tap := ServersTap.new()
	EngineDebugger.register_profiler("servers", tap)
	EngineDebugger.profiler_enable("servers", true)
	_tap_instance = tap
	_install_guard()
	return tap


## Take the tap back out of EngineDebugger. Idempotent, and safe when no tap was
## ever registered. The guard node calls this at shutdown; a caller that quits
## from inside a _ready() (before the deferred guard has landed) must call it
## itself, or the process aborts on the way out.
##
## `_tap_tried` deliberately stays true: after a release the only correct answer
## for a new feed is the wall-clock fallback, not a second registration on a
## debugger that is already halfway shut down.
static func release_servers_tap() -> void:
	if _tap_instance == null:
		return
	# Cleared first, but the feeds hold their own reference, so a feed that polls
	# during teardown reads a stale frame instead of a freed object.
	_tap_instance = null
	EngineDebugger.profiler_enable("servers", false)
	EngineDebugger.unregister_profiler("servers")


static func _install_guard() -> void:
	var loop := Engine.get_main_loop() as SceneTree
	if loop == null or loop.root == null:
		return
	var guard := TapGuard.new()
	guard.name = "ProfileFeedsTapGuard"
	# Deferred because acquire_servers_tap() is normally reached from a _ready(),
	# and the root is mid-add_child at that moment.
	loop.root.add_child.call_deferred(guard)
