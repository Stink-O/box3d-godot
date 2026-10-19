extends RefCounted

## Upstream's human ragdoll prefab, CreateHuman from shared/human.c:13-413,
## for the samples that spawn several of them (Ragdoll Pile). Twelve bones,
## each a dynamic body built at its reference frame offset by the spawn
## position, with upstream's capsules (the calves carry a second, half-density
## foot capsule), friction and rolling resistance per bone, density 1000, and
## a spherical joint (Box3DBallJoint: cone + twist limits) or a revolute joint
## (Box3DHingeJoint: angle limits) to its parent with upstream's exact local
## frames. Every joint gets the spring (when hertz > 0) and the joint
## friction upstream uses: a zero-velocity motor whose torque budget is the
## bone's jointFriction times frictionTorque. Filter joints keep the two
## thighs, and the neck and each upper arm, from colliding (:399-410), and
## the spine_01 and thigh shapes carry group index -groupIndex (:75, :150,
## :204), so a pile can make each human ignore its own bones there.
##
## The table below is upstream's verbatim (generated from shared/human.c, not
## retyped): reference frames, capsule end centres and radii, joint frames,
## limits in degrees, joint friction scale.
##
## Joint frames: a Box3DJoint derives its frames from its node transform, so
## the node is placed at the parent's frame A and the two frames are then set
## to upstream's localFrameA / localFrameB with set_local_frame_a/b. They
## are not the same pose: upstream's frames encode a rest twist the reference
## frames do not, and the springs pull toward it.

