extends Node3D

## Box Hull -- a port of upstream's "Geometry / Box Hull" sample
## (samples/sample_geometry.cpp:12-136).
##
## Upstream's sample is a side-by-side of two ways to make the same shape. It
## takes a box of half extents `h`, a rigid transform and a post scale, and
## builds the box twice:
##
##  * the general path -- transform the eight corners by hand, apply the post
##    scale componentwise, and hand the point cloud to `b3CreateHull`
##    (samples/sample_geometry.cpp:57-67);
##  * the fast path -- `b3MakeScaledBoxHull(h, transform, postScale)`, which
##    returns a `b3BoxHull` BY VALUE that must not be destroyed
##    (collision.h:252-259).
##
## It draws them overlaid, yellow over cyan, with sliders for every argument.
## The reason the sliders are there is the interesting part: the fast path is
## documented as approximate under shear (collision.h:252-259), and the sliders
## are how you find the shear.
##
## Both factories are `Box3DGeometry` static calls here (P-042), so the port is
## the same comparison with the sliders replaced by four fixed cases -- and with
## the agreement MEASURED rather than eyeballed. The readout is the Hausdorff
## distance between the two vertex sets: the largest distance from a corner of
## one hull to the nearest corner of the other, both ways round.
##
## WHAT THE MEASUREMENT SAYS, and it is sharper than "approximate":
##
##  * a rotation with a UNIFORM scale agrees to 0.0 mm -- a similarity does not
##    shear a box, so the fast path is exact;
##  * a rotation with a MIRROR scale agrees to 0.0 mm for the same reason: a
##    reflection of equal magnitude on every axis is still a similarity;
##  * a NON-UNIFORM scale with an axis-aligned transform agrees to 0.0 mm --
##    stretching a box along its own axes just gives a different box;
##  * a rotation AND a non-uniform scale is the case that shears, and there the
##    two hulls' corners part by the better part of a metre on a 2 x 1 x 0.5 m
##    box. The general path is the correct one there; the fast path is the cheap
##    one, and this is the price of it.
##
## Upstream's own way out of that case is `b3ScaleBox` (collision.h:261-268,
## `Box3DGeometry.scale_box`), which resolves a post scale back into half extents
## and a transform -- what a level editor needs when an artist has scaled a box
## node. It is approximate under shear for exactly the same reason.
##
## The one deliberate departure from upstream: its Box Hull creates no world at
## all -- it is a pure geometry viewer. This demo's samples are physical, so each
## hull is also a real collider. That costs nothing and adds something: the
## `Box3DGeometry` Dictionary goes through `make_array_mesh` and straight into
## `Box3DBody.collision_mesh`, which is the whole authoring route from a box3d
## geometry factory to a Godot rigid body, mirrored and sheared boxes included.
##
## Constants: `h = (1.0, 0.5, 0.25)` is upstream's own default
## (samples/sample_geometry.cpp:25); the rotations and scales are fixed picks
## from inside upstream's own slider ranges (rotation -180..180 deg, scale -2..2,
## samples/sample_geometry.cpp:88, :98), with the transform's position left at
## upstream's default of zero. Rotations are composed upstream's way,
## `qz * qy * qx` (samples/sample_geometry.cpp:39-44).

## Upstream's default half extents. Box3D geometry takes HALF extents
## throughout; Box3DBody.box_size would be twice these.
const HALF_EXTENTS := Vector3(1.0, 0.5, 0.25)

## One case per regime. `rotation` is Euler degrees applied qz * qy * qx.
const CASES := [
	{
		"label": "rotated, uniform",
		"rotation": Vector3(25.0, 40.0, 15.0),
		"scale": Vector3(1.5, 1.5, 1.5),
	},
	{
		"label": "rotated, mirrored",
		"rotation": Vector3(25.0, 40.0, 15.0),
		"scale": Vector3(-1.0, 1.0, 1.0),
	},
	{
		"label": "axis-aligned, non-uniform",
		"rotation": Vector3(0.0, 0.0, 0.0),
		"scale": Vector3(1.6, 0.6, 1.0),
	},
	{
		"label": "rotated, non-uniform (shear)",
		"rotation": Vector3(25.0, 40.0, 15.0),
		"scale": Vector3(1.6, 0.6, 1.0),
	},
]

const CASE_SPACING := 3.4
const PAIR_OFFSET := 1.7
const DROP_HEIGHT := 3.0
const GROUND_SIZE := Vector3(40.0, 1.0, 40.0)

## Yellow is upstream's colour for the general hull, cyan for the box hull
## (samples/sample_geometry.cpp:113-114).
const COLOR_HULL := Color(0.95, 0.85, 0.25)
const COLOR_BOX := Color(0.30, 0.85, 0.90)

