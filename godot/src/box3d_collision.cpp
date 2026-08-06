// SPDX-FileCopyrightText: 2026 box3d-godot contributors
// SPDX-License-Identifier: MIT

#include "box3d_collision.h"

#include "box3d_conversions.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/basis.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <vector>

using namespace godot;

namespace {

// A proxy owns its points for the length of one call; b3ShapeProxy only borrows
// them (types.h:1370-1379).
struct Proxy {
	std::vector<b3Vec3> points;
	float radius = 0.0f;

	b3ShapeProxy get() const {
		b3ShapeProxy p;
		p.points = points.data();
		p.count = (int)points.size();
		p.radius = radius;
		return p;
	}
	bool empty() const { return points.empty(); }
};

Proxy make_proxy(const PackedVector3Array &p_points, double p_radius) {
	Proxy out;
	int count = p_points.size();
	if (count > B3_MAX_SHAPE_CAST_POINTS) {
		UtilityFunctions::push_warning(
				"Box3DCollision: a proxy takes at most " + itos(B3_MAX_SHAPE_CAST_POINTS) +
				" points (B3_MAX_SHAPE_CAST_POINTS); the rest are ignored.");
		count = B3_MAX_SHAPE_CAST_POINTS;
	}
	out.points.reserve((size_t)count);
	for (int i = 0; i < count; ++i) {
		out.points.push_back(to_b3(p_points[i]));
	}
	out.radius = (float)Math::abs(p_radius);
	return out;
}

b3Sphere make_sphere(const Vector3 &p_center, double p_radius) {
	b3Sphere s;
	s.center = to_b3(p_center);
	s.radius = (float)Math::abs(p_radius);
	return s;
}

b3Capsule make_capsule(const Vector3 &p_c1, const Vector3 &p_c2, double p_radius) {
	b3Capsule c;
	c.center1 = to_b3(p_c1);
	c.center2 = to_b3(p_c2);
	c.radius = (float)Math::abs(p_radius);
	return c;
}

// Every hull-taking call builds one for the duration and destroys it before
// returning (collision.h:225, :232-234). Null when the cloud is degenerate.
b3HullData *make_hull(const PackedVector3Array &p_points) {
	const int count = p_points.size();
	if (count < 4) {
		UtilityFunctions::push_warning("Box3DCollision: a hull needs at least 4 points.");
		return nullptr;
	}
	std::vector<b3Vec3> points((size_t)count);
	for (int i = 0; i < count; ++i) {
		points[(size_t)i] = to_b3(p_points[i]);
	}
	const int max_verts = count < B3_MAX_HULL_VERTICES ? count : B3_MAX_HULL_VERTICES;
	return b3CreateHull(points.data(), count, max_verts);
}

Dictionary cast_output_to_dict(const b3CastOutput &p_out) {
	Dictionary d;
	d["hit"] = p_out.hit;
	d["position"] = to_gd(p_out.point);
	d["normal"] = to_gd(p_out.normal);
	d["fraction"] = (double)p_out.fraction;
	d["iterations"] = p_out.iterations;
	return d;
}

Dictionary miss() {
	b3CastOutput out = {};
	out.hit = false;
	return cast_output_to_dict(out);
}

// b3IsValidRay is the documented way to keep a bad ray out of the internals
// (collision.h:474-475), so every ray entry point runs it before casting.
bool fill_ray(b3RayCastInput &r_input, const Vector3 &p_origin, const Vector3 &p_translation, double p_max_fraction) {
	r_input.origin = to_b3(p_origin);
	r_input.translation = to_b3(p_translation);
	r_input.maxFraction = (float)p_max_fraction;
	if (!b3IsValidRay(&r_input)) {
		UtilityFunctions::push_warning("Box3DCollision: invalid ray (b3IsValidRay); reporting a miss.");
		return false;
	}
	return true;
}

b3ShapeCastInput make_cast_input(const Proxy &p_proxy, const Vector3 &p_translation, double p_max_fraction,
		bool p_can_encroach) {
	b3ShapeCastInput input = {};
	input.proxy = p_proxy.get();
	input.translation = to_b3(p_translation);
	input.maxFraction = (float)p_max_fraction;
	input.canEncroach = p_can_encroach;
	return input;
}

Basis to_gd_basis(const b3Matrix3 &m) {
	// b3Matrix3 is column-major (cx, cy, cz) and Godot's Basis(x, y, z) takes
	// columns too, so an inertia tensor maps across 1:1.
	return Basis(to_gd(m.cx), to_gd(m.cy), to_gd(m.cz));
}

Dictionary mass_to_dict(const b3MassData &p_data) {
	Dictionary d;
	d["mass"] = (double)p_data.mass;
	d["center"] = to_gd(p_data.center);
	d["inertia"] = to_gd_basis(p_data.inertia);
	return d;
}

AABB aabb_to_gd(const b3AABB &p_aabb) {
	const Vector3 lower = to_gd(p_aabb.lowerBound);
	const Vector3 upper = to_gd(p_aabb.upperBound);
	return AABB(lower, upper - lower);
}

// b3Sweep interpolates the CENTER OF MASS (types.h:1594-1602). The proxies here
// are given in the shape frame, so the local center is zero and the sweep is
// the frame's own start and end pose, which is what b3GetSweepTransform then
// hands back.
b3Sweep make_sweep(const Transform3D &p_from, const Transform3D &p_to) {
	b3Sweep sweep;
	sweep.localCenter = b3Vec3_zero;
	sweep.c1 = to_b3(p_from.origin);
	sweep.c2 = to_b3(p_to.origin);
	sweep.q1 = to_b3(p_from.basis.get_rotation_quaternion());
	sweep.q2 = to_b3(p_to.basis.get_rotation_quaternion());
	return sweep;
}

// The b3Collide* family writes into a caller-supplied point buffer and reports
// how many it used (src/contact.c:481-486 is upstream's own call shape). 32 is
// the capacity the solver itself passes.
const int MANIFOLD_CAPACITY = 32;

Dictionary manifold_to_dict(const b3LocalManifold &p_manifold) {
	Dictionary d;
	Array points;
	for (int i = 0; i < p_manifold.pointCount; ++i) {
		const b3LocalManifoldPoint &mp = p_manifold.points[i];
		Dictionary point;
		point["point"] = to_gd(mp.point);
		point["separation"] = (double)mp.separation;
		point["triangle_index"] = mp.triangleIndex;
		points.push_back(point);
	}
	d["normal"] = to_gd(p_manifold.normal);
	d["points"] = points;
	return d;
}

// One place that owns the scratch buffer, so no caller can forget it.
struct ManifoldScratch {
	b3LocalManifoldPoint buffer[MANIFOLD_CAPACITY];
	b3LocalManifold manifold = {};

