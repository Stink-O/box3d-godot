extends Node3D

## Ball Fountain toy: a spout sprays a steady stream of balls up into the air;
## they arc over and rain back down into the basin, building a lively column
## and a pool that holds a few hundred balls before the oldest recycle.
## Shoot your own in with F.

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

	_attach_lifetime(b, LIFETIME)


## Self-contained despawn: the timer is a child of the body itself, so the two
## are always freed together (no captured-node lambda that can dangle when the
## sample unloads and the body is freed out from under a scene-tree timer).
func _attach_lifetime(body: Box3DBody, lifetime: float) -> void:
	var timer := Timer.new()
	timer.wait_time = lifetime
	timer.one_shot = true
	timer.autostart = true
	body.add_child(timer)
	timer.timeout.connect(body.queue_free)
