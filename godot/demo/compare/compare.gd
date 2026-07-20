extends Node3D

## Physics-engine comparison harness.
##
## Builds one benchmark scenario with EITHER this repo's Box3D GDExtension OR
## Godot's native 3D physics (GodotPhysics or Jolt, whichever the project
## setting selects), behind a FIXED camera and a big video overlay. Because a
## single seeded builder emits the geometry and every body gets the same size,
## mass, friction, restitution, gravity and 60 Hz timestep, the two runs line up
## frame-for-frame in a side-by-side recording and the only variable is the
## solver. See compare/README.md and tools/compare.sh.
##
## Launch directly:
##   godot --path godot/demo res://compare/compare.tscn -- --engine=jolt --scenario=pyramid
##
## engine   = box3d | godot | jolt
##   box3d  uses Box3DWorld / Box3DBody (the GDExtension); the native physics
##          engine project setting is irrelevant to it.
##   godot / jolt build native RigidBody3D / StaticBody3D. WHICH native server
##          runs is decided at startup by physics/3d/physics_engine — the
##          launcher writes that via override.cfg; the overlay reports back the
##          setting actually in force as proof.
## scenario = pyramid | pile | stir | chain

# ---- Matched simulation parameters (applied to BOTH backends) --------------
const BOX := Vector3(1, 1, 1)   # unit cube, full extents (Box3D box_size == BoxShape3D.size)
const DENSITY := 1.0            # Box3D density; native mass = DENSITY * volume
const FRICTION := 0.6           # Box3D's own default, set explicitly on native too
const RESTITUTION := 0.0
const SUBSTEPS := 4             # Box3D solver substeps (native has no exact equal)
const WORKERS := 4              # Box3D solver worker threads (see README)
const GRAVITY := 9.8            # m/s^2, downward, matching project default_gravity

const SEED := 1337

# ---- Per-scenario body counts ---------------------------------------------
const PYRAMID_BASE := 14        # square pyramid, base^..1 -> 1015 boxes
const PILE_X := 12
const PILE_Z := 12
const PILE_Y := 8               # 1152 boxes dropped into a bin
const STIR_X := 14
const STIR_Z := 14
const STIR_Y := 4               # 784 boxes churned by a rotating paddle
const CHAIN_COUNT := 20
const CHAIN_LINKS := 25         # 500 hanging links + 500 joints

# Frame (physics tick) at which the pyramid's wrecking ball is launched.
const COLLAPSE_FRAME := 90

var engine := "box3d"
var scenario := "pyramid"

var _native := false            # true for godot/jolt
var _rng := RandomNumberGenerator.new()
var _stage: Node3D              # Box3DWorld (box3d) or a plain container (native)
var _dynamic: Array[Node] = []  # dynamic bodies, for counting + speed proof
var _stir_bars: Array[Node] = []  # kinematic paddle bars (stir scenario)
var _sim_frame := 0
var _collapsed := false

var _box_meshes := {}           # size string -> BoxMesh (shared per size)
var _palette: Array[StandardMaterial3D] = []
var _phys_mat: PhysicsMaterial  # native friction/restitution

@onready var _camera: Camera3D = $Camera3D
@onready var _overlay = $UI/Overlay

# Eye / look-at per scenario, identical across engines so recordings register.
const VIEWS := {
	"pyramid": [Vector3(0, 9.5, 27), Vector3(0, 5, 0)],
	"pile": [Vector3(0.1, 13, 27), Vector3(0, 3, 0)],
	"stir": [Vector3(0.1, 17, 24), Vector3(0, 1.5, 0)],
	"chain": [Vector3(0.1, 4, 26), Vector3(0, -3, 0)],
}

const ACCENTS := {
	"box3d": Color(0.35, 0.85, 1.0),
	"godot": Color(0.45, 0.7, 1.0),
	"jolt": Color(1.0, 0.62, 0.2),
}


func _ready() -> void:
	_parse_args()
	_native = engine != "box3d"
	_rng.seed = SEED
	_build_palette()
	if _native:
		_phys_mat = PhysicsMaterial.new()
		_phys_mat.friction = FRICTION
		_phys_mat.bounce = RESTITUTION
		_phys_mat.rough = false
		_phys_mat.absorbent = false

	_setup_stage()
	match scenario:
		"pile": _build_pile()
		"stir": _build_stir()
		"chain": _build_chain()
		_: _build_pyramid()

	_frame_camera()
	_setup_overlay()
	_print_proof()


func _parse_args() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--engine="):
			engine = arg.get_slice("=", 1).to_lower()
		elif arg.begins_with("--scenario="):
			scenario = arg.get_slice("=", 1).to_lower()
	if engine not in ["box3d", "godot", "jolt"]:
		engine = "box3d"
	if scenario not in VIEWS:
		scenario = "pyramid"


