extends Node3D

## Every emitter ball in the world, drawn through ONE MultiMesh.
##
## Per-ball MeshInstance3Ds die by draw calls long before the solver hurts:
## the Ball Flood at 12k balls measured 45,000+ draw calls, 21 fps, solver
## 0.00 ms. This is the runtime twin of cube_grid_multimesh.gd -- that one
## adopts a FIXED set of bodies at load, this one grows as emitters spawn
## (capacity doubles when full; MultiMesh.instance_count changes reset the
## buffer, so visible_instance_count draws the live prefix and everything is
## rewritten on the rare grow). Colors ride as per-instance colors; radii as
## a scale baked into each instance basis (the mesh is a unit sphere), which
## also lets balls of different radii share the one mesh.
##
## Emitters opt in per scene (multimesh_render); adopt_into() finds or
## creates the world's shared cloud, so three emitters still mean one draw.

const _Self = preload("res://common/ball_cloud.gd")

const BASE_CAPACITY := 4096

var _mm: MultiMesh
var _mmi: MultiMeshInstance3D
var _bodies: Array[Node3D] = []
var _basis: Array[Basis] = []      ## per-ball radius, baked as a scale basis
var _colors: PackedColorArray = PackedColorArray()
var _last: PackedVector3Array = PackedVector3Array()  ## last origin written
var _born: PackedInt64Array = PackedInt64Array()  ## physics frame of adoption
var _world: Node = null


## Track `body` in `world`'s shared cloud, creating the cloud on first use.
static func adopt_into(world: Node3D, body: Node3D, ball_color: Color,
		radius: float) -> void:
	if world == null or body == null:
		return
	var cloud := world.get_node_or_null("BallCloud")
	if cloud == null:
		cloud = _Self.new()
		cloud.name = "BallCloud"
		world.add_child(cloud)
	cloud._adopt(body, ball_color, radius)


func _ready() -> void:
	_world = get_parent()
	# A coarse sphere: at emitter-ball size on screen 16x8 segments are
	# indistinguishable from the default 64x32, and at 12k balls the triangle
	# count is the difference between 3M and 50M.
	var sphere := SphereMesh.new()
	sphere.radius = 1.0
	sphere.height = 2.0
	sphere.radial_segments = 16
	sphere.rings = 8
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.3
	mat.metallic = 0.2
	sphere.material = mat

	_mm = MultiMesh.new()
	_mm.transform_format = MultiMesh.TRANSFORM_3D
	_mm.use_colors = true
	_mm.mesh = sphere
	_mm.instance_count = BASE_CAPACITY
	_mm.visible_instance_count = 0
	_mmi = MultiMeshInstance3D.new()
	_mmi.multimesh = _mm
	add_child(_mmi)


func _adopt(body: Node3D, ball_color: Color, radius: float) -> void:
	if _bodies.size() == _mm.instance_count:
		_grow()
	var i := _bodies.size()
	_bodies.append(body)
	_basis.append(Basis.from_scale(Vector3.ONE * radius))
	_colors.append(ball_color)
	# Write the spawn pose NOW, before the instance becomes visible: a slot
	# drawn before its first write shows stale buffer data for a frame -- the
	# ghost balls that flickered around the emitters.
	var origin := (global_transform.affine_inverse() * body.global_transform).origin
	_last.append(origin)
	_born.append(Engine.get_physics_frames())
	_mm.set_instance_transform(i, Transform3D(_basis[i], origin))
	_mm.set_instance_color(i, ball_color)
	_mm.visible_instance_count = _bodies.size()
	body.reset_physics_interpolation()


func _grow() -> void:
	_mm.instance_count = _mm.instance_count * 2  # resets the whole buffer
	# Rewrite everything IMMEDIATELY: the reset buffer holds identity
	# transforms, and deferring the rewrite to the next _process would flash
	# thousands of unit spheres at the origin for a frame.
	var inv := global_transform.affine_inverse()
	for i in _bodies.size():
		_mm.set_instance_color(i, _colors[i])
		var b := _bodies[i]
		if is_instance_valid(b):
			var origin := (inv * b.global_transform).origin
			_last[i] = origin
			_mm.set_instance_transform(i, Transform3D(_basis[i], origin))
	_mm.visible_instance_count = _bodies.size()


func _process(_delta: float) -> void:
	# The debug view shells the bodies; hide the cloud so the shells read.
	if _world != null and "debug_draw" in _world:
		_mmi.visible = not _world.debug_draw
	var inv := global_transform.affine_inverse()
	var now := Engine.get_physics_frames()
	var i := 0
	while i < _bodies.size():
		var b := _bodies[i]
		if not is_instance_valid(b):
			_release(i)
			continue
		# A newborn ball stays pinned to its spawn pose: until the engine has
		# two physics ticks of history for the node, the interpolated read
		# below returns junk, and writing it drew ghost balls popping around
		# the emitters for a frame.
		if now - _born[i] < 2:
			i += 1
			continue
		# Interpolated, like the grid renderer: raw physics transforms step
		# at tick rate on high-refresh displays. Rotation is dropped -- a
		# uniformly colored sphere spins invisibly -- so only a moved origin
		# costs a buffer write, and a sleeping ball costs nothing.
		var origin := (inv * b.get_global_transform_interpolated()).origin
		if origin != _last[i]:
			_last[i] = origin
			_mm.set_instance_transform(i, Transform3D(_basis[i], origin))
		i += 1


## Swap-remove: the last ball takes slot i, and the shrunk prefix is what
## visible_instance_count draws.
func _release(i: int) -> void:
	var last := _bodies.size() - 1
	_bodies[i] = _bodies[last]
	_basis[i] = _basis[last]
	_colors[i] = _colors[last]
	_born[i] = _born[last]
	_last[i] = _last[last]
	_bodies.remove_at(last)
	_basis.remove_at(last)
	_colors.remove_at(last)
	_born.remove_at(last)
	_last.remove_at(last)
	if i < _bodies.size():
		# Rewrite the slot NOW: deferring would draw the dead ball's stale
		# transform there, and the swapped-in ball may be a pinned newborn
		# the update loop deliberately skips.
		_mm.set_instance_color(i, _colors[i])
		var b := _bodies[i]
		if is_instance_valid(b):
			var origin := (global_transform.affine_inverse() * b.global_transform).origin
			_last[i] = origin
			_mm.set_instance_transform(i, Transform3D(_basis[i], origin))
	_mm.visible_instance_count = _bodies.size()
