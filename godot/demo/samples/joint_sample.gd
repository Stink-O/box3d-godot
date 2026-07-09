extends Node3D

## Behavior for the Joint Sampler sample: oscillates the motorized slider and
## gives the chain an initial nudge so it sways.

var _slider: Box3DSliderJoint
var _chain_tail: Box3DBody
var _dir := 1.0
var _timer := 0.0


func _ready() -> void:
	var world := $Box3DWorld
	_slider = world.get_node_or_null("SliderJoint")
	_chain_tail = world.get_node_or_null("ChainLink4")
	if _chain_tail:
		_chain_tail.apply_central_impulse(Vector3(2.5, 0, 1.2))


func _physics_process(delta: float) -> void:
	if _slider:
		_timer += delta
		if _timer > 1.4:
			_timer = 0.0
			_dir = -_dir
			_slider.motor_speed = 3.0 * _dir
