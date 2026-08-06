extends Node3D

## Sensor Hits -- a port of upstream's "Events / Sensor Hits" sample
## (samples/sample_events.cpp). Three sensors of three different body types
## stand in a line -- a static mesh gate, a kinematic mesh gate sliding left
## and right, and a dynamic capsule driven up and down by a motorised
## prismatic joint -- and a sphere is fired through all of them at 200-300
## m/s. The question the sample asks is whether a sensor still sees something
## that crosses it in a fraction of a step: at 250 m/s the ball covers four
## metres per physics step, so it is never actually inside a 20 cm gate on any
## frame boundary.
##
## The answer is the Bullet toggle. With it on (upstream's default) the ball
## is swept continuously and every gate reports a begin AND an end touch; with
## it off the ball teleports past them and the counts collapse. Sensor events
## are the same `area_entered` / `area_exited` signals as the Sensor Visit
## sample -- what changes is only whether the sweep gives them anything to
## report.
##
## Upstream's geometry verbatim: a 20 m ground box, a 0.2 x 10 x 10 m wall at
## x = 10 to stop the ball, two `b3CreateGridMesh(2, 2, 5, 0, true)` gates
## (10 x 10 m, turned upright by a quarter turn about z) at x = -4 and x = 0,
## a 0.1 m radius capsule spanning y = 2..10 at x = 4 on a prismatic motor
## (speed 0.5, max force 1000, reversing at +/-1 m), and a 0.25 m ball
## launched from x = -26.7 at y = 6.

const GATE_CELLS := 2
const GATE_CELL_WIDTH := 5.0

const BALL_RADIUS := 0.25
const BALL_START := Vector3(-26.7, 6.0, 0.0)
const BALL_SPEED_RANGE := Vector2(200.0, 300.0)

const KINEMATIC_SPEED := 0.5
const MOTOR_SPEED := 0.5
const MOTOR_MAX_FORCE := 1000.0
const TRAVEL_LIMIT := 1.0

var camera_home := Vector3(0.0, 25.0, 34.6)
var camera_look_at := Vector3(0.0, 5.0, 0.0)

var _world: Box3DWorld
var _kinematic: Box3DBody
var _slider: Box3DSliderJoint
var _ball: Box3DBody
var _is_bullet := true
var _kinematic_direction := 1.0
var _begin_count := 0
var _end_count := 0
var _rng := RandomNumberGenerator.new()
@onready var _label: Label3D = $Status


func _ready() -> void:
	_rng.seed = 20260806
	_world = $Box3DWorld

	_add_floor()
	var ground := _add_ground_with_wall()
	_add_sensor("StaticSensor", Box3DBody.STATIC, Vector3(-4.0, 6.0, 0.0))
	_kinematic = _add_sensor("KinematicSensor", Box3DBody.KINEMATIC, Vector3(0.0, 6.0, 0.0))
	var dynamic := _add_capsule_sensor(Vector3(4.0, 6.0, 0.0))

	# Upstream rotates the prismatic frame so its local x axis (the slide axis)
	# points along world y; the node's axis is its own local x, so the node is
	# rotated the same way.
	_slider = Box3DSliderJoint.new()
	_slider.name = "Lift"
	_slider.transform = Transform3D(
			Basis(Quaternion(Vector3.RIGHT, Vector3.UP)), Vector3(4.0, 7.0, 0.0))
	_slider.motor_enabled = true
	_slider.max_motor_force = MOTOR_MAX_FORCE
	_slider.motor_speed = MOTOR_SPEED
	_world.add_child(_slider)
	_slider.body_a = _slider.get_path_to(ground)
	_slider.body_b = _slider.get_path_to(dynamic)

	launch()


## The shell's reusable Activate button: upstream's Launch.
func activate() -> void:
	launch()


func get_toggle_label() -> String:
	return "Bullet"


func set_toggled(on: bool) -> void:
	_is_bullet = on
	launch()


func launch() -> void:
	if _ball != null:
		_ball.queue_free()
	_begin_count = 0
	_end_count = 0
	_ball = Box3DBody.new()
	_ball.name = "Ball"
	_ball.shape_type = Box3DBody.SPHERE
	_ball.sphere_radius = BALL_RADIUS
	_ball.friction = 0.8
	_ball.rolling_resistance = 0.01
	_ball.continuous = _is_bullet
	_ball.position = BALL_START
	var visual := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = BALL_RADIUS
	mesh.height = 2.0 * BALL_RADIUS
	visual.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.95, 0.8, 0.25)
	mat.emission_enabled = true
	mat.emission = Color(0.95, 0.8, 0.25)
	visual.material_override = mat
	_ball.add_child(visual)
	_world.add_child(_ball)
	_ball.set_linear_velocity(Vector3(
			_rng.randf_range(BALL_SPEED_RANGE.x, BALL_SPEED_RANGE.y), 0.0, 0.0))
	_refresh()


