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

const BOMB_SCENE := preload("res://common/bomb.tscn")
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
	_reset_pose()


# Point at a rebuilt world (e.g. after Reset) WITHOUT moving the camera, so the
# view the user flew to is preserved.
func set_world_keep_view(world: Box3DWorld) -> void:
	_world = world
	_grabbed = null


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
			_set_flying(event.pressed)
		elif event.button_index == MOUSE_BUTTON_LEFT and not _flying:
			if event.pressed:
				_try_grab()
			else:
				_grabbed = null
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


func _physics_process(_delta: float) -> void:
	_drag_grabbed()


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
		# The ball owns its own lifetime timer as a child, so if the whole
		# sample (and this ball with it) gets freed on reset/switch, the timer
		# goes with it instead of leaving a dangling callback pointed at a
		# freed body.
		var timer := Timer.new()
		timer.wait_time = shoot_lifetime
		timer.one_shot = true
		timer.autostart = true
		timer.timeout.connect(ball.queue_free)
		ball.add_child(timer)
