// SPDX-FileCopyrightText: 2026 box3d-godot contributors
// SPDX-License-Identifier: MIT

#pragma once

#include <godot_cpp/classes/multi_mesh.hpp>
#include <godot_cpp/classes/multi_mesh_instance3d.hpp>
#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>

#include <box3d/box3d.h>

#include <vector>

namespace godot {

class Box3DBody;
class Box3DWorld;

// Renders every Box3DBody child as one instance of a single MultiMesh — one
// draw call for any number of bodies. The per-frame transform sync happens in
// C++ straight from the solver's tick snapshots (interpolated to render time)
// and is uploaded as one bulk buffer, so scenes with tens of thousands of
// bodies pay no per-node scripting cost to render. This is the C++ successor
// to demo/common/cube_grid_multimesh.gd, built for the Huge Pyramid.
//
// Bodies must share one shape/size (the MultiMesh draws one mesh); the box
// mesh is auto-built from the first body's box_size. Instances are tinted
// with the same continuous pastel hues as the GDScript version.
class Box3DMultiMeshRenderer : public Node3D {
	GDCLASS(Box3DMultiMeshRenderer, Node3D)

	std::vector<Box3DBody *> bodies;
	Ref<MultiMesh> multimesh;
	MultiMeshInstance3D *mmi = nullptr;
	PackedFloat32Array buffer;
	Box3DWorld *world = nullptr; // parent world, for the debug-draw hide

	void build();
	void update_instances();

protected:
	static void _bind_methods();
	void _notification(int p_what);
};

} // namespace godot
