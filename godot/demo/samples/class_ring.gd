extends Node3D

## Class Ring -- a port of upstream's "Bodies / Class Ring" sample
## (samples/sample_bodies.cpp:1187). One dynamic body carrying 24 capsules
## welded into a ring plus a heavy sphere for the gem, stood on its rim, tilted
## 13 degrees and spun at 100 rad/s about the vertical.
##
## Two things make it work, and both are properties on the body rather than
## anything the scene does. `allow_fast_rotation` stops the solver clamping a
## rotation this fast, and contact recycling is turned OFF because the contact
## patch under the rim travels right around the ring every revolution -- reusing
## last step's contacts would keep feeding the solver a patch that has already
## moved on.
##
## The third thing is the step rate. At 60 Hz the ring turns 95 degrees between
## steps and the contact points cannot follow it, so upstream runs this sample
## at 960 Hz with 8 substeps by taking 15 hidden steps per frame. The world here
## has `auto_step` off and this script drives the same 16 x 1/960 s per physics
## tick, which advances exactly one tick of real time.
##
## The gem is the payload: it is twice the density of the band and sits 0.65 m
## off the axis, and that mass asymmetry is what drives the ring's inversion.

const SEGMENTS := 24  # n
const RING_RADIUS := 1.0  # r
const TUBE_RADIUS := 0.1 * RING_RADIUS
const AXIS_RADIUS := RING_RADIUS - TUBE_RADIUS

const GEM_RADIUS := 0.3
const GEM_CENTER := Vector3(0.0, -0.65 * RING_RADIUS, 0.0)
const GEM_DENSITY := 2.0  # the band is 1

const TILT := deg_to_rad(13.0)
const SPIN := 100.0  # rad/s about the body's own y axis

const GROUND_EXTENT := 100.0  # Sample::AddGroundBox(100)

## Upstream's 960 Hz: 16 steps of 1/960 s per 1/60 s tick, 8 substeps each.
const STEP_MULTIPLIER := 16
const SUBSTEPS := 8

var camera_home := Vector3(8.35, 9.5, 9.95)
var camera_look_at := Vector3(0.0, 2.0, 0.0)

var _world: Box3DWorld
var _ring: Box3DBody


func _ready() -> void:
	_world = $Box3DWorld
	_world.substep_count = SUBSTEPS

	var ground := Box3DBody.new()
	ground.name = "Ground"
	ground.body_type = Box3DBody.STATIC
	ground.shape_type = Box3DBody.BOX
	ground.box_size = Vector3(2.0 * GROUND_EXTENT, 2.0, 2.0 * GROUND_EXTENT)
	ground.position = Vector3(0.0, -1.0, 0.0)
	var ground_visual := MeshInstance3D.new()
	var gm := BoxMesh.new()
	gm.size = Vector3(60.0, 2.0, 60.0)  # the collider is 200 m; only draw the near part
	ground_visual.mesh = gm
	var ground_mat := StandardMaterial3D.new()
	ground_mat.albedo_color = Color(0.24, 0.27, 0.3)
	ground_mat.roughness = 0.9
	ground_visual.material_override = ground_mat
	ground.add_child(ground_visual)
	_world.add_child(ground)

	_ring = Box3DBody.new()
	_ring.name = "Ring"
	_ring.position = Vector3(0.0, RING_RADIUS, 0.0)
	_ring.quaternion = Quaternion(Vector3.RIGHT, TILT)
	_ring.allow_fast_rotation = true
	_ring.contact_recycling = false
	_ring.angular_damping = 0.0  # b3DefaultBodyDef; the node defaults to 0.05

	var band_mat := StandardMaterial3D.new()
	band_mat.albedo_color = Color(0.85, 0.72, 0.3)
	band_mat.metallic = 0.9
	band_mat.roughness = 0.25

	# The band: a closed loop of capsules through 24 points on a circle in the
	# body's xy plane, so the ring stands on its rim and its axis is z.
	var points := _band_points()
	for i in SEGMENTS:
		var p1: Vector3 = points[i]
		var p2: Vector3 = points[(i + 1) % SEGMENTS]
		var segment := p2 - p1
		var shape := Box3DCollisionShape.new()
		shape.name = "Link%d" % i
		shape.shape_type = Box3DCollisionShape.CAPSULE
		shape.capsule_radius = TUBE_RADIUS
		# The node's capsule is centred on its own origin and runs along y, so
		# a two-centre capsule becomes midpoint + a rotation onto the segment.
		shape.capsule_height = segment.length() + 2.0 * TUBE_RADIUS
		shape.transform = Transform3D(
			Basis(Quaternion(Vector3.UP, segment.normalized())), 0.5 * (p1 + p2))
		_ring.add_child(shape)

		var visual := MeshInstance3D.new()
		var cap := CapsuleMesh.new()
		cap.radius = TUBE_RADIUS
		cap.height = shape.capsule_height
		cap.radial_segments = 8
		cap.rings = 2
		visual.mesh = cap
		visual.material_override = band_mat
		visual.transform = shape.transform
		_ring.add_child(visual)

	var gem := Box3DCollisionShape.new()
	gem.name = "Gem"
	gem.shape_type = Box3DCollisionShape.SPHERE
	gem.sphere_radius = GEM_RADIUS
	gem.density = GEM_DENSITY
	gem.position = GEM_CENTER
	_ring.add_child(gem)

	var gem_visual := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = GEM_RADIUS
	sm.height = 2.0 * GEM_RADIUS
	gem_visual.mesh = sm
	var gem_mat := StandardMaterial3D.new()
	gem_mat.albedo_color = Color(0.2, 0.5, 0.85)
	gem_mat.metallic = 0.6
	gem_mat.roughness = 0.15
	gem_visual.material_override = gem_mat
	gem_visual.position = GEM_CENTER
	_ring.add_child(gem_visual)

	# Children first, then the world: a shape added after the body is created
	# reads a global transform that has not propagated yet.
	_world.add_child(_ring)

	# b3RotateVector(bodyDef.rotation, {0, 100, 0}): the spin axis is the
	# body's own up, which the tilt has already taken off vertical.
	_ring.set_angular_velocity(_ring.global_transform.basis * Vector3(0.0, SPIN, 0.0))


## Upstream's 15 hidden steps plus the visible one, at 1/960 s each.
func _physics_process(delta: float) -> void:
	var h := delta / float(STEP_MULTIPLIER)
	for i in STEP_MULTIPLIER:
		_world.step(h)


func _band_points() -> PackedVector3Array:
	var out := PackedVector3Array()
	var delta_angle := TAU / SEGMENTS
	for i in SEGMENTS:
		var a := i * delta_angle
		out.append(Vector3(AXIS_RADIUS * cos(a), AXIS_RADIUS * sin(a), 0.0))
	return out


func get_ring() -> Box3DBody:
	return _ring
