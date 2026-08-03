class_name NativeWorld
extends Node3D

## Stand-in for Box3DWorld when a sample is running on Godot Physics or Jolt.
##
## The demo shell is written against Box3DWorld: main.gd looks the world up as
## `get_node_or_null("Box3DWorld")` in seven places, and fly_camera.gd needs
## `add_child`, `global_transform`, `gravity` and `raycast`. This node answers
## all of that, and is DELIBERATELY NAMED "Box3DWorld" by whoever adds it, so
## none of those lookups need to change.
##
## What it deliberately does NOT have is as important as what it does. The
## sidebar shows a row only when `"substep_count" in world` and friends hold
## (main.gd:574-585), so leaving those properties off is what makes the Box3D
## solver controls hide themselves on a native engine. Same for
## `get_step_time_ms`: common/stats_overlay.gd:146 probes for the method and
## drops its solver line when it is missing. Do not add stubs here to "be
## compatible" — a stub would put a dead control back on screen.
##
## Bodies live in the viewport's own World3D space; this node is a container and
## a query facade, not an owner. Per-world gravity has no native equivalent, so
## the setter writes the space's gravity through PhysicsServer3D.

## Which server is actually stepping: "Godot Physics" or "Jolt Physics".
var engine_name := "Godot Physics"

var _gravity := Vector3(0, -9.8, 0)


var gravity: Vector3:
	get:
		return _gravity
	set(value):
		_gravity = value
		_push_gravity()


func _ready() -> void:
	_push_gravity()


func _space() -> RID:
	var world := get_viewport().find_world_3d()
	return world.space if world != null else RID()


## Gravity is a space parameter natively, not a per-world node property. 30 of
## the samples set a non-default value (car -10, gyro_torque zero), so this
## has to be honoured or those samples simply run wrong.
## The space's default area is not exposed to script, but both servers'
## area_set_param() accept a SPACE rid and forward it to that space's default
## area, so the space RID is the handle.
func _push_gravity() -> void:
	var space := _space()
	if not space.is_valid():
		return
	var length := _gravity.length()
	PhysicsServer3D.area_set_param(space, PhysicsServer3D.AREA_PARAM_GRAVITY_IS_POINT, false)
	PhysicsServer3D.area_set_param(space, PhysicsServer3D.AREA_PARAM_GRAVITY, length)
	PhysicsServer3D.area_set_param(space, PhysicsServer3D.AREA_PARAM_GRAVITY_VECTOR,
			_gravity.normalized() if length > 0.0 else Vector3.DOWN)


## Same signature and return shape as Box3DWorld.raycast, because fly_camera.gd
## consumes both: {"hit": false} or
## {"hit": true, "position", "normal", "fraction", "collider"}.
##
## The mask semantics differ and cannot be fully reconciled: Box3D collides only
## when both sides accept each other, Godot when either does. For a camera pick
## ray that difference is immaterial, and RigNative already rewrites body layers
## so the scene-level filtering matches.
func raycast(from: Vector3, to: Vector3, collision_mask: int = 0xFFFFFFFF) -> Dictionary:
	var space := _space()
	if not space.is_valid():
		return {"hit": false}
	var state := PhysicsServer3D.space_get_direct_state(space)
	if state == null:
		return {"hit": false}
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = collision_mask
	query.collide_with_areas = false
	query.collide_with_bodies = true
	var hit := state.intersect_ray(query)
	if hit.is_empty():
		return {"hit": false}
	var span := from.distance_to(to)
	var result := {
		"hit": true,
		"position": hit["position"],
		"normal": hit["normal"],
		"fraction": (from.distance_to(hit["position"]) / span) if span > 0.0 else 0.0,
	}
	if hit.has("collider") and hit["collider"] != null:
		result["collider"] = hit["collider"]
	return result
