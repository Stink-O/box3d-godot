extends Node3D

## Character Controller -- a port of upstream's "Character" samples
## (samples/sample_character.cpp) and of the mover itself (samples/mover.cpp +
## mover.h). Box3DCharacterBody is the geometric half: collide ->
## b3SolvePlanes -> b3World_CastMover, five passes, exactly as
## CharacterMover::SolveMove sweeps. Everything ABOVE that -- Quake-style
## ground friction, the acceleration model, gravity, the jump, and the pogo
## suspension that decides what "on the ground" means -- lives in the mover
## struct upstream, so it lives in this script, number for number:
##
##   jump 5, max speed 6 (x1.5 sprinting), min speed 0.01, stop speed 1,
##   accelerate 30, friction 4, gravity 15 (mover.h:24-32), a capsule of
##   radius 0.3 with its centres +/- 0.5 (mover.cpp:34), and a 4 Hz / 0.7
##   damping pogo spring probing 3 x radius below the capsule's lower centre
##   (mover.cpp:140-172).
##
## THE CAPSULE FLOATS, AND THAT IS THE DESIGN. The pogo ray starts at the
## capsule's LOWER SPHERE CENTRE and its spring rest length is 3 x radius =
## 0.9 m, while the capsule bottom is only 0.3 m below that centre -- so a
## standing mover rides 0.6 m clear of the ground, less the spring's sag under
## gravity. Measured 0.582 m, and the closed form for the sag agrees to four
## decimals. Upstream's own scene confirms the intent: it parks the two static
## capsules at y = 1.4, which is this mover's standing height (1.3819), not
## the 0.8 they would need to rest on the floor. The pogo ray is drawn (green
## when it finds ground) so the gap reads as suspension travel.
##
## Controls: W A S D walk, Shift sprint, Space jump, C toggles upstream's
## "Clip Velocity" checkbox, V its debug overlays. The shell's sample toggle
## is the THIRD PERSON camera, which is upstream's other checkbox and the same
## rig the Car sample uses (fly_camera.set_follow); hold right mouse in it to
## orbit, exactly as the Car does.
##
## The level is upstream's, piece for piece. From the Mover sample: three 2 m
## blocks at z ~ 14, the 50 x 50 wave height field at (20,0,0), the
## b3CreateTorusMesh(10,12,2,1) torus scaled (-0.75,1.5,0.5), the soft ally and
## springy enemy capsules, the ignored slab, a dynamic ball and the sprung door
## on a +/-90 degree hinge. From the Rigid Body sample in the same file, which
## shares the same level: the 20 degree ramp, the 50 degree ramp, three
## platforms with gaps, the five step-height lips, the wall, three pushable
## boxes and the orange sphere. Two substitutions: upstream's floor
## (data/meshes/test_map01.obj) and stairs (stairs.obj) are art this repo does
## not vendor, so the floor is a box with its top at y = 0 and the stairs are
## ten 0.25 m risers at upstream's stairs origin.
##
## Geometric Mover's time-of-impact half is here too (sample_character.cpp:
## 406-419, :476-496, :606-768). A thin gold plate (2 x 0.2 x 2) drops from
## (10.5, 30, 0) on a loop, respawning once it has slept for a second, and a
## tree of 22 shrinking six-sided cylinders topples from (22, 1.5, 2) on the
## wave field, spun about its base at 0.5 rad/s along (1, 0, -1), and is
## rebuilt the same way. Neither can be caught by the mover's discrete
## collide: the character is not a body, so they pass straight through it.
## Every step, Box3DBody.time_of_impact_mover sweeps the mover capsule over
## its own move against each body's motion over the same step
## (b3Body_TimeOfImpactMover), and a hit is drawn as upstream draws it: a
## point, an arrow along the normal and the approach speed in m/s (yellow
## for the plate, cyan for the tree), plus a translucent yellow plate at the
## pose where it first touched. The tree carries upstream's shape user data
## as mover metadata: push limit 10, clip velocity on, and mover_can_push
## off, so walking into it does not shove it. Stand under the plate's drop
## line (x 10.5, z 0) to be hit.
##
## One deliberate difference: upstream records an impact whenever
## toi.fraction > 0 (:699, :722), but b3Body_TimeOfImpactMover reports a miss
## as fraction 1 with a zero point (src/body.c:817-818), so upstream's test
## passes on every step and its ghost plate simply follows the falling one.
## This port records an impact only on a real hit (the binding's `hit`).
##
## The wave field's diagonal chains of missing cells are upstream's too:
## b3CreateWave's makeHoles marks every 16th CELL as B3_HEIGHT_FIELD_HOLE
## (src/height_field.c:1417) and a row is 49 cells, so the hole index walks one
## cell per row. They are real holes -- the collider has them as well, 150 of
## 2401 cells -- and you can drop through them.

