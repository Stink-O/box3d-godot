extends Node3D

## Gyroscopic Precession — 64 spinning tops. Port of upstream's "Gyroscopic
## Precession" sample (samples/sample_bodies.cpp, itself ported from PEEL):
## each top is a convex hull with a wide 7-gon rim and its tip at the body
## origin, tilted 15 degrees and spun at 75 rad/s about its own symmetry axis
## (allow_fast_rotation bypasses the solver's spin cap). Gravity's torque
## about the tip doesn't topple a fast top — it drives the spin axis in a
## slow circle around vertical: precession. The same ArrayMesh is both the
## visual and the HULL collider, so what you see is exactly what collides.

const COUNT := 8
const SEPARATION := 6.0
const SEGS := 7
const TOP_RADIUS := 2.0
const TOP_HEIGHT := 2.0
const SPIN := 75.0  # rad/s about the top's own axis
const TILT_DEG := 15.0

const COLORS: Array[Color] = [
	Color(0.85, 0.35, 0.25),
	Color(0.35, 0.55, 0.85),
	Color(0.95, 0.75, 0.25),
]

var camera_home := Vector3(28.0, 22.0, 46.0)
var camera_look_at := Vector3(-3.0, 2.0, -3.0)  # grid center


func _ready() -> void:
	var world: Node = get_node("Box3DWorld")
	var mesh := _build_top_mesh()
	var mats: Array[StandardMaterial3D] = []
	for c in COLORS:
		var m := StandardMaterial3D.new()
		m.albedo_color = c
		m.roughness = 0.45
		m.metallic = 0.25
		mats.append(m)

	var tilt := Basis(Vector3(0, 0, 1), deg_to_rad(TILT_DEG))
	for x in COUNT:
		for z in COUNT:
			var body := Box3DBody.new()
			body.shape_type = Box3DBody.HULL
			body.collision_mesh = mesh
			body.allow_fast_rotation = true  # 75 rad/s exceeds the default cap
			body.transform = Transform3D(
				tilt, Vector3((x - 4) * SEPARATION, TOP_HEIGHT, (z - 4) * SEPARATION))
			var vis := MeshInstance3D.new()
			vis.mesh = mesh
			vis.material_override = mats[(x + z) % mats.size()]
			body.add_child(vis)
			world.add_child(body)
			# Spin about the top's own (tilted) symmetry axis, like upstream.
			body.set_angular_velocity(body.global_basis * Vector3(0, SPIN, 0))


## The top: a 7-gon rim at height 2, radius 2, closed by a flat lid, tapering
## to a point at the origin — so the body balances on its tip. Matches
## upstream's b3CreateHull point set exactly.
func _build_top_mesh() -> ArrayMesh:
	var rim: Array[Vector3] = []
	for i in SEGS:
		var phi := TAU * i / SEGS
		rim.append(Vector3(TOP_RADIUS * cos(phi), TOP_HEIGHT, TOP_RADIUS * sin(phi)))
	var apex := Vector3.ZERO

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# Godot front faces wind clockwise seen from outside.
	for i in SEGS:
		var j := (i + 1) % SEGS
		# Side: apex at the bottom, rim edge above.
		for p in [apex, rim[j], rim[i]]:
			st.add_vertex(p)
	for i in range(1, SEGS - 1):
		# Lid fan, facing up.
		for p in [rim[0], rim[i], rim[i + 1]]:
			st.add_vertex(p)
	st.generate_normals()
	return st.commit()
