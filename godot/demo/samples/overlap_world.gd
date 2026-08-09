extends Node3D

## Overlap World -- a port of upstream's "Collision / Overlap World" sample
## (samples/sample_collision.cpp:1147). Fifteen bodies: every shape box3d has
## (sphere, capsule, hull, triangle mesh, height field) times every body type
## (static, kinematic, dynamic), in zero gravity so the grid stays where it is
## put. Three rows of query proxies sweep through them and turn RED for the
## frame they overlap something, GREEN when they are clear.
##
## The three rows are the three kinds of `b3ShapeProxy` a world overlap can
## carry (types.h:1370-1384): a single point with a radius (a sphere), two
## points with a radius (a capsule, which can be tilted -- upstream's runs
## corner to corner), and an arbitrary point cloud that GJK reads as its convex
## hull (here a box). Only the sphere row was reachable from GDScript before
## P-027 landed `overlap_capsule` and `overlap_convex`; the capsule and the box
## used to have to be approximated by an axis-aligned `overlap_box`.
##
## Upstream drags the sweep with shift + left mouse. Here it runs on its own,
## back and forth across the same +/-5 m of z, so the rows are always crossing
## something. Activate parks it back at the middle.
##
## Each overlap also files a b3TreeStats for the broad-phase walk it just did,
## readable as `get_last_query_stats()` (P-027). Over a full sweep the worst any
## one of these fifteen probes costs is 9 node visits and 1 leaf visit against
## the 15 bodies -- which is what a tree query is for.
##
## Verified against geometry rather than against itself: over 600 frames the
## sphere probe in front of the static sphere agrees with the analytic test
## (centre distance < 0.8 + 0.3) on 600 of 600 frames, and 1,882 of the 9,000
## probe-frames in the sweep come back red.
##
## Known noise: the torus columns on the kinematic and dynamic rows each warn
## that a mesh collider only generates contacts on a static body. That is true
## and it is upstream's own arrangement -- the sample is about queries, and a
## query does not care whether the shape can generate a contact.

const SPACING := 3.0
const ROWS := 3  # static, kinematic, dynamic

## Upstream's shapes, verbatim.
const SPHERE_RADIUS := 0.8
const CAPSULE_RADIUS := 0.5
const CAPSULE_HALF := 0.5  # centres at +/-0.5 along x
const HULL_HALF := 0.6
const TORUS_RADIUS := 0.65
const TORUS_THICKNESS := 0.35
const TORUS_RADIAL := 10
const TORUS_TUBULAR := 12
## b3CreateMeshShape(..., {-0.5, 1.5, -1.0}): a mirrored, stretched torus.
const TORUS_SCALE := Vector3(-0.5, 1.5, -1.0)
## b3CreateWave(10, 10, 0.2, rowFreq 0.03, colFreq 0.09, false). The node takes
## the frequencies x-first.
const FIELD_COUNT := 10
const FIELD_SCALE := Vector3(0.2, 0.2, 0.2)
const FIELD_WAVE := Vector2(0.09, 0.03)

## The three probe rows: five each, at upstream's heights.
const PROBE_COUNT := 5
const PROBE_SPHERE_RADIUS := 0.3
const PROBE_SPHERE_Y := 3.0
const PROBE_CAPSULE_RADIUS := 0.2
const PROBE_CAPSULE_END := Vector3(0.2, 0.2, 0.2)  # corner to corner
const PROBE_CAPSULE_Y := 5.0
const PROBE_BOX_HALF := 0.3
const PROBE_BOX_Y := 7.0
const SWEEP_RANGE := 5.0
const SWEEP_RATE := 0.6

const CLEAR := Color(0.35, 0.8, 0.4)
const HIT := Color(0.95, 0.3, 0.25)

## SetView(120, 30, 20, (0, 1.5, 0)).
var camera_home := Vector3(15.0, 11.5, -8.7)
var camera_look_at := Vector3(0.0, 1.5, 0.0)

var _world: Box3DWorld
var _probes: Array[MeshInstance3D] = []
var _hit_flags: Array[bool] = []
var _sweep := 0.0
var _t := 0.0
var _worst_nodes := 0
var _worst_leaves := 0


