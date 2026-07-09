extends Node3D

## Ragdoll: a hand-built humanoid (sphere head, box chest + pelvis, capsule
## limbs) linked by ball joints (neck, waist, shoulders, hips) and hinge joints
## (elbows, knees) with cone/twist/angle limits. Every bone collides with every
## other one, so it can't pass through itself — it crumples into a believable
## heap when it lands. A one-time mass-scaled shove gives each drop some variety.
## Use the Reset button to drop it again.

## Startup nudge, in meters/second of velocity change — NOT a raw impulse. A
## fixed impulse would kick a light bone to a huge speed and blow the ragdoll
## apart; scaling by the body's own mass keeps it a fixed *speed*. The figure
## spawns nearly upright, so it needs a firm shove up high (the chest) to topple
## and crumple — it has no muscles, so once tipped it always collapses.
const SHOVE_SPEED := 2.5


func _ready() -> void:
	var chest := $Box3DWorld/Body.get_node_or_null("chest") as Box3DBody
	if chest != null:
		var a := randf_range(0.0, TAU)
		var dir := Vector3(cos(a), 0.05, sin(a)).normalized()
		chest.apply_central_impulse(dir * chest.get_mass() * SHOVE_SPEED)
