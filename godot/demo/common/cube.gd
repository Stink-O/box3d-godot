extends Box3DBody

## Gives each cube instance its own color. The physics body itself is created
## by the native Box3DBody class; this only touches the visual material.

func _ready() -> void:
	var mesh := get_node_or_null("MeshInstance3D") as MeshInstance3D
	if mesh == null:
		return
	var material := StandardMaterial3D.new()
	material.albedo_color = Color.from_hsv(randf(), 0.5, 0.95)
	material.roughness = 0.8
	mesh.material_override = material