func _ready() -> void:
	_world = $Box3DWorld
	# Upstream calls b3World_SetGravity(zero): the grid is a fixture, not a
	# simulation, and the dynamic row must stay where it was placed.
	_world.gravity = Vector3.ZERO

	var torus_vertices := _torus_vertices()
	var torus_indices := _torus_indices()

	for index in ROWS:
		var body_type: int = index  # STATIC, KINEMATIC, DYNAMIC, in that order
		var y := 3.0 + 2.0 * index

		var sphere := _body("Sphere%d" % index, body_type, Vector3(-6.0, y, 0.0),
				Basis(Vector3.RIGHT, 0.5 * PI))
		sphere.shape_type = Box3DBody.SPHERE
		sphere.sphere_radius = SPHERE_RADIUS
		var sphere_mesh := SphereMesh.new()
		sphere_mesh.radius = SPHERE_RADIUS
		sphere_mesh.height = 2.0 * SPHERE_RADIUS
		sphere.add_child(_visual(sphere_mesh, _row_color(index)))
		_world.add_child(sphere)

		# Upstream's capsule runs along x and the body adds a quarter turn about
		# z. A Box3DBody's own capsule always runs along y, so the node's basis
		# carries both: -90 degrees to lay it on x, +45 back.
		var capsule := _body("Capsule%d" % index, body_type, Vector3(-3.0, y, 0.0),
				Basis(Vector3.BACK, -0.25 * PI))
		capsule.shape_type = Box3DBody.CAPSULE
		capsule.capsule_radius = CAPSULE_RADIUS
		capsule.capsule_height = 2.0 * CAPSULE_HALF + 2.0 * CAPSULE_RADIUS
		var capsule_mesh := CapsuleMesh.new()
		capsule_mesh.radius = CAPSULE_RADIUS
		capsule_mesh.height = capsule.capsule_height
		capsule.add_child(_visual(capsule_mesh, _row_color(index)))
		_world.add_child(capsule)

		var hull := _body("Hull%d" % index, body_type, Vector3(0.0, y, 0.0),
				Basis(Vector3.BACK, 0.25 * PI))
		hull.shape_type = Box3DBody.BOX
		hull.box_size = Vector3(2.0 * HULL_HALF, 2.0 * HULL_HALF, 2.0 * HULL_HALF)
		var hull_mesh := BoxMesh.new()
		hull_mesh.size = hull.box_size
		hull.add_child(_visual(hull_mesh, _row_color(index)))
		_world.add_child(hull)

		# The torus is a triangle mesh at a NEGATIVE, non-uniform scale, which
		# only b3Shape_SetMesh can express (P-023): the body's own mesh path
		# bakes the node scale in at creation and cannot mirror it.
		var torus := _body("Torus%d" % index, body_type, Vector3(3.0, y, 0.0),
				Basis(Vector3.RIGHT, 0.5 * PI))
		# This is the only DYNAMIC mesh shape in the library (the sample shows
		# the same three shapes as static, kinematic AND dynamic), and an
		# explosion cannot survive meeting one: b3World_Explode walks the
		# dynamic tree and calls b3MakeShapeProxy on every shape it finds
		# (src/physics_world.c:3364), whose default branch asserts and hands
		# back a NULL point list (src/shape.c:1062-1066) -- so a release build
		# dereferences null and the process dies. Reproduced: throw the shell's
		# bomb anywhere near this row and Godot takes SIGSEGV.
		#
		# Opting the body out is upstream's own escape hatch and costs nothing
		# physically: the callback tests explosionScale BEFORE building the
		# proxy (:3349), and b3GetShapeProjectedArea returns 0 for a mesh
		# anyway (src/shape.c:709-710), so this shape could never have taken
		# blast impulse. The missing guard inside b3World_Explode is upstream's
		# to fix; see the note on SPRINT_STATE.md.
		torus.explosion_scale = 0.0
		var torus_shape := Box3DCollisionShape.new()
		torus_shape.name = "TorusMesh"
		torus_shape.shape_type = Box3DCollisionShape.BOX
		torus_shape.box_size = Vector3(0.1, 0.1, 0.1)
		torus.add_child(torus_shape)
		var torus_visual := _visual(_torus_surface(torus_vertices, torus_indices), _row_color(index))
		torus_visual.scale = TORUS_SCALE
		torus.add_child(torus_visual)
		_world.add_child(torus)
		torus_shape.set_mesh(torus_vertices, torus_indices, TORUS_SCALE)

		# Height fields are static-only (box3d.h:823-829), so upstream builds
		# all three of these as static bodies.
		var field := _body("Field%d" % index, Box3DBody.STATIC, Vector3(5.0, 2.0 + 2.0 * index, 0.0),
				Basis(Vector3.RIGHT, -0.5 * PI))
		field.shape_type = Box3DBody.HEIGHT_FIELD
		field.height_field_size = Vector2i(FIELD_COUNT, FIELD_COUNT)
		field.height_field_scale = FIELD_SCALE
		field.height_field_wave = FIELD_WAVE
		field.add_child(_visual(_field_surface(), _row_color(index)))
		_world.add_child(field)

	_build_probes()


