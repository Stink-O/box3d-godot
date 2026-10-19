extends Node3D

## Body Cast -- a port of upstream's "Bodies / Cast" sample
## (samples/sample_bodies.cpp:896-1082). Four queries are run every step
## against ONE body, posed somewhere it is not: the per-body query API,
## which skips the world's broad phase entirely and is how a game asks
## "would this ray, sweep or capsule touch THAT body if it were there".
##
## The body is upstream's: a kinematic cylinder hull (b3CreateCylinder(2,
## 0.5, 0, 16), so it stands on its origin from y = 0 to y = 2) created at
## (5, 5, 0) and slowly turning at (0.1, -0.1, 0.1) rad/s (:907-916). Every
## query poses it instead at upstream's m_transform, (-10, 2, 0) turned
## 0.75 pi about normalize(1, -2, 3) (:918-919), drawn there in blue, so the
## real body tumbling off to the side never takes part. Shift + left-drag
## moves that pose in the camera plane, 10 m out along the pick ray, exactly
## as upstream's MouseDown / MouseMove do (:936-966).
##
## The queries, with upstream's numbers (:979-1063):
##  * Box3DBody.cast_ray from (-9.75, 3, -4) along (0, 0, 8): a cyan ray, the
##    hit point and its normal in yellow, the start green and the end red.
##  * Box3DBody.cast_shape with a 0.2 m sphere from (-14.5, 2.5, 0.5) along
##    (8, 0, 0), can_encroach on: the sphere is drawn green where the sweep
##    stops, or white at the end of a miss, with the hit normal in yellow.
##  * Box3DBody.overlaps_shape with a capsule at (-10, 1, 0.5), end centres
##    (-0.5, 1, 0) and (0.5, 0, 0), radius 0.5: green while it overlaps,
##    gray otherwise.
##  * Box3DBody.collide_mover with a purple capsule at (-10, 2, -0.75), end
##    centres (-0.25, 0, 0) and (0.25, 1, 0), radius 0.3: every plane it
##    reports is drawn as upstream's DrawPlane does, an orange square with
##    its normal (samples/gfx/draw.c:119-135).
## Upstream's ground grid and axes (:968-977) are drawn as lines; there is
## no ground body in this sample, upstream's or ours.

const BODY_START := Vector3(5.0, 5.0, 0.0)
const BODY_SPIN := Vector3(0.1, -0.1, 0.1)
const CYLINDER_HEIGHT := 2.0
const CYLINDER_RADIUS := 0.5
const CYLINDER_SIDES := 16
const POSE_ORIGIN := Vector3(-10.0, 2.0, 0.0)
const DRAG_DEPTH := 10.0

const RAY_ORIGIN := Vector3(-9.75, 3.0, -4.0)
const RAY_TRANSLATION := Vector3(0.0, 0.0, 8.0)
const SPHERE_ORIGIN := Vector3(-14.5, 2.5, 0.5)
const SPHERE_RADIUS := 0.2
const SPHERE_TRANSLATION := Vector3(8.0, 0.0, 0.0)
const OVERLAP_ORIGIN := Vector3(-10.0, 1.0, 0.5)
const OVERLAP_A := Vector3(-0.5, 1.0, 0.0)
const OVERLAP_B := Vector3(0.5, 0.0, 0.0)
const OVERLAP_RADIUS := 0.5
const MOVER_ORIGIN := Vector3(-10.0, 2.0, -0.75)
const MOVER_A := Vector3(-0.25, 0.0, 0.0)
const MOVER_B := Vector3(0.25, 1.0, 0.0)
const MOVER_RADIUS := 0.3

## Upstream's palette (shared b3HexColor values).
const CYAN := Color(0.0, 1.0, 1.0)
const YELLOW := Color(1.0, 1.0, 0.0)
const GREEN := Color(0.0, 0.502, 0.0)
const RED := Color(1.0, 0.0, 0.0)
const WHITE := Color(1.0, 1.0, 1.0)
const GRAY := Color(0.502, 0.502, 0.502)
const PURPLE := Color(0.502, 0.0, 0.502)
const ORANGE := Color(1.0, 0.647, 0.0)
const BLUE := Color(0.0, 0.0, 1.0)

## m_camera->SetView(120, 30, 20, {0, 1.5, 0}) (:903): eye = pivot + radius *
## (sin yaw cos pitch, sin pitch, cos yaw cos pitch)
## (samples/host/camera.cpp:35-39,216-220).
var camera_home := Vector3(0.0, 1.5, 0.0) + 20.0 * Vector3(
		sin(deg_to_rad(120.0)) * cos(deg_to_rad(30.0)),
		sin(deg_to_rad(30.0)),
		cos(deg_to_rad(120.0)) * cos(deg_to_rad(30.0)))
var camera_look_at := Vector3(0.0, 1.5, 0.0)

## Upstream's m_transform: where every query poses the body.
var pose := Transform3D(Basis(Vector3(1.0, -2.0, 3.0).normalized(), 0.75 * PI), POSE_ORIGIN)
var last_ray: Dictionary = {}
var last_sphere: Dictionary = {}
var last_overlap := false
var last_planes: Array = []

