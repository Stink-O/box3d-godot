// SPDX-FileCopyrightText: 2026 box3d-godot contributors
// SPDX-License-Identifier: MIT

#include "box3d_body.h"

#include "box3d_collision_shape.h"
#include "box3d_conversions.h"
#include "box3d_world.h"

#include <godot_cpp/classes/box_mesh.hpp>
#include <godot_cpp/classes/capsule_mesh.hpp>
#include <godot_cpp/classes/cylinder_mesh.hpp>
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/mesh_instance3d.hpp>
#include <godot_cpp/classes/sphere_mesh.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <vector>

using namespace godot;

Box3DBody::Box3DBody() {}

Box3DBody::~Box3DBody() {
	if (mesh_data != nullptr) {
		b3DestroyMesh(mesh_data);
		mesh_data = nullptr;
	}
}

Box3DWorld *Box3DBody::find_world() {
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

bool Box3DBody::is_body_valid() const {
	return b3Body_IsValid(body_id);
}

void Box3DBody::create_in_world() {
	if (Engine::get_singleton()->is_editor_hint()) {
		return;
	}
	world = find_world();
	if (world == nullptr) {
		UtilityFunctions::push_warning("Box3DBody has no Box3DWorld ancestor; it will not be simulated.");
		return;
	}
	b3WorldId world_id = world->get_world_id();
	if (!b3World_IsValid(world_id)) {
		return;
	}

	Transform3D xform = get_global_transform();
	Quaternion rotation = xform.basis.get_rotation_quaternion();

	b3BodyDef body_def = b3DefaultBodyDef();
	body_def.type = (b3BodyType)body_type;
	body_def.position = to_b3_pos(xform.origin);
	body_def.rotation = to_b3(rotation);
	body_def.linearDamping = (float)linear_damping;
	body_def.angularDamping = (float)angular_damping;
	body_def.gravityScale = (float)gravity_scale;
	body_def.isBullet = continuous;
	body_def.allowFastRotation = allow_fast_rotation;
	body_def.motionLocks.linearX = lock_linear_x;
	body_def.motionLocks.linearY = lock_linear_y;
	body_def.motionLocks.linearZ = lock_linear_z;
	body_def.motionLocks.angularX = lock_angular_x;
	body_def.motionLocks.angularY = lock_angular_y;
	body_def.motionLocks.angularZ = lock_angular_z;
	body_def.userData = this;
	body_id = b3CreateBody(world_id, &body_def);

	// Compound bodies: if there are Box3DCollisionShape children, build a shape
	// for each and skip the body's own shape_type.
	{
		Transform3D body_inv = get_global_transform().affine_inverse();
		bool has_child_shapes = false;
		for (int i = 0; i < get_child_count(); ++i) {
			Box3DCollisionShape *cs = Object::cast_to<Box3DCollisionShape>(get_child(i));
			if (cs != nullptr) {
				has_child_shapes = true;
				create_child_shape(cs, body_inv);
			}
		}
		if (has_child_shapes) {
			world->register_body(this);
			return;
		}
	}

	b3ShapeDef shape_def = b3DefaultShapeDef();
	shape_def.density = (float)density;
	shape_def.baseMaterial.friction = (float)friction;
	shape_def.baseMaterial.restitution = (float)restitution;
	shape_def.enableContactEvents = contact_monitor;
	shape_def.filter.categoryBits = collision_layer;
	shape_def.filter.maskBits = collision_mask;
	shape_def.isSensor = is_sensor;
	// Enable sensor events on every shape so sensors detect any body (like an
	// Area3D). Box3D only does work here in proportion to the number of sensors.
	shape_def.enableSensorEvents = true;
	// Hit events power the debug draw's impact flash; box3d only reports them
	// above the world's hit-event speed threshold (default 1 m/s).
	shape_def.enableHitEvents = true;

	switch (shape_type) {
		case SPHERE: {
			b3Sphere sphere;
			sphere.center = b3Vec3{ 0.0f, 0.0f, 0.0f };
			sphere.radius = (float)sphere_radius;
			b3CreateSphereShape(body_id, &shape_def, &sphere);
		} break;
		case CAPSULE: {
			float radius = (float)capsule_radius;
			float half = (float)(capsule_height * 0.5) - radius;
			if (half < 0.0f) {
				half = 0.0f;
			}
			b3Capsule capsule;
			capsule.center1 = b3Vec3{ 0.0f, -half, 0.0f };
			capsule.center2 = b3Vec3{ 0.0f, half, 0.0f };
			capsule.radius = radius;
			b3CreateCapsuleShape(body_id, &shape_def, &capsule);
		} break;
		case CYLINDER: {
			// yOffset centers the cylinder on the body origin (Box3D builds it
			// base-up from the offset), matching Godot's centered CylinderMesh.
			float half = (float)capsule_height * 0.5f;
			b3HullData *hull = b3CreateCylinder((float)capsule_height, (float)capsule_radius, -half, cylinder_sides);
			if (hull != nullptr) {
				b3CreateHullShape(body_id, &shape_def, hull);
				b3DestroyHull(hull);
			}
		} break;
		case CONE: {
			// radius1 = base, radius2 = 0 (the point). b3CreateCone has no offset,
			// so bake a -height/2 shift to center it on the body origin.
			b3HullData *hull = b3CreateCone((float)capsule_height, (float)capsule_radius, 0.0f, cylinder_sides);
			if (hull != nullptr) {
				b3Transform xf;
				xf.p = b3Vec3{ 0.0f, -(float)capsule_height * 0.5f, 0.0f };
				xf.q = b3Quat_identity;
				b3CreateTransformedHullShape(body_id, &shape_def, hull, xf, b3Vec3_one);
				b3DestroyHull(hull);
			}
		} break;
		case HULL: {
			Ref<Mesh> src_mesh;
			Transform3D src_local;
			if (resolve_collision_mesh(src_mesh, src_local)) {
				PackedVector3Array faces = src_mesh->get_faces();
				int count = faces.size();
				if (count >= 4) {
					std::vector<b3Vec3> points((size_t)count);
					for (int i = 0; i < count; ++i) {
						points[(size_t)i] = to_b3(src_local.xform(faces[i]));
					}
					int max_verts = count < 255 ? count : 255;
					b3HullData *hull = b3CreateHull(points.data(), count, max_verts);
					if (hull != nullptr) {
						b3CreateHullShape(body_id, &shape_def, hull);
						b3DestroyHull(hull);
					}
				}
			} else {
				UtilityFunctions::push_warning("Box3DBody shape_type is Hull but no collision_mesh or child MeshInstance3D was found.");
			}
		} break;
		case MESH: {
			if (mesh_data != nullptr) {
				b3DestroyMesh(mesh_data);
				mesh_data = nullptr;
			}
			if (body_type != STATIC) {
				UtilityFunctions::push_warning("Box3DBody: Mesh colliders only generate contacts on static bodies.");
			}
			Ref<Mesh> src_mesh;
			Transform3D src_local;
			if (resolve_collision_mesh(src_mesh, src_local)) {
				PackedVector3Array faces = src_mesh->get_faces();
				int vcount = faces.size();
				if (vcount >= 3 && (vcount % 3) == 0) {
					std::vector<b3Vec3> verts((size_t)vcount);
					std::vector<int32_t> idx((size_t)vcount);
					for (int i = 0; i < vcount; ++i) {
						verts[(size_t)i] = to_b3(src_local.xform(faces[i]));
					}
					// Reverse triangle winding: Godot winds faces so the normal
					// points outward, but Box3D's one-sided mesh collision uses the
					// opposite winding, so flip to collide with the outer surface.
					for (int t = 0; t < vcount / 3; ++t) {
						idx[(size_t)(t * 3 + 0)] = t * 3 + 0;
						idx[(size_t)(t * 3 + 1)] = t * 3 + 2;
						idx[(size_t)(t * 3 + 2)] = t * 3 + 1;
					}
					b3MeshDef def = {};
					def.vertices = verts.data();
					def.indices = idx.data();
					def.vertexCount = vcount;
					def.triangleCount = vcount / 3;
					def.weldVertices = true;
					def.weldTolerance = 0.001f;
					def.identifyEdges = true;
					// Box3D keeps a pointer to mesh_data, so it must live until the
					// body is destroyed (see destroy_body()).
					mesh_data = b3CreateMesh(&def, nullptr, 0);
					if (mesh_data != nullptr) {
						b3CreateMeshShape(body_id, &shape_def, mesh_data, b3Vec3_one);
					}
				}
			} else {
				UtilityFunctions::push_warning("Box3DBody shape_type is Mesh but no collision_mesh or child MeshInstance3D was found.");
			}
		} break;
		case FIT_MESH: {
			// Box collider auto-sized to the child MeshInstance3D's mesh bounds, so
			// resizing the visual mesh resizes the collider — no separate box_size.
			Ref<Mesh> src_mesh;
			Transform3D src_local;
			if (resolve_collision_mesh(src_mesh, src_local)) {
				AABB aabb = src_mesh->get_aabb();
				// Transform the 8 corners into body space and take their bounds.
				AABB local_aabb;
				for (int c = 0; c < 8; ++c) {
					Vector3 corner = src_local.xform(aabb.get_endpoint(c));
					if (c == 0) {
						local_aabb = AABB(corner, Vector3());
					} else {
						local_aabb = local_aabb.expand(corner);
					}
				}
				Vector3 h = local_aabb.size * 0.5;
				Vector3 center = local_aabb.position + h;
				b3Transform xf;
				xf.p = to_b3(center);
				xf.q = b3Quat_identity;
				b3BoxHull box = b3MakeTransformedBoxHull((float)h.x, (float)h.y, (float)h.z, xf);
				b3CreateHullShape(body_id, &shape_def, &box.base);
			} else {
				UtilityFunctions::push_warning("Box3DBody shape_type is Fit Mesh but no child MeshInstance3D was found.");
			}
		} break;
		case BOX:
		default: {
			b3BoxHull box = b3MakeBoxHull((float)(box_size.x * 0.5), (float)(box_size.y * 0.5), (float)(box_size.z * 0.5));
			b3CreateHullShape(body_id, &shape_def, &box.base);
		} break;
	}

	update_auto_visual();
	world->register_body(this);
}

bool Box3DBody::resolve_collision_mesh(Ref<Mesh> &r_mesh, Transform3D &r_local) {
	if (collision_mesh.is_valid()) {
		r_mesh = collision_mesh;
		r_local = Transform3D();
		return true;
	}
	// Fall back to the first child MeshInstance3D's mesh, at its transform
	// relative to this body — so devs can drop in their own model as a collider
	// without assigning collision_mesh separately.
	Transform3D body_inv = get_global_transform().affine_inverse();
	for (int i = 0; i < get_child_count(); ++i) {
		MeshInstance3D *mi = Object::cast_to<MeshInstance3D>(get_child(i));
		// Skip our own auto_visual mesh: it's derived FROM the collision shape,
		// so it must never be used as a collision source (would self-reference).
		if (mi != nullptr && mi != auto_mesh_instance && mi->get_mesh().is_valid()) {
			r_mesh = mi->get_mesh();
			r_local = body_inv * mi->get_global_transform();
			return true;
		}
	}
	return false;
}

void Box3DBody::update_auto_visual() {
	if (Engine::get_singleton()->is_editor_hint()) {
		return;
	}
	if (!auto_visual) {
		if (auto_mesh_instance != nullptr) {
			auto_mesh_instance->queue_free();
			auto_mesh_instance = nullptr;
		}
		return;
	}
	// Defer to a user-provided MeshInstance3D child: auto_visual only fills in
	// when there's nothing else drawing the body.
	for (int i = 0; i < get_child_count(); ++i) {
		MeshInstance3D *mi = Object::cast_to<MeshInstance3D>(get_child(i));
		if (mi != nullptr && mi != auto_mesh_instance) {
			if (auto_mesh_instance != nullptr) {
				auto_mesh_instance->queue_free();
				auto_mesh_instance = nullptr;
			}
			return;
		}
	}

	// Build a mesh matching the current primitive collider. Hull/Mesh/Fit Mesh
	// have no size of their own to mirror (they derive the collider FROM a
	// mesh, the opposite direction), so nothing is generated for those.
	Ref<Mesh> mesh;
	switch (shape_type) {
		case SPHERE: {
			Ref<SphereMesh> m;
			m.instantiate();
			m->set_radius((float)sphere_radius);
			m->set_height((float)sphere_radius * 2.0f);
			mesh = m;
		} break;
		case CAPSULE: {
			Ref<CapsuleMesh> m;
			m.instantiate();
			m->set_radius((float)capsule_radius);
			m->set_height((float)capsule_height);
			mesh = m;
		} break;
		case CYLINDER: {
			Ref<CylinderMesh> m;
			m.instantiate();
			m->set_top_radius((float)capsule_radius);
			m->set_bottom_radius((float)capsule_radius);
			m->set_height((float)capsule_height);
			mesh = m;
		} break;
		case CONE: {
			// Apex up, base down — matches b3CreateCone's centering (see the
			// CONE case above) and Godot's CylinderMesh (top face at +height/2).
			Ref<CylinderMesh> m;
			m.instantiate();
			m->set_top_radius(0.0f);
			m->set_bottom_radius((float)capsule_radius);
			m->set_height((float)capsule_height);
			mesh = m;
		} break;
		case BOX: {
			Ref<BoxMesh> m;
			m.instantiate();
			m->set_size(box_size); // BoxMesh size is full extents, like box_size
			mesh = m;
		} break;
		default:
			break;
	}

	if (!mesh.is_valid()) {
		if (auto_mesh_instance != nullptr) {
			auto_mesh_instance->queue_free();
			auto_mesh_instance = nullptr;
		}
		return;
	}

	if (auto_mesh_instance == nullptr) {
		auto_mesh_instance = memnew(MeshInstance3D);
		auto_mesh_instance->set_name("Box3DAutoVisual");
		add_child(auto_mesh_instance);
	}
	auto_mesh_instance->set_mesh(mesh);
}

void Box3DBody::create_child_shape(Box3DCollisionShape *p_shape, const Transform3D &p_body_inv) {
	b3ShapeDef sd = b3DefaultShapeDef();
	sd.density = (float)p_shape->get_density();
	sd.baseMaterial.friction = (float)p_shape->get_friction();
	sd.baseMaterial.restitution = (float)p_shape->get_restitution();
	sd.enableContactEvents = contact_monitor;
	sd.filter.categoryBits = collision_layer;
	sd.filter.maskBits = collision_mask;
	sd.isSensor = is_sensor;
	sd.enableSensorEvents = true;
	sd.enableHitEvents = true;

	// The shape's transform relative to the body.
	Transform3D local = p_body_inv * p_shape->get_global_transform();
	switch (p_shape->get_shape_type()) {
		case Box3DCollisionShape::SPHERE: {
			b3Sphere sphere;
			sphere.center = to_b3(local.origin);
			sphere.radius = (float)p_shape->get_sphere_radius();
			b3CreateSphereShape(body_id, &sd, &sphere);
		} break;
		case Box3DCollisionShape::CAPSULE: {
			float radius = (float)p_shape->get_capsule_radius();
			float half = (float)(p_shape->get_capsule_height() * 0.5) - radius;
			if (half < 0.0f) {
				half = 0.0f;
			}
			b3Capsule capsule;
			capsule.center1 = to_b3(local.xform(Vector3(0, -half, 0)));
			capsule.center2 = to_b3(local.xform(Vector3(0, half, 0)));
			capsule.radius = radius;
			b3CreateCapsuleShape(body_id, &sd, &capsule);
		} break;
		case Box3DCollisionShape::BOX:
		default: {
			Vector3 h = p_shape->get_box_size() * 0.5;
			b3BoxHull box = b3MakeTransformedBoxHull((float)h.x, (float)h.y, (float)h.z, to_b3_transform(local));
			b3CreateHullShape(body_id, &sd, &box.base);
		} break;
	}
}

void Box3DBody::request_rebuild() {
	rebuild_if_alive();
}

void Box3DBody::destroy_body() {
	if (world != nullptr) {
		world->unregister_body(this);
	}
	if (b3Body_IsValid(body_id)) {
		b3DestroyBody(body_id);
	}
	body_id = b3_nullBodyId;
	// The shape (and its mesh reference) is gone now, so the mesh data is free
	// to release.
	if (mesh_data != nullptr) {
		b3DestroyMesh(mesh_data);
		mesh_data = nullptr;
	}
}

void Box3DBody::rebuild_if_alive() {
	if (is_body_valid()) {
		destroy_body();
		create_in_world();
	}
}

void Box3DBody::apply_motion_locks() {
	if (!b3Body_IsValid(body_id)) {
		return;
	}
	b3MotionLocks locks;
	locks.linearX = lock_linear_x;
	locks.linearY = lock_linear_y;
	locks.linearZ = lock_linear_z;
	locks.angularX = lock_angular_x;
	locks.angularY = lock_angular_y;
	locks.angularZ = lock_angular_z;
	b3Body_SetMotionLocks(body_id, locks);
}

void Box3DBody::sync_to_physics(double p_delta) {
	if (!b3Body_IsValid(body_id) || body_type != KINEMATIC) {
		return;
	}
	Transform3D xform = get_global_transform();
	b3WorldTransform target;
	target.p = to_b3_pos(xform.origin);
	target.q = to_b3(xform.basis.get_rotation_quaternion());
	// Solves for the velocity that reaches the target over one step, so the
	// kinematic body pushes dynamic bodies correctly instead of teleporting.
	b3Body_SetTargetTransform(body_id, target, (float)p_delta, true);
}

void Box3DBody::sync_from_physics() {
	if (body_type != DYNAMIC || !b3Body_IsValid(body_id)) {
		return;
	}
	// Sleeping bodies don't move, so skip the node update once their final
	// transform has been written — big scenes idle for free this way.
	if (b3Body_IsAwake(body_id)) {
		asleep_synced = false;
	} else if (asleep_synced) {
		return;
	} else {
		asleep_synced = true;
	}
	b3WorldTransform t = b3Body_GetTransform(body_id);
	set_global_transform(Transform3D(Basis(to_gd(t.q)), to_gd_pos(t.p)));
}

bool Box3DBody::is_awake_now() const {
	return b3Body_IsValid(body_id) && b3Body_IsAwake(body_id);
}

bool Box3DBody::is_enabled_now() const {
	return b3Body_IsValid(body_id) && b3Body_IsEnabled(body_id);
}

void Box3DBody::_notification(int p_what) {
	switch (p_what) {
		case NOTIFICATION_READY: {
			if (!Engine::get_singleton()->is_editor_hint()) {
				create_in_world();
			}
		} break;
		case NOTIFICATION_EXIT_TREE: {
			destroy_body();
			world = nullptr;
		} break;
	}
}

void Box3DBody::emit_contact_begin(Box3DBody *p_other) {
	emit_signal("body_entered", p_other);
}

void Box3DBody::emit_contact_end(Box3DBody *p_other) {
	emit_signal("body_exited", p_other);
}

void Box3DBody::emit_area_begin(Box3DBody *p_visitor) {
	emit_signal("area_entered", p_visitor);
}

void Box3DBody::emit_area_end(Box3DBody *p_visitor) {
	emit_signal("area_exited", p_visitor);
}

// --- Scripting API ---

void Box3DBody::apply_central_force(const Vector3 &p_force) {
	if (b3Body_IsValid(body_id)) {
		b3Body_ApplyForceToCenter(body_id, to_b3(p_force), true);
	}
}

void Box3DBody::apply_central_impulse(const Vector3 &p_impulse) {
	if (b3Body_IsValid(body_id)) {
		b3Body_ApplyLinearImpulseToCenter(body_id, to_b3(p_impulse), true);
	}
}

void Box3DBody::apply_torque(const Vector3 &p_torque) {
	if (b3Body_IsValid(body_id)) {
		b3Body_ApplyTorque(body_id, to_b3(p_torque), true);
	}
}

void Box3DBody::set_linear_velocity(const Vector3 &p_velocity) {
	if (b3Body_IsValid(body_id)) {
		b3Body_SetLinearVelocity(body_id, to_b3(p_velocity));
	}
}

Vector3 Box3DBody::get_linear_velocity() const {
	if (b3Body_IsValid(body_id)) {
		return to_gd(b3Body_GetLinearVelocity(body_id));
	}
	return Vector3();
}

void Box3DBody::set_angular_velocity(const Vector3 &p_velocity) {
	if (b3Body_IsValid(body_id)) {
		b3Body_SetAngularVelocity(body_id, to_b3(p_velocity));
	}
}

Vector3 Box3DBody::get_angular_velocity() const {
	if (b3Body_IsValid(body_id)) {
		return to_gd(b3Body_GetAngularVelocity(body_id));
	}
	return Vector3();
}

double Box3DBody::get_mass() const {
	if (b3Body_IsValid(body_id)) {
		return b3Body_GetMass(body_id);
	}
	return 0.0;
}

void Box3DBody::teleport(const Transform3D &p_xform) {
	// Reposition the body instantly (respawn / reset), clearing momentum so it
	// starts at rest. Unlike a kinematic move this doesn't sweep through the
	// world, so don't teleport into overlapping geometry.
	set_global_transform(p_xform);
	// With physics interpolation on, an instant jump must not be smeared
	// across the render frame.
	reset_physics_interpolation();
	if (b3Body_IsValid(body_id)) {
		b3Body_SetTransform(body_id, to_b3_pos(p_xform.origin),
				to_b3(p_xform.basis.get_rotation_quaternion()));
		b3Body_SetLinearVelocity(body_id, to_b3(Vector3()));
		b3Body_SetAngularVelocity(body_id, to_b3(Vector3()));
		b3Body_SetAwake(body_id, true);
	}
}

// --- Properties ---

void Box3DBody::set_body_type(int p_type) {
	body_type = (BodyType)p_type;
	rebuild_if_alive();
}

int Box3DBody::get_body_type() const {
	return (int)body_type;
}

void Box3DBody::set_shape_type(int p_type) {
	shape_type = (ShapeType)p_type;
	rebuild_if_alive();
}

int Box3DBody::get_shape_type() const {
	return (int)shape_type;
}

void Box3DBody::set_box_size(const Vector3 &p_size) {
	box_size = p_size;
	rebuild_if_alive();
}

Vector3 Box3DBody::get_box_size() const {
	return box_size;
}

void Box3DBody::set_sphere_radius(double p_radius) {
	sphere_radius = p_radius;
	rebuild_if_alive();
}

double Box3DBody::get_sphere_radius() const {
	return sphere_radius;
}

void Box3DBody::set_capsule_radius(double p_radius) {
	capsule_radius = p_radius;
	rebuild_if_alive();
}

double Box3DBody::get_capsule_radius() const {
	return capsule_radius;
}

void Box3DBody::set_capsule_height(double p_height) {
	capsule_height = p_height;
	rebuild_if_alive();
}

double Box3DBody::get_capsule_height() const {
	return capsule_height;
}

void Box3DBody::set_cylinder_sides(int p_sides) {
	cylinder_sides = p_sides < 3 ? 3 : p_sides;
	rebuild_if_alive();
}

int Box3DBody::get_cylinder_sides() const {
	return cylinder_sides;
}

void Box3DBody::set_collision_mesh(const Ref<Mesh> &p_mesh) {
	collision_mesh = p_mesh;
	rebuild_if_alive();
}

Ref<Mesh> Box3DBody::get_collision_mesh() const {
	return collision_mesh;
}

void Box3DBody::set_density(double p_density) {
	density = p_density;
	rebuild_if_alive();
}

double Box3DBody::get_density() const {
	return density;
}

void Box3DBody::set_friction(double p_friction) {
	friction = p_friction;
	rebuild_if_alive();
}

double Box3DBody::get_friction() const {
	return friction;
}

void Box3DBody::set_restitution(double p_restitution) {
	restitution = p_restitution;
	rebuild_if_alive();
}

double Box3DBody::get_restitution() const {
	return restitution;
}

void Box3DBody::set_linear_damping(double p_damping) {
	linear_damping = p_damping;
	if (b3Body_IsValid(body_id)) {
		b3Body_SetLinearDamping(body_id, (float)linear_damping);
	}
}

double Box3DBody::get_linear_damping() const {
	return linear_damping;
}

void Box3DBody::set_angular_damping(double p_damping) {
	angular_damping = p_damping;
	rebuild_if_alive();
}

double Box3DBody::get_angular_damping() const {
	return angular_damping;
}

void Box3DBody::set_gravity_scale(double p_scale) {
	gravity_scale = p_scale;
	rebuild_if_alive();
}

double Box3DBody::get_gravity_scale() const {
	return gravity_scale;
}

void Box3DBody::set_contact_monitor(bool p_enabled) {
	contact_monitor = p_enabled;
	rebuild_if_alive();
}

bool Box3DBody::get_contact_monitor() const {
	return contact_monitor;
}

void Box3DBody::set_is_sensor(bool p_sensor) {
	is_sensor = p_sensor;
	rebuild_if_alive();
}

bool Box3DBody::get_is_sensor() const {
	return is_sensor;
}

void Box3DBody::set_debug_visualize(bool p_enabled) {
	debug_visualize = p_enabled;
}

bool Box3DBody::get_debug_visualize() const {
	return debug_visualize;
}

float Box3DBody::debug_max_extent() const {
	// Distance from the body origin to its farthest collider point, mirroring
	// upstream's sim->maxExtent (rotation's contribution to the fast check).
	bool has_child_shapes = false;
	float max_extent = 0.0f;
	for (int i = 0; i < get_child_count(); ++i) {
		Box3DCollisionShape *cs = Object::cast_to<Box3DCollisionShape>(get_child(i));
		if (cs == nullptr) {
			continue;
		}
		has_child_shapes = true;
		float e = 0.0f;
		switch (cs->get_shape_type()) {
			case Box3DCollisionShape::SPHERE:
				e = (float)cs->get_sphere_radius();
				break;
			case Box3DCollisionShape::CAPSULE:
				e = (float)cs->get_capsule_height() * 0.5f;
				break;
			case Box3DCollisionShape::BOX:
			default:
				e = (float)(cs->get_box_size() * 0.5).length();
				break;
		}
		max_extent = MAX(max_extent, (float)cs->get_position().length() + e);
	}
	if (has_child_shapes) {
		return max_extent;
	}
	switch (shape_type) {
		case SPHERE:
			return (float)sphere_radius;
		case CAPSULE:
		case CYLINDER:
		case CONE: {
			float half_h = (float)capsule_height * 0.5f;
			float r = (float)capsule_radius;
			return Math::sqrt(half_h * half_h + r * r);
		}
		case BOX:
		case FIT_MESH:
			return (float)(box_size * 0.5).length();
		default:
			return 0.0f; // hull/mesh: no rotation contribution
	}
}

float Box3DBody::debug_min_extent() const {
	// Smallest half-extent of the collider, mirroring upstream's sim->minExtent
	// (used by its "fast body" debug state). Child shapes take over for
	// compounds, exactly like collision creation does.
	bool has_child_shapes = false;
	float min_extent = 1e9f;
	for (int i = 0; i < get_child_count(); ++i) {
		Box3DCollisionShape *cs = Object::cast_to<Box3DCollisionShape>(get_child(i));
		if (cs == nullptr) {
			continue;
		}
		has_child_shapes = true;
		float e = 1e9f;
		switch (cs->get_shape_type()) {
			case Box3DCollisionShape::SPHERE:
				e = (float)cs->get_sphere_radius();
				break;
			case Box3DCollisionShape::CAPSULE:
				e = (float)cs->get_capsule_radius();
				break;
			case Box3DCollisionShape::BOX:
			default: {
				Vector3 half = cs->get_box_size() * 0.5;
				e = (float)MIN(half.x, MIN(half.y, half.z));
			} break;
		}
		min_extent = MIN(min_extent, e);
	}
	if (has_child_shapes) {
		return min_extent;
	}
	switch (shape_type) {
		case SPHERE:
			return (float)sphere_radius;
		case CAPSULE:
			return (float)capsule_radius;
		case CYLINDER:
		case CONE:
			return MIN((float)capsule_radius, (float)capsule_height * 0.5f);
		case BOX:
		case FIT_MESH: {
			Vector3 half = box_size * 0.5;
			return (float)MIN(half.x, MIN(half.y, half.z));
		}
		default:
			return 1e9f; // hull/mesh: never flagged fast
	}
}

void Box3DBody::set_continuous(bool p_enabled) {
	continuous = p_enabled;
	if (b3Body_IsValid(body_id)) {
		b3Body_SetBullet(body_id, p_enabled);
	}
}

bool Box3DBody::get_continuous() const {
	return continuous;
}

void Box3DBody::set_allow_fast_rotation(bool p_enabled) {
	allow_fast_rotation = p_enabled;
	rebuild_if_alive();
}

bool Box3DBody::get_allow_fast_rotation() const {
	return allow_fast_rotation;
}

void Box3DBody::set_lock_linear_x(bool p_v) { lock_linear_x = p_v; apply_motion_locks(); }
bool Box3DBody::get_lock_linear_x() const { return lock_linear_x; }
void Box3DBody::set_lock_linear_y(bool p_v) { lock_linear_y = p_v; apply_motion_locks(); }
bool Box3DBody::get_lock_linear_y() const { return lock_linear_y; }
void Box3DBody::set_lock_linear_z(bool p_v) { lock_linear_z = p_v; apply_motion_locks(); }
bool Box3DBody::get_lock_linear_z() const { return lock_linear_z; }
void Box3DBody::set_lock_angular_x(bool p_v) { lock_angular_x = p_v; apply_motion_locks(); }
bool Box3DBody::get_lock_angular_x() const { return lock_angular_x; }
void Box3DBody::set_lock_angular_y(bool p_v) { lock_angular_y = p_v; apply_motion_locks(); }
bool Box3DBody::get_lock_angular_y() const { return lock_angular_y; }
void Box3DBody::set_lock_angular_z(bool p_v) { lock_angular_z = p_v; apply_motion_locks(); }
bool Box3DBody::get_lock_angular_z() const { return lock_angular_z; }

void Box3DBody::set_collision_layer(int p_layer) {
	collision_layer = (uint32_t)p_layer;
	rebuild_if_alive();
}

int Box3DBody::get_collision_layer() const {
	return (int)collision_layer;
}

void Box3DBody::set_collision_mask(int p_mask) {
	collision_mask = (uint32_t)p_mask;
	rebuild_if_alive();
}

int Box3DBody::get_collision_mask() const {
	return (int)collision_mask;
}

void Box3DBody::set_auto_visual(bool p_enabled) {
	auto_visual = p_enabled;
	update_auto_visual();
}

bool Box3DBody::get_auto_visual() const {
	return auto_visual;
}

void Box3DBody::_bind_methods() {
	ClassDB::bind_method(D_METHOD("apply_central_force", "force"), &Box3DBody::apply_central_force);
	ClassDB::bind_method(D_METHOD("apply_central_impulse", "impulse"), &Box3DBody::apply_central_impulse);
	ClassDB::bind_method(D_METHOD("apply_torque", "torque"), &Box3DBody::apply_torque);
	ClassDB::bind_method(D_METHOD("set_linear_velocity", "velocity"), &Box3DBody::set_linear_velocity);
	ClassDB::bind_method(D_METHOD("get_linear_velocity"), &Box3DBody::get_linear_velocity);
	ClassDB::bind_method(D_METHOD("set_angular_velocity", "velocity"), &Box3DBody::set_angular_velocity);
	ClassDB::bind_method(D_METHOD("get_angular_velocity"), &Box3DBody::get_angular_velocity);
	ClassDB::bind_method(D_METHOD("get_mass"), &Box3DBody::get_mass);
	ClassDB::bind_method(D_METHOD("teleport", "transform"), &Box3DBody::teleport);

	ClassDB::bind_method(D_METHOD("set_body_type", "type"), &Box3DBody::set_body_type);
	ClassDB::bind_method(D_METHOD("get_body_type"), &Box3DBody::get_body_type);
	ClassDB::bind_method(D_METHOD("set_shape_type", "type"), &Box3DBody::set_shape_type);
	ClassDB::bind_method(D_METHOD("get_shape_type"), &Box3DBody::get_shape_type);
	ClassDB::bind_method(D_METHOD("set_box_size", "size"), &Box3DBody::set_box_size);
	ClassDB::bind_method(D_METHOD("get_box_size"), &Box3DBody::get_box_size);
	ClassDB::bind_method(D_METHOD("set_sphere_radius", "radius"), &Box3DBody::set_sphere_radius);
	ClassDB::bind_method(D_METHOD("get_sphere_radius"), &Box3DBody::get_sphere_radius);
	ClassDB::bind_method(D_METHOD("set_capsule_radius", "radius"), &Box3DBody::set_capsule_radius);
	ClassDB::bind_method(D_METHOD("get_capsule_radius"), &Box3DBody::get_capsule_radius);
	ClassDB::bind_method(D_METHOD("set_capsule_height", "height"), &Box3DBody::set_capsule_height);
	ClassDB::bind_method(D_METHOD("get_capsule_height"), &Box3DBody::get_capsule_height);
	ClassDB::bind_method(D_METHOD("set_cylinder_sides", "sides"), &Box3DBody::set_cylinder_sides);
	ClassDB::bind_method(D_METHOD("get_cylinder_sides"), &Box3DBody::get_cylinder_sides);
	ClassDB::bind_method(D_METHOD("set_collision_mesh", "mesh"), &Box3DBody::set_collision_mesh);
	ClassDB::bind_method(D_METHOD("get_collision_mesh"), &Box3DBody::get_collision_mesh);
	ClassDB::bind_method(D_METHOD("set_density", "density"), &Box3DBody::set_density);
	ClassDB::bind_method(D_METHOD("get_density"), &Box3DBody::get_density);
	ClassDB::bind_method(D_METHOD("set_friction", "friction"), &Box3DBody::set_friction);
	ClassDB::bind_method(D_METHOD("get_friction"), &Box3DBody::get_friction);
	ClassDB::bind_method(D_METHOD("set_restitution", "restitution"), &Box3DBody::set_restitution);
	ClassDB::bind_method(D_METHOD("get_restitution"), &Box3DBody::get_restitution);
	ClassDB::bind_method(D_METHOD("set_linear_damping", "damping"), &Box3DBody::set_linear_damping);
	ClassDB::bind_method(D_METHOD("get_linear_damping"), &Box3DBody::get_linear_damping);
	ClassDB::bind_method(D_METHOD("set_angular_damping", "damping"), &Box3DBody::set_angular_damping);
	ClassDB::bind_method(D_METHOD("get_angular_damping"), &Box3DBody::get_angular_damping);
	ClassDB::bind_method(D_METHOD("set_gravity_scale", "scale"), &Box3DBody::set_gravity_scale);
	ClassDB::bind_method(D_METHOD("get_gravity_scale"), &Box3DBody::get_gravity_scale);
	ClassDB::bind_method(D_METHOD("set_contact_monitor", "enabled"), &Box3DBody::set_contact_monitor);
	ClassDB::bind_method(D_METHOD("get_contact_monitor"), &Box3DBody::get_contact_monitor);
	ClassDB::bind_method(D_METHOD("set_is_sensor", "sensor"), &Box3DBody::set_is_sensor);
	ClassDB::bind_method(D_METHOD("get_is_sensor"), &Box3DBody::get_is_sensor);
	ClassDB::bind_method(D_METHOD("set_debug_visualize", "enabled"), &Box3DBody::set_debug_visualize);
	ClassDB::bind_method(D_METHOD("get_debug_visualize"), &Box3DBody::get_debug_visualize);
	ClassDB::bind_method(D_METHOD("set_continuous", "enabled"), &Box3DBody::set_continuous);
	ClassDB::bind_method(D_METHOD("get_continuous"), &Box3DBody::get_continuous);
	ClassDB::bind_method(D_METHOD("set_allow_fast_rotation", "enabled"), &Box3DBody::set_allow_fast_rotation);
	ClassDB::bind_method(D_METHOD("get_allow_fast_rotation"), &Box3DBody::get_allow_fast_rotation);
	ClassDB::bind_method(D_METHOD("set_lock_linear_x", "enabled"), &Box3DBody::set_lock_linear_x);
	ClassDB::bind_method(D_METHOD("get_lock_linear_x"), &Box3DBody::get_lock_linear_x);
	ClassDB::bind_method(D_METHOD("set_lock_linear_y", "enabled"), &Box3DBody::set_lock_linear_y);
	ClassDB::bind_method(D_METHOD("get_lock_linear_y"), &Box3DBody::get_lock_linear_y);
	ClassDB::bind_method(D_METHOD("set_lock_linear_z", "enabled"), &Box3DBody::set_lock_linear_z);
	ClassDB::bind_method(D_METHOD("get_lock_linear_z"), &Box3DBody::get_lock_linear_z);
	ClassDB::bind_method(D_METHOD("set_lock_angular_x", "enabled"), &Box3DBody::set_lock_angular_x);
	ClassDB::bind_method(D_METHOD("get_lock_angular_x"), &Box3DBody::get_lock_angular_x);
	ClassDB::bind_method(D_METHOD("set_lock_angular_y", "enabled"), &Box3DBody::set_lock_angular_y);
	ClassDB::bind_method(D_METHOD("get_lock_angular_y"), &Box3DBody::get_lock_angular_y);
	ClassDB::bind_method(D_METHOD("set_lock_angular_z", "enabled"), &Box3DBody::set_lock_angular_z);
	ClassDB::bind_method(D_METHOD("get_lock_angular_z"), &Box3DBody::get_lock_angular_z);
	ClassDB::bind_method(D_METHOD("set_collision_layer", "layer"), &Box3DBody::set_collision_layer);
	ClassDB::bind_method(D_METHOD("get_collision_layer"), &Box3DBody::get_collision_layer);
	ClassDB::bind_method(D_METHOD("set_collision_mask", "mask"), &Box3DBody::set_collision_mask);
	ClassDB::bind_method(D_METHOD("get_collision_mask"), &Box3DBody::get_collision_mask);
	ClassDB::bind_method(D_METHOD("set_auto_visual", "enabled"), &Box3DBody::set_auto_visual);
	ClassDB::bind_method(D_METHOD("get_auto_visual"), &Box3DBody::get_auto_visual);

	ADD_PROPERTY(PropertyInfo(Variant::INT, "body_type", PROPERTY_HINT_ENUM, "Static,Kinematic,Dynamic"), "set_body_type", "get_body_type");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "shape_type", PROPERTY_HINT_ENUM, "Box,Sphere,Capsule,Cylinder,Cone,Hull,Mesh,Fit Mesh"), "set_shape_type", "get_shape_type");
	ADD_PROPERTY(PropertyInfo(Variant::VECTOR3, "box_size"), "set_box_size", "get_box_size");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "sphere_radius", PROPERTY_HINT_RANGE, "0.01,100,0.01,or_greater"), "set_sphere_radius", "get_sphere_radius");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "capsule_radius", PROPERTY_HINT_RANGE, "0.01,100,0.01,or_greater"), "set_capsule_radius", "get_capsule_radius");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "capsule_height", PROPERTY_HINT_RANGE, "0.02,100,0.01,or_greater"), "set_capsule_height", "get_capsule_height");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "cylinder_sides", PROPERTY_HINT_RANGE, "3,64,1"), "set_cylinder_sides", "get_cylinder_sides");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "collision_mesh", PROPERTY_HINT_RESOURCE_TYPE, "Mesh"), "set_collision_mesh", "get_collision_mesh");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "auto_visual"), "set_auto_visual", "get_auto_visual");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "density", PROPERTY_HINT_RANGE, "0.01,100,0.01,or_greater"), "set_density", "get_density");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "friction", PROPERTY_HINT_RANGE, "0,1,0.01,or_greater"), "set_friction", "get_friction");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "restitution", PROPERTY_HINT_RANGE, "0,1,0.01"), "set_restitution", "get_restitution");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "linear_damping", PROPERTY_HINT_RANGE, "0,10,0.01,or_greater"), "set_linear_damping", "get_linear_damping");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "angular_damping", PROPERTY_HINT_RANGE, "0,10,0.01,or_greater"), "set_angular_damping", "get_angular_damping");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "gravity_scale", PROPERTY_HINT_RANGE, "-10,10,0.01"), "set_gravity_scale", "get_gravity_scale");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "contact_monitor"), "set_contact_monitor", "get_contact_monitor");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "is_sensor"), "set_is_sensor", "get_is_sensor");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "debug_visualize"), "set_debug_visualize", "get_debug_visualize");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "continuous"), "set_continuous", "get_continuous");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "allow_fast_rotation"), "set_allow_fast_rotation", "get_allow_fast_rotation");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "collision_layer", PROPERTY_HINT_LAYERS_3D_PHYSICS), "set_collision_layer", "get_collision_layer");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "collision_mask", PROPERTY_HINT_LAYERS_3D_PHYSICS), "set_collision_mask", "get_collision_mask");

	ADD_GROUP("Axis Lock", "lock_");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "lock_linear_x"), "set_lock_linear_x", "get_lock_linear_x");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "lock_linear_y"), "set_lock_linear_y", "get_lock_linear_y");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "lock_linear_z"), "set_lock_linear_z", "get_lock_linear_z");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "lock_angular_x"), "set_lock_angular_x", "get_lock_angular_x");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "lock_angular_y"), "set_lock_angular_y", "get_lock_angular_y");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "lock_angular_z"), "set_lock_angular_z", "get_lock_angular_z");

	ADD_SIGNAL(MethodInfo("body_entered", PropertyInfo(Variant::OBJECT, "body", PROPERTY_HINT_RESOURCE_TYPE, "Box3DBody")));
	ADD_SIGNAL(MethodInfo("body_exited", PropertyInfo(Variant::OBJECT, "body", PROPERTY_HINT_RESOURCE_TYPE, "Box3DBody")));
	ADD_SIGNAL(MethodInfo("area_entered", PropertyInfo(Variant::OBJECT, "visitor", PROPERTY_HINT_RESOURCE_TYPE, "Box3DBody")));
	ADD_SIGNAL(MethodInfo("area_exited", PropertyInfo(Variant::OBJECT, "visitor", PROPERTY_HINT_RESOURCE_TYPE, "Box3DBody")));

	BIND_ENUM_CONSTANT(STATIC);
	BIND_ENUM_CONSTANT(KINEMATIC);
	BIND_ENUM_CONSTANT(DYNAMIC);
	BIND_ENUM_CONSTANT(BOX);
	BIND_ENUM_CONSTANT(SPHERE);
	BIND_ENUM_CONSTANT(CAPSULE);
	BIND_ENUM_CONSTANT(CYLINDER);
	BIND_ENUM_CONSTANT(CONE);
	BIND_ENUM_CONSTANT(HULL);
	BIND_ENUM_CONSTANT(MESH);
	BIND_ENUM_CONSTANT(FIT_MESH);
}
