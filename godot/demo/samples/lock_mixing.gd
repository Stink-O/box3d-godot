extends Node3D

## Lock Mixing -- a port of upstream's "Bodies / Lock Mixing" sample
## (samples/sample_bodies.cpp:1160-1240). Five 2 m cubes side by side, each
## with a different mix of motion locks, so grabbing and shoving them shows
## what every lock does and how locked bodies push on free ones:
##  * "free" at (0, 2, 0): no locks.
##  * "angular xz" at (2, 2, 0): lock_angular_x and lock_angular_z, so it can
##    only turn about the vertical (:1188-1193; upstream leaves angularY
##    commented out).
##  * "linear xyz" at (-2, 2, 0): all three linear locks, so it stays where
##    it was created and can only rotate there, hanging in the air.
##  * "full" at (0, 1, 2): every lock, an immovable dynamic body that is
##    still dynamic (it wakes, it reports contacts) but nothing moves it.
##  * "static" at (0, 1, -3): a static cube for comparison.
## Upstream's numbers are kept: b3MakeBoxHull(1, 1, 1) cubes at density 1000
## (b3DefaultShapeDef; the node default is 1) and angular damping 0
## (b3DefaultBodyDef; the node default is 0.05), on AddGroundBox(20) under
## gravity -10. The Motion Locks sample is the same feature as a toy; this
## is upstream's test of mixing them.

## m_camera->SetView(45, 30, 40, origin) (:1168): eye = pivot + radius *
## (sin yaw cos pitch, sin pitch, cos yaw cos pitch)
## (samples/host/camera.cpp:35-39,216-220).
var camera_home := 40.0 * Vector3(
		sin(deg_to_rad(45.0)) * cos(deg_to_rad(30.0)),
		sin(deg_to_rad(30.0)),
		cos(deg_to_rad(45.0)) * cos(deg_to_rad(30.0)))
var camera_look_at := Vector3.ZERO


func rig_notes() -> Array:
	return ["Godot Physics and Jolt lock axes per body too (axis_lock_*), but a "
			+ "dynamic body with every axis locked is not the same object there as "
			+ "Box3D's immovable dynamic body, so pushes on the 'full' cube can differ."]
