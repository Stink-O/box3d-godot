// SPDX-FileCopyrightText: 2026 box3d-godot contributors
// SPDX-License-Identifier: MIT

#include "box3d_multimesh_renderer.h"

#include "box3d_body.h"
#include "box3d_conversions.h"
#include "box3d_world.h"

#include <godot_cpp/classes/box_mesh.hpp>
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/mesh_instance3d.hpp>
#include <godot_cpp/classes/random_number_generator.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/classes/standard_material3d.hpp>
#include <godot_cpp/core/class_db.hpp>

using namespace godot;

void Box3DMultiMeshRenderer::build() {
	bodies.clear();
	for (int i = 0; i < get_child_count(); ++i) {
		Box3DBody *body = Object::cast_to<Box3DBody>(get_child(i));
		if (body == nullptr) {
			continue;
		}
		bodies.push_back(body);
		// We render this body; skip the (expensive at scale) node sync.
		body->set_sync_node_transform(false);
		// The body's own visual is replaced by our instance.
		MeshInstance3D *mesh = Object::cast_to<MeshInstance3D>(body->find_child("MeshInstance3D", false, false));
		if (mesh != nullptr) {
			mesh->queue_free();
		}
	}
	if (bodies.empty()) {
		return;
	}

	Ref<BoxMesh> box;
	box.instantiate();
	box->set_size(bodies[0]->get_box_size());
	Ref<StandardMaterial3D> mat;
	mat.instantiate();
	mat->set_flag(BaseMaterial3D::FLAG_ALBEDO_FROM_VERTEX_COLOR, true);
	mat->set_roughness(0.8);
	box->set_material(mat);

	multimesh.instantiate();
	multimesh->set_transform_format(MultiMesh::TRANSFORM_3D);
	multimesh->set_use_colors(true);
	multimesh->set_mesh(box);
	multimesh->set_instance_count((int)bodies.size());

	// Per-instance buffer: 12 transform floats + 4 color floats. Colors are
	// written once here; only the transform slots change per frame.
	buffer.resize((int64_t)bodies.size() * 16);
	float *w = buffer.ptrw();
	Ref<RandomNumberGenerator> rng;
	rng.instantiate();
	for (size_t i = 0; i < bodies.size(); ++i) {
		Color c = Color::from_hsv(rng->randf(), 0.5, 0.95);
		float *inst = w + i * 16;
		inst[12] = c.r;
		inst[13] = c.g;
		inst[14] = c.b;
		inst[15] = 1.0f;
	}

	if (mmi == nullptr) {
		mmi = memnew(MultiMeshInstance3D);
		// Instance transforms are written in WORLD space, so the visual node
		// must ignore any transform this renderer node carries.
		mmi->set_as_top_level(true);
		// We interpolate instance transforms ourselves from solver snapshots;
		// the engine's own multimesh physics interpolation (on when the
		// project enables physics_interpolation) double-buffers the server
		// data and garbles plain multimesh_set_buffer uploads.
		mmi->set_physics_interpolation_mode(Node::PHYSICS_INTERPOLATION_MODE_OFF);
		add_child(mmi);
	}
	mmi->set_multimesh(multimesh);
	mmi->set_transform(Transform3D());

	world = Object::cast_to<Box3DWorld>(get_parent());
	update_instances();
}

void Box3DMultiMeshRenderer::update_instances() {
	if (multimesh.is_null() || bodies.empty()) {
		return;
	}
	// The debug view replaces bodies' looks with collider shells; hide ours.
	if (world != nullptr && mmi != nullptr) {
		mmi->set_visible(!world->get_debug_draw());
	}
	float alpha = (float)Engine::get_singleton()->get_physics_interpolation_fraction();
	float *w = buffer.ptrw();
	for (size_t i = 0; i < bodies.size(); ++i) {
		b3WorldTransform prev, curr;
		bodies[i]->get_render_snapshots(prev, curr);
		// Lerp position, nlerp rotation — per-tick deltas are tiny, so
		// normalized lerp is indistinguishable from slerp here.
		double px = prev.p.x + (curr.p.x - prev.p.x) * alpha;
		double py = prev.p.y + (curr.p.y - prev.p.y) * alpha;
		double pz = prev.p.z + (curr.p.z - prev.p.z) * alpha;
		Quaternion qa = to_gd(prev.q);
		Quaternion qb = to_gd(curr.q);
		if (qa.dot(qb) < 0.0f) {
			qb = -qb;
		}
		Quaternion q = (qa + (qb - qa) * alpha).normalized();
		Basis b(q);
		float *inst = w + i * 16;
		inst[0] = (float)b.rows[0][0];
		inst[1] = (float)b.rows[0][1];
		inst[2] = (float)b.rows[0][2];
		inst[3] = (float)px;
		inst[4] = (float)b.rows[1][0];
		inst[5] = (float)b.rows[1][1];
		inst[6] = (float)b.rows[1][2];
		inst[7] = (float)py;
		inst[8] = (float)b.rows[2][0];
		inst[9] = (float)b.rows[2][1];
		inst[10] = (float)b.rows[2][2];
		inst[11] = (float)pz;
	}
	RenderingServer::get_singleton()->multimesh_set_buffer(multimesh->get_rid(), buffer);
}

void Box3DMultiMeshRenderer::_notification(int p_what) {
	switch (p_what) {
		case NOTIFICATION_READY: {
			if (!Engine::get_singleton()->is_editor_hint()) {
				build();
				set_process(true);
			}
		} break;
		case NOTIFICATION_PROCESS: {
			update_instances();
		} break;
		case NOTIFICATION_EXIT_TREE: {
			bodies.clear();
		} break;
	}
}

void Box3DMultiMeshRenderer::_bind_methods() {}
