extends Node3D

## Character Controller: a Box3D PLAYGROUND. Drives a Box3DCharacterBody (a
## kinematic capsule) around an obstacle course built entirely from ordinary
## Box3D bodies — crates, barrels, balls — the same props the rest of the demo
## uses. Walk it with W A S D (camera-relative) and Space to jump — but only
## while you're NOT flying the camera (hold right mouse to fly; release to
## walk). It climbs the low ramp and slides along walls like any mover, and it
## shoves the dynamic props it walks into (see _push_dynamics below), so the
## capsule clearly reads as one more Box3D body sharing the world with the
## crates it's pushing.

@export var speed := 5.0
@export var jump_speed := 6.5
@export var gravity := 18.0
## Shove strength (newtons) applied to a prop the character walks into. It's a
## FORCE, not a set velocity, so light props (balls) fly and heavy ones (crates)
## lumber -- the push scales with the prop's own mass, like real contact.
@export var push_force := 34.0
## Extra reach beyond the capsule radius used to detect props to push.
@export var push_reach := 0.35

## Opening camera framing for this scene, read by the sample-browser shell
## (an establishing shot of the whole playground). Edit these in the inspector
## to reposition the camera for the scene -- no marker node needed.
@export var camera_home := Vector3(7.0, 6.5, 12.0)
@export var camera_look_at := Vector3(0.0, 1.6, -3.0)

var _vel := Vector3.ZERO
var _grounded := false
@onready var _char: Box3DCharacterBody = $Box3DWorld/Character
@onready var _world: Box3DWorld = $Box3DWorld
var _cam: Camera3D


func _ready() -> void:
	_cam = get_viewport().get_camera_3d()


func _physics_process(delta: float) -> void:
	_vel.y -= gravity * delta

	var dir := Vector3.ZERO
	# Only steer while the mouse is free (fly mode captures it).
	if _cam != null and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		var fwd := -_cam.global_transform.basis.z
		var right := _cam.global_transform.basis.x
		fwd.y = 0.0
		right.y = 0.0
		fwd = fwd.normalized()
		right = right.normalized()
		if Input.is_key_pressed(KEY_W): dir += fwd
		if Input.is_key_pressed(KEY_S): dir -= fwd
		if Input.is_key_pressed(KEY_D): dir += right
		if Input.is_key_pressed(KEY_A): dir -= right
		if dir.length() > 0.001:
			dir = dir.normalized()
		if _grounded and Input.is_key_pressed(KEY_SPACE):
			_vel.y = jump_speed

	var horizontal := dir * speed
	var command := Vector3(horizontal.x, _vel.y, horizontal.z)
	var result: Vector3 = _char.move_and_slide(command, delta)

	# move_and_slide returns the actual velocity; a downward command that comes
	# back ~0 means we're standing on something.
	_vel.y = result.y
	_grounded = command.y < 0.0 and result.y > command.y * 0.5

	_push_dynamics(horizontal)


# Box3DCharacterBody is a geometric mover, not a simulated body: b3World_
# CollideMover treats every shape it touches — dynamic crates included — as an
# immovable plane, so the capsule solves its own position against them but the
# engine never pushes them back. This supplies that missing half AS REAL
# CONTACT: while walking, find dynamic props just ahead and apply a capped
# FORCE (not a set velocity) in the walk direction. Because it's a force,
# momentum transfer scales with each prop's mass — a ball flies, a crate
# lumbers — so the character reads as one more body leaning into the pile. The
# force cuts out once a prop already matches our walking speed, so we shove
# props along rather than flinging them away.
func _push_dynamics(horizontal: Vector3) -> void:
	var walk := horizontal.length()
	if walk < 0.01:
		return
	var push_dir := horizontal / walk
	var center := _char.global_position
	var reach := _char.radius + push_reach
	for body in _world.overlap_sphere(center, reach, 0xFFFFFFFF):
		if not (body is Box3DBody) or body.body_type != Box3DBody.DYNAMIC:
			continue
		var to_body: Vector3 = body.global_position - center
		to_body.y = 0.0
		var d := to_body.length()
		if d > 0.01 and push_dir.dot(to_body / d) < 0.3:
			continue  # only push what's in front of our motion
		# Only keep pushing until the prop is moving forward as fast as we walk.
		var v: Vector3 = body.get_linear_velocity()
		var v_fwd := Vector3(v.x, 0.0, v.z).dot(push_dir)
		if v_fwd < walk:
			body.apply_central_force(push_dir * push_force)
