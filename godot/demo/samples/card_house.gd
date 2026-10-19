extends Node3D

## Card House -- a port of upstream's "Stacking / Card House" sample
## (samples/sample_stacking.cpp:15-87). A five-storey house of playing cards:
## pairs of cards leaning on each other at plus and minus 25 degrees, roofed
## by flat cards, each storey one pair narrower than the one below.
##
## Upstream's numbers are kept: cards 0.4 m tall, 0.2 m deep and 0.002 m
## thick (half extents 0.2, 0.1, 0.001 as a box hull, :32-42) with friction
## 0.7 and rolling resistance 0.05 (:28-30), density 1000 (b3DefaultShapeDef;
## the node default is 1), on AddGroundBox(10) under gravity -10, laid out by
## upstream's own loop (:44-79): leaning pairs 0.175 m apart along x, a flat
## card at +0.25 m above every pair but the last, storeys 0.37 m apart.
## Upstream's own comment (:39) notes the box hull is what limits how thin a
## card can be, which is the hard part of this test: contacts between very
## thin hulls standing on their edges.

const CARD_HEIGHT := 0.2
const CARD_THICKNESS := 0.001
const CARD_DEPTH := 0.1
const LEAN := deg_to_rad(25.0)
const STOREYS := 5
const DENSITY := 1000.0
const FRICTION := 0.7
const ROLLING_RESISTANCE := 0.05

## m_camera->SetView(30, 10, 3, {0.75, 1, 0.4}) (:22): eye = pivot + radius *
## (sin yaw cos pitch, sin pitch, cos yaw cos pitch)
## (samples/host/camera.cpp:35-39,216-220).
var camera_home := Vector3(0.75, 1.0, 0.4) + 3.0 * Vector3(
		sin(deg_to_rad(30.0)) * cos(deg_to_rad(10.0)),
		sin(deg_to_rad(10.0)),
		cos(deg_to_rad(30.0)) * cos(deg_to_rad(10.0)))
var camera_look_at := Vector3(0.75, 1.0, 0.4)


func _ready() -> void:
	var world := $Box3DWorld
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.92, 0.9, 0.84)
	material.roughness = 0.6
	var mesh := BoxMesh.new()
	mesh.size = 2.0 * Vector3(CARD_THICKNESS, CARD_HEIGHT, CARD_DEPTH)
	var index := 0
	for card: Dictionary in rig_bodies():
		var body := Box3DBody.new()
		body.name = "Card%d" % index
		body.box_size = card["size"]
		body.density = DENSITY
		body.friction = FRICTION
		body.rolling_resistance = ROLLING_RESISTANCE
		body.angular_damping = 0.0
		body.transform = card["transform"]
		var visual := MeshInstance3D.new()
		visual.mesh = mesh
		visual.material_override = material
		body.add_child(visual)
		world.add_child(body)
		index += 1


## Upstream's layout loop (:44-79), shared with the comparison rig.
func rig_bodies() -> Array:
	var size := 2.0 * Vector3(CARD_THICKNESS, CARD_HEIGHT, CARD_DEPTH)
	var out: Array = []
	var count := STOREYS
	var z0 := 0.0
	var y := CARD_HEIGHT - 0.02
	while count > 0:
		var z := z0
		for i in range(count):
			if i != count - 1:
				out.append(_card(Vector3(z + 0.25, y + CARD_HEIGHT - 0.015, 0.0), 0.5 * PI, size))
			out.append(_card(Vector3(z, y, 0.0), -LEAN, size))
			z += 0.175
			out.append(_card(Vector3(z, y, 0.0), LEAN, size))
			z += 0.175
		y += CARD_HEIGHT * 2.0 - 0.03
		z0 += 0.175
		count -= 1
	return out


func _card(position: Vector3, angle: float, size: Vector3) -> Dictionary:
	return {
		"transform": Transform3D(Basis(Vector3(0.0, 0.0, 1.0), angle), position),
		"size": size,
		"density": DENSITY,
		"friction": FRICTION,
	}