var _tracking := false
var _drag_origin := Vector3.ZERO
var _base_translation := Vector3.ZERO
var _lines: ImmediateMesh
var _points: ImmediateMesh
var _pose_visual: Node3D
var _sphere_visual: MeshInstance3D
var _sphere_material := StandardMaterial3D.new()
var _overlap_material := StandardMaterial3D.new()
@onready var _body: Box3DBody = $Box3DWorld/Cylinder


func _ready() -> void:
	_lines = ImmediateMesh.new()
	add_child(_overlay("Lines", _lines, false))
	_points = ImmediateMesh.new()
	add_child(_overlay("Points", _points, true))

	# The pose every query uses, drawn in blue like upstream's DrawHull.
	_pose_visual = Node3D.new()
	_pose_visual.name = "QueryPose"
	_pose_visual.add_child(_cylinder_visual(_solid(BLUE)))
	add_child(_pose_visual)

	var sphere_mesh := SphereMesh.new()
	sphere_mesh.radius = SPHERE_RADIUS
	sphere_mesh.height = 2.0 * SPHERE_RADIUS
	_sphere_visual = MeshInstance3D.new()
	_sphere_visual.name = "CastSphere"
	_sphere_visual.mesh = sphere_mesh
	_sphere_visual.material_override = _sphere_material
	add_child(_sphere_visual)

	add_child(_capsule_visual("OverlapCapsule", OVERLAP_ORIGIN, OVERLAP_A, OVERLAP_B, OVERLAP_RADIUS, _overlap_material))
	add_child(_capsule_visual("MoverCapsule", MOVER_ORIGIN, MOVER_A, MOVER_B, MOVER_RADIUS, _solid(PURPLE)))

	_body.add_child(_cylinder_visual(_solid(Color(0.275, 0.51, 0.706))))  # steel blue: kinematic
	_run_queries()


## The kinematic body turns at upstream's angular velocity. Kinematic bodies
## follow their node, so the node is integrated the way Box3D integrates a
## world-frame angular velocity, and the solver is handed that motion.
func _physics_process(delta: float) -> void:
	var angle := BODY_SPIN.length() * delta
	_body.basis = (Basis(BODY_SPIN.normalized(), angle) * _body.basis).orthonormalized()
	_run_queries()


## Upstream's Step() (:979-1063): the four per-body queries, at `pose`.
func _run_queries() -> void:
	_pose_visual.transform = pose
	last_ray = _body.cast_ray(RAY_ORIGIN, RAY_ORIGIN + RAY_TRANSLATION, pose)
	last_sphere = _body.cast_shape(PackedVector3Array([SPHERE_ORIGIN]), SPHERE_RADIUS,
			SPHERE_TRANSLATION, pose, 1.0, true)
	last_overlap = _body.overlaps_shape(
			PackedVector3Array([OVERLAP_ORIGIN + OVERLAP_A, OVERLAP_ORIGIN + OVERLAP_B]), OVERLAP_RADIUS, pose)
	last_planes = _body.collide_mover(MOVER_ORIGIN + MOVER_A, MOVER_ORIGIN + MOVER_B, MOVER_RADIUS, pose)
	_draw()


func _draw() -> void:
	_lines.clear_surfaces()
	_points.clear_surfaces()
	_lines.surface_begin(Mesh.PRIMITIVE_LINES)
	_points.surface_begin(Mesh.PRIMITIVE_POINTS)

	# DrawGroundGrid(10) and DrawAxes at (0, 0.1, 0), size 4 (:972-974).
	var grid := Color(0.3, 0.3, 0.3, 0.3)
	for i in range(11):
		var o := -10.0 + 2.0 * i
		_line(Vector3(-10.0, 0.0, o), Vector3(10.0, 0.0, o), grid)
		_line(Vector3(o, 0.0, -10.0), Vector3(o, 0.0, 10.0), grid)
	var axes := Vector3(0.0, 0.1, 0.0)
	_line(axes, axes + Vector3(4, 0, 0), RED)
	_line(axes, axes + Vector3(0, 4, 0), Color(0, 1, 0))
	_line(axes, axes + Vector3(0, 0, 4), BLUE)

	# Ray.
	_line(RAY_ORIGIN, RAY_ORIGIN + RAY_TRANSLATION, CYAN)
	if last_ray.get("hit", false):
		var p: Vector3 = last_ray["position"]
		_line(p, p + 0.2 * last_ray["normal"], YELLOW)
		_point(p, YELLOW)
	_point(RAY_ORIGIN, GREEN)
	_point(RAY_ORIGIN + RAY_TRANSLATION, RED)

	# Sphere cast.
	if last_sphere.get("hit", false):
		_sphere_visual.position = SPHERE_ORIGIN + float(last_sphere["fraction"]) * SPHERE_TRANSLATION
		_sphere_material.albedo_color = GREEN
		var p: Vector3 = last_sphere["position"]
		_line(p, p + 0.2 * last_sphere["normal"], YELLOW)
	else:
		_sphere_visual.position = SPHERE_ORIGIN + SPHERE_TRANSLATION
		_sphere_material.albedo_color = WHITE
	_line(SPHERE_ORIGIN, SPHERE_ORIGIN + SPHERE_TRANSLATION, WHITE)
	_point(SPHERE_ORIGIN, GREEN)
	_point(SPHERE_ORIGIN + SPHERE_TRANSLATION, RED)

	# Capsule overlap.
	_overlap_material.albedo_color = GREEN if last_overlap else GRAY

	# Mover planes, as DrawPlane draws them (samples/gfx/draw.c:119-135).
	for plane: Dictionary in last_planes:
		var n: Vector3 = plane["normal"]
		var c: Vector3 = plane["position"]
		var perp1 := _perp(n)
		var perp2 := perp1.cross(n)
		var p1 := c + perp1 + perp2
		var p2 := c + perp2 - perp1
		var p3 := c - perp1 - perp2
		var p4 := c + perp1 - perp2
		_line(p1, p2, ORANGE)
		_line(p2, p3, ORANGE)
		_line(p3, p4, ORANGE)
		_line(p4, p1, ORANGE)
		_line(c, c + 0.5 * n, ORANGE)
		_point(c, ORANGE)

	_lines.surface_end()
	_points.surface_end()


