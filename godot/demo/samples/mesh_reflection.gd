extends Node3D

## Reflection -- upstream's "Mesh / Reflection" sample
## (samples/sample_mesh.cpp:552) in spirit. Upstream loads
## `data/meshes/building.obj` twice, once at scale (1,1,1) and once mirrored,
## and flips the sign of each axis LIVE with `b3Shape_SetMesh`; the point is
## that a negative scale reflects a triangle mesh and still collides correctly.
##
## Two things kept it out of the demo until now. The art asset is upstream's and
## this fork does not vendor art, so the building here is BUILT IN SCRIPT: five
## boxes stacked into a deliberately chiral silhouette (a stepped tower with a
## wing on +z and an awning on +x), each one `b3CreateBoxMesh`'s eight corners
## and twelve triangles (src/mesh.c:1455-1487) with the index list offset per
## box. And `b3Shape_SetMesh` was unbound, so the scale could not be changed
## after creation at all; it is `Box3DCollisionShape.set_mesh()` /
## `set_mesh_scale()` now (P-023), which is what this sample is here to show.
##
## Left copy: scale (1,1,1), never touched, the reference. Right copy: the SAME
## vertex and index arrays through `set_mesh()`, at whatever scale the Activate
## button has cycled to -- upstream's radio buttons. Only the sign changes, and
## the reflected mesh is a real collider, not a redrawn one: over 56 mirror-image
## ray pairs, at every scale in the cycle, the two copies report the same surface
## height to 0.0000000 m, and the awning authored at local x = +4.5 answers a ray
## at local x = -4.5 on the mirrored copy (top face y = 2.400) and nothing at all
## on its +x side. The crates settle on the silhouette they can see.
##
## Deviations, both deliberate: upstream also offers Neg Y, which here would
## bury the building under the ground mesh, so the cycle covers the x and z
## signs; and upstream gives its mesh three surface materials, which a shape
## node's `set_mesh()` has no argument for (`Box3DBody.surface_materials` is the
## per-triangle route, and it belongs to the body's own mesh shape).
##
## The ground is upstream's `b3CreateGridMesh(20, 20, 2.0, 2, true)`, a 40 x 40 m
## plane of 800 triangles, through the body's raw mesh path.

const GRID_CELLS := 20
const GRID_CELL_WIDTH := 2.0

const LEFT_AT := Vector3(-10.0, 0.0, 0.0)
const RIGHT_AT := Vector3(10.0, 0.0, 0.0)

## Upstream's scale cycle, minus Neg Y. The mirrored copy starts at (-1, 1, 1),
## as upstream's does.
const SCALES: Array[Vector3] = [
	Vector3(-1.0, 1.0, 1.0),
	Vector3(1.0, 1.0, 1.0),
	Vector3(1.0, 1.0, -1.0),
	Vector3(-1.0, 1.0, -1.0),
]

## The chiral silhouette: half extents and centres, in the mesh's own frame.
## Nothing here is symmetric about x or z, which is the whole point.
const BLOCKS: Array[Array] = [
	[Vector3(0.0, 1.0, 0.0), Vector3(3.0, 1.0, 3.0)],    # base slab
	[Vector3(1.0, 3.0, -0.5), Vector3(1.6, 1.0, 1.8)],   # second storey, off-centre
	[Vector3(2.0, 5.0, -1.0), Vector3(0.8, 1.0, 1.0)],   # top storey, further off
	[Vector3(-0.5, 2.5, 4.0), Vector3(1.2, 2.5, 1.0)],   # wing, +z only
	[Vector3(4.5, 2.2, 0.5), Vector3(1.5, 0.2, 1.5)],    # awning, +x only
]

## Upstream's rolling sphere.
const BALL_AT := Vector3(6.0, 15.0, 0.0)
const BALL_RADIUS := 0.5
const BALL_ROLLING_RESISTANCE := 0.2

## SetView(45, 30, 40, origin).
var camera_home := Vector3(24.5, 20.0, 24.5)
var camera_look_at := Vector3(0.0, 0.0, 0.0)

var _vertices: PackedVector3Array
var _indices: PackedInt32Array
var _mirror: Box3DCollisionShape
var _mirror_visual: MeshInstance3D
var _scale_index := 0
var _props: Array[Box3DBody] = []


