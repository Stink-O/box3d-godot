extends Node3D

## Wedge -- a port of upstream's "Stacking / Wedge" sample
## (samples/sample_stacking.cpp), whose comment says it all: "This wedge shape
## can have an incorrect manifold if not handled correctly." The body is a
## six-vertex hull -- a flat slab whose underside collapses to a single ridge
## LINE -- dropped flat onto the ground. Landing edge-first on a plane is the
## degenerate case for manifold generation: the contact is a line, not a face,
## and a solver that picks the wrong reference face makes it jitter, spin off
## or sink. Box3D balances it on the ridge and lets it topple naturally.
##
## Upstream's six points verbatim (samples/sample_stacking.cpp:576): four
## corners of a 2 x 0.2 m top face at y = 1 and two ridge points at y = 0.5,
## with the body dropped from y = 1 so the ridge starts 1.5 m up.
##
## The GDExtension builds a HULL shape from a Godot mesh's point cloud, so
## the same six vertices are fed in as an ArrayMesh, which doubles as the
## visual.

const TOP_Y := 1.0
const RIDGE_Y := 0.5
const HALF_LENGTH := 1.0
const HALF_WIDTH := 0.1
const RIDGE_HALF_LENGTH := 0.5
const START := Vector3(0.0, 1.0, 0.0)

var camera_home := Vector3(9.5, 1.7, 2.5)
var camera_look_at := Vector3(0.0, 0.0, 0.0)

var _wedge: Box3DBody


func _ready() -> void:
	var mesh := _build_mesh()

	_wedge = Box3DBody.new()
	_wedge.name = "Wedge"
	_wedge.shape_type = Box3DBody.HULL
	_wedge.collision_mesh = mesh
	_wedge.position = START
	var visual := MeshInstance3D.new()
	visual.mesh = mesh
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.85, 0.55, 0.35)
	material.roughness = 0.45
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	visual.material_override = material
	_wedge.add_child(visual)
	$Box3DWorld.add_child(_wedge)


## The shell's reusable Activate button: drop it again from the start pose.
func activate() -> void:
	_wedge.teleport(Transform3D(Basis(), START))
	_wedge.set_awake(true)


func _build_mesh() -> ArrayMesh:
	# Upstream's vertex list, in its order.
	var v := [
		Vector3(-HALF_LENGTH, TOP_Y, -HALF_WIDTH),
		Vector3(HALF_LENGTH, TOP_Y, -HALF_WIDTH),
		Vector3(-HALF_LENGTH, TOP_Y, HALF_WIDTH),
		Vector3(HALF_LENGTH, TOP_Y, HALF_WIDTH),
		Vector3(-RIDGE_HALF_LENGTH, RIDGE_Y, 0.0),
		Vector3(RIDGE_HALF_LENGTH, RIDGE_Y, 0.0),
	]
	# Closed surface over those six points: top face, two sloping flanks and
	# the two end caps. b3CreateHull only needs the point cloud, but a closed
	# mesh is what makes the visual read as a solid. Wound Box3D's way --
	# counter-clockwise by the right-hand rule, normal pointing out of the
	# wedge -- and reversed for Godot by Box3DGeometry.make_array_mesh, which
	# also gives each face its own flat normal.
	var idx := PackedInt32Array([
		0, 3, 1, 0, 2, 3,               # top
		0, 5, 4, 0, 1, 5,               # -z flank
		2, 5, 3, 2, 4, 5,               # +z flank
		0, 4, 2, 1, 3, 5,               # end caps
	])
	return Box3DGeometry.make_array_mesh({"vertices": PackedVector3Array(v), "indices": idx})
