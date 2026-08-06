// SPDX-FileCopyrightText: 2026 box3d-godot contributors
// SPDX-License-Identifier: MIT

#pragma once

#include <godot_cpp/classes/node3d.hpp>

#include <box3d/box3d.h>

#include <cfloat>

namespace godot {

class Box3DWorld;
class Box3DBody;

// Base class for Box3D joints. A joint connects `body_a` to `body_b`; if
// `body_b` is left empty the joint anchors to the world at this node's
// position. The node's own transform defines the joint frame (anchor + axes).
class Box3DJoint : public Node3D {
	GDCLASS(Box3DJoint, Node3D)

public:
	// Mirrors b3JointType (types.h) value for value.
	enum JointType {
		JOINT_PARALLEL,
		JOINT_DISTANCE,
		JOINT_FILTER,
		JOINT_MOTOR,
		JOINT_PRISMATIC,
		JOINT_REVOLUTE,
		JOINT_SPHERICAL,
		JOINT_WELD,
		JOINT_WHEEL,
	};

protected:
	b3JointId joint_id = b3_nullJointId;
	b3BodyId anchor_id = b3_nullBodyId; // static body created when body_b is empty
	Box3DWorld *world = nullptr;

	NodePath body_a_path;
	NodePath body_b_path;
	bool collide_connected = false;
	// Advanced solver tuning, defaults copied from box3d's b3DefaultJointDef.
	double constraint_hertz = 60.0;
	double constraint_damping = 2.0;
	// Joint event thresholds. box3d defaults them to FLT_MAX ("never report");
	// 0 here means exactly that, any positive value is the threshold itself.
	double force_threshold = 0.0;
	double torque_threshold = 0.0;
	// b3JointDef.drawScale (types.h:646-647), the per-joint size of the
	// b3World_Draw overlay: box3d draws each joint at
	// max(0.0001, debug_joint_scale * draw_scale) (src/joint.c:1670), so this
	// is what lets a car's wheel joints and a ragdoll's shoulder draw at
	// different sizes under one world-level scale. 1.0 is
	// b3DefaultJointDef's value (b3GetLengthUnitsPerMeter(), src/joint.c:32,
	// and this binding is fixed at 1 unit per metre).
	double draw_scale = 1.0;

	// const because the editor-only warning path needs it from a const method;
	// it only walks parents, which is a const operation.
	Box3DWorld *find_world() const;
	// b3Joint_IsValid plus a join of any in-flight async world step.
	bool joint_live() const;
	Box3DBody *resolve_body(const NodePath &p_path) const;
	// update_configuration_warnings(), but only when an editor is there to show
	// them. A game that authors joints at runtime pays one bool for this.
	void refresh_warnings();
	// Subclass hook for type-specific scene-dock warnings. Overriding
	// _get_configuration_warnings() itself is left to this base class so the
	// GDExtension virtual is bound exactly once.
	virtual void collect_type_warnings(PackedStringArray &p_warnings) const {}
	// The joint frame expressed in a body's local space.
	b3Transform local_frame(const Transform3D &p_body, const Transform3D &p_joint) const;
	void rebuild_if_alive();
	// Push the shared (b3JointDef::base) parameters into a live joint.
	void apply_base_settings();
	// The shared base-def fields that have no b3Joint_Set* counterpart, so they
	// can only be authored at creation. Every create_specific() calls it on its
	// own def.base; today that is drawScale alone.
	void apply_base_def(b3JointDef &p_base) const;

	// Subclasses fill in their specific joint def and create it.
	virtual b3JointId create_specific(b3WorldId p_world, b3BodyId p_a, b3BodyId p_b,
			const Transform3D &p_xf_a, const Transform3D &p_xf_b, const Transform3D &p_joint) {
		return b3_nullJointId;
	}
	// The type this node authors, reported by get_joint_type() before the joint
	// exists in the solver (afterwards the answer comes from box3d itself).
	virtual JointType authored_type() const { return JOINT_FILTER; }

	static void _bind_methods();
	void _notification(int p_what);

public:
	Box3DJoint();
	~Box3DJoint();

	PackedStringArray _get_configuration_warnings() const override;

	void create_joint();
	void destroy_joint();
	bool is_joint_valid() const;

	void set_body_a(const NodePath &p_path);
	NodePath get_body_a() const;
	void set_body_b(const NodePath &p_path);
	NodePath get_body_b() const;
	void set_collide_connected(bool p_enabled);
	bool get_collide_connected() const;

	// Wake both connected bodies. box3d's motor-target setters only store the
	// value, so a sleeping body would ignore a new drive command; every setter
	// that changes a drive target calls this.
	void wake_bodies();

	JointType get_joint_type() const;

