extends Node3D

## Joint Grid -- a port of upstream's "Benchmark / Joint Grid"
## (samples/sample_benchmark.cpp:206, built by CreateJointGrid in
## shared/benchmarks.c:33). A square lattice of spheres, every one tied to its
## neighbour above and to its left by a SPHERICAL joint, hanging from a static
## top row. Sleeping is off world-wide and on every body, so the whole net is
## awake every step: this measures the solver's joint graph and nothing else.
##
## The spheres are filtered out of colliding with each other (upstream's
## `categoryBits = 2, maskBits = ~2`), so there is not a single contact in the
## scene -- every newton in it comes through a joint.
##
## **Scaled down from upstream.** Upstream runs a 100 x 100 grid: 10,000 bodies
## and 19,800 joints, which is a headless benchmark number, not something the
## sample browser can carry at 60 fps next to a camera and a UI. This ships the
## 32 x 32 grid -- 1,024 bodies and 1,984 joints -- which keeps the lattice
## behaviour and the joint-bound profile at demo cost. The single-threaded
## browser build takes 22 x 22 (484 bodies, 924 joints), the same halving the
## Cube Pile does there. Upstream's own debug configuration uses 10 x 10.
##
## Rendering is one MultiMesh: a thousand separate MeshInstance3Ds would make
## this a draw-call benchmark instead of a solver one.

## Grid lines per side. Upstream: 100 (release) / 10 (BENCHMARK_DEBUG).
const GRID_N := 32
const GRID_N_WEB := 22

const SPHERE_RADIUS := 0.4
const SPACING := 1.0  # bodies at (k, -i, 0)

## b3ShapeDef.filter: one category, masked out of itself, so no sphere ever
## touches another one -- upstream's `categoryBits = 2, maskBits = ~2u`.
##
## The BIT is deliberately not upstream's 2: layer 2 is the demo shell's
## invisible-guard layer, and the camera's grab ray and its projectiles both
## skip it (`RAY_MASK = 0xFFFFFFFF ^ 2`, common/fly_camera.gd:39). On category 2
## the whole grid was unclickable -- every left-drag grab raycast filtered the
## spheres out before it could hit one. Which bit carries the "don't touch your
## neighbours" rule is arbitrary; not colliding with the shell is not.
const CATEGORY := 4
const MASK := 0xFFFFFFFB  # ~4u

var camera_home := Vector3.ZERO
var camera_look_at := Vector3.ZERO

var _n := GRID_N
var _bodies: Array[Box3DBody] = []
var _mm: MultiMesh
var _joint_count := 0


func _init() -> void:
	if OS.has_feature("web") and not OS.has_feature("threads"):
		_n = GRID_N_WEB
	# Camera::SetView(-25 deg yaw, 25 deg pitch, radius, pivot) on the grid's
	# centre, with upstream's ~0.95 * n framing radius.
	var pivot := Vector3(0.5 * (_n - 1) * SPACING, -0.5 * (_n - 1) * SPACING, 0.0)
	var yaw := deg_to_rad(-25.0)
	var pitch := deg_to_rad(25.0)
	var radius := 1.3 * _n * SPACING
	camera_home = pivot + radius * Vector3(
		cos(pitch) * sin(yaw), sin(pitch), cos(pitch) * cos(yaw))
	camera_look_at = pivot


func _ready() -> void:
	var world: Box3DWorld = $Box3DWorld
	world.enable_sleep = false  # b3World_EnableSleeping(worldId, false)

	var grid := Node3D.new()
	grid.name = "Grid"
	world.add_child(grid)

	# Upstream's index order: k is the column (x), i is the row (down y). The
	# body list is indexed the same way so index - 1 is the body above and
	# index - n the one in the previous column.
	for k in _n:
		for i in _n:
			var body := Box3DBody.new()
			body.name = "S_%d_%d" % [k, i]
			body.body_type = Box3DBody.STATIC if i == 0 else Box3DBody.DYNAMIC
			body.shape_type = Box3DBody.SPHERE
			body.sphere_radius = SPHERE_RADIUS
			body.position = Vector3(k * SPACING, -i * SPACING, 0.0)
			body.can_sleep = false
			body.angular_damping = 0.0  # b3DefaultBodyDef; the node defaults to 0.05
			body.collision_layer = CATEGORY
			body.collision_mask = MASK
			# The MultiMesh draws every sphere; the nodes carry no visual.
			body.sync_node_transform = true
			grid.add_child(body)
			_bodies.append(body)

			var index := _bodies.size() - 1
			if i > 0:
				_link(grid, _bodies[index - 1], body)
			if k > 0:
				_link(grid, _bodies[index - _n], body)

	_build_multimesh()
	print("[joint_grid] %d bodies, %d spherical joints" % [_bodies.size(), _joint_count])


## One spherical joint between two neighbours. Upstream anchors it half a metre
## from each body along the line between them (localFrameA.p = (0, -0.5, 0) /
## localFrameB.p = (0, 0.5, 0) for the vertical pair, and the x pair for the
## horizontal one), which is the midpoint -- so the joint node goes there and
## the node's own frames come out identical.
func _link(p_parent: Node3D, p_a: Box3DBody, p_b: Box3DBody) -> void:
	var joint := Box3DBallJoint.new()
	joint.name = "J%d" % _joint_count
	joint.position = 0.5 * (p_a.position + p_b.position)
	p_parent.add_child(joint)
	joint.body_a = NodePath("../%s" % p_a.name)
	joint.body_b = NodePath("../%s" % p_b.name)
	_joint_count += 1


func _build_multimesh() -> void:
	var sphere := SphereMesh.new()
	sphere.radius = SPHERE_RADIUS
	sphere.height = 2.0 * SPHERE_RADIUS
	sphere.radial_segments = 12
	sphere.rings = 6
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.45
	sphere.material = mat

	_mm = MultiMesh.new()
	_mm.transform_format = MultiMesh.TRANSFORM_3D
	_mm.use_colors = true
	_mm.mesh = sphere
	_mm.instance_count = _bodies.size()
	for i in _bodies.size():
		_mm.set_instance_transform(i, Transform3D(Basis(), _bodies[i].position))
		# Static top row in slate, the hanging net in a column-wise hue ramp.
		var hue := float(i / _n) / float(_n)
		_mm.set_instance_color(i, Color(0.35, 0.4, 0.45) if _bodies[i].body_type == Box3DBody.STATIC
			else Color.from_hsv(hue, 0.45, 0.95))

	var mmi := MultiMeshInstance3D.new()
	mmi.name = "GridVisual"
	mmi.multimesh = _mm
	add_child(mmi)


func _process(_delta: float) -> void:
	if _mm == null:
		return
	for i in _bodies.size():
		_mm.set_instance_transform(i, _bodies[i].global_transform)


func get_bodies() -> Array[Box3DBody]:
	return _bodies


func get_joint_count() -> int:
	return _joint_count
