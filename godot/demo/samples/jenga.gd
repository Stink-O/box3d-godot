extends Node3D

## Jenga Stack -- a port of upstream's "Stacking / Jenga Stack" sample
## (samples/sample_stacking.cpp). Sixty 2 m beams are laid two per layer,
## each layer turned a quarter turn from the one below, into a tower 6 m
## tall from 20 cm stock. Every beam rests on just two small contact patches,
## so the tower is a test of how well the solver keeps a tall pile of
## box-on-box contacts from creeping: it should stand still, indefinitely.
##
## Upstream's numbers verbatim: half extents (1.0, 0.1, 0.1) -> a 2 x 0.2 x
## 0.2 m beam, 30 layers spaced 2.1 * r so the layers start a hair apart,
## the pair offset by h - 2r = 0.8 m either side of the axis, and rolling
## resistance 0.05 (its hull setting; upstream's capsule variant uses 0.1).
## The bomb and grab tools in the toolbar are the way to knock it over.

const HALF_LENGTH := 1.0
const HALF_THICK := 0.1
const LAYERS := 30
const ROLLING_RESISTANCE := 0.05

var camera_home := Vector3(6.6, 5.1, 9.5)
var camera_look_at := Vector3(0.0, 2.0, 0.0)

var _mesh := BoxMesh.new()
var _material_a := StandardMaterial3D.new()
var _material_b := StandardMaterial3D.new()


func _ready() -> void:
	_mesh.size = Vector3(2.0 * HALF_LENGTH, 2.0 * HALF_THICK, 2.0 * HALF_THICK)
	_material_a.albedo_color = Color(0.82, 0.62, 0.35)
	_material_a.roughness = 0.6
	_material_b.albedo_color = Color(0.68, 0.47, 0.26)
	_material_b.roughness = 0.6

	var tower := Node3D.new()
	tower.name = "Tower"
	$Box3DWorld.add_child(tower)

	for i in LAYERS:
		var odd := (i & 1) == 1
		# Odd layers keep the beams along x; even layers turn them onto z.
		var alpha := 0.0 if odd else 0.5 * PI
		var x := 0.0 if odd else HALF_LENGTH - 2.0 * HALF_THICK
		var z := HALF_LENGTH - 2.0 * HALF_THICK if odd else 0.0
		var y := (2.1 * i + 0.5) * HALF_THICK
		tower.add_child(_make_beam("Beam_%d_a" % i, Vector3(x, y, z), alpha, odd))
		tower.add_child(_make_beam("Beam_%d_b" % i, Vector3(-x, y, -z), alpha, odd))


func _make_beam(beam_name: String, pos: Vector3, alpha: float, odd: bool) -> Box3DBody:
	var body := Box3DBody.new()
	body.name = beam_name
	body.box_size = _mesh.size
	body.rolling_resistance = ROLLING_RESISTANCE
	body.transform = Transform3D(Basis(Vector3.UP, alpha), pos)
	var visual := MeshInstance3D.new()
	visual.mesh = _mesh
	visual.material_override = _material_b if odd else _material_a
	body.add_child(visual)
	return body
