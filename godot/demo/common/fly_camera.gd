extends Camera3D

## Free-fly camera + physics dragging, shared across all samples.
##   Hold RIGHT MOUSE : look around; fly with W A S D and Q / E (Shift = boost)
##   LEFT MOUSE drag  : when not flying, grab a Box3DBody at the point you
##                      clicked and drag that point around (pivots off-center
##                      grabs, e.g. a table's edge, instead of re-centering it)
##   F                : hold to charge a shot 0 -> 1 over ~1s, release to fire
##                      (a quick tap still fires a light shot)
##
## The sample browser calls set_world() each time a sample loads, then (if the
## sample's root script exports camera_home / camera_look_at) frame_view() to
## point the camera at that scene's action.

@export var move_speed := 8.0
@export var boost_multiplier := 3.0
@export var look_sensitivity := 0.0028
@export var grab_strength := 12.0
@export var look_target := Vector3(0, 2.5, 0)
@export var home_position := Vector3(0, 7, 16)
@export var shoot_speed_min := 20.0
@export var shoot_speed_max := 70.0
@export var charge_time := 1.0  ## seconds held to reach full charge
@export var shoot_radius := 0.35
@export var shoot_lifetime := 20.0

var _world: Box3DWorld
var _flying := false
var _yaw := 0.0
var _pitch := 0.0
var _grabbed: Box3DBody = null
var _grab_distance := 0.0
var _grab_local_offset := Vector3.ZERO  ## hit point, in the grabbed body's local space

var _charging := false
var _charge := 0.0
var _charge_bar: ProgressBar = null

## Third-person follow (samples opt in through the shell's toggle button).
## A standard orbit rig: the camera sits EXACTLY on an orbit sphere around a
## smoothed pivot and is hard-aimed at it, so HOLD-RIGHT-MOUSE orbiting is
## 1:1 with the mouse (vertical inverted, flight-style) and the orbit STAYS
## where you put it until the follow ends. Only the pivot (the target's
## position) and the rig's base heading (the target's yaw) are smoothed —
## that's what keeps the chase steady without making the camera itself feel
## laggy. Runs in _physics_process, in lockstep with the body it chases.
## Toggling off glides the camera back to where the free camera was.
var _follow: Node3D = null
var _follow_anchor := Vector3(-8.0, 3.2, 0.0)  ## chase offset in the target's yaw frame
var _follow_look_height := 1.2
var _follow_saved_pose := Transform3D()
var _orbiting := false     ## right mouse held: mouse drags the orbit angles
var _orbit_yaw := 0.0      ## user orbit offsets around the chase anchor (kept on release)
var _orbit_pitch := 0.0
var _pivot := Vector3.ZERO ## smoothed orbit centre (the target, a beat behind)
var _heading := 0.0        ## smoothed target yaw the rig hangs from
var _follow_blend := 1.0   ## 0 -> 1 entry blend from the free pose onto the rig
var _blend_from := Transform3D()
var _returning := false    ## gliding back to _follow_saved_pose after clear_follow()
@export var follow_smoothing := 5.0  ## 1/s glide rate for the toggle-off return
@export var follow_pivot_smoothing := 12.0  ## 1/s pivot chase (higher = tighter)
@export var follow_heading_smoothing := 5.0  ## 1/s how fast the rig re-centres behind a turn
@export var follow_blend_time := 0.5  ## seconds to blend onto the rig when toggled on

const BOMB_SCENE := preload("res://common/bomb.tscn")
const Despawn = preload("res://common/despawn.gd")
var _bomb_mode := false  ## when true, F fires a fused Bomb instead of a ball


# Shell calls this to switch what F shoots (false = ball, true = bomb).
func set_bomb_mode(on: bool) -> void:
	_bomb_mode = on


func _ready() -> void:
	_reset_pose()


# Point the camera at a newly loaded sample's world and reset to the default
# framing. A sample can override the framing afterwards via frame_view().
func set_world(world: Box3DWorld) -> void:
	_world = world
	_grabbed = null
	_end_follow_states()  # the new sample owns the framing; nothing to restore
	_reset_pose()


# Point at a rebuilt world (e.g. after Reset) WITHOUT moving the camera, so the
# view the user flew to is preserved.
func set_world_keep_view(world: Box3DWorld) -> void:
	_world = world
	_grabbed = null
	_end_follow_states()


func _end_follow_states() -> void:
	_follow = null
	_returning = false
	_orbiting = false
	_orbit_yaw = 0.0
	_orbit_pitch = 0.0


