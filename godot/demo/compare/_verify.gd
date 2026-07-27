extends Node3D

## Throwaway smoke test for the comparison harness modules. Runs RigExtract over
## every authored sample and then feeds each Rig to RigNative, so a crash or a
## silently empty extraction is caught here rather than on stage.
##
## Nothing built here is ever added to the scene tree: RigNative parents its
## bodies under a detached Node3D, so no physics space is touched and the
## 5050-body scenarios cost tree allocation only.
##
##   godot --headless --path godot/demo res://compare/_verify.tscn --quit-after 600

const SAMPLES_DIR := "res://samples"

var _fail := 0


func _ready() -> void:
	var paths := _sample_paths()
	if paths.is_empty():
		print("[verify] no scenes found under %s" % SAMPLES_DIR)
		_fail += 1

	for path: String in paths:
		_check(path)

	_check_feeds()
	_check_panel()

	print("[verify] ALL -> %s" % ("PASS" if _fail == 0 else "FAIL (%d)" % _fail))
	# Quitting from _ready() means the tap guard's deferred add_child never runs,
	# and a still-registered EngineProfiler aborts the process during teardown.
	ProfileFeeds.release_servers_tap()
	get_tree().quit(0 if _fail == 0 else 1)


static func _sample_paths() -> PackedStringArray:
	var out := PackedStringArray()
	var dir := DirAccess.open(SAMPLES_DIR)
	if dir == null:
		return out
	for f: String in dir.get_files():
		# Exported projects hand back the .remap/.import name, so normalise.
		var name := f.trim_suffix(".remap")
		if name.ends_with(".tscn"):
			out.append("%s/%s" % [SAMPLES_DIR, name])
	out.sort()
	return out


func _check(path: String) -> void:
	var rig := RigExtract.from_scene(path)
	var bodies: Array = rig.get("bodies", [])
	var joints: Array = rig.get("joints", [])
	var gaps: Array = rig.get("unsupported", [])
	var short := path.get_file().get_basename()
	print("[verify] %s -> %d bodies, %d joints, %d unsupported"
			% [short, bodies.size(), joints.size(), gaps.size()])

	var problems := PackedStringArray()
	if String(rig.get("source", "")) != path:
		problems.append("source not echoed back")
	if not (rig.get("gravity") is Vector3):
		problems.append("gravity is not a Vector3")
	if bodies.is_empty():
		problems.append("no bodies extracted")

	# SPEC A: every Body carries at least one Shape, and every Shape carries the
	# kind-specific group its kind promises.
	var shapeless := 0
	var bad_shape := 0
	for b: Dictionary in bodies:
		var shapes: Array = b.get("shapes", [])
		if shapes.is_empty():
			shapeless += 1
		for s: Dictionary in shapes:
			if not _shape_ok(s):
				bad_shape += 1
	if shapeless > 0:
		problems.append("%d bodies with no shape" % shapeless)
	if bad_shape > 0:
		problems.append("%d malformed shapes" % bad_shape)

	for j: Dictionary in joints:
		var ia := int(j.get("body_a", -2))
		var ib := int(j.get("body_b", -2))
		if ia < -1 or ia >= bodies.size() or ib < -1 or ib >= bodies.size():
			problems.append("joint '%s' has an out-of-range endpoint" % j.get("name", "?"))

	# The native builder runs against every rig, detached, purely to prove it
	# does not fault on any authored combination of shapes and joints.
	var stage := Node3D.new()
	var built := RigNative.build(rig, stage)
	var nb: Array = built.get("bodies", [])
	if nb.size() != bodies.size():
		problems.append("native build made %d of %d bodies" % [nb.size(), bodies.size()])
	stage.free()

	for p: String in problems:
		print("[verify]   ! %s: %s" % [short, p])
	_fail += problems.size()

	# Not a failure: SPEC A forbids running _ready, so a sample that builds its
	# scene in code is legitimately near-empty here. It still cannot be ported,
	# so say so rather than letting a one-body rig read as a clean extraction.
	if bodies.size() < 2:
		print("[verify]   . %s: only %d body authored; this sample builds its bodies "
				% [short, bodies.size()]
				+ "in _ready(), which the extractor deliberately never runs")


