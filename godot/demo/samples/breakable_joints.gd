extends Node3D

## Breakable Joints -- a port of upstream's "Events / Joint" sample
## (samples/sample_events.cpp:330-569). Boxes hang from the ground on joints
## that carry a force threshold of 3000 N and a torque threshold of
## 10000 N m (:368-369). Box3D raises a joint event in any step where a
## joint's constraint force or torque reaches its threshold, and this sample
## destroys the joint right there, as upstream's Step does (:542-559): grab a
## box with the mouse and yank it hard, and its joint snaps.
##
## The events arrive through Box3DWorld.joint_threshold_exceeded, which hands
## back the joint node; freeing the node destroys the Box3D joint and wakes
## its bodies, upstream's b3DestroyJoint(jointId, true).
##
## Upstream's numbers are kept: 2 x 2 x 1 box hulls of density 1 (:363-367)
## with sleep disabled (:362), every 5 m along x from -12.5 at height 10
## (:359), on AddGroundBox(20) under gravity -10, each joint with
## collideConnected on (:392 and siblings). Upstream lays out six slots, but
## the motor joint (:401-420) and the wheel joint (:497-525) are compiled out
## with #if 0, so four joints exist and slots two and six stay empty here too:
##  * distance: a 2 m rod from (x, 13, 0) on the ground to the top of the box
##    (:375-393). The binding's distance joint anchors at body origins, so the
##    two anchor frames are set after creation, to upstream's pivots.
##  * prismatic (Box3DSliderJoint), revolute (Box3DHingeJoint) and weld
##    (Box3DFixedJoint, angular hertz 2, damping ratio 0.5), each pivoted at
##    the box's left edge, (x - 1, 10, 0), with identity frames (:427-495).
## Upstream builds its joints on a separate, shapeless static body at the
## origin; the frames are world points either way, so the ground box serves.

## m_camera->SetView(0, 30, 40, {0, 5, 0}) (:342): eye = pivot + radius *
## (sin yaw cos pitch, sin pitch, cos yaw cos pitch)
## (samples/host/camera.cpp:35-39,216-220).
var camera_home := Vector3(0.0, 5.0 + 40.0 * sin(deg_to_rad(30.0)), 40.0 * cos(deg_to_rad(30.0)))
var camera_look_at := Vector3(0.0, 5.0, 0.0)

## Joints destroyed so far, by node name (for the readout and the selftest).
var broken: Array[String] = []

@onready var _world: Box3DWorld = $Box3DWorld
@onready var _ground: Box3DBody = $Box3DWorld/Ground
@onready var _distance: Box3DDistanceJoint = $Box3DWorld/DistanceJoint


func _ready() -> void:
	# Upstream's distance joint pivots (:384-388): (x, y + 1 + length, 0) on
	# the ground and the box's top centre, (x, y + 1, 0), on the box.
	var pivot1 := _distance.global_position
	_distance.set_local_frame_a(Transform3D(Basis(), _ground.to_local(pivot1)))
	_distance.set_local_frame_b(Transform3D(Basis(), Vector3(0.0, 1.0, 0.0)))
	_world.joint_threshold_exceeded.connect(_on_joint_threshold_exceeded)


## Upstream's joint event loop (:542-559): destroy the joint if it is still
## valid.
func _on_joint_threshold_exceeded(joint: Box3DJoint, _force: Vector3, _torque: Vector3) -> void:
	if not is_instance_valid(joint) or not joint.is_joint_valid():
		return
	broken.append(String(joint.name))
	joint.free()


func rig_notes() -> Array:
	return ["Godot Physics and Jolt joints have no force or torque threshold "
			+ "events, so the joints are rebuilt but never break."]