## Upstream's MouseDown / MouseUp / MouseMove (:936-966): shift + left-drag
## carries the query pose along a plane 10 m out along the pick ray.
## Unhandled, so the shell's buttons get their clicks first; the sample sits
## after the camera in the tree, so it sees the press before the camera's grab
## does and consumes it.
func _unhandled_input(event: InputEvent) -> void:
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed and event.shift_pressed:
			_drag_origin = _pick(camera, event.position)
			_base_translation = pose.origin
			_tracking = true
			get_viewport().set_input_as_handled()
		elif not event.pressed and _tracking:
			_tracking = false
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and _tracking:
		pose.origin = _base_translation + _pick(camera, event.position) - _drag_origin
		get_viewport().set_input_as_handled()


func _pick(camera: Camera3D, at: Vector2) -> Vector3:
	return camera.project_ray_origin(at) + DRAG_DEPTH * camera.project_ray_normal(at)


## b3Perp (include/box3d/math_functions.h:306-322).
static func _perp(a: Vector3) -> Vector3:
	if a.x < -0.5 or 0.5 < a.x:
		return Vector3(a.y, -a.x, 0.0).normalized()
	return Vector3(0.0, a.z, -a.y).normalized()


func _line(a: Vector3, b: Vector3, color: Color) -> void:
	_lines.surface_set_color(color)
	_lines.surface_add_vertex(a)
	_lines.surface_set_color(color)
	_lines.surface_add_vertex(b)


func _point(p: Vector3, color: Color) -> void:
	_points.surface_set_color(color)
	_points.surface_add_vertex(p)


func _overlay(overlay_name: String, mesh: ImmediateMesh, points: bool) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = overlay_name
	mi.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	if points:
		mat.use_point_size = true
		mat.point_size = 10.0
	mi.material_override = mat
	return mi


func _solid(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.5
	return mat


## The cylinder hull's look: b3CreateCylinder builds it base-up from yOffset
## 0, so the mesh sits from y = 0 to y = 2 on its origin.
func _cylinder_visual(material: Material) -> MeshInstance3D:
	var mesh := CylinderMesh.new()
	mesh.top_radius = CYLINDER_RADIUS
	mesh.bottom_radius = CYLINDER_RADIUS
	mesh.height = CYLINDER_HEIGHT
	mesh.radial_segments = CYLINDER_SIDES
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = Vector3(0.0, 0.5 * CYLINDER_HEIGHT, 0.0)
	mi.material_override = material
	return mi


## A CapsuleMesh is Y-aligned and centred, so it is turned onto the segment
## between the two end centres (given relative to `origin`).
func _capsule_visual(node_name: String, origin: Vector3, a: Vector3, b: Vector3, radius: float,
		material: Material) -> MeshInstance3D:
	var axis := b - a
	var mesh := CapsuleMesh.new()
	mesh.radius = radius
	mesh.height = axis.length() + 2.0 * radius
	var mi := MeshInstance3D.new()
	mi.name = node_name
	mi.mesh = mesh
	mi.material_override = material
	var y := axis.normalized()
	var x := y.cross(Vector3.FORWARD).normalized()
	if x.length_squared() < 0.5:
		x = y.cross(Vector3.RIGHT).normalized()
	mi.transform = Transform3D(Basis(x, y, x.cross(y)), origin + 0.5 * (a + b))
	return mi


## Godot Physics and Jolt have no per-body cast, overlap or mover queries.
func rig_notes() -> Array:
	return ["This sample is Box3D's per-body query API (cast_ray, cast_shape, "
			+ "overlaps_shape, collide_mover against one posed body); Godot Physics "
			+ "and Jolt have no equivalent, so only the turning cylinder is rebuilt."]
