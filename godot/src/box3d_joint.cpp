// SPDX-FileCopyrightText: 2026 box3d-godot contributors
// SPDX-License-Identifier: MIT

#include "box3d_joint.h"

#include "box3d_body.h"
#include "box3d_conversions.h"
#include "box3d_world.h"

#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/callable_method_pointer.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <cfloat>

using namespace godot;

// Inspector unit suffixes. This binding is fixed at one Box3D length unit per
// metre, so every suffix here is literal rather than a convention. The
// "\xe2\x8b\x85" is a UTF-8 dot operator (the character Godot uses in compound
// units such as kg m^2) written as bytes so the source stays ASCII: MSVC
// without /utf-8 would otherwise re-encode it.
// Appends the newton-metre suffix to a range hint string, which is where Godot
// wants the unit when a property also has a range.
static String torque_range(const char *p_range) {
	return String(p_range) + String::utf8(",suffix:N\xe2\x8b\x85m");
}

// ---------------------------------------------------------------------------
// Box3DJoint (base)
// ---------------------------------------------------------------------------

Box3DJoint::Box3DJoint() {}

Box3DJoint::~Box3DJoint() {}

Box3DWorld *Box3DJoint::find_world() const {
	Node *node = get_parent();
	while (node != nullptr) {
		Box3DWorld *w = Object::cast_to<Box3DWorld>(node);
		if (w != nullptr) {
			return w;
		}
		node = node->get_parent();
	}
	return nullptr;
}

Box3DBody *Box3DJoint::resolve_body(const NodePath &p_path) const {
	if (p_path.is_empty()) {
		return nullptr;
	}
	return Object::cast_to<Box3DBody>(get_node_or_null(p_path));
}

void Box3DJoint::refresh_warnings() {
	// Editor-only, like Box3DWorld's: outside the editor nothing can display a
	// configuration warning, and a scene that builds joints at runtime (a
	// ragdoll per spawned enemy) should not pay to compose strings nobody reads.
	if (Engine::get_singleton()->is_editor_hint()) {
		update_configuration_warnings();
	}
}

PackedStringArray Box3DJoint::_get_configuration_warnings() const {
	PackedStringArray warnings;
	// Every one of these is a silent no-op at runtime: create_joint() gives up
	// and the scene simply behaves as if the joint were not there.
	if (find_world() == nullptr) {
		warnings.push_back(
				"This joint has no Box3DWorld ancestor, so it is never created and the "
				"bodies stay unconnected.\nMake it a child (or deeper descendant) of the "
				"same Box3DWorld as the bodies it connects.");
	}
	Box3DBody *a = resolve_body(body_a_path);
	if (body_a_path.is_empty()) {
		warnings.push_back(
				"Body A is empty, so this joint is never created.\nPoint Body A at the "
				"Box3DBody this joint acts on. Leaving Body B empty is fine: that "
				"anchors Body A to the world at this node's position.");
	} else if (a == nullptr) {
		warnings.push_back(
				String("Body A (\"{0}\") does not resolve to a Box3DBody, so this joint "
					   "is never created.\nRe-pick the node: the path is relative to this "
					   "joint, and only a Box3DBody can be jointed.")
						.format(Array::make(body_a_path)));
	}
	if (!body_b_path.is_empty()) {
		Box3DBody *b = resolve_body(body_b_path);
		if (b == nullptr) {
			warnings.push_back(
					String("Body B (\"{0}\") does not resolve to a Box3DBody. The joint "
						   "silently falls back to anchoring Body A to the world, which "
						   "looks like the second body being ignored.\nRe-pick the node, "
						   "or clear Body B if anchoring to the world is what you want.")
							.format(Array::make(body_b_path)));
		} else if (a != nullptr && a == b) {
			warnings.push_back(
					"Body A and Body B are the same body. A joint constrains one body "
					"relative to another, so this one has nothing to hold.\nPick a "
					"different Body B, or clear it to anchor Body A to the world.");
		}
	}
	collect_type_warnings(warnings);
	return warnings;
}

b3Transform Box3DJoint::local_frame(const Transform3D &p_body, const Transform3D &p_joint) const {
	return to_b3_transform(p_body.affine_inverse() * p_joint);
}

bool Box3DJoint::is_joint_valid() const {
	return joint_live();
}

// Validity check that also syncs with an in-flight async world step: touching
// the b3 API while the solver thread runs would race, so wait it out first
// (a single atomic load when nothing is in flight).
bool Box3DJoint::joint_live() const {
	if (world != nullptr) {
		world->join_async_step();
	}
	return b3Joint_IsValid(joint_id);
}

void Box3DJoint::create_joint() {
	if (Engine::get_singleton()->is_editor_hint() || joint_live()) {
		return;
	}
	world = find_world();
	if (world == nullptr) {
		UtilityFunctions::push_warning("Box3DJoint has no Box3DWorld ancestor; it will not be created.");
		return;
	}
	b3WorldId world_id = world->get_world_id();
	if (!b3World_IsValid(world_id)) {
		return;
	}

	Box3DBody *body_a = resolve_body(body_a_path);
	if (body_a == nullptr || !b3Body_IsValid(body_a->get_body_id())) {
		UtilityFunctions::push_warning("Box3DJoint requires a valid body_a.");
		return;
	}
	b3BodyId id_a = body_a->get_body_id();
	// Body frames come from the solver, not the Godot nodes: a node can lag a
	// tick behind (async stepping) or be frozen at its spawn pose entirely
	// (sync_node_transform off under Box3DMultiMeshRenderer), and a joint
	// anchored to a stale frame grabs the body in the wrong place.
	b3WorldTransform b3_xf_a = b3Body_GetTransform(id_a);
	Transform3D xf_a(Basis(to_gd(b3_xf_a.q)), to_gd_pos(b3_xf_a.p));

	Transform3D joint_xf = get_global_transform();

	b3BodyId id_b;
	Transform3D xf_b;
	Box3DBody *body_b = resolve_body(body_b_path);
	if (body_b != nullptr && b3Body_IsValid(body_b->get_body_id())) {
		id_b = body_b->get_body_id();
		b3WorldTransform b3_xf_b = b3Body_GetTransform(id_b);
		xf_b = Transform3D(Basis(to_gd(b3_xf_b.q)), to_gd_pos(b3_xf_b.p));
	} else {
		// No body_b: anchor to the world with a static body at the joint origin.
		b3BodyDef def = b3DefaultBodyDef();
		def.type = b3_staticBody;
		def.position = to_b3_pos(joint_xf.origin);
		anchor_id = b3CreateBody(world_id, &def);
		id_b = anchor_id;
		xf_b = Transform3D(Basis(), joint_xf.origin);
	}

	joint_id = create_specific(world_id, id_a, id_b, xf_a, xf_b, joint_xf);

	// Joints are created deferred, so the connected bodies may have already
	// collided — jointed bodies legitimately overlap (e.g. wheels inside a
	// chassis). b3CreateJoint does NOT remove a pre-existing contact between
	// the pair, and with collide_connected off that stale deep contact keeps
	// shoving the bodies apart and fights the joint forever (a wheel pinned
	// into its chassis can't even spin). The live toggle is the one box3d API
	// that purges those contacts, and it early-outs unless the value changes,
	// so bounce it through true -> false.
	if (joint_live() && !collide_connected) {
		b3Joint_SetCollideConnected(joint_id, true);
		b3Joint_SetCollideConnected(joint_id, false);
	}

	// Base-level settings every joint type shares. Applying them after creation
	// rather than through each def keeps the per-type create_specific bodies
	// focused; the values are plain stored parameters either way.
	apply_base_settings();
}

void Box3DJoint::apply_base_settings() {
	if (!joint_live()) {
		return;
	}
	// Route joint events back to this node, the way b3BodyDef.userData already
	// does for bodies (box3d_body.cpp:94). box3d only stores the pointer, it
	// never frees it, and destroy_joint() runs on EXIT_TREE while the node is
	// still alive, so the pointer can never dangle.
	b3Joint_SetUserData(joint_id, (void *)this);
	b3Joint_SetConstraintTuning(joint_id, (float)constraint_hertz, (float)constraint_damping);
	b3Joint_SetForceThreshold(joint_id, force_threshold > 0.0 ? (float)force_threshold : FLT_MAX);
	b3Joint_SetTorqueThreshold(joint_id, torque_threshold > 0.0 ? (float)torque_threshold : FLT_MAX);
}

// Base-def fields with no live setter. b3JointDef.drawScale is copied into the
// joint at creation (src/joint.c:186) and read only by the debug draw
// (src/joint.c:1670); box3d.h:1038-1110 has no b3Joint_SetDrawScale, so this is
// the one and only place it can be authored.
void Box3DJoint::apply_base_def(b3JointDef &p_base) const {
	p_base.drawScale = (float)draw_scale;
}

void Box3DJoint::destroy_joint() {
	if (joint_live()) {
		b3DestroyJoint(joint_id, true);
	}
	joint_id = b3_nullJointId;
	if (b3Body_IsValid(anchor_id)) {
		b3DestroyBody(anchor_id);
	}
	anchor_id = b3_nullBodyId;
}

void Box3DJoint::rebuild_if_alive() {
	if (joint_live()) {
		destroy_joint();
		create_joint();
	}
}

void Box3DJoint::wake_bodies() {
	if (joint_live()) {
		b3Joint_WakeBodies(joint_id);
	}
}

void Box3DJoint::_notification(int p_what) {
	switch (p_what) {
		case NOTIFICATION_READY: {
			if (!Engine::get_singleton()->is_editor_hint()) {
				// Create NOW if the referenced bodies already exist. A deferred
				// create leaves a window where a physics tick steps the bodies
				// unjointed — for a ragdoll spawned at runtime mid-session the
				// bones scatter for that tick and the late joint then freezes
				// the scattered pose in as its rest frame. Bodies earlier in
				// tree order (the common case) are ready before the joint, so
				// this path is immediate; only when a referenced body has not
				// been created yet (scene-load order places it after the
				// joint) fall back to the deferred retry the old behavior
				// existed for.
				Box3DBody *a = resolve_body(body_a_path);
				Box3DBody *b = resolve_body(body_b_path);
				bool a_ready = a != nullptr && a->is_body_valid();
				bool b_ready = body_b_path.is_empty() || (b != nullptr && b->is_body_valid());
				if (a_ready && b_ready) {
					create_joint();
				} else {
					callable_mp(this, &Box3DJoint::create_joint).call_deferred();
				}
			}
		} break;
		case NOTIFICATION_EXIT_TREE: {
			destroy_joint();
			world = nullptr;
		} break;
		// "No Box3DWorld ancestor" and both NodePath warnings depend on where
		// this node sits and on what its paths resolve to, so re-evaluate them
		// whenever the tree around it can have changed.
		case NOTIFICATION_PARENTED:
		case NOTIFICATION_UNPARENTED:
		case NOTIFICATION_ENTER_TREE: {
			refresh_warnings();
		} break;
	}
}

void Box3DJoint::set_body_a(const NodePath &p_path) {
	body_a_path = p_path;
	rebuild_if_alive();
	refresh_warnings();
}

NodePath Box3DJoint::get_body_a() const {
	return body_a_path;
}

void Box3DJoint::set_body_b(const NodePath &p_path) {
	body_b_path = p_path;
	rebuild_if_alive();
	refresh_warnings();
}

NodePath Box3DJoint::get_body_b() const {
	return body_b_path;
}

void Box3DJoint::set_collide_connected(bool p_enabled) {
	collide_connected = p_enabled;
	rebuild_if_alive();
}

bool Box3DJoint::get_collide_connected() const {
	return collide_connected;
}

Box3DJoint::JointType Box3DJoint::get_joint_type() const {
	if (joint_live()) {
		return (JointType)b3Joint_GetType(joint_id);
	}
	return authored_type();
}

Vector3 Box3DJoint::get_constraint_force() const {
	return joint_live() ? to_gd(b3Joint_GetConstraintForce(joint_id)) : Vector3();
}

Vector3 Box3DJoint::get_constraint_torque() const {
	return joint_live() ? to_gd(b3Joint_GetConstraintTorque(joint_id)) : Vector3();
}

double Box3DJoint::get_linear_separation() const {
	return joint_live() ? b3Joint_GetLinearSeparation(joint_id) : 0.0;
}

double Box3DJoint::get_angular_separation() const {
	return joint_live() ? b3Joint_GetAngularSeparation(joint_id) : 0.0;
}

void Box3DJoint::set_local_frame_a(const Transform3D &p_frame) {
	if (joint_live()) {
		b3Joint_SetLocalFrameA(joint_id, to_b3_transform(p_frame));
		wake_bodies();
	}
}

Transform3D Box3DJoint::get_local_frame_a() const {
	if (!joint_live()) {
		return Transform3D();
	}
	b3Transform f = b3Joint_GetLocalFrameA(joint_id);
	return Transform3D(Basis(to_gd(f.q)), to_gd(f.p));
}

void Box3DJoint::set_local_frame_b(const Transform3D &p_frame) {
	if (joint_live()) {
		b3Joint_SetLocalFrameB(joint_id, to_b3_transform(p_frame));
		wake_bodies();
	}
}

Transform3D Box3DJoint::get_local_frame_b() const {
	if (!joint_live()) {
		return Transform3D();
	}
	b3Transform f = b3Joint_GetLocalFrameB(joint_id);
	return Transform3D(Basis(to_gd(f.q)), to_gd(f.p));
}

void Box3DJoint::set_constraint_hertz(double p_v) {
	constraint_hertz = MAX(p_v, 0.0);
	apply_base_settings();
}
double Box3DJoint::get_constraint_hertz() const { return constraint_hertz; }

