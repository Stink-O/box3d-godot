extends Node3D

## Rope Bridge -- a sagging plank bridge slung across a 14 m deep ravine.
##
## The deck is a chain of dynamic planks tied plank to plank by taut-only
## ropes: distance joints whose spring is on at 0 Hz (so no spring force) and
## whose limit runs from 0 to the rope length, which lets a rope go slack but
## never stretch. Each rope is cut a few millimetres shorter than the gap it
## spans (Prestretch), so the deck settles close to the parabola it is laid
## in instead of dropping into a deeper curve. Netting panels are welded on
## along both edges, two hand ropes of capsule links run between four posts on
## ball joints with a little friction, and every fourth plank hangs from the
## nearest hand rope link by a slack cord.
##
## The deck ropes run at constraint_hertz 120 with 8 substeps. Box3D's
## default 60 lets the prestretched deck settle at roughly twice the laid sag;
## 120 is the stiffest a joint honours at 8 substeps (a quarter of the substep
## rate), and stiffer than that makes the planks buzz.
##
## Sag, Prestretch and Plank damping are sidebar dials; each rebuilds the
## bridge. Activate drops a crate onto the middle of the span.

const Despawn = preload("res://common/despawn.gd")
const GROUND_GRID := preload("res://common/ground_grid.tres")

const SPAN := 10.0              ## cliff face to cliff face
const EDGE := 5.0               ## |x| of the cliff faces
const DEPTH := 14.0             ## ravine floor below the cliff tops
const CLIFF := Vector3(145.0, 20.0, 300.0)
const FLOOR_THICK := 2.0
const BOULDERS := 14
const SILL := Vector3(0.3, 0.12, 1.0)
const SILL_X := 5.15
const SILL_PROUD := 0.02
const POST_X := 5.25
const POST_Z := 0.62
const POST_R := 0.09
const POST_LEN := 1.85
const POST_ABOVE := 1.25
const PLANK := Vector3(0.24, 0.05, 1.0)
const PLANK_MASS := 10.0
const PLANK_PITCH := 0.30       ## plank count = floor((arc - 0.1) / PLANK_PITCH)
const ROPE_IN := 0.06           ## deck ropes tied this far in from each plank end
const DECK_Y := -0.025          ## deck centre line at the cliff edges (plank tops level with the cliff)
const NET := Vector3(0.22, 0.5, 0.02)
const NET_MASS := 1.0
const NET_SKIN := 0.006
const HAND_Y := 1.2
const LINK_R := 0.022
const LINK_LEN := 0.5
const LINK_MASS := 1.5
const HAND_SLACK := 1.02        ## sets the link count: round(1.02 * straight / LINK_LEN)
const HAND_SAG := 0.85          ## hand rope sag, as a fraction of the deck sag
const LINK_FRICTION := 1.5      ## N m of friction torque at every link joint
const CORD_EVERY := 4
const CORD_SLACK := 0.03
const ROPE_R := 0.018
const CORD_R := 0.01
const ROPE_HERTZ := 120.0
const SUBSTEPS := 8
const CRATE := Vector3(0.5, 0.5, 0.5)
const CRATE_DENSITY := 400.0
const CRATE_LIFETIME := 30.0

const SAG_RANGE := Vector2(0.3, 2.0)
const PRESTRETCH_RANGE := Vector2(0.0, 0.02)
const DAMPING_RANGE := Vector2(0.0, 2.0)

var camera_home := Vector3(-2.5, 3.0, 13.0)
var camera_look_at := Vector3(0.0, -2.5, 0.0)

var _sag := 0.5
var _prestretch := 0.008
var _damping := 0.4

var _bridge: Node3D
var _planks: Array[Box3DBody] = []
var _plank_frames: Array[Transform3D] = []
var _ropes: Array = []          ## [joint, body_a, local_a, body_b, local_b, mesh]
var _links := {}                ## side (-1 / +1) -> Array of link bodies
var _arc := 0.0
var _joint_serial := 0

