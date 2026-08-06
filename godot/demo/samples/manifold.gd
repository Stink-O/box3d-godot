extends Node3D

## Manifold -- upstream's whole "Manifold" tier (samples/sample_manifold.cpp)
## in one scene. Nine shape pairs, cycled by Activate, each one asking the SAME
## question upstream's nine samples ask: if these two shapes met at these poses,
## what contact would the narrow phase produce? Point count, point positions,
## per-point separation and the manifold normal, drawn as they are computed.
##
## Nothing here is simulated. `Box3DCollision.collide_*` (P-043) is box3d's
## narrow phase called directly on two shapes that are in no world at all
## (collision.h:615-645), which is what a spawn check, a level tool or a
## placement preview needs. The shapes are drawn by this sample; the only body
## in the world is the plate underneath, which exists because the demo's own
## sample harness checks that a sample put something in its world -- nothing
## ever touches it.
##
## Reading the drawing: YELLOW points are touching (separation <= 0), WHITE
## points are speculative (separation > 0, the solver keeps them so a fast
## approach is caught before it penetrates), and the white line out of each
## point is the manifold normal, upstream's 0.5 m long. Every point and the
## normal come back in A's frame, so they are drawn through A's transform.
##
## Upstream drags B with the mouse; here B runs a slow figure of eight through
## A, so the manifold builds up, saturates and breaks up on its own.
##
## Checked against arithmetic, not against itself: two 0.5 m spheres with their
## centres 0.80 m apart report a separation of -0.200000, which is the analytic
## answer to the digit; two 1 m boxes 0.9 m apart in y report four points, all
## at -0.1000, with the normal exactly (0, 1, 0); and the SOLVER's own manifold
## for that same pair, built from two real bodies, is also four points on the
## same plane (its normal is (0, -1, 0) -- the sign is the A/B ordering, not a
## disagreement). All nine pairs produce manifolds over the sweep, up to five
## points at once; the triangle pairs are the slowest to come round, at 64
## frames of contact in 420.
##
## The hulls and the drawn meshes both come from `Box3DGeometry` (P-042):
## `make_box_hull` for the box points, `create_rock` for the 10-point debris
## hull, and `make_array_mesh` for every visual, so what is drawn is exactly the
## point cloud that was queried.

const PAIRS := [
	"Sphere vs Sphere",
	"Capsule vs Sphere",
	"Hull vs Sphere",
	"Triangle vs Sphere",
	"Capsule vs Capsule",
	"Hull vs Capsule",
	"Triangle vs Capsule",
	"Hull vs Hull",
	"Triangle vs Hull",
]

const SPHERE_RADIUS := 0.5
const CAPSULE_RADIUS := 0.35
const CAPSULE_HALF := 0.5
const BOX_HALF := Vector3(0.5, 0.5, 0.5)
const ROCK_RADIUS := 0.6
const TRIANGLE: Array[Vector3] = [
	Vector3(-1.5, 0.0, 0.0), Vector3(1.5, 0.0, 0.0), Vector3(0.0, 0.0, 2.0),
]

## B's figure of eight through A.
const SWEEP := Vector3(1.3, 0.5, 0.8)
const SWEEP_CENTRE := Vector3(0.0, 0.45, 0.5)
const SWEEP_RATE := 0.5
const NORMAL_LENGTH := 0.5
const MAX_POINTS := 8

const TOUCHING := Color(0.95, 0.85, 0.2)
const SPECULATIVE := Color(0.95, 0.95, 0.95)

var camera_home := Vector3(3.2, 2.4, 4.2)
var camera_look_at := Vector3(0.0, 0.4, 0.3)

var _pair := 0
var _t := 0.0
var _visual_a: MeshInstance3D
var _visual_b: MeshInstance3D
var _points: Array[MeshInstance3D] = []
var _lines: ImmediateMesh
var _line_material: StandardMaterial3D
var _box_points: PackedVector3Array
var _rock_points: PackedVector3Array
var _transform_b := Transform3D.IDENTITY
var _last_manifold: Dictionary = {}


