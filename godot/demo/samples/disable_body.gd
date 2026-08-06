extends Node3D

## Disable Body -- a port of upstream's "Bodies / Disable" sample
## (samples/sample_bodies.cpp). A four-link capsule chain hangs from a
## kinematic anchor, every link welded to the one above it, with a loose ball
## sitting beside it. Both can be taken OUT of the simulation and put back:
## a disabled body keeps its shapes, joints and pose but stops colliding,
## moving and being solved -- it costs nothing until it is enabled again,
## which is how you park objects that are out of play.
##
##  * the top-bar toggle disables the THIRD link, mid-chain: its joints go
##    with it, so the tail below drops free;
##  * the Activate button disables/enables the ball.
##
## Disabled bodies are drawn washed out here so the state is visible; upstream
## tints them in its debug draw for the same reason.

const LINK_COUNT := 4
const LINK_RADIUS := 0.1
const LINK_LENGTH := 5.0 * LINK_RADIUS
## Which link the toggle disables, upstream's m_bodyIds[2].
const TOGGLED_LINK := 2

var camera_home := Vector3(6.4, 4.2, 6.4)
var camera_look_at := Vector3(0.0, 2.0, 0.0)

var _links: Array[Box3DBody] = []
var _ball: Box3DBody
var _ball_enabled := true

var _link_material := StandardMaterial3D.new()
var _ball_material := StandardMaterial3D.new()
var _off_material := StandardMaterial3D.new()


func _ready() -> void:
	_link_material.albedo_color = Color(0.55, 0.6, 0.7)
	_link_material.roughness = 0.35
	_link_material.metallic = 0.5
	_ball_material.albedo_color = Color(0.86, 0.45, 0.3)
	_ball_material.roughness = 0.5
	_off_material.albedo_color = Color(0.45, 0.47, 0.52, 0.35)
	_off_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_off_material.roughness = 0.8

	var world: Node = $Box3DWorld
	var chain := Node3D.new()
	chain.name = "Chain"
	world.add_child(chain)

	for link in LINK_COUNT:
		var body := _make_link(link)
		chain.add_child(body)
		_links.append(body)

	# Weld each link to its parent at the parent's lower cap, which is exactly
	# where the child's origin sits -- upstream's localFrameA.p = (0, -length, 0).
	for link in range(1, LINK_COUNT):
		var joint := Box3DFixedJoint.new()
		joint.name = "Weld_%d" % link
		joint.position = _links[link].position
		joint.angular_hertz = 10.0
		joint.angular_damping = 1.0
		chain.add_child(joint)
		joint.body_a = joint.get_path_to(_links[link - 1])
		joint.body_b = joint.get_path_to(_links[link])

	_ball = Box3DBody.new()
	_ball.name = "Ball"
	_ball.shape_type = Box3DBody.SPHERE
	_ball.sphere_radius = 0.5
	_ball.position = Vector3(3.0, 3.0, 0.0)
	var ball_mesh := SphereMesh.new()
	ball_mesh.radius = 0.5
	ball_mesh.height = 1.0
	var ball_visual := MeshInstance3D.new()
	ball_visual.name = "MeshInstance3D"
	ball_visual.mesh = ball_mesh
	ball_visual.material_override = _ball_material
	_ball.add_child(ball_visual)
	world.add_child(_ball)


func _make_link(index: int) -> Box3DBody:
	var body := Box3DBody.new()
	body.name = "Link_%d" % index
	# The chain hangs from a kinematic top link; everything below is dynamic.
	body.body_type = Box3DBody.KINEMATIC if index == 0 else Box3DBody.DYNAMIC
	body.position = Vector3(0.0, (LINK_COUNT - index) * LINK_LENGTH + 1.0, 0.0)

	# Upstream's capsule runs from the body origin DOWN to -linkLength, so the
	# collider sits half a link below the origin rather than centred on it.
	var total_height := LINK_LENGTH + 2.0 * LINK_RADIUS
	var shape := Box3DCollisionShape.new()
	shape.name = "Shape"
	shape.shape_type = Box3DCollisionShape.CAPSULE
	shape.capsule_radius = LINK_RADIUS
	shape.capsule_height = total_height
	shape.position = Vector3(0.0, -0.5 * LINK_LENGTH, 0.0)
	body.add_child(shape)

	var mesh := CapsuleMesh.new()
	mesh.radius = LINK_RADIUS
	mesh.height = total_height
	var visual := MeshInstance3D.new()
	visual.name = "MeshInstance3D"
	visual.mesh = mesh
	visual.material_override = _link_material
	visual.position = shape.position
	body.add_child(visual)
	return body


## The shell's reusable sample toggle: ON removes the third link from the sim.
func get_toggle_label() -> String:
	return "Disable Link"


func set_toggled(on: bool) -> void:
	_set_body_enabled(_links[TOGGLED_LINK], not on, _link_material)
	# b3Body_Disable wakes bodies that were TOUCHING the disabled one, but the
	# links below hang off it by a joint, not a contact -- and a chain at rest
	# is asleep within a second. Without this the tail would just hang there
	# with nothing holding it. Waking is the sample's job, not the solver's.
	for link in _links:
		if link.enabled:
			link.set_awake(true)


## The shell's reusable Activate button: flip the ball in and out of the sim.
func activate() -> void:
	_ball_enabled = not _ball_enabled
	_set_body_enabled(_ball, _ball_enabled, _ball_material)


func _set_body_enabled(body: Box3DBody, on: bool, live_material: Material) -> void:
	if body == null:
		return
	body.enabled = on
	var visual := body.get_node_or_null("MeshInstance3D") as MeshInstance3D
	if visual != null:
		visual.material_override = live_material if on else _off_material

