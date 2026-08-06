// SPDX-FileCopyrightText: 2026 box3d-godot contributors
// SPDX-License-Identifier: MIT

#include "box3d_collision_shape.h"

#include "box3d_body.h"
#include "box3d_conversions.h"
#include "box3d_world.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <vector>

using namespace godot;

// b3Matrix3 is column-major (cx, cy, cz); Godot's Basis(x, y, z) constructor
// takes columns too, so inertia tensors map across 1:1.
static Basis to_gd_basis(const b3Matrix3 &m) {
	return Basis(to_gd(m.cx), to_gd(m.cy), to_gd(m.cz));
}

void Box3DCollisionShape::notify_parent() {
	Box3DBody *body = Object::cast_to<Box3DBody>(get_parent());
	if (body != nullptr) {
		body->request_rebuild();
	}
}

// A geometry change: resize this one shape in place if the owning body can
// (P-010), and only rebuild the whole body when it cannot.
void Box3DCollisionShape::resize_or_notify() {
	if (owner != nullptr && owner->resize_child_shape(this)) {
		return;
	}
	notify_parent();
}

Box3DCollisionShape::~Box3DCollisionShape() {
	// The owning body destroys its shapes before any child node is freed
	// (destroy_body / recreate_shapes both call on_shape_destroyed), so by here
	// nothing in the solver can still be pointing at the blob.
	release_owned_mesh();
}

void Box3DCollisionShape::release_owned_mesh() {
	if (owned_mesh != nullptr) {
		b3DestroyMesh(owned_mesh);
		owned_mesh = nullptr;
	}
}

void Box3DCollisionShape::on_shape_created(b3ShapeId p_id, Box3DBody *p_owner) {
	shape_id = p_id;
	owner = p_owner;
}

void Box3DCollisionShape::on_shape_destroyed() {
	shape_id = b3_nullShapeId;
	owner = nullptr;
	// The shape that referenced the blob is gone, and the shape this node gets
	// next is built from its authored properties, not from that mesh.
	release_owned_mesh();
}

bool Box3DCollisionShape::shape_live() const {
	if (owner != nullptr) {
		// Touching the b3 API while the solver thread runs would race.
		owner->join_world_step();
	}
	return b3Shape_IsValid(shape_id);
}

bool Box3DCollisionShape::apply_surface_material() {
	if (!shape_live()) {
		return false;
	}
	// Read-modify-write: userMaterialId and customColor belong to whoever set
	// them.
	b3SurfaceMaterial mat = b3Shape_GetSurfaceMaterial(shape_id);
	// Upstream asserts on negative material values.
	mat.friction = MAX(0.0f, (float)friction);
	mat.restitution = MAX(0.0f, (float)restitution);
	mat.rollingResistance = MAX(0.0f, (float)rolling_resistance);
	mat.tangentVelocity = to_b3(tangent_velocity);
	mat.userMaterialId = (uint64_t)user_material_id;
	b3Shape_SetSurfaceMaterial(shape_id, mat);
	return true;
}

b3Filter Box3DCollisionShape::make_filter() const {
	b3Filter filter = b3DefaultFilter();
	filter.categoryBits = ((uint64_t)collision_layer_high << 32) | (uint64_t)collision_layer;
	filter.maskBits = ((uint64_t)collision_mask_high << 32) | (uint64_t)collision_mask;
	filter.groupIndex = collision_group;
	return filter;
}

void Box3DCollisionShape::apply_filter_override() {
	// Without the override the body owns the filter, and Box3DBody::apply_filter
	// is what pushes it.
	if (!filter_override || !shape_live()) {
		return;
	}
	b3Shape_SetFilter(shape_id, make_filter(), filter_invoke_contacts);
}

bool Box3DCollisionShape::is_shape_valid() const {
	return shape_live();
}

bool Box3DCollisionShape::is_sensor() const {
	return shape_live() && b3Shape_IsSensor(shape_id);
}

AABB Box3DCollisionShape::get_aabb() const {
	if (shape_live()) {
		b3AABB box = b3Shape_GetAABB(shape_id);
		Vector3 lower = to_gd(box.lowerBound);
		return AABB(lower, to_gd(box.upperBound) - lower);
	}
	return AABB();
}

Vector3 Box3DCollisionShape::get_closest_point(const Vector3 &p_target) const {
	if (shape_live()) {
		return to_gd(b3Shape_GetClosestPoint(shape_id, to_b3(p_target)));
	}
	return Vector3();
}

Dictionary Box3DCollisionShape::compute_mass_data() const {
	Dictionary out;
	b3MassData data = {};
	if (shape_live()) {
		data = b3Shape_ComputeMassData(shape_id);
	}
	out["mass"] = (double)data.mass;
	out["center"] = to_gd(data.center);
	out["inertia"] = to_gd_basis(data.inertia);
	return out;
}

