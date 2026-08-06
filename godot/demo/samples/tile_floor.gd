extends Node3D

## Tile Floor -- a port of upstream's "Compound / Tile Floor" sample
## (samples/sample_compound.cpp:245). A 50 x 50 grid of 8 x 4 x 8 m slabs at
## random heights, 2,500 of them, collapsed into ONE baked compound shape on a
## single static body.
##
## That is the whole point. As 2,500 separate shapes this floor would be 2,500
## broad-phase proxies to keep, refit and query; `b3CreateBakedCompoundShape`
## packs them into one blob with its own internal tree, so the world sees a
## single proxy and the compound's tree resolves the child underneath
## (box3d.h:831-834). It is what you want for static level geometry that is
## authored as pieces. Static, non-sensor bodies only -- Box3D asserts on both.
##
## Here that is `Box3DBody.baked_compound = true` (P-022) plus one
## `Box3DCollisionShape` child per slab. The slabs are drawn by a single
## static MultiMesh for the same reason the collider is one shape.
##
## The lone dynamic sphere is upstream's: 400 m of floor and one marble, to
## show the query landing on the right child of the compound.

const GRID_COUNT := 50
const A := 4.0  # upstream's 'a'
const TILE_SIZE := Vector3(2.0 * A, A, 2.0 * A)  # b3MakeBoxHull(a, 0.5a, a)

const FLOOR_ORIGIN := Vector3(-2.0, 1.0, -3.0)

const BALL_RADIUS := 0.25
const BALL_START := Vector3(3.0, 12.0, 0.0)

var camera_home := Vector3(27.6, 22.5, 27.6)
var camera_look_at := Vector3(0.0, 0.0, 0.0)

var _floor: Box3DBody
var _ball: Box3DBody


func _ready() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 0x71133100

	_floor = Box3DBody.new()
	_floor.name = "TileFloor"
	_floor.body_type = Box3DBody.STATIC
	_floor.baked_compound = true
	_floor.position = FLOOR_ORIGIN

	var transforms: Array[Transform3D] = []
	for i in GRID_COUNT:
		var x := (2.0 * i - GRID_COUNT) * A
		for j in GRID_COUNT:
			var z := (2.0 * j - GRID_COUNT) * A
			var y := rng.randf_range(-0.5, 0.25) * A
			var xf := Transform3D(Basis(), Vector3(x, y, z))
			transforms.append(xf)
			var tile := Box3DCollisionShape.new()
			tile.shape_type = Box3DCollisionShape.BOX
			tile.box_size = TILE_SIZE
			tile.transform = xf
			_floor.add_child(tile)

	_floor.add_child(_tile_multimesh(transforms))
	# Children first, then the world: the baked compound reads each child's
	# global transform as the body is created.
	$Box3DWorld.add_child(_floor)

	_ball = Box3DBody.new()
	_ball.name = "Ball"
	_ball.shape_type = Box3DBody.SPHERE
	_ball.sphere_radius = BALL_RADIUS
	_ball.position = BALL_START
	var visual := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = BALL_RADIUS
	sm.height = 2.0 * BALL_RADIUS
	visual.mesh = sm
	var ball_mat := StandardMaterial3D.new()
	ball_mat.albedo_color = Color(0.9, 0.45, 0.2)
	ball_mat.roughness = 0.3
	visual.material_override = ball_mat
	_ball.add_child(visual)
	$Box3DWorld.add_child(_ball)


## 2,500 slabs in one draw call. They never move, so this is written once.
func _tile_multimesh(p_transforms: Array[Transform3D]) -> MultiMeshInstance3D:
	var box := BoxMesh.new()
	box.size = TILE_SIZE
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.85
	box.material = mat

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = box
	mm.instance_count = p_transforms.size()
	for i in p_transforms.size():
		mm.set_instance_transform(i, p_transforms[i])
		# Height-keyed shading, so the random relief reads from the camera.
		var t: float = clampf((p_transforms[i].origin.y + 0.5 * A) / (0.75 * A), 0.0, 1.0)
		mm.set_instance_color(i, Color(0.28, 0.34, 0.3).lerp(Color(0.62, 0.66, 0.5), t))

	var mmi := MultiMeshInstance3D.new()
	mmi.name = "TileVisual"
	mmi.multimesh = mm
	return mmi


func get_floor_body() -> Box3DBody:
	return _floor


func get_ball() -> Box3DBody:
	return _ball