	ManifoldScratch() {
		manifold.points = buffer;
	}
	Dictionary result() const { return manifold_to_dict(manifold); }
};

Dictionary empty_manifold() {
	Dictionary d;
	d["normal"] = Vector3();
	d["points"] = Array();
	return d;
}

bool triangle_points(const PackedVector3Array &p_triangle, b3Vec3 r_out[3]) {
	if (p_triangle.size() < 3) {
		UtilityFunctions::push_warning("Box3DCollision: a triangle needs 3 points.");
		return false;
	}
	for (int i = 0; i < 3; ++i) {
		r_out[i] = to_b3(p_triangle[i]);
	}
	return true;
}

} // namespace

bool Box3DCollision::is_valid_ray(const Vector3 &p_origin, const Vector3 &p_translation, double p_max_fraction) {
	b3RayCastInput input;
	input.origin = to_b3(p_origin);
	input.translation = to_b3(p_translation);
	input.maxFraction = (float)p_max_fraction;
	return b3IsValidRay(&input);
}

Dictionary Box3DCollision::ray_cast_sphere(const Vector3 &p_center, double p_radius,
		const Vector3 &p_origin, const Vector3 &p_translation, double p_max_fraction) {
	b3RayCastInput input;
	if (!fill_ray(input, p_origin, p_translation, p_max_fraction)) {
		return miss();
	}
	const b3Sphere sphere = make_sphere(p_center, p_radius);
	return cast_output_to_dict(b3RayCastSphere(&sphere, &input));
}

Dictionary Box3DCollision::ray_cast_hollow_sphere(const Vector3 &p_center, double p_radius,
		const Vector3 &p_origin, const Vector3 &p_translation, double p_max_fraction) {
	b3RayCastInput input;
	if (!fill_ray(input, p_origin, p_translation, p_max_fraction)) {
		return miss();
	}
	const b3Sphere sphere = make_sphere(p_center, p_radius);
	return cast_output_to_dict(b3RayCastHollowSphere(&sphere, &input));
}

