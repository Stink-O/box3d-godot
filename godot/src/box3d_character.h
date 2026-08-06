// SPDX-FileCopyrightText: 2026 box3d-godot contributors
// SPDX-License-Identifier: MIT

#pragma once

#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/transform3d.hpp>

#include <box3d/box3d.h>

#include <vector>

namespace godot {

class Box3DBody;
class Box3DWorld;

// A kinematic capsule character controller. Unlike Box3DBody it is not a
// simulated body; it queries the nearest Box3DWorld's mover functions to slide
// a capsule along the world. Drive it with move_and_slide() each frame.
class Box3DCharacterBody : public Node3D {
	GDCLASS(Box3DCharacterBody, Node3D)

	double radius = 0.4;
	double height = 1.8; // total capsule height
	// b3QueryFilter.maskBits: the shape categories this character collides
	// with. Query filtering is two-way (src/shape.h:151-155), so collision_layer
	// below is the other half — what the mover queries ARE, which is how a
	// shape gets to ignore this character while still colliding with bodies.
	// Both are the low 32 categories, matching the inspector's layer widget;
	// Box3DBody's collision_layer_high / collision_mask_high categories are out
	// of reach from here, as they already were for the mask.
	uint32_t collision_mask = 0xFFFFFFFFu;
	// Every category by default, which is b3DefaultQueryFilter's own value
	// (types.h:13-14) truncated to the 32 this node exposes: a character that
	// declares no layer must not become invisible to shapes that narrow theirs.
	uint32_t collision_layer = 0xFFFFFFFFu;
	// Box3D has no up axis of its own, so which planes count as floor is the
	// application's decision (box3d.h:165-166). Defaults match Godot's
	// CharacterBody3D: +Y, 45 degrees.
	Vector3 up_direction = Vector3(0, 1, 0);
	double floor_max_angle = 0.7853981633974483; // radians
	// b3CollisionPlane.pushLimit / .clipVelocity (types.h:1829-1837). FLT_MAX
	// makes a plane as rigid as possible; a finite limit caps how far the plane
	// may push the capsule out in one solve, which is what makes soft collision
	// (pushable crates, springy ceilings) possible. Upstream pairs a soft plane
	// with clipVelocity = false, so the mover keeps its speed through the give.
	// 0 here means FLT_MAX: no inspector spinbox can express it, and it matches
	// the 0-is-unlimited convention Box3DJoint's thresholds already use.
	double push_limit = 0.0;
	bool clip_plane_velocity = true;
	// b3PlaneSolverResult.iterationCount from the last solve, for diagnostics.
	int last_solver_iterations = 0;

	// Collision planes from the last move_and_slide, kept so the node can
	// report what it is touching and clip a velocity against it. b3SolvePlanes
	// fills each plane's push, which is what b3ClipVector reads, so these are
	// stored after the solve rather than straight out of the collide pass.
	std::vector<b3CollisionPlane> last_planes;
	std::vector<Vector3> last_points; // world space, one per plane
	std::vector<Box3DBody *> last_bodies; // one per plane, may be null

	Box3DWorld *find_world() const;
	// Cosine of floor_max_angle, i.e. the dot(normal, up) a plane must reach to
	// count as floor.
	double floor_cosine() const;

protected:
	static void _bind_methods();
	void _notification(int p_what);

public:
	// Editor-only diagnostics. Every case here is one that fails SILENTLY at
	// runtime (the capsule moves with no collision, or degenerates), so the
	// scene dock is the only place a user can find out before shipping.
	PackedStringArray _get_configuration_warnings() const override;

	// Move by velocity*delta, sliding along and stopping at world geometry.
	// Returns the actual resulting velocity (may differ after sliding).
	Vector3 move_and_slide(const Vector3 &p_velocity, double p_delta);

	void set_radius(double p_radius);
	double get_radius() const;
	void set_height(double p_height);
	double get_height() const;
	void set_collision_mask(int p_mask);
	int get_collision_mask() const;
	void set_collision_layer(int p_layer);
	int get_collision_layer() const;
	void set_up_direction(const Vector3 &p_up);
	Vector3 get_up_direction() const;
	void set_floor_max_angle(double p_angle);
	double get_floor_max_angle() const;
	void set_push_limit(double p_limit);
	double get_push_limit() const;
	void set_clip_plane_velocity(bool p_enabled);
	bool get_clip_plane_velocity() const;
	// Iterations b3SolvePlanes used on the last pass of the last move. Purely
	// diagnostic; upstream exposes it for the same reason (types.h:1846-1847).
	int get_last_solver_iterations() const;

	// b3Body_CollideMover (box3d.h:779-780): the planes ONE body would present
	// to this character's capsule at its current position, without moving
	// anything. One Dictionary per plane: { normal, distance, position,
	// collider, shape }. Unlike get_last_collisions() this is a live query, not
	// a report of the last move — it is the "can I stand on that platform if it
	// arrives here" primitive.
	//
	// GOTCHA, and it is upstream's, not this binding's: a mover buried DEEP in
	// a shape reports NOTHING. b3CollideMoverAndHull returns 0 the moment the
	// capsule's core segment intersects the hull, deliberately, so that hulls
	// and meshes behave the same (src/hull.c:2646-2653) — and the same function
	// backs move_and_slide's own collide pass. Touching and shallow overlap
	// report normally; verified against a resting capsule (1 plane) and the
	// same body posed through it (0 planes).
	Array collide_with_body(Box3DBody *p_body) const;
	// The same query with the body posed at p_transform instead of where it is,
	// which is what the upstream signature's bodyTransform argument is for
	// (moving platforms: ask before the platform gets there). Pose it far
	// enough into the capsule and the deep-overlap rule above applies.
	Array collide_with_body_at(Box3DBody *p_body, const Transform3D &p_transform) const;

	// State from the last move_and_slide. All of it comes from the collision
	// planes that call gathered, so it is only as current as the last call.
	bool is_on_floor() const;
	bool is_on_ceiling() const;
	bool is_on_wall() const;
	// Normal of the most upward floor plane, or a zero vector when not on one.
	Vector3 get_floor_normal() const;
	// One entry per plane: { normal, position, collider }.
	Array get_last_collisions() const;
	// Removes the components of p_velocity that push into the planes the last
	// move_and_slide touched (b3ClipVector). This is upstream's alternative to
	// deriving velocity from the achieved translation: it ignores planes that
	// only pushed the capsule out of an overlap, so depenetration does not turn
	// into free speed.
	Vector3 clip_velocity(const Vector3 &p_velocity) const;
};

} // namespace godot
