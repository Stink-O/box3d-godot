extends Node3D

## Hull Reduction -- a port of upstream's "Geometry / Hull Reduction" sample
## (samples/sample_geometry.cpp:232-360).
##
## `b3CreateHull(points, count, maxVertexCount)` does not just wrap a point
## cloud: its third argument is a BUDGET, and the hull it returns is the best
## convex approximation it can build inside that budget (collision.h:225). That
## is the call a game actually ships -- artists hand over a mesh with hundreds of
## corners and the collider gets eight of them. Upstream's sample makes the
## budget a slider from 4 to 128 over a fixed cloud of 128 points and lets you
## watch the shape coarsen.
##
## A slider has no place in a headless sample, so this port shows the whole
## sweep at once: one body per budget, in a row, each built from THE SAME 128
## points and dropped on the ground. Left to right the collider goes from a
## tetrahedron to a faceted ball -- and every one of them is a real collider,
## not a drawing, so the coarse ones visibly rock on their flat faces while the
## fine ones roll.
##
## The cloud is upstream's, drawn from upstream's own generator (XorShift32
## seeded 42, samples/sample_geometry.cpp:259, generator at shared/utils.h:27-60)
## in the same order the C draws it, so these are the same 128 points:
##
##  * SPHERE (upstream's startup mode, samples/sample_geometry.cpp:253) --
##    `RandomUnitVector()`, Shoemake's method, three draws per point. It
##    converts its angles with `b3ComputeCosSin`, a normalized Bhaskara
##    approximation rather than libm (src/math_functions.c:216-263), which is
##    reproduced here for the same reason.
##  * BOX -- `RandomVec3` over [-2, 2] cubed, clamped into [-1, 1] cubed, plus a
##    1 mm noise vector: six draws per point (samples/sample_geometry.cpp:263-
##    276). The clamp is what makes it interesting, because it puts most of the
##    cloud exactly on the faces of a cube, and the noise is what stops those
##    coplanar points being a degenerate input.
##
## The top-bar toggle switches between the two clouds and rebuilds the row,
## which is upstream's pair of radio buttons.
##
## Upstream reports `v/f/e` off the `b3HullData` (samples/sample_geometry.cpp:
## 336). The binding hands back data rather than a pointer -- vertices and a
## triangulated surface -- so the readout here is the achieved vertex count
## against the budget, which is the number the sample is really about: the budget
## is a ceiling, not a target, and it stops binding as soon as the cloud runs out
## of corners. The box cloud saturates at 40 vertices however high the budget
## goes, because a noisy cube simply has no more.
##
## THE REAL CEILING IS NOT THE VERTEX BUDGET. `B3_MAX_HULL_VERTICES` is 128
## (constants.h:115), but `B3_MAX_HULL_EDGES` is also 128 -- 256 half edges
## (constants.h:121) -- and that is what binds first. A hull over a rounded cloud
## is all triangles, so `2E = 6V - 12`, which caps it at 44 vertices; ask for 48
## and box3d prints "hull final half edge count of 276 exceeds limit of 256" and
## returns NOTHING rather than reducing further. The budgets here stop at 44 for
## that reason, and 44 is measured, not guessed.
##
## One addition of this port's own, because upstream's sample has no world at
## all: rolling resistance, so the round end of the row settles in its slot
## instead of rolling out of frame.

## Upstream's cloud size, its `m_capacity` (samples/sample_geometry.cpp:352).
const POINT_COUNT := 128
## Upstream's seed for this scene (samples/sample_geometry.cpp:259).
const RANDOM_SEED := 42
const RAND_LIMIT := 32767

## Budgets across upstream's slider range of 4 to 128
## (samples/sample_geometry.cpp:325), stopping at the 44 the half-edge limit
## actually allows (see the header).
const BUDGETS := [4, 6, 8, 12, 16, 24, 32, 44]

