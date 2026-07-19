// SPDX-FileCopyrightText: 2026 box3d-godot contributors
// SPDX-License-Identifier: MIT

#pragma once

#include <godot_cpp/classes/node3d.hpp>

namespace godot {

class Box3DBody;

// One shape of a compound Box3DBody. Add these as children of a Box3DBody to
// give it multiple shapes at different local transforms. If a body has no
// Box3DCollisionShape children it falls back to its own shape_type.
class Box3DCollisionShape : public Node3D {
	GDCLASS(Box3DCollisionShape, Node3D)

public:
	enum ShapeType {
		BOX = 0,
		SPHERE = 1,
		CAPSULE = 2,
		CYLINDER = 3, // capsule_radius / capsule_height, tessellated by sides
		CONE = 4, // base radius capsule_radius, height capsule_height, apex up
	};

private:
	ShapeType shape_type = BOX;
	Vector3 box_size = Vector3(1, 1, 1);
	double sphere_radius = 0.5;
	double capsule_radius = 0.5;
	double capsule_height = 2.0;
	int sides = 16; // hull tessellation for CYLINDER / CONE
	double density = 1.0;
	double friction = 0.6;
	double restitution = 0.0;

	void notify_parent();

protected:
	static void _bind_methods();
	void _notification(int p_what);

public:
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
	void set_sides(int p_sides);
	int get_sides() const;
	void set_density(double p_density);
	double get_density() const;
	void set_friction(double p_friction);
	double get_friction() const;
	void set_restitution(double p_restitution);
	double get_restitution() const;
};

} // namespace godot

VARIANT_ENUM_CAST(godot::Box3DCollisionShape::ShapeType);