void Box3DJoint::set_constraint_damping(double p_v) {
	constraint_damping = MAX(p_v, 0.0);
	apply_base_settings();
}
double Box3DJoint::get_constraint_damping() const { return constraint_damping; }

void Box3DJoint::set_force_threshold(double p_v) {
	force_threshold = MAX(p_v, 0.0);
	apply_base_settings();
}
double Box3DJoint::get_force_threshold() const { return force_threshold; }

void Box3DJoint::set_torque_threshold(double p_v) {
	torque_threshold = MAX(p_v, 0.0);
	apply_base_settings();
}
double Box3DJoint::get_torque_threshold() const { return torque_threshold; }

void Box3DJoint::set_draw_scale(double p_v) {
	// Clamped at 0 the way the other base tunings are; box3d itself floors the
	// product at 0.0001 (src/joint.c:1670), so 0 means "as small as it draws".
	draw_scale = MAX(p_v, 0.0);
}
double Box3DJoint::get_draw_scale() const { return draw_scale; }

void Box3DJoint::_bind_methods() {
	ClassDB::bind_method(D_METHOD("is_joint_valid"), &Box3DJoint::is_joint_valid);
	ClassDB::bind_method(D_METHOD("set_body_a", "path"), &Box3DJoint::set_body_a);
	ClassDB::bind_method(D_METHOD("get_body_a"), &Box3DJoint::get_body_a);
	ClassDB::bind_method(D_METHOD("set_body_b", "path"), &Box3DJoint::set_body_b);
	ClassDB::bind_method(D_METHOD("get_body_b"), &Box3DJoint::get_body_b);
	ClassDB::bind_method(D_METHOD("set_collide_connected", "enabled"), &Box3DJoint::set_collide_connected);
	ClassDB::bind_method(D_METHOD("get_collide_connected"), &Box3DJoint::get_collide_connected);
	ClassDB::bind_method(D_METHOD("wake_bodies"), &Box3DJoint::wake_bodies);
	ClassDB::bind_method(D_METHOD("get_joint_type"), &Box3DJoint::get_joint_type);
	ClassDB::bind_method(D_METHOD("get_constraint_force"), &Box3DJoint::get_constraint_force);
	ClassDB::bind_method(D_METHOD("get_constraint_torque"), &Box3DJoint::get_constraint_torque);
	ClassDB::bind_method(D_METHOD("get_linear_separation"), &Box3DJoint::get_linear_separation);
	ClassDB::bind_method(D_METHOD("get_angular_separation"), &Box3DJoint::get_angular_separation);
	ClassDB::bind_method(D_METHOD("set_local_frame_a", "frame"), &Box3DJoint::set_local_frame_a);
	ClassDB::bind_method(D_METHOD("get_local_frame_a"), &Box3DJoint::get_local_frame_a);
	ClassDB::bind_method(D_METHOD("set_local_frame_b", "frame"), &Box3DJoint::set_local_frame_b);
	ClassDB::bind_method(D_METHOD("get_local_frame_b"), &Box3DJoint::get_local_frame_b);
	ClassDB::bind_method(D_METHOD("set_constraint_hertz", "hertz"), &Box3DJoint::set_constraint_hertz);
	ClassDB::bind_method(D_METHOD("get_constraint_hertz"), &Box3DJoint::get_constraint_hertz);
	ClassDB::bind_method(D_METHOD("set_constraint_damping", "ratio"), &Box3DJoint::set_constraint_damping);
	ClassDB::bind_method(D_METHOD("get_constraint_damping"), &Box3DJoint::get_constraint_damping);
	ClassDB::bind_method(D_METHOD("set_force_threshold", "newtons"), &Box3DJoint::set_force_threshold);
	ClassDB::bind_method(D_METHOD("get_force_threshold"), &Box3DJoint::get_force_threshold);
	ClassDB::bind_method(D_METHOD("set_torque_threshold", "newton_meters"), &Box3DJoint::set_torque_threshold);
	ClassDB::bind_method(D_METHOD("get_torque_threshold"), &Box3DJoint::get_torque_threshold);
	ClassDB::bind_method(D_METHOD("set_draw_scale", "scale"), &Box3DJoint::set_draw_scale);
	ClassDB::bind_method(D_METHOD("get_draw_scale"), &Box3DJoint::get_draw_scale);

	ADD_PROPERTY(PropertyInfo(Variant::NODE_PATH, "body_a", PROPERTY_HINT_NODE_PATH_VALID_TYPES, "Box3DBody"), "set_body_a", "get_body_a");
	ADD_PROPERTY(PropertyInfo(Variant::NODE_PATH, "body_b", PROPERTY_HINT_NODE_PATH_VALID_TYPES, "Box3DBody"), "set_body_b", "get_body_b");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "collide_connected"), "set_collide_connected", "get_collide_connected");
	ADD_GROUP("Advanced", "");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "constraint_hertz", PROPERTY_HINT_RANGE, "0,240,0.5,or_greater,suffix:Hz"), "set_constraint_hertz", "get_constraint_hertz");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "constraint_damping", PROPERTY_HINT_RANGE, "0,10,0.05,or_greater"), "set_constraint_damping", "get_constraint_damping");
	// 0 on both thresholds means "never report", which is Box3D's own default
	// (FLT_MAX); no spinbox can express that, hence 0 standing in for it.
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "force_threshold", PROPERTY_HINT_RANGE, "0,100000,1,or_greater,suffix:N"), "set_force_threshold", "get_force_threshold");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "torque_threshold", PROPERTY_HINT_RANGE, torque_range("0,100000,1,or_greater")), "set_torque_threshold", "get_torque_threshold");
	// b3JointDef.drawScale: multiplied by Box3DWorld.debug_joint_scale when the
	// b3World_Draw overlay draws this joint. Creation-time, hence the "applies
	// on the next rebuild" wording in the header — box3d has no setter for it.
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "draw_scale", PROPERTY_HINT_RANGE, "0,10,0.05,or_greater"), "set_draw_scale", "get_draw_scale");

	BIND_ENUM_CONSTANT(JOINT_PARALLEL);
	BIND_ENUM_CONSTANT(JOINT_DISTANCE);
	BIND_ENUM_CONSTANT(JOINT_FILTER);
	BIND_ENUM_CONSTANT(JOINT_MOTOR);
	BIND_ENUM_CONSTANT(JOINT_PRISMATIC);
	BIND_ENUM_CONSTANT(JOINT_REVOLUTE);
	BIND_ENUM_CONSTANT(JOINT_SPHERICAL);
	BIND_ENUM_CONSTANT(JOINT_WELD);
	BIND_ENUM_CONSTANT(JOINT_WHEEL);
}

// ---------------------------------------------------------------------------
// Box3DHingeJoint (revolute)
// ---------------------------------------------------------------------------

b3JointId Box3DHingeJoint::create_specific(b3WorldId p_world, b3BodyId p_a, b3BodyId p_b,
		const Transform3D &p_xf_a, const Transform3D &p_xf_b, const Transform3D &p_joint) {
	b3RevoluteJointDef def = b3DefaultRevoluteJointDef();
	def.base.bodyIdA = p_a;
	def.base.bodyIdB = p_b;
	def.base.localFrameA = local_frame(p_xf_a, p_joint);
	def.base.localFrameB = local_frame(p_xf_b, p_joint);
	def.base.collideConnected = collide_connected;
	apply_base_def(def.base);
	def.enableLimit = limit_enabled;
	def.lowerAngle = (float)lower_limit;
	def.upperAngle = (float)upper_limit;
	def.enableMotor = motor_enabled;
	def.motorSpeed = (float)motor_speed;
	def.maxMotorTorque = (float)max_motor_torque;
	// Angular spring toward the spawn pose (frames coincide at creation, so the
	// rest angle is 0 = the authored pose). Ragdolls use this to hold a stance.
	def.enableSpring = spring_enabled;
	def.hertz = (float)spring_hertz;
	def.dampingRatio = (float)spring_damping;
	def.targetAngle = (float)target_angle;
	return b3CreateRevoluteJoint(p_world, &def);
}

void Box3DHingeJoint::collect_type_warnings(PackedStringArray &p_warnings) const {
	// box3d clamps the motor impulse to maxMotorTorque * h (revolute_joint.c:440),
	// so a 0 budget is a motor that runs and can never move anything. The def
	// default IS 0, which makes this the most common "my motor does nothing".
	if (motor_enabled && max_motor_torque <= 0.0) {
		p_warnings.push_back(
				"Motor Enabled is on but Max Motor Torque is 0, so the motor has no "
				"torque to spend and the hinge never turns.\nRaise Max Motor Torque "
				"until it can overcome the load (compare get_motor_torque() against "
				"it to see whether the motor is saturated).");
	}
	if (limit_enabled && lower_limit > upper_limit) {
		p_warnings.push_back(
				"Lower Limit is above Upper Limit, so there is no angle the hinge is "
				"allowed to rest at and the solver fights itself.\nSwap the two values.");
	}
}

void Box3DHingeJoint::set_limit_enabled(bool p_v) {
	limit_enabled = p_v;
	if (joint_live()) {
		b3RevoluteJoint_EnableLimit(joint_id, p_v);
	}
	refresh_warnings();
}
bool Box3DHingeJoint::get_limit_enabled() const { return limit_enabled; }

void Box3DHingeJoint::set_lower_limit(double p_v) {
	lower_limit = p_v;
	if (joint_live()) {
		b3RevoluteJoint_SetLimits(joint_id, (float)lower_limit, (float)upper_limit);
	}
	refresh_warnings();
}
double Box3DHingeJoint::get_lower_limit() const { return lower_limit; }

void Box3DHingeJoint::set_upper_limit(double p_v) {
	upper_limit = p_v;
	if (joint_live()) {
		b3RevoluteJoint_SetLimits(joint_id, (float)lower_limit, (float)upper_limit);
	}
	refresh_warnings();
}
double Box3DHingeJoint::get_upper_limit() const { return upper_limit; }

void Box3DHingeJoint::set_motor_enabled(bool p_v) {
	motor_enabled = p_v;
	if (joint_live()) {
		b3RevoluteJoint_EnableMotor(joint_id, p_v);
	}
	refresh_warnings();
}
bool Box3DHingeJoint::get_motor_enabled() const { return motor_enabled; }

void Box3DHingeJoint::set_motor_speed(double p_v) {
	bool changed = p_v != motor_speed;
	motor_speed = p_v;
	if (joint_live()) {
		b3RevoluteJoint_SetMotorSpeed(joint_id, (float)p_v);
		if (changed) {
			wake_bodies();
		}
	}
}
double Box3DHingeJoint::get_motor_speed() const { return motor_speed; }

void Box3DHingeJoint::set_max_motor_torque(double p_v) {
	max_motor_torque = MAX(p_v, 0.0);
	if (joint_live()) {
		b3RevoluteJoint_SetMaxMotorTorque(joint_id, (float)max_motor_torque);
	}
	refresh_warnings();
}
double Box3DHingeJoint::get_max_motor_torque() const { return max_motor_torque; }

void Box3DHingeJoint::set_spring_enabled(bool p_v) {
	spring_enabled = p_v;
	if (joint_live()) {
		b3RevoluteJoint_EnableSpring(joint_id, p_v);
	}
}
bool Box3DHingeJoint::get_spring_enabled() const { return spring_enabled; }

void Box3DHingeJoint::set_spring_hertz(double p_v) {
	spring_hertz = MAX(p_v, 0.0);
	if (joint_live()) {
		b3RevoluteJoint_SetSpringHertz(joint_id, (float)spring_hertz);
	}
}
double Box3DHingeJoint::get_spring_hertz() const { return spring_hertz; }

void Box3DHingeJoint::set_spring_damping(double p_v) {
	spring_damping = MAX(p_v, 0.0);
	if (joint_live()) {
		b3RevoluteJoint_SetSpringDampingRatio(joint_id, (float)spring_damping);
	}
}
double Box3DHingeJoint::get_spring_damping() const { return spring_damping; }

void Box3DHingeJoint::set_target_angle(double p_v) {
	bool changed = p_v != target_angle;
	target_angle = p_v;
	if (joint_live()) {
		b3RevoluteJoint_SetTargetAngle(joint_id, (float)p_v);
		if (changed) {
			wake_bodies();
		}
	}
}
double Box3DHingeJoint::get_target_angle() const { return target_angle; }

double Box3DHingeJoint::get_angle() const {
	return joint_live() ? b3RevoluteJoint_GetAngle(joint_id) : 0.0;
}

double Box3DHingeJoint::get_motor_torque() const {
	return joint_live() ? b3RevoluteJoint_GetMotorTorque(joint_id) : 0.0;
}