# True while the third-person follow owns the camera. Samples use this to
# keep W A S D driving even though the orbit drag captures the mouse (the
# capture gate exists to protect the FLY camera, which isn't active here).
func is_following() -> bool:
	return _follow != null


# Chase `target` third-person: glide to `local_anchor` in the target's
# yaw-only frame (x = along its nose, y = height, z = sideways) and keep
# looking at it. The current free-camera pose is saved; clear_follow()
# glides back to it.
func set_follow(target: Node3D, local_anchor := Vector3(-8.0, 3.2, 0.0), look_height := 1.2) -> void:
	# Re-following mid-return keeps the ORIGINAL saved pose as the way home.
	if _follow == null and target != null and not _returning:
		_follow_saved_pose = global_transform
	_follow = target
	_follow_anchor = local_anchor
	_follow_look_height = look_height
	_returning = false
	_orbit_yaw = 0.0
	_orbit_pitch = 0.0
	if target != null:
		_pivot = target.global_position
		var fwd: Vector3 = target.global_transform.basis.x
		_heading = atan2(fwd.z, fwd.x)
		_follow_blend = 0.0
		_blend_from = global_transform


# Stop following and glide the camera back to where it was when the follow
# began (starting to fly with right mouse cancels the glide and takes over).
func clear_follow() -> void:
	if _follow != null:
		_returning = true
	_follow = null
	if _orbiting:
		_orbiting = false
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


# Frame the view from `home`, looking at `look_at`. Samples opt into custom
# framing by exporting camera_home / camera_look_at on their root script; the
# shell reads those and calls this. Simpler than a marker node -- just two
# Vector3s you can edit in the inspector.
func frame_view(home: Vector3, target: Vector3) -> void:
	position = home
	look_at(target, Vector3.UP)
	_yaw = rotation.y
	_pitch = rotation.x


# Lets main.gd wire up the shared charge-meter without fly_camera needing to
# know where it lives in the UI tree.
func set_charge_bar(bar: ProgressBar) -> void:
	_charge_bar = bar
	if _charge_bar != null:
		_charge_bar.visible = false
		_charge_bar.min_value = 0.0
		_charge_bar.max_value = 100.0
		_charge_bar.value = 0.0


func _reset_pose() -> void:
	position = home_position
	look_at(look_target, Vector3.UP)
	_yaw = rotation.y
	_pitch = rotation.x


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			if _follow != null:
				# Third person: right mouse orbits the chase view around the
				# target instead of flying (arrow keys keep driving).
				_orbiting = event.pressed
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if _orbiting else Input.MOUSE_MODE_VISIBLE
			else:
				# Grabbing the camera mid-glide cancels the return and flies
				# from wherever the glide had reached.
				if event.pressed:
					_returning = false
				_set_flying(event.pressed)
		elif event.button_index == MOUSE_BUTTON_LEFT and not _flying:
			if event.pressed:
				_try_grab()
			else:
				_grabbed = null
	elif event is InputEventMouseMotion and _follow != null and _orbiting:
		# Vertical inverted (flight-style): push the mouse up to dip the
		# camera and look up at the target.
		_orbit_yaw -= event.relative.x * look_sensitivity
		_orbit_pitch = clampf(_orbit_pitch + event.relative.y * look_sensitivity, -0.6, 1.3)
	elif event is InputEventMouseMotion and _flying:
		_yaw -= event.relative.x * look_sensitivity
		_pitch = clampf(_pitch - event.relative.y * look_sensitivity, -1.5, 1.5)
		rotation = Vector3(_pitch, _yaw, 0.0)
	elif event is InputEventKey and not event.echo and event.keycode == KEY_F:
		if event.pressed:
			_start_charge()
		else:
			_release_charge()


func _set_flying(active: bool) -> void:
	_flying = active
	if active:
		_grabbed = null
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	else:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _process(delta: float) -> void:
	_update_charge(delta)
	if _follow != null:
		if not is_instance_valid(_follow):
			_follow = null  # target freed (reset/switch): stay put, follow ends
		# Following is driven from _physics_process, in lockstep with the
		# chased body -- moving here (at render rate, against a body that only
		# moves per physics tick) makes the target judder relative to the view.
		return
	if _returning:
		_update_return(delta)
		return
	if not _flying:
		return
	var dir := Vector3.ZERO
	if Input.is_key_pressed(KEY_W): dir -= transform.basis.z
	if Input.is_key_pressed(KEY_S): dir += transform.basis.z
	if Input.is_key_pressed(KEY_A): dir -= transform.basis.x
	if Input.is_key_pressed(KEY_D): dir += transform.basis.x
	if Input.is_key_pressed(KEY_E): dir += Vector3.UP
	if Input.is_key_pressed(KEY_Q): dir -= Vector3.UP
	if dir != Vector3.ZERO:
		var speed := move_speed
		if Input.is_key_pressed(KEY_SHIFT):
			speed *= boost_multiplier
		position += dir.normalized() * speed * delta