# --- Engine identity / proof ------------------------------------------------

## Human name for the engine actually running. For native runs this is derived
## from the live project setting, not the requested arg, so a missing override
## shows the truth.
func _engine_display() -> String:
	if not _native:
		return "Box3D"
	return _native_engine_name()


func _native_engine_name() -> String:
	var setting := str(ProjectSettings.get_setting("physics/3d/physics_engine", "DEFAULT"))
	if setting == "Jolt Physics":
		return "Jolt Physics"
	# "DEFAULT" and "GodotPhysics" both resolve to the built-in server.
	return "Godot Physics"


func _engine_proof() -> String:
	if not _native:
		return "Box3D GDExtension  ·  b3World_Step, substeps=%d, %d workers" % [SUBSTEPS, WORKERS]
	var setting := str(ProjectSettings.get_setting("physics/3d/physics_engine", "DEFAULT"))
	return "native PhysicsServer3D  ·  physics/3d/physics_engine = \"%s\"" % setting


## Loud, greppable startup proof for headless verification.
func _print_proof() -> void:
	print("[compare] engine=%s scenario=%s bodies=%d ticks/s=%d" % [
			engine, scenario, _dynamic.size(), Engine.physics_ticks_per_second])
	print("[compare] ENGINE PROOF: %s -> %s" % [_engine_display(), _engine_proof()])
	if _native and engine == "jolt" and _native_engine_name() != "Jolt Physics":
		push_warning("[compare] requested jolt but the live engine is %s "
				% _native_engine_name() + "(override.cfg missing?)")


# --- Overlay / camera -------------------------------------------------------

func _setup_overlay() -> void:
	_overlay.accent = ACCENTS.get(engine, Color.WHITE)
	_overlay.engine_title = _engine_display()
	_overlay.engine_proof = _engine_proof()
	_overlay.scenario_title = "%s   ·   %d dynamic bodies   ·   %d Hz  substeps %d" % [
			scenario.capitalize(), _dynamic.size(),
			Engine.physics_ticks_per_second, SUBSTEPS]


func _frame_camera() -> void:
	var view: Array = VIEWS[scenario]
	_camera.position = view[0]
	_camera.look_at(view[1], Vector3.UP)


# --- Stage (physics world container) ---------------------------------------

func _setup_stage() -> void:
	if _native:
		_stage = Node3D.new()
		_stage.name = "NativeStage"
		add_child(_stage)
	else:
		var world := Box3DWorld.new()
		world.name = "Box3DWorld"
		world.gravity = Vector3(0, -GRAVITY, 0)
		world.substep_count = SUBSTEPS
		world.worker_count = WORKERS
		_stage = world
		add_child(world)


# --- Body factories (backend-agnostic) -------------------------------------

func _box_mesh(size: Vector3) -> BoxMesh:
	var key := str(size)
	if not _box_meshes.has(key):
		var m := BoxMesh.new()
		m.size = size
		_box_meshes[key] = m
	return _box_meshes[key]


func _mat(i: int) -> StandardMaterial3D:
	return _palette[i % _palette.size()]


func _build_palette() -> void:
	for i in 24:
		var m := StandardMaterial3D.new()
		m.albedo_color = Color.from_hsv(float(i) / 24.0, 0.5, 0.95)
		m.roughness = 0.8
		_palette.append(m)


## Spawn an axis-aligned box. `kind`: 0 static, 1 dynamic, 2 kinematic.
func _spawn_box(pos: Vector3, kind: int, size := BOX, color_idx := -1,
		mat_override: Material = null) -> Node:
	var mesh := MeshInstance3D.new()
	mesh.mesh = _box_mesh(size)
	if mat_override != null:
		mesh.material_override = mat_override
	elif color_idx >= 0:
		mesh.material_override = _mat(color_idx)

	if _native:
		var body: PhysicsBody3D
		match kind:
			1:
				var rb := RigidBody3D.new()
				rb.mass = DENSITY * size.x * size.y * size.z
				rb.physics_material_override = _phys_mat
				body = rb
			2:
				body = AnimatableBody3D.new()
			_:
				var sb := StaticBody3D.new()
				sb.physics_material_override = _phys_mat
				body = sb
		var cs := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = size
		cs.shape = shape
		body.add_child(cs)
		body.add_child(mesh)
		body.transform = Transform3D(Basis(), pos)
		_stage.add_child(body)
		if kind == 1:
			_dynamic.append(body)
		return body

	var b := Box3DBody.new()
	b.body_type = [Box3DBody.STATIC, Box3DBody.DYNAMIC, Box3DBody.KINEMATIC][kind]
	b.shape_type = Box3DBody.BOX
	b.box_size = size
	b.density = DENSITY
	b.friction = FRICTION
	b.restitution = RESTITUTION
	b.add_child(mesh)
	b.position = pos
	_stage.add_child(b)
	if kind == 1:
		_dynamic.append(b)
	return b