void Box3DHingeJoint::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_limit_enabled", "enabled"), &Box3DHingeJoint::set_limit_enabled);
	ClassDB::bind_method(D_METHOD("get_limit_enabled"), &Box3DHingeJoint::get_limit_enabled);
	ClassDB::bind_method(D_METHOD("set_lower_limit", "radians"), &Box3DHingeJoint::set_lower_limit);
	ClassDB::bind_method(D_METHOD("get_lower_limit"), &Box3DHingeJoint::get_lower_limit);
	ClassDB::bind_method(D_METHOD("set_upper_limit", "radians"), &Box3DHingeJoint::set_upper_limit);
	ClassDB::bind_method(D_METHOD("get_upper_limit"), &Box3DHingeJoint::get_upper_limit);
	ClassDB::bind_method(D_METHOD("set_motor_enabled", "enabled"), &Box3DHingeJoint::set_motor_enabled);
	ClassDB::bind_method(D_METHOD("get_motor_enabled"), &Box3DHingeJoint::get_motor_enabled);
	ClassDB::bind_method(D_METHOD("set_motor_speed", "radians_per_sec"), &Box3DHingeJoint::set_motor_speed);
	ClassDB::bind_method(D_METHOD("get_motor_speed"), &Box3DHingeJoint::get_motor_speed);
	ClassDB::bind_method(D_METHOD("set_max_motor_torque", "torque"), &Box3DHingeJoint::set_max_motor_torque);
	ClassDB::bind_method(D_METHOD("get_max_motor_torque"), &Box3DHingeJoint::get_max_motor_torque);
	ClassDB::bind_method(D_METHOD("set_spring_enabled", "enabled"), &Box3DHingeJoint::set_spring_enabled);
	ClassDB::bind_method(D_METHOD("get_spring_enabled"), &Box3DHingeJoint::get_spring_enabled);
	ClassDB::bind_method(D_METHOD("set_spring_hertz", "hertz"), &Box3DHingeJoint::set_spring_hertz);
	ClassDB::bind_method(D_METHOD("get_spring_hertz"), &Box3DHingeJoint::get_spring_hertz);
	ClassDB::bind_method(D_METHOD("set_spring_damping", "ratio"), &Box3DHingeJoint::set_spring_damping);
	ClassDB::bind_method(D_METHOD("get_spring_damping"), &Box3DHingeJoint::get_spring_damping);
	ClassDB::bind_method(D_METHOD("set_target_angle", "radians"), &Box3DHingeJoint::set_target_angle);
	ClassDB::bind_method(D_METHOD("get_target_angle"), &Box3DHingeJoint::get_target_angle);
	ClassDB::bind_method(D_METHOD("get_angle"), &Box3DHingeJoint::get_angle);
	ClassDB::bind_method(D_METHOD("get_motor_torque"), &Box3DHingeJoint::get_motor_torque);

	// Grouped in the order a hinge is authored: how far it may turn, what turns
	// it, and how it springs back. Empty prefixes keep the property names in the
	// inspector identical to the ones scripts use.
	ADD_GROUP("Limit", "");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "limit_enabled"), "set_limit_enabled", "get_limit_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "lower_limit", PROPERTY_HINT_RANGE, "-180,180,0.1,radians_as_degrees"), "set_lower_limit", "get_lower_limit");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "upper_limit", PROPERTY_HINT_RANGE, "-180,180,0.1,radians_as_degrees"), "set_upper_limit", "get_upper_limit");
	ADD_GROUP("Motor", "");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "motor_enabled"), "set_motor_enabled", "get_motor_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "motor_speed", PROPERTY_HINT_RANGE, "-50,50,0.1,suffix:rad/s"), "set_motor_speed", "get_motor_speed");
	// 0 is a motor that runs and cannot move anything; the scene dock warns.
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "max_motor_torque", PROPERTY_HINT_RANGE, torque_range("0,10000,1,or_greater")), "set_max_motor_torque", "get_max_motor_torque");
	ADD_GROUP("Spring", "");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "spring_enabled"), "set_spring_enabled", "get_spring_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "spring_hertz", PROPERTY_HINT_RANGE, "0,30,0.1,or_greater,suffix:Hz"), "set_spring_hertz", "get_spring_hertz");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "spring_damping", PROPERTY_HINT_RANGE, "0,4,0.05,or_greater"), "set_spring_damping", "get_spring_damping");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "target_angle", PROPERTY_HINT_RANGE, "-180,180,0.1,radians_as_degrees"), "set_target_angle", "get_target_angle");
}

// ---------------------------------------------------------------------------
// Box3DSliderJoint (prismatic)
// ---------------------------------------------------------------------------

b3JointId Box3DSliderJoint::create_specific(b3WorldId p_world, b3BodyId p_a, b3BodyId p_b,
		const Transform3D &p_xf_a, const Transform3D &p_xf_b, const Transform3D &p_joint) {
	b3PrismaticJointDef def = b3DefaultPrismaticJointDef();
	def.base.bodyIdA = p_a;
	def.base.bodyIdB = p_b;
	def.base.localFrameA = local_frame(p_xf_a, p_joint);
	def.base.localFrameB = local_frame(p_xf_b, p_joint);
	def.base.collideConnected = collide_connected;
	apply_base_def(def.base);
	def.enableLimit = limit_enabled;
	def.lowerTranslation = (float)lower_limit;
	def.upperTranslation = (float)upper_limit;
	def.enableMotor = motor_enabled;
	def.motorSpeed = (float)motor_speed;
	def.maxMotorForce = (float)max_motor_force;
	// Linear spring along the same axis, driving toward target_translation.
	def.enableSpring = spring_enabled;
	def.hertz = (float)spring_hertz;
	def.dampingRatio = (float)spring_damping;
	def.targetTranslation = (float)target_translation;
	return b3CreatePrismaticJoint(p_world, &def);
}

void Box3DSliderJoint::collect_type_warnings(PackedStringArray &p_warnings) const {
	// Same clamp as the hinge, on force instead of torque (prismatic_joint.c:491).
	if (motor_enabled && max_motor_force <= 0.0) {
		p_warnings.push_back(
				"Motor Enabled is on but Max Motor Force is 0, so the motor has no "
				"force to spend and the slider never moves.\nRaise Max Motor Force "
				"until it can carry the load.");
	}
	if (limit_enabled && lower_limit > upper_limit) {
		p_warnings.push_back(
				"Lower Limit is above Upper Limit, so there is no position the slider "
				"is allowed to rest at and the solver fights itself.\nSwap the two "
				"values.");
	}
}

void Box3DSliderJoint::set_limit_enabled(bool p_v) {
	limit_enabled = p_v;
	if (joint_live()) {
		b3PrismaticJoint_EnableLimit(joint_id, p_v);
	}
	refresh_warnings();
}
bool Box3DSliderJoint::get_limit_enabled() const { return limit_enabled; }

void Box3DSliderJoint::set_lower_limit(double p_v) {
	lower_limit = p_v;
	if (joint_live()) {
		b3PrismaticJoint_SetLimits(joint_id, (float)lower_limit, (float)upper_limit);
	}
	refresh_warnings();
}
double Box3DSliderJoint::get_lower_limit() const { return lower_limit; }

void Box3DSliderJoint::set_upper_limit(double p_v) {
	upper_limit = p_v;
	if (joint_live()) {
		b3PrismaticJoint_SetLimits(joint_id, (float)lower_limit, (float)upper_limit);
	}
	refresh_warnings();
}
double Box3DSliderJoint::get_upper_limit() const { return upper_limit; }

void Box3DSliderJoint::set_motor_enabled(bool p_v) {
	motor_enabled = p_v;
	if (joint_live()) {
		b3PrismaticJoint_EnableMotor(joint_id, p_v);
	}
	refresh_warnings();
}
bool Box3DSliderJoint::get_motor_enabled() const { return motor_enabled; }

void Box3DSliderJoint::set_motor_speed(double p_v) {
	bool changed = p_v != motor_speed;
	motor_speed = p_v;
	if (joint_live()) {
		b3PrismaticJoint_SetMotorSpeed(joint_id, (float)p_v);
		if (changed) {
			wake_bodies();
		}
	}
}
double Box3DSliderJoint::get_motor_speed() const { return motor_speed; }

void Box3DSliderJoint::set_max_motor_force(double p_v) {
	max_motor_force = MAX(p_v, 0.0);
	if (joint_live()) {
		b3PrismaticJoint_SetMaxMotorForce(joint_id, (float)max_motor_force);
	}
	refresh_warnings();
}
double Box3DSliderJoint::get_max_motor_force() const { return max_motor_force; }

void Box3DSliderJoint::set_spring_enabled(bool p_v) {
	spring_enabled = p_v;
	if (joint_live()) {
		b3PrismaticJoint_EnableSpring(joint_id, p_v);
	}
}
bool Box3DSliderJoint::get_spring_enabled() const { return spring_enabled; }

void Box3DSliderJoint::set_spring_hertz(double p_v) {
	spring_hertz = MAX(p_v, 0.0);
	if (joint_live()) {
		b3PrismaticJoint_SetSpringHertz(joint_id, (float)spring_hertz);
	}
}
double Box3DSliderJoint::get_spring_hertz() const { return spring_hertz; }

void Box3DSliderJoint::set_spring_damping(double p_v) {
	spring_damping = MAX(p_v, 0.0);
	if (joint_live()) {
		b3PrismaticJoint_SetSpringDampingRatio(joint_id, (float)spring_damping);
	}
}
double Box3DSliderJoint::get_spring_damping() const { return spring_damping; }

void Box3DSliderJoint::set_target_translation(double p_v) {
	bool changed = p_v != target_translation;
	target_translation = p_v;
	if (joint_live()) {
		b3PrismaticJoint_SetTargetTranslation(joint_id, (float)p_v);
		if (changed) {
			wake_bodies();
		}
	}
}
double Box3DSliderJoint::get_target_translation() const { return target_translation; }

double Box3DSliderJoint::get_translation() const {
	return joint_live() ? b3PrismaticJoint_GetTranslation(joint_id) : 0.0;
}

double Box3DSliderJoint::get_speed() const {
	return joint_live() ? b3PrismaticJoint_GetSpeed(joint_id) : 0.0;
}

double Box3DSliderJoint::get_motor_force() const {
	return joint_live() ? b3PrismaticJoint_GetMotorForce(joint_id) : 0.0;
}

void Box3DSliderJoint::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_limit_enabled", "enabled"), &Box3DSliderJoint::set_limit_enabled);
	ClassDB::bind_method(D_METHOD("get_limit_enabled"), &Box3DSliderJoint::get_limit_enabled);
	ClassDB::bind_method(D_METHOD("set_lower_limit", "meters"), &Box3DSliderJoint::set_lower_limit);
	ClassDB::bind_method(D_METHOD("get_lower_limit"), &Box3DSliderJoint::get_lower_limit);
	ClassDB::bind_method(D_METHOD("set_upper_limit", "meters"), &Box3DSliderJoint::set_upper_limit);
	ClassDB::bind_method(D_METHOD("get_upper_limit"), &Box3DSliderJoint::get_upper_limit);
	ClassDB::bind_method(D_METHOD("set_motor_enabled", "enabled"), &Box3DSliderJoint::set_motor_enabled);
	ClassDB::bind_method(D_METHOD("get_motor_enabled"), &Box3DSliderJoint::get_motor_enabled);
	ClassDB::bind_method(D_METHOD("set_motor_speed", "meters_per_sec"), &Box3DSliderJoint::set_motor_speed);
	ClassDB::bind_method(D_METHOD("get_motor_speed"), &Box3DSliderJoint::get_motor_speed);
	ClassDB::bind_method(D_METHOD("set_max_motor_force", "force"), &Box3DSliderJoint::set_max_motor_force);
	ClassDB::bind_method(D_METHOD("get_max_motor_force"), &Box3DSliderJoint::get_max_motor_force);
	ClassDB::bind_method(D_METHOD("set_spring_enabled", "enabled"), &Box3DSliderJoint::set_spring_enabled);
	ClassDB::bind_method(D_METHOD("get_spring_enabled"), &Box3DSliderJoint::get_spring_enabled);
	ClassDB::bind_method(D_METHOD("set_spring_hertz", "hertz"), &Box3DSliderJoint::set_spring_hertz);
	ClassDB::bind_method(D_METHOD("get_spring_hertz"), &Box3DSliderJoint::get_spring_hertz);
	ClassDB::bind_method(D_METHOD("set_spring_damping", "ratio"), &Box3DSliderJoint::set_spring_damping);
	ClassDB::bind_method(D_METHOD("get_spring_damping"), &Box3DSliderJoint::get_spring_damping);
	ClassDB::bind_method(D_METHOD("set_target_translation", "meters"), &Box3DSliderJoint::set_target_translation);
	ClassDB::bind_method(D_METHOD("get_target_translation"), &Box3DSliderJoint::get_target_translation);
	ClassDB::bind_method(D_METHOD("get_translation"), &Box3DSliderJoint::get_translation);
	ClassDB::bind_method(D_METHOD("get_speed"), &Box3DSliderJoint::get_speed);
	ClassDB::bind_method(D_METHOD("get_motor_force"), &Box3DSliderJoint::get_motor_force);

	ADD_GROUP("Limit", "");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "limit_enabled"), "set_limit_enabled", "get_limit_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "lower_limit", PROPERTY_HINT_RANGE, "-10,10,0.01,or_greater,suffix:m"), "set_lower_limit", "get_lower_limit");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "upper_limit", PROPERTY_HINT_RANGE, "-10,10,0.01,or_greater,suffix:m"), "set_upper_limit", "get_upper_limit");
	ADD_GROUP("Motor", "");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "motor_enabled"), "set_motor_enabled", "get_motor_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "motor_speed", PROPERTY_HINT_RANGE, "-20,20,0.1,suffix:m/s"), "set_motor_speed", "get_motor_speed");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "max_motor_force", PROPERTY_HINT_RANGE, "0,10000,1,or_greater,suffix:N"), "set_max_motor_force", "get_max_motor_force");
	ADD_GROUP("Spring", "");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "spring_enabled"), "set_spring_enabled", "get_spring_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "spring_hertz", PROPERTY_HINT_RANGE, "0,30,0.1,or_greater,suffix:Hz"), "set_spring_hertz", "get_spring_hertz");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "spring_damping", PROPERTY_HINT_RANGE, "0,4,0.05,or_greater"), "set_spring_damping", "get_spring_damping");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "target_translation", PROPERTY_HINT_RANGE, "-10,10,0.01,or_greater,suffix:m"), "set_target_translation", "get_target_translation");
}