void Box3DCollisionShape::set_shape_name(const String &p_name) {
	if (shape_live()) {
		CharString utf8 = p_name.utf8();
		b3Shape_SetName(shape_id, utf8.get_data());
	}
}

String Box3DCollisionShape::get_shape_name() const {
	if (shape_live()) {
		return String::utf8(b3Shape_GetName(shape_id));
	}
	return String();
}

Box3DBody *Box3DCollisionShape::get_body() const {
	if (!shape_live()) {
		return nullptr;
	}
	b3BodyId owner_body = b3Shape_GetBody(shape_id);
	if (!b3Body_IsValid(owner_body)) {
		return nullptr;
	}
	// b3BodyDef.userData is the Box3DBody, set at creation.
	return (Box3DBody *)b3Body_GetUserData(owner_body);
}

Box3DWorld *Box3DCollisionShape::get_world() const {
	Box3DBody *body = get_body();
	if (body == nullptr) {
		return nullptr;
	}
	// b3Shape_GetWorld and the body's world must agree; the Box3DWorld node is
	// only reachable through the body, so a disagreement means no answer.
	Box3DWorld *world = body->get_world();
	// b3StoreWorldId, because B3_ID_EQUALS does not work for a b3WorldId
	// (id.h:104-112).
	if (world == nullptr ||
			b3StoreWorldId(b3Shape_GetWorld(shape_id)) != b3StoreWorldId(world->get_world_id())) {
		return nullptr;
	}
	return world;
}

int Box3DCollisionShape::get_geometry_type() const {
	if (!shape_live()) {
		return GEOMETRY_NONE;
	}
	return (int)b3Shape_GetType(shape_id);
}

Dictionary Box3DCollisionShape::get_sphere() const {
	Dictionary out;
	// b3Shape_GetSphere asserts the type is correct (box3d.h:947-948).
	if (get_geometry_type() != GEOMETRY_SPHERE) {
		return out;
	}
	b3Sphere sphere = b3Shape_GetSphere(shape_id);
	out["center"] = to_gd(sphere.center);
	out["radius"] = (double)sphere.radius;
	return out;
}

Dictionary Box3DCollisionShape::get_capsule() const {
	Dictionary out;
	if (get_geometry_type() != GEOMETRY_CAPSULE) {
		return out;
	}
	b3Capsule capsule = b3Shape_GetCapsule(shape_id);
	out["center1"] = to_gd(capsule.center1);
	out["center2"] = to_gd(capsule.center2);
	out["radius"] = (double)capsule.radius;
	return out;
}

Dictionary Box3DCollisionShape::get_hull() const {
	Dictionary out;
	if (get_geometry_type() != GEOMETRY_HULL) {
		return out;
	}
	const b3HullData *hull = b3Shape_GetHull(shape_id);
	if (hull == nullptr) {
		return out;
	}
	// The points hang off the end of the struct; b3GetHullPoints resolves the
	// offset (collision.h:146).
	const b3Vec3 *points = b3GetHullPoints(hull);
	PackedVector3Array out_points;
	if (points != nullptr && hull->vertexCount > 0) {
		out_points.resize(hull->vertexCount);
		for (int i = 0; i < hull->vertexCount; ++i) {
			out_points[i] = to_gd(points[i]);
		}
	}
	Vector3 lower = to_gd(hull->aabb.lowerBound);
	out["points"] = out_points;
	out["center"] = to_gd(hull->center);
	out["aabb"] = AABB(lower, to_gd(hull->aabb.upperBound) - lower);
	out["volume"] = (double)hull->volume;
	out["surface_area"] = (double)hull->surfaceArea;
	out["inner_radius"] = (double)hull->innerRadius;
	out["vertex_count"] = hull->vertexCount;
	out["face_count"] = hull->faceCount;
	return out;
}

Dictionary Box3DCollisionShape::get_mesh() const {
	Dictionary out;
	if (get_geometry_type() != GEOMETRY_MESH) {
		return out;
	}
	b3Mesh mesh = b3Shape_GetMesh(shape_id);
	out["scale"] = to_gd(mesh.scale);
	out["vertex_count"] = mesh.data != nullptr ? mesh.data->vertexCount : 0;
	out["triangle_count"] = mesh.data != nullptr ? mesh.data->triangleCount : 0;
	out["material_count"] = mesh.data != nullptr ? mesh.data->materialCount : 0;
	return out;
}

void Box3DCollisionShape::set_sphere(const Vector3 &p_center, double p_radius, bool p_update_mass) {
	if (!shape_live()) {
		return;
	}
	b3Sphere sphere;
	sphere.center = to_b3(p_center);
	sphere.radius = (float)p_radius;
	b3Shape_SetSphere(shape_id, &sphere);
	if (p_update_mass && owner != nullptr) {
		owner->apply_mass_from_shapes();
	}
}