	// Live solver readouts (zero when the joint isn't created yet).
	Vector3 get_constraint_force() const;  // newtons, world frame
	Vector3 get_constraint_torque() const; // newton-metres, world frame
	double get_linear_separation() const;  // metres
	double get_angular_separation() const; // radians

	// The joint frames in each body's local space. These are authored from the
	// node transform at creation; the accessors are for runtime tweaks.
	void set_local_frame_a(const Transform3D &p_frame);
	Transform3D get_local_frame_a() const;
	void set_local_frame_b(const Transform3D &p_frame);
	Transform3D get_local_frame_b() const;

	void set_constraint_hertz(double p_v);
	double get_constraint_hertz() const;
	void set_constraint_damping(double p_v);
	double get_constraint_damping() const;
	void set_force_threshold(double p_v);
	double get_force_threshold() const;
	void set_torque_threshold(double p_v);
	double get_torque_threshold() const;
	// Debug-overlay size of this joint, multiplied by Box3DWorld's
	// debug_joint_scale. Read at creation only: box3d exposes drawScale on the
	// def and offers no b3Joint_SetDrawScale (box3d.h:1038-1110), so changing
	// it on a live joint stores the value for the next create/rebuild rather
	// than rebuilding a loaded constraint for a debug-draw knob.
	void set_draw_scale(double p_v);
	double get_draw_scale() const;
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
	// Radians. The angle the spring drives toward, measured like the readout
	// below: body B relative to body A about the hinge axis.
	double target_angle = 0.0;

protected:
	static void _bind_methods();
	b3JointId create_specific(b3WorldId p_world, b3BodyId p_a, b3BodyId p_b,
			const Transform3D &p_xf_a, const Transform3D &p_xf_b, const Transform3D &p_joint) override;
	JointType authored_type() const override { return JOINT_REVOLUTE; }
	void collect_type_warnings(PackedStringArray &p_warnings) const override;

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
	void set_target_angle(double p_v);
	double get_target_angle() const;
	// Live readouts from the simulation (0 when the joint isn't created yet).
	double get_angle() const;        // radians
	double get_motor_torque() const; // newton-meters
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
	bool spring_enabled = false;
	double spring_hertz = 1.0;
	double spring_damping = 0.7;
	// Meters, what the spring drives toward. box3d measures translation of body
	// B relative to body A, and this node passes `body_a` as box3d's body A, so
	// with `body_b` empty (world anchor) a positive target moves the body the
	// other way along the axis.
	double target_translation = 0.0;

protected:
	static void _bind_methods();
	b3JointId create_specific(b3WorldId p_world, b3BodyId p_a, b3BodyId p_b,
			const Transform3D &p_xf_a, const Transform3D &p_xf_b, const Transform3D &p_joint) override;
	JointType authored_type() const override { return JOINT_PRISMATIC; }
	void collect_type_warnings(PackedStringArray &p_warnings) const override;

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
	void set_spring_enabled(bool p_v);
	bool get_spring_enabled() const;
	void set_spring_hertz(double p_v);
	double get_spring_hertz() const;
	void set_spring_damping(double p_v);
	double get_spring_damping() const;
	void set_target_translation(double p_v);
	double get_target_translation() const;
	// Live readouts from the simulation (0 when the joint isn't created yet).
	double get_translation() const; // meters along the joint axis
	double get_speed() const;       // meters / second along the joint axis
	double get_motor_force() const; // newtons
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
	// The limit and the motor only do anything while the spring is enabled; a
	// rigid distance joint overrides both (box3d.h:1160-1161, :1184-1186).
	bool motor_enabled = false;
	double motor_speed = 0.0; // meters / second
	double max_motor_force = 0.0;
	// Spring force range, box3d defaults to unlimited in both directions. Not
	// inspector properties: the defaults are ±FLT_MAX, which no spinbox can
	// express. Drive them with set_spring_force_range() instead.
	double lower_spring_force = -FLT_MAX; // tension the spring can sustain
	double upper_spring_force = FLT_MAX;  // compression the spring can sustain

protected:
	static void _bind_methods();
	b3JointId create_specific(b3WorldId p_world, b3BodyId p_a, b3BodyId p_b,
			const Transform3D &p_xf_a, const Transform3D &p_xf_b, const Transform3D &p_joint) override;
	JointType authored_type() const override { return JOINT_DISTANCE; }
	void collect_type_warnings(PackedStringArray &p_warnings) const override;

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
	void set_motor_enabled(bool p_v);
	bool get_motor_enabled() const;
	void set_motor_speed(double p_v);
	double get_motor_speed() const;
	void set_max_motor_force(double p_v);
	double get_max_motor_force() const;
	// Upstream takes/returns the pair together; Vector2 is (lower, upper).
	void set_spring_force_range(double p_lower, double p_upper);
	Vector2 get_spring_force_range() const;
	// Live readouts from the simulation (0 when the joint isn't created yet).
	double get_current_length() const; // meters
	double get_motor_force() const;    // newtons
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
	Quaternion target_rotation;   // spring target, frame B relative to frame A
	bool motor_enabled = false;
	Vector3 motor_velocity;       // radians / second
	double max_motor_torque = 0.0;

protected:
	static void _bind_methods();
	b3JointId create_specific(b3WorldId p_world, b3BodyId p_a, b3BodyId p_b,
			const Transform3D &p_xf_a, const Transform3D &p_xf_b, const Transform3D &p_joint) override;
	JointType authored_type() const override { return JOINT_SPHERICAL; }
	void collect_type_warnings(PackedStringArray &p_warnings) const override;
	// Re-runs create_specific's motor decision on the live joint: the explicit
	// motor wins, and when it is off a positive friction_torque installs the
	// zero-velocity motor that stands in for dry friction. One place, so the
	// shorthand and the explicit motor can never be half-applied.
	void apply_motor_state();

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
	void set_target_rotation(const Quaternion &p_v);
	Quaternion get_target_rotation() const;
	void set_motor_enabled(bool p_v);
	bool get_motor_enabled() const;
	void set_motor_velocity(const Vector3 &p_v);
	Vector3 get_motor_velocity() const;
	void set_max_motor_torque(double p_v);
	double get_max_motor_torque() const;
	// Live readouts from the simulation (0 when the joint isn't created yet).
	// "current" disambiguates these from the cone_angle / twist limits above,
	// which is what upstream's GetConeLimit / GetConeAngle pair means.
	double get_current_cone_angle() const;  // radians
	double get_current_twist_angle() const; // radians
	Vector3 get_motor_torque() const;       // newton-meters
};

// Fixed / weld joint: rigidly locks two bodies together.
class Box3DFixedJoint : public Box3DJoint {
	GDCLASS(Box3DFixedJoint, Box3DJoint)

