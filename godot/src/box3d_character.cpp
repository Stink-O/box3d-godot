// SPDX-FileCopyrightText: 2026 box3d-godot contributors
// SPDX-License-Identifier: MIT

#include "box3d_character.h"

#include "box3d_body.h"
#include "box3d_conversions.h"
#include "box3d_world.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/string.hpp>

#include <cfloat>

using namespace godot;

namespace {

// Collects the collision planes from b3World_CollideMover, plus upstream's
// "plane extras" (samples/mover.h:16-20): the contact point and the shape that
// produced each plane, which is what lets the node report what it touched.
//
// The arrays grow instead of truncating. Upstream's sample stops at a fixed 8
// (samples/mover.h:24) because it is a demo character in known geometry; a
// binding that silently dropped planes would let a capsule wedged in a corner
// pass through the plane it did not keep, and nothing would say so.
struct MoverContext {
	std::vector<b3CollisionPlane> planes;
	std::vector<b3Vec3> points; // relative to origin, as delivered
	std::vector<b3ShapeId> shapes;
	float push_limit = FLT_MAX;
	bool clip_velocity = true;
};

bool plane_result_cb(b3ShapeId p_shape, const b3PlaneResult *p_results, int p_count, void *p_context) {
	MoverContext *ctx = static_cast<MoverContext *>(p_context);
	for (int i = 0; i < p_count; ++i) {
		b3CollisionPlane cp;
		cp.plane = p_results[i].plane;
		// Upstream reads these per shape, from the shape's own user data
		// (samples/mover.cpp:55-62). This binding has no per-shape mover
		// settings yet, so they come from the character; see the node notes.
		cp.pushLimit = ctx->push_limit;
		cp.push = 0.0f;
		cp.clipVelocity = ctx->clip_velocity;
		ctx->planes.push_back(cp);
		ctx->points.push_back(p_results[i].point);
		ctx->shapes.push_back(p_shape);
	}
	return true;
}

} // namespace

