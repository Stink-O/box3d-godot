extends Node3D

## Ball Fountain toy: a spout sprays a steady stream of balls up into the air;
## they arc over and rain back down into the basin, building a lively column
## and a pool that holds a few hundred balls before the oldest recycle.
## Shoot your own in with F.

const Despawn = preload("res://common/despawn.gd")

const PERIOD := 0.13
const LIFETIME := 20.0
const UP_SPEED := 12.5

var _world: Box3DWorld
var _t := 0.0
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_world = $Box3DWorld
	_rng.randomize()


func _physics_process(delta: float) -> void:
	_t += delta
	if _t >= PERIOD:
		_t = 0.0
		_spray()


func _spray() -> void:
	var b := Box3DBody.new()
	b.shape_type = Box3DBody.SPHERE
	b.sphere_radius = 0.28
	b.restitution = 0.35
	b.friction = 0.2
	b.position = Vector3(0, 3.3, 0)
	_world.add_child(b)
	b.set_linear_velocity(Vector3(_rng.randf_range(-1.8, 1.8), UP_SPEED, _rng.randf_range(-1.8, 1.8)))

	var mi := MeshInstance3D.new()
	var m := SphereMesh.new()
	m.radius = 0.28
	m.height = 0.56
	mi.mesh = m
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color.from_hsv(_rng.randf_range(0.5, 0.7), 0.6, 0.95)
	mat.roughness = 0.25
	mat.metallic = 0.1
	mi.material_override = mat
	b.add_child(mi)

	Despawn.attach(b, LIFETIME)
