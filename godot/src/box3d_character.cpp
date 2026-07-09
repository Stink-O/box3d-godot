// SPDX-FileCopyrightText: 2026 box3d-godot contributors
// SPDX-License-Identifier: MIT

#include "box3d_character.h"

#include "box3d_conversions.h"
#include "box3d_world.h"

#include <godot_cpp/core/class_db.hpp>

#include <cfloat>

using namespace godot;

namespace {

// Collects the collision planes from b3World_CollideMover.
struct MoverContext {
	static const int CAPACITY = 32;
	b3CollisionPlane planes[CAPACITY];
	int count = 0;
};

bool plane_result_cb(b3ShapeId, const b3PlaneResult *p_results, int p_count, void *p_context) {
	MoverContext *ctx = static_cast<MoverContext *>(p_context);
	for (int i = 0; i < p_count && ctx->count < MoverContext::CAPACITY; ++i) {
		b3CollisionPlane cp;
		cp.plane = p_results[i].plane;
		cp.pushLimit = FLT_MAX; // rigid
		cp.push = 0.0f;
		cp.clipVelocity = true;
		ctx->planes[ctx->count] = cp;
		ctx->count += 1;
	}
	return true;
}

} // namespace

Box3DWorld *Box3DCharacterBody::find_world() {
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

	Box3DWorld *world = find_world();
	if (world == nullptr) {
		set_global_position(start + free_move);
		return p_velocity;
	}
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

	b3Pos origin = to_b3_pos(start);
	MoverContext ctx;
	b3World_CollideMover(world_id, origin, &mover, filter, plane_result_cb, &ctx);

	Vector3 solved;
	if (ctx.count == 0) {
		solved = free_move;
	} else {
		// Slides the desired move along every touching plane and pushes out of
		// any overlap in one solve.
		b3PlaneSolverResult result = b3SolvePlanes(to_b3(free_move), ctx.planes, ctx.count);
		solved = to_gd(result.delta);
	}

	set_global_position(start + solved);
	return (p_delta > 0.0) ? (solved / (real_t)p_delta) : Vector3();
}

void Box3DCharacterBody::set_radius(double p_radius) {
	radius = p_radius;
}

double Box3DCharacterBody::get_radius() const {
	return radius;
}

void Box3DCharacterBody::set_height(double p_height) {
	height = p_height;
}

double Box3DCharacterBody::get_height() const {
	return height;
}

void Box3DCharacterBody::set_collision_mask(int p_mask) {
	collision_mask = (uint32_t)p_mask;
}

int Box3DCharacterBody::get_collision_mask() const {
	return (int)collision_mask;
}

void Box3DCharacterBody::_bind_methods() {
	ClassDB::bind_method(D_METHOD("move_and_slide", "velocity", "delta"), &Box3DCharacterBody::move_and_slide);
	ClassDB::bind_method(D_METHOD("set_radius", "radius"), &Box3DCharacterBody::set_radius);
	ClassDB::bind_method(D_METHOD("get_radius"), &Box3DCharacterBody::get_radius);
	ClassDB::bind_method(D_METHOD("set_height", "height"), &Box3DCharacterBody::set_height);
	ClassDB::bind_method(D_METHOD("get_height"), &Box3DCharacterBody::get_height);
	ClassDB::bind_method(D_METHOD("set_collision_mask", "mask"), &Box3DCharacterBody::set_collision_mask);
	ClassDB::bind_method(D_METHOD("get_collision_mask"), &Box3DCharacterBody::get_collision_mask);

	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "radius", PROPERTY_HINT_RANGE, "0.05,10,0.01,or_greater"), "set_radius", "get_radius");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "height", PROPERTY_HINT_RANGE, "0.1,10,0.01,or_greater"), "set_height", "get_height");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "collision_mask", PROPERTY_HINT_LAYERS_3D_PHYSICS), "set_collision_mask", "get_collision_mask");
}