void Box3DCollisionShape::set_capsule(const Vector3 &p_center1, const Vector3 &p_center2, double p_radius, bool p_update_mass) {
	if (!shape_live()) {
		return;
	}
	b3Capsule capsule;
	capsule.center1 = to_b3(p_center1);
	capsule.center2 = to_b3(p_center2);
	capsule.radius = (float)p_radius;
	b3Shape_SetCapsule(shape_id, &capsule);
	if (p_update_mass && owner != nullptr) {
		owner->apply_mass_from_shapes();
	}
}

void Box3DCollisionShape::set_hull(const PackedVector3Array &p_points, bool p_update_mass) {
	if (!shape_live()) {
		return;
	}
	int count = p_points.size();
	// b3CreateHull needs a volume to work with; four points is the minimum.
	if (count < 4) {
		UtilityFunctions::push_warning("Box3DCollisionShape.set_hull needs at least 4 points.");
		return;
	}
	std::vector<b3Vec3> points((size_t)count);
	for (int i = 0; i < count; ++i) {
		points[(size_t)i] = to_b3(p_points[i]);
	}
	// b3CreateHull caps the vertex count at 255 (the half-edge indices are
	// uint8), which is what the body's own HULL path passes too.
	int max_verts = count < 255 ? count : 255;
	b3HullData *hull = b3CreateHull(points.data(), count, max_verts);
	if (hull == nullptr) {
		UtilityFunctions::push_warning("Box3DCollisionShape.set_hull could not build a hull from those points.");
		return;
	}
	// Hulls are fully cloned by the shape (box3d.h:805), so the local one is
	// free the moment the call returns.
	b3Shape_SetHull(shape_id, hull);
	b3DestroyHull(hull);
	if (p_update_mass && owner != nullptr) {
		owner->apply_mass_from_shapes();
	}
}

bool Box3DCollisionShape::set_mesh(const PackedVector3Array &p_vertices, const PackedInt32Array &p_indices,
		const Vector3 &p_scale, bool p_update_mass) {
	if (!shape_live()) {
		return false;
	}
	const int vcount = p_vertices.size();
	const int icount = p_indices.size();
	if (vcount < 3 || icount < 3 || (icount % 3) != 0) {
		UtilityFunctions::push_warning("Box3DCollisionShape.set_mesh needs 3+ vertices and an index count that is a non-zero multiple of 3.");
		return false;
	}
	std::vector<b3Vec3> verts((size_t)vcount);
	for (int i = 0; i < vcount; ++i) {
		verts[(size_t)i] = to_b3(p_vertices[i]);
	}
	std::vector<int32_t> idx((size_t)icount);
	for (int i = 0; i < icount; ++i) {
		const int32_t v = p_indices[i];
		if (v < 0 || v >= vcount) {
			UtilityFunctions::push_warning("Box3DCollisionShape.set_mesh: an index falls outside the vertex array.");
			return false;
		}
		idx[(size_t)i] = v;
	}
	// b3Shape_SetMesh asserts b3IsValidVec3(scale) and, through b3SafeScale,
	// wants no component near zero (types.h:2227-2229).
	if (!Math::is_finite(p_scale.x) || !Math::is_finite(p_scale.y) || !Math::is_finite(p_scale.z) ||
			p_scale.is_zero_approx()) {
		UtilityFunctions::push_warning("Box3DCollisionShape.set_mesh needs a finite, non-zero scale.");
		return false;
	}
	if (owner != nullptr && owner->get_body_type() != Box3DBody::STATIC && !owner->get_is_sensor()) {
		// Same rule and same wording as Box3DBody's own mesh path: a sensor is
		// exempt because sensors are resolved by overlap (src/sensor.c:65).
		UtilityFunctions::push_warning("Box3DCollisionShape: mesh shapes only generate contacts on static bodies.");
	}

	b3MeshDef def = {};
	def.vertices = verts.data();
	def.indices = idx.data();
	def.vertexCount = vcount;
	def.triangleCount = icount / 3;
	// The same build settings Box3DBody's raw-mesh path uses, so a mesh authored
	// either way behaves the same: weld at 1 mm, no median split, edges
	// identified (which is what stops internal-edge ghost collisions).
	def.weldVertices = true;
	def.weldTolerance = 0.001f;
	def.useMedianSplit = false;
	def.identifyEdges = true;
	b3MeshData *built = b3CreateMesh(&def, nullptr, 0);
	if (built == nullptr) {
		UtilityFunctions::push_warning("Box3DCollisionShape.set_mesh: Box3D could not build a mesh from that data.");
		return false;
	}
	// Install first, free second: the old blob is still the live shape's until
	// b3Shape_SetMesh returns.
	b3Shape_SetMesh(shape_id, built, to_b3(p_scale));
	release_owned_mesh();
	owned_mesh = built;
	if (p_update_mass && owner != nullptr) {
		// b3Shape_SetMesh leaves mass alone by design (box3d.h:976-978).
		owner->apply_mass_from_shapes();
	}
	return true;
}