## The bone table (shared/human.c:45-348). "group" is "G" where upstream sets
## shapeDef.filter.groupIndex = -groupIndex, "0" where it sets 0.
static var BONES: Array = [
	{
		"name": "pelvis", "parent": -1,
		"reference": Transform3D(Basis(Quaternion(1.0, 0.0, 0.0, 0.0).normalized()), Vector3(0.0, 0.996219, -0.023868)),
		"group": "0", "friction": 0.6, "rolling_resistance": 0.1,
		"capsules": [[Vector3(0.04, 1e-06, 0.0), Vector3(-0.04, -1e-06, 0.0), 0.15, 1.0]],
	},
	{
		"name": "spine_01", "parent": 0,
		"reference": Transform3D(Basis(Quaternion(1.0, 0.0, 0.0, 0.0).normalized()), Vector3(0.0, 1.017288, -0.024882)),
		"group": "G", "friction": 0.5, "rolling_resistance": 0.1,
		"capsules": [[Vector3(0.029876, -0.146581, 0.00626), Vector3(-0.029876, -0.146574, 0.00626), 0.145663, 1.0]],
		"joint": "spherical", "frame_a": Transform3D(Basis(Quaternion(-0.642737, 0.0, 0.0, -0.766087).normalized()), Vector3(0.0, -0.021069, 0.001014)), "frame_b": Transform3D(Basis(Quaternion(-0.707107, 0.0, 0.0, -0.707107).normalized()), Vector3(0.0, 0.0, 0.0)),
		"swing": 35.0, "twist": Vector2(-17.5, 17.5), "joint_friction": 1.0,
	},
	{
		"name": "spine_03", "parent": 1,
		"reference": Transform3D(Basis(Quaternion(1.0, 0.0, 0.0, 0.0).normalized()), Vector3(0.0, 1.267766, -0.02232)),
		"group": "0", "friction": 0.5, "rolling_resistance": 0.1,
		"capsules": [[Vector3(0.063996, -0.117434, -0.040199), Vector3(-0.063996, -0.117432, -0.040199), 0.165004, 1.0]],
		"joint": "spherical", "frame_a": Transform3D(Basis(Quaternion(-0.642766, 0.0, 0.0, -0.766063).normalized()), Vector3(0.0, -0.250478, -0.002562)), "frame_b": Transform3D(Basis(Quaternion(-0.707107, 0.0, 0.0, -0.707107).normalized()), Vector3(0.0, 0.0, 0.0)),
		"swing": 35.0, "twist": Vector2(-17.5, 17.5), "joint_friction": 1.0,
	},
	{
		"name": "neck", "parent": 2,
		"reference": Transform3D(Basis(Quaternion(0.987879, 0.0, 0.0, 0.155228).normalized()), Vector3(0.0, 1.498783, 0.024462)),
		"group": "0", "friction": 0.2, "rolling_resistance": 0.05,
		"capsules": [[Vector3(0.0, -0.21234, 0.0), Vector3(0.0, -0.08734, 0.0), 0.11, 1.0]],
		"joint": "spherical", "frame_a": Transform3D(Basis(Quaternion(-0.516157, -2e-06, 3e-06, -0.856494).normalized()), Vector3(0.0, -0.231017, -0.046781)), "frame_b": Transform3D(Basis(Quaternion(-0.707108, -2e-06, 2e-06, -0.707106).normalized()), Vector3(0.0, 0.0, 0.0)),
		"swing": 30.0, "twist": Vector2(-17.5, 17.5), "joint_friction": 1.0,
	},
	{
		"name": "thigh_l", "parent": 0,
		"reference": Transform3D(Basis(Quaternion(0.471412, 0.52951, -0.499888, -0.497495).normalized()), Vector3(0.092175, 0.971562, -0.011177)),
		"group": "G", "friction": 0.6, "rolling_resistance": 0.1,
		"capsules": [[Vector3(-0.047269, 1e-06, 0.0), Vector3(-0.379769, 5e-06, 0.0), 0.091539, 1.0]],
		"joint": "spherical", "frame_a": Transform3D(Basis(Quaternion(-0.460186, -0.365368, -0.637662, 0.498118).normalized()), Vector3(0.092175, 0.024656, -0.012691)), "frame_b": Transform3D(Basis(Quaternion(-0.499997, -0.500003, 0.500002, 0.499998).normalized()), Vector3(0.0, 0.0, 0.0)),
		"swing": 30.0, "twist": Vector2(-10.0, 10.0), "joint_friction": 1.0,
	},
	{
		"name": "calf_l", "parent": 4,
		"reference": Transform3D(Basis(Quaternion(0.521188, 0.480597, -0.54638, -0.445935).normalized()), Vector3(0.11872, 0.534541, -0.035362)),
		"group": "0", "friction": 0.1, "rolling_resistance": 0.0,
		"capsules": [[Vector3(-0.445, 1e-06, 0.0), Vector3(0.005, -1e-06, 0.0), 0.08, 1.0], [Vector3(-0.456371, 0.129321, 1.3e-05), Vector3(-0.359977, 0.014394, 1.3e-05), 0.07, 0.5]],
		"joint": "revolute", "frame_a": Transform3D(Basis(Quaternion(0.344866, -0.938652, 2e-06, -8e-06).normalized()), Vector3(-0.438494, -0.000175, 0.0)), "frame_b": Transform3D(Basis(Quaternion(-0.008182, -0.999967, 1e-06, -7e-06).normalized()), Vector3(0.0, 0.0, 0.0)),
		"swing": 0.0, "twist": Vector2(-30.0, 30.0), "joint_friction": 1.0,
	},
	{
		"name": "thigh_r", "parent": 0,
		"reference": Transform3D(Basis(Quaternion(-0.497495, 0.499888, 0.52951, -0.471412).normalized()), Vector3(-0.092175, 0.971562, -0.011177)),
		"group": "G", "friction": 0.6, "rolling_resistance": 0.1,
		"capsules": [[Vector3(0.047269, -1e-06, 0.0), Vector3(0.379769, -5e-06, 0.0), 0.092587, 1.0]],
		"joint": "spherical", "frame_a": Transform3D(Basis(Quaternion(0.380666, 0.491846, 0.488644, -0.611889).normalized()), Vector3(-0.092175, 0.024656, -0.012691)), "frame_b": Transform3D(Basis(Quaternion(-0.500002, 0.499998, -0.499998, 0.500002).normalized()), Vector3(0.0, 0.0, 0.0)),
		"swing": 30.0, "twist": Vector2(-10.0, 10.0), "joint_friction": 1.0,
	},
	{
		"name": "calf_r", "parent": 6,
		"reference": Transform3D(Basis(Quaternion(-0.445935, 0.54638, 0.480597, -0.521188).normalized()), Vector3(-0.11872, 0.534541, -0.035362)),
		"group": "0", "friction": 0.1, "rolling_resistance": 0.0,
		"capsules": [[Vector3(0.445, -2e-06, 3e-06), Vector3(-0.005, 0.0, 3e-06), 0.08, 1.0], [Vector3(0.369113, -0.00683, 1.7e-05), Vector3(0.465507, -0.121757, 1.7e-05), 0.07, 0.5]],
		"joint": "revolute", "frame_a": Transform3D(Basis(Quaternion(7e-06, 5e-06, -0.34486, -0.938654).normalized()), Vector3(0.438494, 0.000175, 0.0)), "frame_b": Transform3D(Basis(Quaternion(6e-06, 5e-06, 0.008188, -0.999966).normalized()), Vector3(0.0, 0.0, 0.0)),
		"swing": 0.0, "twist": Vector2(-30.0, 30.0), "joint_friction": 1.0,
	},
	{
		"name": "upper_arm_l", "parent": 2,
		"reference": Transform3D(Basis(Quaternion(0.56022, -0.307179, 0.366233, -0.676512).normalized()), Vector3(0.185817, 1.44363, 0.031306)),
		"group": "0", "friction": 0.6, "rolling_resistance": 0.1,
		"capsules": [[Vector3(0.296038, 0.004386, -0.000794), Vector3(-0.016086, 0.004384, -0.016127), 0.065, 1.0]],
		"joint": "spherical", "frame_a": Transform3D(Basis(Quaternion(-0.559466, -0.213784, -0.670199, 0.438323).normalized()), Vector3(0.185817, -0.175865, -0.053625)), "frame_b": Transform3D(Basis(Quaternion(-0.500953, -0.502617, -0.509318, -0.486844).normalized()), Vector3(0.0, 0.0, 0.0)),
		"swing": 45.0, "twist": Vector2(-20.0, 20.0), "joint_friction": 0.8,
	},
	{
		"name": "lower_arm_l", "parent": 8,
		"reference": Transform3D(Basis(Quaternion(0.406736, -0.493012, 0.089135, -0.763911).normalized()), Vector3(0.347683, 1.193455, 0.029378)),
		"group": "0", "friction": 0.3, "rolling_resistance": 0.1,
		"capsules": [[Vector3(0.312329, -0.008256, -0.016454), Vector3(0.033153, 0.008259, -0.002741), 0.06, 1.0]],
		"joint": "revolute", "frame_a": Transform3D(Basis(Quaternion(0.916726, 0.399352, 0.000839, -0.011456).normalized()), Vector3(0.297979, 0.000361, 0.0)), "frame_b": Transform3D(Basis(Quaternion(0.999922, -0.003857, 0.004659, -0.010908).normalized()), Vector3(0.0, 0.0, 0.0)),
		"swing": 0.0, "twist": Vector2(-35.0, 35.0), "joint_friction": 0.06,
	},
	{
		"name": "upper_arm_r", "parent": 2,
		"reference": Transform3D(Basis(Quaternion(0.676512, 0.366233, 0.307179, 0.56022).normalized()), Vector3(-0.185817, 1.44363, 0.031306)),
		"group": "0", "friction": 0.6, "rolling_resistance": 0.1,
		"capsules": [[Vector3(-0.300237, -1e-06, -0.000319), Vector3(0.011887, 1e-06, 0.015013), 0.065, 1.0]],
		"joint": "spherical", "frame_a": Transform3D(Basis(Quaternion(0.213793, 0.559449, 0.438334, -0.670204).normalized()), Vector3(-0.185817, -0.175865, -0.053625)), "frame_b": Transform3D(Basis(Quaternion(-0.509319, 0.486843, 0.500954, -0.502617).normalized()), Vector3(0.0, 0.0, 0.0)),
		"swing": 45.0, "twist": Vector2(-20.0, 20.0), "joint_friction": 0.8,
	},
	{
		"name": "lower_arm_r", "parent": 10,
		"reference": Transform3D(Basis(Quaternion(0.763911, 0.089135, 0.493012, 0.406736).normalized()), Vector3(-0.347683, 1.193455, 0.029378)),
		"group": "0", "friction": 0.3, "rolling_resistance": 0.1,
		"capsules": [[Vector3(-0.312649, -3e-06, 0.016471), Vector3(-0.032986, 0.0, 0.002732), 0.06, 1.0]],
		"joint": "revolute", "frame_a": Transform3D(Basis(Quaternion(-0.405444, 0.914059, 0.010541, 0.000852).normalized()), Vector3(-0.297979, -0.000361, 0.0)), "frame_b": Transform3D(Basis(Quaternion(-0.002794, 0.999936, 0.010042, 0.004364).normalized()), Vector3(0.0, 0.0, 0.0)),
		"swing": 0.0, "twist": Vector2(-35.0, 35.0), "joint_friction": 0.06,
	},

]

