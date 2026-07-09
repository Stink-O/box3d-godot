extends Node3D

## Headless smoke test for the sample browser: loads every scene in samples/,
## steps it, and checks its Box3DWorld exists and keeps bodies. Run with:
##   godot --headless --path . res://tests/test_samples.tscn -- --selftest

var _all_ok := true


func _ready() -> void:
	var paths: Array = []
	var dir := DirAccess.open("res://samples")
	if dir != null:
		for f in dir.get_files():
			if f.ends_with(".tscn"):
				paths.append("res://samples/" + f)
	paths.sort()

	for p in paths:
		await _smoke(p)

	print("[samples] ALL -> ", "PASS" if _all_ok else "FAIL")
	get_tree().quit(0 if _all_ok else 1)


func _smoke(path: String) -> void:
	var scene: PackedScene = load(path)
	var ok := scene != null
	if ok:
		var inst = scene.instantiate()
		add_child(inst)
		var world = inst.get_node_or_null("Box3DWorld")
		ok = world != null
		for i in range(30):
			await get_tree().physics_frame
		if world != null:
			ok = ok and world.get_child_count() > 0
		inst.queue_free()
		await get_tree().physics_frame
	_all_ok = _all_ok and ok
	print("[samples] %s -> %s" % [path.get_file(), "PASS" if ok else "FAIL"])
