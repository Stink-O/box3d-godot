extends Node3D

## Fixed Rotation -- a port of upstream's "Bodies / Fixed Rotation" sample
## (samples/sample_bodies.cpp:1242-1289). Upstream's comment is the point: a
## fully rotation-locked body uses a zero inverse inertia tensor. A floating
## capsule with all three angular locks is created overlapping a static
## capsule; the solver pushes the two apart, and the locked one slides out
## sideways without picking up any spin, however the contact pushes on it.
##
## Upstream's numbers are kept: both capsules run from (0, 0, 0) to (0, 1, 0)
## in their body's frame (so the body origin is the bottom cap's centre),
## the static one radius 0.3 at (0, 0.5, 0) and the dynamic one radius 0.2
## at (0.3, 0.5, 0), 0.5 m centre to centre, already 0.2 m interpenetrating
## (:1253-1278). The dynamic capsule has gravity scale 0, sleep disabled and
## lock_angular_x/y/z (:1265-1272), density 1000 (b3DefaultShapeDef), on
## AddGroundBox(20) under gravity -10. Grab it and drag it around the static
## one: it never turns.

## m_camera->SetView(0, 15, 10, origin) (:1251): eye = pivot + radius *
## (sin yaw cos pitch, sin pitch, cos yaw cos pitch)
## (samples/host/camera.cpp:35-39,216-220).
var camera_home := Vector3(0.0, 10.0 * sin(deg_to_rad(15.0)), 10.0 * cos(deg_to_rad(15.0)))
var camera_look_at := Vector3.ZERO


func rig_notes() -> Array:
	return ["Godot Physics and Jolt rebuild the two capsules with the angular "
			+ "axis locks; upstream's point, the zero inverse inertia, is Box3D's own."]
