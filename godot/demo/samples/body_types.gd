extends Node3D

## Body Types sample / toy: shows static, kinematic and dynamic bodies together.
## You animate a KINEMATIC body's node transform and the sim makes it shove
## dynamic bodies around. Here a kinematic platform slides back and forth
## (carrying and toppling a stack of dynamic crates) and a kinematic piston pops
## up to launch crates. The static block just sits there.

var _t := 0.0
var _platform: Box3DBody
var _piston: Box3DBody
var _plat_home: Vector3
var _piston_home: Vector3


func _ready() -> void:
	_platform = $Box3DWorld/KinematicPlatform
	_piston = $Box3DWorld/Piston
	_plat_home = _platform.position
	_piston_home = _piston.position


func _physics_process(delta: float) -> void:
	_t += delta
	# Kinematic bodies follow the node transform you set — the solver turns that
	# motion into pushes on the dynamic crates.
	_platform.position = _plat_home + Vector3(sin(_t * 1.1) * 4.0, 0.0, 0.0)
	var lift: float = maxf(0.0, sin(_t * 1.6))
	_piston.position = _piston_home + Vector3(0.0, lift * lift * 2.0, 0.0)
