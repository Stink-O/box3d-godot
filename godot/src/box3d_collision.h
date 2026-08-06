// SPDX-FileCopyrightText: 2026 box3d-godot contributors
// SPDX-License-Identifier: MIT

#pragma once

#include <godot_cpp/classes/object.hpp>
#include <godot_cpp/core/binder_common.hpp>
#include <godot_cpp/variant/aabb.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <box3d/box3d.h>

namespace godot {

// Upstream's standalone geometry queries (collision.h:472-648): ray casts,
// shape casts, overlaps, distance, time of impact, mass properties and the
// b3Collide* manifold builders, all of which run on raw geometry OUTSIDE any
// world.
//
// Every call is STATIC and needs no world, because none of these functions
// takes a b3WorldId — they neither read nor lock a world, so they are safe
// while a world is stepping. That is also what they are for: predicting a
// collision that has not happened, or answering a question about geometry that
// was never added to a scene (tools, spawn checks, AI). For "what is in the
// scene right now", use Box3DWorld's queries instead.
//
// Two conventions run through the whole class:
//
//  * A PRIMITIVE is spelled out in arguments, exactly as upstream spells it:
//    a sphere is a center and a radius (types.h:1898-1910), a capsule is its
//    two end centers and a radius (types.h:1917-1930), a hull is a point cloud
//    that gets hulled. Hull-taking calls build a b3HullData for the call and
//    destroy it before returning, so nothing is left for a script to leak.
//  * A PROXY is the generic query shape: a point cloud plus a radius
//    (b3ShapeProxy, types.h:1370-1384). One point with a radius is a sphere,
//    two are a capsule, eight with radius 0 are a box, and any cloud is its
//    own convex hull. At most B3_MAX_SHAPE_CAST_POINTS (128) points.
//
// Everything is in ONE frame: shape A's. Upstream is explicit that the pair
// queries run in frame A and return their points and normals there
// (collision.h:589-592, :595-597), so `transform_b` is B's pose relative to A,
// and a result has to be moved into world space by the caller.
class Box3DCollision : public Object {
	GDCLASS(Box3DCollision, Object)

protected:
	static void _bind_methods();

public:
	// --- rays, in the shape's own frame ------------------------------------
	// Each returns { hit, position, normal, fraction, iterations }. A zero
	// length ray is a point query, and for the solid primitives an origin
	// inside the shape reports a hit at the origin with zero fraction and a
	// zero normal (collision.h:527-529).

	// b3IsValidRay (collision.h:475): upstream's own input check. Everything
	// below runs it first, so a bad ray is a clean miss instead of an assert.
	static bool is_valid_ray(const Vector3 &p_origin, const Vector3 &p_translation, double p_max_fraction = 1.0);
	static Dictionary ray_cast_sphere(const Vector3 &p_center, double p_radius,
			const Vector3 &p_origin, const Vector3 &p_translation, double p_max_fraction = 1.0);
	// b3RayCastHollowSphere (collision.h:531-533): a shell, not a ball, so a ray
	// starting inside passes through and hits the far wall.
	static Dictionary ray_cast_hollow_sphere(const Vector3 &p_center, double p_radius,
			const Vector3 &p_origin, const Vector3 &p_translation, double p_max_fraction = 1.0);
	static Dictionary ray_cast_capsule(const Vector3 &p_center1, const Vector3 &p_center2, double p_radius,
			const Vector3 &p_origin, const Vector3 &p_translation, double p_max_fraction = 1.0);
	static Dictionary ray_cast_hull(const PackedVector3Array &p_points,
			const Vector3 &p_origin, const Vector3 &p_translation, double p_max_fraction = 1.0);

	// --- shape casts: a proxy swept at a fixed primitive --------------------
	// Same result Dictionary. Initial overlap is a MISS for all three
	// (collision.h:550-566), which is the opposite of the ray behaviour above.
	// can_encroach lets a proxy with a radius move slightly closer when it is
	// already touching (types.h:1400-1401).
	static Dictionary shape_cast_sphere(const Vector3 &p_center, double p_radius,
			const PackedVector3Array &p_proxy_points, double p_proxy_radius, const Vector3 &p_translation,
			double p_max_fraction = 1.0, bool p_can_encroach = false);
	static Dictionary shape_cast_capsule(const Vector3 &p_center1, const Vector3 &p_center2, double p_radius,
			const PackedVector3Array &p_proxy_points, double p_proxy_radius, const Vector3 &p_translation,
			double p_max_fraction = 1.0, bool p_can_encroach = false);
	static Dictionary shape_cast_hull(const PackedVector3Array &p_points,
			const PackedVector3Array &p_proxy_points, double p_proxy_radius, const Vector3 &p_translation,
			double p_max_fraction = 1.0, bool p_can_encroach = false);

