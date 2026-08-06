extends Node3D

## Mesh Tile -- a port of upstream's "Compound / Mesh Tile" sample
## (samples/sample_compound.cpp:363). ONE box mesh is authored once and placed
## four times, 2 x 2, each instance dropped to its own random height so the
## tiles meet in steps rather than a flat floor. The mesh is
## `b3CreateBoxMesh({0,0,0}, {a, 0.5a, a}, true)` with a = 4, i.e. an 8 x 4 x 8 m
## shell of 8 vertices and 12 triangles, reproduced vertex for vertex and index
## for index (src/mesh.c:1455-1487) and handed to the node's raw
## `mesh_vertices` / `mesh_indices` path. Weld tolerance 0 and median split off,
## exactly as that call sets them.
##
## DEVIATION, and it is the reason this port was last in the queue: upstream
## packs the four instances into ONE baked compound
## (`b3CompoundMeshDef` -> `b3CreateCompound` -> `b3CreateBakedCompoundShape`),
## so the world keeps a single broad-phase proxy and the compound's own tree
## resolves which instance was hit. `Box3DBody.baked_compound` builds a compound
## from its `Box3DCollisionShape` children, and that node authors hulls, spheres
## and capsules only -- there is no way to put a mesh in a compound from script
## (godot/src/box3d_body.cpp:1161, "No meshes"). So each instance is its own
## static MESH body here: same geometry, same placement, same shared source
## data, four proxies instead of one. The single-proxy baked compound is what
## "Compound / Tile Floor" already shows, with hulls.
##
## The two props are upstream's own, taken out of the `#if 0` and the commented
## block it leaves at the end of the constructor: a 0.25 m sphere at (3, 12, 0)
## and a 0.4 x 0.6 x 0.8 m box at (0, 10, 2). Without them the sample renders a
## floor and nothing happens to it. Activate drops them again.

## Upstream's gridCount and 'a'.
const GRID_COUNT := 2
const A := 4.0
## b3CreateBoxMesh takes HALF extents: the tile is 8 x 4 x 8 m.
const TILE_EXTENT := Vector3(A, 0.5 * A, A)

const BALL_RADIUS := 0.25
const BALL_START := Vector3(3.0, 12.0, 0.0)
## b3MakeBoxHull(0.2, 0.3, 0.4) is half extents, so the full size is doubled.
const CRATE_SIZE := Vector3(0.4, 0.6, 0.8)
const CRATE_START := Vector3(0.0, 10.0, 2.0)

## SetView(45, 30, 45, origin).
var camera_home := Vector3(27.6, 22.5, 27.6)
var camera_look_at := Vector3(0.0, 0.0, 0.0)

var _tiles: Array[Box3DBody] = []
var _ball: Box3DBody
var _crate: Box3DBody


func _ready() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 0x4d3511e0

	# Authored once, instanced four times -- upstream's `meshes[index].meshData
	# = box`. Box3D copies the data into each shape, so the sharing here is of
	# the source arrays, not of one b3MeshData.
	var vertices := _box_mesh_vertices()
	var indices := _box_mesh_indices()
	var surface := _box_surface(vertices, indices)

	for i in GRID_COUNT:
		var x := (2.0 * i - GRID_COUNT) * A
		for j in GRID_COUNT:
			var z := (2.0 * j - GRID_COUNT) * A
			var y := rng.randf_range(-0.5, 0.25) * A
			_tiles.append(_make_tile(vertices, indices, surface, Vector3(x, y, z)))

	_spawn_props()


## The shell's reusable Activate button: drop the two props again.
func activate() -> void:
	_spawn_props()


## One instance of the shared mesh, placed by the node's own transform the way
## `b3CompoundMeshDef.transform` places it upstream.
func _make_tile(p_vertices: PackedVector3Array, p_indices: PackedInt32Array,
		p_surface: ArrayMesh, p_position: Vector3) -> Box3DBody:
	var tile := Box3DBody.new()
	tile.name = "Tile%d_%d" % [int(p_position.x), int(p_position.z)]
	tile.body_type = Box3DBody.STATIC
	tile.shape_type = Box3DBody.MESH
	# b3CreateBoxMesh's own b3MeshDef is zero-initialised: no welding, no
	# median split. The node defaults to a 1 mm weld tolerance.
	tile.mesh_weld_tolerance = 0.0
	tile.mesh_median_split = false
	# Indices before vertices: a vertex list with no triangles is not a legal
	# mesh, and each setter rebuilds. Neither is live yet -- the body only joins
	# the world once both are set.
	tile.mesh_indices = p_indices
	tile.mesh_vertices = p_vertices
	tile.position = p_position

	var visual := MeshInstance3D.new()
	visual.name = "TileVisual"
	visual.mesh = p_surface
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.3, 0.36, 0.33).lerp(
			Color(0.62, 0.66, 0.5), clampf((p_position.y + 2.0) / 3.0, 0.0, 1.0))
	mat.roughness = 0.85
	visual.material_override = mat
	tile.add_child(visual)

	$Box3DWorld.add_child(tile)
	return tile


func _spawn_props() -> void:
	if _ball != null:
		_ball.queue_free()
	if _crate != null:
		_crate.queue_free()

	_ball = Box3DBody.new()
	_ball.name = "Ball"
	_ball.shape_type = Box3DBody.SPHERE
	_ball.sphere_radius = BALL_RADIUS
	_ball.position = BALL_START
	var sphere := SphereMesh.new()
	sphere.radius = BALL_RADIUS
	sphere.height = 2.0 * BALL_RADIUS
	_ball.add_child(_visual(sphere, Color(0.9, 0.45, 0.2)))
	$Box3DWorld.add_child(_ball)

	_crate = Box3DBody.new()
	_crate.name = "Crate"
	_crate.shape_type = Box3DBody.BOX
	_crate.box_size = CRATE_SIZE
	_crate.position = CRATE_START
	var box := BoxMesh.new()
	box.size = CRATE_SIZE
	_crate.add_child(_visual(box, Color(0.85, 0.75, 0.35)))
	$Box3DWorld.add_child(_crate)


func _visual(p_mesh: Mesh, p_color: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = p_color
	mat.roughness = 0.35
	mi.mesh = p_mesh
	mi.material_override = mat
	return mi


## b3CreateBoxMesh's eight corners, in its order (src/mesh.c:1460-1467). The
## instance is centred on its body, so the mesh's own centre is the origin.
func _box_mesh_vertices() -> PackedVector3Array:
	var e := TILE_EXTENT
	return PackedVector3Array([
		Vector3(e.x, e.y, e.z), Vector3(-e.x, e.y, e.z),
		Vector3(-e.x, -e.y, e.z), Vector3(e.x, -e.y, e.z),
		Vector3(e.x, e.y, -e.z), Vector3(-e.x, e.y, -e.z),
		Vector3(-e.x, -e.y, -e.z), Vector3(e.x, -e.y, -e.z),
	])


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


## The same triangles as a Godot surface, so what is drawn is what box3d
## collides. Box3D's winding is the opposite of Godot's, and reversing it is
## Box3DGeometry.make_array_mesh's job -- one bridge, one flat-shaded face per
## triangle.
func _box_surface(p_vertices: PackedVector3Array, p_indices: PackedInt32Array) -> ArrayMesh:
	return Box3DGeometry.make_array_mesh({"vertices": p_vertices, "indices": p_indices})


func get_tiles() -> Array[Box3DBody]:
	return _tiles


func get_ball() -> Box3DBody:
	return _ball


func get_crate() -> Box3DBody:
	return _crate
