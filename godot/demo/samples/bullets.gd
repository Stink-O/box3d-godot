extends Node3D

## Bullets / CCD sample: a firing range that shoots fast bullets at a thin wall.
## With the world's continuous_collision ON the bullets are caught by the wall;
## toggle it OFF (press C) and they tunnel straight through to the backstop —
## the classic reason CCD exists. Shots persist for a while so a few always
## sit visible at the wall or backstop. Press B to fire an extra volley.

const Despawn = preload("res://common/despawn.gd")

const PERIOD := 0.8
const SPEED := 46.0
const LIFETIME := 7.0

var _world: Box3DWorld
var _t := PERIOD
@onready var _label: Label3D = $Status


func _ready() -> void:
	_world = $Box3DWorld
	_refresh()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_C:
			_world.continuous_collision = not _world.continuous_collision
			_refresh()
		elif event.keycode == KEY_B:
			_volley()


func _refresh() -> void:
	if _world.continuous_collision:
		_label.text = "CCD: ON — bullets stop at the wall\n(press C to toggle, B to fire)"
		_label.modulate = Color(1, 0.92, 0.6, 1)
	else:
		_label.text = "CCD: OFF — bullets tunnel through!\n(press C to toggle, B to fire)"
		_label.modulate = Color(1, 0.55, 0.5, 1)


func _physics_process(delta: float) -> void:
	_t += delta
	if _t >= PERIOD:
		_t = 0.0
		_volley()


func _volley() -> void:
	for x in [-1.6, 0.0, 1.6]:
		_fire(x)


func _fire(x: float) -> void:
	var b := Box3DBody.new()
	b.shape_type = Box3DBody.SPHERE
	b.sphere_radius = 0.2
	b.density = 6.0
	b.continuous = true
	b.gravity_scale = 0.0  # fly level so it's a clean head-on shot
	b.position = Vector3(x, 2.5, 9.0)
	_world.add_child(b)
	b.set_linear_velocity(Vector3(0, 0, -SPEED))

	var mi := MeshInstance3D.new()
	var m := SphereMesh.new()
	m.radius = 0.2
	m.height = 0.4
	mi.mesh = m
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.95, 0.8, 0.25)
	mat.emission_enabled = true
	mat.emission = Color(0.95, 0.8, 0.25)
	mat.emission_energy_multiplier = 1.5
	mi.material_override = mat
	b.add_child(mi)

	Despawn.attach(b, LIFETIME)
