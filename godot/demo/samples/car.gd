extends Node3D

## Car: a port of box3d's own "Driving" sample (upstream samples/
## sample_joint.cpp), same construction and numbers. The vehicle is pure
## Box3D — nothing pushes the chassis directly, all motion comes from the
## joints and wheel traction:
##   - four sphere wheels hang on Box3DWheelJoints; each joint's suspension
##     spring carries the chassis (hertz 4, damping 0.7, travel ±0.2 m),
##   - the REAR joints drive their spin motor (rear-wheel drive, 5 N·m),
##   - the FRONT joints steer by spring toward target_steering_angle (±45°),
##   - a soft Box3DParallelJoint keeps the chassis upright while letting it
##     pitch/roll with the terrain (and yaw freely to steer),
##   - the ground is a rolling sine-wave triangle mesh (car_terrain.res,
##     baked by tools/gen_car_terrain.gd), standing in for upstream's
##     b3CreateWave height field.
##
## Drive with the ARROW KEYS (or W A S D while not flying the camera):
## Up/Down = throttle, Left/Right = steer. The car crests the swells, leans
## on its suspension, and can be flipped if you fly off a crest badly — the
## upright spring will wrestle it back. The top bar's "Third Person" toggle
## (the shell's reusable sample toggle) puts the shared camera on a chase
## rig behind the car; toggling it off returns to the free camera exactly
## where you left it.

const SPIN_SPEED := 30.0     # rad/s wheel-spin target at full throttle (upstream's)
const MAX_STEER := 0.25 * PI # target steering angle at full lock (upstream's)

## Opening camera framing, read by the sample-browser shell.
@export var camera_home := Vector3(11.0, 8.0, 13.0)
@export var camera_look_at := Vector3(0.0, 1.5, 0.0)

@onready var _chassis: Box3DBody = $Box3DWorld/Chassis
@onready var _front: Array = [$Box3DWorld/FrontLeftJoint, $Box3DWorld/FrontRightJoint]
@onready var _rear: Array = [$Box3DWorld/RearLeftJoint, $Box3DWorld/RearRightJoint]
@onready var _speedo: Label3D = $Speedo


# --- Shell toggle: third-person chase camera (see main.gd's SampleToggle) ---

func get_toggle_label() -> String:
	return "🎥 Third Person"


func set_toggled(on: bool) -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null or not cam.has_method("set_follow"):
		return
	if on:
		cam.set_follow(_chassis, Vector3(-8.0, 3.2, 0.0), 1.2)
	else:
		cam.clear_follow()


func _physics_process(_delta: float) -> void:
	# Arrow keys always; W A S D too, but only while the camera isn't captured
	# (right mouse held for flying), so the two never fight.
	var driving := Input.mouse_mode != Input.MOUSE_MODE_CAPTURED
	var throttle := 0.0
	if Input.is_key_pressed(KEY_UP) or (driving and Input.is_key_pressed(KEY_W)):
		throttle += 1.0
	if Input.is_key_pressed(KEY_DOWN) or (driving and Input.is_key_pressed(KEY_S)):
		throttle -= 1.0
	var steer := 0.0
	if Input.is_key_pressed(KEY_LEFT) or (driving and Input.is_key_pressed(KEY_A)):
		steer += 1.0
	if Input.is_key_pressed(KEY_RIGHT) or (driving and Input.is_key_pressed(KEY_D)):
		steer -= 1.0

	# Feed the joints, exactly like upstream's Step(): negative spin about the
	# +Z axle rolls the car toward its +X nose; positive steering angles yaw
	# the front wheels left. Traction, weight transfer and the suspension
	# squat under acceleration all fall out of the simulation.
	for joint in _rear:
		joint.spin_motor_speed = -SPIN_SPEED * throttle
	for joint in _front:
		joint.target_steering_angle = MAX_STEER * steer


func _process(_delta: float) -> void:
	# Speed along the nose (+X), floating above the car — upstream draws the
	# same readout as screen text.
	var speed: float = _chassis.get_linear_velocity().dot(_chassis.global_transform.basis.x)
	_speedo.text = "%.1f m/s" % speed
	_speedo.global_position = _chassis.global_position + Vector3(0, 1.9, 0)
