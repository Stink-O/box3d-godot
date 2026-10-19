extends Node3D

## Arch -- a port of upstream's "Stacking / Arch" sample
## (samples/sample_stacking.cpp:653-758). A free-standing masonry arch of 17
## wedge-shaped stones, held up only by friction and by the stones pressing on
## each other, carrying a stack of four slabs on its keystone. No joints and
## no glue: it stands only if the solver resolves the contact forces through
## the whole curve accurately.
##
## Upstream's numbers are kept verbatim: the inner and outer curves are its
## two nine-point tables (:662-680), scaled by 0.25 (:682-689); each stone is
## the convex hull of the eight corners between consecutive points, 1 m deep
## (b3CreateHull(ps, 8, 8), :697-711), eight stones per side with the left
## side mirrored (:713-725), one keystone across the top (:727-736), and four
## 4 x 1 x 1 box slabs stacked on it (:738-745). Every shape has density 200
## (:693), on AddGroundBox(40) under gravity -10. As upstream, each stone's
## body sits at the origin and its hull carries the stone's real coordinates.

## Upstream's ps1 (inner) and ps2 (outer) curves, before the 0.25 scale.
const INNER := [
	Vector2(16.0, 0.0), Vector2(14.93803712795643, 5.133601056842984),
	Vector2(13.79871746027416, 10.24928069555078), Vector2(12.56252963284711, 15.34107019122473),
	Vector2(11.20040987372525, 20.39856541571217), Vector2(9.66521217819836, 25.40369899225096),
	Vector2(7.87179930638133, 30.3179337000085), Vector2(5.635199558196225, 35.03820717801641),
	Vector2(2.405937953536585, 39.09554102558315),
]
const OUTER := [
	Vector2(24.0, 0.0), Vector2(22.33619528222415, 6.02299846205841),
	Vector2(20.54936888969905, 12.00964361211476), Vector2(18.60854610798073, 17.9470321677465),
	Vector2(16.46769273811807, 23.81367936585418), Vector2(14.05325025774858, 29.57079353071012),
	Vector2(11.23551045834022, 35.13775818285372), Vector2(7.752568160730571, 40.30450679009583),
	Vector2(3.016931552701656, 44.28891593799322),
]
const SCALE := 0.25
const HALF_DEPTH := 0.5
const DENSITY := 200.0
const SLAB_SIZE := Vector3(4.0, 1.0, 1.0)

## m_camera->SetView(25, 10, 30, {0, 5, 0}) (:658): eye = pivot + radius *
## (sin yaw cos pitch, sin pitch, cos yaw cos pitch)
## (samples/host/camera.cpp:35-39,216-220).
var camera_home := Vector3(0.0, 5.0, 0.0) + 30.0 * Vector3(
		sin(deg_to_rad(25.0)) * cos(deg_to_rad(10.0)),
		sin(deg_to_rad(10.0)),
		cos(deg_to_rad(25.0)) * cos(deg_to_rad(10.0)))
var camera_look_at := Vector3(0.0, 5.0, 0.0)


func _ready() -> void:
	var world := $Box3DWorld
	var stone := StandardMaterial3D.new()
	stone.albedo_color = Color(0.72, 0.66, 0.56)
	stone.roughness = 0.85
	var slab := StandardMaterial3D.new()
	slab.albedo_color = Color(0.55, 0.6, 0.7)
	slab.roughness = 0.7
	var index := 0
	for e: Dictionary in rig_bodies():
		var body := Box3DBody.new()
		body.name = "Stone%d" % index
		body.density = DENSITY
		body.angular_damping = 0.0
		body.transform = e["transform"]
		var visual := MeshInstance3D.new()
		if e.has("hull_mesh"):
			body.shape_type = Box3DBody.HULL
			body.collision_mesh = e["hull_mesh"]
			visual.mesh = e["hull_mesh"]
			visual.material_override = stone
		else:
			body.name = "Slab%d" % (index - 17)
			body.box_size = e["size"]
			var box := BoxMesh.new()
			box.size = e["size"]
			visual.mesh = box
			visual.material_override = slab
		body.add_child(visual)
		world.add_child(body)
		index += 1


## The stones and slabs (:691-745), shared with the comparison rig.
func rig_bodies() -> Array:
	var ps1: Array[Vector2] = []
	var ps2: Array[Vector2] = []
	for i in range(9):
		ps1.append(INNER[i] * SCALE)
		ps2.append(OUTER[i] * SCALE)
	var out: Array = []
	for i in range(8):
		out.append(_stone([ps1[i], ps2[i], ps2[i + 1], ps1[i + 1]]))
	for i in range(8):
		var m := Vector2(-1.0, 1.0)
		out.append(_stone([ps2[i] * m, ps1[i] * m, ps1[i + 1] * m, ps2[i + 1] * m]))
	var m := Vector2(-1.0, 1.0)
	out.append(_stone([ps1[8], ps2[8], ps2[8] * m, ps1[8] * m]))
	for i in range(4):
		out.append({
			"transform": Transform3D(Basis(), Vector3(0.0, 0.5 + ps2[8].y + 1.0 * i, 0.0)),
			"size": SLAB_SIZE,
			"density": DENSITY,
		})
	return out


## One stone: b3CreateHull of the quad's four corners at both depths, its
## body at the origin.
func _stone(quad: Array) -> Dictionary:
	var points := PackedVector3Array()
	for z in [-HALF_DEPTH, HALF_DEPTH]:
		for p: Vector2 in quad:
			points.append(Vector3(p.x, p.y, z))
	var hull: Dictionary = Box3DGeometry.create_hull(points, 8)
	return {
		"transform": Transform3D(),
		"hull_mesh": Box3DGeometry.make_array_mesh(hull),
		"density": DENSITY,
	}