bool Box3DCollisionShape::set_mesh_scale(const Vector3 &p_scale) {
	if (get_geometry_type() != GEOMETRY_MESH) {
		return false;
	}
	b3Mesh mesh = b3Shape_GetMesh(shape_id);
	if (mesh.data == nullptr) {
		return false;
	}
	if (!Math::is_finite(p_scale.x) || !Math::is_finite(p_scale.y) || !Math::is_finite(p_scale.z) ||
			p_scale.is_zero_approx()) {
		UtilityFunctions::push_warning("Box3DCollisionShape.set_mesh_scale needs a finite, non-zero scale.");
		return false;
	}
	// Same triangles, new scale — ownership does not move, whoever built the
	// blob still owns it.
	b3Shape_SetMesh(shape_id, mesh.data, to_b3(p_scale));
	return true;
}

Dictionary Box3DCollisionShape::raycast(const Vector3 &p_origin, const Vector3 &p_translation) const {
	Dictionary out;
	if (!shape_live()) {
		out["hit"] = false;
		return out;
	}
	b3WorldCastOutput result = b3Shape_RayCast(shape_id, to_b3_pos(p_origin), to_b3(p_translation));
	out["hit"] = result.hit;
	out["point"] = to_gd_pos(result.point);
	out["normal"] = to_gd(result.normal);
	out["fraction"] = (double)result.fraction;
	out["triangle_index"] = result.triangleIndex;
	out["child_index"] = result.childIndex;
	out["material_index"] = result.materialIndex;
	out["iterations"] = result.iterations;
	return out;
}

void Box3DCollisionShape::_notification(int p_what) {
	if (p_what == NOTIFICATION_PARENTED) {
		notify_parent();
	} else if (p_what == NOTIFICATION_UNPARENTED) {
		// On Godot 4.7 this fires while get_parent() is still valid AND this
		// node is still in the parent's child list, so a rebuild kicked off
		// from here would build a shape FOR THE NODE LEAVING and store it as
		// that shape's userData — leaving a collider behind in the world and,
		// once the node is freed, a dangling pointer on every event dispatch.
		// The flag is what Box3DBody's shape walks use to skip it.
		leaving = true;
		notify_parent();
		leaving = false;
		// Whatever the body decided, this node no longer owns a shape.
		on_shape_destroyed();
	}
}

void Box3DCollisionShape::set_shape_type(int p_type) {
	shape_type = (ShapeType)p_type;
	notify_parent();
}

int Box3DCollisionShape::get_shape_type() const {
	return (int)shape_type;
}

void Box3DCollisionShape::set_box_size(const Vector3 &p_size) {
	box_size = p_size;
	resize_or_notify();
}

Vector3 Box3DCollisionShape::get_box_size() const {
	return box_size;
}

void Box3DCollisionShape::set_sphere_radius(double p_radius) {
	sphere_radius = p_radius;
	resize_or_notify();
}

double Box3DCollisionShape::get_sphere_radius() const {
	return sphere_radius;
}

void Box3DCollisionShape::set_capsule_radius(double p_radius) {
	capsule_radius = p_radius;
	resize_or_notify();
}

double Box3DCollisionShape::get_capsule_radius() const {
	return capsule_radius;
}

void Box3DCollisionShape::set_capsule_height(double p_height) {
	capsule_height = p_height;
	resize_or_notify();
}

double Box3DCollisionShape::get_capsule_height() const {
	return capsule_height;
}

void Box3DCollisionShape::set_sides(int p_sides) {
	sides = p_sides < 3 ? 3 : p_sides;
	resize_or_notify();
}

int Box3DCollisionShape::get_sides() const {
	return sides;
}

void Box3DCollisionShape::set_density(double p_density) {
	density = p_density;
	if (shape_live()) {
		// updateBodyMass: keep the body's mass properties in step, which is what
		// the rebuild this replaces used to do.
		b3Shape_SetDensity(shape_id, (float)density, true);
	} else {
		notify_parent();
	}
}

double Box3DCollisionShape::get_density() const {
	return density;
}

void Box3DCollisionShape::set_friction(double p_friction) {
	friction = p_friction;
	if (!apply_surface_material()) {
		notify_parent();
	}
}

double Box3DCollisionShape::get_friction() const {
	return friction;
}

void Box3DCollisionShape::set_restitution(double p_restitution) {
	restitution = p_restitution;
	if (!apply_surface_material()) {
		notify_parent();
	}
}

double Box3DCollisionShape::get_restitution() const {
	return restitution;
}