static func _shape_ok(s: Dictionary) -> bool:
	if not (s.get("transform") is Transform3D):
		return false
	match String(s.get("kind", "")):
		"box":
			return s.get("size") is Vector3
		"sphere":
			return s.get("radius") is float
		"capsule":
			return s.get("radius") is float and s.get("height") is float
		"hull":
			var pts: Variant = s.get("points")
			return pts is PackedVector3Array and (pts as PackedVector3Array).size() >= 4
		"mesh":
			var faces: Variant = s.get("faces")
			return faces is PackedVector3Array \
					and (faces as PackedVector3Array).size() >= 3 \
					and (faces as PackedVector3Array).size() % 3 == 0
	return false


## The native feeds must build and answer every SPEC B call without a live
## Box3D world; the Box3D feed is checked against a real world node when the
## GDExtension is present.
func _check_feeds() -> void:
	var made: Array = []
	made.append(ProfileFeeds.make("godot", self))
	made.append(ProfileFeeds.make("jolt", self))
	if ClassDB.class_exists(&"Box3DWorld"):
		var w: Object = ClassDB.instantiate(&"Box3DWorld")
		made.append(ProfileFeeds.make("box3d", w))
		if w is Node:
			(w as Node).free()
	else:
		print("[verify]   ! ProfileFeeds: Box3DWorld is not registered")
		_fail += 1

	for feed in made:
		if feed == null:
			print("[verify]   ! ProfileFeeds.make returned null")
			_fail += 1
			continue
		# Long enough to outlast the native feeds' 120-tick discovery watchdog, so
		# the settled row set is what gets checked, not the empty pre-ready one.
		for i in 140:
			var s: PackedFloat32Array = feed.sample()
			if not feed.is_ready() or s.is_empty():
				continue
			if s.size() != feed.rows().size():
				# Legitimate on exactly the tick a feed settles: the row set is
				# final from here on, so a later disagreement is the real bug.
				if i < 139:
					continue
				print("[verify]   ! %s: %d samples for %d rows"
						% [feed.engine_name(), s.size(), feed.rows().size()])
				_fail += 1
		var rows: Array = feed.rows()
		if not feed.is_ready():
			print("[verify]   ! %s: never became ready" % feed.engine_name())
			_fail += 1
		for r: int in feed.flame_rows():
			if r <= 0 or r >= rows.size():
				print("[verify]   ! %s: flame row %d is out of range"
						% [feed.engine_name(), r])
				_fail += 1
		print("[verify] feed %s -> %d rows, ready=%s, phases=%s | %s"
				% [feed.engine_name(), rows.size(), feed.is_ready(),
				feed.has_phases(), feed.source_proof()])
		for row: Dictionary in rows:
			if not (row.get("label") is String) or not (row.get("indent") is int) \
					or not (row.get("color") is Color):
				print("[verify]   ! %s: malformed row %s" % [feed.engine_name(), row])
				_fail += 1
		print("[verify] counters %s -> %s" % [feed.engine_name(), feed.counters()])


## The panel is a Control, so headless never calls _draw; poll() is still the
## path that writes the ring and re-adopts a late row set, so drive that.
func _check_panel() -> void:
	var panel := ProfilerPanel.new()
	add_child(panel)
	panel.set_feed(ProfileFeeds.make("godot", self))
	# Past the 120-tick watchdog, so the late row set and the panel's re-adopt
	# path are both exercised rather than just the empty one.
	for i in 200:
		panel.poll()
	panel.reset()
	panel.free()
	print("[verify] panel -> polled 200 ticks without error")