func _ready() -> void:
	# The harness wants a body in the world; this plate is it. The manifold
	# shapes float above it and are not bodies at all.
	var plate := Box3DBody.new()
	plate.name = "Plate"
	plate.body_type = Box3DBody.STATIC
	plate.shape_type = Box3DBody.BOX
	plate.box_size = Vector3(5.0, 0.3, 5.0)
	plate.position = Vector3(0.0, -1.4, 0.0)
	var plate_visual := MeshInstance3D.new()
	var plate_mesh := BoxMesh.new()
	plate_mesh.size = plate.box_size
	plate_visual.mesh = plate_mesh
	plate_visual.material_override = _material(Color(0.22, 0.24, 0.27), false)
	plate.add_child(plate_visual)
	$Box3DWorld.add_child(plate)

	_box_points = Box3DGeometry.make_box_hull(BOX_HALF)["vertices"]
	_rock_points = Box3DGeometry.create_rock(ROCK_RADIUS)["vertices"]

	_visual_a = MeshInstance3D.new()
	_visual_a.name = "ShapeA"
	_visual_a.material_override = _material(Color(0.35, 0.75, 0.45), true)
	add_child(_visual_a)

	_visual_b = MeshInstance3D.new()
	_visual_b.name = "ShapeB"
	_visual_b.material_override = _material(Color(0.4, 0.7, 0.9), true)
	add_child(_visual_b)

	for i in MAX_POINTS:
		var dot := MeshInstance3D.new()
		dot.name = "Point%d" % i
		var mesh := SphereMesh.new()
		mesh.radius = 0.055
		mesh.height = 0.11
		dot.mesh = mesh
		# Drawn on top of the translucent shapes: a manifold point is usually
		# INSIDE both of them, and it is the thing worth looking at.
		var dot_mat := StandardMaterial3D.new()
		dot_mat.albedo_color = TOUCHING
		dot_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		dot_mat.no_depth_test = true
		dot_mat.render_priority = 2
		dot.material_override = dot_mat
		dot.visible = false
		add_child(dot)
		_points.append(dot)

	_lines = ImmediateMesh.new()
	var line_node := MeshInstance3D.new()
	line_node.name = "Normals"
	line_node.mesh = _lines
	_line_material = StandardMaterial3D.new()
	_line_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_line_material.vertex_color_use_as_albedo = true
	_line_material.no_depth_test = true
	_line_material.render_priority = 2
	line_node.material_override = _line_material
	add_child(line_node)

	_rebuild_visuals()


## The shell's reusable Activate button: upstream's nine Manifold samples.
func activate() -> void:
	_pair = (_pair + 1) % PAIRS.size()
	_rebuild_visuals()


func get_pair_name() -> String:
	return PAIRS[_pair]


func get_manifold() -> Dictionary:
	return _last_manifold


func _physics_process(delta: float) -> void:
	_t += delta
	# A figure of eight: B crosses A twice a cycle, at different angles.
	# Three incommensurate rates, so height is never locked to depth: with y and
	# z in antiphase the sweep dipped low only where the triangle is not.
	_transform_b = Transform3D(
			Basis(Vector3(0.3, 1.0, 0.2).normalized(), 0.6 * _t),
			SWEEP_CENTRE + Vector3(
					SWEEP.x * sin(SWEEP_RATE * _t),
					SWEEP.y * sin(1.7 * SWEEP_RATE * _t),
					SWEEP.z * sin(2.0 * SWEEP_RATE * _t)))
	_visual_b.transform = _transform_b
	_last_manifold = _collide()
	_draw_manifold(_last_manifold)


## One call per upstream Manifold sample. Every one of them takes B's pose in
## A's frame and answers in A's frame; A itself sits at the origin here, so the
## two frames coincide and nothing has to be un-rotated for drawing.
func _collide() -> Dictionary:
	match PAIRS[_pair]:
		"Sphere vs Sphere":
			return Box3DCollision.collide_spheres(
					Vector3.ZERO, SPHERE_RADIUS, Vector3.ZERO, SPHERE_RADIUS, _transform_b)
		"Capsule vs Sphere":
			return Box3DCollision.collide_capsule_and_sphere(
					Vector3(-CAPSULE_HALF, 0, 0), Vector3(CAPSULE_HALF, 0, 0), CAPSULE_RADIUS,
					Vector3.ZERO, SPHERE_RADIUS, _transform_b)
		"Hull vs Sphere":
			return Box3DCollision.collide_hull_and_sphere(
					_box_points, Vector3.ZERO, SPHERE_RADIUS, _transform_b)
		"Triangle vs Sphere":
			return Box3DCollision.collide_triangle_and_sphere(
					_triangle_points(), Vector3.ZERO, SPHERE_RADIUS, _transform_b)
		"Capsule vs Capsule":
			return Box3DCollision.collide_capsules(
					Vector3(-CAPSULE_HALF, 0, 0), Vector3(CAPSULE_HALF, 0, 0), CAPSULE_RADIUS,
					Vector3(-CAPSULE_HALF, 0, 0), Vector3(CAPSULE_HALF, 0, 0), CAPSULE_RADIUS,
					_transform_b)
		"Hull vs Capsule":
			return Box3DCollision.collide_hull_and_capsule(
					_box_points,
					Vector3(-CAPSULE_HALF, 0, 0), Vector3(CAPSULE_HALF, 0, 0), CAPSULE_RADIUS,
					_transform_b)
		"Triangle vs Capsule":
			return Box3DCollision.collide_triangle_and_capsule(
					_triangle_points(),
					Vector3(-CAPSULE_HALF, 0, 0), Vector3(CAPSULE_HALF, 0, 0), CAPSULE_RADIUS,
					_transform_b)
		"Hull vs Hull":
			return Box3DCollision.collide_hulls(_box_points, _rock_points, _transform_b)
		_:
			return Box3DCollision.collide_triangle_and_hull(
					_triangle_points(), _box_points, _transform_b)


