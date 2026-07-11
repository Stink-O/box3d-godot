// SPDX-FileCopyrightText: 2026 box3d-godot contributors
// SPDX-License-Identifier: MIT

#pragma once

#include <godot_cpp/classes/node3d.hpp>

#include <box3d/box3d.h>

namespace godot {

class Box3DWorld;
class Box3DBody;

// Base class for Box3D joints. A joint connects `body_a` to `body_b`; if
// `body_b` is left empty the joint anchors to the world at this node's
// position. The node's own transform defines the joint frame (anchor + axes).
class Box3DJoint : public Node3D {
	GDCLASS(Box3DJoint, Node3D)

protected:
	b3JointId joint_id = b3_nullJointId;
	b3BodyId anchor_id = b3_nullBodyId; // static body created when body_b is empty
	Box3DWorld *world = nullptr;

	NodePath body_a_path;
	NodePath body_b_path;
	bool collide_connected = false;

	Box3DWorld *find_world();
	Box3DBody *resolve_body(const NodePath &p_path);
	// The joint frame expressed in a body's local space.
	b3Transform local_frame(const Transform3D &p_body, const Transform3D &p_joint) const;
	void rebuild_if_alive();
	// Wake both connected bodies. box3d's motor-target setters only store the
	// value, so a sleeping body would ignore a new drive command; every setter
	// that changes a drive target calls this.
	void wake_bodies();

	// Subclasses fill in their specific joint def and create it.
	virtual b3JointId create_specific(b3WorldId p_world, b3BodyId p_a, b3BodyId p_b,
			const Transform3D &p_xf_a, const Transform3D &p_xf_b, const Transform3D &p_joint) {
		return b3_nullJointId;
	}

	static void _bind_methods();
	void _notification(int p_what);

public:
	Box3DJoint();
	~Box3DJoint();

	void create_joint();
	void destroy_joint();
	bool is_joint_valid() const;

	void set_body_a(const NodePath &p_path);
	NodePath get_body_a() const;
	void set_body_b(const NodePath &p_path);
	NodePath get_body_b() const;
	void set_collide_connected(bool p_enabled);
	bool get_collide_connected() const;
};

// Revolute joint: rotates about this node's local Z axis (the blue gizmo arrow).
class Box3DHingeJoint : public Box3DJoint {
	GDCLASS(Box3DHingeJoint, Box3DJoint)

	bool limit_enabled = false;
	double lower_limit = 0.0; // radians
	double upper_limit = 0.0; // radians
	bool motor_enabled = false;
	double motor_speed = 0.0; // radians / second
	double max_motor_torque = 0.0;
	bool spring_enabled = false;
	double spring_hertz = 1.0;
	double spring_damping = 0.7;

protected:
	static void _bind_methods();
	b3JointId create_specific(b3WorldId p_world, b3BodyId p_a, b3BodyId p_b,
			const Transform3D &p_xf_a, const Transform3D &p_xf_b, const Transform3D &p_joint) override;

public:
	void set_limit_enabled(bool p_v);
	bool get_limit_enabled() const;
	void set_lower_limit(double p_v);
	double get_lower_limit() const;
	void set_upper_limit(double p_v);
	double get_upper_limit() const;
	void set_motor_enabled(bool p_v);
	bool get_motor_enabled() const;
	void set_motor_speed(double p_v);
	double get_motor_speed() const;
	void set_max_motor_torque(double p_v);
	double get_max_motor_torque() const;
	void set_spring_enabled(bool p_v);
	bool get_spring_enabled() const;
	void set_spring_hertz(double p_v);
	double get_spring_hertz() const;
	void set_spring_damping(double p_v);
	double get_spring_damping() const;
};

// Prismatic joint: body_b slides along this node's local X axis (the red gizmo arrow).
class Box3DSliderJoint : public Box3DJoint {
	GDCLASS(Box3DSliderJoint, Box3DJoint)

	bool limit_enabled = false;
	double lower_limit = 0.0; // meters
	double upper_limit = 0.0; // meters
	bool motor_enabled = false;
	double motor_speed = 0.0; // meters / second
	double max_motor_force = 0.0;

protected:
	static void _bind_methods();
	b3JointId create_specific(b3WorldId p_world, b3BodyId p_a, b3BodyId p_b,
			const Transform3D &p_xf_a, const Transform3D &p_xf_b, const Transform3D &p_joint) override;

public:
	void set_limit_enabled(bool p_v);
	bool get_limit_enabled() const;
	void set_lower_limit(double p_v);
	double get_lower_limit() const;
	void set_upper_limit(double p_v);
	double get_upper_limit() const;
	void set_motor_enabled(bool p_v);
	bool get_motor_enabled() const;
	void set_motor_speed(double p_v);
	double get_motor_speed() const;
	void set_max_motor_force(double p_v);
	double get_max_motor_force() const;
};

// Distance joint: keeps body_a and body_b a set distance apart. Rope / rod / spring.
class Box3DDistanceJoint : public Box3DJoint {
	GDCLASS(Box3DDistanceJoint, Box3DJoint)