## Spawn a dynamic sphere (the pyramid's wrecking ball).
func _spawn_sphere(pos: Vector3, radius: float, density: float, mat: Material) -> Node:
	var mesh := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = radius
	sm.height = radius * 2.0
	mesh.mesh = sm
	mesh.material_override = mat

	if _native:
		var rb := RigidBody3D.new()
		rb.mass = density * (4.0 / 3.0 * PI * radius * radius * radius)
		rb.physics_material_override = _phys_mat
		rb.continuous_cd = true
		var cs := CollisionShape3D.new()
		var shape := SphereShape3D.new()
		shape.radius = radius
		cs.shape = shape
		rb.add_child(cs)
		rb.add_child(mesh)
		rb.transform = Transform3D(Basis(), pos)
		_stage.add_child(rb)
		return rb

	var b := Box3DBody.new()
	b.body_type = Box3DBody.DYNAMIC
	b.shape_type = Box3DBody.SPHERE
	b.sphere_radius = radius
	b.density = density
	b.friction = FRICTION
	b.restitution = RESTITUTION
	b.continuous = true
	b.add_child(mesh)
	b.position = pos
	_stage.add_child(b)
	return b


func _set_velocity(body: Node, v: Vector3) -> void:
	if _native:
		(body as RigidBody3D).linear_velocity = v
	else:
		body.set_linear_velocity(v)


func _speed(body: Node) -> float:
	if not is_instance_valid(body):
		return 0.0
	if _native:
		return (body as RigidBody3D).linear_velocity.length()
	return body.get_linear_velocity().length()


# --- Floor / walls ----------------------------------------------------------

var _floor_mat: StandardMaterial3D
var _wall_mat: StandardMaterial3D


func _ground_materials() -> void:
	if _floor_mat == null:
		_floor_mat = StandardMaterial3D.new()
		_floor_mat.albedo_color = Color(0.2, 0.22, 0.26)
		_floor_mat.roughness = 0.55
		_floor_mat.metallic = 0.1
		_wall_mat = StandardMaterial3D.new()
		_wall_mat.albedo_color = Color(0.28, 0.3, 0.34, 0.5)
		_wall_mat.roughness = 0.5
		_wall_mat.flags_transparent = true


func _build_floor(extent: float) -> void:
	_ground_materials()
	_spawn_box(Vector3(0, -0.5, 0), 0, Vector3(extent, 1, extent), -1, _floor_mat)


func _build_bin(inner: float, wall_h: float) -> void:
	_ground_materials()
	var t := 1.0        # wall thickness
	var h := wall_h
	var half := inner / 2.0 + t / 2.0
	for s in [Vector3(1, 0, 0), Vector3(-1, 0, 0), Vector3(0, 0, 1), Vector3(0, 0, -1)]:
		var along_x := absf(s.x) > 0.0
		var size := Vector3(t, h, inner + 2.0 * t) if along_x else Vector3(inner + 2.0 * t, h, t)
		_spawn_box(s * half + Vector3(0, h / 2.0, 0), 0, size, -1, _wall_mat)


# --- Scenarios --------------------------------------------------------------

## Solid square pyramid, then a heavy sphere fired into it at COLLAPSE_FRAME.
func _build_pyramid() -> void:
	_build_floor(40.0)
	var s := 1.02  # spacing (slight gap avoids initial interpenetration)
	var idx := 0
	for layer in PYRAMID_BASE:
		var n := PYRAMID_BASE - layer
		var y := 0.55 + layer * s
		var start := -(n - 1) * s / 2.0
		for i in n:
			for j in n:
				_spawn_box(Vector3(start + i * s, y, start + j * s), 1, BOX, idx)
				idx += 1


## Rain 1152 boxes from a staggered grid into a walled bin; they settle.
func _build_pile() -> void:
	_build_floor(40.0)
	_build_bin(15.0, 7.0)
	var s := 1.06
	var idx := 0
	for gy in PILE_Y:
		var y := 6.5 + gy * 1.3
		var ox := (-(PILE_X - 1) * s / 2.0)
		var oz := (-(PILE_Z - 1) * s / 2.0)
		for gx in PILE_X:
			for gz in PILE_Z:
				# Small deterministic jitter so the pile doesn't fall as a lattice.
				var jx := _rng.randf_range(-0.08, 0.08)
				var jz := _rng.randf_range(-0.08, 0.08)
				_spawn_box(Vector3(ox + gx * s + jx, y, oz + gz * s + jz), 1, BOX, idx)
				idx += 1