# --- CharacterMover tuning (samples/mover.h:24-32) ---------------------------
const JUMP_SPEED := 5.0
const MAX_SPEED := 6.0
const MIN_SPEED := 0.01
const STOP_SPEED := 1.0
const ACCELERATE := 30.0
const FRICTION := 4.0
const GRAVITY := 15.0
const SPRINT_SCALE := 1.5

# --- capsule + pogo (samples/mover.cpp:34, :140-171) -------------------------
const CAPSULE_RADIUS := 0.3
const CAPSULE_HALF := 0.5 # centre1/centre2 offset, so total height 1.6
const POGO_HERTZ := 4.0
const POGO_ZETA := 0.7
## The pogo ray skips category 2, upstream's "allies" (mover.cpp:144).
const POGO_MASK := 0xFFFFFFFD

const START_POSITION := Vector3(7.5, 0.75, 9.0)

# --- Geometric Mover's time-of-impact props (sample_character.cpp:406-419,
# :476-496, :606-637) ---------------------------------------------------------
const FALLING_EXTENT := Vector3(1.0, 0.1, 1.0)
const FALLING_SPAWN := Vector3(10.5, 30.0, 0.0)
const TREE_SPAWN := Vector3(22.0, 1.5, 2.0)
const TREE_SPIN := 0.5
const TREE_AXIS := Vector3(1.0, 0.0, -1.0)
const TREE_SEGMENTS := 22
## SettledForOneSecond (:672-688): a body asleep this long is put back.
const SETTLE_TIME := 1.0
## b3DefaultShapeDef's density, which the plate and the tree keep.
const PROP_DENSITY := 1000.0

## Upstream frames this sample with a 5 m boom on the mover itself
## (SetView(120, 30, 5, moverPosition), sample_character.cpp:325), which is
## what the Third Person toggle gives you. The opening shot is pulled back to
## an establishing view instead, because the scene carries both of upstream's
## character courses and a 5 m boom shows almost none of it.
var camera_home := Vector3(11.5, 7.0, 15.0)
var camera_look_at := Vector3(1.5, 0.5, 3.5)

var _world: Box3DWorld
var _char: Box3DCharacterBody
var _cam: Camera3D

var _velocity := Vector3.ZERO
var _pogo_velocity := 0.0
var _on_ground := false
var _sprint := false
## Upstream's "Clip Velocity" checkbox (sample_character.cpp:546), on the C key
## because the shell's one sample toggle is the third-person camera.
var _clip_velocity := true
## Upstream's debug draw, its V key (sample_character.cpp:1505).
var _show_debug := true

var _hud: Label3D
var _overlay: ImmediateMesh
var _pogo_from := Vector3.ZERO
var _pogo_to := Vector3.ZERO
var _pogo_grounded := false
var _clip_held := false
var _debug_held := false

var _falling_box: Box3DBody
var _tree: Box3DBody
var _box_timer := 0.0
var _tree_timer := 0.0
## The step's start poses, recorded before the move and swept to the end
## poses at the start of the next physics frame (after the world stepped).
var _sweep_ready := false
var _mover_start := Vector3.ZERO
var _box_start := Transform3D()
var _tree_start := Transform3D()
## Upstream's MoverImpact (point, normal, speed); empty until the first hit.
var _box_impact: Dictionary = {}
var _tree_impact: Dictionary = {}
var _impact_lines: ImmediateMesh
var _impact_ghost: MeshInstance3D
var _box_label: Label3D
var _tree_label: Label3D
var _tree_material: StandardMaterial3D


func _ready() -> void:
	_world = $Box3DWorld
	_char = $Box3DWorld/Mover
	_cam = get_viewport().get_camera_3d()
	_build_stairs()
	_build_torus()
	_build_terrain_visual()
	_build_obstacle_course()
	_build_hud()
	_build_overlay()
	_build_falling_box()
	_create_falling_tree()
	_build_impact_overlay()


## The shell's Activate button: upstream restarts the sample to put the mover
## back at its start (sample_character.cpp:321).
func activate() -> void:
	_char.global_position = START_POSITION
	_velocity = Vector3.ZERO
	_pogo_velocity = 0.0
	_on_ground = false
	# A teleport is not a move to sweep.
	_sweep_ready = false