	// --- overlaps: a proxy against a posed primitive ------------------------
	// b3Overlap* (collision.h:478-495). The transform poses the PRIMITIVE; the
	// proxy is already where it is.
	static bool overlap_sphere(const Vector3 &p_center, double p_radius, const Transform3D &p_transform,
			const PackedVector3Array &p_proxy_points, double p_proxy_radius);
	static bool overlap_capsule(const Vector3 &p_center1, const Vector3 &p_center2, double p_radius,
			const Transform3D &p_transform, const PackedVector3Array &p_proxy_points, double p_proxy_radius);
	static bool overlap_hull(const PackedVector3Array &p_points, const Transform3D &p_transform,
			const PackedVector3Array &p_proxy_points, double p_proxy_radius);

	// --- the generic pair queries ------------------------------------------
	// b3ShapeDistance (collision.h:585-592): closest points between two convex
	// proxies, in A's frame. Returns
	// { point_a, point_b, normal, distance, iterations }; `normal` is invalid
	// when the distance is zero, which is upstream's overlap signal. The
	// b3SimplexCache upstream warm-starts with is zeroed per call here, which is
	// what it says to do when the poses are unrelated (types.h:1506-1513).
	static Dictionary shape_distance(const PackedVector3Array &p_points_a, double p_radius_a,
			const PackedVector3Array &p_points_b, double p_radius_b,
			const Transform3D &p_transform_b, bool p_use_radii = true);
	// b3ShapeCast (collision.h:594-597): B swept against a fixed A, in A's
	// frame. Initially touching is a miss.
	static Dictionary shape_cast(const PackedVector3Array &p_points_a, double p_radius_a,
			const PackedVector3Array &p_points_b, double p_radius_b,
			const Transform3D &p_transform_b, const Vector3 &p_translation_b,
			double p_max_fraction = 1.0, bool p_can_encroach = false);
	// b3TimeOfImpact (collision.h:602-607): the first time in [0, max_fraction]
	// at which two SWEEPING proxies touch. Each sweep is given as the shape
	// frame's start and end pose, and the proxy points are in that frame.
	// Returns { state, state_name, fraction, distance, point, normal,
	// distance_iterations, push_back_iterations, root_iterations }, with `state`
	// one of the TOIState values below. Upstream warns it uses a swept
	// separating axis and can miss intermediate non-tunnelling collisions.
	static Dictionary time_of_impact(const PackedVector3Array &p_points_a, double p_radius_a,
			const Transform3D &p_from_a, const Transform3D &p_to_a,
			const PackedVector3Array &p_points_b, double p_radius_b,
			const Transform3D &p_from_b, const Transform3D &p_to_b,
			double p_max_fraction = 1.0);
	// b3GetSweepTransform (collision.h:599-600): the pose at a fraction of a
	// sweep, i.e. where time_of_impact's fraction actually puts the shape.
	static Transform3D get_sweep_transform(const Transform3D &p_from, const Transform3D &p_to, double p_time);

	// Mirrors b3TOIState (types.h:1614-1622).
	enum TOIState {
		TOI_UNKNOWN,
		TOI_FAILED,
		TOI_OVERLAPPED,
		TOI_HIT,
		TOI_SEPARATED,
	};

