extends Node3D

## Mover Overlap -- a port of upstream's "Character / MoverOverlap" sample
## (samples/sample_character.cpp:148-313). It exercises the deep-overlap path
## of the mover's plane collide against each primitive: drag the yellow mover
## capsule into the static sphere, capsule and box, and watch the planes
## Box3DWorld.collide_mover returns (lime arrows from each contact point along
## its normal) and where Box3DCollision.solve_planes pushes the capsule out to
## (cyan). A degenerate, zero-length normal would be drawn red and counted;
## upstream's point is that the count stays 0 even with the mover buried.
##
## Upstream's setup (:163-205): a static sphere of radius 0.6 at (-3, 1, 0),
## a static capsule along Z (end centres (0, 0, +-0.7), radius 0.4) at
## (0, 1, 0) and a static 1.2 m box hull at (3, 1, 0); the mover is end
## centres (0, +-0.5, 0), radius 0.35, starting at (0, 3.5, 0). Every step
## it collects up to 32 planes (:292), draws them, solves them from a zero
## target delta as rigid planes (FLT_MAX push limit, :262) and draws the
## pushed pose (:265-267). The three DrawTextLine readouts (:269-271) are the
## floating label. Left-drag moves the mover in the camera plane, 10 m out
## along the pick ray, as upstream's MouseDown / MouseMove do (:220-243).

const MOVER_A := Vector3(0.0, -0.5, 0.0)
const MOVER_B := Vector3(0.0, 0.5, 0.0)
const MOVER_RADIUS := 0.35
const START := Vector3(0.0, 3.5, 0.0)
## m_planeCapacity (:292).
const PLANE_CAPACITY := 32
const DRAG_DEPTH := 10.0

const YELLOW := Color(1.0, 1.0, 0.0)
const CYAN := Color(0.0, 1.0, 1.0)
const LIME := Color(0.196, 0.804, 0.196)  # b3_colorLimeGreen
const RED := Color(1.0, 0.0, 0.0)

## m_camera->SetView(120, 25, 10, {0, 1, 0}) (:160): eye = pivot + radius *
## (sin yaw cos pitch, sin pitch, cos yaw cos pitch)
## (samples/host/camera.cpp:35-39,216-220).
var camera_home := Vector3(0.0, 1.0, 0.0) + 10.0 * Vector3(
		sin(deg_to_rad(120.0)) * cos(deg_to_rad(25.0)),
		sin(deg_to_rad(25.0)),
		cos(deg_to_rad(120.0)) * cos(deg_to_rad(25.0)))
var camera_look_at := Vector3(0.0, 1.0, 0.0)

## Upstream's m_transform.p: the queried mover pose.
var mover_position := START
var planes: Array = []
var pushed_position := START
var zero_normal_count := 0

var _tracking := false
var _drag_origin := Vector3.ZERO
var _base_translation := Vector3.ZERO
var _lines: ImmediateMesh
var _points: ImmediateMesh
var _point_count := 0
var _queried: MeshInstance3D
var _pushed: MeshInstance3D
@onready var _world: Box3DWorld = $Box3DWorld
@onready var _label: Label3D = $Status


func _ready() -> void:
	_lines = ImmediateMesh.new()
	add_child(_overlay("Lines", _lines, false))
	_points = ImmediateMesh.new()
	add_child(_overlay("Points", _points, true))
	_queried = _capsule_visual("QueriedMover", YELLOW)
	_pushed = _capsule_visual("PushedMover", CYAN)
	_query()


func _physics_process(_delta: float) -> void:
	_query()


## Upstream's Step (:245-272).
func _query() -> void:
	var found: Array = _world.collide_mover(mover_position + MOVER_A, mover_position + MOVER_B, MOVER_RADIUS)
	planes = found.slice(0, PLANE_CAPACITY)
	zero_normal_count = 0
	for plane: Dictionary in planes:
		if not (plane["normal"] as Vector3).is_normalized():
			zero_normal_count += 1
	var solved: Dictionary = Box3DCollision.solve_planes(Vector3.ZERO, planes)
	pushed_position = mover_position + solved["delta"]
	_queried.position = mover_position
	_pushed.position = pushed_position
	_label.text = "drag the capsule with the left mouse to push it into the shapes\n" \
			+ "yellow = queried pose, cyan = solved push-out, lime = valid plane normals\n" \
			+ "planes: %d   degenerate normals: %d" % [planes.size(), zero_normal_count]
	_draw()


func _draw() -> void:
	_lines.clear_surfaces()
	_points.clear_surfaces()
	_lines.surface_begin(Mesh.PRIMITIVE_LINES)
	_points.surface_begin(Mesh.PRIMITIVE_POINTS)
	_point_count = 0
	# DrawGroundGrid(12) (:207-211).
	var grid := Color(0.3, 0.3, 0.3, 0.3)
	for i in range(13):
		var o := -12.0 + 2.0 * i
		_line(Vector3(-12.0, 0.0, o), Vector3(12.0, 0.0, o), grid)
		_line(Vector3(o, 0.0, -12.0), Vector3(o, 0.0, 12.0), grid)
	# One arrow per plane from its contact point along the normal (:253-263).
	for plane: Dictionary in planes:
		var n: Vector3 = plane["normal"]
		var color := LIME if n.is_normalized() else RED
		var p: Vector3 = plane["position"]
		var tip := p + 0.5 * n
		_point(p, color)
		_line(p, tip, color)
		var side := n.cross(Vector3.UP if absf(n.y) < 0.9 else Vector3.RIGHT).normalized()
		_line(tip, tip - 0.12 * n + 0.06 * side, color)
		_line(tip, tip - 0.12 * n - 0.06 * side, color)
	_lines.surface_end()
	# A points surface with no vertices is an error, and a frame with no
	# planes has none.
	if _point_count > 0:
		_points.surface_end()
	else:
		_points.clear_surfaces()


## Upstream's MouseDown / MouseUp / MouseMove (:220-243). Unhandled, so the
## shell's buttons get their clicks first; the sample sits after the camera in
## the tree, so it sees the press before the camera's grab and consumes it.
func _unhandled_input(event: InputEvent) -> void:
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed and not event.alt_pressed:
			_drag_origin = _pick(camera, event.position)
			_base_translation = mover_position
			_tracking = true
			get_viewport().set_input_as_handled()
		elif not event.pressed and _tracking:
			_tracking = false
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and _tracking:
		mover_position = _base_translation + _pick(camera, event.position) - _drag_origin
		get_viewport().set_input_as_handled()


func _pick(camera: Camera3D, at: Vector2) -> Vector3:
	return camera.project_ray_origin(at) + DRAG_DEPTH * camera.project_ray_normal(at)


func _capsule_visual(node_name: String, color: Color) -> MeshInstance3D:
	var mesh := CapsuleMesh.new()
	mesh.radius = MOVER_RADIUS
	mesh.height = (MOVER_B - MOVER_A).length() + 2.0 * MOVER_RADIUS
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	var mi := MeshInstance3D.new()
	mi.name = node_name
	mi.mesh = mesh
	mi.material_override = material
	add_child(mi)
	return mi


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
	mat.no_depth_test = true
	if points:
		mat.use_point_size = true
		mat.point_size = 6.0
	mi.material_override = mat
	return mi


func rig_notes() -> Array:
	return ["This sample runs Box3D's character mover queries by hand "
			+ "(collide_mover, solve_planes); Godot Physics and Jolt have no plane solver, "
			+ "so only the three static shapes are rebuilt."]