var _wood := _material(Color(0.55, 0.4, 0.26), 0.85)
var _post_wood := _material(Color(0.42, 0.3, 0.2), 0.85)
var _rope := _material(Color(0.72, 0.62, 0.45), 0.95)
var _net := _material(Color(0.75, 0.68, 0.52), 0.95)
var _stone := _material(Color(0.42, 0.42, 0.44), 0.95)
var _rock := _material(Color(0.33, 0.32, 0.31), 1.0)
var _crate := _material(Color(0.62, 0.5, 0.32), 0.8)

@onready var _world: Box3DWorld = $Box3DWorld
@onready var _label: Label3D = $Status


func _ready() -> void:
	_world.substep_count = SUBSTEPS
	_build_ravine()
	_rebuild()


## Drops a crate onto the middle of the span.
func activate() -> void:
	var crate := Box3DBody.new()
	crate.name = "Crate"
	crate.box_size = CRATE
	crate.density = CRATE_DENSITY
	crate.friction = 0.7
	crate.position = Vector3(randf_range(-1.0, 1.0), 3.0, randf_range(-0.2, 0.2))
	crate.add_child(_mesh_box(CRATE, _crate))
	_world.add_child(crate)
	Despawn.attach(crate, CRATE_LIFETIME)


# --- ravine and bridge heads ------------------------------------------------

func _build_ravine() -> void:
	var ravine := Node3D.new()
	ravine.name = "Ravine"
	_world.add_child(ravine)
	for side in [-1.0, 1.0]:
		var cliff := _static_box(ravine, "Cliff%s" % _side_name(side), CLIFF,
				Vector3(side * (EDGE + CLIFF.x * 0.5), -CLIFF.y * 0.5, 0.0), _rock, 0.8)
		# The grid goes on the top only, so the faces read as rock and the
		# drop is visible; it sits a millimetre proud to keep clear of the
		# box's own top face.
		var top := PlaneMesh.new()
		top.size = Vector2(CLIFF.x, CLIFF.z)
		var top_visual := _mesh_instance(top, GROUND_GRID)
		top_visual.position.y = CLIFF.y * 0.5 + 0.001
		cliff.add_child(top_visual)
	# The floor runs 1 m into each cliff, so no gap opens at its ends.
	_static_box(ravine, "RavineFloor", Vector3(SPAN + 2.0, FLOOR_THICK, CLIFF.z),
			Vector3(0.0, -DEPTH - FLOOR_THICK * 0.5, 0.0), _stone, 0.8)
	# A fixed seed, so the boulders land in the same place on every load.
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for n in BOULDERS:
		var s := rng.randf_range(0.5, 1.8)
		var size := Vector3(s, s * rng.randf_range(0.4, 0.8), s * rng.randf_range(0.7, 1.3))
		var x := rng.randf_range(-4.2, 4.2)
		var z := rng.randf_range(-14.0, 14.0)
		var yaw := rng.randf_range(-PI, PI)
		# Bedded a quarter of its height into the floor.
		var boulder := _static_box(ravine, "Boulder%d" % n, size,
				Vector3(x, -DEPTH + size.y * 0.25, z), _stone, 0.8)
		boulder.basis = Basis(Vector3.UP, yaw)


## A heavy timber sill across each bridge head and four posts.
func _build_heads() -> void:
	for side in [-1.0, 1.0]:
		_static_box(_bridge, "Sill%s" % _side_name(side), SILL,
				Vector3(side * SILL_X, SILL_PROUD - SILL.y * 0.5, 0.0), _post_wood, 0.9)
		for zs in [-1.0, 1.0]:
			var post := Box3DBody.new()
			post.name = _post_name(side, zs)
			post.body_type = Box3DBody.STATIC
			post.shape_type = Box3DBody.CYLINDER
			post.capsule_radius = POST_R
			post.capsule_height = POST_LEN
			post.friction = 0.8
			post.position = Vector3(side * POST_X, POST_ABOVE - POST_LEN * 0.5, zs * POST_Z)
			var mesh := CylinderMesh.new()
			mesh.top_radius = POST_R
			mesh.bottom_radius = POST_R
			mesh.height = POST_LEN
			mesh.radial_segments = 12
			post.add_child(_mesh_instance(mesh, _post_wood))
			_bridge.add_child(post)