// ---------------------------------------------------------------------------
// Box3DDistanceJoint
// ---------------------------------------------------------------------------

b3JointId Box3DDistanceJoint::create_specific(b3WorldId p_world, b3BodyId p_a, b3BodyId p_b,
		const Transform3D &p_xf_a, const Transform3D &p_xf_b, const Transform3D &p_joint) {
	b3DistanceJointDef def = b3DefaultDistanceJointDef();
	def.base.bodyIdA = p_a;
	def.base.bodyIdB = p_b;
	// Anchor at each body's origin, so the joint spans body centers.
	def.base.localFrameA = b3Transform_identity;
	def.base.localFrameB = b3Transform_identity;
	def.base.collideConnected = collide_connected;
	apply_base_def(def.base);
	double len = length;
	if (len < 0.0) {
		len = p_xf_a.origin.distance_to(p_xf_b.origin);
	}
	def.length = (float)len;
	def.enableSpring = spring_enabled;
	def.hertz = (float)spring_hertz;
	def.dampingRatio = (float)spring_damping;
	def.enableLimit = limit_enabled;
	def.minLength = (float)min_length;
	def.maxLength = (float)max_length;
	def.lowerSpringForce = (float)lower_spring_force;
	def.upperSpringForce = (float)upper_spring_force;
	def.enableMotor = motor_enabled;
	def.motorSpeed = (float)motor_speed;
	def.maxMotorForce = (float)max_motor_force;
	return b3CreateDistanceJoint(p_world, &def);
}

void Box3DDistanceJoint::collect_type_warnings(PackedStringArray &p_warnings) const {
	// Both the limit and the motor live inside the `if (enableSpring)` branch of
	// the solver (distance_joint.c:480); without the spring the joint is rigid
	// and overrides them. box3d.h says the same about the limit at :1187.
	if (!spring_enabled && (motor_enabled || limit_enabled)) {
		p_warnings.push_back(
				"Spring Enabled is off, so this joint is rigid at Length and the "
				"limits and the motor have no effect at all.\nTurn Spring Enabled on "
				"to use them, or turn the limit and the motor off.");
	}
	if (spring_enabled && motor_enabled && max_motor_force <= 0.0) {
		p_warnings.push_back(
				"Motor Enabled is on but Max Motor Force is 0, so the winch has no "
				"force to spend and the distance never changes.\nRaise Max Motor "
				"Force.");
	}
	if (limit_enabled && min_length > max_length) {
		p_warnings.push_back(
				"Min Length is above Max Length, so there is no distance the joint is "
				"allowed to settle at.\nSwap the two values.");
	}
}

void Box3DDistanceJoint::set_length(double p_v) {
	length = p_v;
	if (joint_live() && p_v >= 0.0) {
		b3DistanceJoint_SetLength(joint_id, (float)p_v);
	} else {
		rebuild_if_alive();
	}
}
double Box3DDistanceJoint::get_length() const { return length; }

void Box3DDistanceJoint::set_spring_enabled(bool p_v) {
	spring_enabled = p_v;
	if (joint_live()) {
		b3DistanceJoint_EnableSpring(joint_id, p_v);
	}
	refresh_warnings();
}
bool Box3DDistanceJoint::get_spring_enabled() const { return spring_enabled; }

void Box3DDistanceJoint::set_spring_hertz(double p_v) {
	spring_hertz = MAX(p_v, 0.0);
	if (joint_live()) {
		b3DistanceJoint_SetSpringHertz(joint_id, (float)spring_hertz);
	}
}
double Box3DDistanceJoint::get_spring_hertz() const { return spring_hertz; }

void Box3DDistanceJoint::set_spring_damping(double p_v) {
	spring_damping = MAX(p_v, 0.0);
	if (joint_live()) {
		b3DistanceJoint_SetSpringDampingRatio(joint_id, (float)spring_damping);
	}
}
double Box3DDistanceJoint::get_spring_damping() const { return spring_damping; }

void Box3DDistanceJoint::set_limit_enabled(bool p_v) {
	limit_enabled = p_v;
	if (joint_live()) {
		b3DistanceJoint_EnableLimit(joint_id, p_v);
	}
	refresh_warnings();
}
bool Box3DDistanceJoint::get_limit_enabled() const { return limit_enabled; }

void Box3DDistanceJoint::set_min_length(double p_v) {
	min_length = p_v;
	if (joint_live()) {
		b3DistanceJoint_SetLengthRange(joint_id, (float)min_length, (float)max_length);
	}
	refresh_warnings();
}
double Box3DDistanceJoint::get_min_length() const { return min_length; }

void Box3DDistanceJoint::set_max_length(double p_v) {
	max_length = p_v;
	if (joint_live()) {
		b3DistanceJoint_SetLengthRange(joint_id, (float)min_length, (float)max_length);
	}
	refresh_warnings();
}
double Box3DDistanceJoint::get_max_length() const { return max_length; }

void Box3DDistanceJoint::set_motor_enabled(bool p_v) {
	motor_enabled = p_v;
	if (joint_live()) {
		b3DistanceJoint_EnableMotor(joint_id, p_v);
	}
	refresh_warnings();
}
bool Box3DDistanceJoint::get_motor_enabled() const { return motor_enabled; }

void Box3DDistanceJoint::set_motor_speed(double p_v) {
	bool changed = p_v != motor_speed;
	motor_speed = p_v;
	if (joint_live()) {
		b3DistanceJoint_SetMotorSpeed(joint_id, (float)p_v);
		if (changed) {
			wake_bodies();
		}
	}
}
double Box3DDistanceJoint::get_motor_speed() const { return motor_speed; }

void Box3DDistanceJoint::set_max_motor_force(double p_v) {
	max_motor_force = MAX(p_v, 0.0);
	if (joint_live()) {
		b3DistanceJoint_SetMaxMotorForce(joint_id, (float)max_motor_force);
	}
	refresh_warnings();
}
double Box3DDistanceJoint::get_max_motor_force() const { return max_motor_force; }

void Box3DDistanceJoint::set_spring_force_range(double p_lower, double p_upper) {
	lower_spring_force = p_lower;
	upper_spring_force = p_upper;
	if (joint_live()) {
		b3DistanceJoint_SetSpringForceRange(joint_id, (float)p_lower, (float)p_upper);
	}
}

Vector2 Box3DDistanceJoint::get_spring_force_range() const {
	if (joint_live()) {
		float lower = 0.0f;
		float upper = 0.0f;
		b3DistanceJoint_GetSpringForceRange(joint_id, &lower, &upper);
		return Vector2((real_t)lower, (real_t)upper);
	}
	return Vector2((real_t)lower_spring_force, (real_t)upper_spring_force);
}

double Box3DDistanceJoint::get_current_length() const {
	return joint_live() ? b3DistanceJoint_GetCurrentLength(joint_id) : 0.0;
}

double Box3DDistanceJoint::get_motor_force() const {
	return joint_live() ? b3DistanceJoint_GetMotorForce(joint_id) : 0.0;
}

void Box3DDistanceJoint::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_length", "length"), &Box3DDistanceJoint::set_length);
	ClassDB::bind_method(D_METHOD("get_length"), &Box3DDistanceJoint::get_length);
	ClassDB::bind_method(D_METHOD("set_spring_enabled", "enabled"), &Box3DDistanceJoint::set_spring_enabled);
	ClassDB::bind_method(D_METHOD("get_spring_enabled"), &Box3DDistanceJoint::get_spring_enabled);
	ClassDB::bind_method(D_METHOD("set_spring_hertz", "hertz"), &Box3DDistanceJoint::set_spring_hertz);
	ClassDB::bind_method(D_METHOD("get_spring_hertz"), &Box3DDistanceJoint::get_spring_hertz);
	ClassDB::bind_method(D_METHOD("set_spring_damping", "ratio"), &Box3DDistanceJoint::set_spring_damping);
	ClassDB::bind_method(D_METHOD("get_spring_damping"), &Box3DDistanceJoint::get_spring_damping);
	ClassDB::bind_method(D_METHOD("set_limit_enabled", "enabled"), &Box3DDistanceJoint::set_limit_enabled);
	ClassDB::bind_method(D_METHOD("get_limit_enabled"), &Box3DDistanceJoint::get_limit_enabled);
	ClassDB::bind_method(D_METHOD("set_min_length", "length"), &Box3DDistanceJoint::set_min_length);
	ClassDB::bind_method(D_METHOD("get_min_length"), &Box3DDistanceJoint::get_min_length);
	ClassDB::bind_method(D_METHOD("set_max_length", "length"), &Box3DDistanceJoint::set_max_length);
	ClassDB::bind_method(D_METHOD("get_max_length"), &Box3DDistanceJoint::get_max_length);
	ClassDB::bind_method(D_METHOD("set_motor_enabled", "enabled"), &Box3DDistanceJoint::set_motor_enabled);
	ClassDB::bind_method(D_METHOD("get_motor_enabled"), &Box3DDistanceJoint::get_motor_enabled);
	ClassDB::bind_method(D_METHOD("set_motor_speed", "meters_per_sec"), &Box3DDistanceJoint::set_motor_speed);
	ClassDB::bind_method(D_METHOD("get_motor_speed"), &Box3DDistanceJoint::get_motor_speed);
	ClassDB::bind_method(D_METHOD("set_max_motor_force", "force"), &Box3DDistanceJoint::set_max_motor_force);
	ClassDB::bind_method(D_METHOD("get_max_motor_force"), &Box3DDistanceJoint::get_max_motor_force);
	ClassDB::bind_method(D_METHOD("set_spring_force_range", "lower_force", "upper_force"), &Box3DDistanceJoint::set_spring_force_range);
	ClassDB::bind_method(D_METHOD("get_spring_force_range"), &Box3DDistanceJoint::get_spring_force_range);
	ClassDB::bind_method(D_METHOD("get_current_length"), &Box3DDistanceJoint::get_current_length);
	ClassDB::bind_method(D_METHOD("get_motor_force"), &Box3DDistanceJoint::get_motor_force);

	// -1 is not a length: it means "measure the bodies when the joint is
	// created", which is what authoring in the editor wants.
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "length", PROPERTY_HINT_RANGE, "-1,100,0.01,or_greater,suffix:m"), "set_length", "get_length");
	// The spring comes first because the limit and the motor below only run
	// while it is on: without it the joint is rigid at Length.
	ADD_GROUP("Spring", "");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "spring_enabled"), "set_spring_enabled", "get_spring_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "spring_hertz", PROPERTY_HINT_RANGE, "0,60,0.1,or_greater,suffix:Hz"), "set_spring_hertz", "get_spring_hertz");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "spring_damping", PROPERTY_HINT_RANGE, "0,10,0.01,or_greater"), "set_spring_damping", "get_spring_damping");
	ADD_GROUP("Limit", "");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "limit_enabled"), "set_limit_enabled", "get_limit_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "min_length", PROPERTY_HINT_RANGE, "0,100,0.01,or_greater,suffix:m"), "set_min_length", "get_min_length");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "max_length", PROPERTY_HINT_RANGE, "0,100,0.01,or_greater,suffix:m"), "set_max_length", "get_max_length");
	ADD_GROUP("Motor", "");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "motor_enabled"), "set_motor_enabled", "get_motor_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "motor_speed", PROPERTY_HINT_RANGE, "-20,20,0.1,suffix:m/s"), "set_motor_speed", "get_motor_speed");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "max_motor_force", PROPERTY_HINT_RANGE, "0,10000,1,or_greater,suffix:N"), "set_max_motor_force", "get_max_motor_force");
}

// ---------------------------------------------------------------------------
// Box3DBallJoint (spherical)
// ---------------------------------------------------------------------------

b3JointId Box3DBallJoint::create_specific(b3WorldId p_world, b3BodyId p_a, b3BodyId p_b,
		const Transform3D &p_xf_a, const Transform3D &p_xf_b, const Transform3D &p_joint) {
	b3SphericalJointDef def = b3DefaultSphericalJointDef();
	def.base.bodyIdA = p_a;
	def.base.bodyIdB = p_b;
	def.base.localFrameA = local_frame(p_xf_a, p_joint);
	def.base.localFrameB = local_frame(p_xf_b, p_joint);
	def.base.collideConnected = collide_connected;
	apply_base_def(def.base);
	def.enableConeLimit = cone_limit_enabled;
	def.coneAngle = (float)cone_angle;
	def.enableTwistLimit = twist_limit_enabled;
	def.lowerTwistAngle = (float)twist_lower;
	def.upperTwistAngle = (float)twist_upper;
	// Angular spring toward the spawn pose (frames coincide at creation).
	def.enableSpring = spring_enabled;
	def.hertz = (float)spring_hertz;
	def.dampingRatio = (float)spring_damping;
	def.targetRotation = to_b3(target_rotation);
	def.enableMotor = motor_enabled;
	def.motorVelocity = to_b3(motor_velocity);
	def.maxMotorTorque = (float)max_motor_torque;
	// A zero-velocity motor with a torque cap acts as dry friction, the same
	// trick box3d's own human prefab uses to keep ragdoll limbs from flailing.
	// Only the shorthand when no explicit motor is configured.
	if (!motor_enabled && friction_torque > 0.0) {
		def.enableMotor = true;
		def.motorVelocity = b3Vec3_zero;
		def.maxMotorTorque = (float)friction_torque;
	}
	return b3CreateSphericalJoint(p_world, &def);
}

