extends Node3D

## Ray & Shape Cast sample / toy: a laser beam sweeps around a central emitter,
## raycasting each frame. Whatever it hits lights up (and a marker sits at the
## impact point), so it reads like a radar sweep. Targets are dynamic — shoot or
## drag them (F / left-drag) and the sweep tracks them. Uses Box3DWorld.raycast.

const RANGE := 26.0
const SWEEP_SPEED := 1.3  # rad/s
const ORIGIN := Vector3(0, 1.6, 0)

var _angle := 0.0
var _world: Box3DWorld
var _beam: MeshInstance3D
var _marker: MeshInstance3D
var _mats: Dictionary = {}
var _glow: Dictionary = {}


func _ready() -> void:
	_world = $Box3DWorld
	_beam = $Beam
	_marker = $HitMarker
	for t in $Box3DWorld/Targets.get_children():
		if t is Box3DBody:
			var mi := t.get_node("MeshInstance3D") as MeshInstance3D
			var mat: StandardMaterial3D = mi.material_override.duplicate()
			mat.emission_enabled = true
			mat.emission = Color(1.0, 0.35, 0.2)
			mat.emission_energy_multiplier = 0.0
			mi.material_override = mat
			_mats[t] = mat
			_glow[t] = 0.0


func _physics_process(delta: float) -> void:
	_angle = wrapf(_angle + SWEEP_SPEED * delta, 0.0, TAU)
	var dir := Vector3(cos(_angle), 0.0, sin(_angle))
	var endpoint := ORIGIN + dir * RANGE
	var hit := _world.raycast(ORIGIN, endpoint)
	if hit.get("hit", false):
		endpoint = hit["position"]
		var body = hit.get("collider")
		if body != null and _glow.has(body):
			_glow[body] = 1.0
		_marker.visible = true
		_marker.global_position = endpoint
	else:
		_marker.visible = false
	_stretch_beam(ORIGIN, endpoint)


func _process(delta: float) -> void:
	for b in _mats:
		if _glow[b] > 0.0:
			_glow[b] = maxf(0.0, _glow[b] - delta * 2.2)
			_mats[b].emission_energy_multiplier = _glow[b] * 4.0


# Orient/scale the (Y-aligned, height-1) beam cylinder to span a -> b.
func _stretch_beam(a: Vector3, b: Vector3) -> void:
	var d := b - a
	var length := d.length()
	if length < 0.001:
		return
	var y := d / length
	var ref := Vector3.UP if absf(y.y) < 0.99 else Vector3.FORWARD
	var x := ref.cross(y).normalized()
	var z := x.cross(y)
	# Stretch the y COLUMN (the mesh's local height axis): Basis.scaled() scales
	# rows (global axes), which for this horizontal beam would leave its length
	# at 1 and smear its cross-section vertically instead.
	_beam.transform = Transform3D(Basis(x, y * length, z), (a + b) * 0.5)