func _side_name(side: float) -> String:
	return "Near" if side < 0.0 else "Far"


func _post_name(side: float, zs: float) -> String:
	return "Post%s%s" % [_side_name(side), "L" if zs < 0.0 else "R"]


# --- the deck ----------------------------------------------------------------

## Parabola through the deck ends: centre-line height at x.
func _deck_y(x: float) -> float:
	return DECK_Y - _sag * (1.0 - (x / EDGE) * (x / EDGE))


func _deck_slope(x: float) -> float:
	return 2.0 * _sag * x / (EDGE * EDGE)


## x at arc length `s` from the near edge along the parabola (tabulated,
## linear between samples).
func _x_at_arc(table: PackedFloat64Array, s: float) -> float:
	var n := table.size() - 1
	for i in n:
		if table[i + 1] >= s:
			var f := (s - table[i]) / maxf(table[i + 1] - table[i], 1e-9)
			return -EDGE + (float(i) + f) * SPAN / n
	return EDGE


func _build_deck() -> void:
	var steps := 2000
	var table := PackedFloat64Array()
	table.resize(steps + 1)
	table[0] = 0.0
	for i in steps:
		var x0 := -EDGE + SPAN * i / steps
		var x1 := -EDGE + SPAN * (i + 1) / steps
		table[i + 1] = table[i] + Vector2(x1 - x0, _deck_y(x1) - _deck_y(x0)).length()
	_arc = table[steps]
	var count := int(floor((_arc - 0.1) / PLANK_PITCH))
	var gap := (_arc - PLANK.x * count) / float(count + 1)
	for i in count:
		var s := gap + PLANK.x * 0.5 + i * (PLANK.x + gap)
		var x := _x_at_arc(table, s)
		var frame := Transform3D(Basis(Vector3.BACK, atan(_deck_slope(x))), Vector3(x, _deck_y(x), 0.0))
		_plank_frames.append(frame)
		_planks.append(_build_plank(i, frame))
	# Deck ropes: near sill -> plank 0 -> ... -> plank n-1 -> far sill, one
	# along each edge.
	var sill_near: Box3DBody = _bridge.get_node("SillNear")
	var sill_far: Box3DBody = _bridge.get_node("SillFar")
	for zs in [-1.0, 1.0]:
		var z: float = zs * (PLANK.z * 0.5 - ROPE_IN)
		_tie(sill_near, Vector3(-EDGE, DECK_Y, z), _planks[0], _edge_point(0, -1.0, z))
		for i in range(count - 1):
			_tie(_planks[i], _edge_point(i, 1.0, z), _planks[i + 1], _edge_point(i + 1, -1.0, z))
		_tie(_planks[count - 1], _edge_point(count - 1, 1.0, z), sill_far, Vector3(EDGE, DECK_Y, z))


## One plank, with a netting panel standing on each end and welded on.
func _build_plank(i: int, frame: Transform3D) -> Box3DBody:
	var plank := Box3DBody.new()
	plank.name = "Plank%d" % i
	plank.box_size = PLANK
	plank.density = PLANK_MASS / (PLANK.x * PLANK.y * PLANK.z)
	plank.friction = 0.9
	plank.angular_damping = 0.6
	plank.linear_damping = _damping
	plank.transform = frame
	plank.add_child(_mesh_box(PLANK, _wood))
	_bridge.add_child(plank)
	for zs in [-1.0, 1.0]:
		var local := Vector3(0.0, PLANK.y * 0.5 + NET.y * 0.5 + NET_SKIN,
				zs * (PLANK.z * 0.5 - NET.z * 0.5 - NET_SKIN))
		var panel := Box3DBody.new()
		panel.name = "Net%d%s" % [i, "L" if zs < 0.0 else "R"]
		panel.box_size = NET
		panel.density = NET_MASS / (NET.x * NET.y * NET.z)
		panel.friction = 0.6
		panel.transform = Transform3D(frame.basis, frame * local)
		panel.add_child(_mesh_box(NET, _net))
		_bridge.add_child(panel)
		var weld := Box3DFixedJoint.new()
		weld.name = "NetWeld%d%s" % [i, "L" if zs < 0.0 else "R"]
		weld.transform = Transform3D(frame.basis, frame * Vector3(0.0, PLANK.y * 0.5, local.z))
		weld.body_a = NodePath("../" + String(plank.name))
		weld.body_b = NodePath("../" + String(panel.name))
		_bridge.add_child(weld)
	return plank