void Box3DBallJoint::collect_type_warnings(PackedStringArray &p_warnings) const {
	// spherical_joint.c:484 clamps the motor impulse to maxMotorTorque * h.
	// friction_torque is the other way in, and it is only applied when the
	// explicit motor is off (see create_specific), so it is not a substitute.
	if (motor_enabled && max_motor_torque <= 0.0) {
		p_warnings.push_back(
				"Motor Enabled is on but Max Motor Torque is 0, so the motor has no "
				"torque to spend and Motor Velocity is never reached.\nRaise Max Motor "
				"Torque. (Friction Torque is a separate shorthand and is ignored while "
				"the explicit motor is on.)");
	}
	// b3SphericalJoint_SetConeLimit asserts 0 <= angle <= PI/2 (spherical_joint.c:42):
	// the cone is a half-angle, so 90 degrees is already a full hemisphere.
	if (cone_limit_enabled && cone_angle > 0.5 * (double)B3_PI) {
		p_warnings.push_back(
				"Cone Angle is above 90 degrees. It is a half-angle, and Box3D only "
				"supports 0 to 90 (90 is already a full hemisphere of freedom); a "
				"larger value trips an assert in a debug build of Box3D.\nLower Cone "
				"Angle to 90 degrees or less, or turn the cone limit off to leave the "
				"swing free.");
	}
	if (twist_limit_enabled && twist_lower > twist_upper) {
		p_warnings.push_back(
				"Twist Lower is above Twist Upper, so there is no twist angle the "
				"joint is allowed to rest at.\nSwap the two values.");
	}
}

void Box3DBallJoint::set_cone_limit_enabled(bool p_v) {
	cone_limit_enabled = p_v;
	if (joint_live()) {
		b3SphericalJoint_EnableConeLimit(joint_id, p_v);
	}
	refresh_warnings();
}
bool Box3DBallJoint::get_cone_limit_enabled() const { return cone_limit_enabled; }

void Box3DBallJoint::set_cone_angle(double p_v) {
	cone_angle = p_v;
	if (joint_live()) {
		b3SphericalJoint_SetConeLimit(joint_id, (float)p_v);
	}
	refresh_warnings();
}
double Box3DBallJoint::get_cone_angle() const { return cone_angle; }

void Box3DBallJoint::set_twist_limit_enabled(bool p_v) {
	twist_limit_enabled = p_v;
	if (joint_live()) {
		b3SphericalJoint_EnableTwistLimit(joint_id, p_v);
	}
	refresh_warnings();
}
bool Box3DBallJoint::get_twist_limit_enabled() const { return twist_limit_enabled; }

void Box3DBallJoint::set_twist_lower(double p_v) {
	twist_lower = p_v;
	if (joint_live()) {
		b3SphericalJoint_SetTwistLimits(joint_id, (float)twist_lower, (float)twist_upper);
	}
	refresh_warnings();
}
double Box3DBallJoint::get_twist_lower() const { return twist_lower; }

void Box3DBallJoint::set_twist_upper(double p_v) {
	twist_upper = p_v;
	if (joint_live()) {
		b3SphericalJoint_SetTwistLimits(joint_id, (float)twist_lower, (float)twist_upper);
	}
	refresh_warnings();
}
double Box3DBallJoint::get_twist_upper() const { return twist_upper; }

void Box3DBallJoint::set_spring_enabled(bool p_v) {
	spring_enabled = p_v;
	if (joint_live()) {
		b3SphericalJoint_EnableSpring(joint_id, p_v);
	}
}
bool Box3DBallJoint::get_spring_enabled() const { return spring_enabled; }

void Box3DBallJoint::set_spring_hertz(double p_v) {
	spring_hertz = MAX(p_v, 0.0);
	if (joint_live()) {
		b3SphericalJoint_SetSpringHertz(joint_id, (float)spring_hertz);
	}
}
double Box3DBallJoint::get_spring_hertz() const { return spring_hertz; }

void Box3DBallJoint::set_spring_damping(double p_v) {
	spring_damping = MAX(p_v, 0.0);
	if (joint_live()) {
		b3SphericalJoint_SetSpringDampingRatio(joint_id, (float)spring_damping);
	}
}
double Box3DBallJoint::get_spring_damping() const { return spring_damping; }

// The three inputs to the motor decision (motor_enabled, motor_velocity /
// max_motor_torque, friction_torque) all route through here rather than pushing
// their own b3 call, because friction_torque drives the SAME motor: pushing one
// of them in isolation would silently overwrite the other's use of it.
void Box3DBallJoint::apply_motor_state() {
	if (!joint_live()) {
		return;
	}
	// Mirrors create_specific exactly (box3d.h:1550-1565).
	const bool use_friction = !motor_enabled && friction_torque > 0.0;
	b3SphericalJoint_EnableMotor(joint_id, motor_enabled || use_friction);
	b3SphericalJoint_SetMotorVelocity(joint_id, use_friction ? b3Vec3_zero : to_b3(motor_velocity));
	b3SphericalJoint_SetMaxMotorTorque(joint_id, (float)(use_friction ? friction_torque : max_motor_torque));
}

void Box3DBallJoint::set_friction_torque(double p_v) {
	const double previous = friction_torque;
	friction_torque = MAX(p_v, 0.0);
	// Live since P-036: this used to rebuild the joint, which dropped the
	// warm-start impulse and popped a loaded ragdoll every time a limb's
	// friction was nudged. The shorthand is only ever a zero-velocity motor
	// with a torque cap, so the two live setters express it exactly.
	apply_motor_state();
	if (!motor_enabled && previous != friction_torque) {
		// Changing the resistance is a drive-target change, and a sleeping body
		// would otherwise ignore it (box3d_joint.h wake_bodies note).
		wake_bodies();
	}
}
double Box3DBallJoint::get_friction_torque() const { return friction_torque; }

void Box3DBallJoint::set_target_rotation(const Quaternion &p_v) {
	bool changed = p_v != target_rotation;
	target_rotation = p_v;
	if (joint_live()) {
		b3SphericalJoint_SetTargetRotation(joint_id, to_b3(p_v));
		if (changed) {
			wake_bodies();
		}
	}
}
Quaternion Box3DBallJoint::get_target_rotation() const { return target_rotation; }

void Box3DBallJoint::set_motor_enabled(bool p_v) {
	motor_enabled = p_v;
	// Not a plain EnableMotor: turning the explicit motor off must hand the
	// motor back to friction_torque if one is authored, and turning it on must
	// take the velocity and torque cap back from it.
	apply_motor_state();
	refresh_warnings();
}
bool Box3DBallJoint::get_motor_enabled() const { return motor_enabled; }

void Box3DBallJoint::set_motor_velocity(const Vector3 &p_v) {
	bool changed = p_v != motor_velocity;
	motor_velocity = p_v;
	apply_motor_state();
	if (changed && joint_live()) {
		wake_bodies();
	}
}
Vector3 Box3DBallJoint::get_motor_velocity() const { return motor_velocity; }

void Box3DBallJoint::set_max_motor_torque(double p_v) {
	max_motor_torque = MAX(p_v, 0.0);
	apply_motor_state();
	refresh_warnings();
}
double Box3DBallJoint::get_max_motor_torque() const { return max_motor_torque; }

double Box3DBallJoint::get_current_cone_angle() const {
	return joint_live() ? b3SphericalJoint_GetConeAngle(joint_id) : 0.0;
}

double Box3DBallJoint::get_current_twist_angle() const {
	return joint_live() ? b3SphericalJoint_GetTwistAngle(joint_id) : 0.0;
}

Vector3 Box3DBallJoint::get_motor_torque() const {
	return joint_live() ? to_gd(b3SphericalJoint_GetMotorTorque(joint_id)) : Vector3();
}

void Box3DBallJoint::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_cone_limit_enabled", "enabled"), &Box3DBallJoint::set_cone_limit_enabled);
	ClassDB::bind_method(D_METHOD("get_cone_limit_enabled"), &Box3DBallJoint::get_cone_limit_enabled);
	ClassDB::bind_method(D_METHOD("set_cone_angle", "radians"), &Box3DBallJoint::set_cone_angle);
	ClassDB::bind_method(D_METHOD("get_cone_angle"), &Box3DBallJoint::get_cone_angle);
	ClassDB::bind_method(D_METHOD("set_twist_limit_enabled", "enabled"), &Box3DBallJoint::set_twist_limit_enabled);
	ClassDB::bind_method(D_METHOD("get_twist_limit_enabled"), &Box3DBallJoint::get_twist_limit_enabled);
	ClassDB::bind_method(D_METHOD("set_twist_lower", "radians"), &Box3DBallJoint::set_twist_lower);
	ClassDB::bind_method(D_METHOD("get_twist_lower"), &Box3DBallJoint::get_twist_lower);
	ClassDB::bind_method(D_METHOD("set_twist_upper", "radians"), &Box3DBallJoint::set_twist_upper);
	ClassDB::bind_method(D_METHOD("get_twist_upper"), &Box3DBallJoint::get_twist_upper);
	ClassDB::bind_method(D_METHOD("set_spring_enabled", "enabled"), &Box3DBallJoint::set_spring_enabled);
	ClassDB::bind_method(D_METHOD("get_spring_enabled"), &Box3DBallJoint::get_spring_enabled);
	ClassDB::bind_method(D_METHOD("set_spring_hertz", "hertz"), &Box3DBallJoint::set_spring_hertz);
	ClassDB::bind_method(D_METHOD("get_spring_hertz"), &Box3DBallJoint::get_spring_hertz);
	ClassDB::bind_method(D_METHOD("set_spring_damping", "ratio"), &Box3DBallJoint::set_spring_damping);
	ClassDB::bind_method(D_METHOD("get_spring_damping"), &Box3DBallJoint::get_spring_damping);
	ClassDB::bind_method(D_METHOD("set_friction_torque", "torque"), &Box3DBallJoint::set_friction_torque);
	ClassDB::bind_method(D_METHOD("get_friction_torque"), &Box3DBallJoint::get_friction_torque);
	ClassDB::bind_method(D_METHOD("set_target_rotation", "rotation"), &Box3DBallJoint::set_target_rotation);
	ClassDB::bind_method(D_METHOD("get_target_rotation"), &Box3DBallJoint::get_target_rotation);
	ClassDB::bind_method(D_METHOD("set_motor_enabled", "enabled"), &Box3DBallJoint::set_motor_enabled);
	ClassDB::bind_method(D_METHOD("get_motor_enabled"), &Box3DBallJoint::get_motor_enabled);
	ClassDB::bind_method(D_METHOD("set_motor_velocity", "radians_per_sec"), &Box3DBallJoint::set_motor_velocity);
	ClassDB::bind_method(D_METHOD("get_motor_velocity"), &Box3DBallJoint::get_motor_velocity);
	ClassDB::bind_method(D_METHOD("set_max_motor_torque", "torque"), &Box3DBallJoint::set_max_motor_torque);
	ClassDB::bind_method(D_METHOD("get_max_motor_torque"), &Box3DBallJoint::get_max_motor_torque);
	ClassDB::bind_method(D_METHOD("get_current_cone_angle"), &Box3DBallJoint::get_current_cone_angle);
	ClassDB::bind_method(D_METHOD("get_current_twist_angle"), &Box3DBallJoint::get_current_twist_angle);
	ClassDB::bind_method(D_METHOD("get_motor_torque"), &Box3DBallJoint::get_motor_torque);

	// friction_torque is the one knob that stands alone: it is the shorthand for
	// a zero-target motor, so it sits above the mechanisms it substitutes for.
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "friction_torque", PROPERTY_HINT_RANGE, torque_range("0,100,0.1,or_greater")), "set_friction_torque", "get_friction_torque");
	ADD_GROUP("Cone Limit", "");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "cone_limit_enabled"), "set_cone_limit_enabled", "get_cone_limit_enabled");
	// Box3D accepts 0 to PI/2 here (spherical_joint.c:42): the cone angle is a
	// HALF-angle, so 90 degrees is already a full hemisphere of swing.
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "cone_angle", PROPERTY_HINT_RANGE, "0,90,0.1,radians_as_degrees"), "set_cone_angle", "get_cone_angle");
	ADD_GROUP("Twist Limit", "");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "twist_limit_enabled"), "set_twist_limit_enabled", "get_twist_limit_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "twist_lower", PROPERTY_HINT_RANGE, "-180,180,0.1,radians_as_degrees"), "set_twist_lower", "get_twist_lower");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "twist_upper", PROPERTY_HINT_RANGE, "-180,180,0.1,radians_as_degrees"), "set_twist_upper", "get_twist_upper");
	ADD_GROUP("Spring", "");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "spring_enabled"), "set_spring_enabled", "get_spring_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "spring_hertz", PROPERTY_HINT_RANGE, "0,30,0.1,or_greater,suffix:Hz"), "set_spring_hertz", "get_spring_hertz");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "spring_damping", PROPERTY_HINT_RANGE, "0,4,0.05,or_greater"), "set_spring_damping", "get_spring_damping");
	// The spring's target, hence its place in this group rather than beside the
	// motor's velocity target.
	ADD_PROPERTY(PropertyInfo(Variant::QUATERNION, "target_rotation"), "set_target_rotation", "get_target_rotation");
	ADD_GROUP("Motor", "motor_");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "motor_enabled"), "set_motor_enabled", "get_motor_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::VECTOR3, "motor_velocity", PROPERTY_HINT_NONE, "suffix:rad/s"), "set_motor_velocity", "get_motor_velocity");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "max_motor_torque", PROPERTY_HINT_RANGE, torque_range("0,1000,0.1,or_greater")), "set_max_motor_torque", "get_max_motor_torque");
}

// ---------------------------------------------------------------------------
// Box3DFixedJoint (weld)
// ---------------------------------------------------------------------------