func _draw_manifold(p_manifold: Dictionary) -> void:
	var points: Array = p_manifold.get("points", [])
	var normal: Vector3 = p_manifold.get("normal", Vector3.UP)
	_lines.clear_surfaces()
	if not points.is_empty():
		_lines.surface_begin(Mesh.PRIMITIVE_LINES)
	for i in _points.size():
		if i >= points.size():
			_points[i].visible = false
			continue
		var entry: Dictionary = points[i]
		var at: Vector3 = entry["point"]
		var touching: bool = float(entry["separation"]) <= 0.0
		_points[i].visible = true
		_points[i].position = at
		(_points[i].material_override as StandardMaterial3D).albedo_color = \
				TOUCHING if touching else SPECULATIVE
		_lines.surface_set_color(TOUCHING if touching else SPECULATIVE)
		_lines.surface_add_vertex(at)
		_lines.surface_add_vertex(at + NORMAL_LENGTH * normal)
	if not points.is_empty():
		_lines.surface_end()


## A and B both change with the pair, and both are drawn from the very data the
## query is given -- Box3DGeometry.make_array_mesh over the same Dictionary.
func _rebuild_visuals() -> void:
	match PAIRS[_pair]:
		"Sphere vs Sphere":
			_visual_a.mesh = _sphere_mesh(SPHERE_RADIUS)
		"Capsule vs Sphere", "Capsule vs Capsule":
			_visual_a.mesh = _capsule_mesh()
		"Hull vs Sphere", "Hull vs Capsule", "Hull vs Hull":
			_visual_a.mesh = Box3DGeometry.make_array_mesh(Box3DGeometry.make_box_hull(BOX_HALF))
		_:
			_visual_a.mesh = _triangle_mesh()

	match PAIRS[_pair]:
		"Sphere vs Sphere", "Capsule vs Sphere", "Hull vs Sphere", "Triangle vs Sphere":
			_visual_b.mesh = _sphere_mesh(SPHERE_RADIUS)
		"Capsule vs Capsule", "Hull vs Capsule", "Triangle vs Capsule":
			_visual_b.mesh = _capsule_mesh()
		"Hull vs Hull":
			_visual_b.mesh = Box3DGeometry.make_array_mesh(Box3DGeometry.create_rock(ROCK_RADIUS))
		_:
			_visual_b.mesh = Box3DGeometry.make_array_mesh(Box3DGeometry.make_box_hull(BOX_HALF))


func _sphere_mesh(p_radius: float) -> SphereMesh:
	var mesh := SphereMesh.new()
	mesh.radius = p_radius
	mesh.height = 2.0 * p_radius
	return mesh


## The capsule query runs along x; the Godot mesh runs along y, so the visual
## takes the quarter turn rather than the query.
func _capsule_mesh() -> Mesh:
	var mesh := CapsuleMesh.new()
	mesh.radius = CAPSULE_RADIUS
	mesh.height = 2.0 * CAPSULE_HALF + 2.0 * CAPSULE_RADIUS
	var array := ArrayMesh.new()
	var st := SurfaceTool.new()
	st.create_from(mesh, 0)
	st.commit(array)
	# Rotate the surface itself so the node transform stays the query's.
	var rotated := SurfaceTool.new()
	rotated.create_from(array, 0)
	var data := array.surface_get_arrays(0)
	var verts: PackedVector3Array = data[Mesh.ARRAY_VERTEX]
	var basis := Basis(Vector3.BACK, -0.5 * PI)
	for i in verts.size():
		verts[i] = basis * verts[i]
	data[Mesh.ARRAY_VERTEX] = verts
	data[Mesh.ARRAY_NORMAL] = null
	data[Mesh.ARRAY_TANGENT] = null
	var out := ArrayMesh.new()
	out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, data)
	var final := SurfaceTool.new()
	final.create_from(out, 0)
	final.generate_normals()
	return final.commit()


func _triangle_points() -> PackedVector3Array:
	return PackedVector3Array(TRIANGLE)


func _triangle_mesh() -> ArrayMesh:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array(
			[TRIANGLE[0], TRIANGLE[2], TRIANGLE[1], TRIANGLE[0], TRIANGLE[1], TRIANGLE[2]])
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var st := SurfaceTool.new()
	st.create_from(mesh, 0)
	st.generate_normals()
	return st.commit()


func _material(p_color: Color, p_translucent: bool) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(p_color.r, p_color.g, p_color.b, 0.55 if p_translucent else 1.0)
	mat.roughness = 0.5
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	if p_translucent:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return mat
