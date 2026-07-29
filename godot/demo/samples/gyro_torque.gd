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

## Upstream's initial state: spin about local Z (the intermediate axis) with a
## small perturbation on the other two axes to seed the flip.
const SPIN := Vector3(0.01, 0.01, 10.0)

@onready var _handle: Box3DBody = $Box3DWorld/Handle


func _ready() -> void:
	_handle.set_angular_velocity(rig_body_motion()["Handle"]["angular_velocity"])


## The handle is authored in the .tscn but its spin is not: a starting velocity
## is not a scene property, so RigExtract (which never runs _ready) rebuilt a
## motionless handle on Godot Physics and Jolt. Publishing the spin here gives
## both builders one source -- _ready above applies it to the Box3D body, and
## the rig applies it to the RigidBody3D twin.
func rig_body_motion() -> Dictionary:
	return {"Handle": {"angular_velocity": SPIN}}


## Measured, not assumed: with the spin restored, Godot Physics and Jolt each
## hold the handle's spin axis on a smooth slow drift for a full minute, while
## Box3D swings it through repeated inversions over the same run. Neither
## native server integrates the gyroscopic term, so the flip -- the entire
## point of the sample -- cannot appear there, and a steadily spinning handle
## would otherwise read as the sample simply working.
func rig_notes() -> Array:
	return ["Gyroscopic torque is not integrated by Godot Physics or Jolt: "
			+ "the handle spins steadily instead of periodically flipping "
			+ "(the Dzhanibekov effect this sample exists to show)."]
