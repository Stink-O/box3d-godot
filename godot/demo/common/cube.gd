extends Box3DBody

## Gives each cube a color from a small shared palette of materials.
##
## This used to be a per-instance shader parameter ("instance uniform") on one
## shared ShaderMaterial — but the GL Compatibility backend caps instance-
## uniform allocations at 4096 per hardware limits, and the 16^3 Cube Pile sits
## exactly at that number: on Android's GL fallback the allocations past the
## cap failed and those cubes rendered BLACK. A palette of plain shared
## StandardMaterial3Ds carries no per-instance data at all, so it renders
## correctly on every backend — and 24 shared materials sort and batch far
## better than 4096 instance-uniform writes.

const PALETTE_SIZE := 24

static var _palette: Array[StandardMaterial3D] = []


func _ready() -> void:
	var mesh := get_node_or_null("MeshInstance3D") as MeshInstance3D
	if mesh == null:
		return
	if _palette.is_empty():
		for i in PALETTE_SIZE:
			var m := StandardMaterial3D.new()
			# Same pastel look the instance uniform produced (hue spread,
			# s = 0.5, v = 0.95), just quantized to PALETTE_SIZE hues.
			m.albedo_color = Color.from_hsv(float(i) / PALETTE_SIZE, 0.5, 0.95)
			m.roughness = 0.8
			_palette.append(m)
	mesh.material_override = _palette[randi() % PALETTE_SIZE]