# --- Shell toggle: third-person chase camera, the Car sample's rig -----------

func get_toggle_label() -> String:
	return "Third Person"


func set_toggled(on: bool) -> void:
	if _cam == null or not _cam.has_method("set_follow"):
		return
	if on:
		# Pivot on the capsule, eye behind and above it -- upstream's own
		# framing is SetView(120, 30, 5, moverPosition), a 5 m boom at 30
		# degrees (sample_character.cpp:325).
		_cam.set_follow(_char, Vector3(-4.33, 2.5, 0.0), 0.9)
	else:
		_cam.clear_follow()


func _physics_process(delta: float) -> void:
	# Upstream's Step (sample_character.cpp:743-768) records the mover's and
	# both bodies' poses, moves the mover, steps the world and then sweeps.
	# The world steps after this script, so the sweep of the last step runs
	# here first, and this step's start poses are recorded before the move.
	if _sweep_ready:
		_update_falling_box(delta)
		_update_falling_tree(delta)
	_mover_start = _char.global_position
	_box_start = _falling_box.global_transform
	_tree_start = _tree.global_transform
	_sweep_ready = true

	# CharacterMover::Step (mover.cpp:263-318): camera-relative throttle, jump
	# and sprint, then one SolveMove.
	var throttle := Vector2.ZERO
	var forward := Vector3.FORWARD
	var right := Vector3.RIGHT
	if _cam != null:
		forward = -_cam.global_transform.basis.z
		right = _cam.global_transform.basis.x
	forward.y = 0.0
	right.y = 0.0
	forward = forward.normalized()
	right = right.normalized()

	# Steer whenever the mouse is free, and also while the third-person rig has
	# it captured for orbiting -- there is no fly camera to protect then. Same
	# rule the Car sample uses.
	var steering: bool = Input.mouse_mode != Input.MOUSE_MODE_CAPTURED \
			or (_cam != null and _cam.has_method("is_following") and _cam.is_following())
	if steering:
		if Input.is_key_pressed(KEY_W): throttle.x += 1.0
		if Input.is_key_pressed(KEY_S): throttle.x -= 1.0
		if Input.is_key_pressed(KEY_A): throttle.y -= 1.0
		if Input.is_key_pressed(KEY_D): throttle.y += 1.0
		if Input.is_key_pressed(KEY_SPACE) and _on_ground:
			_velocity.y = JUMP_SPEED
			_on_ground = false
		_sprint = _on_ground and Input.is_key_pressed(KEY_SHIFT)
	else:
		_sprint = false

	# Upstream's two checkboxes, as key presses (edge-triggered).
	var clip_now := Input.is_key_pressed(KEY_C)
	if clip_now and not _clip_held:
		_clip_velocity = not _clip_velocity
	_clip_held = clip_now
	var debug_now := Input.is_key_pressed(KEY_V)
	if debug_now and not _debug_held:
		_show_debug = not _show_debug
	_debug_held = debug_now

	solve_move(delta, forward, right, throttle)


## CharacterMover::SolveMove (samples/mover.cpp:83-261).
func solve_move(delta: float, forward: Vector3, right: Vector3, throttle: Vector2) -> void:
	# Friction: linear damping above stop speed, a fixed reduction below it.
	var speed := _velocity.length()
	if speed < MIN_SPEED:
		_velocity.x = 0.0
		_velocity.z = 0.0
	else:
		var control := STOP_SPEED if speed < STOP_SPEED else speed
		var drop := control * FRICTION * delta
		var ratio := maxf(0.0, speed - drop) / speed
		_velocity.x *= ratio
		_velocity.z *= ratio

	var max_speed: float = SPRINT_SCALE * MAX_SPEED if _sprint else MAX_SPEED

	var desired_velocity := max_speed * throttle.x * forward + max_speed * throttle.y * right
	var desired_speed := desired_velocity.length()
	var desired_direction := desired_velocity / desired_speed if desired_speed > 0.0 else Vector3.ZERO
	if desired_speed > max_speed:
		desired_speed = max_speed

	if _on_ground:
		_velocity.y = 0.0

	# Accelerate: only ever ADDS speed along the wish direction, capped by how
	# much is missing, which is what makes air control feel like Quake's.
	var current_speed := _velocity.dot(desired_direction)
	var add_speed := desired_speed - current_speed
	if add_speed > 0.0:
		_velocity += minf(ACCELERATE * max_speed * delta, add_speed) * desired_direction

	_velocity.y -= GRAVITY * delta

	_solve_pogo(delta)

	# target = p + dt * velocity + dt * pogoVelocity * up (mover.cpp:175). The
	# pogo is a suspension, not part of the mover's velocity, so it is added to
	# the move and never to _velocity.
	var command := _velocity + Vector3(0.0, _pogo_velocity, 0.0)
	var achieved: Vector3 = _char.move_and_slide(command, delta)

	if _clip_velocity:
		# b3ClipVector against the planes the move solved: keeps the mover from
		# picking up speed out of soft depenetration (mover.cpp:250-255).
		_velocity = _char.clip_velocity(_velocity)
	elif delta > 0.0:
		# The position-delta branch (mover.cpp:256-260): move_and_slide returns
		# exactly (endPosition - startPosition) / timeStep.
		_velocity = achieved