	double linear_hertz = 0.0;  // 0 = perfectly rigid
	double angular_hertz = 0.0; // 0 = perfectly rigid
	// Non-dimensional, 1 = critical damping. box3d defaults both to 0.
	double linear_damping = 0.0;
	double angular_damping = 0.0;

protected:
	static void _bind_methods();
	b3JointId create_specific(b3WorldId p_world, b3BodyId p_a, b3BodyId p_b,
			const Transform3D &p_xf_a, const Transform3D &p_xf_b, const Transform3D &p_joint) override;
	JointType authored_type() const override { return JOINT_WELD; }
	void collect_type_warnings(PackedStringArray &p_warnings) const override;

public:
	void set_linear_hertz(double p_v);
	double get_linear_hertz() const;
	void set_angular_hertz(double p_v);
	double get_angular_hertz() const;
	void set_linear_damping(double p_v);
	double get_linear_damping() const;
	void set_angular_damping(double p_v);
	double get_angular_damping() const;
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
	JointType authored_type() const override { return JOINT_WHEEL; }
	void collect_type_warnings(PackedStringArray &p_warnings) const override;

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
	double get_spin_speed() const;      // radians / second
	double get_steering_angle() const;  // radians
	double get_spin_torque() const;     // newton-meters
	double get_steering_torque() const; // newton-meters
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
	JointType authored_type() const override { return JOINT_PARALLEL; }
	void collect_type_warnings(PackedStringArray &p_warnings) const override;

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
	JointType authored_type() const override { return JOINT_MOTOR; }
	void collect_type_warnings(PackedStringArray &p_warnings) const override;

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

// Filter joint: the cheapest joint in box3d. It applies no constraint at all —
// its only effect is to stop `body_a` and `body_b` colliding with each other
// while keeping them in one simulation island, which collision mask bits cannot
// express (two bodies of the same layer that must ignore only each other).
// It has no parameters beyond the ones on Box3DJoint.
class Box3DFilterJoint : public Box3DJoint {
	GDCLASS(Box3DFilterJoint, Box3DJoint)

protected:
	static void _bind_methods();
	b3JointId create_specific(b3WorldId p_world, b3BodyId p_a, b3BodyId p_b,
			const Transform3D &p_xf_a, const Transform3D &p_xf_b, const Transform3D &p_joint) override;
	JointType authored_type() const override { return JOINT_FILTER; }
	void collect_type_warnings(PackedStringArray &p_warnings) const override;
};

} // namespace godot

VARIANT_ENUM_CAST(godot::Box3DJoint::JointType);
