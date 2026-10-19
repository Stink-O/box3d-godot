extends Node3D

## Safety Factor -- a port of upstream's "Continuous / Safety Factor" sample
## (samples/sample_continuous.cpp:1024-1137). A 1 m box is dropped a short
## way onto the ground, and the readouts show what continuous collision does
## at a speed where tunnelling is no risk at all.
##
## Box3D only sweeps a body that moves farther in one step than its
## `safety_factor` times its smallest extent (src/solver.c:791-796). Below
## that it is solved discretely, which lets it sink a little into the ground
## on the step it lands. Lowering the factor engages the sweep at slower
## speeds, so the body is moved back to its time of impact and the overlap
## shrinks. Upstream draws the box orange on the steps it is "fast"; so does
## this port, from the same test the readout prints.
##
## Upstream's numbers are kept: a 0.5 m half-extent box hull (b3MakeBoxHull,
## density 1000 from b3DefaultShapeDef) dropped from Height above the ground
## (sample_continuous.cpp:1059) with bodyDef.safetyFactor = Safety (:1060),
## on AddGroundBox(20), a 40 x 2 x 40 hull with its top at y = 0
## (samples/sample.cpp:607-616), under gravity -10. Height (0..2, default
## 0.3) and Safety (0..1, default 0.1) are upstream's two sliders (:1110-1111)
## and are sidebar dials here; changing one drops a fresh box, like upstream,
## and Activate is upstream's Drop button (:1114).
##
## The three readouts are upstream's DrawTextLine lines (:1104-1106):
## actual movement is this step's |v| * dt, fast movement is the threshold
## Safety * extent, and overlap is the deepest negative contact separation
## seen since the drop, read from Box3DBody.get_contacts() as upstream reads
## b3Body_GetContactData (:1081-1094). The red line under the ground is
## upstream's overlap line (:1098-1099), drawn through the ground the way
## upstream dashes the hidden part.
##
## Upstream's tip is to pause and single-step; the shell has no pause, so the
## overlap readout holds the deepest value instead, which is what upstream's
## m_overlap accumulates anyway.

const EXTENT := 0.5
const DENSITY := 1000.0
const LINE_HALF_LENGTH := 3.0
const HEIGHT_RANGE := Vector2(0.0, 2.0)
const SAFETY_RANGE := Vector2(0.0, 1.0)
## Upstream's b3_colorOrange (b3HexColor 0xFFA500), its "fast body" colour.
const FAST_COLOR := Color(1.0, 0.647, 0.0)
const BOX_COLOR := Color(0.55, 0.6, 0.7)

## m_camera->SetView(0, 3, 8, {0, 1, 0}) (:1040): yaw 0, pitch 3 degrees,
## radius 8 about the pivot (samples/host/camera.cpp:35-39,216-220).
var camera_home := Vector3(0.0, 1.0 + 8.0 * sin(deg_to_rad(3.0)), 8.0 * cos(deg_to_rad(3.0)))
var camera_look_at := Vector3(0.0, 1.0, 0.0)

var _height := 0.3
var _safety := 0.1
var _overlap := 0.0
var _box: Box3DBody
var _box_material := StandardMaterial3D.new()
var _mesh := BoxMesh.new()
var _lines: ImmediateMesh
@onready var _world: Box3DWorld = $Box3DWorld
@onready var _label: Label3D = $Status


func _ready() -> void:
	# Run after the world's step (priority 0), so the readouts describe the
	# step just taken, as upstream's Step() reads after Sample::Step().
	process_physics_priority = 1
	_mesh.size = Vector3.ONE * 2.0 * EXTENT
	_box_material.albedo_color = BOX_COLOR
	_box_material.roughness = 0.5

	_lines = ImmediateMesh.new()
	var overlay := MeshInstance3D.new()
	overlay.name = "OverlapLine"
	overlay.mesh = _lines
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 0.0, 0.0)
	mat.no_depth_test = true
	overlay.material_override = mat
	add_child(overlay)

	_launch()


## Upstream's Drop button.
func activate() -> void:
	_launch()


## Upstream's Launch() (:1053-1070): destroy the old box, create a new one at
## the current height with the current safety factor, reset the overlap.
func _launch() -> void:
	if not is_inside_tree():
		return
	if _box != null:
		_box.free()
	_box = Box3DBody.new()
	_box.name = "Box"
	_box.box_size = Vector3.ONE * 2.0 * EXTENT
	_box.density = DENSITY
	_box.safety_factor = _safety
	_box.position = Vector3(0.0, _height + EXTENT, 0.0)
	var visual := MeshInstance3D.new()
	visual.mesh = _mesh
	visual.material_override = _box_material
	_box.add_child(visual)
	_world.add_child(_box)
	_overlap = 0.0
	_box_material.albedo_color = BOX_COLOR
	_refresh()


func _physics_process(delta: float) -> void:
	if _box == null:
		return
	# Contacts are computed at the beginning of the step, so the manifold
	# holds the initial separation (:1080).
	for contact: Dictionary in _box.get_contacts():
		for point: Dictionary in contact["points"]:
			_overlap = maxf(_overlap, -float(point["separation"]))
	var motion := delta * _box.get_linear_velocity().length()
	var fast := motion > _safety * EXTENT
	_box_material.albedo_color = FAST_COLOR if fast else BOX_COLOR
	_refresh(motion)


func _refresh(motion := 0.0) -> void:
	_label.text = "actual movement = %.3f m\nfast movement = %.3f m\noverlap = %.4f m" % [
		motion, _safety * EXTENT, _overlap]
	_lines.clear_surfaces()
	_lines.surface_begin(Mesh.PRIMITIVE_LINES)
	_lines.surface_add_vertex(Vector3(-LINE_HALF_LENGTH, -_overlap, 0.0))
	_lines.surface_add_vertex(Vector3(LINE_HALF_LENGTH, -_overlap, 0.0))
	_lines.surface_end()


# --- Sidebar dials: upstream's Height and Safety sliders -------------------

func sample_size_dials() -> Array:
	return [
		{
			"key": "height", "label": "Height", "value": _height,
			"min": HEIGHT_RANGE.x, "max": HEIGHT_RANGE.y, "step": 0.01,
			"tooltip": "Gap between the bottom of the box and the ground at the drop.",
		},
		{
			"key": "safety", "label": "Safety", "value": _safety,
			"min": SAFETY_RANGE.x, "max": SAFETY_RANGE.y, "step": 0.01,
			"tooltip": "The box's safety_factor: it is swept against the ground on any"
					+ " step it moves farther than this times its 0.5 m half extent.",
		},
	]


func sample_size_hint(key: String, value: float) -> String:
	var height := value if key == "height" else _height
	var safety := value if key == "safety" else _safety
	return "Drop from %.2f m; swept when a step moves more than %.3f m" % [height, safety * EXTENT]


func set_sample_size(key: String, value: float) -> void:
	if key == "height":
		_height = clampf(value, HEIGHT_RANGE.x, HEIGHT_RANGE.y)
	elif key == "safety":
		_safety = clampf(value, SAFETY_RANGE.x, SAFETY_RANGE.y)
	_launch()


## Godot Physics and Jolt rebuild the authored ground only: the box is made
## in code, and neither engine has a per-body CCD safety factor to show.
func rig_notes() -> Array:
	return ["Godot Physics and Jolt have no per-body continuous collision "
			+ "safety factor, so the drop this sample measures has no equivalent there."]
