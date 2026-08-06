extends Node3D

## Motor Joint -- a port of upstream's "Joints / Motor Joint" sample
## (samples/sample_joint.cpp). A motor joint is a soft SIX-DEGREE-OF-FREEDOM
## drive between two bodies: give it a target frame and it pulls the second
## body there with a spring of the given hertz and damping, capped by a
## maximum force and torque. It is the joint the demo's own mouse drag uses.
##
##  * the bar chases an invisible KINEMATIC target (drawn as the wire cube)
##    swinging along a Lissajous path and rotating; the joint has to fight
##    gravity and its own inertia to keep up, so it always trails a little;
##  * the small cube on the left is pinned to the ground by a second, much
##    stiffer motor joint (7.5 Hz) offset from its centre -- knock it and it
##    springs back to exactly the same pose.
##
## Upstream drives the target from a speed slider that starts at ZERO, so
## nothing moves until you touch it; this port runs at speed 1 and puts the
## freeze on the top-bar toggle instead. Activate punches the bar with
## upstream's 100 kN impulse so you can watch the spring recover.

const IMPULSE := 100000.0
## Upstream's slider value, in target-path radians per second.
const SPEED := 1.0

var camera_home := Vector3(0.0, 8.0, 25.0)
var camera_look_at := Vector3(0.0, 8.0, 0.0)

var _target: Box3DBody
var _bar: Box3DBody
var _time := 0.0
var _paused := false


func _ready() -> void:
	_target = $Box3DWorld/Target
	_bar = $Box3DWorld/Bar


func _physics_process(delta: float) -> void:
	if _paused:
		return
	_time += SPEED * delta
	# Upstream's path, verbatim: a 6 m horizontal sweep at twice the rate of a
	# 4 m vertical one, with the frame spinning about Z at 2 rad per unit time.
	_target.position = Vector3(6.0 * sin(2.0 * _time), 10.0 + 4.0 * sin(_time), 0.0)
	_target.rotation = Vector3(0.0, 0.0, 2.0 * _time)


## The shell's reusable sample toggle: freeze the target where it is. The bar
## settles onto it, which is the clearest read of what the joint is doing.
func get_toggle_label() -> String:
	return "Freeze Target"


func set_toggled(on: bool) -> void:
	_paused = on


## The shell's reusable Activate button: upstream's "Apply Impulse".
func activate() -> void:
	_bar.apply_central_impulse(Vector3(IMPULSE, 0.0, 0.0))