## The pogo suspension (mover.cpp:140-172). A ray from the capsule's lower
## centre looks 3 x radius + radius below it; the mover rides a 4 Hz spring
## against whatever it finds, and "on the ground" IS that ray hitting, not the
## collision planes. It is what carries the capsule up stairs and over lips
## without a step-up hack, and what holds it 0.58 m clear of the floor.
func _solve_pogo(delta: float) -> void:
	var rest_length := 3.0 * CAPSULE_RADIUS
	var ray_length := rest_length + CAPSULE_RADIUS
	var ray_origin := _char.global_position + Vector3(0.0, -CAPSULE_HALF, 0.0)
	var ray_target := ray_origin + Vector3(0.0, -ray_length, 0.0)
	var hit: Dictionary = _world.raycast(ray_origin, ray_target, POGO_MASK)

	_pogo_from = ray_origin
	_pogo_to = ray_target
	_pogo_grounded = false

	# After gravity, a mover still moving up must not be pulled back down.
	var suppress: bool = _velocity.y > 0.0
	if suppress or not hit.get("hit", false):
		_on_ground = false
		_pogo_velocity = 0.0
		return

	_on_ground = true
	_pogo_grounded = true
	_pogo_to = hit["position"]
	var current_length: float = hit["fraction"] * ray_length
	var omega := TAU * POGO_HERTZ
	var omega_h := omega * delta
	_pogo_velocity = (_pogo_velocity - omega * omega_h * (current_length - rest_length)) \
			/ (1.0 + 2.0 * POGO_ZETA * omega_h + omega_h * omega_h)


func _process(_delta: float) -> void:
	_update_hud()
	_draw_overlay()
	_draw_impacts()


# --- Geometric Mover's falling plate and tree --------------------------------

## The falling plate (sample_character.cpp:476-496): a dynamic 2 x 0.2 x 2
## box dropped from (10.5, 30, 0) with no spin.
func _build_falling_box() -> void:
	_falling_box = Box3DBody.new()
	_falling_box.name = "FallingBox"
	_falling_box.box_size = 2.0 * FALLING_EXTENT
	_falling_box.density = PROP_DENSITY
	_falling_box.angular_damping = 0.0
	_falling_box.position = FALLING_SPAWN
	var mesh := BoxMesh.new()
	mesh.size = 2.0 * FALLING_EXTENT
	var visual := MeshInstance3D.new()
	visual.mesh = mesh
	visual.material_override = _material(Color(1.0, 0.8431, 0.0), 0.45)  # b3_colorGold
	_falling_box.add_child(visual)
	_world.add_child(_falling_box)


