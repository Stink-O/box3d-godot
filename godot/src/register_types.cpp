// SPDX-FileCopyrightText: 2026 box3d-godot contributors
// SPDX-License-Identifier: MIT

#include "register_types.h"

#include "box3d_body.h"
#include "box3d_character.h"
#include "box3d_collision.h"
#include "box3d_collision_shape.h"
#include "box3d_contact_rules.h"
#include "box3d_geometry.h"
#include "box3d_joint.h"
#include "box3d_multimesh_renderer.h"
#include "box3d_replay.h"
#include "box3d_world.h"

#include <gdextension_interface.h>

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

using namespace godot;

void initialize_box3d_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
	GDREGISTER_CLASS(Box3DWorld);
	GDREGISTER_CLASS(Box3DBody);
	GDREGISTER_CLASS(Box3DCharacterBody);
	GDREGISTER_CLASS(Box3DCollisionShape);
	GDREGISTER_ABSTRACT_CLASS(Box3DJoint);
	GDREGISTER_CLASS(Box3DHingeJoint);
	GDREGISTER_CLASS(Box3DSliderJoint);
	GDREGISTER_CLASS(Box3DDistanceJoint);
	GDREGISTER_CLASS(Box3DBallJoint);
	GDREGISTER_CLASS(Box3DFixedJoint);
	GDREGISTER_CLASS(Box3DMotorJoint);
	GDREGISTER_CLASS(Box3DWheelJoint);
	GDREGISTER_CLASS(Box3DParallelJoint);
	GDREGISTER_CLASS(Box3DFilterJoint);
	GDREGISTER_CLASS(Box3DMultiMeshRenderer);
	// A Resource scripts instantiate with .new() and scenes load from a .tres,
	// so it registers concrete, not abstract.
	GDREGISTER_CLASS(Box3DContactRules);
	// RefCounted, both instantiated from script with .new(): the recording
	// buffer and the player that stands its bytes back up.
	GDREGISTER_CLASS(Box3DRecording);
	GDREGISTER_CLASS(Box3DReplayPlayer);
	// Static-method utility classes: nothing instantiates them, but a class
	// that is never registered is invisible to GDScript however complete its
	// bindings are (the P-037 lesson).
	GDREGISTER_ABSTRACT_CLASS(Box3DGeometry);
	GDREGISTER_ABSTRACT_CLASS(Box3DCollision);
}

void uninitialize_box3d_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
}

extern "C" {
// Entry point referenced by box3d.gdextension (entry_symbol).
GDExtensionBool GDE_EXPORT box3d_library_init(
		GDExtensionInterfaceGetProcAddress p_get_proc_address,
		const GDExtensionClassLibraryPtr p_library,
		GDExtensionInitialization *r_initialization) {
	godot::GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);

	init_obj.register_initializer(initialize_box3d_module);
	init_obj.register_terminator(uninitialize_box3d_module);
	init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);

	return init_obj.init();
}
}
