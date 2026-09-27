extends Node3D

## Draws every Box3DBody child as one instance of the shared barrel mesh --
## one draw call for the whole spire.
##
## The runtime twin of cube_grid_multimesh.gd, and it exists for the same
## reason: 3000 barrels as 3000 MeshInstance3Ds is 3000 draw calls a frame,
## which is what actually kills this scene on mobile and through a browser's
## GL translator long before the solver notices 3000 hulls. Physics is
## untouched -- the same Box3DBody nodes, so grabbing, shooting and raycasts
## behave exactly as they would without this node.
##
## Bodies must already be children when this enters the tree: _ready adopts
## what it finds and never looks again.

const Barrel = preload("res://common/barrel.gd")

## How far apart two drums can look. All of it is brightness: the paint is in
## the mesh's vertex colors (barrel.gd), and the per-instance color only
## multiplies it, so this is weathering rather than a second palette.
const WEATHER_MIN := 0.78
const WEATHER_MAX := 1.0

var _bodies: Array[Box3DBody] = []
## What each body was tinted with, kept here as well as in the MultiMesh: the
## MultiMesh is server-side state and `get_instance_color` reads back black
## under --headless, so this array is the only answer available to the replay
## sidecar (see get_replay_body_colors below).
var _colors: PackedColorArray = PackedColorArray()
var _mm: MultiMesh
var _mmi: MultiMeshInstance3D
var _world: Node = null
var _last: Array[Transform3D] = []  ## last transform written per instance


func _ready() -> void:
	_world = get_parent()
	for c in get_children():
		if c is Box3DBody:
			_bodies.append(c)
			# Anything that came with its own visual is drawn by us now.
			var mesh := c.get_node_or_null("MeshInstance3D")
			if mesh != null:
				mesh.queue_free()

	_mm = MultiMesh.new()
	_mm.transform_format = MultiMesh.TRANSFORM_3D
	_mm.use_colors = true
	_mm.mesh = Barrel.mesh()
	_mm.instance_count = _bodies.size()
	_last.resize(_bodies.size())
	_colors.resize(_bodies.size())
	for i in _bodies.size():
		var w := randf_range(WEATHER_MIN, WEATHER_MAX)
		_colors[i] = Color(w, w, w)
		_mm.set_instance_color(i, _colors[i])
		# The bodies and the MultiMeshInstance are siblings under this node, so
		# body-local transforms are already in the right space.
		_last[i] = _bodies[i].transform
		_mm.set_instance_transform(i, _last[i])

	_mmi = MultiMeshInstance3D.new()
	_mmi.multimesh = _mm
	# As in cube_grid_multimesh.gd and ball_cloud.gd: physics_interpolation=true
	# also switches on the RenderingServer's OWN MultiMesh interpolation, a
	# second blend on top of the interpolated transforms _process writes.
	# Interpolate in exactly one place.
	_mmi.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	RenderingServer.multimesh_set_physics_interpolated(_mm.get_rid(), false)
	add_child(_mmi)


## F-042's colour protocol. These barrels have no MeshInstance3D to read a
## material off, so a recording can only learn their colours by asking.
func get_replay_body_colors() -> Dictionary:
	var out := {}
	for i in _bodies.size():
		if i < _colors.size() and is_instance_valid(_bodies[i]):
			out[_bodies[i]] = _colors[i]
	return out


func _process(_delta: float) -> void:
	# The debug view replaces bodies' looks with collider shells; hide ours.
	if _world != null and "debug_draw" in _world:
		_mmi.visible = not _world.debug_draw
	var inv := global_transform.affine_inverse()
	for i in _bodies.size():
		var t := inv * _bodies[i].get_global_transform_interpolated()
		# A settled spire is 3000 bodies asleep at a constant transform;
		# skipping the write keeps the buffer clean and uploads nothing.
		if t != _last[i]:
			_last[i] = t
			_mm.set_instance_transform(i, t)
