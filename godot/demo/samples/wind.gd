extends Node3D

## Wind -- a port of upstream's "Shapes / Wind" sample
## (samples/sample_shapes.cpp). Ten thin plates are pinned end to end with
## spherical joints into a ribbon hanging off a fixed anchor, and a steady
## 6 m/s wind is applied to every plate each step. Nothing here is a force
## field: `Box3DBody.apply_wind(wind, drag, lift, max_speed)` is box3d's
## `b3Shape_ApplyWind`, which turns the SHAPE's own cross-section and its
## velocity relative to the air into drag (along the flow) and lift
## (perpendicular to it), so the ribbon streams out, rolls and flutters
## instead of just being pushed.
##
## Upstream's drag 1.0 / lift 0.75 / max speed 10 are kept verbatim, as is
## the wandering noise it adds to the wind direction: a random unit-ish
## vector eased in at 5% per step, which is what makes the flutter irregular.
## Wind only acts on sphere, capsule and hull shapes (src/shape.c:1863) --
## a Box3D "box" is a hull, so these plates qualify.
##
## Press the top-bar toggle to cut the wind and watch the ribbon fall limp.

## Upstream's `radius`: the plate scale everything is derived from.
const R := 0.1
## Height of the anchor, upstream's `verticalOffset`.
const ANCHOR_Y := 2.0
const COUNT := 10
## b3MakeBoxHull(1.25r, 0.75r, 0.125r) is a HALF-extent call: double it.
const PLATE_SIZE := Vector3(2.5 * R, 1.5 * R, 0.25 * R)
const DENSITY := 20.0
const GRAVITY_SCALE := 0.5

const WIND := Vector3(6.0, 0.0, 0.0)
const DRAG := 1.0
const LIFT := 0.75
const MAX_SPEED := 10.0
## Upstream's noise: lerp towards a fresh random vector in [-0.3, 0.3]^3.
const NOISE_RANGE := 0.3
const NOISE_LERP := 0.05

var camera_home := Vector3(0.0, 1.0, 5.0)
var camera_look_at := Vector3(0.0, 1.0, 0.0)

var _plates: Array[Box3DBody] = []
var _noise := Vector3.ZERO
var _blowing := true
var _rng := RandomNumberGenerator.new()
var _arrow: ImmediateMesh
@onready var _world: Box3DWorld = $Box3DWorld


func _ready() -> void:
	_rng.seed = 20260805

	var mesh := BoxMesh.new()
	mesh.size = PLATE_SIZE
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.9, 0.55, 0.75)
	material.roughness = 0.4
	material.cull_mode = BaseMaterial3D.CULL_DISABLED

	var ribbon := Node3D.new()
	ribbon.name = "Ribbon"
	_world.add_child(ribbon)

	# Upstream anchors the first joint on a static body at the origin, then
	# chains: joint i pins plate i-1's +x end to plate i's -x end. Both local
	# frames name the same world point, so one joint node at that point is the
	# same constraint.
	for i in COUNT:
		var plate := Box3DBody.new()
		plate.name = "Plate_%d" % i
		plate.box_size = PLATE_SIZE
		plate.density = DENSITY
		plate.gravity_scale = GRAVITY_SCALE
		plate.can_sleep = false
		plate.position = Vector3((2.0 * i + 1.0) * R, ANCHOR_Y, 0.0)
		var visual := MeshInstance3D.new()
		visual.mesh = mesh
		visual.material_override = material
		plate.add_child(visual)
		ribbon.add_child(plate)
		_plates.append(plate)

	for i in COUNT:
		var joint := Box3DBallJoint.new()
		joint.name = "Joint_%d" % i
		joint.position = Vector3(2.0 * i * R, ANCHOR_Y, 0.0)
		ribbon.add_child(joint)
		if i == 0:
			# Anchor link: body A is the static ground body in the scene.
			joint.body_a = joint.get_path_to($Box3DWorld/Anchor)
		else:
			joint.body_a = NodePath("../Plate_%d" % (i - 1))
		joint.body_b = NodePath("../Plate_%d" % i)

	_arrow = ImmediateMesh.new()
	var arrow_node := MeshInstance3D.new()
	arrow_node.name = "WindArrow"
	arrow_node.mesh = _arrow
	var arrow_mat := StandardMaterial3D.new()
	arrow_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	arrow_mat.albedo_color = Color(1.0, 0.0, 1.0)  # upstream's fuchsia
	arrow_node.material_override = arrow_mat
	add_child(arrow_node)


## The shell's reusable toggle: upstream drags the wind slider to zero.
func get_toggle_label() -> String:
	return "Wind"


func get_toggle_initial() -> bool:
	return _blowing  # upstream starts blowing (m_wind = {6,0,0}, sample_shapes.cpp:710)


func set_toggled(on: bool) -> void:
	_blowing = on


func _physics_process(_delta: float) -> void:
	var wind := Vector3.ZERO
	if _blowing:
		# Upstream keeps the wind SPEED and perturbs only the direction.
		var speed := WIND.length()
		wind = speed * (WIND.normalized() + _noise)
		for plate in _plates:
			plate.apply_wind(wind, DRAG, LIFT, MAX_SPEED)
		var target := Vector3(
				_rng.randf_range(-NOISE_RANGE, NOISE_RANGE),
				_rng.randf_range(-NOISE_RANGE, NOISE_RANGE),
				_rng.randf_range(-NOISE_RANGE, NOISE_RANGE))
		_noise = _noise.lerp(target, NOISE_LERP)
	_draw_arrow(wind)


func _draw_arrow(wind: Vector3) -> void:
	_arrow.clear_surfaces()
	if wind.is_zero_approx():
		return
	var p1 := Vector3(0.0, 0.5, 0.0)
	var p2 := p1 + 0.2 * wind
	_arrow.surface_begin(Mesh.PRIMITIVE_LINES)
	_arrow.surface_add_vertex(p1)
	_arrow.surface_add_vertex(p2)
	# Two barbs, so the line reads as an arrow from any angle.
	var back := (p1 - p2).normalized() * 0.15
	for side in [Vector3.UP, Vector3.BACK]:
		_arrow.surface_add_vertex(p2)
		_arrow.surface_add_vertex(p2 + back + side * 0.08)
	_arrow.surface_end()
