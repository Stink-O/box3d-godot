extends Node3D

## Throwaway diagnostic rig (NOT part of the selftests): loads a sample, lets it
## settle, fires the shell's blast at a point among its dynamic bodies, and
## prints the velocity delta the blast produced.
##
##   godot --headless --path godot/demo res://tests/blast_probe.tscn -- \
##       --scene=res://samples/gear_lift.tscn [--impulse=9] [--settle=120]
##
## The delta is sampled IMMEDIATELY after Box3DWorld.explode, before the next
## step, because b3World_Explode writes straight into the solver's velocity
## state (src/physics_world.c:3417-3421) -- so nothing else can contaminate it.

const BLAST_RADIUS := 8.0  ## common/bomb.gd BLAST_RADIUS
const BLAST_IMPULSE := 9.0  ## common/bomb.gd BLAST_IMPULSE
const FALLOFF := 1.0  ## common/explosion_fx.gd blast()

const ExplosionFX = preload("res://common/explosion_fx.gd")


func _ready() -> void:
	var scene_path := ""
	var impulse := BLAST_IMPULSE
	var settle := 120
	var at_override := Vector3.INF
	var via_fx := false
	for a in OS.get_cmdline_user_args():
		if a == "--fx":
			via_fx = true
		if a.begins_with("--scene="):
			scene_path = a.substr(8)
		elif a.begins_with("--impulse="):
			impulse = float(a.substr(10))
		elif a.begins_with("--settle="):
			settle = int(a.substr(9))
		elif a.begins_with("--at="):
			var p := a.substr(5).split(",")
			at_override = Vector3(float(p[0]), float(p[1]), float(p[2]))
	if scene_path == "":
		print("[blast] no --scene=")
		get_tree().quit(1)
		return

	var scene: PackedScene = load(scene_path)
	if scene == null:
		print("[blast] load failed: ", scene_path)
		get_tree().quit(1)
		return
	var inst = scene.instantiate()
	add_child(inst)
	var world = inst.get_node_or_null("Box3DWorld")
	if world == null:
		print("[blast] no Box3DWorld in ", scene_path)
		get_tree().quit(1)
		return

	for i in range(settle):
		await get_tree().physics_frame

	var bodies: Array = []
	_collect(inst, bodies)
	var dyn: Array = []
	for b in bodies:
		if b.body_type == 2:
			dyn.append(b)
	if dyn.is_empty():
		print("[blast] %s: NO DYNAMIC BODIES (total bodies %d)" % [scene_path.get_file(), bodies.size()])
		get_tree().quit(0)
		return

	var at := at_override
	if at == Vector3.INF:
		# Centre of the dynamic mass, snapped onto the nearest actual body so the
		# blast always lands in the material rather than in a hole.
		var c := Vector3.ZERO
		for b in dyn:
			c += b.global_position
		c /= dyn.size()
		var best = dyn[0]
		var bestd := INF
		for b in dyn:
			var d: float = b.global_position.distance_to(c)
			if d < bestd:
				bestd = d
				best = b
		at = best.global_position

	# In range of the blast, by the same distance test the callback uses on a
	# centre-to-centre basis (a rough superset: the callback measures to the
	# shape surface, so this can only under-count).
	var near: Array = []
	for b in dyn:
		if b.global_position.distance_to(at) <= BLAST_RADIUS + FALLOFF:
			near.append(b)

	var before := {}
	for b in near:
		before[b] = b.get_linear_velocity()
	var pos_before := {}
	for b in near:
		pos_before[b] = b.global_position

	if via_fx:
		ExplosionFX.blast(world, at, BLAST_RADIUS, impulse)
	else:
		world.explode(at, BLAST_RADIUS, impulse, FALLOFF)

	var deltas: Array = []
	var moved := 0
	for b in near:
		var d: float = (b.get_linear_velocity() - (before[b] as Vector3)).length()
		deltas.append(d)
		if d > 0.05:
			moved += 1
	deltas.sort()
	var mean := 0.0
	for d in deltas:
		mean += d
	if deltas.size() > 0:
		mean /= deltas.size()

	# What it looks like a second later: settled displacement, the thing a human
	# actually sees.
	for i in range(60):
		await get_tree().physics_frame
	var disp := 0.0
	for b in near:
		disp += b.global_position.distance_to(pos_before[b] as Vector3)
	if near.size() > 0:
		disp /= near.size()

	var mass := 0.0
	for b in near:
		mass += b.get_mass()
	if near.size() > 0:
		mass /= near.size()

	var p10 := 0.0
	var p50 := 0.0
	var p90 := 0.0
	if deltas.size() > 0:
		p10 = deltas[int(deltas.size() * 0.10)]
		p50 = deltas[deltas.size() / 2]
		p90 = deltas[mini(deltas.size() - 1, int(deltas.size() * 0.90))]
	# Optional mechanism-survival check: does a named body still do its job
	# several seconds after the blast?
	for a in OS.get_cmdline_user_args():
		if not a.begins_with("--watch="):
			continue
		var w := inst.find_child(a.substr(8), true, false) as Box3DBody
		if w == null:
			print("[watch] %s NOT FOUND" % a.substr(8))
			continue
		var y0: float = w.global_position.y
		for i in range(360):
			await get_tree().physics_frame
		print("[watch] %s y %.3f -> %.3f (dy %+.3f) speed=%.3f" % [
			w.name, y0, w.global_position.y, w.global_position.y - y0,
			w.get_linear_velocity().length()])

	print("[blast] %s|near=%d|moved=%d|mass=%.3f|dvmean=%.4f|p10=%.4f|p50=%.4f|p90=%.4f|max=%.4f|disp60=%.4f" % [
		scene_path.get_file().trim_suffix(".tscn"), near.size(), moved, mass,
		mean, p10, p50, p90, (deltas[-1] if deltas.size() > 0 else 0.0), disp])
	get_tree().quit(0)


func _collect(n: Node, out: Array) -> void:
	if n is Box3DBody:
		out.append(n)
	for c in n.get_children():
		_collect(c, out)
