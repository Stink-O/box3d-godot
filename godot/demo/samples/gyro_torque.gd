extends Node3D

## Gyroscopic Torque — the Dzhanibekov effect (intermediate axis theorem).
## Port of upstream's "Gyroscopic Torque" sample (samples/sample_bodies.cpp):
## a T-handle — a slender rod (cylinder h 0.6, r 0.15) crossing a thin bar
## (2 x 0.1 x 0.2) — floats in a zero-gravity world (the scene's own
## gravity is (0,0,0), so the sidebar's Gravity Y honestly reads 0 and
## turning it up drops the handle onto the floor) and spins about its
## intermediate inertia axis at 10 rad/s with a tiny
## perturbation, with zero angular damping so the spin never decays (the
## binding's default damping would bleed it). Gyroscopic torque makes it
## periodically flip 180 degrees, exactly like the famous wing-nut footage
## from Salyut 7. Use Reset to restart the spin.

var camera_home := Vector3(0.0, 3.4, 4.4)
var camera_look_at := Vector3(0.0, 2.0, 0.0)

@onready var _handle: Box3DBody = $Box3DWorld/Handle


func _ready() -> void:
	# Upstream's initial state: spin about local Z (the intermediate axis)
	# with a small perturbation on the other two axes to seed the flip.
	_handle.set_angular_velocity(Vector3(0.01, 0.01, 10.0))