## Upstream's box cloud bounds, clamp and noise (samples/sample_geometry.cpp:
## 263-266).
const BOX_LOWER := Vector3(-2.0, -2.0, -2.0)
const BOX_UPPER := Vector3(2.0, 2.0, 2.0)
const BOX_CLAMP := Vector3(1.0, 1.0, 1.0)
const BOX_NOISE := 0.001

const SPACING := 2.8
const DROP_HEIGHT := 1.8
const ROLLING_RESISTANCE := 0.3
const GROUND_SIZE := Vector3(60.0, 1.0, 20.0)

var camera_home := Vector3(0.0, 9.5, 17.0)
var camera_look_at := Vector3(0.0, 0.5, 0.0)

var _world: Box3DWorld
var _bodies: Array[Box3DBody] = []
## false = upstream's sphere cloud, which is the mode it starts in.
var _box_cloud := false
var _rand_state := RANDOM_SEED

@onready var _label: Label3D = $Status


func _ready() -> void:
	_world = $Box3DWorld

	var ground := Box3DBody.new()
	ground.name = "Ground"
	ground.body_type = Box3DBody.STATIC
	ground.shape_type = Box3DBody.BOX
	ground.box_size = GROUND_SIZE
	ground.position = Vector3(0.0, -0.5 * GROUND_SIZE.y, 0.0)
	ground.auto_visual = false
	var ground_visual := MeshInstance3D.new()
	ground_visual.name = "GroundMesh"
	var ground_mesh := BoxMesh.new()
	ground_mesh.size = GROUND_SIZE
	ground_visual.mesh = ground_mesh
	ground_visual.material_override = _material(Color(0.22, 0.24, 0.27))
	ground.add_child(ground_visual)
	_world.add_child(ground)

	_build_row()


func get_toggle_label() -> String:
	return "Box Cloud"


## Upstream opens on the sphere cloud, so the switch starts off.
func get_toggle_initial() -> bool:
	return _box_cloud


func set_toggled(p_on: bool) -> void:
	if p_on == _box_cloud:
		return
	_box_cloud = p_on
	_build_row()


## The shell's Activate button: drop the row again from the start pose.
func activate() -> void:
	_build_row()


func _build_row() -> void:
	for body in _bodies:
		# Removed from the tree first, not just queued: leaving the tree is what
		# destroys the Box3D body, and queue_free() alone would leave the old
		# row colliding with the new one for a frame.
		_world.remove_child(body)
		body.queue_free()
	_bodies.clear()

	var points := _generate_points()
	var lines := PackedStringArray([
		"128 points, %s cloud" % ("box" if _box_cloud else "sphere")])
	var achieved := PackedStringArray()

	for k in BUDGETS.size():
		var budget := int(BUDGETS[k])
		var hull := Box3DGeometry.create_hull(points, budget)
		var verts: PackedVector3Array = hull["vertices"]
		achieved.append("%d/%d" % [verts.size(), budget])

		var mesh := Box3DGeometry.make_array_mesh(hull)
		var body := Box3DBody.new()
		body.name = "Hull%d" % budget
		body.body_type = Box3DBody.DYNAMIC
		body.shape_type = Box3DBody.HULL
		body.collision_mesh = mesh
		body.rolling_resistance = ROLLING_RESISTANCE
		body.auto_visual = false
		body.position = Vector3((k - 0.5 * (BUDGETS.size() - 1)) * SPACING, DROP_HEIGHT, 0.0)
		var visual := MeshInstance3D.new()
		visual.name = "Visual"
		visual.mesh = mesh
		visual.material_override = _material(Color.from_hsv(
				0.08 + 0.5 * float(k) / float(BUDGETS.size() - 1), 0.6, 0.9))
		body.add_child(visual)
		_world.add_child(body)
		_bodies.append(body)

	lines.append("hull verts / budget: " + "  ".join(achieved))
	_label.text = "\n".join(lines)


