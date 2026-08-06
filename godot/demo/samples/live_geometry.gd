extends Node3D

## Live Geometry -- there is no upstream sample for this one. Upstream reaches
## `b3Shape_SetSphere` / `SetCapsule` / `SetHull` from the C API only
## (box3d.h:962-1005) and its sample set never animates a shape, so this is
## written in the spirit of one: the smallest scene that makes the capability
## visible, with upstream's own call semantics kept exact.
##
## What is new is that these are the node's ORDINARY size properties now. Until
## this sprint, `sphere_radius = r` (or a child shape's `box_size`) destroyed
## the body and built a new one, which threw away its velocity, its sleep
## state, its contacts and its warm-start impulses -- a settled stack visibly
## popped. They now go straight to `b3Shape_Set*` plus
## `b3Body_ApplyMassFromShapes`, so geometry can change every frame while the
## simulation keeps running underneath it. Box3D wakes the touching bodies
## itself (`src/shape.c:1554-1558`, "need to wake bodies so they can react to
## the shape change"), which is why nothing here has to be nudged.
##
## Three things resize, one per route:
##  * PISTON -- a static body's own box, growing about its own centre, so its
##    top face lifts the five-box tower standing on it. The tower is carried,
##    not thrown: the base brick tracks the top face to within 9 mm, no two
##    bricks ever part by more than 4.4 cm, and nothing exceeds 0.41 m/s. Over
##    50 s of riding (five and a half round trips) it leans by 2.2 degrees and
##    the bricks are still 0.4 m apart, in order.
##  * BALL -- a dynamic body's own sphere. Its mass is recomputed with it, so
##    mass tracks r^3 exactly: 0.30 m to 0.90 m radius is a factor of 27.00.
##    It also stays resting on the ground the whole time, its centre at
##    exactly its current radius, rather than being launched by its own growth.
##  * DUMBBELL -- two `Box3DCollisionShape` sphere children of one dynamic
##    body, driven in antiphase. Nothing moves the body; the mass simply
##    redistributes between its ends -- the local centre of mass swings +/-0.62 m
##    along the bar -- and it rolls toward whichever end is heavier.
##
## The top-bar toggle freezes every size where it stands. Freeze it and the
## whole scene goes to sleep (0 awake bodies), which is the other half of the
## proof: nothing here is being rebuilt behind the scenes.

const GROUND_SIZE := Vector3(40.0, 1.0, 40.0)

## Piston: a static box that only ever changes size. Its centre never moves, so
## the top face is at half the height.
const PISTON_AT := Vector3(-3.5, 0.0, 0.0)
const PISTON_FOOTPRINT := 1.6
const PISTON_MIN_HEIGHT := 1.0
const PISTON_MAX_HEIGHT := 3.0
const TOWER_COUNT := 5
const BRICK := 0.4

const BALL_AT := Vector3(3.5, 0.0, 0.0)
const BALL_MIN_RADIUS := 0.3
const BALL_MAX_RADIUS := 0.9

const DUMBBELL_AT := Vector3(0.0, 0.6, 3.0)
const DUMBBELL_HALF_SPAN := 0.7
const DUMBBELL_MIN_RADIUS := 0.22
const DUMBBELL_MAX_RADIUS := 0.55
const BAR_SIZE := Vector3(1.4, 0.12, 0.12)

## Seconds per full breathe cycle.
const PERIOD := 9.0

var camera_home := Vector3(0.5, 4.2, 9.0)
var camera_look_at := Vector3(0.0, 1.3, 0.6)

var _piston: Box3DBody
var _piston_visual: MeshInstance3D
var _ball: Box3DBody
var _ball_visual: MeshInstance3D
var _dumbbell: Box3DBody
var _lobes: Array[Box3DCollisionShape] = []
var _lobe_visuals: Array[MeshInstance3D] = []
var _time := 0.0
var _running := true


func _ready() -> void:
	var ground := Box3DBody.new()
	ground.name = "Ground"
	ground.body_type = Box3DBody.STATIC
	ground.shape_type = Box3DBody.BOX
	ground.box_size = GROUND_SIZE
	ground.position = Vector3(0.0, -0.5 * GROUND_SIZE.y, 0.0)
	ground.add_child(_box_visual(GROUND_SIZE, Color(0.24, 0.26, 0.29)))
	$Box3DWorld.add_child(ground)

	_build_piston()
	_build_ball()
	_build_dumbbell()


## The shell's reusable toggle: freeze the animation, keep the world running.
## The scene loads ALREADY resizing (there is nothing to look at otherwise), so
## the switch reports that state instead of claiming the effect is off.
func get_toggle_label() -> String:
	return "Resize"


func get_toggle_initial() -> bool:
	return _running


func set_toggled(p_on: bool) -> void:
	_running = p_on