## A deck-rope tie point (world) on plank i's leading (+1) or trailing (-1)
## edge, at mid-thickness.
func _edge_point(i: int, along: float, z: float) -> Vector3:
	return _plank_frames[i] * Vector3(along * PLANK.x * 0.5, 0.0, z)


## A taut-only rope between two world points on two bodies, cut Prestretch
## shorter than their distance.
func _tie(a: Box3DBody, pa: Vector3, b: Box3DBody, pb: Vector3) -> void:
	var length := maxf(pa.distance_to(pb) - _prestretch, 0.005)
	_rope_between(a, pa, b, pb, length, "DeckRope", ROPE_R)


## A distance joint used as a rope: the spring is on at 0 Hz, so it adds no
## force, and the limit 0..length is what holds the load.
func _rope_between(a: Box3DBody, pa: Vector3, b: Box3DBody, pb: Vector3, length: float,
		prefix: String, radius: float) -> void:
	var joint := Box3DDistanceJoint.new()
	_joint_serial += 1
	joint.name = "%s%d" % [prefix, _joint_serial]
	joint.length = length
	joint.spring_enabled = true
	joint.spring_hertz = 0.0
	joint.limit_enabled = true
	joint.min_length = 0.0
	joint.max_length = length
	joint.constraint_hertz = ROPE_HERTZ
	joint.body_a = NodePath("../" + String(a.name))
	joint.body_b = NodePath("../" + String(b.name))
	_bridge.add_child(joint)
	var local_a := a.global_transform.affine_inverse() * pa
	var local_b := b.global_transform.affine_inverse() * pb
	if joint.is_joint_valid():
		joint.set_local_frame_a(Transform3D(Basis(), local_a))
		joint.set_local_frame_b(Transform3D(Basis(), local_b))
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = radius
	cylinder.bottom_radius = radius
	cylinder.height = 1.0
	cylinder.radial_segments = 6
	cylinder.rings = 1
	var visual := _mesh_instance(cylinder, _rope)
	visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_bridge.add_child(visual)
	_ropes.append([joint, a, local_a, b, local_b, visual])


# --- hand ropes and cords ----------------------------------------------------