Dictionary Box3DCollision::ray_cast_capsule(const Vector3 &p_center1, const Vector3 &p_center2, double p_radius,
		const Vector3 &p_origin, const Vector3 &p_translation, double p_max_fraction) {
	b3RayCastInput input;
	if (!fill_ray(input, p_origin, p_translation, p_max_fraction)) {
		return miss();
	}
	const b3Capsule capsule = make_capsule(p_center1, p_center2, p_radius);
	return cast_output_to_dict(b3RayCastCapsule(&capsule, &input));
}

Dictionary Box3DCollision::ray_cast_hull(const PackedVector3Array &p_points,
		const Vector3 &p_origin, const Vector3 &p_translation, double p_max_fraction) {
	b3RayCastInput input;
	if (!fill_ray(input, p_origin, p_translation, p_max_fraction)) {
		return miss();
	}
	b3HullData *hull = make_hull(p_points);
	if (hull == nullptr) {
		return miss();
	}
	const Dictionary out = cast_output_to_dict(b3RayCastHull(hull, &input));
	b3DestroyHull(hull);
	return out;
}

Dictionary Box3DCollision::shape_cast_sphere(const Vector3 &p_center, double p_radius,
		const PackedVector3Array &p_proxy_points, double p_proxy_radius, const Vector3 &p_translation,
		double p_max_fraction, bool p_can_encroach) {
	const Proxy proxy = make_proxy(p_proxy_points, p_proxy_radius);
	if (proxy.empty()) {
		return miss();
	}
	const b3ShapeCastInput input = make_cast_input(proxy, p_translation, p_max_fraction, p_can_encroach);
	const b3Sphere sphere = make_sphere(p_center, p_radius);
	return cast_output_to_dict(b3ShapeCastSphere(&sphere, &input));
}

Dictionary Box3DCollision::shape_cast_capsule(const Vector3 &p_center1, const Vector3 &p_center2, double p_radius,
		const PackedVector3Array &p_proxy_points, double p_proxy_radius, const Vector3 &p_translation,
		double p_max_fraction, bool p_can_encroach) {
	const Proxy proxy = make_proxy(p_proxy_points, p_proxy_radius);
	if (proxy.empty()) {
		return miss();
	}
	const b3ShapeCastInput input = make_cast_input(proxy, p_translation, p_max_fraction, p_can_encroach);
	const b3Capsule capsule = make_capsule(p_center1, p_center2, p_radius);
	return cast_output_to_dict(b3ShapeCastCapsule(&capsule, &input));
}

Dictionary Box3DCollision::shape_cast_hull(const PackedVector3Array &p_points,
		const PackedVector3Array &p_proxy_points, double p_proxy_radius, const Vector3 &p_translation,
		double p_max_fraction, bool p_can_encroach) {
	const Proxy proxy = make_proxy(p_proxy_points, p_proxy_radius);
	if (proxy.empty()) {
		return miss();
	}
	b3HullData *hull = make_hull(p_points);
	if (hull == nullptr) {
		return miss();
	}
	const b3ShapeCastInput input = make_cast_input(proxy, p_translation, p_max_fraction, p_can_encroach);
	const Dictionary out = cast_output_to_dict(b3ShapeCastHull(hull, &input));
	b3DestroyHull(hull);
	return out;
}

bool Box3DCollision::overlap_sphere(const Vector3 &p_center, double p_radius, const Transform3D &p_transform,
		const PackedVector3Array &p_proxy_points, double p_proxy_radius) {
	const Proxy proxy = make_proxy(p_proxy_points, p_proxy_radius);
	if (proxy.empty()) {
		return false;
	}
	const b3Sphere sphere = make_sphere(p_center, p_radius);
	const b3ShapeProxy sp = proxy.get();
	return b3OverlapSphere(&sphere, to_b3_transform(p_transform), &sp);
}

bool Box3DCollision::overlap_capsule(const Vector3 &p_center1, const Vector3 &p_center2, double p_radius,
		const Transform3D &p_transform, const PackedVector3Array &p_proxy_points, double p_proxy_radius) {
	const Proxy proxy = make_proxy(p_proxy_points, p_proxy_radius);
	if (proxy.empty()) {
		return false;
	}
	const b3Capsule capsule = make_capsule(p_center1, p_center2, p_radius);
	const b3ShapeProxy sp = proxy.get();
	return b3OverlapCapsule(&capsule, to_b3_transform(p_transform), &sp);
}