## CreateFallingTree (sample_character.cpp:606-638): 22 six-sided cylinder
## hulls on one body, each b3CreateCylinder(l + 2r, r, y - r, 6) with y
## stepping by l + 2r and r shrinking by 5%, friction 0.9, rolling
## resistance 0.05, sleep threshold 0.2, then spun about its base.
func _create_falling_tree() -> void:
	if _tree_material == null:
		_tree_material = _material(Color(0.55, 0.4, 0.25), 0.8)
	_tree = Box3DBody.new()
	_tree.name = "FallingTree"
	_tree.sleep_threshold = 0.2
	_tree.angular_damping = 0.0
	_tree.position = TREE_SPAWN
	# Upstream's m_treeShapeUserData (:414-416), as mover metadata.
	_tree.set_meta("mover_push_limit", 10.0)
	_tree.set_meta("mover_clip_velocity", true)
	_tree.set_meta("mover_can_push", false)
	var y := 1.0
	var r := 0.75
	var l := 1.5
	for i in range(TREE_SEGMENTS):
		var height := l + 2.0 * r
		var centre := Vector3(0.0, y - r + 0.5 * height, 0.0)
		var segment := Box3DCollisionShape.new()
		segment.shape_type = Box3DCollisionShape.CYLINDER
		segment.capsule_radius = r
		segment.capsule_height = height
		segment.sides = 6
		segment.density = PROP_DENSITY
		segment.friction = 0.9
		segment.rolling_resistance = 0.05
		segment.position = centre
		_tree.add_child(segment)
		var mesh := CylinderMesh.new()
		mesh.top_radius = r
		mesh.bottom_radius = r
		mesh.height = height
		mesh.radial_segments = 6
		mesh.rings = 1
		var visual := MeshInstance3D.new()
		visual.mesh = mesh
		visual.position = centre
		visual.material_override = _tree_material
		_tree.add_child(visual)
		y += height
		r *= 0.95
	_world.add_child(_tree)
	# Spin about the base: omega, plus the matching velocity of the centre of
	# mass, omega x (centre - spawn) (:635-637).
	var spin := TREE_SPIN * TREE_AXIS.normalized()
	_tree.set_angular_velocity(spin)
	_tree.set_linear_velocity(spin.cross(_tree.get_center_of_mass() - TREE_SPAWN))


## SettledForOneSecond (sample_character.cpp:672-688).
func _settled(body: Box3DBody, timer: float, delta: float) -> float:
	if body.is_awake():
		return 0.0
	return timer + delta


## The mover capsule's sweep over the last step against `body` moving from
## `start` to where it is now (UpdateFallingBox / UpdateFallingTree,
## sample_character.cpp:712-733, :691-709).
func _sweep(body: Box3DBody, start: Transform3D) -> Dictionary:
	var a := _mover_start + Vector3(0.0, -CAPSULE_HALF, 0.0)
	var b := _mover_start + Vector3(0.0, CAPSULE_HALF, 0.0)
	return body.time_of_impact_mover(a, b, CAPSULE_RADIUS, _char.global_position - _mover_start,
			start, body.global_transform)


## MakeImpact (:648-654): the normal points from the body to the mover, so
## an approach is a positive speed.
func _impact(body: Box3DBody, toi: Dictionary) -> Dictionary:
	var point: Vector3 = toi["position"]
	var normal: Vector3 = toi["normal"]
	return {"point": point, "normal": normal,
			"speed": normal.dot(body.get_point_velocity(point) - _velocity)}


func _update_falling_box(delta: float) -> void:
	var toi := _sweep(_falling_box, _box_start)
	if toi["hit"]:
		var f: float = toi["fraction"]
		var end := _falling_box.global_transform
		var q1 := _box_start.basis.get_rotation_quaternion()
		var q2 := end.basis.get_rotation_quaternion()
		if q1.dot(q2) < 0.0:
			q2 = -q2
		# The plate's pose at first touch, b3NLerp as upstream (:724-725).
		_impact_ghost.transform = Transform3D(Basis((q1 * (1.0 - f) + q2 * f).normalized()),
				_box_start.origin.lerp(end.origin, f))
		_box_impact = _impact(_falling_box, toi)
	_box_timer = _settled(_falling_box, _box_timer, delta)
	if _box_timer >= SETTLE_TIME:
		_box_timer = 0.0
		# RespawnFallingBox (:735-741).
		_falling_box.teleport(Transform3D(Basis(), FALLING_SPAWN))
		_falling_box.set_linear_velocity(Vector3.ZERO)
		_falling_box.set_angular_velocity(Vector3.ZERO)
		_falling_box.set_awake(true)


func _update_falling_tree(delta: float) -> void:
	var toi := _sweep(_tree, _tree_start)
	if toi["hit"]:
		_tree_impact = _impact(_tree, toi)
	_tree_timer = _settled(_tree, _tree_timer, delta)
	if _tree_timer >= SETTLE_TIME:
		_tree_timer = 0.0
		# ResetFallingTree (:641-645): destroy and rebuild.
		_tree.free()
		_create_falling_tree()