## Upstream's filter joints (:399-410), by bone index.
const FILTERED_PAIRS := [[4, 6], [3, 8], [3, 10]]

## b3DefaultShapeDef's density (the node default is 1).
const DENSITY := 1000.0


## CreateHuman (shared/human.c:13-413). Builds the ragdoll under `parent`
## (which must be inside a Box3DWorld), returns its bodies in bone order.
static func create(parent: Node3D, position: Vector3, friction_torque: float, hertz: float,
		damping_ratio: float, group_index: int, material: Material = null) -> Array[Box3DBody]:
	var bodies: Array[Box3DBody] = []
	for bone: Dictionary in BONES:
		var body := Box3DBody.new()
		body.name = String(bone["name"])
		body.angular_damping = 0.0  # b3DefaultBodyDef
		var reference: Transform3D = bone["reference"]
		body.transform = Transform3D(reference.basis, position + reference.origin)
		for capsule: Array in bone["capsules"]:
			_add_capsule(body, capsule[0], capsule[1], capsule[2], DENSITY * float(capsule[3]),
					bone["friction"], bone["rolling_resistance"],
					-group_index if bone["group"] == "G" else 0, material)
		parent.add_child(body)
		bodies.append(body)

	for i in range(1, BONES.size()):
		var bone: Dictionary = BONES[i]
		var a: Box3DBody = bodies[int(bone["parent"])]
		var b: Box3DBody = bodies[i]
		var frame_a: Transform3D = bone["frame_a"]
		var frame_b: Transform3D = bone["frame_b"]
		var limit_twist: Vector2 = bone["twist"] * (PI / 180.0)
		var motor_torque: float = float(bone["joint_friction"]) * friction_torque
		var joint: Box3DJoint
		if bone["joint"] == "revolute":
			var hinge := Box3DHingeJoint.new()
			hinge.limit_enabled = true
			hinge.lower_limit = limit_twist.x
			hinge.upper_limit = limit_twist.y
			hinge.spring_enabled = hertz > 0.0
			hinge.spring_hertz = hertz
			hinge.spring_damping = damping_ratio
			hinge.motor_enabled = true
			hinge.motor_speed = 0.0
			hinge.max_motor_torque = motor_torque
			joint = hinge
		else:
			var ball := Box3DBallJoint.new()
			ball.cone_limit_enabled = true
			ball.cone_angle = deg_to_rad(float(bone["swing"]))
			ball.twist_limit_enabled = true
			ball.twist_lower = limit_twist.x
			ball.twist_upper = limit_twist.y
			ball.spring_enabled = hertz > 0.0
			ball.spring_hertz = hertz
			ball.spring_damping = damping_ratio
			ball.motor_enabled = true
			ball.motor_velocity = Vector3.ZERO
			ball.max_motor_torque = motor_torque
			joint = ball
		joint.name = "%s_joint" % bone["name"]
		joint.transform = a.transform * frame_a
		joint.body_a = NodePath("../" + String(a.name))
		joint.body_b = NodePath("../" + String(b.name))
		parent.add_child(joint)
		joint.set_local_frame_a(frame_a)
		joint.set_local_frame_b(frame_b)

	for pair: Array in FILTERED_PAIRS:
		var filter := Box3DFilterJoint.new()
		filter.name = "filter_%s_%s" % [bodies[pair[0]].name, bodies[pair[1]].name]
		filter.body_a = NodePath("../" + String(bodies[pair[0]].name))
		filter.body_b = NodePath("../" + String(bodies[pair[1]].name))
		parent.add_child(filter)
	return bodies


