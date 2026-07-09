extends Node3D

## Contacts sample / toy: every bumper peg has contact_monitor on, so when a
## ball clatters into it (body_entered) the peg flashes bright and fades back.
## A steady rain of balls drops into the peg field so ricochets keep painting
## flashes and the pit builds up a real pile before the oldest balls recycle.
## Shoot (F) in a few extra and watch the trail. Demonstrates contact_monitor
## + body_entered.

const FLASH := Color(1.0, 0.85, 0.2)
const FADE := 6.0  # how fast the peg glow decays

const SPAWN_PERIOD := 0.4
const LIFETIME := 30.0
const BALL_RADIUS := 0.35

var _mats: Array = []   # StandardMaterial3D per peg
var _glow: Array = []   # current glow energy per peg

var _world: Box3DWorld
var _t := 0.0
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_world = $Box3DWorld
	_rng.randomize()
	for peg in $Box3DWorld/Pegs.get_children():
		if peg is Box3DBody:
			var mi := peg.get_node("MeshInstance3D") as MeshInstance3D
			var base := mi.material_override
			var mat: StandardMaterial3D = base.duplicate() if base != null else StandardMaterial3D.new()
			mat.emission_enabled = true
			mat.emission = FLASH
			mat.emission_energy_multiplier = 0.0
			mi.material_override = mat
			var idx := _mats.size()
			_mats.append(mat)
			_glow.append(0.0)
			peg.body_entered.connect(_on_hit.bind(idx))


func _on_hit(_other: Node, idx: int) -> void:
	_glow[idx] = 1.0


func _process(delta: float) -> void:
	for i in _mats.size():
		if _glow[i] > 0.0:
			_glow[i] = maxf(0.0, _glow[i] - delta * FADE)
			_mats[i].emission_energy_multiplier = _glow[i] * 5.0


func _physics_process(delta: float) -> void:
	_t += delta
	if _t >= SPAWN_PERIOD:
		_t = 0.0
		_drop_ball()


func _drop_ball() -> void:
	var b := Box3DBody.new()
	b.shape_type = Box3DBody.SPHERE
	b.sphere_radius = BALL_RADIUS
	b.restitution = 0.65
	b.density = 2.0
	b.position = Vector3(_rng.randf_range(-5.5, 5.5), _rng.randf_range(9.0, 13.0), _rng.randf_range(-5.5, 5.5))
	_world.add_child(b)
	b.set_linear_velocity(Vector3(_rng.randf_range(-0.8, 0.8), 0, _rng.randf_range(-0.8, 0.8)))

	var mi := MeshInstance3D.new()
	var m := SphereMesh.new()
	m.radius = BALL_RADIUS
	m.height = BALL_RADIUS * 2.0
	mi.mesh = m
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color.from_hsv(_rng.randf_range(0.0, 0.08), 0.7, 0.9)
	mat.roughness = 0.35
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
