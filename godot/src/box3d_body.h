// SPDX-FileCopyrightText: 2026 box3d-godot contributors
// SPDX-License-Identifier: MIT

#pragma once

#include <godot_cpp/classes/mesh.hpp>
#include <godot_cpp/classes/node3d.hpp>

#include <box3d/box3d.h>

namespace godot {

class Box3DWorld;
class Box3DCollisionShape;
class MeshInstance3D;

// A rigid body simulated by the nearest Box3DWorld ancestor. The node's
// transform is driven by the simulation for dynamic bodies, and drives the
// simulation for kinematic bodies. Attach a MeshInstance3D child for visuals.
class Box3DBody : public Node3D {
	GDCLASS(Box3DBody, Node3D)

public:
	enum BodyType {
		STATIC = 0,
		KINEMATIC = 1,
		DYNAMIC = 2,
	};

	enum ShapeType {
		BOX = 0,
		SPHERE = 1,
		CAPSULE = 2,
		CYLINDER = 3,
		CONE = 4,
		HULL = 5,
		MESH = 6,
		FIT_MESH = 7, // box collider auto-sized to the child MeshInstance3D's bounds
	};

private:
	b3BodyId body_id = b3_nullBodyId;
	// A triangle-mesh shape references this data (Box3D does not copy it), so it
	// must outlive the shape; freed in destroy_body().
	b3MeshData *mesh_data = nullptr;
	Box3DWorld *world = nullptr;

	BodyType body_type = DYNAMIC;
	ShapeType shape_type = BOX;
	Vector3 box_size = Vector3(1, 1, 1); // full extents
	double sphere_radius = 0.5;
	double capsule_radius = 0.5;
	double capsule_height = 2.0; // total height, including the two caps
	// Cylinder and cone reuse capsule_radius / capsule_height. Sides sets their
	// tessellation (they are built as convex hulls).
	int cylinder_sides = 16;
	Ref<Mesh> collision_mesh; // convex hull is built from this mesh's vertices
	double density = 1.0;
	double friction = 0.6;
	double restitution = 0.0;
	double linear_damping = 0.0;
	double angular_damping = 0.05;
	double gravity_scale = 1.0;
	bool contact_monitor = false;
	bool is_sensor = false;
	bool continuous = false; // continuous collision (bullet)
	bool allow_fast_rotation = false;
	bool lock_linear_x = false;
	bool lock_linear_y = false;
	bool lock_linear_z = false;
	bool lock_angular_x = false;
	bool lock_angular_y = false;
	bool lock_angular_z = false;
	uint32_t collision_layer = 1;
	uint32_t collision_mask = 0xFFFFFFFFu;
	// When true and no MeshInstance3D child is present, a MeshInstance3D is
	// generated at runtime whose mesh mirrors the collision shape (box/sphere/
	// capsule/cylinder/cone), so box_size/sphere_radius/etc. drive both the
	// collider and the visual from one place. Default false for backward
	// compatibility with existing scenes.
	bool auto_visual = false;
	// The node auto_visual generates; nullptr when there is none (auto_visual
	// is off, or the body already has its own MeshInstance3D child).
	MeshInstance3D *auto_mesh_instance = nullptr;

	Box3DWorld *find_world();
	void rebuild_if_alive();
	void apply_motion_locks();
	void create_child_shape(Box3DCollisionShape *p_shape, const Transform3D &p_body_inv);
	// Mesh used for Hull/Mesh/FitMesh colliders: an explicit collision_mesh (at
	// identity), else the first child MeshInstance3D's mesh (at its local
	// transform). Returns false if neither is available.
	bool resolve_collision_mesh(Ref<Mesh> &r_mesh, Transform3D &r_local);
	// Creates/updates/removes auto_mesh_instance to match auto_visual and the
	// current shape_type/size. No-op in the editor (runtime feature only).
	void update_auto_visual();

protected:
	static void _bind_methods();
	void _notification(int p_what);

public:
	Box3DBody();
	~Box3DBody();

	// Internal, called by the owning world / node lifecycle.
	void create_in_world();
	void destroy_body();
	void request_rebuild(); // called by child Box3DCollisionShape nodes
	void sync_to_physics(double p_delta);
	void sync_from_physics();
	bool is_body_valid() const;
	b3BodyId get_body_id() const { return body_id; }

	// Called by the world when it dispatches contact / sensor events.
	void emit_contact_begin(Box3DBody *p_other);
	void emit_contact_end(Box3DBody *p_other);
	void emit_area_begin(Box3DBody *p_visitor);
	void emit_area_end(Box3DBody *p_visitor);

	// Scripting API.
	void apply_central_force(const Vector3 &p_force);
	void apply_central_impulse(const Vector3 &p_impulse);
	void apply_torque(const Vector3 &p_torque);
	void set_linear_velocity(const Vector3 &p_velocity);
	Vector3 get_linear_velocity() const;
	void set_angular_velocity(const Vector3 &p_velocity);
	Vector3 get_angular_velocity() const;
	double get_mass() const;
	void teleport(const Transform3D &p_xform);

	// Properties.
	void set_body_type(int p_type);
	int get_body_type() const;
	void set_shape_type(int p_type);
	int get_shape_type() const;
	void set_box_size(const Vector3 &p_size);
	Vector3 get_box_size() const;
	void set_sphere_radius(double p_radius);
	double get_sphere_radius() const;
	void set_capsule_radius(double p_radius);
	double get_capsule_radius() const;
	void set_capsule_height(double p_height);
	double get_capsule_height() const;
	void set_cylinder_sides(int p_sides);
	int get_cylinder_sides() const;
	void set_collision_mesh(const Ref<Mesh> &p_mesh);
	Ref<Mesh> get_collision_mesh() const;
	void set_density(double p_density);
	double get_density() const;
	void set_friction(double p_friction);
	double get_friction() const;
	void set_restitution(double p_restitution);
	double get_restitution() const;
	void set_linear_damping(double p_damping);
	double get_linear_damping() const;
	void set_angular_damping(double p_damping);
	double get_angular_damping() const;
	void set_gravity_scale(double p_scale);
	double get_gravity_scale() const;
	void set_contact_monitor(bool p_enabled);
	bool get_contact_monitor() const;
	void set_is_sensor(bool p_sensor);
	bool get_is_sensor() const;
	void set_continuous(bool p_enabled);
	bool get_continuous() const;
	void set_allow_fast_rotation(bool p_enabled);
	bool get_allow_fast_rotation() const;
	void set_lock_linear_x(bool p_v);
	bool get_lock_linear_x() const;
	void set_lock_linear_y(bool p_v);
	bool get_lock_linear_y() const;
	void set_lock_linear_z(bool p_v);
	bool get_lock_linear_z() const;
	void set_lock_angular_x(bool p_v);
	bool get_lock_angular_x() const;
	void set_lock_angular_y(bool p_v);
	bool get_lock_angular_y() const;
	void set_lock_angular_z(bool p_v);
	bool get_lock_angular_z() const;
	void set_collision_layer(int p_layer);
	int get_collision_layer() const;
	void set_collision_mask(int p_mask);
	int get_collision_mask() const;
	void set_auto_visual(bool p_enabled);
	bool get_auto_visual() const;
};

} // namespace godot

VARIANT_ENUM_CAST(godot::Box3DBody::BodyType);
VARIANT_ENUM_CAST(godot::Box3DBody::ShapeType);