bool Box3DCollision::overlap_hull(const PackedVector3Array &p_points, const Transform3D &p_transform,
		const PackedVector3Array &p_proxy_points, double p_proxy_radius) {
	const Proxy proxy = make_proxy(p_proxy_points, p_proxy_radius);
	if (proxy.empty()) {
		return false;
	}
	b3HullData *hull = make_hull(p_points);
	if (hull == nullptr) {
		return false;
	}
	const b3ShapeProxy sp = proxy.get();
	const bool hit = b3OverlapHull(hull, to_b3_transform(p_transform), &sp);
	b3DestroyHull(hull);
	return hit;
}

Dictionary Box3DCollision::shape_distance(const PackedVector3Array &p_points_a, double p_radius_a,
		const PackedVector3Array &p_points_b, double p_radius_b,
		const Transform3D &p_transform_b, bool p_use_radii) {
	Dictionary out;
	const Proxy a = make_proxy(p_points_a, p_radius_a);
	const Proxy b = make_proxy(p_points_b, p_radius_b);
	if (a.empty() || b.empty()) {
		out["point_a"] = Vector3();
		out["point_b"] = Vector3();
		out["normal"] = Vector3();
		out["distance"] = 0.0;
		out["iterations"] = 0;
		return out;
	}
	b3DistanceInput input = {};
	input.proxyA = a.get();
	input.proxyB = b.get();
	input.transform = to_b3_transform(p_transform_b);
	input.useRadii = p_use_radii;
	// Zeroed per call: the cache only warm-starts repeated queries with nearby
	// transforms, and upstream says to zero it otherwise (types.h:1506-1513).
	b3SimplexCache cache = {};
	const b3DistanceOutput result = b3ShapeDistance(&input, &cache, nullptr, 0);
	out["point_a"] = to_gd(result.pointA);
	out["point_b"] = to_gd(result.pointB);
	out["normal"] = to_gd(result.normal);
	out["distance"] = (double)result.distance;
	out["iterations"] = result.iterations;
	return out;
}

Dictionary Box3DCollision::shape_cast(const PackedVector3Array &p_points_a, double p_radius_a,
		const PackedVector3Array &p_points_b, double p_radius_b,
		const Transform3D &p_transform_b, const Vector3 &p_translation_b,
		double p_max_fraction, bool p_can_encroach) {
	const Proxy a = make_proxy(p_points_a, p_radius_a);
	const Proxy b = make_proxy(p_points_b, p_radius_b);
	if (a.empty() || b.empty()) {
		return miss();
	}
	b3ShapeCastPairInput input = {};
	input.proxyA = a.get();
	input.proxyB = b.get();
	input.transform = to_b3_transform(p_transform_b);
	input.translationB = to_b3(p_translation_b);
	input.maxFraction = (float)p_max_fraction;
	input.canEncroach = p_can_encroach;
	return cast_output_to_dict(b3ShapeCast(&input));
}

Dictionary Box3DCollision::time_of_impact(const PackedVector3Array &p_points_a, double p_radius_a,
		const Transform3D &p_from_a, const Transform3D &p_to_a,
		const PackedVector3Array &p_points_b, double p_radius_b,
		const Transform3D &p_from_b, const Transform3D &p_to_b,
		double p_max_fraction) {
	Dictionary out;
	const Proxy a = make_proxy(p_points_a, p_radius_a);
	const Proxy b = make_proxy(p_points_b, p_radius_b);
	if (a.empty() || b.empty()) {
		out["state"] = TOI_UNKNOWN;
		out["state_name"] = "unknown";
		out["fraction"] = 0.0;
		out["distance"] = 0.0;
		out["point"] = Vector3();
		out["normal"] = Vector3();
		return out;
	}
	b3TOIInput input = {};
	input.proxyA = a.get();
	input.proxyB = b.get();
	input.sweepA = make_sweep(p_from_a, p_to_a);
	input.sweepB = make_sweep(p_from_b, p_to_b);
	input.maxFraction = (float)p_max_fraction;
	const b3TOIOutput result = b3TimeOfImpact(&input);
	out["state"] = (int)result.state;
	const char *names[] = { "unknown", "failed", "overlapped", "hit", "separated" };
	out["state_name"] = String(result.state >= 0 && result.state <= b3_toiStateSeparated ? names[result.state] : "unknown");
	out["fraction"] = (double)result.fraction;
	out["distance"] = (double)result.distance;
	out["point"] = to_gd(result.point);
	out["normal"] = to_gd(result.normal);
	out["distance_iterations"] = result.distanceIterations;
	out["push_back_iterations"] = result.pushBackIterations;
	out["root_iterations"] = result.rootIterations;
	return out;
}

