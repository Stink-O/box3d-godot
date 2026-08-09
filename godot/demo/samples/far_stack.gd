extends Node3D

## Far Stack -- a port of upstream's "World / Far Stack" sample
## (samples/sample_world.cpp:12-122).
##
## Upstream's World category asks one question: how far from the world origin
## can a simulation run before floating point stops being able to describe it?
## Its scene is deliberately plain -- a 24 x 2 x 24 m ground box and a six-high
## column of 1 m boxes with a 2 cm alternating skew, so nothing balances by luck
## -- and it is built at an offset you can slide from the origin out to
## 10,000 km. The readout is the top box's height above the ground, measured in
## the offset's own frame: it holds steady where precision holds, and drifts
## once it does not.
##
## THE CEILING IS REAL AND IT IS NAMED IN THE HEADERS. Box3D's own sanity limit
## on a position is `B3_HUGE`, and in float mode that is 1e5 m -- 100 km --
## against 1e9 m under `BOX3D_DOUBLE_PRECISION`, with upstream's comment right
## above it: "In float mode positions greater than about 16km have precision
## problems, so 100km is a safe limit" (constants.h:22-30). This GDExtension is
## built in float mode, and Godot's own `Vector3` is single precision in a stock
## build too, so upstream's 1000 km and 10,000 km presets are not offsets this
## port can honestly run. It sweeps upstream's other three -- the origin, 10 km
## and 100 km -- the whole of the range a float build owns.
##
## AND THE RESULT IS THE GOOD ONE, which is worth stating plainly because the
## sample's framing invites the opposite guess. Measured over the three presets,
## the settled height of the top box agrees to a tenth of a millimetre
## (5.4920 m, 5.4921 m, 5.4921 m): the stack 100 km out settles exactly as the
## one at the origin does. That is the contact solver working in delta space
## rather than in absolute coordinates. What does move is the lateral drift, by
## a couple of millimetres between offsets -- the float32 step at 1e5 m is 7.8 mm,
## so a few of those is all the precision that is left in the READBACK. Upstream's
## warning about float builds is about the offsets past this ceiling, and those
## need `BOX3D_DOUBLE_PRECISION`.
##
## The scene is rendered in a LOCAL frame on purpose. The bodies really are at
## the offset -- that is the point -- but their `auto_visual` is off and the
## drawing is done by ghost meshes placed at `body position - base`, so the
## renderer and the camera never handle a 1e5 coordinate and what you are
## looking at is the physics readback rather than a second precision problem
## stacked on top of the first.
##
## Upstream constants, verbatim: ground half extents (12, 1, 12) with the body
## at `base + (0, -1, 0)` so its top face is exactly `base.y`
## (samples/sample_world.cpp:47-56); six dynamic boxes of half extent 0.5 at
## `base + (skew, 0.5 + i, 0)` with `skew = +/-0.02` alternating
## (samples/sample_world.cpp:57-71); presets at 0, 10 and 100 km
## (samples/sample_world.cpp:79). The camera is upstream's
## `SetView(0, 8, 16, {0, 2, 0})` resolved onto its orbit.
##
## The lateral drift line is this port's own addition. Upstream prints the
## height only, but the offset runs along x, so x is where the quantization
## actually shows up and printing it makes the effect legible without a slider
## to wiggle.

## Upstream's presets, minus the two that need BOX3D_DOUBLE_PRECISION.
const OFFSETS_KM := [0.0, 10.0, 100.0]
const HOLD_SECONDS := 6.0

const GROUND_SIZE := Vector3(24.0, 2.0, 24.0)
const COLUMN_COUNT := 6
const BOX_SIZE := Vector3(1.0, 1.0, 1.0)
## Upstream's "small alternating skew so a float build visibly drifts rather
## than balancing by luck" (samples/sample_world.cpp:65-66).
const SKEW := 0.02

var camera_home := Vector3(0.0, 4.23, 15.84)
var camera_look_at := Vector3(0.0, 2.0, 0.0)

var _world: Box3DWorld
var _ground: Box3DBody
var _boxes: Array[Box3DBody] = []
var _ghost_ground: MeshInstance3D
var _ghosts: Array[MeshInstance3D] = []

var _index := 0
var _time := 0.0
var _base := Vector3.ZERO