func _ready() -> void:
	_vertices = _building_vertices()
	_indices = _building_indices()

	_build_ground()
	# Left: the reference, authored on the body itself and left alone.
	_build_copy(LEFT_AT, Vector3.ONE, false)
	# Right: the same arrays, retyped onto a child shape so set_mesh_scale can
	# reach them afterwards.
	_build_copy(RIGHT_AT, SCALES[_scale_index], true)
	_apply_scale()

	_spawn_props()


## The shell's reusable Activate button: upstream's scale radio buttons.
func activate() -> void:
	_scale_index = (_scale_index + 1) % SCALES.size()
	_apply_scale()


func get_mirror_scale() -> Vector3:
	return SCALES[_scale_index]


func get_mirror_shape() -> Box3DCollisionShape:
	return _mirror


func _apply_scale() -> void:
	var s: Vector3 = SCALES[_scale_index]
	# b3Shape_SetMesh's scale argument, live: the shape keeps its triangles and
	# is re-fitted at the new scale (src/shape.c:1640-1675).
	_mirror.set_mesh_scale(s)
	# The visual is rebuilt at that scale rather than node-scaled: a mirroring
	# scale reverses every triangle, and baking it into the surface is what
	# keeps the drawn side and the collidable side the same one.
	_mirror_visual.mesh = _surface(_vertices, _indices, s)


func _build_ground() -> void:
	var ground := Box3DBody.new()
	ground.name = "Ground"
	ground.body_type = Box3DBody.STATIC
	ground.shape_type = Box3DBody.MESH
	ground.mesh_weld_tolerance = 0.0
	ground.mesh_indices = _grid_indices()
	ground.mesh_vertices = _grid_vertices()

	var visual := MeshInstance3D.new()
	visual.name = "GroundVisual"
	visual.mesh = _surface(_grid_vertices(), _grid_indices())
	visual.material_override = _material(Color(0.24, 0.28, 0.3))
	ground.add_child(visual)
	$Box3DWorld.add_child(ground)


## One building. `p_mirrored` decides which route authors it: the body's own
## mesh (fixed for the lifetime of the shape) or a child shape retyped by
## set_mesh(), which is the only one that can be rescaled afterwards.
func _build_copy(p_at: Vector3, p_scale: Vector3, p_mirrored: bool) -> void:
	var body := Box3DBody.new()
	body.name = "Mirror" if p_mirrored else "Reference"
	body.body_type = Box3DBody.STATIC
	body.position = p_at

	var visual := MeshInstance3D.new()
	visual.name = "BuildingVisual"
	visual.mesh = _surface(_vertices, _indices, p_scale)
	visual.material_override = _material(
			Color(0.78, 0.5, 0.35) if p_mirrored else Color(0.45, 0.6, 0.72))
	body.add_child(visual)

	if p_mirrored:
		# The child starts as a token box because a Box3DCollisionShape has no
		# mesh shape type to author; set_mesh retypes the live shape.
		var shape := Box3DCollisionShape.new()
		shape.name = "MirrorMesh"
		shape.shape_type = Box3DCollisionShape.BOX
		shape.box_size = Vector3(0.1, 0.1, 0.1)
		body.add_child(shape)
		$Box3DWorld.add_child(body)
		shape.set_mesh(_vertices, _indices, p_scale)
		_mirror = shape
		_mirror_visual = visual
	else:
		body.shape_type = Box3DBody.MESH
		body.mesh_weld_tolerance = 0.0
		body.mesh_indices = _indices
		body.mesh_vertices = _vertices
		$Box3DWorld.add_child(body)