Transform3D Box3DCollision::get_sweep_transform(const Transform3D &p_from, const Transform3D &p_to, double p_time) {
	const b3Sweep sweep = make_sweep(p_from, p_to);
	const b3Transform xf = b3GetSweepTransform(&sweep, (float)p_time);
	Transform3D out;
	out.basis = Basis(to_gd(xf.q));
	out.origin = to_gd(xf.p);
	return out;
}

Dictionary Box3DCollision::compute_sphere_mass(const Vector3 &p_center, double p_radius, double p_density) {
	const b3Sphere sphere = make_sphere(p_center, p_radius);
	return mass_to_dict(b3ComputeSphereMass(&sphere, (float)p_density));
}

Dictionary Box3DCollision::compute_capsule_mass(const Vector3 &p_center1, const Vector3 &p_center2, double p_radius,
		double p_density) {
	const b3Capsule capsule = make_capsule(p_center1, p_center2, p_radius);
	return mass_to_dict(b3ComputeCapsuleMass(&capsule, (float)p_density));
}

Dictionary Box3DCollision::compute_hull_mass(const PackedVector3Array &p_points, double p_density) {
	b3HullData *hull = make_hull(p_points);
	if (hull == nullptr) {
		b3MassData empty = {};
		return mass_to_dict(empty);
	}
	const b3MassData data = b3ComputeHullMass(hull, (float)p_density);
	b3DestroyHull(hull);
	return mass_to_dict(data);
}

AABB Box3DCollision::compute_sphere_aabb(const Vector3 &p_center, double p_radius, const Transform3D &p_transform) {
	const b3Sphere sphere = make_sphere(p_center, p_radius);
	return aabb_to_gd(b3ComputeSphereAABB(&sphere, to_b3_transform(p_transform)));
}

AABB Box3DCollision::compute_capsule_aabb(const Vector3 &p_center1, const Vector3 &p_center2, double p_radius,
		const Transform3D &p_transform) {
	const b3Capsule capsule = make_capsule(p_center1, p_center2, p_radius);
	return aabb_to_gd(b3ComputeCapsuleAABB(&capsule, to_b3_transform(p_transform)));
}

AABB Box3DCollision::compute_hull_aabb(const PackedVector3Array &p_points, const Transform3D &p_transform) {
	b3HullData *hull = make_hull(p_points);
	if (hull == nullptr) {
		return AABB();
	}
	const AABB out = aabb_to_gd(b3ComputeHullAABB(hull, to_b3_transform(p_transform)));
	b3DestroyHull(hull);
	return out;
}

Dictionary Box3DCollision::collide_spheres(const Vector3 &p_center_a, double p_radius_a,
		const Vector3 &p_center_b, double p_radius_b, const Transform3D &p_transform_b) {
	ManifoldScratch scratch;
	const b3Sphere a = make_sphere(p_center_a, p_radius_a);
	const b3Sphere b = make_sphere(p_center_b, p_radius_b);
	b3CollideSpheres(&scratch.manifold, MANIFOLD_CAPACITY, &a, &b, to_b3_transform(p_transform_b));
	return scratch.result();
}

Dictionary Box3DCollision::collide_capsule_and_sphere(const Vector3 &p_center_a1, const Vector3 &p_center_a2,
		double p_radius_a, const Vector3 &p_center_b, double p_radius_b, const Transform3D &p_transform_b) {
	ManifoldScratch scratch;
	const b3Capsule a = make_capsule(p_center_a1, p_center_a2, p_radius_a);
	const b3Sphere b = make_sphere(p_center_b, p_radius_b);
	b3CollideCapsuleAndSphere(&scratch.manifold, MANIFOLD_CAPACITY, &a, &b, to_b3_transform(p_transform_b));
	return scratch.result();
}