	double length = -1.0; // < 0 means "use the current distance between bodies"
	bool spring_enabled = false;
	double spring_hertz = 4.0;
	double spring_damping = 0.5;
	bool limit_enabled = false;
	double min_length = 0.0;
	double max_length = 10.0;

protected:
	static void _bind_methods();
	b3JointId create_specific(b3WorldId p_world, b3BodyId p_a, b3BodyId p_b,
			const Transform3D &p_xf_a, const Transform3D &p_xf_b, const Transform3D &p_joint) override;

public:
	void set_length(double p_v);
	double get_length() const;
	void set_spring_enabled(bool p_v);
	bool get_spring_enabled() const;
	void set_spring_hertz(double p_v);
	double get_spring_hertz() const;
	void set_spring_damping(double p_v);
	double get_spring_damping() const;
	void set_limit_enabled(bool p_v);
	bool get_limit_enabled() const;
	void set_min_length(double p_v);
	double get_min_length() const;
	void set_max_length(double p_v);
	double get_max_length() const;
};

// Ball / spherical joint: a point on body_b is pinned to a point on body_a,
// free to rotate. Good for ragdoll shoulders, chains, pendulums. Optional cone
// and twist limits constrain the rotation range (about the node's local Z).
class Box3DBallJoint : public Box3DJoint {
	GDCLASS(Box3DBallJoint, Box3DJoint)

	bool cone_limit_enabled = false;
	double cone_angle = 0.5; // radians, half-angle of the cone
	bool twist_limit_enabled = false;
	double twist_lower = 0.0; // radians
	double twist_upper = 0.0; // radians
	bool spring_enabled = false;
	double spring_hertz = 1.0;
	double spring_damping = 0.7;
	double friction_torque = 0.0; // > 0 enables a zero-target motor = dry joint friction

protected:
	static void _bind_methods();
	b3JointId create_specific(b3WorldId p_world, b3BodyId p_a, b3BodyId p_b,
			const Transform3D &p_xf_a, const Transform3D &p_xf_b, const Transform3D &p_joint) override;

public:
	void set_cone_limit_enabled(bool p_v);
	bool get_cone_limit_enabled() const;
	void set_cone_angle(double p_v);
	double get_cone_angle() const;
	void set_twist_limit_enabled(bool p_v);
	bool get_twist_limit_enabled() const;
	void set_twist_lower(double p_v);
	double get_twist_lower() const;
	void set_twist_upper(double p_v);
	double get_twist_upper() const;
	void set_spring_enabled(bool p_v);
	bool get_spring_enabled() const;
	void set_spring_hertz(double p_v);
	double get_spring_hertz() const;
	void set_spring_damping(double p_v);
	double get_spring_damping() const;
	void set_friction_torque(double p_v);
	double get_friction_torque() const;
};

// Fixed / weld joint: rigidly locks two bodies together.
class Box3DFixedJoint : public Box3DJoint {
	GDCLASS(Box3DFixedJoint, Box3DJoint)

	double linear_hertz = 0.0;  // 0 = perfectly rigid
	double angular_hertz = 0.0; // 0 = perfectly rigid

protected:
	static void _bind_methods();
	b3JointId create_specific(b3WorldId p_world, b3BodyId p_a, b3BodyId p_b,
			const Transform3D &p_xf_a, const Transform3D &p_xf_b, const Transform3D &p_joint) override;

public:
	void set_linear_hertz(double p_v);
	double get_linear_hertz() const;
	void set_angular_hertz(double p_v);
	double get_angular_hertz() const;
};

// Wheel joint: body_a is the chassis, body_b the wheel. The wheel travels on a
// suspension spring along the node's local Y (the green gizmo arrow), spins
// about the node's local Z (the axle), and can optionally steer about the
// suspension axis. This is box3d's vehicle joint — see the Car sample, which
// mirrors upstream's "Driving" sample.
class Box3DWheelJoint : public Box3DJoint {
	GDCLASS(Box3DWheelJoint, Box3DJoint)

