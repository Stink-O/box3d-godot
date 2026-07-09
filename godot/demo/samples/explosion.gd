extends Node3D

## Explosion sample / toy: a stacked "building". Press the top-bar Activate
## button to set off a blast at its base -- it flings the blocks with
## Box3DWorld.explode and plays the shared ExplosionFX flash (a bright sphere
## that expands and fades). Reset rebuilds it. The bomb marker gently pulses so
## you know where the blast goes off.

const ExplosionFX = preload("res://common/explosion_fx.gd")

const CENTER := Vector3(0, 1.0, 0)
const RADIUS := 10.0
const IMPULSE := 8.0

var _world: Box3DWorld
var _t := 0.0
@onready var _bomb: MeshInstance3D = $Box3DWorld/Bomb


func _ready() -> void:
	_world = $Box3DWorld


# Called by the shell's reusable "Activate" button.
func activate() -> void:
	ExplosionFX.blast(_world, CENTER, RADIUS, IMPULSE)


func _process(delta: float) -> void:
	if _bomb != null:
		_t += delta
		var s := 1.0 + 0.15 * sin(_t * 6.0)
		_bomb.scale = Vector3(s, s, s)
