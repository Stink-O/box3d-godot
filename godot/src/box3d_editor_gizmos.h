// SPDX-FileCopyrightText: 2026 box3d-godot contributors
// SPDX-License-Identifier: MIT

#pragma once

// The editor-only half of the extension: Node3D gizmos that draw a Box3D
// collider's outline and a joint's frame, axes and limits straight in the
// viewport, so a scene reads the same before you press play as it does under
// Box3DWorld's debug draw afterwards.
//
// EVERYTHING HERE IS EDITOR-ONLY BY CONSTRUCTION. The three classes are
// registered from register_types.cpp at MODULE_INITIALIZATION_LEVEL_EDITOR,
// which the engine only ever reaches in the editor: an exported game never
// calls that level, so the classes are never registered, never instantiated,
// and nothing in this file runs. Nothing here touches a b3WorldId or the step
// path — the geometry is rebuilt from the AUTHORED properties, because in the
// editor there is no solver world to ask (Box3DBody::create_in_world and
// Box3DJoint::create_joint both return early on is_editor_hint()).
//
// Colours follow upstream's own debug palette so the editor and the runtime
// overlay agree: b3HexColor constants from include/box3d/types.h:2773-2941,
// picked the way upstream's own draw code picks them (bodies:
// src/physics_world.c:1240-1305; joints: src/joint.c:1655-1720 plus the
// per-type b3Draw*Joint functions cited at each call site below).

#include <godot_cpp/classes/editor_node3d_gizmo.hpp>
#include <godot_cpp/classes/editor_node3d_gizmo_plugin.hpp>
#include <godot_cpp/classes/editor_plugin.hpp>
#include <godot_cpp/classes/ref.hpp>

namespace godot {

class Node3D;

// Collider outlines for Box3DBody and its Box3DCollisionShape children.
class Box3DColliderGizmoPlugin : public EditorNode3DGizmoPlugin {
	GDCLASS(Box3DColliderGizmoPlugin, EditorNode3DGizmoPlugin)

protected:
	static void _bind_methods() {}

public:
	Box3DColliderGizmoPlugin();

	String _get_gizmo_name() const override;
	int32_t _get_priority() const override;
	bool _has_gizmo(Node3D *p_node) const override;
	void _redraw(const Ref<EditorNode3DGizmo> &p_gizmo) override;
};

// Frames, axes and limits for every Box3DJoint subclass.
class Box3DJointGizmoPlugin : public EditorNode3DGizmoPlugin {
	GDCLASS(Box3DJointGizmoPlugin, EditorNode3DGizmoPlugin)

protected:
	static void _bind_methods() {}

public:
	Box3DJointGizmoPlugin();

	String _get_gizmo_name() const override;
	int32_t _get_priority() const override;
	bool _has_gizmo(Node3D *p_node) const override;
	void _redraw(const Ref<EditorNode3DGizmo> &p_gizmo) override;
};

// The one EditorPlugin the extension installs. Godot instantiates it by class
// name (EditorPlugins::add_by_type below hands it the name), so unlike the two
// gizmo plugins it cannot be registered as internal.
class Box3DEditorPlugin : public EditorPlugin {
	GDCLASS(Box3DEditorPlugin, EditorPlugin)

	Ref<Box3DColliderGizmoPlugin> collider_gizmos;
	Ref<Box3DJointGizmoPlugin> joint_gizmos;

protected:
	static void _bind_methods() {}

public:
	void _enter_tree() override;
	void _exit_tree() override;
	String _get_plugin_name() const override;
};

} // namespace godot
