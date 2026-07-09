extends Node3D

## Bowling toy: ten pins racked at the end of a lane. A ball rolls in on load
## for an opening strike; then shoot more balls down the lane with F, or hit
## Reset to re-rack. Just dynamic bodies + a rolling ball — no tricks.

const ROLL_SPEED := 15.0


func _ready() -> void:
	var ball := $Box3DWorld.get_node_or_null("Ball") as Box3DBody
	if ball != null:
		# a slight angle so it curves into the pocket for a livelier strike
		ball.set_linear_velocity(Vector3(0.6, 0.0, -ROLL_SPEED))
