extends RefCounted

## The barrel MODEL: a 55-gallon steel drum, lathed in code.
##
## Built rather than imported for the same reason the Huge Pyramid's blocks
## are: the Barrel Spire draws 3000 of these, and a mesh this small is cheaper
## to describe in thirty lines of profile than to ship, import and keep in step
## with a .glb. Everything here is geometry and paint -- a barrel is a plain
## Box3DBody with a cylinder collider, and nothing in this file knows what it
## is filled with.
##
## Two numbers are load-bearing and are checked by the selftest:
##   - RADIUS is the collider radius AND the widest point of the mesh (the
##     rolling hoops), so a ring of barrels packed to a RADIUS * 2 chord has
##     its visuals meet exactly where the colliders do. Let the hoops bulge
##     past the collider and stacked barrels visibly interpenetrate.
##   - SIDES is the mesh's radial segment count AND the collider's
##     cylinder_sides, so the silhouette is the collider rather than an
##     approximation of it.

const RADIUS := 0.30  ## outer radius, hoops included
const HEIGHT := 0.88  ## overall height
const SIDES := 12     ## radial segments, mesh and collider alike

## Lathe profile, bottom rim to top rim, as (radius, height) pairs. The barrel
## sits on the body origin's Y, so it runs -HEIGHT/2 to +HEIGHT/2. The straight
## sides sit slightly inside RADIUS; the two rolling hoops and the two rolled
## rims (the "chimes") are what reaches it.
const _SHELL := 0.285  ## the straight side, inboard of the hoops
const _PROFILE: Array[Vector2] = [
	Vector2(0.25, -0.44),    # bottom lid edge
	Vector2(RADIUS, -0.41),  # bottom chime
	Vector2(_SHELL, -0.37),
	Vector2(_SHELL, -0.14),  # lower body
	Vector2(RADIUS, -0.115), # lower hoop
	Vector2(RADIUS, -0.075),
	Vector2(_SHELL, -0.05),
	Vector2(_SHELL, 0.05),   # hazard band, between the hoops
	Vector2(RADIUS, 0.075),  # upper hoop
	Vector2(RADIUS, 0.115),
	Vector2(_SHELL, 0.14),
	Vector2(_SHELL, 0.37),   # upper body
	Vector2(RADIUS, 0.41),   # top chime
	Vector2(0.25, 0.44),     # top lid edge
]

## Paint. These are baked into VERTEX colors rather than into materials, so the
## whole barrel is one surface in one draw call however many of it there are;
## the MultiMesh's per-instance color then only has to carry the slight
## weathering difference between one drum and the next (see barrel_cluster.gd).
const PAINT := Color(0.60, 0.075, 0.055)     ## the red the drum is sprayed
const STEEL := Color(0.34, 0.045, 0.035)     ## hoops and chimes, in shadow
const HAZARD := Color(0.74, 0.58, 0.09)      ## the band between the hoops
const LID := Color(0.47, 0.06, 0.05)         ## both ends

## One color per profile SEGMENT (so one per _PROFILE entry bar the last).
const _BANDS: Array[Color] = [
	STEEL,  # bottom chime
	STEEL,
	PAINT,  # lower body
	STEEL,  # lower hoop
	STEEL,
	STEEL,
	HAZARD, # the band
	STEEL,  # upper hoop
	STEEL,
	STEEL,
	PAINT,  # upper body
	STEEL,  # top chime
	STEEL,
]

static var _mesh: ArrayMesh = null


## The drum, cached: one ArrayMesh shared by every barrel in the process.
static func mesh() -> ArrayMesh:
	if _mesh == null:
		_mesh = _build()
	return _mesh


## A body shaped like this barrel, with the collider that matches the mesh.
## The caller owns it and still has to place it and parent it to a world.
static func make_body(density: float) -> Box3DBody:
	var b := Box3DBody.new()
	b.shape_type = Box3DBody.CYLINDER  # upright on Y, like the mesh
	b.capsule_radius = RADIUS
	b.capsule_height = HEIGHT
	b.cylinder_sides = SIDES
	b.density = density
	return b


## Vertex-colored, and metallic enough to catch the sky the shell lights every
## sample with. Kept off full metallic on purpose: a drum at 1.0 has no diffuse
## left at all and a spire of them reads as a black cone from any angle that
## misses the sun.
static func material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.metallic = 0.65
	mat.roughness = 0.38
	return mat


static func _build() -> ArrayMesh:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()

	# Sides: one quad strip per profile segment. Vertices are duplicated per
	# segment so the hoops keep their hard edge, and the ring around each
	# segment shares the smooth radial normal so a 12-gon still reads round.
	for s in _PROFILE.size() - 1:
		var p0: Vector2 = _PROFILE[s]
		var p1: Vector2 = _PROFILE[s + 1]
		# Normal of the segment in the (radius, height) plane, turned outward.
		var edge := (p1 - p0).normalized()
		var nr := edge.y
		var ny := -edge.x
		var base := verts.size()
		for j in SIDES:
			var a := TAU * j / SIDES
			var ca := cos(a)
			var sa := sin(a)
			var n := Vector3(nr * ca, ny, nr * sa).normalized()
			verts.append(Vector3(p0.x * ca, p0.y, p0.x * sa))
			normals.append(n)
			colors.append(_BANDS[s])
			verts.append(Vector3(p1.x * ca, p1.y, p1.x * sa))
			normals.append(n)
			colors.append(_BANDS[s])
		for j in SIDES:
			var i0 := base + j * 2
			var i1 := i0 + 1
			var i2 := base + ((j + 1) % SIDES) * 2
			var i3 := i2 + 1
			_add_tri(indices, verts, normals, i0, i1, i2)
			_add_tri(indices, verts, normals, i1, i3, i2)

	# The two lids, as fans around a center vertex.
	_add_cap(verts, normals, colors, indices, _PROFILE[0], Vector3.DOWN)
	_add_cap(verts, normals, colors, indices, _PROFILE[-1], Vector3.UP)

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, material())
	return mesh


static func _add_cap(verts: PackedVector3Array, normals: PackedVector3Array,
		colors: PackedColorArray, indices: PackedInt32Array,
		rim: Vector2, n: Vector3) -> void:
	var center := verts.size()
	verts.append(Vector3(0.0, rim.y, 0.0))
	normals.append(n)
	colors.append(LID)
	for j in SIDES:
		var a := TAU * j / SIDES
		verts.append(Vector3(rim.x * cos(a), rim.y, rim.x * sin(a)))
		normals.append(n)
		colors.append(LID)
	for j in SIDES:
		_add_tri(indices, verts, normals,
			center, center + 1 + j, center + 1 + (j + 1) % SIDES)


## One triangle, wound the way Godot wants it. Godot's front faces wind
## CLOCKWISE seen from outside, i.e. the winding cross-product points INWARD --
## the same rule tools/gen_car_wheel.gd works to. Checking it against the
## vertex normal we already computed is cheaper than reasoning about it per
## call site, and it cannot silently rot when the profile changes.
static func _add_tri(indices: PackedInt32Array, verts: PackedVector3Array,
		normals: PackedVector3Array, ia: int, ib: int, ic: int) -> void:
	var cross := (verts[ib] - verts[ia]).cross(verts[ic] - verts[ia])
	indices.append(ia)
	if cross.dot(normals[ia]) > 0.0:
		indices.append(ic)
		indices.append(ib)
	else:
		indices.append(ib)
		indices.append(ic)