b3JointId Box3DFixedJoint::create_specific(b3WorldId p_world, b3BodyId p_a, b3BodyId p_b,
		const Transform3D &p_xf_a, const Transform3D &p_xf_b, const Transform3D &p_joint) {
	b3WeldJointDef def = b3DefaultWeldJointDef();
	def.base.bodyIdA = p_a;
	def.base.bodyIdB = p_b;
	def.base.localFrameA = local_frame(p_xf_a, p_joint);
	def.base.localFrameB = local_frame(p_xf_b, p_joint);
	def.base.collideConnected = collide_connected;
	apply_base_def(def.base);
	def.linearHertz = (float)linear_hertz;
	def.angularHertz = (float)angular_hertz;
	def.linearDampingRatio = (float)linear_damping;
	def.angularDampingRatio = (float)angular_damping;
	return b3CreateWeldJoint(p_world, &def);
}

void Box3DFixedJoint::collect_type_warnings(PackedStringArray &p_warnings) const {
	// weld_joint.c:125/134 short-circuits to the rigid joint softness whenever
	// the matching hertz is 0, so the damping ratio beside it is never read.
	if (linear_damping > 0.0 && linear_hertz <= 0.0) {
		p_warnings.push_back(
				"Linear Damping does nothing while Linear Hertz is 0: with no spring "
				"the weld is perfectly rigid and the damping ratio is never used.\n"
				"Raise Linear Hertz to make the weld springy, or leave Linear Damping "
				"at 0.");
	}
	if (angular_damping > 0.0 && angular_hertz <= 0.0) {
		p_warnings.push_back(
				"Angular Damping does nothing while Angular Hertz is 0: with no spring "
				"the weld is perfectly rigid and the damping ratio is never used.\n"
				"Raise Angular Hertz to make the weld springy, or leave Angular "
				"Damping at 0.");
	}
}

// All four weld parameters have live setters upstream. Use them rather than
// rebuilding: a rebuild re-anchors the weld on the bodies' *current* poses, so
// tweaking softness at runtime would silently freeze in whatever sag the joint
// had at that instant.
void Box3DFixedJoint::set_linear_hertz(double p_v) {
	linear_hertz = MAX(p_v, 0.0);
	if (joint_live()) {
		b3WeldJoint_SetLinearHertz(joint_id, (float)linear_hertz);
	}
	refresh_warnings();
}
double Box3DFixedJoint::get_linear_hertz() const { return linear_hertz; }

void Box3DFixedJoint::set_angular_hertz(double p_v) {
	angular_hertz = MAX(p_v, 0.0);
	if (joint_live()) {
		b3WeldJoint_SetAngularHertz(joint_id, (float)angular_hertz);
	}
	refresh_warnings();
}
double Box3DFixedJoint::get_angular_hertz() const { return angular_hertz; }

void Box3DFixedJoint::set_linear_damping(double p_v) {
	linear_damping = MAX(p_v, 0.0);
	if (joint_live()) {
		b3WeldJoint_SetLinearDampingRatio(joint_id, (float)linear_damping);
	}
	refresh_warnings();
}
double Box3DFixedJoint::get_linear_damping() const { return linear_damping; }

void Box3DFixedJoint::set_angular_damping(double p_v) {
	angular_damping = MAX(p_v, 0.0);
	if (joint_live()) {
		b3WeldJoint_SetAngularDampingRatio(joint_id, (float)angular_damping);
	}
	refresh_warnings();
}
double Box3DFixedJoint::get_angular_damping() const { return angular_damping; }

void Box3DFixedJoint::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_linear_hertz", "hertz"), &Box3DFixedJoint::set_linear_hertz);
	ClassDB::bind_method(D_METHOD("get_linear_hertz"), &Box3DFixedJoint::get_linear_hertz);
	ClassDB::bind_method(D_METHOD("set_angular_hertz", "hertz"), &Box3DFixedJoint::set_angular_hertz);
	ClassDB::bind_method(D_METHOD("get_angular_hertz"), &Box3DFixedJoint::get_angular_hertz);
	ClassDB::bind_method(D_METHOD("set_linear_damping", "ratio"), &Box3DFixedJoint::set_linear_damping);
	ClassDB::bind_method(D_METHOD("get_linear_damping"), &Box3DFixedJoint::get_linear_damping);
	ClassDB::bind_method(D_METHOD("set_angular_damping", "ratio"), &Box3DFixedJoint::set_angular_damping);
	ClassDB::bind_method(D_METHOD("get_angular_damping"), &Box3DFixedJoint::get_angular_damping);

	// 0 Hz is not "no weld": it is the rigid weld, and the damping ratio beside
	// it is then unused (weld_joint.c:125).
	ADD_GROUP("Linear", "linear_");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "linear_hertz", PROPERTY_HINT_RANGE, "0,120,0.5,or_greater,suffix:Hz"), "set_linear_hertz", "get_linear_hertz");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "linear_damping", PROPERTY_HINT_RANGE, "0,10,0.01,or_greater"), "set_linear_damping", "get_linear_damping");
	ADD_GROUP("Angular", "angular_");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "angular_hertz", PROPERTY_HINT_RANGE, "0,120,0.5,or_greater,suffix:Hz"), "set_angular_hertz", "get_angular_hertz");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "angular_damping", PROPERTY_HINT_RANGE, "0,10,0.01,or_greater"), "set_angular_damping", "get_angular_damping");
}

// ---------------------------------------------------------------------------
// Box3DWheelJoint
// ---------------------------------------------------------------------------

b3JointId Box3DWheelJoint::create_specific(b3WorldId p_world, b3BodyId p_a, b3BodyId p_b,
		const Transform3D &p_xf_a, const Transform3D &p_xf_b, const Transform3D &p_joint) {
	b3WheelJointDef def = b3DefaultWheelJointDef();
	def.base.bodyIdA = p_a;
	def.base.bodyIdB = p_b;
	// box3d's wheel joint suspends/steers along frame A's local X and spins the
	// wheel about frame B's local Z. This node exposes Y as the suspension axis
	// and Z as the axle, so frame A gets the node basis with (X,Y) rotated to
	// put b3's X on the node's Y; frame B takes the node basis directly (its Z
	// is already the axle). Same relative frames as upstream's Driving sample.
	Transform3D frame_a = p_joint;
	frame_a.basis = p_joint.basis * Basis(Vector3(0, 1, 0), Vector3(-1, 0, 0), Vector3(0, 0, 1));
	def.base.localFrameA = local_frame(p_xf_a, frame_a);
	def.base.localFrameB = local_frame(p_xf_b, p_joint);
	def.base.collideConnected = collide_connected;
	apply_base_def(def.base);
	def.enableSuspensionSpring = suspension_enabled;
	def.suspensionHertz = (float)suspension_hertz;
	def.suspensionDampingRatio = (float)suspension_damping;
	def.enableSuspensionLimit = suspension_limit_enabled;
	def.lowerSuspensionLimit = (float)lower_suspension_limit;
	def.upperSuspensionLimit = (float)upper_suspension_limit;
	def.enableSpinMotor = spin_motor_enabled;
	def.spinSpeed = (float)spin_motor_speed;
	def.maxSpinTorque = (float)max_spin_torque;
	def.enableSteering = steering_enabled;
	def.steeringHertz = (float)steering_hertz;
	def.steeringDampingRatio = (float)steering_damping;
	def.targetSteeringAngle = (float)target_steering_angle;
	def.maxSteeringTorque = (float)max_steering_torque;
	def.enableSteeringLimit = steering_limit_enabled;
	def.lowerSteeringLimit = (float)lower_steering_limit;
	def.upperSteeringLimit = (float)upper_steering_limit;
	return b3CreateWheelJoint(p_world, &def);
}

void Box3DWheelJoint::collect_type_warnings(PackedStringArray &p_warnings) const {
	// wheel_joint.c:666 and :712 clamp the two drives to their torque budget * h,
	// and both budgets default to 0 (b3DefaultWheelJointDef zeroes them), so a
	// car that will not drive or will not steer usually lands here.
	if (spin_motor_enabled && max_spin_torque <= 0.0) {
		p_warnings.push_back(
				"Spin Motor Enabled is on but Max Spin Torque is 0, so the wheel has "
				"no drive torque and the vehicle does not move.\nRaise Max Spin "
				"Torque.");
	}
	if (steering_enabled && max_steering_torque <= 0.0) {
		p_warnings.push_back(
				"Steering Enabled is on but Max Steering Torque is 0, so the wheel "
				"never turns toward Target Steering Angle.\nRaise Max Steering "
				"Torque.");
	}
	// Both limit setters assert lower <= upper (wheel_joint.c:96, :248).
	if (suspension_limit_enabled && lower_suspension_limit > upper_suspension_limit) {
		p_warnings.push_back(
				"Lower Suspension Limit is above Upper Suspension Limit, which Box3D "
				"does not accept (it asserts in a debug build).\nSwap the two values.");
	}
	if (steering_limit_enabled && lower_steering_limit > upper_steering_limit) {
		p_warnings.push_back(
				"Lower Steering Limit is above Upper Steering Limit, which Box3D does "
				"not accept (it asserts in a debug build).\nSwap the two values.");
	}
}

void Box3DWheelJoint::set_suspension_enabled(bool p_v) {
	suspension_enabled = p_v;
	if (joint_live()) {
		b3WheelJoint_EnableSuspension(joint_id, p_v);
	}
}
bool Box3DWheelJoint::get_suspension_enabled() const { return suspension_enabled; }

void Box3DWheelJoint::set_suspension_hertz(double p_v) {
	suspension_hertz = p_v;
	if (joint_live()) {
		b3WheelJoint_SetSuspensionHertz(joint_id, (float)p_v);
	}
}
double Box3DWheelJoint::get_suspension_hertz() const { return suspension_hertz; }

void Box3DWheelJoint::set_suspension_damping(double p_v) {
	suspension_damping = p_v;
	if (joint_live()) {
		b3WheelJoint_SetSuspensionDampingRatio(joint_id, (float)p_v);
	}
}
double Box3DWheelJoint::get_suspension_damping() const { return suspension_damping; }

void Box3DWheelJoint::set_suspension_limit_enabled(bool p_v) {
	suspension_limit_enabled = p_v;
	if (joint_live()) {
		b3WheelJoint_EnableSuspensionLimit(joint_id, p_v);
	}
	refresh_warnings();
}
bool Box3DWheelJoint::get_suspension_limit_enabled() const { return suspension_limit_enabled; }

void Box3DWheelJoint::set_lower_suspension_limit(double p_v) {
	lower_suspension_limit = p_v;
	if (joint_live()) {
		b3WheelJoint_SetSuspensionLimits(joint_id, (float)lower_suspension_limit, (float)upper_suspension_limit);
	}
	refresh_warnings();
}
double Box3DWheelJoint::get_lower_suspension_limit() const { return lower_suspension_limit; }

void Box3DWheelJoint::set_upper_suspension_limit(double p_v) {
	upper_suspension_limit = p_v;
	if (joint_live()) {
		b3WheelJoint_SetSuspensionLimits(joint_id, (float)lower_suspension_limit, (float)upper_suspension_limit);
	}
	refresh_warnings();
}
double Box3DWheelJoint::get_upper_suspension_limit() const { return upper_suspension_limit; }

void Box3DWheelJoint::set_spin_motor_enabled(bool p_v) {
	spin_motor_enabled = p_v;
	if (joint_live()) {
		b3WheelJoint_EnableSpinMotor(joint_id, p_v);
	}
	refresh_warnings();
}
bool Box3DWheelJoint::get_spin_motor_enabled() const {
	return joint_live() ? b3WheelJoint_IsSpinMotorEnabled(joint_id) : spin_motor_enabled;
}

void Box3DWheelJoint::set_spin_motor_speed(double p_v) {
	bool changed = p_v != spin_motor_speed;
	spin_motor_speed = p_v;
	if (joint_live()) {
		b3WheelJoint_SetSpinMotorSpeed(joint_id, (float)p_v);
		if (changed) {
			wake_bodies();
		}
	}
}
double Box3DWheelJoint::get_spin_motor_speed() const {
	return joint_live() ? b3WheelJoint_GetSpinMotorSpeed(joint_id) : spin_motor_speed;
}

void Box3DWheelJoint::set_max_spin_torque(double p_v) {
	max_spin_torque = p_v;
	if (joint_live()) {
		b3WheelJoint_SetMaxSpinTorque(joint_id, (float)p_v);
	}
	refresh_warnings();
}
double Box3DWheelJoint::get_max_spin_torque() const {
	return joint_live() ? b3WheelJoint_GetMaxSpinTorque(joint_id) : max_spin_torque;
}

void Box3DWheelJoint::set_steering_enabled(bool p_v) {
	steering_enabled = p_v;
	if (joint_live()) {
		b3WheelJoint_EnableSteering(joint_id, p_v);
	}
	refresh_warnings();
}
bool Box3DWheelJoint::get_steering_enabled() const { return steering_enabled; }

void Box3DWheelJoint::set_steering_hertz(double p_v) {
	steering_hertz = p_v;
	if (joint_live()) {
		b3WheelJoint_SetSteeringHertz(joint_id, (float)p_v);
	}
}
double Box3DWheelJoint::get_steering_hertz() const { return steering_hertz; }

void Box3DWheelJoint::set_steering_damping(double p_v) {
	steering_damping = p_v;
	if (joint_live()) {
		b3WheelJoint_SetSteeringDampingRatio(joint_id, (float)p_v);
	}
}
double Box3DWheelJoint::get_steering_damping() const { return steering_damping; }