## A dense bed of boxes churned by a rotating kinematic paddle.
func _build_stir() -> void:
	_build_floor(40.0)
	_build_bin(16.0, 5.0)
	var s := 1.05
	var idx := 0
	for gy in STIR_Y:
		var y := 0.6 + gy * 1.05
		var ox := (-(STIR_X - 1) * s / 2.0)
		var oz := (-(STIR_Z - 1) * s / 2.0)
		for gx in STIR_X:
			for gz in STIR_Z:
				var jx := _rng.randf_range(-0.06, 0.06)
				var jz := _rng.randf_range(-0.06, 0.06)
				_spawn_box(Vector3(ox + gx * s + jx, y, oz + gz * s + jz), 1, BOX, idx)
				idx += 1
	# Cross-shaped paddle: two kinematic bars we rotate about Y every physics
	# tick (see _physics_process). Kept as a 90-degree pair so the bed churns
	# in both axes rather than being swept by a single line.
	var bar_mat := StandardMaterial3D.new()
	bar_mat.albedo_color = Color(0.85, 0.2, 0.2)
	bar_mat.roughness = 0.4
	var bar_size := Vector3(15, 2.0, 1.2)
	_stir_bars = [
		_spawn_box(Vector3(0, 1.6, 0), 2, bar_size, -1, bar_mat),
		_spawn_box(Vector3(0, 1.6, 0), 2, bar_size, -1, bar_mat),
	]


## Rows of hanging chains: dynamic links joined by ball / pin joints, the top
## of each chain anchored to the world.
func _build_chain() -> void:
	var anchor: StaticBody3D = null
	if _native:
		# One shared static anchor; each PinJoint3D pins at its own global point.
		anchor = StaticBody3D.new()
		anchor.name = "ChainAnchor"
		_stage.add_child(anchor)
	var link := Vector3(0.6, 0.6, 0.6)
	var gap := 0.72
	var spacing := 2.2
	var x0 := -(CHAIN_COUNT - 1) * spacing / 2.0
	for c in CHAIN_COUNT:
		var x := x0 + c * spacing
		var top_y := 2.0
		var prev: Node = null
		for l in CHAIN_LINKS:
			var y := top_y - l * gap
			var body := _spawn_box(Vector3(x, y, 0), 1, link, c)
			var pin_y := y + gap / 2.0
			if prev == null:
				_join(anchor, body, Vector3(x, pin_y, 0))  # world/anchor -> first link
			else:
				_join(prev, body, Vector3(x, pin_y, 0))
			prev = body


## Pin `a` to `b` at world point `at`. `a` null means anchor to the world.
func _join(a: Node, b: Node, at: Vector3) -> void:
	if _native:
		var j := PinJoint3D.new()
		j.position = at
		_stage.add_child(j)
		# node_a empty -> world; else the two bodies.
		if a != null:
			j.node_a = j.get_path_to(a)
		j.node_b = j.get_path_to(b)
	else:
		var j := Box3DBallJoint.new()
		j.position = at
		_stage.add_child(j)
		# body_b empty anchors to the world at this node's position.
		if a == null:
			j.body_a = j.get_path_to(b)
		else:
			j.body_a = j.get_path_to(a)
			j.body_b = j.get_path_to(b)


# --- Per-tick drivers -------------------------------------------------------

func _physics_process(_delta: float) -> void:
	_sim_frame += 1

	if scenario == "pyramid" and not _collapsed and _sim_frame >= COLLAPSE_FRAME:
		_collapsed = true
		var ball_mat := StandardMaterial3D.new()
		ball_mat.albedo_color = Color(0.95, 0.85, 0.25)
		ball_mat.metallic = 0.3
		ball_mat.roughness = 0.3
		# Fired on a fairly flat arc into the pyramid's midriff — deterministic,
		# and identical across engines.
		var from := Vector3(0, 7.5, 19)
		var ball := _spawn_sphere(from, 1.4, 6.0, ball_mat)
		_set_velocity(ball, Vector3(0, -0.2, -1).normalized() * 33.0)

	if scenario == "stir" and not _stir_bars.is_empty():
		# Spin the paddle steadily about Y; the kinematic bars carry the bed.
		var yaw := _sim_frame * (1.1 / Engine.physics_ticks_per_second)
		for k in _stir_bars.size():
			var xf := Transform3D(Basis(Vector3.UP, yaw + k * (PI / 2.0)),
					Vector3(0, 1.6, 0))
			(_stir_bars[k] as Node3D).global_transform = xf

	# Feed the overlay (body count is stable after build; cheap to set).
	if _overlay != null:
		_overlay.bodies = _dynamic.size()

	# Greppable proof that stepping actually moved bodies (headless checks this).
	if _sim_frame == 60 or _sim_frame == 150:
		var n := mini(_dynamic.size(), 60)
		var total := 0.0
		for i in n:
			total += _speed(_dynamic[i])
		var mean := total / maxf(n, 1)
		print("[compare] frame %d mean_speed(first %d)=%.3f m/s" % [_sim_frame, n, mean])
