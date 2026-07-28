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


## One shared material, random hue. Static so the native rebuild can color its
## bodies from the identical palette.
static func pick_material() -> StandardMaterial3D:
	if _palette.is_empty():
		for i in PALETTE_SIZE:
			var m := StandardMaterial3D.new()
			# Same pastel look the instance uniform produced (hue spread,
			# s = 0.5, v = 0.95), just quantized to PALETTE_SIZE hues.
			# The linear_to_srgb() matches the MultiMesh renderers: their
			# per-instance colors are consumed RAW as linear albedo (no sRGB
			# decode), which renders the same numbers noticeably paler. Baking
			# that shift into the material albedo gives every cube the one
			# signature pastel, whichever renderer (or physics engine) draws it.
			m.albedo_color = Color.from_hsv(float(i) / PALETTE_SIZE, 0.5, 0.95) \
					.linear_to_srgb()
			m.roughness = 0.8
			_palette.append(m)
	return _palette[randi() % PALETTE_SIZE]


func _ready() -> void:
	var mesh := get_node_or_null("MeshInstance3D") as MeshInstance3D
	if mesh == null:
		return
	mesh.material_override = pick_material()


## The color above is assigned in _ready, which never runs on the unparented
## instance RigExtract walks — so the rig would carry a null material and the
## native rebuild rendered every cube plain. The extractor asks for this
## instead wherever a visual has no authored material.
func rig_visual_material() -> Material:
	return pick_material()