void Box3DCollisionShape::set_rolling_resistance(double p_resistance) {
	rolling_resistance = p_resistance;
	if (!apply_surface_material()) {
		notify_parent();
	}
}

double Box3DCollisionShape::get_rolling_resistance() const {
	return rolling_resistance;
}

void Box3DCollisionShape::set_tangent_velocity(const Vector3 &p_velocity) {
	tangent_velocity = p_velocity;
	if (!apply_surface_material()) {
		notify_parent();
	}
}

Vector3 Box3DCollisionShape::get_tangent_velocity() const {
	return tangent_velocity;
}

void Box3DCollisionShape::set_user_material_id(int64_t p_id) {
	user_material_id = p_id;
	if (!apply_surface_material()) {
		notify_parent();
	}
}

int64_t Box3DCollisionShape::get_user_material_id() const {
	return user_material_id;
}

void Box3DCollisionShape::set_filter_override(bool p_enabled) {
	filter_override = p_enabled;
	if (filter_override) {
		apply_filter_override();
	} else {
		// Handing the filter back to the body means re-reading the body's, which
		// only its own apply_filter() knows how to build.
		notify_parent();
	}
}

bool Box3DCollisionShape::get_filter_override() const {
	return filter_override;
}

void Box3DCollisionShape::set_collision_layer(int p_layer) {
	collision_layer = (uint32_t)p_layer;
	apply_filter_override();
}

int Box3DCollisionShape::get_collision_layer() const {
	return (int)collision_layer;
}

void Box3DCollisionShape::set_collision_mask(int p_mask) {
	collision_mask = (uint32_t)p_mask;
	apply_filter_override();
}

int Box3DCollisionShape::get_collision_mask() const {
	return (int)collision_mask;
}

void Box3DCollisionShape::set_collision_layer_high(int p_layer) {
	collision_layer_high = (uint32_t)p_layer;
	apply_filter_override();
}

int Box3DCollisionShape::get_collision_layer_high() const {
	return (int)collision_layer_high;
}

void Box3DCollisionShape::set_collision_mask_high(int p_mask) {
	collision_mask_high = (uint32_t)p_mask;
	apply_filter_override();
}

int Box3DCollisionShape::get_collision_mask_high() const {
	return (int)collision_mask_high;
}

void Box3DCollisionShape::set_collision_group(int p_group) {
	collision_group = p_group;
	apply_filter_override();
}

int Box3DCollisionShape::get_collision_group() const {
	return collision_group;
}

void Box3DCollisionShape::set_filter_invoke_contacts(bool p_enabled) {
	// Only decides what a LATER filter push costs; changing it alone pushes
	// nothing.
	filter_invoke_contacts = p_enabled;
}

bool Box3DCollisionShape::get_filter_invoke_contacts() const {
	return filter_invoke_contacts;
}

Dictionary Box3DCollisionShape::get_filter() const {
	Dictionary out;
	if (!shape_live()) {
		return out;
	}
	b3Filter filter = b3Shape_GetFilter(shape_id);
	out["layer"] = (int64_t)(uint32_t)(filter.categoryBits & 0xFFFFFFFFull);
	out["mask"] = (int64_t)(uint32_t)(filter.maskBits & 0xFFFFFFFFull);
	out["layer_high"] = (int64_t)(uint32_t)(filter.categoryBits >> 32);
	out["mask_high"] = (int64_t)(uint32_t)(filter.maskBits >> 32);
	out["group"] = filter.groupIndex;
	return out;
}

void Box3DCollisionShape::set_contact_events(int p_mode) {
	contact_events = (EventMode)p_mode;
	if (contact_events != EVENT_INHERIT && shape_live()) {
		b3Shape_EnableContactEvents(shape_id, contact_events == EVENT_ENABLED);
	} else {
		// Back to inheriting: only the body knows what it hands its shapes.
		notify_parent();
	}
}

int Box3DCollisionShape::get_contact_events() const {
	return (int)contact_events;
}

void Box3DCollisionShape::set_sensor_events(int p_mode) {
	sensor_events = (EventMode)p_mode;
	if (sensor_events != EVENT_INHERIT && shape_live()) {
		b3Shape_EnableSensorEvents(shape_id, sensor_events == EVENT_ENABLED);
	} else {
		notify_parent();
	}
}

int Box3DCollisionShape::get_sensor_events() const {
	return (int)sensor_events;
}

void Box3DCollisionShape::set_hit_events(int p_mode) {
	hit_events = (EventMode)p_mode;
	if (hit_events != EVENT_INHERIT && shape_live()) {
		b3Shape_EnableHitEvents(shape_id, hit_events == EVENT_ENABLED);
	} else {
		notify_parent();
	}
}

int Box3DCollisionShape::get_hit_events() const {
	return (int)hit_events;
}

