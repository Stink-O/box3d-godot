extends Node3D

## Sensor Visit -- a port of upstream's "Events / Sensor Visit" sample
## (samples/sample_events.cpp). A kinematic 4 m box is flagged as a SENSOR:
## it takes part in collision detection but never pushes anything, it only
## reports who is inside it. A 1 m box dropped from 12.5 m falls straight
## through the sensor volume, and the moment the sensor reports the visit the
## visitor is destroyed -- upstream deletes the body from the begin-touch
## event, this port frees the node from the `area_entered` signal, which is
## the same event routed through Godot.
##
## Press the top-bar Activate button to drop another one.

const VISITOR_SPAWN := Vector3(0.0, 12.5, 0.0)
const VISITOR_SIZE := Vector3(1.0, 1.0, 1.0)

var camera_home := Vector3(0.0, 15.0, 17.3)
var camera_look_at := Vector3(0.0, 5.0, 0.0)

var _mesh := BoxMesh.new()
var _material := StandardMaterial3D.new()
var _visitors: Node3D


func _ready() -> void:
	_mesh.size = VISITOR_SIZE
	_material.albedo_color = Color(0.95, 0.72, 0.25)
	_material.roughness = 0.45

	_visitors = Node3D.new()
	_visitors.name = "Visitors"
	$Box3DWorld.add_child(_visitors)

	$Box3DWorld/Sensor.area_entered.connect(_on_sensor_visited)
	_drop_visitor()


## The shell's reusable Activate button: drop another box into the sensor.
func activate() -> void:
	_drop_visitor()


func _drop_visitor() -> void:
	var body := Box3DBody.new()
	body.box_size = VISITOR_SIZE
	body.position = VISITOR_SPAWN
	var visual := MeshInstance3D.new()
	visual.mesh = _mesh
	visual.material_override = _material
	body.add_child(visual)
	_visitors.add_child(body)


func _on_sensor_visited(visitor: Box3DBody) -> void:
	# Upstream destroys the visiting body on the begin-touch event. queue_free
	# defers to the end of the frame, so the solver is never re-entered from
	# inside its own event dispatch.
	if visitor != null and visitor.get_parent() == _visitors:
		visitor.queue_free()