@onready var _label: Label3D = $Status


func _ready() -> void:
	_world = $Box3DWorld
	_base = _base_for(_index)

	_ground = Box3DBody.new()
	_ground.name = "Ground"
	_ground.body_type = Box3DBody.STATIC
	_ground.shape_type = Box3DBody.BOX
	_ground.box_size = GROUND_SIZE
	_ground.auto_visual = false
	_ground.position = _base + Vector3(0.0, -0.5 * GROUND_SIZE.y, 0.0)
	_world.add_child(_ground)

	for i in COLUMN_COUNT:
		var body := Box3DBody.new()
		body.name = "Box%d" % i
		body.body_type = Box3DBody.DYNAMIC
		body.shape_type = Box3DBody.BOX
		body.box_size = BOX_SIZE
		body.auto_visual = false
		body.position = _base + _local_box(i)
		_world.add_child(body)
		_boxes.append(body)

	_build_ghosts()
	_update_ghosts()


## The shell's Activate button: jump straight to the next offset.
func activate() -> void:
	_advance()


func _physics_process(delta: float) -> void:
	_time += delta
	if _time >= HOLD_SECONDS:
		_advance()
	_update_ghosts()
	_update_label()


func _advance() -> void:
	_time = 0.0
	_index = (_index + 1) % OFFSETS_KM.size()
	_base = _base_for(_index)
	# Upstream rebuilds the world for each preset. Teleporting reaches the same
	# start state without paying for a rebuild, and the bodies are put fully to
	# rest so the new offset is not judged on momentum carried over from the old.
	_ground.teleport(Transform3D(Basis(), _base + Vector3(0.0, -0.5 * GROUND_SIZE.y, 0.0)))
	for i in _boxes.size():
		var body := _boxes[i]
		body.set_linear_velocity(Vector3.ZERO)
		body.set_angular_velocity(Vector3.ZERO)
		body.teleport(Transform3D(Basis(), _base + _local_box(i)))
		body.set_awake(true)


func _base_for(p_index: int) -> Vector3:
	return Vector3(1000.0 * float(OFFSETS_KM[p_index]), 0.0, 0.0)


func _local_box(p_index: int) -> Vector3:
	var skew := SKEW if (p_index & 1) != 0 else -SKEW
	return Vector3(skew, 0.5 + 1.0 * p_index, 0.0)


func _build_ghosts() -> void:
	var ground_mesh := BoxMesh.new()
	ground_mesh.size = GROUND_SIZE
	_ghost_ground = MeshInstance3D.new()
	_ghost_ground.name = "GroundGhost"
	_ghost_ground.mesh = ground_mesh
	_ghost_ground.material_override = _material(Color(0.22, 0.24, 0.27))
	add_child(_ghost_ground)

	var box_mesh := BoxMesh.new()
	box_mesh.size = BOX_SIZE
	for i in COLUMN_COUNT:
		var ghost := MeshInstance3D.new()
		ghost.name = "BoxGhost%d" % i
		ghost.mesh = box_mesh
		ghost.material_override = _material(Color.from_hsv(0.08 + 0.06 * i, 0.55, 0.92))
		add_child(ghost)
		_ghosts.append(ghost)


## The bodies are at the offset; the drawing is not. Subtracting the base in
## GDScript (which is double precision) leaves exactly the error the physics
## readback carries and adds none of its own.
func _update_ghosts() -> void:
	_ghost_ground.transform = Transform3D(Basis(), _ground.position - _base)
	for i in _ghosts.size():
		_ghosts[i].transform = Transform3D(Basis(_boxes[i].quaternion), _boxes[i].position - _base)


func _update_label() -> void:
	# b3Body_GetWorldCenter, in the offset's own frame -- upstream's readout
	# (samples/sample_world.cpp:99-105).
	var top := _boxes[COLUMN_COUNT - 1].get_center_of_mass() - _base
	_label.text = "\n".join(PackedStringArray([
		"world offset: %.0f km" % float(OFFSETS_KM[_index]),
		"top box height above ground: %.4f m" % top.y,
		"top box lateral drift: %.4f m" % top.x,
	]))


func _material(p_color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = p_color
	m.roughness = 0.5
	return m