func _physics_process(delta: float) -> void:
	# Both movers bounce between -1 and 1, as upstream's Step does. Upstream
	# steers the kinematic gate with b3Body_SetLinearVelocity; the node drives
	# kinematic bodies from its own transform instead (Box3DBody sets a target
	# transform every step), so the equivalent is to walk the node.
	var x := _kinematic.position.x
	if x > TRAVEL_LIMIT:
		_kinematic_direction = -1.0
	elif x < -TRAVEL_LIMIT:
		_kinematic_direction = 1.0
	_kinematic.position.x = x + _kinematic_direction * KINEMATIC_SPEED * delta
	var t := _slider.get_translation()
	if t > TRAVEL_LIMIT:
		_slider.motor_speed = -MOTOR_SPEED
	elif t < -TRAVEL_LIMIT:
		_slider.motor_speed = MOTOR_SPEED


func _on_begin(_visitor: Box3DBody) -> void:
	_begin_count += 1
	_refresh()


func _on_end(_visitor: Box3DBody) -> void:
	_end_count += 1
	_refresh()


func _refresh() -> void:
	_label.text = "bullet: %s\nbegin touch count = %d\nend touch count = %d" % [
		"ON" if _is_bullet else "OFF", _begin_count, _end_count]


func _add_floor() -> void:
	var floor_body := Box3DBody.new()
	floor_body.name = "Floor"
	floor_body.body_type = Box3DBody.STATIC
	floor_body.box_size = Vector3(20.0, 2.0, 20.0)
	floor_body.position = Vector3(0.0, -1.0, 0.0)
	var visual := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = floor_body.box_size
	visual.mesh = mesh
	visual.material_override = _matte(Color(0.2, 0.22, 0.26))
	floor_body.add_child(visual)
	_world.add_child(floor_body)


## Upstream's second static body, the one the prismatic joint anchors to: it
## carries the backstop wall as an offset shape.
func _add_ground_with_wall() -> Box3DBody:
	var ground := Box3DBody.new()
	ground.name = "Ground"
	ground.body_type = Box3DBody.STATIC
	var shape := Box3DCollisionShape.new()
	shape.shape_type = 0
	shape.box_size = Vector3(0.2, 10.0, 10.0)
	shape.position = Vector3(10.0, 5.0, 0.0)
	ground.add_child(shape)
	var visual := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = shape.box_size
	visual.mesh = mesh
	visual.position = shape.position
	visual.material_override = _matte(Color(0.3, 0.33, 0.38))
	ground.add_child(visual)
	_world.add_child(ground)
	return ground


## A 10 x 10 m mesh gate, stood upright, as a sensor.
func _add_sensor(sensor_name: String, type: int, pos: Vector3) -> Box3DBody:
	var verts := PackedVector3Array()
	var half := 0.5 * GATE_CELL_WIDTH * GATE_CELLS
	for ix in GATE_CELLS + 1:
		for iz in GATE_CELLS + 1:
			verts.append(Vector3(
					-half + ix * GATE_CELL_WIDTH, 0.0, -half + iz * GATE_CELL_WIDTH))
	var idx := PackedInt32Array()
	for ix in GATE_CELLS:
		for iz in GATE_CELLS:
			var i1 := iz + (GATE_CELLS + 1) * ix
			var i2 := i1 + 1
			var i3 := i2 + (GATE_CELLS + 1)
			var i4 := i3 - 1
			idx.append_array([i1, i2, i3, i3, i4, i1])

	var body := Box3DBody.new()
	body.name = sensor_name
	body.body_type = type
	body.shape_type = Box3DBody.MESH
	body.mesh_weld_tolerance = 0.0
	body.mesh_median_split = true
	body.mesh_indices = idx
	body.mesh_vertices = verts
	body.is_sensor = true
	# A quarter turn about z stands the gate up across the line of fire.
	body.transform = Transform3D(Basis(Vector3.BACK, 0.5 * PI), pos)

	var flipped := PackedInt32Array()
	for t in idx.size() / 3:
		flipped.append_array([idx[t * 3], idx[t * 3 + 2], idx[t * 3 + 1]])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_INDEX] = flipped
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var visual := MeshInstance3D.new()
	visual.mesh = mesh
	visual.material_override = _glass(Color(0.35, 0.85, 1.0, 0.25))
	body.add_child(visual)

	_world.add_child(body)
	body.area_entered.connect(_on_begin)
	body.area_exited.connect(_on_end)
	return body


## The dynamic sensor: upstream's capsule spans y = 1..9 in a body at y = 1,
## which is a centred 8.2 m capsule on a body at y = 6.
func _add_capsule_sensor(pos: Vector3) -> Box3DBody:
	var body := Box3DBody.new()
	body.name = "DynamicSensor"
	body.shape_type = Box3DBody.CAPSULE
	body.capsule_radius = 0.1
	body.capsule_height = 8.2
	body.is_sensor = true
	body.position = pos
	var visual := MeshInstance3D.new()
	var mesh := CapsuleMesh.new()
	mesh.radius = 0.1
	mesh.height = 8.2
	visual.mesh = mesh
	visual.material_override = _glass(Color(1.0, 0.6, 0.35, 0.35))
	body.add_child(visual)
	_world.add_child(body)
	body.area_entered.connect(_on_begin)
	body.area_exited.connect(_on_end)
	return body


func _matte(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = 0.55
	return m


func _glass(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = color
	m.roughness = 0.2
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m
