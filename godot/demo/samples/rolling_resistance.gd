extends Node3D

## Rolling Resistance -- a port of upstream's "Shapes / Rolling Resistance"
## sample (samples/sample_shapes.cpp:57-111). Five balls and five capsules
## roll off a 10 degree ramp onto the flat, each with more rolling
## resistance than the one before: 0, 0.05, 0.1, 0.15 and 0.2. Without it a
## ball rolls on forever; with it, it slows and stops sooner the higher the
## value. Rolling resistance only acts on spheres and capsules, the two
## shapes that roll on a point or a line.
##
## Upstream's numbers are kept: the ramp is b3MakeBoxHull(32, 0.5, 15), a
## 64 x 1 x 30 slab at (0, 2, -20) turned 10 degrees about X (:68-74); the
## balls have radius 1 at x = -25 + 5 i and the capsules run from (-1, 0, 0)
## to (1, 0, 0) with radius 0.5 at x = 2 + 5 i, all at (x, 8, -24)
## (:76-96), density 1000 (b3DefaultShapeDef), angular damping 0
## (b3DefaultBodyDef), on AddGroundBox(80) under gravity -10. As upstream,
## the dynamic bodies inherit the ramp's 10 degree rotation, because the
## sample reuses one b3BodyDef for all of them (:70, :79, :89).

## m_camera->SetView(-140, 17, 60, {0, 7.5, 0}) (:63): eye = pivot + radius *
## (sin yaw cos pitch, sin pitch, cos yaw cos pitch)
## (samples/host/camera.cpp:35-39,216-220).
var camera_home := Vector3(0.0, 7.5, 0.0) + 60.0 * Vector3(
		sin(deg_to_rad(-140.0)) * cos(deg_to_rad(17.0)),
		sin(deg_to_rad(17.0)),
		cos(deg_to_rad(-140.0)) * cos(deg_to_rad(17.0)))
var camera_look_at := Vector3(0.0, 7.5, 0.0)


func rig_notes() -> Array:
	return ["Godot Physics and Jolt have no rolling resistance, so on those engines "
			+ "every ball and capsule rolls the same distance instead of stopping in order."]
