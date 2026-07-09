extends Node

## Headless smoke test for the sample-browser shell + ball shooting.
## Loads main.tscn, verifies the dropdown popup is populated, then fires the
## camera's _shoot() and checks a ball spawns in the world and travels forward.

func _ready() -> void:
	if not "--selftest" in OS.get_cmdline_user_args():
		return
	var scene: PackedScene = load("res://main.tscn")
	var main: Node = scene.instantiate()
	add_child(main)
	await get_tree().process_frame
	await get_tree().process_frame

	var ok := true

	# Dropdown popup should hold every sample as an item.
	var popup: PopupMenu = main.get_node("UI/Bar/Menu").get_popup()
	var item_count := 0
	for i in popup.item_count:
		if not popup.is_item_separator(i):
			item_count += 1
	ok = _check("dropdown lists samples (%d)" % item_count, item_count >= 3) and ok

	var host: Node = main.get_node("SampleHost")
	var sample: Node = host.get_child(0)
	var world: Node = sample.get_node("Box3DWorld")
	var before := world.get_child_count()

	var cam := main.get_node("Camera3D")
	cam.call("_shoot")
	# Let the body register and simulate.
	for i in 20:
		await get_tree().physics_frame

	var after := world.get_child_count()
	ok = _check("shoot spawned a ball (%d -> %d)" % [before, after], after == before + 1) and ok

	# The ball should have moved away from its spawn (forward + gravity).
	var ball: Box3DBody = world.get_child(after - 1)
	var speed := ball.get_linear_velocity().length()
	ok = _check("ball is moving (%.1f m/s)" % speed, speed > 1.0) and ok

	print("[shoot] ALL -> %s" % ("PASS" if ok else "FAIL"))
	get_tree().quit(0 if ok else 1)


func _check(label: String, cond: bool) -> bool:
	print("[shoot] %s -> %s" % [label, "PASS" if cond else "FAIL"])
	return cond