func _update_follow(delta: float) -> void:
	# Smooth ONLY the pivot (where the target is) and the base heading (which
	# way it faces); the camera itself then sits exactly on the orbit sphere
	# and is hard-aimed at the pivot, so mouse orbiting is 1:1 and the target
	# stays centred even through fast drags.
	_pivot = _pivot.lerp(_follow.global_position, 1.0 - exp(-follow_pivot_smoothing * delta))
	var nose: Vector3 = _follow.global_transform.basis.x
	nose.y = 0.0
	if nose.length_squared() > 0.001:
		_heading = lerp_angle(_heading, atan2(nose.z, nose.x),
				1.0 - exp(-follow_heading_smoothing * delta))

	var fwd := Vector3(cos(_heading), 0.0, sin(_heading))
	var side := Vector3.UP.cross(fwd)
	var offset := fwd * _follow_anchor.x \
			+ Vector3.UP * _follow_anchor.y + side * _follow_anchor.z

	# User orbit: swing the offset around the pivot (yaw about UP, then pitch
	# about the swung offset's own side axis) -- applied EXACTLY, no easing.
	offset = offset.rotated(Vector3.UP, _orbit_yaw)
	var horiz := Vector3(offset.x, 0.0, offset.z)
	if horiz.length_squared() > 0.001:
		offset = offset.rotated(horiz.normalized().cross(Vector3.UP), _orbit_pitch)

	var desired := _pivot + offset

	# Don't sink the rig into a hill (or a wall): cast from safely above the
	# pivot (clear of the target's own collider even when it pitches) and
	# pull the camera in front of whatever the ray hits.
	if _world != null:
		var from := _pivot + Vector3.UP * maxf(_follow_look_height, 1.2)
		var hit := _world.raycast(from, desired)
		if hit.get("hit", false):
			desired = (hit["position"] as Vector3).lerp(from, 0.1)

	var look_target := _pivot + Vector3.UP * _follow_look_height

	# Short one-way blend from the free pose onto the rig when toggled on;
	# once it completes the camera IS the rig, with zero lag of its own.
	_follow_blend = minf(_follow_blend + delta / maxf(follow_blend_time, 0.001), 1.0)
	var t := smoothstep(0.0, 1.0, _follow_blend)
	global_position = _blend_from.origin.lerp(desired, t) if t < 1.0 else desired

	var to_target := look_target - global_position
	if to_target.length_squared() > 0.01 and absf(to_target.normalized().y) < 0.999:
		var aim := Basis.looking_at(to_target, Vector3.UP).get_rotation_quaternion()
		if t < 1.0:
			aim = _blend_from.basis.get_rotation_quaternion().slerp(aim, t)
		global_transform.basis = Basis(aim)
	_yaw = rotation.y
	_pitch = rotation.x


func _update_return(delta: float) -> void:
	# Glide home to the pose saved when the follow began, then snap the last
	# hair's-breadth so the restore is exact.
	var t := 1.0 - exp(-follow_smoothing * delta)
	position = position.lerp(_follow_saved_pose.origin, t)
	var target_q := _follow_saved_pose.basis.get_rotation_quaternion()
	var q := global_transform.basis.get_rotation_quaternion().slerp(target_q, t)
	global_transform.basis = Basis(q)
	if position.distance_to(_follow_saved_pose.origin) < 0.05 \
			and q.angle_to(target_q) < 0.01:
		global_transform = _follow_saved_pose
		_returning = false
	_yaw = rotation.y
	_pitch = rotation.x


func _update_charge(delta: float) -> void:
	if _charging:
		_charge = clampf(_charge + delta / maxf(charge_time, 0.001), 0.0, 1.0)
	if _charge_bar != null:
		_charge_bar.visible = _charging
		_charge_bar.value = _charge * 100.0


func _start_charge() -> void:
	_charging = true
	_charge = 0.0