func _build_impact_overlay() -> void:
	_impact_lines = ImmediateMesh.new()
	var node := MeshInstance3D.new()
	node.name = "Impacts"
	node.mesh = _impact_lines
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true
	material.no_depth_test = true
	node.material_override = material
	add_child(node)

	var ghost_mesh := BoxMesh.new()
	ghost_mesh.size = 2.0 * FALLING_EXTENT
	var ghost_material := StandardMaterial3D.new()
	ghost_material.albedo_color = Color(1.0, 1.0, 0.0, 0.4)  # b3_colorYellow, alpha 0.4
	ghost_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_impact_ghost = MeshInstance3D.new()
	_impact_ghost.name = "ImpactPose"
	_impact_ghost.mesh = ghost_mesh
	_impact_ghost.material_override = ghost_material
	_impact_ghost.visible = false
	add_child(_impact_ghost)

	_box_label = _impact_label(Color(1.0, 1.0, 0.0))
	_tree_label = _impact_label(Color(0.0, 1.0, 1.0))


func _impact_label(color: Color) -> Label3D:
	var label := Label3D.new()
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.font_size = 24
	label.outline_size = 8
	label.modulate = color
	label.no_depth_test = true
	label.visible = false
	add_child(label)
	return label


## DrawImpact (:656-669): a point, an arrow half a metre along the normal and
## the approach speed at its tip.
func _draw_impacts() -> void:
	_impact_lines.clear_surfaces()
	_impact_ghost.visible = not _box_impact.is_empty()
	if _box_impact.is_empty() and _tree_impact.is_empty():
		_box_label.visible = false
		_tree_label.visible = false
		return
	_impact_lines.surface_begin(Mesh.PRIMITIVE_LINES)
	_draw_impact(_box_impact, Color(1.0, 1.0, 0.0), _box_label)
	_draw_impact(_tree_impact, Color(0.0, 1.0, 1.0), _tree_label)
	_impact_lines.surface_end()


func _draw_impact(impact: Dictionary, color: Color, label: Label3D) -> void:
	label.visible = not impact.is_empty()
	if impact.is_empty():
		return
	var point: Vector3 = impact["point"]
	var normal: Vector3 = impact["normal"]
	var tip := point + 0.5 * normal
	var side := normal.cross(Vector3.UP if absf(normal.y) < 0.9 else Vector3.RIGHT).normalized()
	_impact_lines.surface_set_color(color)
	for seg in [[point, tip], [tip, tip - 0.12 * normal + 0.06 * side],
			[tip, tip - 0.12 * normal - 0.06 * side],
			[point - 0.05 * side, point + 0.05 * side]]:
		_impact_lines.surface_add_vertex(seg[0])
		_impact_lines.surface_add_vertex(seg[1])
	label.global_position = tip
	label.text = " %.1f m/s" % float(impact["speed"])


# --- HUD and debug draw, upstream's own readouts -----------------------------

## sample_character.cpp:1592-1598 draws position, velocity, on-ground and
## sprint as screen text; mover.cpp's own HUD is the third-person line. Same
## readouts, as the floating label the rest of this demo uses.
func _build_hud() -> void:
	_hud = Label3D.new()
	_hud.name = "Status"
	_hud.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_hud.font_size = 20
	_hud.outline_size = 8
	_hud.modulate = Color(0.85, 0.95, 1.0)
	_hud.no_depth_test = true
	add_child(_hud)


func _update_hud() -> void:
	var pos := _char.global_position
	var horizontal := Vector2(_velocity.x, _velocity.z).length()
	_hud.global_position = pos + Vector3(0, 1.25, 0)
	_hud.text = "pos %.2f %.2f %.2f\nspeed %.2f m/s   vertical %.2f\non ground: %s   sprint: %s\nclip velocity (C): %s   debug (V): %s" % [
			pos.x, pos.y, pos.z, horizontal, _velocity.y,
			"yes" if _on_ground else "no", "yes" if _sprint else "no",
			"on" if _clip_velocity else "off", "on" if _show_debug else "off"]


## mover.cpp draws three things every frame: the pogo ray (green when it found
## ground, grey when it did not, :157/:171), a marker and normal for every
## collision plane (:332-340), and the velocity vector (:343).
func _build_overlay() -> void:
	_overlay = ImmediateMesh.new()
	var node := MeshInstance3D.new()
	node.name = "MoverDebug"
	node.mesh = _overlay
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true
	material.no_depth_test = true
	node.material_override = material
	add_child(node)


