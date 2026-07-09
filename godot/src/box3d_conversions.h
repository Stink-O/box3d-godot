// SPDX-FileCopyrightText: 2026 box3d-godot contributors
// SPDX-License-Identifier: MIT
//
// Conversions between Godot math types and Box3D math types.
// Box3D has no built-in up-axis; we map coordinates 1:1 with Godot (Y-up,
// right-handed) so no axis swizzle is needed.

#pragma once

#include <godot_cpp/variant/basis.hpp>
#include <godot_cpp/variant/quaternion.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <box3d/box3d.h>

namespace godot {

inline b3Vec3 to_b3(const Vector3 &v) {
	return b3Vec3{ (float)v.x, (float)v.y, (float)v.z };
}

// b3Pos is a distinct type only in double-precision builds; this constructs it
// correctly in both single and double precision.
inline b3Pos to_b3_pos(const Vector3 &v) {
	b3Pos p;
	p.x = v.x;
	p.y = v.y;
	p.z = v.z;
	return p;
}

inline Vector3 to_gd(const b3Vec3 &v) {
	return Vector3((real_t)v.x, (real_t)v.y, (real_t)v.z);
}

inline Vector3 to_gd_pos(const b3Pos &p) {
	return Vector3((real_t)p.x, (real_t)p.y, (real_t)p.z);
}

// Godot Quaternion is (x, y, z, w); Box3D b3Quat is { b3Vec3 v; float s }.
inline b3Quat to_b3(const Quaternion &q) {
	b3Quat r;
	r.v = b3Vec3{ (float)q.x, (float)q.y, (float)q.z };
	r.s = (float)q.w;
	return r;
}

inline Quaternion to_gd(const b3Quat &q) {
	return Quaternion((real_t)q.v.x, (real_t)q.v.y, (real_t)q.v.z, (real_t)q.s);
}

// A local (non-world) rigid transform: position + rotation. Used for joint frames.
inline b3Transform to_b3_transform(const Transform3D &t) {
	b3Transform bt;
	bt.p = to_b3(t.origin);
	bt.q = to_b3(t.basis.get_rotation_quaternion());
	return bt;
}

} // namespace godot
