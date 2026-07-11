extends Box3DBody

## Gives each cube instance its own color. Every cube shares the one
## ShaderMaterial in cube.tscn; the color is a per-instance shader parameter,
## so thousands of cubes don't create thousands of materials.

func _ready() -> void:
	var mesh := get_node_or_null("MeshInstance3D") as MeshInstance3D
	if mesh == null:
		return
	mesh.set_instance_shader_parameter("tint", Color.from_hsv(randf(), 0.5, 0.95))