Dictionary Box3DCollision::collide_hull_and_sphere(const PackedVector3Array &p_points_a,
		const Vector3 &p_center_b, double p_radius_b, const Transform3D &p_transform_b) {
	b3HullData *hull = make_hull(p_points_a);
	if (hull == nullptr) {
		return empty_manifold();
	}
	ManifoldScratch scratch;
	const b3Sphere b = make_sphere(p_center_b, p_radius_b);
	b3SimplexCache cache = {};
	b3CollideHullAndSphere(&scratch.manifold, MANIFOLD_CAPACITY, hull, &b, to_b3_transform(p_transform_b), &cache);
	const Dictionary out = scratch.result();
	b3DestroyHull(hull);
	return out;
}

Dictionary Box3DCollision::collide_capsules(const Vector3 &p_center_a1, const Vector3 &p_center_a2, double p_radius_a,
		const Vector3 &p_center_b1, const Vector3 &p_center_b2, double p_radius_b,
		const Transform3D &p_transform_b) {
	ManifoldScratch scratch;
	const b3Capsule a = make_capsule(p_center_a1, p_center_a2, p_radius_a);
	const b3Capsule b = make_capsule(p_center_b1, p_center_b2, p_radius_b);
	b3CollideCapsules(&scratch.manifold, MANIFOLD_CAPACITY, &a, &b, to_b3_transform(p_transform_b));
	return scratch.result();
}

Dictionary Box3DCollision::collide_hull_and_capsule(const PackedVector3Array &p_points_a,
		const Vector3 &p_center_b1, const Vector3 &p_center_b2, double p_radius_b,
		const Transform3D &p_transform_b) {
	b3HullData *hull = make_hull(p_points_a);
	if (hull == nullptr) {
		return empty_manifold();
	}
	ManifoldScratch scratch;
	const b3Capsule b = make_capsule(p_center_b1, p_center_b2, p_radius_b);
	b3SimplexCache cache = {};
	b3CollideHullAndCapsule(&scratch.manifold, MANIFOLD_CAPACITY, hull, &b, to_b3_transform(p_transform_b), &cache);
	const Dictionary out = scratch.result();
	b3DestroyHull(hull);
	return out;
}

Dictionary Box3DCollision::collide_hulls(const PackedVector3Array &p_points_a, const PackedVector3Array &p_points_b,
		const Transform3D &p_transform_b) {
	b3HullData *hull_a = make_hull(p_points_a);
	b3HullData *hull_b = make_hull(p_points_b);
	if (hull_a == nullptr || hull_b == nullptr) {
		if (hull_a != nullptr) {
			b3DestroyHull(hull_a);
		}
		if (hull_b != nullptr) {
			b3DestroyHull(hull_b);
		}
		return empty_manifold();
	}
	ManifoldScratch scratch;
	b3SATCache cache = {};
	b3CollideHulls(&scratch.manifold, MANIFOLD_CAPACITY, hull_a, hull_b, to_b3_transform(p_transform_b), &cache);
	const Dictionary out = scratch.result();
	b3DestroyHull(hull_a);
	b3DestroyHull(hull_b);
	return out;
}

Dictionary Box3DCollision::collide_triangle_and_sphere(const PackedVector3Array &p_triangle,
		const Vector3 &p_center_b, double p_radius_b, const Transform3D &p_transform_b) {
	b3Vec3 triangle[3];
	if (!triangle_points(p_triangle, triangle)) {
		return empty_manifold();
	}
	// The transform poses the sphere in the triangle's frame; b3CollideTriangle*
	// takes the triangle already in frame A (collision.h:637-645).
	b3Sphere b = make_sphere(p_center_b, p_radius_b);
	b.center = to_b3(p_transform_b.xform(to_gd(b.center)));
	ManifoldScratch scratch;
	b3CollideTriangleAndSphere(&scratch.manifold, MANIFOLD_CAPACITY, triangle, &b);
	return scratch.result();
}

Dictionary Box3DCollision::collide_triangle_and_capsule(const PackedVector3Array &p_triangle,
		const Vector3 &p_center_b1, const Vector3 &p_center_b2, double p_radius_b,
		const Transform3D &p_transform_b) {
	b3Vec3 triangle[3];
	if (!triangle_points(p_triangle, triangle)) {
		return empty_manifold();
	}
	// Same as the sphere form: this call takes no transform, so the capsule is
	// posed into the triangle's frame here.
	b3Capsule b = make_capsule(p_transform_b.xform(p_center_b1), p_transform_b.xform(p_center_b2), p_radius_b);
	ManifoldScratch scratch;
	b3SimplexCache cache = {};
	b3CollideTriangleAndCapsule(&scratch.manifold, MANIFOLD_CAPACITY, triangle, &b, &cache);
	return scratch.result();
}

