extends Node3D

## Spinning Stick -- a port of upstream's "Continuous / Spinning Stick" sample
## (samples/sample_continuous.cpp). A 4 m stick is dropped onto the edge of a
## thin wall at 100 m/s while spinning at up to 50 rad/s about a random axis.
## That combination is the hard case for continuous collision: the body's
## CENTRE barely moves per step while its ends sweep several metres, so a
## solver that only sweeps the centre lets the stick scissor straight through
## the wall.
##
## Upstream's numbers are kept: wall 0.25 x 1 x 20 m with its top at y = 1,
## stick 4 x 0.2 x 0.2 m dropped from y = 20 with rolling resistance 0.1, and
## an angular velocity drawn uniformly from [-50, 50] rad/s per axis. Like
## upstream it relies on box3d's default sweep -- `continuous` (isBullet) and
## `allow_fast_rotation` are both left off, and the stick still stays out of
## the wall.
##
## Activate drops a fresh stick with a new random spin (upstream restarts the
## sample). The toggle arms `allow_fast_rotation` on the NEXT stick: that lifts
## box3d's cap of half a revolution per substep, which is what upstream's
## b3BodyDef.allowFastRotation is for.

const STICK_SIZE := Vector3(4.0, 0.2, 0.2)
const STICK_START := Vector3(0.0, 20.0, 0.5)
const DROP_SPEED := 100.0
const SPIN_RANGE := 50.0
const ROLLING_RESISTANCE := 0.1

var camera_home := Vector3(12.8, 10.5, 12.8)
var camera_look_at := Vector3(0.0, 2.0, 0.0)

var _sticks: Node3D
var _fast_rotation := false
var _rng := RandomNumberGenerator.new()
var _mesh := BoxMesh.new()
var _material := StandardMaterial3D.new()


func _ready() -> void:
	_rng.seed = 20260805
	_mesh.size = STICK_SIZE
	_material.albedo_color = Color(0.9, 0.6, 0.25)
	_material.roughness = 0.4

	_sticks = Node3D.new()
	_sticks.name = "Sticks"
	$Box3DWorld.add_child(_sticks)
	_drop()


## The shell's reusable Activate button: another stick, another random spin.
func activate() -> void:
	_drop()


func get_toggle_label() -> String:
	return "Fast Rotation"


func set_toggled(on: bool) -> void:
	_fast_rotation = on


func _drop() -> void:
	var stick := Box3DBody.new()
	stick.box_size = STICK_SIZE
	stick.rolling_resistance = ROLLING_RESISTANCE
	stick.allow_fast_rotation = _fast_rotation
	stick.position = STICK_START
	var visual := MeshInstance3D.new()
	visual.mesh = _mesh
	visual.material_override = _material
	stick.add_child(visual)
	_sticks.add_child(stick)
	stick.set_linear_velocity(Vector3(0.0, -DROP_SPEED, 0.0))
	stick.set_angular_velocity(Vector3(
			_rng.randf_range(-SPIN_RANGE, SPIN_RANGE),
			_rng.randf_range(-SPIN_RANGE, SPIN_RANGE),
			_rng.randf_range(-SPIN_RANGE, SPIN_RANGE)))