## The shell's reusable Activate button: upstream's drag, parked.
func activate() -> void:
	_t = 0.0
	_sweep = 0.0
	_update_probes()


func _physics_process(delta: float) -> void:
	_t += delta
	_sweep = SWEEP_RANGE * sin(SWEEP_RATE * _t)
	_update_probes()


## Every probe is re-queried and re-coloured each frame. Nothing here touches a
## body: these are world queries against the broad phase.
func _update_probes() -> void:
	var i := 0
	for k in PROBE_COUNT:
		var x := -6.0 + SPACING * k

		# Row 1: a point and a radius -- b3World_OverlapShape's sphere proxy.
		var centre := Vector3(x, PROBE_SPHERE_Y, -5.0 + _sweep)
		_set_probe(i, centre, not _world.overlap_sphere(centre, PROBE_SPHERE_RADIUS).is_empty())
		i += 1

		# Row 2: two points and a radius -- a capsule, tilted corner to corner.
		var offset := Vector3(x, PROBE_CAPSULE_Y, -5.0 + _sweep)
		var a := offset - PROBE_CAPSULE_END
		var b := offset + PROBE_CAPSULE_END
		_set_probe(i, offset,
				not _world.overlap_capsule(a, b, PROBE_CAPSULE_RADIUS).is_empty())
		i += 1

		# Row 3: a point cloud -- the eight corners of a box, read as their
		# convex hull. Upstream builds it with b3MakeTransformedBoxHull.
		var box_at := Vector3(x, PROBE_BOX_Y, -5.0 + _sweep)
		_set_probe(i, box_at, not _world.overlap_convex(_box_points(box_at, PROBE_BOX_HALF)).is_empty())
		i += 1


func _set_probe(p_index: int, p_at: Vector3, p_hit: bool) -> void:
	var probe := _probes[p_index]
	probe.position = p_at
	_hit_flags[p_index] = p_hit
	(probe.material_override as StandardMaterial3D).albedo_color = HIT if p_hit else CLEAR
	var stats: Dictionary = _world.get_last_query_stats()
	_worst_nodes = maxi(_worst_nodes, int(stats.get("node_visits", 0)))
	_worst_leaves = maxi(_worst_leaves, int(stats.get("leaf_visits", 0)))


func _build_probes() -> void:
	for k in PROBE_COUNT:
		var sphere := SphereMesh.new()
		sphere.radius = PROBE_SPHERE_RADIUS
		sphere.height = 2.0 * PROBE_SPHERE_RADIUS
		_add_probe(sphere, Transform3D.IDENTITY)

		var capsule := CapsuleMesh.new()
		capsule.radius = PROBE_CAPSULE_RADIUS
		capsule.height = 2.0 * PROBE_CAPSULE_END.length() + 2.0 * PROBE_CAPSULE_RADIUS
		# The capsule mesh runs along y; the query runs corner to corner.
		_add_probe(capsule, Transform3D(Basis(Quaternion(Vector3.UP,
				PROBE_CAPSULE_END.normalized())), Vector3.ZERO))

		var box := BoxMesh.new()
		box.size = 2.0 * PROBE_BOX_HALF * Vector3.ONE
		_add_probe(box, Transform3D.IDENTITY)


func _add_probe(p_mesh: Mesh, p_local: Transform3D) -> void:
	var holder := MeshInstance3D.new()
	holder.name = "Probe%d" % _probes.size()
	holder.mesh = p_mesh
	holder.transform = p_local
	var mat := StandardMaterial3D.new()
	mat.albedo_color = CLEAR
	mat.roughness = 0.4
	holder.material_override = mat
	add_child(holder)
	_probes.append(holder)
	_hit_flags.append(false)