void Box3DWheelJoint::set_target_steering_angle(double p_v) {
	bool changed = p_v != target_steering_angle;
	target_steering_angle = p_v;
	if (joint_live()) {
		b3WheelJoint_SetTargetSteeringAngle(joint_id, (float)p_v);
		if (changed) {
			wake_bodies();
		}
	}
}
double Box3DWheelJoint::get_target_steering_angle() const { return target_steering_angle; }

void Box3DWheelJoint::set_max_steering_torque(double p_v) {
	max_steering_torque = p_v;
	if (joint_live()) {
		b3WheelJoint_SetMaxSteeringTorque(joint_id, (float)p_v);
	}
	refresh_warnings();
}
double Box3DWheelJoint::get_max_steering_torque() const { return max_steering_torque; }

void Box3DWheelJoint::set_steering_limit_enabled(bool p_v) {
	steering_limit_enabled = p_v;
	if (joint_live()) {
		b3WheelJoint_EnableSteeringLimit(joint_id, p_v);
	}
	refresh_warnings();
}
bool Box3DWheelJoint::get_steering_limit_enabled() const { return steering_limit_enabled; }

void Box3DWheelJoint::set_lower_steering_limit(double p_v) {
	lower_steering_limit = p_v;
	if (joint_live()) {
		b3WheelJoint_SetSteeringLimits(joint_id, (float)lower_steering_limit, (float)upper_steering_limit);
	}
	refresh_warnings();
}
double Box3DWheelJoint::get_lower_steering_limit() const { return lower_steering_limit; }

void Box3DWheelJoint::set_upper_steering_limit(double p_v) {
	upper_steering_limit = p_v;
	if (joint_live()) {
		b3WheelJoint_SetSteeringLimits(joint_id, (float)lower_steering_limit, (float)upper_steering_limit);
	}
	refresh_warnings();
}
double Box3DWheelJoint::get_upper_steering_limit() const { return upper_steering_limit; }

double Box3DWheelJoint::get_spin_speed() const {
	return joint_live() ? b3WheelJoint_GetSpinSpeed(joint_id) : 0.0;
}

double Box3DWheelJoint::get_steering_angle() const {
	return joint_live() ? b3WheelJoint_GetSteeringAngle(joint_id) : 0.0;
}

double Box3DWheelJoint::get_spin_torque() const {
	return joint_live() ? b3WheelJoint_GetSpinTorque(joint_id) : 0.0;
}

double Box3DWheelJoint::get_steering_torque() const {
	return joint_live() ? b3WheelJoint_GetSteeringTorque(joint_id) : 0.0;
}

void Box3DWheelJoint::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_suspension_enabled", "enabled"), &Box3DWheelJoint::set_suspension_enabled);
	ClassDB::bind_method(D_METHOD("get_suspension_enabled"), &Box3DWheelJoint::get_suspension_enabled);
	ClassDB::bind_method(D_METHOD("set_suspension_hertz", "hertz"), &Box3DWheelJoint::set_suspension_hertz);
	ClassDB::bind_method(D_METHOD("get_suspension_hertz"), &Box3DWheelJoint::get_suspension_hertz);
	ClassDB::bind_method(D_METHOD("set_suspension_damping", "ratio"), &Box3DWheelJoint::set_suspension_damping);
	ClassDB::bind_method(D_METHOD("get_suspension_damping"), &Box3DWheelJoint::get_suspension_damping);
	ClassDB::bind_method(D_METHOD("set_suspension_limit_enabled", "enabled"), &Box3DWheelJoint::set_suspension_limit_enabled);
	ClassDB::bind_method(D_METHOD("get_suspension_limit_enabled"), &Box3DWheelJoint::get_suspension_limit_enabled);
	ClassDB::bind_method(D_METHOD("set_lower_suspension_limit", "meters"), &Box3DWheelJoint::set_lower_suspension_limit);
	ClassDB::bind_method(D_METHOD("get_lower_suspension_limit"), &Box3DWheelJoint::get_lower_suspension_limit);
	ClassDB::bind_method(D_METHOD("set_upper_suspension_limit", "meters"), &Box3DWheelJoint::set_upper_suspension_limit);
	ClassDB::bind_method(D_METHOD("get_upper_suspension_limit"), &Box3DWheelJoint::get_upper_suspension_limit);
	ClassDB::bind_method(D_METHOD("set_spin_motor_enabled", "enabled"), &Box3DWheelJoint::set_spin_motor_enabled);
	ClassDB::bind_method(D_METHOD("get_spin_motor_enabled"), &Box3DWheelJoint::get_spin_motor_enabled);
	ClassDB::bind_method(D_METHOD("set_spin_motor_speed", "radians_per_sec"), &Box3DWheelJoint::set_spin_motor_speed);
	ClassDB::bind_method(D_METHOD("get_spin_motor_speed"), &Box3DWheelJoint::get_spin_motor_speed);
	ClassDB::bind_method(D_METHOD("set_max_spin_torque", "torque"), &Box3DWheelJoint::set_max_spin_torque);
	ClassDB::bind_method(D_METHOD("get_max_spin_torque"), &Box3DWheelJoint::get_max_spin_torque);
	ClassDB::bind_method(D_METHOD("set_steering_enabled", "enabled"), &Box3DWheelJoint::set_steering_enabled);
	ClassDB::bind_method(D_METHOD("get_steering_enabled"), &Box3DWheelJoint::get_steering_enabled);
	ClassDB::bind_method(D_METHOD("set_steering_hertz", "hertz"), &Box3DWheelJoint::set_steering_hertz);
	ClassDB::bind_method(D_METHOD("get_steering_hertz"), &Box3DWheelJoint::get_steering_hertz);
	ClassDB::bind_method(D_METHOD("set_steering_damping", "ratio"), &Box3DWheelJoint::set_steering_damping);
	ClassDB::bind_method(D_METHOD("get_steering_damping"), &Box3DWheelJoint::get_steering_damping);
	ClassDB::bind_method(D_METHOD("set_target_steering_angle", "radians"), &Box3DWheelJoint::set_target_steering_angle);
	ClassDB::bind_method(D_METHOD("get_target_steering_angle"), &Box3DWheelJoint::get_target_steering_angle);
	ClassDB::bind_method(D_METHOD("set_max_steering_torque", "torque"), &Box3DWheelJoint::set_max_steering_torque);
	ClassDB::bind_method(D_METHOD("get_max_steering_torque"), &Box3DWheelJoint::get_max_steering_torque);
	ClassDB::bind_method(D_METHOD("set_steering_limit_enabled", "enabled"), &Box3DWheelJoint::set_steering_limit_enabled);
	ClassDB::bind_method(D_METHOD("get_steering_limit_enabled"), &Box3DWheelJoint::get_steering_limit_enabled);
	ClassDB::bind_method(D_METHOD("set_lower_steering_limit", "radians"), &Box3DWheelJoint::set_lower_steering_limit);
	ClassDB::bind_method(D_METHOD("get_lower_steering_limit"), &Box3DWheelJoint::get_lower_steering_limit);
	ClassDB::bind_method(D_METHOD("set_upper_steering_limit", "radians"), &Box3DWheelJoint::set_upper_steering_limit);
	ClassDB::bind_method(D_METHOD("get_upper_steering_limit"), &Box3DWheelJoint::get_upper_steering_limit);
	ClassDB::bind_method(D_METHOD("get_spin_speed"), &Box3DWheelJoint::get_spin_speed);
	ClassDB::bind_method(D_METHOD("get_steering_angle"), &Box3DWheelJoint::get_steering_angle);
	ClassDB::bind_method(D_METHOD("get_spin_torque"), &Box3DWheelJoint::get_spin_torque);
	ClassDB::bind_method(D_METHOD("get_steering_torque"), &Box3DWheelJoint::get_steering_torque);

	ADD_GROUP("Suspension", "suspension_");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "suspension_enabled"), "set_suspension_enabled", "get_suspension_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "suspension_hertz", PROPERTY_HINT_RANGE, "0,60,0.1,or_greater,suffix:Hz"), "set_suspension_hertz", "get_suspension_hertz");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "suspension_damping", PROPERTY_HINT_RANGE, "0,10,0.01,or_greater"), "set_suspension_damping", "get_suspension_damping");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "suspension_limit_enabled"), "set_suspension_limit_enabled", "get_suspension_limit_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "lower_suspension_limit", PROPERTY_HINT_RANGE, "-10,10,0.01,or_greater,suffix:m"), "set_lower_suspension_limit", "get_lower_suspension_limit");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "upper_suspension_limit", PROPERTY_HINT_RANGE, "-10,10,0.01,or_greater,suffix:m"), "set_upper_suspension_limit", "get_upper_suspension_limit");
	ADD_GROUP("Spin Motor", "spin_motor_");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "spin_motor_enabled"), "set_spin_motor_enabled", "get_spin_motor_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "spin_motor_speed", PROPERTY_HINT_RANGE, "-100,100,0.1,suffix:rad/s"), "set_spin_motor_speed", "get_spin_motor_speed");
	// Both drive budgets default to 0, which is a wheel that will not turn; the
	// scene dock warns about each.
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "max_spin_torque", PROPERTY_HINT_RANGE, torque_range("0,10000,0.1,or_greater")), "set_max_spin_torque", "get_max_spin_torque");
	ADD_GROUP("Steering", "steering_");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "steering_enabled"), "set_steering_enabled", "get_steering_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "steering_hertz", PROPERTY_HINT_RANGE, "0,60,0.1,or_greater,suffix:Hz"), "set_steering_hertz", "get_steering_hertz");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "steering_damping", PROPERTY_HINT_RANGE, "0,10,0.01,or_greater"), "set_steering_damping", "get_steering_damping");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "target_steering_angle", PROPERTY_HINT_RANGE, "-90,90,0.1,radians_as_degrees"), "set_target_steering_angle", "get_target_steering_angle");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "max_steering_torque", PROPERTY_HINT_RANGE, torque_range("0,10000,0.1,or_greater")), "set_max_steering_torque", "get_max_steering_torque");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "steering_limit_enabled"), "set_steering_limit_enabled", "get_steering_limit_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "lower_steering_limit", PROPERTY_HINT_RANGE, "-90,90,0.1,radians_as_degrees"), "set_lower_steering_limit", "get_lower_steering_limit");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "upper_steering_limit", PROPERTY_HINT_RANGE, "-90,90,0.1,radians_as_degrees"), "set_upper_steering_limit", "get_upper_steering_limit");
}

// ---------------------------------------------------------------------------
// Box3DParallelJoint
// ---------------------------------------------------------------------------

b3JointId Box3DParallelJoint::create_specific(b3WorldId p_world, b3BodyId p_a, b3BodyId p_b,
		const Transform3D &p_xf_a, const Transform3D &p_xf_b, const Transform3D &p_joint) {
	b3ParallelJointDef def = b3DefaultParallelJointDef();
	def.base.bodyIdA = p_a;
	def.base.bodyIdB = p_b;
	def.base.localFrameA = local_frame(p_xf_a, p_joint);
	def.base.localFrameB = local_frame(p_xf_b, p_joint);
	def.base.collideConnected = collide_connected;
	apply_base_def(def.base);
	def.hertz = (float)spring_hertz;
	def.dampingRatio = (float)spring_damping;
	if (max_torque > 0.0) {
		def.maxTorque = (float)max_torque;
	}
	return b3CreateParallelJoint(p_world, &def);
}

void Box3DParallelJoint::collect_type_warnings(PackedStringArray &p_warnings) const {
	// This joint IS its spring: b3MakeSoft returns an all-zero softness at 0 Hz
	// (solver.h:266), so the constraint applies no impulse whatsoever.
	if (spring_hertz <= 0.0) {
		p_warnings.push_back(
				"Spring Hertz is 0, so this joint applies no torque at all and the "
				"bodies are not aligned.\nRaise Spring Hertz (1 is Box3D's default: "
				"slow and soft; higher snaps upright faster).");
	}
}

void Box3DParallelJoint::set_spring_hertz(double p_v) {
	spring_hertz = p_v;
	if (joint_live()) {
		b3ParallelJoint_SetSpringHertz(joint_id, (float)p_v);
	}
	refresh_warnings();
}
double Box3DParallelJoint::get_spring_hertz() const { return spring_hertz; }

void Box3DParallelJoint::set_spring_damping(double p_v) {
	spring_damping = p_v;
	if (joint_live()) {
		b3ParallelJoint_SetSpringDampingRatio(joint_id, (float)p_v);
	}
}
double Box3DParallelJoint::get_spring_damping() const { return spring_damping; }

void Box3DParallelJoint::set_max_torque(double p_v) {
	max_torque = p_v;
	if (joint_live() && p_v > 0.0) {
		b3ParallelJoint_SetMaxTorque(joint_id, (float)p_v);
	} else {
		rebuild_if_alive(); // back to 0 = unlimited needs the def default
	}
}
double Box3DParallelJoint::get_max_torque() const { return max_torque; }

void Box3DParallelJoint::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_spring_hertz", "hertz"), &Box3DParallelJoint::set_spring_hertz);
	ClassDB::bind_method(D_METHOD("get_spring_hertz"), &Box3DParallelJoint::get_spring_hertz);
	ClassDB::bind_method(D_METHOD("set_spring_damping", "ratio"), &Box3DParallelJoint::set_spring_damping);
	ClassDB::bind_method(D_METHOD("get_spring_damping"), &Box3DParallelJoint::get_spring_damping);
	ClassDB::bind_method(D_METHOD("set_max_torque", "torque"), &Box3DParallelJoint::set_max_torque);
	ClassDB::bind_method(D_METHOD("get_max_torque"), &Box3DParallelJoint::get_max_torque);

	// This joint IS its spring, so 0 Hz means it applies nothing at all.
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "spring_hertz", PROPERTY_HINT_RANGE, "0,60,0.1,or_greater,suffix:Hz"), "set_spring_hertz", "get_spring_hertz");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "spring_damping", PROPERTY_HINT_RANGE, "0,10,0.01,or_greater"), "set_spring_damping", "get_spring_damping");
	// Unlike every other torque budget here, 0 means UNLIMITED (the node keeps
	// Box3D's FLT_MAX default when this is 0), so it gets no warning.
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "max_torque", PROPERTY_HINT_RANGE, torque_range("0,10000,0.1,or_greater")), "set_max_torque", "get_max_torque");
}