func _draw_overlay() -> void:
	_overlay.clear_surfaces()
	if not _show_debug:
		return
	_overlay.surface_begin(Mesh.PRIMITIVE_LINES)

	_overlay.surface_set_color(Color(0.2, 0.9, 0.3) if _pogo_grounded else Color(0.6, 0.6, 0.6))
	_overlay.surface_add_vertex(_pogo_from)
	_overlay.surface_add_vertex(_pogo_to)

	_overlay.surface_set_color(Color(0.7, 0.4, 0.95))
	_overlay.surface_add_vertex(_char.global_position)
	_overlay.surface_add_vertex(_char.global_position + _velocity)

	_overlay.surface_set_color(Color(0.95, 0.9, 0.2))
	for contact in _char.get_last_collisions():
		var point: Vector3 = contact["position"]
		var normal: Vector3 = contact["normal"]
		_overlay.surface_add_vertex(point)
		_overlay.surface_add_vertex(point + 0.25 * normal)
	_overlay.surface_end()


# --- level pieces built in code ---------------------------------------------

func _static_box(name: String, size: Vector3, position: Vector3, material: StandardMaterial3D,
		rotation_axis := Vector3.UP, angle := 0.0) -> Box3DBody:
	var body := Box3DBody.new()
	body.name = name
	body.body_type = Box3DBody.STATIC
	body.box_size = size
	body.transform = Transform3D(Basis(rotation_axis, angle), position)
	var mesh := BoxMesh.new()
	mesh.size = size
	var visual := MeshInstance3D.new()
	visual.mesh = mesh
	visual.material_override = material
	body.add_child(visual)
	_world.add_child(body)
	return body


func _material(color: Color, roughness := 0.75) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = roughness
	return material


## Stand-in for upstream's `data/meshes/stairs.obj` at (-10, 0, 0)
## (sample_character.cpp:364-374), which this repo does not vendor. Ten 0.25 m
## steps: high enough that the pogo spring, not a step-up hack, is what gets
## the capsule up them. Kept 2 m wide so it clears the step-height lips the
## Rigid Body sample puts at x = -8.
func _build_stairs() -> void:
	var material := _material(Color(0.46, 0.48, 0.44), 0.8)
	for i in range(10):
		var rise := 0.25 * (i + 1)
		_static_box("Step%d" % i, Vector3(2.0, rise, 0.6),
				Vector3(-10.0, 0.5 * rise, 0.3 + 0.6 * i), material)


## b3CreateTorusMesh(10, 12, 2, 1) at (-10, 1, -8), turned a quarter turn about
## Y and given upstream's (-0.75, 1.5, 0.5) mesh scale
## (sample_character.cpp:377-387). b3CreateMeshShape applies that scale to the
## points without re-winding, so it is baked into the vertices here the same
## way -- including the mirroring negative x.
func _build_torus() -> void:
	var geometry: Dictionary = Box3DGeometry.create_torus_mesh(10, 12, 2.0, 1.0)
	var scale := Vector3(-0.75, 1.5, 0.5)
	var points: PackedVector3Array = geometry["vertices"]
	for i in points.size():
		points[i] = points[i] * scale
	geometry["vertices"] = points

	var torus := Box3DBody.new()
	torus.name = "Torus"
	torus.body_type = Box3DBody.STATIC
	torus.shape_type = Box3DBody.MESH
	torus.mesh_vertices = points
	torus.mesh_indices = geometry["indices"]
	torus.transform = Transform3D(Basis(Vector3.UP, 0.5 * PI), Vector3(-10.0, 1.0, -8.0))

	var visual := MeshInstance3D.new()
	visual.mesh = Box3DGeometry.make_array_mesh(geometry)
	var material := _material(Color(0.55, 0.35, 0.7), 0.5)
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	visual.material_override = material
	torus.add_child(visual)
	_world.add_child(torus)