var camera_home := Vector3(11.5, 7.0, 11.5)
var camera_look_at := Vector3(0.0, 0.8, 0.0)

@onready var _label: Label3D = $Status


func _ready() -> void:
	var world: Box3DWorld = $Box3DWorld

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
	world.add_child(ground)

	var lines := PackedStringArray([
		"yellow = b3CreateHull(8 corners), cyan = b3MakeScaledBoxHull"])

	for k in CASES.size():
		var info: Dictionary = CASES[k]
		var post_scale: Vector3 = info["scale"]
		var xform := Transform3D(Basis(_rotation(info["rotation"])), Vector3.ZERO)
		var z := (k - 0.5 * (CASES.size() - 1)) * CASE_SPACING

		# The general path: upstream's eight corners, in upstream's order.
		var hull := Box3DGeometry.create_hull(_corner_points(xform, post_scale), 8)
		# The fast path: one call, and its result is a value type upstream never
		# destroys.
		var box := Box3DGeometry.make_scaled_box_hull(HALF_EXTENTS, xform, post_scale)

		_spawn(world, "Hull%d" % k, hull, Vector3(-PAIR_OFFSET, DROP_HEIGHT, z), COLOR_HULL)
		_spawn(world, "Box%d" % k, box, Vector3(PAIR_OFFSET, DROP_HEIGHT, z), COLOR_BOX)

		var a: PackedVector3Array = hull["vertices"]
		var b: PackedVector3Array = box["vertices"]
		var deviation := maxf(_max_deviation(a, b), _max_deviation(b, a))
		lines.append("%s: corners part by %.1f mm" % [info["label"], 1000.0 * deviation])

	_label.text = "\n".join(lines)


## Upstream's eight corners (samples/sample_geometry.cpp:57-64): transform the
## corner, then multiply by the post scale componentwise. Upstream guards the
## scale with `b3SafeScale`, which only clamps components below B3_MIN_SCALE;
## every scale here is far above it, so the guard would be a no-op.
func _corner_points(p_transform: Transform3D, p_scale: Vector3) -> PackedVector3Array:
	var h := HALF_EXTENTS
	var corners := PackedVector3Array([
		Vector3(h.x, h.y, h.z),
		Vector3(h.x, h.y, -h.z),
		Vector3(h.x, -h.y, h.z),
		Vector3(h.x, -h.y, -h.z),
		Vector3(-h.x, h.y, h.z),
		Vector3(-h.x, h.y, -h.z),
		Vector3(-h.x, -h.y, h.z),
		Vector3(-h.x, -h.y, -h.z),
	])
	var points := PackedVector3Array()
	points.resize(corners.size())
	for i in corners.size():
		points[i] = (p_transform * corners[i]) * p_scale
	return points


## Upstream composes its slider angles as qz * qy * qx
## (samples/sample_geometry.cpp:39-44).
func _rotation(p_degrees: Vector3) -> Quaternion:
	var qx := Quaternion(Vector3.RIGHT, deg_to_rad(p_degrees.x))
	var qy := Quaternion(Vector3.UP, deg_to_rad(p_degrees.y))
	var qz := Quaternion(Vector3.BACK, deg_to_rad(p_degrees.z))
	return qz * qy * qx


## Largest distance from a point of p_from to the nearest point of p_to. Run both
## ways round it is the Hausdorff distance between the two vertex sets, which is
## zero exactly when the hulls have the same corners.
func _max_deviation(p_from: PackedVector3Array, p_to: PackedVector3Array) -> float:
	var worst := 0.0
	for a in p_from:
		var nearest := INF
		for b in p_to:
			nearest = minf(nearest, a.distance_to(b))
		worst = maxf(worst, nearest)
	return worst


## The Dictionary a geometry factory returns is both the collider and the visual:
## `make_array_mesh` turns it into a Godot surface, and the HULL shape type
## re-hulls that surface's points, so the drawn shape is the queried one.
func _spawn(p_world: Box3DWorld, p_name: String, p_geometry: Dictionary, p_at: Vector3,
		p_color: Color) -> void:
	var mesh := Box3DGeometry.make_array_mesh(p_geometry)
	var body := Box3DBody.new()
	body.name = p_name
	body.body_type = Box3DBody.DYNAMIC
	body.shape_type = Box3DBody.HULL
	body.collision_mesh = mesh
	body.auto_visual = false
	body.position = p_at
	var visual := MeshInstance3D.new()
	visual.name = "Visual"
	visual.mesh = mesh
	visual.material_override = _material(p_color)
	body.add_child(visual)
	p_world.add_child(body)


func _material(p_color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = p_color
	m.roughness = 0.5
	return m
