// SPDX-FileCopyrightText: 2026 box3d-godot contributors
// SPDX-License-Identifier: MIT

#include "box3d_collision_shape.h"

#include "box3d_body.h"

#include <godot_cpp/core/class_db.hpp>

using namespace godot;

void Box3DCollisionShape::notify_parent() {
	Box3DBody *body = Object::cast_to<Box3DBody>(get_parent());
	if (body != nullptr) {
		body->request_rebuild();
	}
}

void Box3DCollisionShape::_notification(int p_what) {
	if (p_what == NOTIFICATION_PARENTED || p_what == NOTIFICATION_UNPARENTED) {
		notify_parent();
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
	notify_parent();
}

Vector3 Box3DCollisionShape::get_box_size() const {
	return box_size;
}

void Box3DCollisionShape::set_sphere_radius(double p_radius) {
	sphere_radius = p_radius;
	notify_parent();
}

double Box3DCollisionShape::get_sphere_radius() const {
	return sphere_radius;
}

void Box3DCollisionShape::set_capsule_radius(double p_radius) {
	capsule_radius = p_radius;
	notify_parent();
}

double Box3DCollisionShape::get_capsule_radius() const {
	return capsule_radius;
}

void Box3DCollisionShape::set_capsule_height(double p_height) {
	capsule_height = p_height;
	notify_parent();
}

double Box3DCollisionShape::get_capsule_height() const {
	return capsule_height;
}

void Box3DCollisionShape::set_density(double p_density) {
	density = p_density;
	notify_parent();
}

double Box3DCollisionShape::get_density() const {
	return density;
}

void Box3DCollisionShape::set_friction(double p_friction) {
	friction = p_friction;
	notify_parent();
}

double Box3DCollisionShape::get_friction() const {
	return friction;
}

void Box3DCollisionShape::set_restitution(double p_restitution) {
	restitution = p_restitution;
	notify_parent();
}

double Box3DCollisionShape::get_restitution() const {
	return restitution;
}

void Box3DCollisionShape::_bind_methods() {
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
	ClassDB::bind_method(D_METHOD("set_density", "density"), &Box3DCollisionShape::set_density);
	ClassDB::bind_method(D_METHOD("get_density"), &Box3DCollisionShape::get_density);
	ClassDB::bind_method(D_METHOD("set_friction", "friction"), &Box3DCollisionShape::set_friction);
	ClassDB::bind_method(D_METHOD("get_friction"), &Box3DCollisionShape::get_friction);
	ClassDB::bind_method(D_METHOD("set_restitution", "restitution"), &Box3DCollisionShape::set_restitution);
	ClassDB::bind_method(D_METHOD("get_restitution"), &Box3DCollisionShape::get_restitution);

	ADD_PROPERTY(PropertyInfo(Variant::INT, "shape_type", PROPERTY_HINT_ENUM, "Box,Sphere,Capsule"), "set_shape_type", "get_shape_type");
	ADD_PROPERTY(PropertyInfo(Variant::VECTOR3, "box_size"), "set_box_size", "get_box_size");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "sphere_radius", PROPERTY_HINT_RANGE, "0.01,100,0.01,or_greater"), "set_sphere_radius", "get_sphere_radius");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "capsule_radius", PROPERTY_HINT_RANGE, "0.01,100,0.01,or_greater"), "set_capsule_radius", "get_capsule_radius");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "capsule_height", PROPERTY_HINT_RANGE, "0.02,100,0.01,or_greater"), "set_capsule_height", "get_capsule_height");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "density", PROPERTY_HINT_RANGE, "0.01,100,0.01,or_greater"), "set_density", "get_density");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "friction", PROPERTY_HINT_RANGE, "0,1,0.01,or_greater"), "set_friction", "get_friction");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "restitution", PROPERTY_HINT_RANGE, "0,1,0.01"), "set_restitution", "get_restitution");

	BIND_ENUM_CONSTANT(BOX);
	BIND_ENUM_CONSTANT(SPHERE);
	BIND_ENUM_CONSTANT(CAPSULE);
}