	// --- mass properties and bounds ----------------------------------------
	// b3Compute*Mass (collision.h:472-483) and b3Compute*AABB (collision.h:485-
	// 495). Mass returns { mass, center, inertia }, the same three keys
	// Box3DBody.get_mass_data() uses, so a computed tensor can be handed
	// straight to Box3DBody.set_mass_data().
	static Dictionary compute_sphere_mass(const Vector3 &p_center, double p_radius, double p_density);
	static Dictionary compute_capsule_mass(const Vector3 &p_center1, const Vector3 &p_center2, double p_radius,
			double p_density);
	static Dictionary compute_hull_mass(const PackedVector3Array &p_points, double p_density);
	static AABB compute_sphere_aabb(const Vector3 &p_center, double p_radius, const Transform3D &p_transform);
	static AABB compute_capsule_aabb(const Vector3 &p_center1, const Vector3 &p_center2, double p_radius,
			const Transform3D &p_transform);
	static AABB compute_hull_aabb(const PackedVector3Array &p_points, const Transform3D &p_transform);

	// --- manifolds ----------------------------------------------------------
	// The b3Collide* family (collision.h:615-645): the narrow phase itself, run
	// on two shapes that are in no world. This is what a contact would look like
	// if these two shapes met at these poses, which is the question a spawn
	// check or a level tool asks.
	//
	// Every one returns { normal, points }, with `normal` in frame A and one
	// entry per manifold point: { point, separation, triangle_index }. Points
	// and normal are LOCAL to A, not world space. An empty `points` array means
	// the shapes are apart.
	//
	// transform_b is B's pose in A's frame throughout. Upstream's cache
	// arguments (b3SimplexCache, b3SATCache) are warm-start scratch and are
	// zeroed per call here rather than exposed: they are solver-internal, they
	// only pay off across repeated calls with nearby poses, and a wrong one is
	// a wrong answer.
	static Dictionary collide_spheres(const Vector3 &p_center_a, double p_radius_a,
			const Vector3 &p_center_b, double p_radius_b, const Transform3D &p_transform_b);
	static Dictionary collide_capsule_and_sphere(const Vector3 &p_center_a1, const Vector3 &p_center_a2,
			double p_radius_a, const Vector3 &p_center_b, double p_radius_b, const Transform3D &p_transform_b);
	static Dictionary collide_hull_and_sphere(const PackedVector3Array &p_points_a,
			const Vector3 &p_center_b, double p_radius_b, const Transform3D &p_transform_b);
	static Dictionary collide_capsules(const Vector3 &p_center_a1, const Vector3 &p_center_a2, double p_radius_a,
			const Vector3 &p_center_b1, const Vector3 &p_center_b2, double p_radius_b,
			const Transform3D &p_transform_b);
	static Dictionary collide_hull_and_capsule(const PackedVector3Array &p_points_a,
			const Vector3 &p_center_b1, const Vector3 &p_center_b2, double p_radius_b,
			const Transform3D &p_transform_b);
	static Dictionary collide_hulls(const PackedVector3Array &p_points_a, const PackedVector3Array &p_points_b,
			const Transform3D &p_transform_b);
	// The triangle forms take the triangle as shape A and point their normal
	// FROM the triangle TO the other shape (collision.h:637-645). The triangle
	// is already in A's frame, so it takes no transform of its own, and the
	// other shape is posed into that frame by transform_b.
	//
	// A triangle is SINGLE SIDED. Wind it so its face normal
	// ((b - a) x (c - a)) points at the shape you are testing, or the call
	// reports nothing at all -- which is a correct answer, not a failure, and
	// is the same rule a mesh collider follows.
	static Dictionary collide_triangle_and_sphere(const PackedVector3Array &p_triangle,
			const Vector3 &p_center_b, double p_radius_b, const Transform3D &p_transform_b);
	static Dictionary collide_triangle_and_capsule(const PackedVector3Array &p_triangle,
			const Vector3 &p_center_b1, const Vector3 &p_center_b2, double p_radius_b,
			const Transform3D &p_transform_b);
	// triangle_flags is a b3MeshEdgeFlags mask (types.h:2104-2122) marking which
	// of the triangle's edges are concave; 0 treats every edge as convex, which
	// is right for a lone triangle. enable_speculative keeps points that are
	// close but not touching, as the solver does.
	static Dictionary collide_triangle_and_hull(const PackedVector3Array &p_triangle,
			const PackedVector3Array &p_points_b, const Transform3D &p_transform_b,
			int p_triangle_flags = 0, bool p_enable_speculative = true);
};

} // namespace godot

VARIANT_ENUM_CAST(godot::Box3DCollision::TOIState);