func _physics_process(delta: float) -> void:
	if not _running:
		return
	_time += delta
	# 0..1..0, one PERIOD per round trip.
	var wave := 0.5 - 0.5 * cos(TAU * _time / PERIOD)

	var height: float = lerpf(PISTON_MIN_HEIGHT, PISTON_MAX_HEIGHT, wave)
	# The ONE line that used to rebuild the body.
	_piston.box_size = Vector3(PISTON_FOOTPRINT, height, PISTON_FOOTPRINT)
	(_piston_visual.mesh as BoxMesh).size = _piston.box_size

	var radius: float = lerpf(BALL_MIN_RADIUS, BALL_MAX_RADIUS, wave)
	_ball.sphere_radius = radius
	_scale_sphere_mesh(_ball_visual, radius)

	# Antiphase: as one lobe grows the other shrinks, so the total mass barely
	# moves and only its distribution does.
	for i in _lobes.size():
		var t: float = wave if i == 0 else 1.0 - wave
		var r: float = lerpf(DUMBBELL_MIN_RADIUS, DUMBBELL_MAX_RADIUS, t)
		_lobes[i].sphere_radius = r
		_scale_sphere_mesh(_lobe_visuals[i], r)


func _build_piston() -> void:
	_piston = Box3DBody.new()
	_piston.name = "Piston"
	_piston.body_type = Box3DBody.STATIC
	_piston.shape_type = Box3DBody.BOX
	_piston.box_size = Vector3(PISTON_FOOTPRINT, PISTON_MIN_HEIGHT, PISTON_FOOTPRINT)
	_piston.position = PISTON_AT
	_piston_visual = _box_visual(_piston.box_size, Color(0.35, 0.5, 0.62))
	_piston.add_child(_piston_visual)
	$Box3DWorld.add_child(_piston)

	# The tower starts on the piston at its shortest, resting, and is lifted by
	# the shape change alone.
	for i in TOWER_COUNT:
		var brick := Box3DBody.new()
		brick.name = "Brick%d" % i
		brick.shape_type = Box3DBody.BOX
		brick.box_size = Vector3(BRICK, BRICK, BRICK)
		brick.position = PISTON_AT + Vector3(0.0,
				0.5 * PISTON_MIN_HEIGHT + (i + 0.5) * BRICK, 0.0)
		# Alternating colours so the ride reads as five bricks, not one column.
		brick.add_child(_box_visual(brick.box_size,
				Color(0.88, 0.58, 0.26) if i % 2 == 0 else Color(0.93, 0.86, 0.55)))
		$Box3DWorld.add_child(brick)


func _build_ball() -> void:
	_ball = Box3DBody.new()
	_ball.name = "Ball"
	_ball.shape_type = Box3DBody.SPHERE
	_ball.sphere_radius = BALL_MIN_RADIUS
	_ball.position = BALL_AT + Vector3(0.0, BALL_MIN_RADIUS, 0.0)
	_ball_visual = MeshInstance3D.new()
	_ball_visual.mesh = SphereMesh.new()
	_ball_visual.material_override = _material(Color(0.9, 0.45, 0.25))
	_scale_sphere_mesh(_ball_visual, BALL_MIN_RADIUS)
	_ball.add_child(_ball_visual)
	$Box3DWorld.add_child(_ball)


func _build_dumbbell() -> void:
	_dumbbell = Box3DBody.new()
	_dumbbell.name = "Dumbbell"
	_dumbbell.shape_type = Box3DBody.BOX
	_dumbbell.box_size = BAR_SIZE
	_dumbbell.position = DUMBBELL_AT
	_dumbbell.add_child(_box_visual(BAR_SIZE, Color(0.55, 0.55, 0.6)))

	for i in 2:
		var lobe := Box3DCollisionShape.new()
		lobe.name = "Lobe%d" % i
		lobe.shape_type = Box3DCollisionShape.SPHERE
		lobe.sphere_radius = DUMBBELL_MIN_RADIUS
		lobe.position = Vector3((-1.0 if i == 0 else 1.0) * DUMBBELL_HALF_SPAN, 0.0, 0.0)
		var visual := MeshInstance3D.new()
		visual.mesh = SphereMesh.new()
		visual.material_override = _material(Color(0.4, 0.75, 0.55))
		_scale_sphere_mesh(visual, DUMBBELL_MIN_RADIUS)
		lobe.add_child(visual)
		_dumbbell.add_child(lobe)
		_lobes.append(lobe)
		_lobe_visuals.append(visual)

	$Box3DWorld.add_child(_dumbbell)


func _box_visual(p_size: Vector3, p_color: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = p_size
	mi.mesh = mesh
	mi.material_override = _material(p_color)
	return mi


func _scale_sphere_mesh(p_visual: MeshInstance3D, p_radius: float) -> void:
	var mesh := p_visual.mesh as SphereMesh
	mesh.radius = p_radius
	mesh.height = 2.0 * p_radius


func _material(p_color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = p_color
	mat.roughness = 0.45
	return mat


func get_piston() -> Box3DBody:
	return _piston


func get_ball() -> Box3DBody:
	return _ball


func get_dumbbell() -> Box3DBody:
	return _dumbbell
