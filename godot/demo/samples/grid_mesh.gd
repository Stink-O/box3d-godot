extends Node3D

## Grid -- a port of upstream's "Mesh / Grid" sample
## (samples/sample_mesh.cpp). The ground is `b3CreateGridMesh(20, 20, 1.0, 0,
## true)`: a 20 x 20 m plane cut into 800 triangles, handed to the node's raw
## `mesh_vertices` / `mesh_indices` path exactly as box3d builds it
## (src/mesh.c:1217-1290), and then SCALED by 2 into a 40 x 40 m field.
##
## The scale is the interesting part. `b3CreateMeshShape` takes a scale vector
## of its own and box3d applies it per triangle when it collides, so one mesh
## can be reused at several sizes without duplicating it. On the node that
## scale is simply the Godot node's scale -- the ground here is a Node3D
## scaled by 2, upstream's `m_scale = {2, 2, 2}`.
##
## A cylinder is dropped on it (upstream's default of the four shape radio
## buttons); Activate cycles through sphere, box and capsule the way those
## buttons do. Rolling on a tessellated plane is the case where a body can
## catch on the internal edges between triangles -- it should roll smoothly,
## which is what box3d's identifyEdges pass is for.

## b3CreateGridMesh(xCount, zCount, cellWidth, ...).
const CELLS := 20
const CELL_WIDTH := 1.0
const MESH_SCALE := Vector3(2.0, 2.0, 2.0)

const SPAWN := Vector3(0.1, 1.0, -0.1)
const CYLINDER_RADIUS := 0.25
const CYLINDER_HEIGHT := 1.0
const CYLINDER_SIDES := 15
const SPHERE_RADIUS := 0.5
const BOX_SIZE := Vector3(1.0, 1.0, 1.0)
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
	_material.albedo_color = Color(0.85, 0.75, 0.4)
	_material.roughness = 0.4

	# The ground is built here rather than in the scene because the mesh only
	# exists once these two arrays are set: a MESH body that entered the tree
	# with neither would warn about having no collider at all. Node scale is
	# b3CreateMeshShape's scale argument.
	var ground := Box3DBody.new()
	ground.name = "Ground"
	ground.body_type = Box3DBody.STATIC
	ground.shape_type = Box3DBody.MESH
	ground.mesh_weld_tolerance = 0.0
	ground.mesh_indices = _grid_indices()
	ground.mesh_vertices = _grid_vertices()
	ground.scale = MESH_SCALE

	var visual := MeshInstance3D.new()
	visual.name = "GridVisual"
	visual.mesh = _grid_surface()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.22, 0.26, 0.3)
	mat.roughness = 0.6
	visual.material_override = mat
	ground.add_child(visual)
	$Box3DWorld.add_child(ground)

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
	_body.position = SPAWN
	var visual := MeshInstance3D.new()
	visual.material_override = _material
	match _shapes[_index]:
		"cylinder":
			# Upstream's cylinder is built base-up from y = 0; the node centres
			# it on the body origin, so the body carries half its height.
			_body.shape_type = Box3DBody.CYLINDER
			_body.capsule_radius = CYLINDER_RADIUS
			_body.capsule_height = CYLINDER_HEIGHT
			_body.cylinder_sides = CYLINDER_SIDES
			_body.rolling_resistance = 0.02
			_body.angular_damping = 0.1
			_body.position = SPAWN + Vector3(0.0, 0.5 * CYLINDER_HEIGHT, 0.0)
			var cm := CylinderMesh.new()
			cm.top_radius = CYLINDER_RADIUS
			cm.bottom_radius = CYLINDER_RADIUS
			cm.height = CYLINDER_HEIGHT
			cm.radial_segments = CYLINDER_SIDES
			visual.mesh = cm
		"sphere":
			_body.shape_type = Box3DBody.SPHERE
			_body.sphere_radius = SPHERE_RADIUS
			_body.rolling_resistance = 0.05
			_body.angular_damping = 0.0
			var sm := SphereMesh.new()
			sm.radius = SPHERE_RADIUS
			sm.height = 2.0 * SPHERE_RADIUS
			visual.mesh = sm
		"box":
			_body.shape_type = Box3DBody.BOX
			_body.box_size = BOX_SIZE
			_body.angular_damping = 0.0
			var bm := BoxMesh.new()
			bm.size = BOX_SIZE
			visual.mesh = bm
		"capsule":
			# Authored off-centre and along z upstream, so it needs a child
			# shape node: the body's own capsule is centred and runs along y.
			_body.angular_damping = 0.0
			var shape := Box3DCollisionShape.new()
			shape.shape_type = 2
			shape.capsule_radius = CAPSULE_RADIUS
			shape.capsule_height = CAPSULE_HEIGHT
			shape.rolling_resistance = 0.05
			shape.transform = Transform3D(Basis(Vector3.RIGHT, 0.5 * PI), CAPSULE_CENTER)
			_body.add_child(shape)
			var cap := CapsuleMesh.new()
			cap.radius = CAPSULE_RADIUS
			cap.height = CAPSULE_HEIGHT
			visual.mesh = cap
			visual.transform = Transform3D(Basis(Vector3.RIGHT, 0.5 * PI), CAPSULE_CENTER)
	_body.add_child(visual)
	$Box3DWorld.add_child(_body)


## b3CreateGridMesh's grid points, in its order: x outer, z inner, both from
## -half the span (src/mesh.c:1221-1243).
func _grid_vertices() -> PackedVector3Array:
	var v := PackedVector3Array()
	var half := 0.5 * CELL_WIDTH * CELLS
	for ix in CELLS + 1:
		for iz in CELLS + 1:
			v.append(Vector3(-half + ix * CELL_WIDTH, 0.0, -half + iz * CELL_WIDTH))
	return v


## Its two triangles per cell, unchanged (src/mesh.c:1256-1277).
func _grid_indices() -> PackedInt32Array:
	var idx := PackedInt32Array()
	for ix in CELLS:
		for iz in CELLS:
			var i1 := iz + (CELLS + 1) * ix
			var i2 := i1 + 1
			var i3 := i2 + (CELLS + 1)
			var i4 := i3 - 1
			idx.append_array([i1, i2, i3, i3, i4, i1])
	return idx


## The same grid as a Godot surface. The triangles are box3d's -- CCW by the
## right-hand rule, normal pointing at the collidable side -- and
## Box3DGeometry.make_array_mesh is the one place that reverses them for
## Godot's opposite front-face convention.
func _grid_surface() -> ArrayMesh:
	return Box3DGeometry.make_array_mesh(
			{"vertices": _grid_vertices(), "indices": _grid_indices()})