## Each side a chain of capsule links between the post tops, laid along a
## parabola that sags HAND_SAG times the deck sag, joined link to link and
## end to post by ball joints with a little friction.
func _build_hand_ropes() -> void:
	var straight := 2.0 * POST_X
	var n := maxi(2, roundi(HAND_SLACK * straight / LINK_LEN))
	var sag := HAND_SAG * _sag
	# Joint points evenly spaced in arc length along the rope's parabola.
	var steps := 1000
	var table := PackedFloat64Array()
	table.resize(steps + 1)
	table[0] = 0.0
	var prev := Vector2(-POST_X, HAND_Y)
	for i in steps:
		var x := -POST_X + straight * (i + 1) / steps
		var p := Vector2(x, HAND_Y - sag * (1.0 - (x / POST_X) * (x / POST_X)))
		table[i + 1] = table[i] + p.distance_to(prev)
		prev = p
	var pts: Array[Vector2] = []
	for k in n + 1:
		var s := table[steps] * k / n
		var x := -POST_X
		for i in steps:
			if table[i + 1] >= s:
				var f := (s - table[i]) / maxf(table[i + 1] - table[i], 1e-9)
				x = -POST_X + straight * (float(i) + f) / steps
				break
		if k == n:
			x = POST_X
		pts.append(Vector2(x, HAND_Y - sag * (1.0 - (x / POST_X) * (x / POST_X))))
	for zs in [-1.0, 1.0]:
		var z: float = zs * POST_Z
		var side := "L" if zs < 0.0 else "R"
		var links: Array[Box3DBody] = []
		for k in n:
			var d := pts[k + 1] - pts[k]
			var span := d.length()
			var link := Box3DBody.new()
			link.name = "Link%s%d" % [side, k]
			link.shape_type = Box3DBody.CAPSULE
			link.capsule_radius = LINK_R
			link.capsule_height = span + 2.0 * LINK_R
			link.density = LINK_MASS / (PI * LINK_R * LINK_R * span + 4.0 / 3.0 * PI * pow(LINK_R, 3))
			link.friction = 0.8
			link.angular_damping = 0.3
			link.linear_damping = 0.05
			# Capsule Y along the link.
			var mid := (pts[k] + pts[k + 1]) * 0.5
			link.transform = Transform3D(Basis(Vector3.BACK, atan2(d.y, d.x) - PI * 0.5), Vector3(mid.x, mid.y, z))
			var mesh := CapsuleMesh.new()
			mesh.radius = LINK_R
			mesh.height = span + 2.0 * LINK_R
			mesh.radial_segments = 8
			mesh.rings = 2
			link.add_child(_mesh_instance(mesh, _rope))
			_bridge.add_child(link)
			links.append(link)
		_links[zs] = links
		for k in n + 1:
			var a: Box3DBody
			var b: Box3DBody
			if k == 0:
				a = links[0]
				b = _bridge.get_node(_post_name(-1.0, zs))
			elif k == n:
				a = links[n - 1]
				b = _bridge.get_node(_post_name(1.0, zs))
			else:
				a = links[k - 1]
				b = links[k]
			var joint := Box3DBallJoint.new()
			joint.name = "LinkJoint%s%d" % [side, k]
			joint.position = Vector3(pts[k].x, pts[k].y, z)
			joint.friction_torque = LINK_FRICTION
			joint.body_a = NodePath("../" + String(a.name))
			joint.body_b = NodePath("../" + String(b.name))
			_bridge.add_child(joint)


## Every CORD_EVERY-th plank hangs from the nearest hand rope link on each
## side by a cord with CORD_SLACK of slack.
func _build_cords() -> void:
	for i in range(2, _planks.size(), CORD_EVERY):
		for zs in [-1.0, 1.0]:
			var p: Vector3 = _plank_frames[i] * Vector3(0.0, PLANK.y * 0.5, zs * PLANK.z * 0.5)
			var best: Box3DBody = null
			for link: Box3DBody in _links[zs]:
				if best == null or link.global_position.distance_to(p) < best.global_position.distance_to(p):
					best = link
			var q := best.global_position
			_rope_between(_planks[i], p, best, q, p.distance_to(q) + CORD_SLACK, "Cord", CORD_R)


# --- build and rebuild --------------------------------------------------------

func _rebuild() -> void:
	if _bridge != null:
		# Free in reverse creation order, so Box3D's id pools return to the
		# state they started in and a rebuild replays the same way.
		var kids := _bridge.get_children()
		kids.reverse()
		for child in kids:
			_bridge.remove_child(child)
			child.free()
		_bridge.free()
	_planks.clear()
	_plank_frames.clear()
	_ropes.clear()
	_links.clear()
	_joint_serial = 0
	_bridge = Node3D.new()
	_bridge.name = "Bridge"
	_world.add_child(_bridge)
	_build_heads()
	_build_deck()
	_build_hand_ropes()
	_build_cords()