Box3DWorld *Box3DCharacterBody::find_world() const {
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

Vector3 Box3DCharacterBody::move_and_slide(const Vector3 &p_velocity, double p_delta) {
	Vector3 start = get_global_position();
	Vector3 free_move = p_velocity * (real_t)p_delta;

	// Cleared up front so the touch reports never survive a call that found no
	// world (or no planes at all).
	last_planes.clear();
	last_points.clear();
	last_bodies.clear();
	last_solver_iterations = 0;

	Box3DWorld *world = find_world();
	if (world == nullptr) {
		set_global_position(start + free_move);
		return p_velocity;
	}
	// get_world_id() joins any in-flight async step, so the mover queries below
	// never race the solver.
	b3WorldId world_id = world->get_world_id();
	if (!b3World_IsValid(world_id)) {
		set_global_position(start + free_move);
		return p_velocity;
	}

	float r = (float)radius;
	float half = (float)(height * 0.5) - r;
	if (half < 0.0f) {
		half = 0.0f;
	}
	b3Capsule mover;
	mover.center1 = b3Vec3{ 0.0f, -half, 0.0f };
	mover.center2 = b3Vec3{ 0.0f, half, 0.0f };
	mover.radius = r;

	b3QueryFilter filter = b3DefaultQueryFilter();
	filter.maskBits = collision_mask;
	filter.categoryBits = collision_layer;

	// Upstream's split: b3World_CollideMover answers "what am I touching" and
	// b3SolvePlanes turns that into a slide, while b3World_CastMover is what
	// actually carries the capsule there — it sweeps, so a fast mover cannot
	// pass through thin geometry, and the cast is explicitly documented as a
	// bad source of touch information (box3d.h:107-110, :121-122). Solving
	// once at the start pose (what this did before) tunnels.
	//
	// The loop is upstream's character mover verbatim (samples/mover.cpp:185-212):
	// collide at the current pose, solve the planes for the remaining delta,
	// sweep, advance by the swept fraction, and stop early once the step the
	// sweep allowed is negligible. Five passes let the capsule turn a corner
	// (each blocked slide re-collides against whatever it now faces) and bound
	// the cost when it is wedged.
	const int MAX_ITERATIONS = 5;
	const float TOLERANCE = 0.01f; // meters; upstream's value at 1 unit/meter

	b3Pos position = to_b3_pos(start);
	const b3Pos target = to_b3_pos(start + free_move);

	MoverContext ctx;
	ctx.push_limit = push_limit > 0.0 ? (float)push_limit : FLT_MAX;
	ctx.clip_velocity = clip_plane_velocity;
	for (int iteration = 0; iteration < MAX_ITERATIONS; ++iteration) {
		ctx.planes.clear();
		ctx.points.clear();
		ctx.shapes.clear();
		b3World_CollideMover(world_id, position, &mover, filter, plane_result_cb, &ctx);

		// Slides the remaining move along every touching plane and pushes out
		// of any overlap in one solve.
		b3Vec3 target_delta = b3SubPos(target, position);
		b3PlaneSolverResult result = b3SolvePlanes(target_delta, ctx.planes.data(), (int)ctx.planes.size());
		last_solver_iterations = result.iterationCount;

		// Keep the planes this pass solved: the solve is what fills each
		// plane's push, and the last pass is the one that describes where the
		// capsule ended up. Points are delivered relative to the collide
		// origin (samples/mover.cpp:73), so they are offset back to world here.
		last_planes = ctx.planes;
		last_points.clear();
		last_bodies.clear();
		for (size_t i = 0; i < ctx.planes.size(); ++i) {
			last_points.push_back(to_gd_pos(b3OffsetPos(position, ctx.points[i])));
			last_bodies.push_back(world->body_from_shape(ctx.shapes[i]));
		}

		// The sweep clips the slide against anything in the way. No custom
		// filter callback: the mask filter above is the whole contract, and a
		// b3MoverFilterFcn is allowed to be null (test/test_large_world.c:239).
		float fraction = b3World_CastMover(world_id, position, &mover, result.delta, filter, nullptr, nullptr);
		b3Vec3 delta = b3MulSV(fraction, result.delta);
		position = b3OffsetPos(position, delta);

		if (b3LengthSquared(delta) < TOLERANCE * TOLERANCE) {
			break;
		}
	}

	Vector3 end = to_gd_pos(position);
	set_global_position(end);
	// The achieved translation over the frame, which is what a caller feeds
	// back in as velocity next frame.
	return (p_delta > 0.0) ? ((end - start) / (real_t)p_delta) : Vector3();
}

void Box3DCharacterBody::_notification(int p_what) {
	switch (p_what) {
		// The "no Box3DWorld ancestor" warning depends on where this node sits,
		// so it is re-evaluated whenever that can have changed. Reparenting a
		// whole subtree re-enters the tree, which covers ancestors moving too.
		case NOTIFICATION_PARENTED:
		case NOTIFICATION_UNPARENTED:
		case NOTIFICATION_ENTER_TREE: {
			update_configuration_warnings();
		} break;
	}
}

PackedStringArray Box3DCharacterBody::_get_configuration_warnings() const {
	PackedStringArray warnings;
	if (find_world() == nullptr) {
		warnings.push_back(
				"This node has no Box3DWorld ancestor, so there is no simulation to "
				"collide against: move_and_slide() will move it in a straight line "
				"through everything.\nMake it a child (or deeper descendant) of a "
				"Box3DWorld node.");
	}
	// b3Capsule is two centers plus a radius, so a total height below 2 * radius
	// cannot be expressed; move_and_slide() clamps the half-length to 0 and the
	// mover silently becomes a sphere of the given radius.
	if (height < 2.0 * radius) {
		warnings.push_back(
				String("Height ({0}) is less than 2 x Radius ({1}), so the capsule "
					   "collapses to a sphere of radius {1} and the character is "
					   "shorter than it looks.\nRaise Height to at least {2}, or lower "
					   "Radius to at most {3}.")
						.format(Array::make(height, radius, 2.0 * radius, height * 0.5)));
	}
	if (collision_mask == 0) {
		warnings.push_back(
				"Collision Mask is 0, so this character matches no collision layer and "
				"move_and_slide() will pass through every collider.\nEnable at least "
				"one layer.");
	}
	return warnings;
}

void Box3DCharacterBody::set_radius(double p_radius) {
	radius = p_radius;
	update_configuration_warnings();
}

double Box3DCharacterBody::get_radius() const {
	return radius;
}

void Box3DCharacterBody::set_height(double p_height) {
	height = p_height;
	update_configuration_warnings();
}

double Box3DCharacterBody::get_height() const {
	return height;
}

void Box3DCharacterBody::set_collision_mask(int p_mask) {
	collision_mask = (uint32_t)p_mask;
	update_configuration_warnings();
}

int Box3DCharacterBody::get_collision_mask() const {
	return (int)collision_mask;
}

void Box3DCharacterBody::set_collision_layer(int p_layer) {
	collision_layer = (uint32_t)p_layer;
}

int Box3DCharacterBody::get_collision_layer() const {
	return (int)collision_layer;
}

void Box3DCharacterBody::set_up_direction(const Vector3 &p_up) {
	up_direction = p_up.is_zero_approx() ? Vector3(0, 1, 0) : p_up.normalized();
}

Vector3 Box3DCharacterBody::get_up_direction() const {
	return up_direction;
}

void Box3DCharacterBody::set_floor_max_angle(double p_angle) {
	floor_max_angle = p_angle;
}

double Box3DCharacterBody::get_floor_max_angle() const {
	return floor_max_angle;
}

double Box3DCharacterBody::floor_cosine() const {
	return Math::cos(floor_max_angle);
}

bool Box3DCharacterBody::is_on_floor() const {
	return !get_floor_normal().is_zero_approx();
}

bool Box3DCharacterBody::is_on_ceiling() const {
	const double limit = -floor_cosine();
	for (const b3CollisionPlane &plane : last_planes) {
		if (to_gd(plane.plane.normal).dot(up_direction) <= limit) {
			return true;
		}
	}
	return false;
}

bool Box3DCharacterBody::is_on_wall() const {
	const double limit = floor_cosine();
	for (const b3CollisionPlane &plane : last_planes) {
		const double d = to_gd(plane.plane.normal).dot(up_direction);
		if (d < limit && d > -limit) {
			return true;
		}
	}
	return false;
}

Vector3 Box3DCharacterBody::get_floor_normal() const {
	// The planes point outward from the shape the capsule touched, so a floor
	// is the plane whose normal is closest to up.
	const double limit = floor_cosine();
	double best = limit;
	Vector3 normal;
	for (const b3CollisionPlane &plane : last_planes) {
		const Vector3 n = to_gd(plane.plane.normal);
		const double d = n.dot(up_direction);
		if (d >= best) {
			best = d;
			normal = n;
		}
	}
	return normal;
}

Array Box3DCharacterBody::get_last_collisions() const {
	Array out;
	for (size_t i = 0; i < last_planes.size(); ++i) {
		Dictionary entry;
		entry["normal"] = to_gd(last_planes[i].plane.normal);
		entry["position"] = last_points[i];
		// Cast to Object *: a Variant built from a forward-declared pointer
		// silently becomes a bool.
		entry["collider"] = static_cast<Object *>(last_bodies[i]);
		out.push_back(entry);
	}
	return out;
}

void Box3DCharacterBody::set_push_limit(double p_limit) {
	push_limit = p_limit < 0.0 ? 0.0 : p_limit;
}

double Box3DCharacterBody::get_push_limit() const {
	return push_limit;
}

void Box3DCharacterBody::set_clip_plane_velocity(bool p_enabled) {
	clip_plane_velocity = p_enabled;
}

bool Box3DCharacterBody::get_clip_plane_velocity() const {
	return clip_plane_velocity;
}

int Box3DCharacterBody::get_last_solver_iterations() const {
	return last_solver_iterations;
}

Array Box3DCharacterBody::collide_with_body(Box3DBody *p_body) const {
	if (p_body == nullptr || !b3Body_IsValid(p_body->get_body_id())) {
		return Array();
	}
	// b3Body_CollideMover takes the transform to pose the body at, so the
	// "where it is now" form reads it back from the solver.
	p_body->join_world_step();
	const b3WorldTransform xf = b3Body_GetTransform(p_body->get_body_id());
	Transform3D t(Basis(to_gd(xf.q)), to_gd_pos(xf.p));
	return collide_with_body_at(p_body, t);
}

Array Box3DCharacterBody::collide_with_body_at(Box3DBody *p_body, const Transform3D &p_transform) const {
	Array out;
	if (p_body == nullptr) {
		return out;
	}
	Box3DWorld *world = find_world();
	if (world == nullptr) {
		return out;
	}
	// Joins any in-flight async step: the query walks the body's shapes.
	p_body->join_world_step();
	const b3BodyId body_id = p_body->get_body_id();
	if (!b3Body_IsValid(body_id)) {
		return out;
	}

	float r = (float)radius;
	float half = (float)(height * 0.5) - r;
	if (half < 0.0f) {
		half = 0.0f;
	}
	b3Capsule mover;
	mover.center1 = b3Vec3{ 0.0f, -half, 0.0f };
	mover.center2 = b3Vec3{ 0.0f, half, 0.0f };
	mover.radius = r;

	b3QueryFilter filter = b3DefaultQueryFilter();
	filter.maskBits = collision_mask;
	filter.categoryBits = collision_layer;

	b3WorldTransform body_xf;
	body_xf.p = to_b3_pos(p_transform.origin);
	body_xf.q = to_b3(p_transform.basis.get_rotation_quaternion());

	const b3Pos origin = to_b3_pos(get_global_position());

	// The call writes at most planeCapacity results and returns how many it
	// wrote, so a full buffer means there may be more: grow and ask again
	// rather than silently reporting a subset. One shape can present several
	// planes, so the ceiling is generous.
	std::vector<b3BodyPlaneResult> results;
	int capacity = 8;
	int count = 0;
	while (true) {
		results.resize((size_t)capacity);
		count = b3Body_CollideMover(body_id, results.data(), capacity, origin, &mover, filter, body_xf);
		if (count < capacity || capacity >= 256) {
			break;
		}
		capacity *= 2;
	}

	for (int i = 0; i < count; ++i) {
		Dictionary entry;
		entry["normal"] = to_gd(results[i].result.plane.normal);
		entry["distance"] = (double)results[i].result.plane.offset;
		// The point comes back relative to the query origin, as it does from
		// b3World_CollideMover (samples/mover.cpp:73).
		entry["position"] = to_gd_pos(b3OffsetPos(origin, results[i].result.point));
		entry["collider"] = static_cast<Object *>(p_body);
		// Null for a body's own shape_type shape, matching the world's events.
		entry["shape"] = (Object *)b3Shape_GetUserData(results[i].shapeId);
		out.push_back(entry);
	}
	return out;
}

Vector3 Box3DCharacterBody::clip_velocity(const Vector3 &p_velocity) const {
	if (last_planes.empty()) {
		return p_velocity;
	}
	return to_gd(b3ClipVector(to_b3(p_velocity), last_planes.data(), (int)last_planes.size()));
}

void Box3DCharacterBody::_bind_methods() {
	ClassDB::bind_method(D_METHOD("move_and_slide", "velocity", "delta"), &Box3DCharacterBody::move_and_slide);
	ClassDB::bind_method(D_METHOD("set_radius", "radius"), &Box3DCharacterBody::set_radius);
	ClassDB::bind_method(D_METHOD("get_radius"), &Box3DCharacterBody::get_radius);
	ClassDB::bind_method(D_METHOD("set_height", "height"), &Box3DCharacterBody::set_height);
	ClassDB::bind_method(D_METHOD("get_height"), &Box3DCharacterBody::get_height);
	ClassDB::bind_method(D_METHOD("set_collision_mask", "mask"), &Box3DCharacterBody::set_collision_mask);
	ClassDB::bind_method(D_METHOD("get_collision_mask"), &Box3DCharacterBody::get_collision_mask);
	ClassDB::bind_method(D_METHOD("set_collision_layer", "layer"), &Box3DCharacterBody::set_collision_layer);
	ClassDB::bind_method(D_METHOD("get_collision_layer"), &Box3DCharacterBody::get_collision_layer);
	ClassDB::bind_method(D_METHOD("set_up_direction", "up_direction"), &Box3DCharacterBody::set_up_direction);
	ClassDB::bind_method(D_METHOD("get_up_direction"), &Box3DCharacterBody::get_up_direction);
	ClassDB::bind_method(D_METHOD("set_floor_max_angle", "angle"), &Box3DCharacterBody::set_floor_max_angle);
	ClassDB::bind_method(D_METHOD("get_floor_max_angle"), &Box3DCharacterBody::get_floor_max_angle);
	ClassDB::bind_method(D_METHOD("is_on_floor"), &Box3DCharacterBody::is_on_floor);
	ClassDB::bind_method(D_METHOD("is_on_ceiling"), &Box3DCharacterBody::is_on_ceiling);
	ClassDB::bind_method(D_METHOD("is_on_wall"), &Box3DCharacterBody::is_on_wall);
	ClassDB::bind_method(D_METHOD("get_floor_normal"), &Box3DCharacterBody::get_floor_normal);
	ClassDB::bind_method(D_METHOD("get_last_collisions"), &Box3DCharacterBody::get_last_collisions);
	ClassDB::bind_method(D_METHOD("clip_velocity", "velocity"), &Box3DCharacterBody::clip_velocity);
	ClassDB::bind_method(D_METHOD("set_push_limit", "limit"), &Box3DCharacterBody::set_push_limit);
	ClassDB::bind_method(D_METHOD("get_push_limit"), &Box3DCharacterBody::get_push_limit);
	ClassDB::bind_method(D_METHOD("set_clip_plane_velocity", "enabled"), &Box3DCharacterBody::set_clip_plane_velocity);
	ClassDB::bind_method(D_METHOD("get_clip_plane_velocity"), &Box3DCharacterBody::get_clip_plane_velocity);
	ClassDB::bind_method(D_METHOD("get_last_solver_iterations"), &Box3DCharacterBody::get_last_solver_iterations);
	ClassDB::bind_method(D_METHOD("collide_with_body", "body"), &Box3DCharacterBody::collide_with_body);
	ClassDB::bind_method(D_METHOD("collide_with_body_at", "body", "body_transform"), &Box3DCharacterBody::collide_with_body_at);

	// Units are metres: this binding is fixed at one Box3D length unit per
	// metre, so the inspector can state the unit outright.
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "radius", PROPERTY_HINT_RANGE, "0.05,10,0.01,or_greater,suffix:m"), "set_radius", "get_radius");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "height", PROPERTY_HINT_RANGE, "0.1,10,0.01,or_greater,suffix:m"), "set_height", "get_height");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "collision_mask", PROPERTY_HINT_LAYERS_3D_PHYSICS), "set_collision_mask", "get_collision_mask");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "collision_layer", PROPERTY_HINT_LAYERS_3D_PHYSICS), "set_collision_layer", "get_collision_layer");
	// Box3D itself has no up axis; these two only decide how the planes from
	// the last move are classified into floor/wall/ceiling.
	ADD_PROPERTY(PropertyInfo(Variant::VECTOR3, "up_direction"), "set_up_direction", "get_up_direction");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "floor_max_angle", PROPERTY_HINT_RANGE, "0,180,0.1,radians_as_degrees"), "set_floor_max_angle", "get_floor_max_angle");

	// Soft collision. 0 is FLT_MAX, i.e. Box3D's maximally rigid plane and the
	// behaviour every existing scene already has. A finite limit caps the
	// push-out per solve; upstream pairs that with clip_plane_velocity OFF so
	// the mover keeps its speed through the give (types.h:1831-1837).
	ADD_GROUP("Collision Response", "");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "push_limit", PROPERTY_HINT_RANGE, "0,5,0.001,or_greater,suffix:m"), "set_push_limit", "get_push_limit");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "clip_plane_velocity"), "set_clip_plane_velocity", "get_clip_plane_velocity");
}
