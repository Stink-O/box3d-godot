extends Node3D

## Temporary frame-time benchmark for the Cube Pile (not part of the suite).
## Loads the sample, lets it settle (thousands of awake bodies), and prints
## per-frame timing stats for the settling phase and the settled phase.

var _frames := 0
var _samples: Array = []
var _last_usec := 0
var _phys_max := 0.0
var _phys_sum := 0.0
var _phys_n := 0


func _ready() -> void:
	var ps: PackedScene = load("res://samples/cube_pile.tscn")
	var pile := ps.instantiate()
	add_child(pile)
	var args := OS.get_cmdline_user_args()
	if "--nointerp" in args:
		get_tree().root.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		print("[bench] physics interpolation OFF")
	if "--mailbox" in args:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_MAILBOX)
		print("[bench] vsync MAILBOX (got %d)" % DisplayServer.window_get_vsync_mode())
	if "--nosync" in args:
		# Freeze the MultiMesh copy loop; physics keeps running unwatched.
		for n in _find_grids(pile):
			n.set_process(false)
		print("[bench] MultiMesh sync loop OFF")
	_last_usec = Time.get_ticks_usec()


func _find_grids(root: Node) -> Array:
	var out := []
	for c in root.get_children():
		if c.get_script() != null and str(c.get_script().resource_path).ends_with("cube_grid_multimesh.gd"):
			out.append(c)
		out.append_array(_find_grids(c))
	return out


func _physics_process(_d: float) -> void:
	# TIME_PHYSICS_PROCESS updates once a second; sampling every tick still
	# captures each new 1 s value during the run.
	var t: float = Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)
	_phys_max = maxf(_phys_max, t)
	_phys_sum += t
	_phys_n += 1


func _process(_d: float) -> void:
	var now := Time.get_ticks_usec()
	_samples.append(now - _last_usec)
	_last_usec = now
	_frames += 1
	if _frames == 600:
		_report("settling")
	elif _frames == 1200:
		_report("settled")
		get_tree().quit(0)


func _report(label: String) -> void:
	_samples.sort()
	var total := 0
	for v in _samples:
		total += v
	var n := _samples.size()
	var over16 := 0
	var over33 := 0
	for v in _samples:
		if v > 16600:
			over16 += 1
		if v > 33300:
			over33 += 1
	print("[bench] %s: avg %.2f ms  p99 %.2f ms  max %.2f ms  frames>16.6ms: %d  >33ms: %d  (of %d)" % [
		label, total / 1000.0 / n, _samples[int(n * 0.99)] / 1000.0,
		_samples[n - 1] / 1000.0, over16, over33, n])
	if _phys_n > 0:
		print("[bench] %s: physics step avg %.2f ms  max %.2f ms" % [
			label, _phys_sum / _phys_n * 1000.0, _phys_max * 1000.0])
	_phys_max = 0.0
	_phys_sum = 0.0
	_phys_n = 0
	_samples.clear()