## Rope drawing follows the bodies every frame.
func _process(_delta: float) -> void:
	for r in _ropes:
		var visual: MeshInstance3D = r[5]
		var a: Box3DBody = r[1]
		var b: Box3DBody = r[3]
		if not is_instance_valid(visual) or not is_instance_valid(a) or not is_instance_valid(b):
			continue
		var pa: Vector3 = a.global_transform * (r[2] as Vector3)
		var pb: Vector3 = b.global_transform * (r[4] as Vector3)
		var d := pb - pa
		var span := d.length()
		if span < 1e-4:
			visual.visible = false
			continue
		visual.visible = true
		var y := d / span
		var x := y.cross(Vector3.BACK)
		if x.length() < 1e-3:
			x = y.cross(Vector3.RIGHT)
		x = x.normalized()
		visual.global_transform = Transform3D(Basis(x, y * span, x.cross(y)), (pa + pb) * 0.5)
	_label.text = "%d planks, deck sag %.2f m" % [_planks.size(), deck_sag()]


## How far the lowest plank centre hangs below the deck ends.
func deck_sag() -> float:
	var low := INF
	for plank in _planks:
		if is_instance_valid(plank):
			low = minf(low, plank.global_position.y)
	return DECK_Y - low if low < INF else 0.0


func plank_count() -> int:
	return _planks.size()


# --- helpers -----------------------------------------------------------------

func _static_box(parent: Node, p_name: String, size: Vector3, pos: Vector3, material: Material,
		friction: float) -> Box3DBody:
	var body := Box3DBody.new()
	body.name = p_name
	body.body_type = Box3DBody.STATIC
	body.box_size = size
	body.friction = friction
	body.position = pos
	body.add_child(_mesh_box(size, material))
	parent.add_child(body)
	return body


func _mesh_box(size: Vector3, material: Material) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	return _mesh_instance(mesh, material)


func _mesh_instance(mesh: Mesh, material: Material) -> MeshInstance3D:
	var visual := MeshInstance3D.new()
	visual.mesh = mesh
	visual.material_override = material
	return visual


static func _material(color: Color, roughness: float) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = roughness
	return material


# --- Sidebar dials ------------------------------------------------------------

func sample_size_dials() -> Array:
	return [
		{
			"key": "sag", "label": "Sag", "value": _sag,
			"min": SAG_RANGE.x, "max": SAG_RANGE.y, "step": 0.05,
			"tooltip": "How far the deck is laid below its ends at mid span, in metres.",
		},
		{
			"key": "prestretch", "label": "Prestretch", "value": _prestretch,
			"min": PRESTRETCH_RANGE.x, "max": PRESTRETCH_RANGE.y, "step": 0.001,
			"tooltip": "How much shorter than the gap it spans each deck rope is cut, in metres.",
		},
		{
			"key": "damping", "label": "Plank damping", "value": _damping,
			"min": DAMPING_RANGE.x, "max": DAMPING_RANGE.y, "step": 0.05,
			"tooltip": "Linear damping on every plank.",
		},
	]


func sample_size_hint(key: String, value: float) -> String:
	match key:
		"sag":
			return "Deck laid %.2f m below its ends (rebuilds the bridge)" % value
		"prestretch":
			return "Deck ropes cut %.1f mm short (rebuilds the bridge)" % (value * 1000.0)
		_:
			return "Plank damping %.2f (rebuilds the bridge)" % value


func set_sample_size(key: String, value: float) -> void:
	match key:
		"sag":
			_sag = clampf(value, SAG_RANGE.x, SAG_RANGE.y)
		"prestretch":
			_prestretch = clampf(value, PRESTRETCH_RANGE.x, PRESTRETCH_RANGE.y)
		"damping":
			_damping = clampf(value, DAMPING_RANGE.x, DAMPING_RANGE.y)
	if is_inside_tree():
		_rebuild()


## The whole bridge is built in code, so the Godot Physics and Jolt rigs see
## an empty scene.
func rig_notes() -> Array:
	return ["The bridge is built in code, so Godot Physics and Jolt rebuild "
			+ "nothing here; their distance joints also have no taut-only limit to match."]