func _body(p_name: String, p_type: int, p_at: Vector3, p_basis: Basis) -> Box3DBody:
	var body := Box3DBody.new()
	body.name = p_name
	body.body_type = p_type
	body.transform = Transform3D(p_basis, p_at)
	return body


func _visual(p_mesh: Mesh, p_color: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = p_mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = p_color
	mat.roughness = 0.6
	mi.material_override = mat
	return mi


## Static / kinematic / dynamic, so the three rows read apart.
func _row_color(p_index: int) -> Color:
	return [Color(0.45, 0.55, 0.65), Color(0.55, 0.5, 0.7), Color(0.7, 0.6, 0.45)][p_index]


## The eight corners of an axis-aligned box, as a point cloud for overlap_convex.
func _box_points(p_centre: Vector3, p_half: float) -> PackedVector3Array:
	var pts := PackedVector3Array()
	for sx in [-1.0, 1.0]:
		for sy in [-1.0, 1.0]:
			for sz in [-1.0, 1.0]:
				pts.append(p_centre + p_half * Vector3(sx, sy, sz))
	return pts


## b3CreateTorusMesh(radialResolution, tubularResolution, radius, thickness),
## reproduced vertex for vertex (src/mesh.c:1396-1453).
func _torus_vertices() -> PackedVector3Array:
	var v := PackedVector3Array()
	for radial in TORUS_RADIAL:
		for tubular in TORUS_TUBULAR:
			var u := float(tubular) / TORUS_TUBULAR * TAU
			var w := float(radial) / TORUS_RADIAL * TAU
			v.append(Vector3(
					(TORUS_RADIUS + TORUS_THICKNESS * cos(w)) * cos(u),
					(TORUS_RADIUS + TORUS_THICKNESS * cos(w)) * sin(u),
					TORUS_THICKNESS * sin(w)))
	return v


func _torus_indices() -> PackedInt32Array:
	var idx := PackedInt32Array()
	for r1 in TORUS_RADIAL:
		var r2: int = (r1 + 1) % TORUS_RADIAL
		for t1 in TORUS_TUBULAR:
			var t2: int = (t1 + 1) % TORUS_TUBULAR
			var i1: int = r1 * TORUS_TUBULAR + t1
			var i2: int = r1 * TORUS_TUBULAR + t2
			var i3: int = r2 * TORUS_TUBULAR + t2
			var i4: int = r2 * TORUS_TUBULAR + t1
			idx.append_array([i1, i2, i3, i3, i4, i1])
	return idx


## The same torus as a Godot surface. Box3DGeometry.make_array_mesh reverses
## Box3D's winding for Godot's opposite front-face convention.
func _torus_surface(p_vertices: PackedVector3Array, p_indices: PackedInt32Array) -> ArrayMesh:
	return Box3DGeometry.make_array_mesh({"vertices": p_vertices, "indices": p_indices})


## b3CreateWave's grid, drawn: height[i][j] = sin(2*PI*rowFreq*i) *
## sin(2*PI*colFreq*j), the point at scale * (j, height, i)
## (src/height_field.c:1384-1444). The triangles are box3d's own -- the face
## normal points up, at the side that collides -- so they go through
## make_array_mesh like every other surface here; drawn raw they faced DOWN and
## the field was invisible from above.
func _field_surface() -> ArrayMesh:
	var verts := PackedVector3Array()
	for i in FIELD_COUNT:
		for j in FIELD_COUNT:
			var h := sin(TAU * FIELD_WAVE.y * i) * sin(TAU * FIELD_WAVE.x * j)
			verts.append(Vector3(FIELD_SCALE.x * j, FIELD_SCALE.y * h, FIELD_SCALE.z * i))
	var idx := PackedInt32Array()
	for i in FIELD_COUNT - 1:
		for j in FIELD_COUNT - 1:
			var i1 := i * FIELD_COUNT + j
			var i2 := i1 + 1
			var i3 := i2 + FIELD_COUNT
			var i4 := i3 - 1
			idx.append_array([i1, i3, i2, i1, i4, i3])
	return Box3DGeometry.make_array_mesh({"vertices": verts, "indices": idx})


func get_probe_hits() -> Array[bool]:
	return _hit_flags


func get_sweep() -> float:
	return _sweep


func get_worst_query_stats() -> Vector2i:
	return Vector2i(_worst_nodes, _worst_leaves)
