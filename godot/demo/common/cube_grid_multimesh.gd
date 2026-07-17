extends Node3D

## Renders every cube body under this node through ONE MultiMesh.
##
## The Cube Pile is 4096 bodies, and as instanced scenes each carried its own
## MeshInstance3D — 4096 draw calls per frame, which is the dominant rendering
## cost of this sample on mobile (and through the emulator's GL translator).
## A MultiMesh submits all of them as a single draw call; this script frees the
## per-cube meshes at load and copies body transforms into the MultiMesh every
## frame instead. Physics is untouched: same 4096 Box3DBody nodes, and grabbing
## / shooting / raycasts behave exactly as before.
##
## Colors ride along as per-instance MultiMesh colors (continuous pastel hues,
## like the original look) — no materials, no instance-uniform limits.

var _bodies: Array[Box3DBody] = []
var _mm: MultiMesh
var _mmi: MultiMeshInstance3D
var _world: Node = null


func _ready() -> void:
	_world = get_parent()  # Box3DWorld in the generated scene

	for c in get_children():
		if c is Box3DBody:
			_bodies.append(c)
			# The cube scene's own visual is replaced by our instance.
			var mesh := c.get_node_or_null("MeshInstance3D")
			if mesh != null:
				mesh.queue_free()

	var box := BoxMesh.new()
	box.size = Vector3.ONE  # matches the cube bodies' box_size
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.8
	box.material = mat

	_mm = MultiMesh.new()
	_mm.transform_format = MultiMesh.TRANSFORM_3D
	_mm.use_colors = true
	_mm.mesh = box
	_mm.instance_count = _bodies.size()
	for i in _bodies.size():
		_mm.set_instance_color(i, Color.from_hsv(randf(), 0.5, 0.95))
		# Bodies and the MultiMeshInstance are siblings under this node, so
		# body-local transforms are already in the right space.
		_mm.set_instance_transform(i, _bodies[i].transform)

	_mmi = MultiMeshInstance3D.new()
	_mmi.multimesh = _mm
	add_child(_mmi)


func _process(_delta: float) -> void:
	# The debug view replaces bodies' looks with collider shells (the bodies
	# keep debug_visualize, so the world shells them); hide our visual then.
	if _world != null and "debug_draw" in _world:
		_mmi.visible = not _world.debug_draw
	for i in _bodies.size():
		_mm.set_instance_transform(i, _bodies[i].transform)
