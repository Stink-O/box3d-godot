extends Node3D

## Bullet vs Stack -- a port of upstream's "Continuous / Bullet vs Stack"
## sample (samples/sample_continuous.cpp:190). A ten-box tower stands in front
## of a thin wall; Activate fires a small, very dense sphere through it at
## 500 m/s from 20 m away.
##
## Two continuous-collision jobs in one shot. The bullet itself is 0.5 m across
## and travels 8.3 m per 60 Hz step, so without `continuous` it would pass the
## whole tower between two steps and never generate a contact at all. The wall
## behind the tower is 20 cm thick and catches both the bullet and everything
## the impact throws at it: that is the case a swept bullet has to get right
## against a static shape it is already most of the way through.
##
## Upstream keys this to 'L' and to an ImGui button; here it is the shell's
## Activate button, and firing again replaces the previous bullet.

const GROUND_EXTENT := 50.0  # Sample::AddGroundBox(50)

const WALL_CENTER := Vector3(-1.0, 4.0, 0.0)  # body at y=-1 + local (-1, 5, 0)
const WALL_SIZE := Vector3(0.2, 10.0, 20.0)  # b3MakeTransformedBoxHull(0.1, 5, 10)

const STACK_COUNT := 10
const BOX_SIZE := Vector3(1.0, 1.0, 1.0)  # b3MakeBoxHull(0.5, 0.5, 0.5)
const STACK_PITCH := 1.1

const BULLET_START := Vector3(20.5, 5.5, 0.0)
const BULLET_VELOCITY := Vector3(-500.0, 0.0, 0.0)
const BULLET_RADIUS := 0.25
const BULLET_DENSITY := 10.0  # shapeDef.density *= 10

var camera_home := Vector3(7.30, 12.26, 27.23)
var camera_look_at := Vector3(0.0, 2.0, 0.0)

var _bullet: Box3DBody
var _box_material := StandardMaterial3D.new()


func _ready() -> void:
	var world: Node = $Box3DWorld
	_box_material.albedo_color = Color(0.78, 0.68, 0.5)
	_box_material.roughness = 0.6

	# Sample::AddGroundBox: a static box at y = -1 with half extents
	# (extent, 1, extent), so its top face is exactly y = 0.
	var ground := Box3DBody.new()
	ground.name = "Ground"
	ground.body_type = Box3DBody.STATIC
	ground.shape_type = Box3DBody.BOX
	ground.box_size = Vector3(2.0 * GROUND_EXTENT, 2.0, 2.0 * GROUND_EXTENT)
	ground.position = Vector3(0.0, -1.0, 0.0)
	var ground_mat := StandardMaterial3D.new()
	ground_mat.albedo_color = Color(0.25, 0.28, 0.3)
	ground_mat.roughness = 0.9
	_add_box_visual(ground, ground.box_size, ground_mat)
	world.add_child(ground)

	# The backstop. Upstream hangs it off the same static body as a transformed
	# hull; as its own static body it is the same collider in the same place.
	var wall := Box3DBody.new()
	wall.name = "Wall"
	wall.body_type = Box3DBody.STATIC
	wall.shape_type = Box3DBody.BOX
	wall.box_size = WALL_SIZE
	wall.position = WALL_CENTER
	var wall_mat := StandardMaterial3D.new()
	wall_mat.albedo_color = Color(0.35, 0.4, 0.45)
	wall_mat.roughness = 0.7
	_add_box_visual(wall, WALL_SIZE, wall_mat)
	world.add_child(wall)

	for row in STACK_COUNT:
		var box := Box3DBody.new()
		box.name = "Box%d" % row
		box.shape_type = Box3DBody.BOX
		box.box_size = BOX_SIZE
		box.position = Vector3(0.0, 0.5 + STACK_PITCH * row, 0.0)
		box.angular_damping = 0.0  # b3DefaultBodyDef; the node defaults to 0.05
		_add_box_visual(box, BOX_SIZE, _box_material)
		world.add_child(box)


## The shell's Activate button: upstream's 'L' key / "Launch" button.
func activate() -> void:
	if _bullet != null and is_instance_valid(_bullet):
		_bullet.free()
	_bullet = Box3DBody.new()
	_bullet.name = "Bullet"
	_bullet.shape_type = Box3DBody.SPHERE
	_bullet.sphere_radius = BULLET_RADIUS
	_bullet.density = BULLET_DENSITY
	_bullet.continuous = true  # b3BodyDef.isBullet
	_bullet.angular_damping = 0.0
	_bullet.position = BULLET_START
	var visual := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = BULLET_RADIUS
	sm.height = 2.0 * BULLET_RADIUS
	visual.mesh = sm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.9, 0.3, 0.2)
	mat.metallic = 0.4
	visual.material_override = mat
	_bullet.add_child(visual)
	$Box3DWorld.add_child(_bullet)
	_bullet.set_linear_velocity(BULLET_VELOCITY)


func get_bullet() -> Box3DBody:
	return _bullet


func _add_box_visual(p_body: Box3DBody, p_size: Vector3, p_material: Material) -> void:
	var visual := MeshInstance3D.new()
	visual.name = "Visual"
	var bm := BoxMesh.new()
	bm.size = p_size
	visual.mesh = bm
	visual.material_override = p_material
	p_body.add_child(visual)
