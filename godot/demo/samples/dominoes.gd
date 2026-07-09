extends Node3D

## Dominoes: a straight line of slabs. Nudges the first one to start the
## cascade. Use the Reset button to run it again.

const KICK_SPIN := 4.0


func _ready() -> void:
	var row := $Box3DWorld/Dominoes
	var first := row.get_child(0) as Box3DBody
	if first != null:
		# Spin the first slab forward about its wide (local Z) axis so its top
		# tips down the line, toppling into its neighbour to start the chain.
		first.set_angular_velocity(-first.global_transform.basis.z * KICK_SPIN)
