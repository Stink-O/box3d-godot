extends Node3D

## Capsule Plane -- a port of upstream's "Character / CapsulePlane" sample
## (samples/sample_character.cpp:14-146). The two halves of the geometric
## character mover, run by hand: Box3DWorld.collide_mover gathers the
## collision planes a capsule meets where it stands, and
## Box3DCollision.solve_planes turns them into the translation that pushes
## it back out.
##
## Upstream's setup: a static 1 m box hull at (0, 1, 1) (:31-37) and a green
## capsule, end centres (0, +-0.5, 0) and radius 0.25, starting at
## (0, 1, 0.4), already 0.15 m into the box's near face (:29-30). Every step
## the capsule is collided with the world, keeping at most three planes as
## upstream's m_planeCapacity does (:79-88, :140), and each plane is drawn
## as upstream draws it: a yellow point (offset - radius) along the normal
## from the capsule's centre and a 0.1 m tick along the normal (:120-127).
## Activate is upstream's Solve button (:70-76): one b3SolvePlanes from a
## zero target delta, and the capsule is moved by the result (:48-52).
## Left-drag moves the capsule in the camera plane, 10 m out along the pick
## ray, exactly as upstream's MouseDown / MouseMove do (:90-113); drag it
## into the box (or let it sit where it starts) and press Activate to watch
## it come back out. Upstream's ground grid and axes (:54-61) are lines.

const CAPSULE_A := Vector3(0.0, -0.5, 0.0)
const CAPSULE_B := Vector3(0.0, 0.5, 0.0)
const CAPSULE_RADIUS := 0.25
const START := Vector3(0.0, 1.0, 0.4)
## m_planeCapacity (:140).
const PLANE_CAPACITY := 3
const DRAG_DEPTH := 10.0

## m_camera->SetView(120, 30, 20, {0, 1.5, 0}) (:27): eye = pivot + radius *
## (sin yaw cos pitch, sin pitch, cos yaw cos pitch)
## (samples/host/camera.cpp:35-39,216-220).
var camera_home := Vector3(0.0, 1.5, 0.0) + 20.0 * Vector3(
		sin(deg_to_rad(120.0)) * cos(deg_to_rad(30.0)),
		sin(deg_to_rad(30.0)),
		cos(deg_to_rad(120.0)) * cos(deg_to_rad(30.0)))
var camera_look_at := Vector3(0.0, 1.5, 0.0)

## Upstream's m_transform.p: where the capsule's centre is.
var capsule_position := START
var planes: Array = []

var _tracking := false
var _drag_origin := Vector3.ZERO
var _base_translation := Vector3.ZERO
var _lines: ImmediateMesh
var _points: ImmediateMesh
var _point_count := 0
var _capsule: MeshInstance3D
@onready var _world: Box3DWorld = $Box3DWorld


func _ready() -> void:
	_lines = ImmediateMesh.new()
	add_child(_overlay("Lines", _lines, false))
	_points = ImmediateMesh.new()
	add_child(_overlay("Points", _points, true))
	var mesh := CapsuleMesh.new()
	mesh.radius = CAPSULE_RADIUS
	mesh.height = (CAPSULE_B - CAPSULE_A).length() + 2.0 * CAPSULE_RADIUS
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.0, 0.502, 0.0)  # b3_colorGreen
	_capsule = MeshInstance3D.new()
	_capsule.name = "Capsule"
	_capsule.mesh = mesh
	_capsule.material_override = material
	add_child(_capsule)


## Upstream's Solve button (:48-52, :70-76).
func activate() -> void:
	solve()


func solve() -> void:
	var result: Dictionary = Box3DCollision.solve_planes(Vector3.ZERO, planes)
	capsule_position += result["delta"]
	_collide()


func _physics_process(_delta: float) -> void:
	_collide()


## Upstream's Step (:115-128).
func _collide() -> void:
	var found: Array = _world.collide_mover(capsule_position + CAPSULE_A, capsule_position + CAPSULE_B,
			CAPSULE_RADIUS)
	planes = found.slice(0, PLANE_CAPACITY)
	_capsule.position = capsule_position
	_draw()


func _draw() -> void:
	_lines.clear_surfaces()
	_points.clear_surfaces()
	_lines.surface_begin(Mesh.PRIMITIVE_LINES)
	_points.surface_begin(Mesh.PRIMITIVE_POINTS)
	_point_count = 0

	# DrawGroundGrid(10) and the three 2 m axis lines (:54-61).
	var grid := Color(0.3, 0.3, 0.3, 0.3)
	for i in range(11):
		var o := -10.0 + 2.0 * i
		_line(Vector3(-10.0, 0.0, o), Vector3(10.0, 0.0, o), grid)
		_line(Vector3(o, 0.0, -10.0), Vector3(o, 0.0, 10.0), grid)
	_line(Vector3.ZERO, Vector3(2, 0, 0), Color(1, 0, 0))
	_line(Vector3.ZERO, Vector3(0, 2, 0), Color(0, 0.502, 0))
	_line(Vector3.ZERO, Vector3(0, 0, 2), Color(0, 0, 1))

	var yellow := Color(1.0, 1.0, 0.0)
	for plane: Dictionary in planes:
		var n: Vector3 = plane["normal"]
		var p1: Vector3 = capsule_position + (float(plane["distance"]) - CAPSULE_RADIUS) * n
		_point(p1, yellow)
		_line(p1, p1 + 0.1 * n, yellow)

	_lines.surface_end()
	# A points surface with no vertices is an error, and a frame with no
	# planes has none.
	if _point_count > 0:
		_points.surface_end()
	else:
		_points.clear_surfaces()


## Upstream's MouseDown / MouseUp / MouseMove (:90-113): a left drag without
## Alt carries the capsule along a plane 10 m out along the pick ray.
## Unhandled, so the shell's buttons get their clicks first; the sample sits
## after the camera in the tree, so it sees the press before the camera's grab
## does and consumes it.
func _unhandled_input(event: InputEvent) -> void:
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed and not event.alt_pressed:
			_drag_origin = _pick(camera, event.position)
			_base_translation = capsule_position
			_tracking = true
			get_viewport().set_input_as_handled()
		elif not event.pressed and _tracking:
			_tracking = false
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and _tracking:
		capsule_position = _base_translation + _pick(camera, event.position) - _drag_origin
		get_viewport().set_input_as_handled()


func _pick(camera: Camera3D, at: Vector2) -> Vector3:
	return camera.project_ray_origin(at) + DRAG_DEPTH * camera.project_ray_normal(at)


func _line(a: Vector3, b: Vector3, color: Color) -> void:
	_lines.surface_set_color(color)
	_lines.surface_add_vertex(a)
	_lines.surface_set_color(color)
	_lines.surface_add_vertex(b)


func _point(p: Vector3, color: Color) -> void:
	_points.surface_set_color(color)
	_points.surface_add_vertex(p)
	_point_count += 1


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
		mat.point_size = 5.0
	mi.material_override = mat
	return mi


func rig_notes() -> Array:
	return ["This sample runs Box3D's character mover queries by hand "
			+ "(collide_mover, solve_planes); Godot Physics and Jolt have no plane solver, "
			+ "so only the static box is rebuilt."]
