extends Node3D

## Big Box -- a port of upstream's "Mesh / Big Box" sample
## (samples/sample_mesh.cpp). The ground is a single 100 x 2 x 100 m box fed
## to box3d as a TRIANGLE MESH: eight vertices and twelve triangles, each one
## 50 m across. Enormous triangles are the awkward case for a mesh collider --
## the contact point can sit a long way from every vertex, so any precision
## loss in the manifold shows up as a body that jitters, sinks or drifts. A
## 30 cm cylinder resting on it is the read-out: it should sit dead still.
##
## The mesh is upstream's `b3CreateBoxMesh({0, -1, 0}, {50, 1, 50}, true)`
## reproduced vertex for vertex and index for index (src/mesh.c:1455-1487) and
## handed to the node's raw `mesh_vertices` / `mesh_indices` path, which passes
## the winding through unchanged. Welding is off and the split is the default,
## as in that call.
##
## Activate cycles the body through upstream's four radio buttons: cylinder
## (r 0.15, h 0.3, 32 sides), sphere (r 0.5), 1 m box and the capsule. All of
## them spawn at upstream's (0.5, 0, 0), which puts the round ones half inside
## the ground -- watch box3d push them out.

const GROUND_CENTER := Vector3(0.0, -1.0, 0.0)
const GROUND_EXTENT := Vector3(50.0, 1.0, 50.0)
const SPAWN := Vector3(0.5, 0.0, 0.0)
const ROLLING_RESISTANCE := 0.05
const CYLINDER_RADIUS := 0.15
const CYLINDER_HEIGHT := 0.3
const CYLINDER_SIDES := 32
const SPHERE_RADIUS := 0.5
const BOX_SIZE := Vector3(1.0, 1.0, 1.0)
## Upstream's capsule runs along z from 0.476 to 1.276 with radius 0.15.
const CAPSULE_RADIUS := 0.15
const CAPSULE_HEIGHT := 1.1
const CAPSULE_CENTER := Vector3(0.0, 0.0, 0.876)

var camera_home := Vector3(3.7, 3.0, 3.7)
var camera_look_at := Vector3(0.0, 0.0, 0.0)

var _shapes := ["cylinder", "sphere", "box", "capsule"]
var _index := 0
var _body: Box3DBody
var _material := StandardMaterial3D.new()


func _ready() -> void:
	_material.albedo_color = Color(0.9, 0.7, 0.3)
	_material.roughness = 0.4

	# Indices first: each setter rebuilds the shape, and a vertex list with no
	# triangles yet is not a legal mesh.
	var ground: Box3DBody = $Box3DWorld/Ground
	ground.mesh_indices = _box_mesh_indices()
	ground.mesh_vertices = _box_mesh_vertices()
	_spawn()


## The shell's reusable Activate button: upstream's shape radio buttons.
func activate() -> void:
	_index = (_index + 1) % _shapes.size()
	_spawn()


func _spawn() -> void:
	if _body != null:
		_body.queue_free()
	_body = Box3DBody.new()
	_body.name = "Body"
	_body.rolling_resistance = ROLLING_RESISTANCE
	_body.position = SPAWN
	var visual := MeshInstance3D.new()
	visual.material_override = _material
	match _shapes[_index]:
		"cylinder":
			_body.shape_type = Box3DBody.CYLINDER
			_body.capsule_radius = CYLINDER_RADIUS
			_body.capsule_height = CYLINDER_HEIGHT
			_body.cylinder_sides = CYLINDER_SIDES
			var cm := CylinderMesh.new()
			cm.top_radius = CYLINDER_RADIUS
			cm.bottom_radius = CYLINDER_RADIUS
			cm.height = CYLINDER_HEIGHT
			cm.radial_segments = CYLINDER_SIDES
			visual.mesh = cm
		"sphere":
			_body.shape_type = Box3DBody.SPHERE
			_body.sphere_radius = SPHERE_RADIUS
			var sm := SphereMesh.new()
			sm.radius = SPHERE_RADIUS
			sm.height = 2.0 * SPHERE_RADIUS
			visual.mesh = sm
		"box":
			_body.shape_type = Box3DBody.BOX
			_body.box_size = BOX_SIZE
			var bm := BoxMesh.new()
			bm.size = BOX_SIZE
			visual.mesh = bm
		"capsule":
			# Upstream's capsule is authored off the body origin and along z,
			# so it needs a child shape node: the body's own shape_type is
			# always centred on the origin and runs along y.
			var shape := Box3DCollisionShape.new()
			shape.shape_type = 2
			shape.capsule_radius = CAPSULE_RADIUS
			shape.capsule_height = CAPSULE_HEIGHT
			shape.rolling_resistance = ROLLING_RESISTANCE
			shape.transform = Transform3D(Basis(Vector3.RIGHT, 0.5 * PI), CAPSULE_CENTER)
			_body.add_child(shape)
			var cap := CapsuleMesh.new()
			cap.radius = CAPSULE_RADIUS
			cap.height = CAPSULE_HEIGHT
			visual.mesh = cap
			visual.transform = Transform3D(Basis(Vector3.RIGHT, 0.5 * PI), CAPSULE_CENTER)
	_body.add_child(visual)
	$Box3DWorld.add_child(_body)


## b3CreateBoxMesh's eight corners, in its order (src/mesh.c:1460-1467).
func _box_mesh_vertices() -> PackedVector3Array:
	var e := GROUND_EXTENT
	var v := PackedVector3Array([
		Vector3(e.x, e.y, e.z), Vector3(-e.x, e.y, e.z),
		Vector3(-e.x, -e.y, e.z), Vector3(e.x, -e.y, e.z),
		Vector3(e.x, e.y, -e.z), Vector3(-e.x, e.y, -e.z),
		Vector3(-e.x, -e.y, -e.z), Vector3(e.x, -e.y, -e.z),
	])
	for i in v.size():
		v[i] += GROUND_CENTER
	return v


## Its twelve triangles, unchanged (src/mesh.c:1469-1476).
func _box_mesh_indices() -> PackedInt32Array:
	return PackedInt32Array([
		0, 1, 3, 1, 2, 3,  # front
		0, 4, 1, 1, 4, 5,  # top
		0, 3, 7, 4, 0, 7,  # right
		4, 7, 5, 6, 5, 7,  # back
		1, 5, 2, 6, 2, 5,  # left
		3, 2, 7, 6, 7, 2,  # bottom
	])
