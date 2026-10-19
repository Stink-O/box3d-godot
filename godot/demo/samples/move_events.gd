extends Node3D

## Body Move Events -- a port of upstream's "Events / Move" sample
## (samples/sample_events.cpp:247-327). A 20 m column, hinged at nothing,
## stands on its base and is launched so that its base point starts at rest:
## it topples like a felled tree. Every step the sample reads the world's
## body move events (Box3DWorld.get_move_events, upstream's
## b3World_GetBodyEvents) and prints one line per event, "big box moved"
## while it falls and "big box fell asleep" on the one step it settles,
## after which there are no events at all.
##
## Upstream's numbers are kept: the body "big box" has its origin at the
## pivot (0, 1, 0) and one box hull of half extents (0.5, 10, 0.5) centred
## 10 m above it (:255-268), density 1000 (b3DefaultShapeDef) with hit
## events on (:264), on AddGroundBox(40) under gravity -10. Its launch
## (:270-280): v = (-10, 0, 0) and omega = (v x r) / |r|^2 with r the pivot
## relative to the centre of mass, which makes the pivot's own velocity
## zero, so the column pivots about its foot. The first readout is
## upstream's (:285-292): the pivot's velocity vp, and the body's v and w.

const PIVOT := Vector3(0.0, 1.0, 0.0)
const LAUNCH := Vector3(-10.0, 0.0, 0.0)

## m_camera->SetView(0, 30, 40, {0, 5, 0}) (:254): eye = pivot + radius *
## (sin yaw cos pitch, sin pitch, cos yaw cos pitch)
## (samples/host/camera.cpp:35-39,216-220).
var camera_home := Vector3(0.0, 5.0 + 40.0 * sin(deg_to_rad(30.0)), 40.0 * cos(deg_to_rad(30.0)))
var camera_look_at := Vector3(0.0, 5.0, 0.0)

## The last step's readout lines, upstream's DrawTextLine output.
var event_lines: Array[String] = []
var _local_pivot := Vector3.ZERO
@onready var _world: Box3DWorld = $Box3DWorld
@onready var _box: Box3DBody = $"Box3DWorld/big box"
@onready var _label: Label3D = $Status


func _ready() -> void:
	# After the world's step, so the event list is this step's (:296-312).
	process_physics_priority = 1
	_local_pivot = _box.to_local(PIVOT)
	var r := PIVOT - _box.get_center_of_mass()
	var rr := r.length_squared()
	if rr > 0.0:
		_box.set_angular_velocity(LAUNCH.cross(r) / rr)
		_box.set_linear_velocity(LAUNCH)
	_refresh()


func _physics_process(_delta: float) -> void:
	event_lines.clear()
	for e: Dictionary in _world.get_move_events():
		var body: Box3DBody = e["body"]
		var label := body.get_body_name() if body != null else "?"
		event_lines.append("%s fell asleep" % label if e["fell_asleep"] else "%s moved" % label)
	_refresh()


func _refresh() -> void:
	var vp := _box.get_local_point_velocity(_local_pivot)
	var v := _box.get_linear_velocity()
	var w := _box.get_angular_velocity()
	var text := "vp = [%.2f, %.2f, %.2f], v = [%.2f, %.2f, %.2f], w = [%.2f, %.2f, %.2f]" % [
			vp.x, vp.y, vp.z, v.x, v.y, v.z, w.x, w.y, w.z]
	for line in event_lines:
		text += "\n" + line
	_label.text = text


func rig_notes() -> Array:
	return ["Godot Physics and Jolt have no move-event list; the column is rebuilt "
			+ "and topples, but the readout is Box3D's."]