// ---------------------------------------------------------------------------
// Box3DFilterJoint
// ---------------------------------------------------------------------------

b3JointId Box3DFilterJoint::create_specific(b3WorldId p_world, b3BodyId p_a, b3BodyId p_b,
		const Transform3D &p_xf_a, const Transform3D &p_xf_b, const Transform3D &p_joint) {
	if (body_b_path.is_empty()) {
		UtilityFunctions::push_warning("Box3DFilterJoint needs body_b: it only filters collisions between two bodies.");
	}
	b3FilterJointDef def = b3DefaultFilterJointDef();
	def.base.bodyIdA = p_a;
	def.base.bodyIdB = p_b;
	// The frames are unused by the solver for this type, but keeping them
	// authored like every other joint means the base-class frame accessors and
	// the debug draw report something meaningful.
	def.base.localFrameA = local_frame(p_xf_a, p_joint);
	def.base.localFrameB = local_frame(p_xf_b, p_joint);
	def.base.collideConnected = collide_connected;
	apply_base_def(def.base);
	return b3CreateFilterJoint(p_world, &def);
}

void Box3DFilterJoint::collect_type_warnings(PackedStringArray &p_warnings) const {
	// The base class treats an empty body_b as "anchor to the world", which is a
	// sensible default for every other type and meaningless for this one: there
	// is nothing to stop colliding with a private static anchor.
	if (!body_a_path.is_empty() && body_b_path.is_empty()) {
		p_warnings.push_back(
				"Body B is empty. A filter joint exists only to stop two specific "
				"bodies colliding, so with one body it filters nothing.\nSet Body B to "
				"the body that Body A should pass through.");
	}
}

void Box3DFilterJoint::_bind_methods() {}

// ---------------------------------------------------------------------------
// Box3DMotorJoint
// ---------------------------------------------------------------------------

b3JointId Box3DMotorJoint::create_specific(b3WorldId p_world, b3BodyId p_a, b3BodyId p_b,
		const Transform3D &p_xf_a, const Transform3D &p_xf_b, const Transform3D &p_joint) {
	b3MotorJointDef def = b3DefaultMotorJointDef();
	def.base.bodyIdA = p_a;
	def.base.bodyIdB = p_b;
	def.base.localFrameA = local_frame(p_xf_a, p_joint);
	def.base.localFrameB = local_frame(p_xf_b, p_joint);
	def.base.collideConnected = collide_connected;
	apply_base_def(def.base);
	def.linearVelocity = to_b3(linear_velocity);
	def.maxVelocityForce = (float)max_force;
	def.angularVelocity = to_b3(angular_velocity);
	def.maxVelocityTorque = (float)max_torque;
	def.linearHertz = (float)linear_hertz;
	def.linearDampingRatio = (float)linear_damping;
	def.maxSpringForce = (float)max_spring_force;
	def.angularHertz = (float)angular_hertz;
	def.angularDampingRatio = (float)angular_damping;
	def.maxSpringTorque = (float)max_spring_torque;
	return b3CreateMotorJoint(p_world, &def);
}

void Box3DMotorJoint::collect_type_warnings(PackedStringArray &p_warnings) const {
	// Unlike every other joint here, the two velocity budgets default to 1000 on
	// this node (upstream's b3DefaultMotorJointDef zeroes them), so these two
	// only fire when someone has zeroed a budget by hand.
	if (linear_velocity != Vector3() && max_force <= 0.0) {
		p_warnings.push_back(
				"Linear Velocity is set but Max Force is 0, so the velocity drive is "
				"skipped entirely (Box3D only runs it while the force budget is above "
				"0).\nRaise Max Force.");
	}
	if (angular_velocity != Vector3() && max_torque <= 0.0) {
		p_warnings.push_back(
				"Angular Velocity is set but Max Torque is 0, so the angular drive is "
				"skipped entirely.\nRaise Max Torque.");
	}
	// motor_joint.c:351 / :302 run each position spring only while BOTH its
	// hertz and its budget are above 0, and the budgets default to 0.
	if (linear_hertz > 0.0 && max_spring_force <= 0.0) {
		p_warnings.push_back(
				"Linear Hertz is set but Max Spring Force is 0, so the position spring "
				"never runs.\nRaise Max Spring Force: Box3D needs both above 0.");
	}
	if (max_spring_force > 0.0 && linear_hertz <= 0.0) {
		p_warnings.push_back(
				"Max Spring Force is set but Linear Hertz is 0, so the position spring "
				"never runs.\nRaise Linear Hertz: Box3D needs both above 0.");
	}
	if (angular_hertz > 0.0 && max_spring_torque <= 0.0) {
		p_warnings.push_back(
				"Angular Hertz is set but Max Spring Torque is 0, so the rotation "
				"spring never runs.\nRaise Max Spring Torque: Box3D needs both above "
				"0.");
	}
	if (max_spring_torque > 0.0 && angular_hertz <= 0.0) {
		p_warnings.push_back(
				"Max Spring Torque is set but Angular Hertz is 0, so the rotation "
				"spring never runs.\nRaise Angular Hertz: Box3D needs both above 0.");
	}
}

void Box3DMotorJoint::set_linear_velocity(const Vector3 &p_v) {
	bool changed = p_v != linear_velocity;
	linear_velocity = p_v;
	if (joint_live()) {
		b3MotorJoint_SetLinearVelocity(joint_id, to_b3(p_v));
		if (changed) {
			wake_bodies();
		}
	}
	refresh_warnings();
}
Vector3 Box3DMotorJoint::get_linear_velocity() const { return linear_velocity; }

void Box3DMotorJoint::set_max_force(double p_v) {
	max_force = p_v;
	if (joint_live()) {
		b3MotorJoint_SetMaxVelocityForce(joint_id, (float)p_v);
	}
	refresh_warnings();
}
double Box3DMotorJoint::get_max_force() const { return max_force; }

void Box3DMotorJoint::set_angular_velocity(const Vector3 &p_v) {
	bool changed = p_v != angular_velocity;
	angular_velocity = p_v;
	if (joint_live()) {
		b3MotorJoint_SetAngularVelocity(joint_id, to_b3(p_v));
		if (changed) {
			wake_bodies();
		}
	}
	refresh_warnings();
}
Vector3 Box3DMotorJoint::get_angular_velocity() const { return angular_velocity; }

void Box3DMotorJoint::set_max_torque(double p_v) {
	max_torque = p_v;
	if (joint_live()) {
		b3MotorJoint_SetMaxVelocityTorque(joint_id, (float)p_v);
	}
	refresh_warnings();
}
double Box3DMotorJoint::get_max_torque() const { return max_torque; }

void Box3DMotorJoint::set_linear_hertz(double p_v) {
	linear_hertz = p_v;
	if (joint_live()) {
		b3MotorJoint_SetLinearHertz(joint_id, (float)p_v);
	}
	refresh_warnings();
}
double Box3DMotorJoint::get_linear_hertz() const { return linear_hertz; }

void Box3DMotorJoint::set_linear_damping(double p_v) {
	linear_damping = p_v;
	if (joint_live()) {
		b3MotorJoint_SetLinearDampingRatio(joint_id, (float)p_v);
	}
}
double Box3DMotorJoint::get_linear_damping() const { return linear_damping; }

void Box3DMotorJoint::set_max_spring_force(double p_v) {
	max_spring_force = p_v;
	if (joint_live()) {
		b3MotorJoint_SetMaxSpringForce(joint_id, (float)p_v);
	}
	refresh_warnings();
}
double Box3DMotorJoint::get_max_spring_force() const { return max_spring_force; }

void Box3DMotorJoint::set_angular_hertz(double p_v) {
	angular_hertz = p_v;
	if (joint_live()) {
		b3MotorJoint_SetAngularHertz(joint_id, (float)p_v);
	}
	refresh_warnings();
}
double Box3DMotorJoint::get_angular_hertz() const { return angular_hertz; }

void Box3DMotorJoint::set_angular_damping(double p_v) {
	angular_damping = p_v;
	if (joint_live()) {
		b3MotorJoint_SetAngularDampingRatio(joint_id, (float)p_v);
	}
}
double Box3DMotorJoint::get_angular_damping() const { return angular_damping; }

void Box3DMotorJoint::set_max_spring_torque(double p_v) {
	max_spring_torque = p_v;
	if (joint_live()) {
		b3MotorJoint_SetMaxSpringTorque(joint_id, (float)p_v);
	}
	refresh_warnings();
}
double Box3DMotorJoint::get_max_spring_torque() const { return max_spring_torque; }

void Box3DMotorJoint::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_linear_velocity", "velocity"), &Box3DMotorJoint::set_linear_velocity);
	ClassDB::bind_method(D_METHOD("get_linear_velocity"), &Box3DMotorJoint::get_linear_velocity);
	ClassDB::bind_method(D_METHOD("set_max_force", "force"), &Box3DMotorJoint::set_max_force);
	ClassDB::bind_method(D_METHOD("get_max_force"), &Box3DMotorJoint::get_max_force);
	ClassDB::bind_method(D_METHOD("set_angular_velocity", "velocity"), &Box3DMotorJoint::set_angular_velocity);
	ClassDB::bind_method(D_METHOD("get_angular_velocity"), &Box3DMotorJoint::get_angular_velocity);
	ClassDB::bind_method(D_METHOD("set_max_torque", "torque"), &Box3DMotorJoint::set_max_torque);
	ClassDB::bind_method(D_METHOD("get_max_torque"), &Box3DMotorJoint::get_max_torque);

	ClassDB::bind_method(D_METHOD("set_linear_hertz", "hertz"), &Box3DMotorJoint::set_linear_hertz);
	ClassDB::bind_method(D_METHOD("get_linear_hertz"), &Box3DMotorJoint::get_linear_hertz);
	ClassDB::bind_method(D_METHOD("set_linear_damping", "ratio"), &Box3DMotorJoint::set_linear_damping);
	ClassDB::bind_method(D_METHOD("get_linear_damping"), &Box3DMotorJoint::get_linear_damping);
	ClassDB::bind_method(D_METHOD("set_max_spring_force", "force"), &Box3DMotorJoint::set_max_spring_force);
	ClassDB::bind_method(D_METHOD("get_max_spring_force"), &Box3DMotorJoint::get_max_spring_force);
	ClassDB::bind_method(D_METHOD("set_angular_hertz", "hertz"), &Box3DMotorJoint::set_angular_hertz);
	ClassDB::bind_method(D_METHOD("get_angular_hertz"), &Box3DMotorJoint::get_angular_hertz);
	ClassDB::bind_method(D_METHOD("set_angular_damping", "ratio"), &Box3DMotorJoint::set_angular_damping);
	ClassDB::bind_method(D_METHOD("get_angular_damping"), &Box3DMotorJoint::get_angular_damping);
	ClassDB::bind_method(D_METHOD("set_max_spring_torque", "torque"), &Box3DMotorJoint::set_max_spring_torque);
	ClassDB::bind_method(D_METHOD("get_max_spring_torque"), &Box3DMotorJoint::get_max_spring_torque);

	// Two independent mechanisms, hence two groups: the velocity drive runs
	// while its budget is above 0, the position spring while BOTH its hertz and
	// its budget are (motor_joint.c:302, :351, :394).
	ADD_GROUP("Velocity Drive", "");
	ADD_PROPERTY(PropertyInfo(Variant::VECTOR3, "linear_velocity", PROPERTY_HINT_NONE, "suffix:m/s"), "set_linear_velocity", "get_linear_velocity");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "max_force", PROPERTY_HINT_RANGE, "0,100000,1,or_greater,suffix:N"), "set_max_force", "get_max_force");
	ADD_PROPERTY(PropertyInfo(Variant::VECTOR3, "angular_velocity", PROPERTY_HINT_NONE, "suffix:rad/s"), "set_angular_velocity", "get_angular_velocity");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "max_torque", PROPERTY_HINT_RANGE, torque_range("0,100000,1,or_greater")), "set_max_torque", "get_max_torque");
	ADD_GROUP("Position Spring", "");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "linear_hertz", PROPERTY_HINT_RANGE, "0,60,0.1,or_greater,suffix:Hz"), "set_linear_hertz", "get_linear_hertz");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "linear_damping", PROPERTY_HINT_RANGE, "0,10,0.01,or_greater"), "set_linear_damping", "get_linear_damping");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "max_spring_force", PROPERTY_HINT_RANGE, "0,100000,1,or_greater,suffix:N"), "set_max_spring_force", "get_max_spring_force");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "angular_hertz", PROPERTY_HINT_RANGE, "0,60,0.1,or_greater,suffix:Hz"), "set_angular_hertz", "get_angular_hertz");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "angular_damping", PROPERTY_HINT_RANGE, "0,10,0.01,or_greater"), "set_angular_damping", "get_angular_damping");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "max_spring_torque", PROPERTY_HINT_RANGE, torque_range("0,100000,1,or_greater")), "set_max_spring_torque", "get_max_spring_torque");
}