## A b3Capsule from its two end centres in the body's frame: a Y-aligned
## Box3DCollisionShape turned onto the segment, with a matching mesh.
static func _add_capsule(body: Box3DBody, c1: Vector3, c2: Vector3, radius: float, density: float,
		friction: float, rolling_resistance: float, group: int, material: Material) -> void:
	var axis := c2 - c1
	var length := axis.length()
	var y := axis / length
	var x := y.cross(Vector3.FORWARD)
	if x.length_squared() < 0.25:
		x = y.cross(Vector3.RIGHT)
	x = x.normalized()
	var xf := Transform3D(Basis(x, y, x.cross(y)), 0.5 * (c1 + c2))
	var shape := Box3DCollisionShape.new()
	shape.shape_type = Box3DCollisionShape.CAPSULE
	shape.capsule_radius = radius
	shape.capsule_height = length + 2.0 * radius
	shape.density = density
	shape.friction = friction
	shape.rolling_resistance = rolling_resistance
	if group != 0:
		shape.filter_override = true
		shape.collision_group = group
	shape.transform = xf
	body.add_child(shape)
	var mesh := CapsuleMesh.new()
	mesh.radius = radius
	mesh.height = length + 2.0 * radius
	mesh.radial_segments = 16
	mesh.rings = 4
	var visual := MeshInstance3D.new()
	visual.mesh = mesh
	visual.transform = xf
	if material != null:
		visual.material_override = material
	body.add_child(visual)
