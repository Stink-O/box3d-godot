extends Node3D

## Pool Break toy: fifteen balls racked in a triangle; the cue ball is shot into
## them on load for a satisfying scatter. Shoot more balls with F, grab any ball
## to line up your own shot, or Reset to re-rack.

const BREAK_SPEED := 24.0


func _ready() -> void:
	var cue := $Box3DWorld.get_node_or_null("Cue") as Box3DBody
	if cue != null:
		# aim just off-centre so the rack scatters instead of splitting clean
		cue.set_linear_velocity(Vector3(0.5, 0.0, -BREAK_SPEED))