void Box3DCollisionShape::set_custom_filtering(bool p_enabled) {
	if (custom_filtering == p_enabled) {
		return;
	}
	custom_filtering = p_enabled;
	// Creation-time flag: there is no b3Shape_EnableCustomFiltering, so the
	// shape has to be built again.
	notify_parent();
}

void Box3DCollisionShape::set_pre_solve_events(bool p_enabled) {
	pre_solve_events = p_enabled;
	if (shape_live()) {
		b3Shape_EnablePreSolveEvents(shape_id, p_enabled);
	}
}

bool Box3DCollisionShape::are_contact_events_enabled() const {
	return shape_live() && b3Shape_AreContactEventsEnabled(shape_id);
}

bool Box3DCollisionShape::are_sensor_events_enabled() const {
	return shape_live() && b3Shape_AreSensorEventsEnabled(shape_id);
}

bool Box3DCollisionShape::are_hit_events_enabled() const {
	return shape_live() && b3Shape_AreHitEventsEnabled(shape_id);
}

void Box3DCollisionShape::_bind_methods() {
	ClassDB::bind_method(D_METHOD("is_shape_valid"), &Box3DCollisionShape::is_shape_valid);
	ClassDB::bind_method(D_METHOD("is_sensor"), &Box3DCollisionShape::is_sensor);
	ClassDB::bind_method(D_METHOD("get_aabb"), &Box3DCollisionShape::get_aabb);
	ClassDB::bind_method(D_METHOD("get_closest_point", "target"), &Box3DCollisionShape::get_closest_point);
	ClassDB::bind_method(D_METHOD("compute_mass_data"), &Box3DCollisionShape::compute_mass_data);
	ClassDB::bind_method(D_METHOD("set_shape_name", "name"), &Box3DCollisionShape::set_shape_name);
	ClassDB::bind_method(D_METHOD("get_shape_name"), &Box3DCollisionShape::get_shape_name);
	ClassDB::bind_method(D_METHOD("get_body"), &Box3DCollisionShape::get_body);
	ClassDB::bind_method(D_METHOD("get_world"), &Box3DCollisionShape::get_world);
	ClassDB::bind_method(D_METHOD("get_geometry_type"), &Box3DCollisionShape::get_geometry_type);
	ClassDB::bind_method(D_METHOD("get_sphere"), &Box3DCollisionShape::get_sphere);
	ClassDB::bind_method(D_METHOD("get_capsule"), &Box3DCollisionShape::get_capsule);
	ClassDB::bind_method(D_METHOD("get_hull"), &Box3DCollisionShape::get_hull);
	ClassDB::bind_method(D_METHOD("get_mesh"), &Box3DCollisionShape::get_mesh);
	ClassDB::bind_method(D_METHOD("set_sphere", "center", "radius", "update_mass"), &Box3DCollisionShape::set_sphere, DEFVAL(true));
	ClassDB::bind_method(D_METHOD("set_capsule", "center1", "center2", "radius", "update_mass"), &Box3DCollisionShape::set_capsule, DEFVAL(true));
	ClassDB::bind_method(D_METHOD("set_hull", "points", "update_mass"), &Box3DCollisionShape::set_hull, DEFVAL(true));
	ClassDB::bind_method(D_METHOD("set_mesh", "vertices", "indices", "scale", "update_mass"), &Box3DCollisionShape::set_mesh, DEFVAL(Vector3(1, 1, 1)), DEFVAL(false));
	ClassDB::bind_method(D_METHOD("set_mesh_scale", "scale"), &Box3DCollisionShape::set_mesh_scale);
	ClassDB::bind_method(D_METHOD("raycast", "origin", "translation"), &Box3DCollisionShape::raycast);
	ClassDB::bind_method(D_METHOD("set_shape_type", "type"), &Box3DCollisionShape::set_shape_type);
	ClassDB::bind_method(D_METHOD("get_shape_type"), &Box3DCollisionShape::get_shape_type);
	ClassDB::bind_method(D_METHOD("set_box_size", "size"), &Box3DCollisionShape::set_box_size);
	ClassDB::bind_method(D_METHOD("get_box_size"), &Box3DCollisionShape::get_box_size);
	ClassDB::bind_method(D_METHOD("set_sphere_radius", "radius"), &Box3DCollisionShape::set_sphere_radius);
	ClassDB::bind_method(D_METHOD("get_sphere_radius"), &Box3DCollisionShape::get_sphere_radius);
	ClassDB::bind_method(D_METHOD("set_capsule_radius", "radius"), &Box3DCollisionShape::set_capsule_radius);
	ClassDB::bind_method(D_METHOD("get_capsule_radius"), &Box3DCollisionShape::get_capsule_radius);
	ClassDB::bind_method(D_METHOD("set_capsule_height", "height"), &Box3DCollisionShape::set_capsule_height);
	ClassDB::bind_method(D_METHOD("get_capsule_height"), &Box3DCollisionShape::get_capsule_height);
	ClassDB::bind_method(D_METHOD("set_sides", "sides"), &Box3DCollisionShape::set_sides);
	ClassDB::bind_method(D_METHOD("get_sides"), &Box3DCollisionShape::get_sides);
	ClassDB::bind_method(D_METHOD("set_density", "density"), &Box3DCollisionShape::set_density);
	ClassDB::bind_method(D_METHOD("get_density"), &Box3DCollisionShape::get_density);
	ClassDB::bind_method(D_METHOD("set_friction", "friction"), &Box3DCollisionShape::set_friction);
	ClassDB::bind_method(D_METHOD("get_friction"), &Box3DCollisionShape::get_friction);
	ClassDB::bind_method(D_METHOD("set_restitution", "restitution"), &Box3DCollisionShape::set_restitution);
	ClassDB::bind_method(D_METHOD("get_restitution"), &Box3DCollisionShape::get_restitution);
	ClassDB::bind_method(D_METHOD("set_rolling_resistance", "resistance"), &Box3DCollisionShape::set_rolling_resistance);
	ClassDB::bind_method(D_METHOD("get_rolling_resistance"), &Box3DCollisionShape::get_rolling_resistance);
	ClassDB::bind_method(D_METHOD("set_tangent_velocity", "velocity"), &Box3DCollisionShape::set_tangent_velocity);
	ClassDB::bind_method(D_METHOD("get_tangent_velocity"), &Box3DCollisionShape::get_tangent_velocity);
	ClassDB::bind_method(D_METHOD("set_user_material_id", "id"), &Box3DCollisionShape::set_user_material_id);
	ClassDB::bind_method(D_METHOD("get_user_material_id"), &Box3DCollisionShape::get_user_material_id);
	ClassDB::bind_method(D_METHOD("set_filter_override", "enabled"), &Box3DCollisionShape::set_filter_override);
	ClassDB::bind_method(D_METHOD("get_filter_override"), &Box3DCollisionShape::get_filter_override);
	ClassDB::bind_method(D_METHOD("set_collision_layer", "layer"), &Box3DCollisionShape::set_collision_layer);
	ClassDB::bind_method(D_METHOD("get_collision_layer"), &Box3DCollisionShape::get_collision_layer);
	ClassDB::bind_method(D_METHOD("set_collision_mask", "mask"), &Box3DCollisionShape::set_collision_mask);
	ClassDB::bind_method(D_METHOD("get_collision_mask"), &Box3DCollisionShape::get_collision_mask);
	ClassDB::bind_method(D_METHOD("set_collision_layer_high", "layer"), &Box3DCollisionShape::set_collision_layer_high);
	ClassDB::bind_method(D_METHOD("get_collision_layer_high"), &Box3DCollisionShape::get_collision_layer_high);
	ClassDB::bind_method(D_METHOD("set_collision_mask_high", "mask"), &Box3DCollisionShape::set_collision_mask_high);
	ClassDB::bind_method(D_METHOD("get_collision_mask_high"), &Box3DCollisionShape::get_collision_mask_high);
	ClassDB::bind_method(D_METHOD("set_collision_group", "group"), &Box3DCollisionShape::set_collision_group);
	ClassDB::bind_method(D_METHOD("get_collision_group"), &Box3DCollisionShape::get_collision_group);
	ClassDB::bind_method(D_METHOD("set_filter_invoke_contacts", "enabled"), &Box3DCollisionShape::set_filter_invoke_contacts);
	ClassDB::bind_method(D_METHOD("get_filter_invoke_contacts"), &Box3DCollisionShape::get_filter_invoke_contacts);
	ClassDB::bind_method(D_METHOD("get_filter"), &Box3DCollisionShape::get_filter);
	ClassDB::bind_method(D_METHOD("set_contact_events", "mode"), &Box3DCollisionShape::set_contact_events);
	ClassDB::bind_method(D_METHOD("get_contact_events"), &Box3DCollisionShape::get_contact_events);
	ClassDB::bind_method(D_METHOD("set_sensor_events", "mode"), &Box3DCollisionShape::set_sensor_events);
	ClassDB::bind_method(D_METHOD("get_sensor_events"), &Box3DCollisionShape::get_sensor_events);
	ClassDB::bind_method(D_METHOD("set_hit_events", "mode"), &Box3DCollisionShape::set_hit_events);
	ClassDB::bind_method(D_METHOD("get_hit_events"), &Box3DCollisionShape::get_hit_events);
	ClassDB::bind_method(D_METHOD("set_custom_filtering", "enabled"), &Box3DCollisionShape::set_custom_filtering);
	ClassDB::bind_method(D_METHOD("get_custom_filtering"), &Box3DCollisionShape::get_custom_filtering);
	ClassDB::bind_method(D_METHOD("set_pre_solve_events", "enabled"), &Box3DCollisionShape::set_pre_solve_events);
	ClassDB::bind_method(D_METHOD("get_pre_solve_events"), &Box3DCollisionShape::get_pre_solve_events);
	ClassDB::bind_method(D_METHOD("are_contact_events_enabled"), &Box3DCollisionShape::are_contact_events_enabled);
	ClassDB::bind_method(D_METHOD("are_sensor_events_enabled"), &Box3DCollisionShape::are_sensor_events_enabled);
	ClassDB::bind_method(D_METHOD("are_hit_events_enabled"), &Box3DCollisionShape::are_hit_events_enabled);

	ADD_PROPERTY(PropertyInfo(Variant::INT, "shape_type", PROPERTY_HINT_ENUM, "Box,Sphere,Capsule,Cylinder,Cone"), "set_shape_type", "get_shape_type");
	ADD_PROPERTY(PropertyInfo(Variant::VECTOR3, "box_size"), "set_box_size", "get_box_size");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "sphere_radius", PROPERTY_HINT_RANGE, "0.01,100,0.01,or_greater"), "set_sphere_radius", "get_sphere_radius");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "capsule_radius", PROPERTY_HINT_RANGE, "0.01,100,0.01,or_greater"), "set_capsule_radius", "get_capsule_radius");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "capsule_height", PROPERTY_HINT_RANGE, "0.02,100,0.01,or_greater"), "set_capsule_height", "get_capsule_height");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "sides", PROPERTY_HINT_RANGE, "3,64,1"), "set_sides", "get_sides");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "density", PROPERTY_HINT_RANGE, "0.01,100,0.01,or_greater"), "set_density", "get_density");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "friction", PROPERTY_HINT_RANGE, "0,1,0.01,or_greater"), "set_friction", "get_friction");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "restitution", PROPERTY_HINT_RANGE, "0,1,0.01"), "set_restitution", "get_restitution");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "rolling_resistance", PROPERTY_HINT_RANGE, "0,1,0.01"), "set_rolling_resistance", "get_rolling_resistance");
	ADD_PROPERTY(PropertyInfo(Variant::VECTOR3, "tangent_velocity"), "set_tangent_velocity", "get_tangent_velocity");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "user_material_id"), "set_user_material_id", "get_user_material_id");

	ADD_GROUP("Filter Override", "");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "filter_override"), "set_filter_override", "get_filter_override");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "collision_layer", PROPERTY_HINT_LAYERS_3D_PHYSICS), "set_collision_layer", "get_collision_layer");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "collision_mask", PROPERTY_HINT_LAYERS_3D_PHYSICS), "set_collision_mask", "get_collision_mask");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "collision_layer_high", PROPERTY_HINT_LAYERS_3D_PHYSICS), "set_collision_layer_high", "get_collision_layer_high");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "collision_mask_high", PROPERTY_HINT_LAYERS_3D_PHYSICS), "set_collision_mask_high", "get_collision_mask_high");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "collision_group"), "set_collision_group", "get_collision_group");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "filter_invoke_contacts"), "set_filter_invoke_contacts", "get_filter_invoke_contacts");

	ADD_GROUP("Events", "");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "contact_events", PROPERTY_HINT_ENUM, "Inherit,Enabled,Disabled"), "set_contact_events", "get_contact_events");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "sensor_events", PROPERTY_HINT_ENUM, "Inherit,Enabled,Disabled"), "set_sensor_events", "get_sensor_events");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "hit_events", PROPERTY_HINT_ENUM, "Inherit,Enabled,Disabled"), "set_hit_events", "get_hit_events");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "custom_filtering"), "set_custom_filtering", "get_custom_filtering");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "pre_solve_events"), "set_pre_solve_events", "get_pre_solve_events");

	BIND_ENUM_CONSTANT(BOX);
	BIND_ENUM_CONSTANT(SPHERE);
	BIND_ENUM_CONSTANT(CAPSULE);
	BIND_ENUM_CONSTANT(CYLINDER);
	BIND_ENUM_CONSTANT(CONE);

	BIND_ENUM_CONSTANT(GEOMETRY_NONE);
	BIND_ENUM_CONSTANT(GEOMETRY_CAPSULE);
	BIND_ENUM_CONSTANT(GEOMETRY_COMPOUND);
	BIND_ENUM_CONSTANT(GEOMETRY_HEIGHT_FIELD);
	BIND_ENUM_CONSTANT(GEOMETRY_HULL);
	BIND_ENUM_CONSTANT(GEOMETRY_MESH);
	BIND_ENUM_CONSTANT(GEOMETRY_SPHERE);

	BIND_ENUM_CONSTANT(EVENT_INHERIT);
	BIND_ENUM_CONSTANT(EVENT_ENABLED);
	BIND_ENUM_CONSTANT(EVENT_DISABLED);
}