func _spawn_props() -> void:
	# Upstream's sphere, verbatim.
	var ball := Box3DBody.new()
	ball.name = "Ball"
	ball.shape_type = Box3DBody.SPHERE
	ball.sphere_radius = BALL_RADIUS
	ball.rolling_resistance = BALL_ROLLING_RESISTANCE
	ball.position = BALL_AT
	var sphere := SphereMesh.new()
	sphere.radius = BALL_RADIUS
	sphere.height = 2.0 * BALL_RADIUS
	var ball_visual := MeshInstance3D.new()
	ball_visual.mesh = sphere
	ball_visual.material_override = _material(Color(0.9, 0.45, 0.2))
	ball.add_child(ball_visual)
	$Box3DWorld.add_child(ball)
	_props.append(ball)

	# Upstream drops twenty ragdolls over the pair; a row of crates over each
	# building does the same job here -- something has to be standing on the
	# mirrored silhouette for the reflection to mean anything.
	var rng := RandomNumberGenerator.new()
	rng.seed = 0x9e11ec70
	for base in [LEFT_AT, RIGHT_AT]:
		for i in 6:
			var crate := Box3DBody.new()
			crate.name = "Crate%d_%d" % [int(base.x), i]
			crate.shape_type = Box3DBody.BOX
			crate.box_size = Vector3(0.7, 0.7, 0.7)
			crate.position = base + Vector3(
					rng.randf_range(-2.0, 4.5), 9.0 + 1.2 * i, rng.randf_range(-2.0, 4.5))
			var mesh := BoxMesh.new()
			mesh.size = crate.box_size
			var mi := MeshInstance3D.new()
			mi.mesh = mesh
			mi.material_override = _material(Color(0.85, 0.8, 0.45))
			crate.add_child(mi)
			$Box3DWorld.add_child(crate)
			_props.append(crate)


## b3CreateBoxMesh's eight corners and twelve triangles, once per block, with
## the indices offset by the running vertex count (src/mesh.c:1455-1487).
func _building_vertices() -> PackedVector3Array:
	var v := PackedVector3Array()
	for block in BLOCKS:
		var centre: Vector3 = block[0]
		var e: Vector3 = block[1]
		for corner in [
			Vector3(e.x, e.y, e.z), Vector3(-e.x, e.y, e.z),
			Vector3(-e.x, -e.y, e.z), Vector3(e.x, -e.y, e.z),
			Vector3(e.x, e.y, -e.z), Vector3(-e.x, e.y, -e.z),
			Vector3(-e.x, -e.y, -e.z), Vector3(e.x, -e.y, -e.z),
		]:
			v.append(centre + corner)
	return v


func _building_indices() -> PackedInt32Array:
	const BOX := [
		0, 1, 3, 1, 2, 3,
		0, 4, 1, 1, 4, 5,
		0, 3, 7, 4, 0, 7,
		4, 7, 5, 6, 5, 7,
		1, 5, 2, 6, 2, 5,
		3, 2, 7, 6, 7, 2,
	]
	var idx := PackedInt32Array()
	for b in BLOCKS.size():
		for i in BOX:
			idx.append(i + 8 * b)
	return idx


## b3CreateGridMesh(20, 20, 2.0, ...): x outer, z inner, two triangles per cell
## (src/mesh.c:1217-1290).
func _grid_vertices() -> PackedVector3Array:
	var v := PackedVector3Array()
	var half := 0.5 * GRID_CELL_WIDTH * GRID_CELLS
	for ix in GRID_CELLS + 1:
		for iz in GRID_CELLS + 1:
			v.append(Vector3(-half + ix * GRID_CELL_WIDTH, 0.0, -half + iz * GRID_CELL_WIDTH))
	return v


func _grid_indices() -> PackedInt32Array:
	var idx := PackedInt32Array()
	for ix in GRID_CELLS:
		for iz in GRID_CELLS:
			var i1 := iz + (GRID_CELLS + 1) * ix
			var i2 := i1 + 1
			var i3 := i2 + (GRID_CELLS + 1)
			var i4 := i3 - 1
			idx.append_array([i1, i2, i3, i3, i4, i1])
	return idx


## The same triangles as a Godot surface, at the same scale the collider is
## given. Box3D's winding is the opposite of Godot's and a mirroring scale
## reverses it once more; Box3DGeometry.make_array_mesh is where both are
## resolved, which is why the mirrored copy is REBUILT at the new scale rather
## than drawn through a negatively scaled node.
func _surface(p_vertices: PackedVector3Array, p_indices: PackedInt32Array,
		p_scale := Vector3.ONE) -> ArrayMesh:
	return Box3DGeometry.make_array_mesh(
			{"vertices": p_vertices, "indices": p_indices}, p_scale)


func _material(p_color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = p_color
	mat.roughness = 0.8
	return mat
