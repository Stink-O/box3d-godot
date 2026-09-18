extends Node3D

## Wind Drop -- a port of upstream's "Shapes / Wind Drop" sample
## (samples/sample_shapes.cpp, class WindDrop). One thin square plate is
## dropped from ten metres, tilted a quarter radian so it does not fall dead
## flat, and every step it is handed to `Box3DBody.apply_wind` with ZERO wind.
## Box3D has no per-body drag setting; what makes the plate float down and
## glide is `b3Shape_ApplyWind` (src/shape.c): for every hull face that meets
## the relative airflow it adds 0.5 * airDensity * projectedArea * speed^2
## along the flow (drag) plus a lift term perpendicular to it. A plate falling
## face-on shows a huge projected area, so it slows to a glide, while the
## same plate edge-on cuts through the air. The toggle removes the call and
## the plate free-falls, which is the whole comparison in one scene.
##
## Upstream's numbers are kept verbatim except lift: hull half extents
## (4r, 0.1r, 4r) with r = 0.1 (so an 0.8 x 0.02 x 0.8 m plate), density 2,
## gravity scale 0.5, drag 1.0, max relative speed 10 m/s. The scene's
## AddGroundBox(15) is the 30 m floor.
##
## Lift is 1.0 here, not upstream's 4.0. The plate weighs 26 g, and at lift 4
## one face-on step of capped airflow is ~200 N, so the per-step velocity
## change dwarfs the velocity it was computed from and the explicit force
## overshoots. Untouched the drop is fine; grabbed with the shell's mouse
## joint it hit 58 m/s and left the floor 99 m out. Measured headlessly with
## the shell's own grab joint swirled for 1.5 s then released:
##   lift 4.0: 58 m/s, 99 m from the origin, never lands
##   lift 2.0: blows up from an 8 m/s kick alone
##   lift 1.5: blows up from a 15 m/s kick
##   lift 1.0: 15 m/s while held, lands 3.4 m out, 10 s to land untouched
## Lowering max_speed does not help (the force per step still exceeds the
## plate's momentum), and lift 1 is about the flat-plate maximum anyway.

const R := 0.1
## b3MakeBoxHull(4r, 0.1r, 4r) is a HALF-extent call: double it.
const PLATE_SIZE := Vector3(8.0 * R, 0.2 * R, 8.0 * R)
const DROP_HEIGHT := 10.0
## Upstream's b3MakeQuatFromAxisAngle(axisX, 0.25).
const TILT := 0.25
const DENSITY := 2.0
const GRAVITY_SCALE := 0.5

const DRAG := 1.0
## Upstream 4.0; see the header for why 1.0.
const LIFT := 1.0
const MAX_SPEED := 10.0

## Upstream's SetView(-45, 15, 20, {0, 5, 0}) with the radius halved to 10:
## eye = pivot + radius * (sin yaw * cos pitch, sin pitch, cos yaw * cos pitch).
## Upstream draws the plate as thick debug lines; shaded in Godot, an 0.8 m
## plate is a sliver at 20 m. Same angle, same pivot, closer.
var camera_home := Vector3(-6.83, 7.59, 6.83)
var camera_look_at := Vector3(0.0, 5.0, 0.0)

var _plate: Box3DBody
var _air := true
@onready var _world: Box3DWorld = $Box3DWorld


func _ready() -> void:
	var mesh := BoxMesh.new()
	mesh.size = PLATE_SIZE
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.9, 0.55, 0.75)
	material.roughness = 0.4
	material.cull_mode = BaseMaterial3D.CULL_DISABLED

	_plate = Box3DBody.new()
	_plate.name = "Plate"
	_plate.box_size = PLATE_SIZE
	_plate.density = DENSITY
	_plate.gravity_scale = GRAVITY_SCALE
	_plate.position = Vector3(0.0, DROP_HEIGHT, 0.0)
	_plate.rotation = Vector3(TILT, 0.0, 0.0)
	var visual := MeshInstance3D.new()
	visual.mesh = mesh
	visual.material_override = material
	_plate.add_child(visual)
	_world.add_child(_plate)


## The shell's reusable toggle: air on is upstream; off is a plain drop.
func get_toggle_label() -> String:
	return "Air"


func get_toggle_initial() -> bool:
	return _air


func set_toggled(on: bool) -> void:
	_air = on


func _physics_process(_delta: float) -> void:
	if _air and _plate != null:
		# Zero wind: the only airflow is the plate's own motion through still
		# air, so this is pure drag and lift against its velocity.
		_plate.apply_wind(Vector3.ZERO, DRAG, LIFT, MAX_SPEED)
