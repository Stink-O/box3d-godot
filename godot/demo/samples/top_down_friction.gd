extends Node3D

## Top Down Friction -- a port of upstream's "Joints / Top Down Friction"
## sample (samples/sample_joint.cpp). A hundred pieces float in a walled
## arena with gravity switched off, as if seen from above in a top-down
## game. Each one is tied to the static ground by a MOTOR JOINT whose target
## velocity is zero: the joint constantly pushes the body's linear and
## angular velocity back to nothing, up to a 1000 N / 1000 N.m budget, which
## is exactly the "friction against the floor you cannot see" a top-down game
## needs. There is no floor under them and no damping on the bodies -- the
## drag is entirely the joints.
##
## `collide_connected` is on, otherwise a body jointed to the ground would
## stop colliding with the walls, which are shapes on that same ground body.
##
## Upstream's Explode button is the shell's Activate: a 10 m blast at the
## centre with 10000 impulse per unit area and a falloff of 5. Watch the
## pieces scatter, bounce off the walls (restitution 0.8) and be reeled to a
## halt by their motors. The blast peaks over 300 m/s, so the odd piece does
## punch through a wall -- upstream's bodies are not bullets either.

const N := 10
const START := Vector2(-5.0, 15.0)
const RESTITUTION := 0.8
const MAX_FORCE := 1000.0
const MAX_TORQUE := 1000.0

const CAPSULE_RADIUS := 0.25
## Upstream's capsule runs along X between (-0.25, 0) and (0.25, 0):
## |c2 - c1| + 2r as a Godot capsule, laid on its side.
const CAPSULE_HEIGHT := 1.0
const SPHERE_RADIUS := 0.35
const BOX_SIZE := Vector3(0.7, 0.7, 0.7)

const BLAST_CENTER := Vector3(0.0, 10.0, 0.0)
const BLAST_RADIUS := 10.0
const BLAST_IMPULSE := 10000.0
const BLAST_FALLOFF := 5.0

var camera_home := Vector3(0.0, 10.0, 26.0)
var camera_look_at := Vector3(0.0, 10.0, 0.0)

var _capsule_mesh := CapsuleMesh.new()
var _sphere_mesh := SphereMesh.new()
var _box_mesh := BoxMesh.new()
var _materials: Array[StandardMaterial3D] = []


func _ready() -> void:
	_capsule_mesh.radius = CAPSULE_RADIUS
	_capsule_mesh.height = CAPSULE_HEIGHT
	_sphere_mesh.radius = SPHERE_RADIUS
	_sphere_mesh.height = 2.0 * SPHERE_RADIUS
	_box_mesh.size = BOX_SIZE
	for c in [Color(0.85, 0.5, 0.35), Color(0.45, 0.72, 0.85), Color(0.72, 0.78, 0.5)]:
		var m := StandardMaterial3D.new()
		m.albedo_color = c
		m.roughness = 0.45
		_materials.append(m)

	var pieces := Node3D.new()
	pieces.name = "Pieces"
	$Box3DWorld.add_child(pieces)

	var x := START.x
	var y := START.y
	for i in N:
		for j in N:
			var kind := (N * i + j) % 4
			var body := _make_piece(kind, Vector3(x, y, 0.0))
			body.name = "Piece_%d_%d" % [i, j]
			pieces.add_child(body)

			var joint := Box3DMotorJoint.new()
			joint.name = "Motor_%d_%d" % [i, j]
			# Frame B sits on the body's own origin, as upstream's identity
			# localFrameB does. Frame A lands wherever that is in the static
			# ground's space, which a zero-velocity motor does not care about.
			joint.position = body.position
			joint.collide_connected = true
			joint.max_force = MAX_FORCE
			joint.max_torque = MAX_TORQUE
			joint.linear_velocity = Vector3.ZERO
			joint.angular_velocity = Vector3.ZERO
			pieces.add_child(joint)
			joint.body_a = joint.get_path_to($Box3DWorld/Ground)
			joint.body_b = NodePath("../%s" % body.name)

			x += 1.0
		x = START.x
		y -= 1.0


## The shell's reusable Activate button: upstream's Explode.
func activate() -> void:
	$Box3DWorld.explode(BLAST_CENTER, BLAST_RADIUS, BLAST_IMPULSE, BLAST_FALLOFF)


func _make_piece(kind: int, pos: Vector3) -> Box3DBody:
	var body := Box3DBody.new()
	body.gravity_scale = 0.0
	body.restitution = RESTITUTION
	var visual := MeshInstance3D.new()
	match kind:
		0:
			body.shape_type = Box3DBody.CAPSULE
			body.capsule_radius = CAPSULE_RADIUS
			body.capsule_height = CAPSULE_HEIGHT
			# Box3D's capsule is authored along X; Godot's is along Y.
			body.transform = Transform3D(Basis(Vector3.BACK, 0.5 * PI), pos)
			visual.mesh = _capsule_mesh
		1:
			body.shape_type = Box3DBody.SPHERE
			body.sphere_radius = SPHERE_RADIUS
			body.position = pos
			visual.mesh = _sphere_mesh
		_:
			body.shape_type = Box3DBody.BOX
			body.box_size = BOX_SIZE
			body.position = pos
			visual.mesh = _box_mesh
	visual.material_override = _materials[kind % _materials.size()]
	body.add_child(visual)
	return body
