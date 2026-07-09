extends Node3D

## Motion Locks sample / toy: the pucks are locked to the table plane
## (lock_linear_y + lock_angular_x/z) so they stay flat and just glide and
## ricochet — an air-hockey table. The beads are locked to a single axis
## (everything but lock_linear_x) so they clack back and forth along their rail
## like an abacus. This script only kicks everything off with a starting shove.


func _ready() -> void:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	for p in $Box3DWorld/Pucks.get_children():
		if p is Box3DBody:
			var a := rng.randf_range(0.0, TAU)
			p.set_linear_velocity(Vector3(cos(a), 0.0, sin(a)) * rng.randf_range(7.0, 11.0))
	for b in $Box3DWorld/Beads.get_children():
		if b is Box3DBody:
			b.set_linear_velocity(Vector3(rng.randf_range(-7.0, 7.0), 0.0, 0.0))