	bool suspension_enabled = true;
	double suspension_hertz = 1.0;
	double suspension_damping = 0.7;
	bool suspension_limit_enabled = false;
	double lower_suspension_limit = 0.0; // meters
	double upper_suspension_limit = 0.0; // meters
	bool spin_motor_enabled = false;
	double spin_motor_speed = 0.0; // radians / second
	double max_spin_torque = 0.0;
	bool steering_enabled = false;
	double steering_hertz = 1.0;
	double steering_damping = 0.7;
	double target_steering_angle = 0.0; // radians
	double max_steering_torque = 0.0;
	bool steering_limit_enabled = false;
	double lower_steering_limit = 0.0; // radians
	double upper_steering_limit = 0.0; // radians

protected:
	static void _bind_methods();
	b3JointId create_specific(b3WorldId p_world, b3BodyId p_a, b3BodyId p_b,
			const Transform3D &p_xf_a, const Transform3D &p_xf_b, const Transform3D &p_joint) override;

public:
	void set_suspension_enabled(bool p_v);
	bool get_suspension_enabled() const;
	void set_suspension_hertz(double p_v);
	double get_suspension_hertz() const;
	void set_suspension_damping(double p_v);
	double get_suspension_damping() const;
	void set_suspension_limit_enabled(bool p_v);
	bool get_suspension_limit_enabled() const;
	void set_lower_suspension_limit(double p_v);
	double get_lower_suspension_limit() const;
	void set_upper_suspension_limit(double p_v);
	double get_upper_suspension_limit() const;
	void set_spin_motor_enabled(bool p_v);
	bool get_spin_motor_enabled() const;
	void set_spin_motor_speed(double p_v);
	double get_spin_motor_speed() const;
	void set_max_spin_torque(double p_v);
	double get_max_spin_torque() const;
	void set_steering_enabled(bool p_v);
	bool get_steering_enabled() const;
	void set_steering_hertz(double p_v);
	double get_steering_hertz() const;
	void set_steering_damping(double p_v);
	double get_steering_damping() const;
	void set_target_steering_angle(double p_v);
	double get_target_steering_angle() const;
	void set_max_steering_torque(double p_v);
	double get_max_steering_torque() const;
	void set_steering_limit_enabled(bool p_v);
	bool get_steering_limit_enabled() const;
	void set_lower_steering_limit(double p_v);
	double get_lower_steering_limit() const;
	void set_upper_steering_limit(double p_v);
	double get_upper_steering_limit() const;
	// Live readouts from the simulation (0 when the joint isn't created yet).
	double get_spin_speed() const;
	double get_steering_angle() const;
};

// Parallel joint: a spring that keeps the two bodies' copies of the node's
// local Z axis parallel. Point the node's Z up and leave body_b empty to keep
// body_a upright (it can still yaw); soften with hertz/damping/max_torque.
class Box3DParallelJoint : public Box3DJoint {
	GDCLASS(Box3DParallelJoint, Box3DJoint)

	double spring_hertz = 1.0;
	double spring_damping = 1.0;
	double max_torque = 0.0; // 0 = unlimited

protected:
	static void _bind_methods();
	b3JointId create_specific(b3WorldId p_world, b3BodyId p_a, b3BodyId p_b,
			const Transform3D &p_xf_a, const Transform3D &p_xf_b, const Transform3D &p_joint) override;

public:
	void set_spring_hertz(double p_v);
	double get_spring_hertz() const;
	void set_spring_damping(double p_v);
	double get_spring_damping() const;
	void set_max_torque(double p_v);
	double get_max_torque() const;
};

// Motor joint: drives the relative linear/angular velocity between two bodies
// (like a servo), and/or pulls the joint frames together with position
// springs. The spring half makes a great compliant "mouse grab": box3d's own
// samples hold bodies with linear_hertz 7.5, damping 1, a force cap, and
// max_torque as angular friction.
class Box3DMotorJoint : public Box3DJoint {
	GDCLASS(Box3DMotorJoint, Box3DJoint)

	Vector3 linear_velocity;
	double max_force = 1000.0;
	Vector3 angular_velocity;
	double max_torque = 1000.0;
	double linear_hertz = 0.0; // 0 = no position spring
	double linear_damping = 1.0;
	double max_spring_force = 0.0;
	double angular_hertz = 0.0;
	double angular_damping = 1.0;
	double max_spring_torque = 0.0;

protected:
	static void _bind_methods();
	b3JointId create_specific(b3WorldId p_world, b3BodyId p_a, b3BodyId p_b,
			const Transform3D &p_xf_a, const Transform3D &p_xf_b, const Transform3D &p_joint) override;

public:
	void set_linear_velocity(const Vector3 &p_v);
	Vector3 get_linear_velocity() const;
	void set_max_force(double p_v);
	double get_max_force() const;
	void set_angular_velocity(const Vector3 &p_v);
	Vector3 get_angular_velocity() const;
	void set_max_torque(double p_v);
	double get_max_torque() const;
	void set_linear_hertz(double p_v);
	double get_linear_hertz() const;
	void set_linear_damping(double p_v);
	double get_linear_damping() const;
	void set_max_spring_force(double p_v);
	double get_max_spring_force() const;
	void set_angular_hertz(double p_v);
	double get_angular_hertz() const;
	void set_angular_damping(double p_v);
	double get_angular_damping() const;
	void set_max_spring_torque(double p_v);
	double get_max_spring_torque() const;
};

} // namespace godot