func _material(p_color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = p_color
	m.roughness = 0.55
	return m


# --- upstream's point clouds --------------------------------------------------


func _generate_points() -> PackedVector3Array:
	# Upstream reseeds on every regeneration, so switching modes and switching
	# back gives the same cloud (samples/sample_geometry.cpp:259).
	_rand_state = RANDOM_SEED
	var points := PackedVector3Array()
	points.resize(POINT_COUNT)
	for i in POINT_COUNT:
		if _box_cloud:
			var p := _random_vec3(BOX_LOWER, BOX_UPPER)
			p = p.clamp(-BOX_CLAMP, BOX_CLAMP)
			var f := _random_vec3(
					Vector3(-BOX_NOISE, -BOX_NOISE, -BOX_NOISE),
					Vector3(BOX_NOISE, BOX_NOISE, BOX_NOISE))
			points[i] = p + f
		else:
			points[i] = _random_unit_vector()
	return points


# --- upstream's random number generator (shared/utils.h:27-135) ----------------
# Reproduced rather than approximated, because the point of the scene is that it
# is upstream's cloud. GDScript integers are 64-bit and signed, so every shift is
# masked back to 32 bits.


func _random_int() -> int:
	var x := _rand_state
	x = (x ^ (x << 13)) & 0xFFFFFFFF
	x = x ^ (x >> 17)
	x = (x ^ (x << 5)) & 0xFFFFFFFF
	_rand_state = x
	return x % (RAND_LIMIT + 1)


func _random_float_range(p_lo: float, p_hi: float) -> float:
	var r := float(_random_int() & RAND_LIMIT) / float(RAND_LIMIT)
	return (p_hi - p_lo) * r + p_lo


func _random_vec3(p_lo: Vector3, p_hi: Vector3) -> Vector3:
	# x, y, z in that order -- the draw order is part of the sequence.
	var x := _random_float_range(p_lo.x, p_hi.x)
	var y := _random_float_range(p_lo.y, p_hi.y)
	var z := _random_float_range(p_lo.z, p_hi.z)
	return Vector3(x, y, z)


## Shoemake's method as upstream spells it (shared/utils.h:90-111). Note that
## upstream's "unit" vector is the vector part of a uniform random quaternion
## and is therefore NOT of unit length; it is reproduced as written.
func _random_unit_vector() -> Vector3:
	var u1 := _random_float_range(0.0, 1.0)
	var u2 := _random_float_range(0.0, TAU)
	var u3 := _random_float_range(0.0, TAU)
	var sqrt1_minus_u1 := sqrt(1.0 - u1)
	var sqrt_u1 := sqrt(u1)
	var cs2 := _cos_sin(u2)
	var cs3 := _cos_sin(u3)
	return Vector3(sqrt1_minus_u1 * cs2.y, sqrt1_minus_u1 * cs2.x, sqrt_u1 * cs3.y)


## `b3ComputeCosSin` (src/math_functions.c:216-263), returned as (cos, sin).
## Box3D does not call libm here: it evaluates a pair of Bhaskara rational
## approximations and normalizes the result.
func _cos_sin(p_radians: float) -> Vector2:
	# b3UnwindAngle is remainderf(radians, 2 * PI): the residue toward the
	# NEAREST multiple of a turn, which lands in [-PI, PI], not fmod's [0, TAU).
	var x: float = p_radians - TAU * roundf(p_radians / TAU)
	var pi2 := PI * PI

	var c := 0.0
	if x < -0.5 * PI:
		var y := x + PI
		c = -(pi2 - 4.0 * y * y) / (pi2 + y * y)
	elif x > 0.5 * PI:
		var y := x - PI
		c = -(pi2 - 4.0 * y * y) / (pi2 + y * y)
	else:
		c = (pi2 - 4.0 * x * x) / (pi2 + x * x)

	var s := 0.0
	if x < 0.0:
		var y := x + PI
		s = -16.0 * y * (PI - y) / (5.0 * pi2 - 4.0 * y * (PI - y))
	else:
		s = 16.0 * x * (PI - x) / (5.0 * pi2 - 4.0 * x * (PI - x))

	var mag := sqrt(s * s + c * c)
	var inv_mag := 1.0 / mag if mag > 0.0 else 0.0
	return Vector2(c * inv_mag, s * inv_mag)
