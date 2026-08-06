extends Node3D

## Hollow Box -- a port of upstream's "Mesh / Hollow Box" sample
## (samples/sample_mesh.cpp:1535). The room is `b3CreateHollowBoxMesh({0,0,0},
## {10,10,10})`: eight corners and twelve triangles wound so every normal
## points INWARD (src/mesh.c:1489-1521), handed to the node's raw
## `mesh_vertices` / `mesh_indices` path index for index.
##
## The point of the sample is what happens to a body that starts on the wrong
## side of a one-sided triangle. All fourteen props are spawned overlapping a
## wall -- 20 cm through the floor, 5 cm into a side wall -- with
## `gravity_scale = 0` and sleeping off, so nothing but the mesh's own
## depenetration is acting on them. A correctly wound hollow mesh pushes each
## one back into the room and then leaves it there; a mesh with the normals the
## other way would suck them out through the wall instead.
##
## Six 8-sided cylinders and eight capsules, at upstream's positions.

const EXTENT := Vector3(10.0, 10.0, 10.0)  # b3CreateHollowBoxMesh half extents

## b3CreateCylinder(height 1.0, radius 0.25, yOffset 0, sides 8).
const CYL_HEIGHT := 1.0
const CYL_RADIUS := 0.25
const CYL_SIDES := 8
const CYL_POSITIONS := [
	Vector3(0.0, -10.2, 0.0),
	Vector3(0.0, 9.2, 0.0),
	Vector3(-9.8, 0.0, 0.0),
	Vector3(9.8, 0.0, 0.0),
	Vector3(0.0, 0.0, -9.8),
	Vector3(0.0, 0.0, 9.8),
]

## b3Capsule {0,0,0}..{0,1,0} radius 0.25: total height 1.0 + 2 * 0.25.
const CAP_RADIUS := 0.25
const CAP_LENGTH := 1.0
const CAP_POSITIONS := [
	Vector3(0.0, -10.2, 2.0),
	Vector3(0.0, 9.2, 2.0),
	Vector3(0.0, -9.9, 4.0),
	Vector3(0.0, 8.9, 4.0),
	Vector3(-9.8, 2.0, 0.0),
	Vector3(9.8, 2.0, 0.0),
	Vector3(0.0, 2.0, -9.8),
	Vector3(0.0, 2.0, 9.8),
]

var camera_home := Vector3(18.37, 15.0, 18.37)
var camera_look_at := Vector3(0.0, 0.0, 0.0)


func _ready() -> void:
	var world: Node = $Box3DWorld

	# Built here, not in the scene: a MESH body whose raw arrays are still
	# half-set warns about having no collider, so it must not enter the tree
	# until both are in place.
	var room := Box3DBody.new()
	room.name = "Room"
	room.body_type = Box3DBody.STATIC
	room.shape_type = Box3DBody.MESH
	room.mesh_weld_tolerance = 0.0  # b3MeshDef def = {0}
	room.mesh_median_split = false
	room.mesh_indices = _hollow_box_indices()
	room.mesh_vertices = _hollow_box_vertices()

	var visual := MeshInstance3D.new()
	visual.name = "RoomVisual"
	visual.mesh = _hollow_box_surface()
	var wall_mat := StandardMaterial3D.new()
	wall_mat.albedo_color = Color(0.28, 0.32, 0.36)
	wall_mat.roughness = 0.85
	visual.material_override = wall_mat
	room.add_child(visual)
	world.add_child(room)

	var prop_mat := StandardMaterial3D.new()
	prop_mat.albedo_color = Color(0.85, 0.65, 0.35)
	prop_mat.roughness = 0.4

	for i in CYL_POSITIONS.size():
		var body := _new_prop("Cylinder%d" % i, prop_mat)
		# Upstream's cylinder is built base-up from y = 0 (b3CreateCylinder's
		# yOffset), while the node centres it on the body origin.
		body.shape_type = Box3DBody.CYLINDER
		body.capsule_radius = CYL_RADIUS
		body.capsule_height = CYL_HEIGHT
		body.cylinder_sides = CYL_SIDES
		body.position = CYL_POSITIONS[i] + Vector3(0.0, 0.5 * CYL_HEIGHT, 0.0)
		var cm := CylinderMesh.new()
		cm.top_radius = CYL_RADIUS
		cm.bottom_radius = CYL_RADIUS
		cm.height = CYL_HEIGHT
		cm.radial_segments = CYL_SIDES
		body.get_node("Visual").mesh = cm
		world.add_child(body)

	for i in CAP_POSITIONS.size():
		var body := _new_prop("Capsule%d" % i, prop_mat)
		# Two centres a metre apart: the node's capsule is centred on the body
		# origin, so the body carries the half-length offset.
		body.shape_type = Box3DBody.CAPSULE
		body.capsule_radius = CAP_RADIUS
		body.capsule_height = CAP_LENGTH + 2.0 * CAP_RADIUS
		body.position = CAP_POSITIONS[i] + Vector3(0.0, 0.5 * CAP_LENGTH, 0.0)
		var cap := CapsuleMesh.new()
		cap.radius = CAP_RADIUS
		cap.height = CAP_LENGTH + 2.0 * CAP_RADIUS
		body.get_node("Visual").mesh = cap
		world.add_child(body)


func _new_prop(p_name: String, p_material: Material) -> Box3DBody:
	var body := Box3DBody.new()
	body.name = p_name
	# b3DefaultBodyDef: no gravity here, never sleeps, no angular damping (the
	# node defaults to 0.05, upstream to 0).
	body.gravity_scale = 0.0
	body.can_sleep = false
	body.angular_damping = 0.0
	var visual := MeshInstance3D.new()
	visual.name = "Visual"
	visual.material_override = p_material
	body.add_child(visual)
	return body


## b3CreateHollowBoxMesh's eight corners, in its order (src/mesh.c:1494-1496).
func _hollow_box_vertices() -> PackedVector3Array:
	var x := EXTENT.x
	var y := EXTENT.y
	var z := EXTENT.z
	return PackedVector3Array([
		Vector3(x, y, z), Vector3(-x, y, z), Vector3(-x, -y, z), Vector3(x, -y, z),
		Vector3(x, y, -z), Vector3(-x, y, -z), Vector3(-x, -y, -z), Vector3(x, -y, -z),
	])


## Its twelve triangles, unchanged (src/mesh.c:1503-1510). Every one is wound
## so the right-hand normal faces into the room.
func _hollow_box_indices() -> PackedInt32Array:
	return PackedInt32Array([
		3, 1, 0, 3, 2, 1,  # front
		1, 4, 0, 5, 4, 1,  # top
		7, 3, 0, 7, 0, 4,  # right
		5, 7, 4, 7, 5, 6,  # back
		2, 5, 1, 5, 2, 6,  # left
		7, 2, 3, 2, 7, 6,  # bottom
	])


## The same room as a Godot surface. Godot's front faces wind the opposite way
## from Box3D's, so reversing each triangle here keeps the visible side on the
## same side as the collision normal -- the walls face inward, which is also
## what lets the camera see past the near ones into the room.
func _hollow_box_surface() -> ArrayMesh:
	var verts := _hollow_box_vertices()
	var idx := _hollow_box_indices()
	var flipped := PackedInt32Array()
	for t in idx.size() / 3:
		flipped.append_array([idx[t * 3], idx[t * 3 + 2], idx[t * 3 + 1]])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_INDEX] = flipped
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var st := SurfaceTool.new()
	st.create_from(mesh, 0)
	st.generate_normals()
	return st.commit()