## The obstacle course upstream's Rigid Body character builds on the same level
## (sample_character.cpp:1400-1480): a 20 degree ramp, a 50 degree ramp that is
## too steep to stand on, three platforms with gaps between them, five lips of
## increasing height, a wall, three boxes to push and a sphere. Upstream's
## colours (olive drab, indian red, slate gray, cornflower blue, dark slate
## gray, gold, orange) come along.
func _build_obstacle_course() -> void:
	# Ramp and steep ramp: b3MakeQuatFromAxisAngle(axisZ, -20 / -50 degrees).
	_static_box("Ramp", Vector3(6.0, 0.3, 3.0), Vector3(6.0, 1.0, 4.0),
			_material(Color(0.4196, 0.5569, 0.1373)), Vector3.BACK, deg_to_rad(-20.0))
	_static_box("SteepRamp", Vector3(5.0, 0.3, 3.0), Vector3(6.0, 2.0, -4.0),
			_material(Color(0.8039, 0.3608, 0.3608)), Vector3.BACK, deg_to_rad(-50.0))

	var platform_material := _material(Color(0.4392, 0.502, 0.5647))
	for i in range(3):
		_static_box("Platform%d" % i, Vector3(2.4, 0.3, 2.4),
				Vector3(-4.0 + 3.5 * i, 1.2, -5.0), platform_material)

	# Step-height test: lips of 0.05 + 0.08 * i half height, so each one's top
	# is at twice that and the capsule has to clear an increasing edge.
	var lip_material := _material(Color(0.3922, 0.5843, 0.9294))
	for i in range(5):
		var lip := 0.05 + 0.08 * i
		_static_box("Lip%d" % i, Vector3(2.0, 2.0 * lip, 1.2),
				Vector3(-8.0, lip, -1.0 + 2.0 * i), lip_material)

	_static_box("Wall", Vector3(8.0, 3.0, 0.4), Vector3(0.0, 1.5, 10.0),
			_material(Color(0.1843, 0.3098, 0.3098)))

	# Three dynamic boxes to push around, and a dynamic sphere.
	var box_material := _material(Color(1.0, 0.8431, 0.0), 0.45)
	for i in range(3):
		var crate := Box3DBody.new()
		crate.name = "Crate%d" % i
		crate.box_size = Vector3(0.8, 0.8, 0.8)
		crate.density = 1000.0
		crate.angular_damping = 0.0
		crate.position = Vector3(3.0 + 1.5 * i, 0.5, 0.0)
		var mesh := BoxMesh.new()
		mesh.size = crate.box_size
		var visual := MeshInstance3D.new()
		visual.mesh = mesh
		visual.material_override = box_material
		crate.add_child(visual)
		_world.add_child(crate)

	var sphere := Box3DBody.new()
	sphere.name = "OrangeBall"
	sphere.shape_type = Box3DBody.SPHERE
	sphere.sphere_radius = 0.5
	sphere.density = 1000.0
	sphere.angular_damping = 0.0
	sphere.position = Vector3(-3.0, 1.0, 0.0)
	var sphere_mesh := SphereMesh.new()
	sphere_mesh.radius = 0.5
	sphere_mesh.height = 1.0
	var sphere_visual := MeshInstance3D.new()
	sphere_visual.mesh = sphere_mesh
	sphere_visual.material_override = _material(Color(1.0, 0.647, 0.0), 0.45)
	sphere.add_child(sphere_visual)
	_world.add_child(sphere)


## The wave height field is authored on the Terrain node; this is the matching
## surface to look at. height(i, j) = sin(2*PI*rowFreq*i) * sin(2*PI*colFreq*j)
## with the grid point at scale * (j, height, i) (src/height_field.c:1384-1444),
## and b3CreateWave punches out every 16th cell when makeHoles is on (:1417) --
## those cells are missing from the collider too, so they are missing here.
func _build_terrain_visual() -> void:
	var terrain: Box3DBody = $Box3DWorld/Terrain
	var count_x: int = terrain.height_field_size.x
	var count_z: int = terrain.height_field_size.y
	var scale: Vector3 = terrain.height_field_scale
	var wave: Vector2 = terrain.height_field_wave

	var verts := PackedVector3Array()
	verts.resize(count_x * count_z)
	for i in count_z:
		var row := sin(TAU * wave.y * i)
		for j in count_x:
			verts[i * count_x + j] = Vector3(j * scale.x, row * sin(TAU * wave.x * j) * scale.y, i * scale.z)

	var indices := PackedInt32Array()
	for i in count_z - 1:
		for j in count_x - 1:
			var cell := i * (count_x - 1) + j
			if terrain.height_field_holes and cell > 0 and cell % 16 == 0:
				continue
			var i11 := i * count_x + j
			var i12 := i11 + 1
			var i21 := i11 + count_x
			var i22 := i21 + 1
			indices.append_array([i11, i21, i12, i12, i21, i22])

	# Wound box3d's way and handed to the one bridge that knows how to turn
	# that into a Godot surface, as every other hand-built surface in the demo
	# now is.
	var visual := MeshInstance3D.new()
	visual.name = "TerrainMesh"
	visual.mesh = Box3DGeometry.make_array_mesh({"vertices": verts, "indices": indices})
	visual.material_override = _material(Color(0.35, 0.45, 0.38))
	terrain.add_child(visual)
