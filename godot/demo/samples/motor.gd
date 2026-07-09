extends Node3D

## Motorized sample / toy: a hinge motor spins a turntable up to speed — the
## boxes riding it slide out and fling off (shoot more onto it with F). A second
## motor whirls a windmill bar that swats boxes around. Uses Box3DHingeJoint's
## motor (motor_speed set live each frame).

const TURN_TARGET := 5.5   # rad/s
const TURN_RAMP := 2.5     # spin-up rate
const WIND_SPEED := 3.5

var _turn: Box3DHingeJoint
var _wind: Box3DHingeJoint
var _speed := 0.0


func _ready() -> void:
	_turn = $Box3DWorld/TurntableJoint
	_wind = $Box3DWorld/WindmillJoint


func _physics_process(delta: float) -> void:
	# Set motor speeds live each frame — the joints are created deferred, so a
	# one-time set in _ready can land before the joint exists.
	_speed = minf(TURN_TARGET, _speed + TURN_RAMP * delta)
	if _turn != null:
		_turn.motor_speed = _speed
	if _wind != null:
		_wind.motor_speed = WIND_SPEED
