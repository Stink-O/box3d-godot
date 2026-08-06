extends Node3D

## High Mass Ratio -- a port of upstream's "Robustness / HighMassRatio1"
## sample (samples/sample_robustness.cpp). Three identical 10-row pyramids of
## 2 m boxes, each crowned by a single box of the SAME size that is 100x, 200x
## and 300x denser than everything holding it up (the red one). Mass ratios
## like that are the classic way to make an iterative solver sag or explode,
## so this is a robustness read-out, not a toy: the left stack should barely
## notice, and the sag should grow as you look right.
##
## The heavy box starts one row's height above the apex so it lands on the
## pyramid rather than resting there from frame zero -- upstream's `yy` offset.

const EXTENT := 1.0
## Boxes along the bottom row of each pyramid, upstream's `count`.
const BASE_COUNT := 10
const BASE_DENSITY := 1.0
## Density multiplier of the crowning box: pyramid j gets (j + 1) * this.
const HEAVY_DENSITY_STEP := 100.0
const PYRAMID_COUNT := 3

var camera_home := Vector3(33.8, 18.1, 58.6)
var camera_look_at := Vector3(2.0, 4.0, 0.0)

var _mesh := BoxMesh.new()
var _light_material := StandardMaterial3D.new()
var _heavy_material := StandardMaterial3D.new()


func _ready() -> void:
	_mesh.size = Vector3(2.0 * EXTENT, 2.0 * EXTENT, 2.0 * EXTENT)
	_light_material.albedo_color = Color(0.62, 0.68, 0.78)
	_light_material.roughness = 0.65
	_heavy_material.albedo_color = Color(0.85, 0.2, 0.18)
	_heavy_material.roughness = 0.35
	_heavy_material.metallic = 0.35

	var world: Node = $Box3DWorld
	for j in PYRAMID_COUNT:
		var stack := Node3D.new()
		stack.name = "Pyramid_%d" % j
		world.add_child(stack)
		# Upstream spaces the pyramids by the width of a full base row plus one
		# box, measured from a left edge at -20.
		var offset := -20.0 * EXTENT + 2.0 * (BASE_COUNT + 1.0) * EXTENT * j
		var count := BASE_COUNT
		var y := EXTENT
		while count > 0:
			for i in count:
				var coeff := i - 0.5 * count
				# The last row is the single heavy box; it starts a row higher.
				var yy := y + 2.0 * EXTENT if count == 1 else y
				var heavy := count == 1
				var density := (j + 1.0) * HEAVY_DENSITY_STEP if heavy else BASE_DENSITY
				stack.add_child(_make_box(
						Vector3(2.0 * coeff * EXTENT + offset, yy, 0.0), density, heavy))
			count -= 1
			y += 2.0 * EXTENT


func _make_box(pos: Vector3, density: float, heavy: bool) -> Box3DBody:
	var body := Box3DBody.new()
	body.box_size = _mesh.size
	body.density = density
	body.position = pos
	var visual := MeshInstance3D.new()
	visual.mesh = _mesh
	visual.material_override = _heavy_material if heavy else _light_material
	body.add_child(visual)
	return body