Dictionary Box3DCollision::collide_triangle_and_hull(const PackedVector3Array &p_triangle,
		const PackedVector3Array &p_points_b, const Transform3D &p_transform_b,
		int p_triangle_flags, bool p_enable_speculative) {
	b3Vec3 triangle[3];
	if (!triangle_points(p_triangle, triangle)) {
		return empty_manifold();
	}
	// This one has no transform either, so the hull is built already posed.
	PackedVector3Array posed;
	posed.resize(p_points_b.size());
	for (int i = 0; i < p_points_b.size(); ++i) {
		posed[i] = p_transform_b.xform(p_points_b[i]);
	}
	b3HullData *hull = make_hull(posed);
	if (hull == nullptr) {
		return empty_manifold();
	}
	ManifoldScratch scratch;
	b3SATCache cache = {};
	b3CollideTriangleAndHull(&scratch.manifold, MANIFOLD_CAPACITY, triangle[0], triangle[1], triangle[2],
			p_triangle_flags, hull, &cache, p_enable_speculative);
	const Dictionary out = scratch.result();
	b3DestroyHull(hull);
	return out;
}

void Box3DCollision::_bind_methods() {
	ClassDB::bind_static_method("Box3DCollision", D_METHOD("is_valid_ray", "origin", "translation", "max_fraction"), &Box3DCollision::is_valid_ray, DEFVAL(1.0));
	ClassDB::bind_static_method("Box3DCollision", D_METHOD("ray_cast_sphere", "center", "radius", "origin", "translation", "max_fraction"), &Box3DCollision::ray_cast_sphere, DEFVAL(1.0));
	ClassDB::bind_static_method("Box3DCollision", D_METHOD("ray_cast_hollow_sphere", "center", "radius", "origin", "translation", "max_fraction"), &Box3DCollision::ray_cast_hollow_sphere, DEFVAL(1.0));
	ClassDB::bind_static_method("Box3DCollision", D_METHOD("ray_cast_capsule", "center1", "center2", "radius", "origin", "translation", "max_fraction"), &Box3DCollision::ray_cast_capsule, DEFVAL(1.0));
	ClassDB::bind_static_method("Box3DCollision", D_METHOD("ray_cast_hull", "points", "origin", "translation", "max_fraction"), &Box3DCollision::ray_cast_hull, DEFVAL(1.0));

	ClassDB::bind_static_method("Box3DCollision", D_METHOD("shape_cast_sphere", "center", "radius", "proxy_points", "proxy_radius", "translation", "max_fraction", "can_encroach"), &Box3DCollision::shape_cast_sphere, DEFVAL(1.0), DEFVAL(false));
	ClassDB::bind_static_method("Box3DCollision", D_METHOD("shape_cast_capsule", "center1", "center2", "radius", "proxy_points", "proxy_radius", "translation", "max_fraction", "can_encroach"), &Box3DCollision::shape_cast_capsule, DEFVAL(1.0), DEFVAL(false));
	ClassDB::bind_static_method("Box3DCollision", D_METHOD("shape_cast_hull", "points", "proxy_points", "proxy_radius", "translation", "max_fraction", "can_encroach"), &Box3DCollision::shape_cast_hull, DEFVAL(1.0), DEFVAL(false));

	ClassDB::bind_static_method("Box3DCollision", D_METHOD("overlap_sphere", "center", "radius", "transform", "proxy_points", "proxy_radius"), &Box3DCollision::overlap_sphere);
	ClassDB::bind_static_method("Box3DCollision", D_METHOD("overlap_capsule", "center1", "center2", "radius", "transform", "proxy_points", "proxy_radius"), &Box3DCollision::overlap_capsule);
	ClassDB::bind_static_method("Box3DCollision", D_METHOD("overlap_hull", "points", "transform", "proxy_points", "proxy_radius"), &Box3DCollision::overlap_hull);

	ClassDB::bind_static_method("Box3DCollision", D_METHOD("shape_distance", "points_a", "radius_a", "points_b", "radius_b", "transform_b", "use_radii"), &Box3DCollision::shape_distance, DEFVAL(true));
	ClassDB::bind_static_method("Box3DCollision", D_METHOD("shape_cast", "points_a", "radius_a", "points_b", "radius_b", "transform_b", "translation_b", "max_fraction", "can_encroach"), &Box3DCollision::shape_cast, DEFVAL(1.0), DEFVAL(false));
	ClassDB::bind_static_method("Box3DCollision", D_METHOD("time_of_impact", "points_a", "radius_a", "from_a", "to_a", "points_b", "radius_b", "from_b", "to_b", "max_fraction"), &Box3DCollision::time_of_impact, DEFVAL(1.0));
	ClassDB::bind_static_method("Box3DCollision", D_METHOD("get_sweep_transform", "from", "to", "time"), &Box3DCollision::get_sweep_transform);

	ClassDB::bind_static_method("Box3DCollision", D_METHOD("compute_sphere_mass", "center", "radius", "density"), &Box3DCollision::compute_sphere_mass);
	ClassDB::bind_static_method("Box3DCollision", D_METHOD("compute_capsule_mass", "center1", "center2", "radius", "density"), &Box3DCollision::compute_capsule_mass);
	ClassDB::bind_static_method("Box3DCollision", D_METHOD("compute_hull_mass", "points", "density"), &Box3DCollision::compute_hull_mass);
	ClassDB::bind_static_method("Box3DCollision", D_METHOD("compute_sphere_aabb", "center", "radius", "transform"), &Box3DCollision::compute_sphere_aabb);
	ClassDB::bind_static_method("Box3DCollision", D_METHOD("compute_capsule_aabb", "center1", "center2", "radius", "transform"), &Box3DCollision::compute_capsule_aabb);
	ClassDB::bind_static_method("Box3DCollision", D_METHOD("compute_hull_aabb", "points", "transform"), &Box3DCollision::compute_hull_aabb);

	ClassDB::bind_static_method("Box3DCollision", D_METHOD("collide_spheres", "center_a", "radius_a", "center_b", "radius_b", "transform_b"), &Box3DCollision::collide_spheres);
	ClassDB::bind_static_method("Box3DCollision", D_METHOD("collide_capsule_and_sphere", "center_a1", "center_a2", "radius_a", "center_b", "radius_b", "transform_b"), &Box3DCollision::collide_capsule_and_sphere);
	ClassDB::bind_static_method("Box3DCollision", D_METHOD("collide_hull_and_sphere", "points_a", "center_b", "radius_b", "transform_b"), &Box3DCollision::collide_hull_and_sphere);
	ClassDB::bind_static_method("Box3DCollision", D_METHOD("collide_capsules", "center_a1", "center_a2", "radius_a", "center_b1", "center_b2", "radius_b", "transform_b"), &Box3DCollision::collide_capsules);
	ClassDB::bind_static_method("Box3DCollision", D_METHOD("collide_hull_and_capsule", "points_a", "center_b1", "center_b2", "radius_b", "transform_b"), &Box3DCollision::collide_hull_and_capsule);
	ClassDB::bind_static_method("Box3DCollision", D_METHOD("collide_hulls", "points_a", "points_b", "transform_b"), &Box3DCollision::collide_hulls);
	ClassDB::bind_static_method("Box3DCollision", D_METHOD("collide_triangle_and_sphere", "triangle", "center_b", "radius_b", "transform_b"), &Box3DCollision::collide_triangle_and_sphere);
	ClassDB::bind_static_method("Box3DCollision", D_METHOD("collide_triangle_and_capsule", "triangle", "center_b1", "center_b2", "radius_b", "transform_b"), &Box3DCollision::collide_triangle_and_capsule);
	ClassDB::bind_static_method("Box3DCollision", D_METHOD("collide_triangle_and_hull", "triangle", "points_b", "transform_b", "triangle_flags", "enable_speculative"), &Box3DCollision::collide_triangle_and_hull, DEFVAL(0), DEFVAL(true));

	BIND_ENUM_CONSTANT(TOI_UNKNOWN);
	BIND_ENUM_CONSTANT(TOI_FAILED);
	BIND_ENUM_CONSTANT(TOI_OVERLAPPED);
	BIND_ENUM_CONSTANT(TOI_HIT);
	BIND_ENUM_CONSTANT(TOI_SEPARATED);
}
