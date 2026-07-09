// SPDX-FileCopyrightText: 2026 box3d-godot contributors
// SPDX-License-Identifier: MIT

#pragma once

#include <godot_cpp/classes/node3d.hpp>

#include <box3d/box3d.h>

namespace godot {

class Box3DWorld;

// A kinematic capsule character controller. Unlike Box3DBody it is not a
// simulated body; it queries the nearest Box3DWorld's mover functions to slide
// a capsule along the world. Drive it with move_and_slide() each frame.
class Box3DCharacterBody : public Node3D {
	GDCLASS(Box3DCharacterBody, Node3D)

	double radius = 0.4;
	double height = 1.8; // total capsule height
	uint32_t collision_mask = 0xFFFFFFFFu;

	Box3DWorld *find_world();

protected:
	static void _bind_methods();

public:
	// Move by velocity*delta, sliding along and stopping at world geometry.
	// Returns the actual resulting velocity (may differ after sliding).
	Vector3 move_and_slide(const Vector3 &p_velocity, double p_delta);

	void set_radius(double p_radius);
	double get_radius() const;
	void set_height(double p_height);
	double get_height() const;
	void set_collision_mask(int p_mask);
	int get_collision_mask() const;
};

} // namespace godot