func _release_charge() -> void:
	if not _charging:
		return
	_charging = false
	var charge := _charge
	_charge = 0.0
	_shoot(charge)


func _physics_process(delta: float) -> void:
	_drag_grabbed()
	if _follow != null and is_instance_valid(_follow):
		_update_follow(delta)


func _try_grab() -> void:
	if _world == null:
		return
	var mouse := get_viewport().get_mouse_position()
	var from := project_ray_origin(mouse)
	var dir := project_ray_normal(mouse)
	var hit := _world.raycast(from, from + dir * 500.0)
	if hit.get("hit", false):
		var body = hit.get("collider")
		if body is Box3DBody and body.body_type == Box3DBody.DYNAMIC:
			_grabbed = body
			_grab_distance = from.distance_to(hit["position"])
			# Remember the hit point in the body's local frame so the drag
			# follows that exact point (and rotates the body) rather than
			# snapping the body's origin to the cursor.
			_grab_local_offset = body.global_transform.affine_inverse() * hit["position"]


func _drag_grabbed() -> void:
	if _grabbed == null or _flying:
		return
	var mouse := get_viewport().get_mouse_position()
	var from := project_ray_origin(mouse)
	var dir := project_ray_normal(mouse)
	var target := from + dir * _grab_distance

	# World-space offset of the grabbed point, rotating with the body.
	var r: Vector3 = _grabbed.global_transform.basis * _grab_local_offset
	var point_world: Vector3 = _grabbed.global_position + r
	var error: Vector3 = target - point_world

	# Approximate a point constraint: the component of the error tangent to
	# the lever arm `r` is chased by rotating about the body's centre (so
	# grabbing near a table's edge pivots it), and the component along `r`
	# is chased by translating the centre. Below a small lever length there's
	# no stable pivot axis, so just translate.
	var ang_vel := Vector3.ZERO
	var lever2 := r.length_squared()
	if lever2 > 0.01:
		ang_vel = (r.cross(error) * (grab_strength / lever2)).limit_length(25.0)
	var lin_vel: Vector3 = error * grab_strength - ang_vel.cross(r)

	_grabbed.set_linear_velocity(lin_vel)
	_grabbed.set_angular_velocity(ang_vel)


var _ball_mesh: SphereMesh
var _ball_mat: StandardMaterial3D


# Launch a fast CCD ball from the camera, aimed through the mouse (or straight
# ahead while flying, since the cursor is captured). `charge` in [0, 1] scales
# the launch speed between shoot_speed_min and shoot_speed_max; a quick tap
# fires at charge ~0 (a light shot). Balls self-destruct after shoot_lifetime
# so they don't pile up forever.
func _shoot(charge: float = 0.0) -> void:
	if _world == null:
		return
	var origin: Vector3
	var dir: Vector3
	if _flying:
		origin = global_position
		dir = -global_transform.basis.z
	else:
		var mouse := get_viewport().get_mouse_position()
		origin = project_ray_origin(mouse)
		dir = project_ray_normal(mouse)

	var speed := lerpf(shoot_speed_min, shoot_speed_max, clampf(charge, 0.0, 1.0))

	if _bomb_mode:
		var bomb := BOMB_SCENE.instantiate() as Box3DBody
		bomb.position = origin + dir * (shoot_radius + 0.6)
		_world.add_child(bomb)
		bomb.set_linear_velocity(dir * speed)
		return  # the bomb owns its own fuse -> explode -> free lifecycle

	if _ball_mesh == null:
		_ball_mesh = SphereMesh.new()
		_ball_mesh.radius = shoot_radius
		_ball_mesh.height = shoot_radius * 2.0
		_ball_mat = StandardMaterial3D.new()
		_ball_mat.albedo_color = Color(0.95, 0.85, 0.25)
		_ball_mat.metallic = 0.2
		_ball_mat.roughness = 0.35

	var ball := Box3DBody.new()
	ball.shape_type = Box3DBody.SPHERE
	ball.sphere_radius = shoot_radius
	ball.density = 4.0
	ball.restitution = 0.35
	ball.continuous = true  # CCD so a fast ball can't tunnel through walls
	ball.position = origin + dir * (shoot_radius + 0.5)

	var mesh := MeshInstance3D.new()
	mesh.mesh = _ball_mesh
	mesh.material_override = _ball_mat
	ball.add_child(mesh)

	_world.add_child(ball)
	ball.set_linear_velocity(dir * speed)

	if shoot_lifetime > 0.0:
		Despawn.attach(ball, shoot_lifetime)
