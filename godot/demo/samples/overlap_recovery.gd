extends Node3D

## Overlap Recovery -- a port of upstream's "Robustness / Overlap Recovery"
## sample (samples/sample_robustness.cpp). Ten boxes are spawned deliberately
## INTERLOCKED: each one starts a quarter of its width inside its neighbours,
## a state a rigid-body solver should never see. Box3D untangles them with a
## soft push instead of firing them across the map, which is what the contact
## tuning on the world is for -- contact_hertz 30 and contact_damping 10 are
## upstream's numbers.
##
## Upstream also tunes a third value, the maximum contact push VELOCITY
## (b3World_SetContactTuning's third argument, 3 m/s there); the GDExtension
## binds hertz and damping but not that one, so this port takes the solver
## default. See SPRINT_STATE.md.

## Half-width of a box, upstream's m_extent.
const EXTENT := 0.5
## Rows in the triangle, upstream's m_baseCount. 4 rows = 10 boxes.
const BASE_COUNT := 4
## Fraction of a box each neighbour is buried by, upstream's m_overlap.
const OVERLAP := 0.25
const DENSITY := 1.0

var camera_home := Vector3(10.0, 5.1, 10.0)
var camera_look_at := Vector3(0.0, 1.5, 0.0)

var _mesh := BoxMesh.new()
var _material := StandardMaterial3D.new()


func _ready() -> void:
	_mesh.size = Vector3(2.0 * EXTENT, 2.0 * EXTENT, 2.0 * EXTENT)
	_material.albedo_color = Color(0.86, 0.45, 0.3)
	_material.roughness = 0.5

	var world: Node = $Box3DWorld
	var pile := Node3D.new()
	pile.name = "Pile"
	world.add_child(pile)

	# Upstream's layout, verbatim: rows shrink by one, and every step along a
	# row (and up to the next) is only (1 - overlap) of a box width, so each
	# box lands buried in the one before it.
	var fraction := 1.0 - OVERLAP
	var y := EXTENT
	for i in BASE_COUNT:
		var x := fraction * EXTENT * (i - BASE_COUNT)
		for j in range(i, BASE_COUNT):
			pile.add_child(_make_box(Vector3(x, y, 0.0)))
			x += 2.0 * fraction * EXTENT
		y += 2.0 * fraction * EXTENT


func _make_box(pos: Vector3) -> Box3DBody:
	var body := Box3DBody.new()
	body.box_size = _mesh.size
	body.density = DENSITY
	body.position = pos
	var visual := MeshInstance3D.new()
	visual.mesh = _mesh
	visual.material_override = _material
	body.add_child(visual)
	return body
