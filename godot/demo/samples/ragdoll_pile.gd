extends Node3D

## Ragdoll Pile -- a port of upstream's "Ragdoll / Pile" sample
## (samples/sample_ragdoll.cpp:208-260). Twenty of upstream's human ragdolls
## dropped together onto a triangle-mesh floor, where they fall into a
## tangled heap and settle.
##
## Upstream's numbers are kept: the floor is b3CreateGridMesh(20, 20, 1, 1,
## true) on a static body at (0, -1, 0) (:219-224); the humans are upstream's
## CreateHuman prefab (shared/human.c, ported in common/human.gd) with joint
## friction torque 10, spring hertz 0.5 and damping ratio 0.7 (:233-236),
## each spawned at (x, 2, z) with x and z from upstream's own RandomVec3 over
## [-2, 2] (a = 0.1 * count, :227-232) after seeding g_randomSeed = 42, and
## each with its own group index i (:237), so human i's spine and thighs
## ignore each other. The count is upstream's release build's 20 (:254; its
## debug build drops to 8).
##
## The random draws are upstream's XorShift32 (shared/utils.h:29-38) walked
## from 42 through RandomFloatRange / RandomVec3 (:56-71) in x, y, z order,
## as Spinning Stick does, so the pile starts exactly where upstream's does.

const Human := preload("res://common/human.gd")

const COUNT := 20
const FRICTION_TORQUE := 10.0
const HERTZ := 0.5
const DAMPING := 0.7
const SEED := 42
## shared/utils.h:8.
const RAND_LIMIT := 32767
const UINT32_MASK := 0xFFFFFFFF

## m_camera->SetView(180, 30, 20, origin) (:216): eye = pivot + radius *
## (sin yaw cos pitch, sin pitch, cos yaw cos pitch)
## (samples/host/camera.cpp:35-39,216-220).
var camera_home := 20.0 * Vector3(
		sin(deg_to_rad(180.0)) * cos(deg_to_rad(30.0)),
		sin(deg_to_rad(30.0)),
		cos(deg_to_rad(180.0)) * cos(deg_to_rad(30.0)))
var camera_look_at := Vector3.ZERO

var humans: Array = []
var _random_seed := SEED


func _ready() -> void:
	var world := $Box3DWorld
	var skins := [Color(1.0, 0.871, 0.678), Color(1.0, 1.0, 0.878), Color(0.804, 0.522, 0.247),
			Color(0.824, 0.706, 0.549)]  # upstream's skin colours (shared/human.c:43)
	# The floor: b3CreateGridMesh(20, 20, 1, 1, true) at (0, -1, 0) (:219-224).
	var grid: Dictionary = Box3DGeometry.create_grid_mesh(20, 20, 1.0, 1, true)
	var ground := Box3DBody.new()
	ground.name = "Ground"
	ground.body_type = Box3DBody.STATIC
	ground.shape_type = Box3DBody.MESH
	ground.mesh_vertices = grid["vertices"]
	ground.mesh_indices = grid["indices"]
	ground.position = Vector3(0.0, -1.0, 0.0)
	var floor_visual := MeshInstance3D.new()
	floor_visual.mesh = Box3DGeometry.make_array_mesh(grid)
	var floor_material := StandardMaterial3D.new()
	floor_material.albedo_color = Color(0.2, 0.22, 0.26)
	floor_material.roughness = 0.55
	floor_visual.material_override = floor_material
	ground.add_child(floor_visual)
	world.add_child(ground)

	var a := 0.1 * COUNT
	for i in range(COUNT):
		var offset := Vector3(_random_float_range(-a, a), _random_float_range(-a, a), _random_float_range(-a, a))
		var holder := Node3D.new()
		holder.name = "Human%d" % i
		world.add_child(holder)
		var material := StandardMaterial3D.new()
		material.albedo_color = skins[i % 4]
		material.roughness = 0.6
		humans.append(Human.create(holder, Vector3(offset.x, 2.0, offset.z), FRICTION_TORQUE, HERTZ,
				DAMPING, i, material))


## Upstream's RandomInt, XorShift32 (shared/utils.h:27-38), masked to uint32.
func _random_int() -> int:
	var x: int = _random_seed
	x ^= (x << 13) & UINT32_MASK
	x ^= x >> 17
	x ^= (x << 5) & UINT32_MASK
	x &= UINT32_MASK
	_random_seed = x
	return x % (RAND_LIMIT + 1)


## Upstream's RandomFloatRange (shared/utils.h:56-62).
func _random_float_range(lo: float, hi: float) -> float:
	var r := float(_random_int() & RAND_LIMIT) / float(RAND_LIMIT)
	return (hi - lo) * r + lo


func rig_notes() -> Array:
	return ["The twenty humans are built in code from upstream's capsule ragdoll "
			+ "prefab, which the comparison rig does not rebuild; only the mesh floor is."]
