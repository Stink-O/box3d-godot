// SPDX-FileCopyrightText: 2026 box3d-godot contributors
// SPDX-License-Identifier: MIT

#include "box3d_world.h"

#include "box3d_body.h"
#include "box3d_collision_shape.h"
#include "box3d_conversions.h"
#include "box3d_joint.h"

#include <godot_cpp/classes/box_mesh.hpp>
#include <godot_cpp/classes/capsule_mesh.hpp>
#include <godot_cpp/classes/cylinder_mesh.hpp>
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/immediate_mesh.hpp>
#include <godot_cpp/classes/label3d.hpp>
#include <godot_cpp/classes/mesh_instance3d.hpp>
#include <godot_cpp/classes/multi_mesh.hpp>
#include <godot_cpp/classes/multi_mesh_instance3d.hpp>
#include <godot_cpp/classes/project_settings.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/classes/shader.hpp>
#include <godot_cpp/classes/shader_material.hpp>
#include <godot_cpp/classes/sphere_mesh.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/string.hpp>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <godot_cpp/core/math.hpp>

using namespace godot;

Box3DWorld::Box3DWorld() {}

Box3DWorld::~Box3DWorld() {
	stop_step_thread();
	// Before the world goes: stopping is what completes the buffer, and it has
	// to happen while the world is still alive to be an explicit stop rather
	// than b3DestroyWorld's implicit one.
	stop_recording();
	// Drop the solver callbacks with the world they point at.
	if (contact_rules.is_valid()) {
		contact_rules->uninstall(this);
	}
	if (b3World_IsValid(world_id)) {
		b3DestroyWorld(world_id);
		world_id = b3_nullWorldId;
	}
}

void Box3DWorld::step_world(b3WorldId p_id, double p_delta, int p_substeps) {
	const auto t0 = std::chrono::steady_clock::now();
	b3World_Step(p_id, (float)p_delta, p_substeps);
	const auto t1 = std::chrono::steady_clock::now();
	last_step_usec.store(
			std::chrono::duration_cast<std::chrono::microseconds>(t1 - t0).count(),
			std::memory_order_relaxed);
}

double Box3DWorld::get_step_time_ms() const {
	return (double)last_step_usec.load(std::memory_order_relaxed) / 1000.0;
}

Dictionary Box3DWorld::get_profile() const {
	Dictionary d;
	if (!is_world_alive()) {
		return d;
	}
	// The profile is rewritten by every b3World_Step, so an in-flight async
	// step would hand back a half-updated struct.
	join_async_step();
	const b3Profile p = b3World_GetProfile(world_id);
	d["step"] = p.step;
	d["pairs"] = p.pairs;
	d["collide"] = p.collide;
	d["solve"] = p.solve;
	d["solverSetup"] = p.solverSetup;
	d["constraints"] = p.constraints;
	d["prepareConstraints"] = p.prepareConstraints;
	d["integrateVelocities"] = p.integrateVelocities;
	d["warmStart"] = p.warmStart;
	d["solveImpulses"] = p.solveImpulses;
	d["integratePositions"] = p.integratePositions;
	d["relaxImpulses"] = p.relaxImpulses;
	d["applyRestitution"] = p.applyRestitution;
	d["storeImpulses"] = p.storeImpulses;
	d["splitIslands"] = p.splitIslands;
	d["transforms"] = p.transforms;
	d["sensorHits"] = p.sensorHits;
	d["jointEvents"] = p.jointEvents;
	d["hitEvents"] = p.hitEvents;
	d["refit"] = p.refit;
	d["bullets"] = p.bullets;
	d["sleepIslands"] = p.sleepIslands;
	d["sensors"] = p.sensors;
	return d;
}

Dictionary Box3DWorld::get_live_settings() const {
	Dictionary d;
	if (!is_world_alive()) {
		return d;
	}
	join_async_step();
	d["gravity"] = to_gd(b3World_GetGravity(world_id));
	d["restitutionThreshold"] = (double)b3World_GetRestitutionThreshold(world_id);
	d["hitEventThreshold"] = (double)b3World_GetHitEventThreshold(world_id);
	d["contactRecycleDistance"] = (double)b3World_GetContactRecycleDistance(world_id);
	d["maximumLinearSpeed"] = (double)b3World_GetMaximumLinearSpeed(world_id);
	d["workerCount"] = b3World_GetWorkerCount(world_id);
	d["sleepingEnabled"] = b3World_IsSleepingEnabled(world_id);
	d["continuousEnabled"] = b3World_IsContinuousEnabled(world_id);
	d["warmStartingEnabled"] = b3World_IsWarmStartingEnabled(world_id);
	// Deliberately not repeated here: awake body count and world bounds already
	// have their own methods (get_awake_body_count / get_bounds).
	return d;
}

Dictionary Box3DWorld::get_max_capacity() const {
	Dictionary d;
	if (!is_world_alive()) {
		return d;
	}
	join_async_step();
	const b3Capacity c = b3World_GetMaxCapacity(world_id);
	d["staticShapeCount"] = c.staticShapeCount;
	d["dynamicShapeCount"] = c.dynamicShapeCount;
	d["staticBodyCount"] = c.staticBodyCount;
	d["dynamicBodyCount"] = c.dynamicBodyCount;
	d["contactCount"] = c.contactCount;
	return d;
}

int Box3DWorld::get_world_count() {
	return b3GetWorldCount();
}

int Box3DWorld::get_max_world_count() {
	return b3GetMaxWorldCount();
}

int Box3DWorld::get_graph_color_count() {
	return B3_GRAPH_COLOR_COUNT;
}

Color Box3DWorld::get_graph_color(int p_index) {
	// b3GetGraphColor asserts on an out-of-range index (src/constraint_graph.c:35)
	// and a debug build of Box3D would abort the game, so clamp instead. The
	// last slot is the overflow colour, which is a real answer, not an error.
	const int index = CLAMP(p_index, 0, B3_GRAPH_COLOR_COUNT - 1);
	// Same unpack as the overlay's ov_color(): 0x00RRGGBB, opaque, with the
	// b3DebugMaterial high byte masked off.
	const uint32_t rgb = (uint32_t)b3GetGraphColor(index) & 0x00FFFFFFu;
	return Color::hex((rgb << 8) | 0xFFu);
}

int64_t Box3DWorld::make_debug_color(const Color &p_color, DebugMaterial p_material) {
	// b3MakeDebugColor (types.h:2939-2942) verbatim, on Godot's colour type:
	// to_rgba32() is 0xRRGGBBAA, so drop the alpha byte to get the RGB the
	// packer wants.
	const uint32_t rgb = (p_color.to_rgba32() >> 8) & 0x00FFFFFFu;
	const uint32_t material = (uint32_t)CLAMP((int)p_material, 0, 255);
	return (int64_t)(rgb | (material << 24));
}

Dictionary Box3DWorld::get_counters() const {
	Dictionary d;
	if (!is_world_alive()) {
		return d;
	}
	join_async_step();
	const b3Counters c = b3World_GetCounters(world_id);
	d["bodyCount"] = c.bodyCount;
	d["shapeCount"] = c.shapeCount;
	d["contactCount"] = c.contactCount;
	d["jointCount"] = c.jointCount;
	d["islandCount"] = c.islandCount;
	d["stackUsed"] = c.stackUsed;
	d["arenaCapacity"] = c.arenaCapacity;
	d["staticTreeHeight"] = c.staticTreeHeight;
	d["treeHeight"] = c.treeHeight;
	d["satCallCount"] = c.satCallCount;
	d["satCacheHitCount"] = c.satCacheHitCount;
	d["byteCount"] = c.byteCount;
	d["taskCount"] = c.taskCount;
	d["awakeContactCount"] = c.awakeContactCount;
	d["recycledContactCount"] = c.recycledContactCount;
	d["distanceIterations"] = c.distanceIterations;
	d["pushBackIterations"] = c.pushBackIterations;
	d["rootIterations"] = c.rootIterations;
	// Graph-color and manifold-size histograms, kept as arrays so a UI can
	// draw them without knowing the bucket counts at compile time.
	PackedInt32Array colors;
	colors.resize(24);
	for (int i = 0; i < 24; i++) {
		colors.set(i, c.colorCounts[i]);
	}
	d["colorCounts"] = colors;
	PackedInt32Array manifolds;
	manifolds.resize(B3_CONTACT_MANIFOLD_COUNT_BUCKETS);
	for (int i = 0; i < B3_CONTACT_MANIFOLD_COUNT_BUCKETS; i++) {
		manifolds.set(i, c.manifoldCounts[i]);
	}
	d["manifoldCounts"] = manifolds;
	return d;
}

void Box3DWorld::async_thread_main() {
	std::unique_lock<std::mutex> lock(step_mutex);
	while (true) {
		step_cv.wait(lock, [this] { return worker_busy || worker_exit; });
		if (worker_exit) {
			break;
		}
		double dt = worker_dt;
		int substeps = worker_substeps;
		b3WorldId id = world_id; // stable: destruction joins this thread first
		lock.unlock();
		step_world(id, dt, substeps);
		lock.lock();
		worker_busy = false;
		step_cv.notify_all();
	}
}

void Box3DWorld::launch_async_step(double p_delta) {
	if (!step_thread.joinable()) {
		step_thread = std::thread(&Box3DWorld::async_thread_main, this);
	}
	{
		std::lock_guard<std::mutex> lock(step_mutex);
		worker_dt = p_delta;
		worker_substeps = substep_count;
		worker_busy = true;
		step_inflight.store(true, std::memory_order_release);
	}
	step_cv.notify_all();
}

void Box3DWorld::join_async_step() const {
	if (!step_inflight.load(std::memory_order_acquire)) {
		return;
	}
	{
		std::unique_lock<std::mutex> lock(step_mutex);
		step_cv.wait(lock, [this] { return !worker_busy; });
	}
	step_inflight.store(false, std::memory_order_release);
	step_pending_apply = true;
}

void Box3DWorld::apply_step_results() {
	step_pending_apply = false;
	sync_bodies_from_move_events();
	dispatch_contact_events();
	dispatch_sensor_events();
	dispatch_joint_events();
	dispatch_body_events();
	// Async mode refreshes the debug shells here: we are post-join, and apply
	// runs at most once per physics frame so it cannot catch-up-spiral like
	// the old per-tick update in the synchronous path could.
	if (debug_draw) {
		update_debug_draw();
	}
	if (debug_overlay_any()) {
		update_debug_overlay();
	}
}

void Box3DWorld::stop_step_thread() {
	if (!step_thread.joinable()) {
		return;
	}
	{
		std::lock_guard<std::mutex> lock(step_mutex);
		worker_exit = true;
	}
	step_cv.notify_all();
	step_thread.join();
	worker_exit = false;
	step_inflight.store(false, std::memory_order_release);
	step_pending_apply = false;
}

// b3SetLengthUnitsPerMeter (constants.h:8-15). Upstream's contract is absolute:
// set it at application startup, ONCE, before any other Box3D call. It rescales
// B3_LINEAR_SLOP, B3_HUGE, B3_MAX_AABB_MARGIN, the default sleep threshold and
// the default contact speed (constants.h:27-97, src/types.c:12, :37, :68), all
// of which are read when a world, a shape or a def is built — so a world built
// at one scale and a shape built at another disagree about what "small" means.
//
// A scene property would therefore be a footgun: any node could rewrite the
// tuning of every world in the process, halfway through a game. A project
// setting read once at module load is the only shape that matches upstream's
// rule, so that is what this is:
//
//     physics/box3d/length_units_per_meter   (float, default 1)
//
// It is applied from _bind_methods(), which runs during class registration at
// MODULE_INITIALIZATION_LEVEL_SCENE — before any scene is loaded and before any
// script can reach the binding, i.e. the earliest hook this file owns that is
// still after ProjectSettings exists. ensure_world() calls it again as a belt
// and braces for the case where the singleton was not available that early; the
// static flag makes every call after the first a no-op, which is exactly the
// "only modified once" upstream asks for.
//
// Leave it at 1 unless the game genuinely uses another unit. Nothing in this
// binding converts for you: every suffix in the inspector is written in metres.
void Box3DWorld::apply_length_units_setting() {
	static bool applied = false;
	if (applied) {
		return;
	}
	ProjectSettings *settings = ProjectSettings::get_singleton();
	if (settings == nullptr) {
		// Too early for the singleton; ensure_world() will try again.
		return;
	}
	applied = true;
	const String key = "physics/box3d/length_units_per_meter";
	if (!settings->has_setting(key)) {
		settings->set_setting(key, 1.0);
		settings->set_initial_value(key, 1.0);
		Dictionary info;
		info["name"] = key;
		info["type"] = Variant::FLOAT;
		info["hint"] = PROPERTY_HINT_RANGE;
		info["hint_string"] = "0.001,1000,0.001,or_greater";
		settings->add_property_info(info);
	}
	const double units = (double)settings->get_setting(key, 1.0);
	// b3SetLengthUnitsPerMeter asserts on a non-finite or non-positive value
	// (src/core.c:41-45), so script and project data are validated here rather
	// than being allowed to abort a debug build of Box3D.
	if (!std::isfinite(units) || units <= 0.0) {
		UtilityFunctions::push_warning(
				"Box3D: " + key + " must be a positive finite number; keeping 1 unit per metre.");
		return;
	}
	b3SetLengthUnitsPerMeter((float)units);
}

double Box3DWorld::get_length_units_per_meter() {
	return (double)b3GetLengthUnitsPerMeter();
}

bool Box3DWorld::set_length_units_per_meter(double p_units) {
	if (!std::isfinite(p_units) || p_units <= 0.0) {
		UtilityFunctions::push_error("Box3DWorld.set_length_units_per_meter: the scale must be positive and finite.");
		return false;
	}
	// Upstream's "before any calls to Box3D" (constants.h:11) is enforced at the
	// only boundary this binding can observe: a live world has already baked the
	// old scale into its slop, its margins and every shape in it, so changing it
	// underneath would leave the process holding two incompatible worlds.
	if (b3GetWorldCount() > 0) {
		UtilityFunctions::push_error(
				"Box3DWorld.set_length_units_per_meter: refused, " + itos(b3GetWorldCount()) +
				" world(s) already exist. It must be set before the first world is created; "
				"use the physics/box3d/length_units_per_meter project setting instead.");
		return false;
	}
	b3SetLengthUnitsPerMeter((float)p_units);
	return true;
}

void Box3DWorld::ensure_world() {
	if (b3World_IsValid(world_id)) {
		return;
	}
	// No-op after the first call; only does anything if class registration ran
	// before ProjectSettings was reachable.
	apply_length_units_setting();
	b3WorldDef def = b3DefaultWorldDef();
	def.gravity = to_b3(gravity);
	def.enableContinuous = continuous_collision;
	if (max_linear_speed > 0.0) {
		def.maximumLinearSpeed = (float)max_linear_speed;
	}
	// >1 turns on Box3D's internal multithreaded scheduler (no task callbacks
	// needed). Applied at world creation.
	def.workerCount = (uint32_t)(worker_count < 1 ? 1 : worker_count);
	def.enableSleep = enable_sleep;
	def.hitEventThreshold = (float)hit_event_threshold;
	def.restitutionThreshold = (float)restitution_threshold;
	// Optional pre-sizing. Zeros are Box3D's own default (grow on demand), so a
	// scene that authors nothing here is unaffected.
	def.capacity.staticShapeCount = capacity_static_shapes;
	def.capacity.dynamicShapeCount = capacity_dynamic_shapes;
	def.capacity.staticBodyCount = capacity_static_bodies;
	def.capacity.dynamicBodyCount = capacity_dynamic_bodies;
	def.capacity.contactCount = capacity_contacts;
	world_id = b3CreateWorld(&def);
	// The route from a b3WorldId back to this node, mirroring what bodies,
	// shapes and joints already do with their own user data. Nothing in the
	// binding needs it yet; a world-level Box3D callback would.
	b3World_SetUserData(world_id, this);
	apply_contact_tuning();
	// Not a b3WorldDef field: the world seeds it from B3_CONTACT_RECYCLE_DISTANCE
	// at creation (src/physics_world.c:332), so it can only be set afterwards.
	b3World_SetContactRecycleDistance(world_id, (float)contact_recycle_distance);
	b3World_EnableWarmStarting(world_id, enable_warm_starting);
	// Last: a world that was destroyed and recreated gets its solver callbacks
	// back, so the rules survive a rebuild the way every other property does.
	if (contact_rules.is_valid()) {
		contact_rules->install(this);
	}
}

bool Box3DWorld::has_body_descendant(const Node *p_node) {
	const int count = p_node->get_child_count();
	for (int i = 0; i < count; ++i) {
		Node *child = p_node->get_child(i);
		if (Object::cast_to<Box3DBody>(child) != nullptr) {
			return true;
		}
		// A nested Box3DWorld owns its own subtree: bodies below it join that
		// world, not this one, so they do not count as this world's contents.
		if (Object::cast_to<Box3DWorld>(child) != nullptr) {
			continue;
		}
		if (has_body_descendant(child)) {
			return true;
		}
	}
	return false;
}

PackedStringArray Box3DWorld::_get_configuration_warnings() const {
	PackedStringArray warnings;
	// Box3DBody and Box3DCharacterBody both find their world by walking UP the
	// tree, so a body that is a sibling of the world (the classic first
	// mistake) is never simulated and reports nothing.
	if (!has_body_descendant(this)) {
		warnings.push_back(
				"This world has no Box3DBody descendants, so it simulates nothing.\n"
				"Box3D only sees bodies placed UNDER a Box3DWorld — add Box3DBody "
				"nodes as children of this node.");
	}
	// Nested worlds are legal but almost never intended: two Box3D worlds never
	// collide with each other, and the inner one silently captures every body
	// below it.
	for (Node *ancestor = get_parent(); ancestor != nullptr; ancestor = ancestor->get_parent()) {
		if (Object::cast_to<Box3DWorld>(ancestor) != nullptr) {
			warnings.push_back(
					String("This world is nested inside another Box3DWorld (\"{0}\"). "
						   "Bodies below this node join THIS world only, and the two "
						   "simulations cannot collide with each other.\nUse one "
						   "Box3DWorld per simulation unless that separation is "
						   "deliberate.")
							.format(Array::make(ancestor->get_name())));
			break;
		}
	}
	if (!auto_step) {
		warnings.push_back(
				"Auto Step is off, so this world never advances on its own and the "
				"scene will look frozen.\nCall step(delta) from a script's "
				"_physics_process(), or turn Auto Step back on.");
	}
	return warnings;
}

void Box3DWorld::apply_contact_tuning() {
	if (!b3World_IsValid(world_id)) {
		return;
	}
	join_async_step();
	b3World_SetContactTuning(world_id, (float)contact_hertz, (float)contact_damping, (float)contact_speed);
}

b3WorldId Box3DWorld::get_world_id() {
	ensure_world();
	join_async_step();
	return world_id;
}

bool Box3DWorld::is_world_alive() const {
	join_async_step();
	return b3World_IsValid(world_id);
}

void Box3DWorld::register_body(Box3DBody *p_body) {
	if (p_body == nullptr) {
		return;
	}
	bodies.push_back(p_body);
}

void Box3DWorld::unregister_body(Box3DBody *p_body) {
	for (size_t i = 0; i < bodies.size(); ++i) {
		if (bodies[i] == p_body) {
			bodies.erase(bodies.begin() + i);
			return;
		}
	}
}

void Box3DWorld::step(double p_delta) {
	ensure_world();
	if (!b3World_IsValid(world_id) || p_delta <= 0.0) {
		return;
	}
	if (async_step) {
		if (step_inflight.load(std::memory_order_acquire)) {
			{
				std::lock_guard<std::mutex> lock(step_mutex);
				if (worker_busy) {
					// The previous step is still solving: skip this tick so
					// rendering stays smooth (the sim lags rather than stalls).
					return;
				}
			}
			step_inflight.store(false, std::memory_order_release);
			step_pending_apply = true;
		}
		if (step_pending_apply) {
			apply_step_results();
		}
		// Push user-driven (kinematic) transforms into the solver.
		for (Box3DBody *body : bodies) {
			if (body != nullptr) {
				body->sync_to_physics(p_delta);
			}
		}
		last_step_delta = p_delta;
		launch_async_step(p_delta);
		return;
	}
	// Synchronous path. Settle any leftover async state first (async_step may
	// have just been toggled off with a step still in flight).
	join_async_step();
	if (step_pending_apply) {
		apply_step_results();
	}
	// Push user-driven (kinematic) transforms into the solver.
	for (Box3DBody *body : bodies) {
		if (body != nullptr) {
			body->sync_to_physics(p_delta);
		}
	}
	last_step_delta = p_delta;
	step_world(world_id, p_delta, substep_count);
	// Read simulated (dynamic) transforms back out to the nodes.
	sync_bodies_from_move_events();
	dispatch_contact_events();
	dispatch_sensor_events();
	dispatch_joint_events();
	dispatch_body_events();
	debug_step_dirty = true; // the shells refresh from NOTIFICATION_PROCESS
}

Box3DBody *Box3DWorld::body_from_shape(b3ShapeId p_shape) {
	if (!b3Shape_IsValid(p_shape)) {
		return nullptr;
	}
	b3BodyId body_id = b3Shape_GetBody(p_shape);
	if (!b3Body_IsValid(body_id)) {
		return nullptr;
	}
	return static_cast<Box3DBody *>(b3Body_GetUserData(body_id));
}

Vector3i Box3DWorld::store_contact_id(b3ContactId p_id) {
	uint32_t values[3];
	b3StoreContactId(p_id, values);
	// int32 <- uint32 is a bit-preserving round trip through Vector3i's lanes;
	// b3LoadContactId casts each lane straight back (id.h:164-171), so a
	// negative lane here is not a corrupted handle.
	return Vector3i((int32_t)values[0], (int32_t)values[1], (int32_t)values[2]);
}

b3ContactId Box3DWorld::load_contact_id(const Vector3i &p_handle) {
	uint32_t values[3] = { (uint32_t)p_handle.x, (uint32_t)p_handle.y, (uint32_t)p_handle.z };
	return b3LoadContactId(values);
}

Object *Box3DWorld::shape_node_from(b3ShapeId p_shape) {
	if (!b3Shape_IsValid(p_shape)) {
		return nullptr;
	}
	return (Box3DCollisionShape *)b3Shape_GetUserData(p_shape);
}

void Box3DWorld::dispatch_contact_events() {
	if (!b3World_IsValid(world_id)) {
		return;
	}
	b3ContactEvents events = b3World_GetContactEvents(world_id);
	// The world-level begin/end signals exist for one reason the per-body
	// body_entered/body_exited pair cannot serve: they carry the contactId, and
	// a contact belongs to the PAIR, not to either body. Upstream reports one
	// event per pair; emitting it from each body would hand the same handle out
	// twice with no way to tell the two halves apart. Both are gated on
	// has_connections, so a scene that ignores them pays one bool per step.
	const bool report_begin = has_connections("contact_began");
	const bool report_end = has_connections("contact_ended");
	for (int i = 0; i < events.beginCount; ++i) {
		const b3ContactBeginTouchEvent &begin = events.beginEvents[i];
		Box3DBody *a = body_from_shape(begin.shapeIdA);
		Box3DBody *b = body_from_shape(begin.shapeIdB);
		if (a != nullptr && b != nullptr) {
			a->emit_contact_begin(b);
			b->emit_contact_begin(a);
		}
		if (report_begin) {
			Dictionary d;
			d["body_a"] = a;
			d["body_b"] = b;
			d["shape_a"] = shape_node_from(begin.shapeIdA);
			d["shape_b"] = shape_node_from(begin.shapeIdB);
			d["contact_id"] = store_contact_id(begin.contactId);
			emit_signal("contact_began", d);
		}
	}
	for (int i = 0; i < events.endCount; ++i) {
		const b3ContactEndTouchEvent &end = events.endEvents[i];
		Box3DBody *a = body_from_shape(end.shapeIdA);
		Box3DBody *b = body_from_shape(end.shapeIdB);
		if (a != nullptr && b != nullptr) {
			a->emit_contact_end(b);
			b->emit_contact_end(a);
		}
		if (report_end) {
			Dictionary d;
			d["body_a"] = a;
			d["body_b"] = b;
			// Both shape ids and the contact id may already be dangling here
			// (types.h:1120-1140): the shapes go through b3Shape_IsValid and the
			// handle is one is_contact_valid() away from being checked, which is
			// exactly what a handler needs to notice the contact is gone.
			d["shape_a"] = shape_node_from(end.shapeIdA);
			d["shape_b"] = shape_node_from(end.shapeIdB);
			d["contact_id"] = store_contact_id(end.contactId);
			emit_signal("contact_ended", d);
		}
	}
	// Hit events carry the only contact geometry Box3D reports without a
	// manifold query: where the shapes met, the normal from A to B, and how
	// fast they closed (types.h:1144-1174). They are reported once per pair,
	// so the signal keeps upstream's A/B ordering rather than being emitted
	// twice from each body's point of view. Every field is copied into the
	// Dictionary: the event arrays are only valid until the next step
	// (box3d.h:62-72), so a handler that stashes the payload must not be
	// holding a view of solver memory.
	const bool report_hits = has_connections("contact_hit");
	// Hit events also stand in for upstream's internal TOI flag (lime flash).
	// Upstream sets it during the continuous-collision sweep, i.e. only for
	// bodies moving over half their min extent per step, and CCD only sweeps
	// against static geometry (bullets also sweep dynamic bodies). Mirror
	// both conditions using the hit event's approach speed.
	float dt = (float)last_step_delta;
	for (int i = 0; i < events.hitCount; ++i) {
		const b3ContactHitEvent &hit = events.hitEvents[i];
		Box3DBody *a = body_from_shape(hit.shapeIdA);
		Box3DBody *b = body_from_shape(hit.shapeIdB);
		if (report_hits) {
			Dictionary d;
			d["body_a"] = a;
			d["body_b"] = b;
			// Null when the shape came from the body's own shape_type rather
			// than from a Box3DCollisionShape child.
			d["shape_a"] = (Box3DCollisionShape *)b3Shape_GetUserData(hit.shapeIdA);
			d["shape_b"] = (Box3DCollisionShape *)b3Shape_GetUserData(hit.shapeIdB);
			d["point"] = to_gd_pos(hit.point);
			d["normal"] = to_gd(hit.normal); // points from A towards B
			d["approach_speed"] = (double)hit.approachSpeed; // m/s, always positive
			d["user_material_a"] = (int64_t)hit.userMaterialIdA;
			d["user_material_b"] = (int64_t)hit.userMaterialIdB;
			d["contact_id"] = store_contact_id(hit.contactId);
			emit_signal("contact_hit", d);
		}
		if (a == nullptr || b == nullptr) {
			continue;
		}
		Box3DBody *pair[2] = { a, b };
		for (int j = 0; j < 2; ++j) {
			Box3DBody *self = pair[j];
			Box3DBody *other = pair[1 - j];
			if (self->get_body_type() != Box3DBody::DYNAMIC) {
				continue;
			}
			bool swept_partner = other->get_body_type() == Box3DBody::STATIC || self->get_continuous();
			if (swept_partner && hit.approachSpeed * dt > 0.5f * self->debug_min_extent()) {
				self->debug_hit_mark();
			}
		}
	}
}

void Box3DWorld::dispatch_sensor_events() {
	if (!b3World_IsValid(world_id)) {
		return;
	}
	b3SensorEvents events = b3World_GetSensorEvents(world_id);
	for (int i = 0; i < events.beginCount; ++i) {
		Box3DBody *sensor = body_from_shape(events.beginEvents[i].sensorShapeId);
		Box3DBody *visitor = body_from_shape(events.beginEvents[i].visitorShapeId);
		if (sensor != nullptr && visitor != nullptr) {
			sensor->emit_area_begin(visitor);
		}
	}
	for (int i = 0; i < events.endCount; ++i) {
		Box3DBody *sensor = body_from_shape(events.endEvents[i].sensorShapeId);
		Box3DBody *visitor = body_from_shape(events.endEvents[i].visitorShapeId);
		if (sensor != nullptr && visitor != nullptr) {
			sensor->emit_area_end(visitor);
		}
	}
}

// The transform read-back, driven by the move event array rather than by a
// poll over every registered body. Upstream documents this as exactly what the
// array is for (types.h:1204-1207): it is contiguous and holds only the bodies
// the solver moved.
//
// "Moved" is precisely "was in the awake set this step": the integrate-position
// task writes one entry per awake sim (src/solver.c:735-738), and the island
// sleep path stamps fellAsleep onto that same entry (src/solver_set.c:203-211).
// So the bodies this loop skips are the static, kinematic-at-rest, disabled and
// already-asleep ones — every one of which Box3DBody::sync_from_physics()
// already early-returned for, after paying a b3Body_IsAwake call to find out.
// Skipping them outright is the whole win, and it is what makes a 16k-body
// scene that has settled cost nothing to read back.
//
// The final resting transform is still delivered: a body that falls asleep
// during the step gets one last event carrying fellAsleep, which is the tick
// sync_from_physics writes and latches on.
//
// The event's own transform is what gets written, not a re-read: sync_from_move
// _event() takes b3BodyMoveEvent.transform and its fellAsleep flag directly, so
// the read-back costs no b3 call at all per body. The transform is the post-CCD
// pose (src/solver.c:570-572 rewrites it after the sweep), i.e. the same value
// b3Body_GetTransform would have returned, and fellAsleep is the awake state
// sync_from_physics used to pay a b3Body_IsAwake to learn.
void Box3DWorld::sync_bodies_from_move_events() {
	if (!b3World_IsValid(world_id)) {
		return;
	}
	b3BodyEvents events = b3World_GetBodyEvents(world_id);
	for (int i = 0; i < events.moveCount; ++i) {
		const b3BodyMoveEvent &move = events.moveEvents[i];
		Box3DBody *body = static_cast<Box3DBody *>(move.userData);
		if (body != nullptr) {
			body->sync_from_move_event(move.transform, move.fellAsleep);
		}
	}
	// Not driven by the event array: the hit flash is the binding's own state
	// and has to age on bodies that did not move (an impact can be the last
	// thing that happens before a body sleeps). No b3 call, just a counter.
	for (Box3DBody *body : bodies) {
		if (body != nullptr) {
			body->debug_hit_decay();
		}
	}
}

// b3World_GetBodyEvents reports every body the solver moved this step, each
// carrying a fellAsleep flag (types.h:1200-1223). Falling asleep is the only
// sleep transition Box3D reports, and nothing else in the binding can observe
// it: b3Body_IsAwake is a level, not an edge. Waking has no event; a move
// event without the flag means the body is awake (types.h:1204-1205).
//
// The move transforms themselves are deliberately not consumed here. Reading
// them would have to replace Box3DBody::sync_from_physics, which lives in
// another file and owns the interpolation snapshots.
void Box3DWorld::dispatch_body_events() {
	if (!b3World_IsValid(world_id)) {
		return;
	}
	// The array is every moved body, so at 16k bodies this loop is not free.
	// Nobody listening means nobody pays.
	if (!has_connections("body_fell_asleep")) {
		return;
	}
	b3BodyEvents events = b3World_GetBodyEvents(world_id);
	for (int i = 0; i < events.moveCount; ++i) {
		const b3BodyMoveEvent &event = events.moveEvents[i];
		if (!event.fellAsleep) {
			continue;
		}
		Box3DBody *body = static_cast<Box3DBody *>(event.userData);
		if (body != nullptr) {
			emit_signal("body_fell_asleep", body);
		}
	}
}

// b3World_GetJointEvents reports every awake joint whose constraint force or
// torque reached its threshold during the step (types.h:1237-1246,
// src/solver.c:297-309). Upstream omits the observed force/torque from the
// event "for efficiency reasons" and documents reading it back when the event
// fires, which is what the payload does here. The route from event to node is
// the joint's user data: Box3DJoint stores itself there at creation
// (box3d_joint.cpp:139), mirroring b3BodyDef.userData.
void Box3DWorld::dispatch_joint_events() {
	if (!b3World_IsValid(world_id)) {
		return;
	}
	// Nothing to build if nobody is listening. Joints only produce events once
	// a threshold is authored (the node's 0 means FLT_MAX, i.e. never), so this
	// loop is normally empty anyway.
	if (!has_connections("joint_threshold_exceeded")) {
		return;
	}
	b3JointEvents events = b3World_GetJointEvents(world_id);
	for (int i = 0; i < events.count; ++i) {
		const b3JointEvent &event = events.jointEvents[i];
		Box3DJoint *joint = static_cast<Box3DJoint *>(event.userData);
		if (joint == nullptr) {
			continue;
		}
		Vector3 force;
		Vector3 torque;
		// The event array is only valid until the next step, but a handler for
		// an earlier event may have destroyed this joint already.
		if (b3Joint_IsValid(event.jointId)) {
			force = to_gd(b3Joint_GetConstraintForce(event.jointId));
			torque = to_gd(b3Joint_GetConstraintTorque(event.jointId));
		}
		emit_signal("joint_threshold_exceeded", joint, force, torque);
	}
}

void Box3DWorld::_notification(int p_what) {
	switch (p_what) {
		case NOTIFICATION_ENTER_TREE: {
			if (!Engine::get_singleton()->is_editor_hint()) {
				ensure_world();
				set_physics_process(true);
				set_process(true);
			} else {
				update_configuration_warnings();
			}
		} break;
		case NOTIFICATION_PARENTED:
		case NOTIFICATION_CHILD_ORDER_CHANGED: {
			// Re-check "has bodies" / "nested world" when the subtree changes.
			// Gated on the editor so a game spawning thousands of bodies never
			// pays for a diagnostic nothing can display.
			if (Engine::get_singleton()->is_editor_hint()) {
				update_configuration_warnings();
			}
		} break;
		case NOTIFICATION_PROCESS: {
			// Synchronous mode refreshes the debug shells here, at most once
			// per frame AND only after a step actually ran (the solver data is
			// frozen between ticks, so re-reading it at render rate was pure
			// waste; updating inside step() instead made every catch-up tick
			// pay the full rebuild, which spiraled heavy scenes to a
			// standstill). Async mode updates from apply_step_results instead:
			// a step is in flight during most process callbacks, and joining
			// here would stall the rendering async exists to protect.
			if (!async_step && debug_step_dirty && !Engine::get_singleton()->is_editor_hint()) {
				const bool overlay = debug_overlay_any();
				if (debug_draw || overlay) {
					debug_step_dirty = false;
				}
				if (debug_draw) {
					update_debug_draw();
				}
				if (overlay) {
					update_debug_overlay();
				}
			}
		} break;
		case NOTIFICATION_EXIT_TREE: {
			stop_step_thread();
			stop_recording();
			if (contact_rules.is_valid()) {
				contact_rules->uninstall(this);
			}
			if (b3World_IsValid(world_id)) {
				b3DestroyWorld(world_id);
			}
			world_id = b3_nullWorldId;
			bodies.clear();
		} break;
		case NOTIFICATION_PHYSICS_PROCESS: {
			if (auto_step && !Engine::get_singleton()->is_editor_hint()) {
				step(get_physics_process_delta_time());
			}
		} break;
	}
}

void Box3DWorld::set_gravity(const Vector3 &p_gravity) {
	gravity = p_gravity;
	if (b3World_IsValid(world_id)) {
		join_async_step();
		b3World_SetGravity(world_id, to_b3(gravity));
	}
}

Vector3 Box3DWorld::get_gravity() const {
	return gravity;
}

void Box3DWorld::set_substep_count(int p_count) {
	substep_count = p_count < 1 ? 1 : p_count;
}

int Box3DWorld::get_substep_count() const {
	return substep_count;
}

void Box3DWorld::set_auto_step(bool p_enabled) {
	auto_step = p_enabled;
	update_configuration_warnings();
}

bool Box3DWorld::get_auto_step() const {
	return auto_step;
}

void Box3DWorld::set_continuous_collision(bool p_enabled) {
	continuous_collision = p_enabled;
	if (b3World_IsValid(world_id)) {
		join_async_step();
		b3World_EnableContinuous(world_id, p_enabled);
	}
}

bool Box3DWorld::get_continuous_collision() const {
	return continuous_collision;
}

void Box3DWorld::set_max_linear_speed(double p_speed) {
	max_linear_speed = p_speed;
	if (b3World_IsValid(world_id) && p_speed > 0.0) {
		join_async_step();
		b3World_SetMaximumLinearSpeed(world_id, (float)p_speed);
	}
}

double Box3DWorld::get_max_linear_speed() const {
	return max_linear_speed;
}

void Box3DWorld::set_worker_count(int p_count) {
	worker_count = p_count < 1 ? 1 : p_count;
#ifdef BOX3D_NO_THREADS
	// A single-threaded wasm build has no pthreads to give the solver, and
	// asking for workers anyway is not a soft failure: b3CreateScheduler goes
	// to pthread_create, and with exceptions disabled a refusal aborts the
	// process. Several samples author 4 or 16 workers, so clamp rather than
	// trust the scene.
	worker_count = 1;
#endif
	// Live: b3World_SetWorkerCount tears down and rebuilds the worker contexts
	// (src/physics_world.c:2271-2287), so this no longer waits for a world
	// rebuild. It clamps to [1, B3_MAX_WORKERS] itself.
	if (b3World_IsValid(world_id)) {
		join_async_step();
		b3World_SetWorkerCount(world_id, worker_count);
	}
}

int Box3DWorld::get_worker_count() const {
	return worker_count;
}

void Box3DWorld::set_async_step(bool p_enabled) {
#if defined(BOX3D_NO_THREADS) || defined(__EMSCRIPTEN__)
	// Refused on nothreads builds for the set_worker_count reason (std::thread
	// cannot report failure with exceptions off, so it aborts) — and on EVERY
	// wasm build, the threaded one included, because the async rig deadlocks
	// the tab: the step thread is created from the main browser thread, and
	// when the Emscripten pthread pool is busy (heavy samples author 4-16
	// solver workers) it sits queued until main returns to the event loop.
	// Main instead busy-waits in join_async_step(), which nearly every API
	// entry calls, so neither side can ever advance and the page freezes.
	// Stepping stays synchronous (solver workers are unaffected); the demo's
	// sidebar probes this refusal and hides the control.
	(void)p_enabled;
	async_step = false;
	return;
#else
	if (async_step == p_enabled) {
		return;
	}
	if (!p_enabled) {
		// Finish and absorb any in-flight step before going synchronous.
		join_async_step();
		if (step_pending_apply) {
			apply_step_results();
		}
	}
	async_step = p_enabled;
	// Run after every script's _physics_process so per-tick API calls (e.g. a
	// grab joint chasing the mouse) land before the step launches and never
	// have to wait for it.
	set_physics_process_priority(p_enabled ? 100 : 0);
#endif
}

bool Box3DWorld::get_async_step() const {
	return async_step;
}

Dictionary Box3DWorld::raycast(const Vector3 &p_from, const Vector3 &p_to, uint64_t p_mask, uint64_t p_layer) {
	join_async_step();
	Dictionary result;
	ensure_world();
	if (!b3World_IsValid(world_id)) {
		result["hit"] = false;
		return result;
	}
	b3Pos origin = to_b3_pos(p_from);
	b3Vec3 translation = to_b3(p_to - p_from);
	b3QueryFilter filter = b3DefaultQueryFilter();
	filter.maskBits = p_mask;
	filter.categoryBits = p_layer;
	b3RayResult r = b3World_CastRayClosest(world_id, origin, translation, filter);
	// b3RayResult carries the same two counters b3TreeStats does
	// (types.h:1355-1361), so the closest-hit ray reports its cost too.
	last_query_stats.nodeVisits = r.nodeVisits;
	last_query_stats.leafVisits = r.leafVisits;

	// b3RayResult.hit is the documented miss flag (types.h:1365-1366); the null
	// shape id means the same thing today but is not the stated contract.
	if (r.hit) {
		result["hit"] = true;
		result["position"] = to_gd_pos(r.point);
		result["normal"] = to_gd(r.normal);
		result["fraction"] = r.fraction;
		result["shape"] = (Box3DCollisionShape *)b3Shape_GetUserData(r.shapeId);
		// Per-triangle on a mesh or height field, per-child on a compound.
		result["user_material"] = (int64_t)r.userMaterialId;
		result["triangle_index"] = r.triangleIndex;
		result["child_index"] = r.childIndex;
		b3BodyId body_id = b3Shape_GetBody(r.shapeId);
		void *user_data = b3Body_GetUserData(body_id);
		if (user_data != nullptr) {
			result["collider"] = static_cast<Object *>(static_cast<Box3DBody *>(user_data));
		}
	} else {
		result["hit"] = false;
	}
	return result;
}

namespace {

struct OverlapContext {
	Box3DWorld *world;
	std::vector<Box3DBody *> bodies;
};

bool overlap_result_cb(b3ShapeId p_shape, void *p_context) {
	OverlapContext *ctx = static_cast<OverlapContext *>(p_context);
	Box3DBody *body = ctx->world->body_from_shape(p_shape);
	if (body != nullptr) {
		for (Box3DBody *existing : ctx->bodies) {
			if (existing == body) {
				return true;
			}
		}
		ctx->bodies.push_back(body);
	}
	return true;
}

struct CastContext {
	Box3DWorld *world;
	bool hit = false;
	b3Pos point;
	b3Vec3 normal;
	float fraction = 1.0f;
	Box3DBody *body = nullptr;
};

float cast_result_cb(b3ShapeId p_shape, b3Pos p_point, b3Vec3 p_normal, float p_fraction, uint64_t, int, int, void *p_context) {
	CastContext *ctx = static_cast<CastContext *>(p_context);
	ctx->hit = true;
	ctx->point = p_point;
	ctx->normal = p_normal;
	ctx->fraction = p_fraction;
	ctx->body = ctx->world->body_from_shape(p_shape);
	return p_fraction; // clip so later reports are only closer hits
}

struct RayAllContext {
	Box3DWorld *world;
	std::vector<Dictionary> hits;
};

// Collects every shape along the ray. Upstream's return protocol decides that:
// 1 means "do not clip the ray, keep going" (types.h:99-113), where the closest
// -hit query returns the fraction instead. Shapes can arrive in any order
// (box3d.h:85), so the caller sorts.
float ray_all_result_cb(b3ShapeId p_shape, b3Pos p_point, b3Vec3 p_normal, float p_fraction, uint64_t p_material,
		int p_triangle, int p_child, void *p_context) {
	RayAllContext *ctx = static_cast<RayAllContext *>(p_context);
	Dictionary hit;
	hit["collider"] = ctx->world->body_from_shape(p_shape);
	hit["shape"] = (Box3DCollisionShape *)b3Shape_GetUserData(p_shape);
	hit["position"] = to_gd_pos(p_point);
	hit["normal"] = to_gd(p_normal);
	hit["fraction"] = (double)p_fraction;
	hit["user_material"] = (int64_t)p_material;
	hit["triangle_index"] = p_triangle;
	hit["child_index"] = p_child;
	ctx->hits.push_back(hit);
	return 1.0f;
}

// The eight corners of an axis-aligned box, as a zero-radius point cloud
// relative to the query origin. Upstream: "A box is four points with a zero
// radius" in 2D; in 3D that is the eight corners (types.h:1382-1384).
void fill_box_proxy(b3Vec3 p_points[8], const Vector3 &p_size) {
	const float hx = (float)Math::abs(p_size.x) * 0.5f;
	const float hy = (float)Math::abs(p_size.y) * 0.5f;
	const float hz = (float)Math::abs(p_size.z) * 0.5f;
	int i = 0;
	for (int sx = -1; sx <= 1; sx += 2) {
		for (int sy = -1; sy <= 1; sy += 2) {
			for (int sz = -1; sz <= 1; sz += 2) {
				p_points[i++] = b3Vec3{ sx * hx, sy * hy, sz * hz };
			}
		}
	}
}

} // namespace

// A proxy the caller owns for the length of one query: the point cloud lives
// here, and b3ShapeProxy only borrows it (types.h:1370-1379). Points are stored
// RELATIVE to the query origin, which is what keeps a query precise far from
// the world origin (box3d.h:78-80). Named in godot:: rather than in the
// anonymous namespace above because the two shared query helpers on Box3DWorld
// take it by reference and are declared in the header.
struct godot::Box3DQueryProxy {
	std::vector<b3Vec3> points;
	b3Pos origin = {};
	float radius = 0.0f;

	b3ShapeProxy proxy() const {
		b3ShapeProxy p;
		p.points = points.data();
		p.count = (int)points.size();
		p.radius = radius;
		return p;
	}
};

namespace {

// Two end centers plus a radius, exactly b3Capsule's own description
// (types.h:1917-1930). The origin is the mid-point so both ends stay small.
Box3DQueryProxy capsule_proxy(const Vector3 &p_a, const Vector3 &p_b, double p_radius) {
	Box3DQueryProxy out;
	const Vector3 mid = (p_a + p_b) * 0.5f;
	out.origin = to_b3_pos(mid);
	out.points.push_back(to_b3(p_a - mid));
	out.points.push_back(to_b3(p_b - mid));
	out.radius = (float)Math::abs(p_radius);
	return out;
}

// An arbitrary convex volume: the cloud itself, radius 0. GJK treats the cloud
// as its convex hull, so no hull has to be built to query one.
Box3DQueryProxy convex_proxy(const PackedVector3Array &p_points) {
	Box3DQueryProxy out;
	int count = p_points.size();
	if (count <= 0) {
		return out;
	}
	if (count > B3_MAX_SHAPE_CAST_POINTS) {
		UtilityFunctions::push_warning(
				"Box3DWorld: a query proxy takes at most " + itos(B3_MAX_SHAPE_CAST_POINTS) +
				" points (B3_MAX_SHAPE_CAST_POINTS); the rest are ignored.");
		count = B3_MAX_SHAPE_CAST_POINTS;
	}
	// Centroid origin: the proxy points are relative to it, so a cloud far from
	// the world origin keeps its precision.
	Vector3 centroid;
	for (int i = 0; i < count; ++i) {
		centroid += p_points[i];
	}
	centroid /= (float)count;
	out.origin = to_b3_pos(centroid);
	out.points.reserve((size_t)count);
	for (int i = 0; i < count; ++i) {
		out.points.push_back(to_b3(p_points[i] - centroid));
	}
	return out;
}

} // namespace

void Box3DWorld::set_contact_rules(const Ref<Box3DContactRules> &p_rules) {
	if (contact_rules == p_rules) {
		return;
	}
	join_async_step();
	if (contact_rules.is_valid()) {
		contact_rules->uninstall(this);
	}
	contact_rules = p_rules;
	if (contact_rules.is_valid() && b3World_IsValid(world_id)) {
		contact_rules->install(this);
	}
}

Ref<Box3DContactRules> Box3DWorld::get_contact_rules() const {
	return contact_rules;
}

bool Box3DWorld::start_recording(const Ref<Box3DRecording> &p_recording) {
	if (p_recording.is_null() || p_recording->get_handle() == nullptr) {
		ERR_PRINT("Box3DWorld.start_recording: no recording buffer.");
		return false;
	}
	if (active_recording.is_valid()) {
		ERR_PRINT("Box3DWorld.start_recording: this world is already recording. "
				  "Call stop_recording() first.");
		return false;
	}
	if (p_recording->is_recording()) {
		// Not upstream's rule but this binding's: b3World_StartRecording resets
		// the buffer, so letting a second world start on it would silently
		// discard the first world's session (box3d.h:277-278).
		ERR_PRINT("Box3DWorld.start_recording: that buffer is already recording another world.");
		return false;
	}
	ensure_world();
	if (!b3World_IsValid(world_id)) {
		return false;
	}
	// b3World_StartRecording refuses a locked world and asserts on one
	// (src/physics_world.c:2300-2305 -> :96-106), so land on a step boundary.
	join_async_step();
	b3World_StartRecording(world_id, p_recording->get_handle());
	active_recording = p_recording;
	p_recording->attach_world(this);
	return true;
}

bool Box3DWorld::stop_recording() {
	if (active_recording.is_null()) {
		return false;
	}
	if (b3World_IsValid(world_id)) {
		join_async_step();
		// This is what appends the geometry registry and backpatches the
		// header, i.e. what makes the buffer loadable (src/recording.c:1069-
		// 1108). Safe when the world is not recording.
		b3World_StopRecording(world_id);
	}
	// A dead world already stopped the session itself: b3DestroyWorld calls
	// b3StopRecordingInternal before teardown (src/physics_world.c:414-415), so
	// the buffer is complete either way and only the bookkeeping is left.
	active_recording->detach_world();
	active_recording = Ref<Box3DRecording>();
	return true;
}

bool Box3DWorld::is_recording() const {
	return active_recording.is_valid();
}

Ref<Box3DRecording> Box3DWorld::get_recording() const {
	return active_recording;
}

Dictionary Box3DWorld::get_last_query_stats() const {
	Dictionary out;
	out["node_visits"] = last_query_stats.nodeVisits;
	out["leaf_visits"] = last_query_stats.leafVisits;
	return out;
}

Array Box3DWorld::raycast_all(const Vector3 &p_from, const Vector3 &p_to, uint64_t p_mask, uint64_t p_layer) {
	join_async_step();
	ensure_world();
	Array out;
	RayAllContext ctx;
	ctx.world = this;
	if (!b3World_IsValid(world_id)) {
		return out;
	}
	b3QueryFilter filter = b3DefaultQueryFilter();
	filter.maskBits = p_mask;
	filter.categoryBits = p_layer;
	last_query_stats = b3World_CastRay(world_id, to_b3_pos(p_from), to_b3(p_to - p_from), filter, ray_all_result_cb, &ctx);
	// Nearest first: the traversal order is unspecified (box3d.h:85), and
	// nearest-first is what every caller of an all-hits ray wants.
	std::stable_sort(ctx.hits.begin(), ctx.hits.end(), [](const Dictionary &a, const Dictionary &b) {
		return (double)a["fraction"] < (double)b["fraction"];
	});
	for (const Dictionary &hit : ctx.hits) {
		out.push_back(hit);
	}
	return out;
}

Array Box3DWorld::overlap_sphere(const Vector3 &p_center, double p_radius, uint64_t p_mask, uint64_t p_layer) {
	join_async_step();
	Array result;
	ensure_world();
	if (!b3World_IsValid(world_id)) {
		return result;
	}
	b3Vec3 point = b3Vec3{ 0.0f, 0.0f, 0.0f };
	b3ShapeProxy proxy;
	proxy.points = &point;
	proxy.count = 1;
	proxy.radius = (float)p_radius;
	b3QueryFilter filter = b3DefaultQueryFilter();
	filter.maskBits = p_mask;
	filter.categoryBits = p_layer;
	OverlapContext ctx;
	ctx.world = this;
	last_query_stats = b3World_OverlapShape(world_id, to_b3_pos(p_center), &proxy, filter, overlap_result_cb, &ctx);
	for (Box3DBody *body : ctx.bodies) {
		result.push_back(body);
	}
	return result;
}

Array Box3DWorld::overlap_box(const Vector3 &p_center, const Vector3 &p_size, uint64_t p_mask, uint64_t p_layer) {
	join_async_step();
	Array result;
	ensure_world();
	if (!b3World_IsValid(world_id)) {
		return result;
	}
	b3Vec3 points[8];
	fill_box_proxy(points, p_size);
	b3ShapeProxy proxy;
	proxy.points = points;
	proxy.count = 8;
	proxy.radius = 0.0f;
	b3QueryFilter filter = b3DefaultQueryFilter();
	filter.maskBits = p_mask;
	filter.categoryBits = p_layer;
	OverlapContext ctx;
	ctx.world = this;
	// The proxy points are relative to the origin, which is what keeps the
	// query precise far from the world origin (box3d.h:78-80).
	last_query_stats = b3World_OverlapShape(world_id, to_b3_pos(p_center), &proxy, filter, overlap_result_cb, &ctx);
	for (Box3DBody *body : ctx.bodies) {
		result.push_back(body);
	}
	return result;
}

// The capsule and convex overlaps share everything but how the point cloud is
// built, so they meet here.
Array Box3DWorld::run_overlap_proxy(const Box3DQueryProxy &p_shape, uint64_t p_mask, uint64_t p_layer) {
	Array result;
	if (p_shape.points.empty() || !b3World_IsValid(world_id)) {
		return result;
	}
	const b3ShapeProxy proxy = p_shape.proxy();
	b3QueryFilter filter = b3DefaultQueryFilter();
	filter.maskBits = p_mask;
	filter.categoryBits = p_layer;
	OverlapContext ctx;
	ctx.world = this;
	last_query_stats = b3World_OverlapShape(world_id, p_shape.origin, &proxy, filter, overlap_result_cb, &ctx);
	for (Box3DBody *body : ctx.bodies) {
		result.push_back(body);
	}
	return result;
}

Dictionary Box3DWorld::run_cast_proxy(const Box3DQueryProxy &p_shape, const Vector3 &p_motion, uint64_t p_mask, uint64_t p_layer) {
	Dictionary result;
	if (p_shape.points.empty() || !b3World_IsValid(world_id)) {
		result["hit"] = false;
		return result;
	}
	const b3ShapeProxy proxy = p_shape.proxy();
	b3QueryFilter filter = b3DefaultQueryFilter();
	filter.maskBits = p_mask;
	filter.categoryBits = p_layer;
	CastContext ctx;
	ctx.world = this;
	last_query_stats = b3World_CastShape(world_id, p_shape.origin, &proxy, to_b3(p_motion), filter, cast_result_cb, &ctx);
	if (ctx.hit) {
		result["hit"] = true;
		result["position"] = to_gd_pos(ctx.point);
		result["normal"] = to_gd(ctx.normal);
		result["fraction"] = ctx.fraction;
		if (ctx.body != nullptr) {
			result["collider"] = static_cast<Object *>(ctx.body);
		}
	} else {
		result["hit"] = false;
	}
	return result;
}

Array Box3DWorld::overlap_capsule(const Vector3 &p_point_a, const Vector3 &p_point_b, double p_radius,
		uint64_t p_mask, uint64_t p_layer) {
	join_async_step();
	ensure_world();
	return run_overlap_proxy(capsule_proxy(p_point_a, p_point_b, p_radius), p_mask, p_layer);
}

Array Box3DWorld::overlap_convex(const PackedVector3Array &p_points, uint64_t p_mask, uint64_t p_layer) {
	join_async_step();
	ensure_world();
	return run_overlap_proxy(convex_proxy(p_points), p_mask, p_layer);
}

Dictionary Box3DWorld::shape_cast_capsule(const Vector3 &p_point_a, const Vector3 &p_point_b, double p_radius,
		const Vector3 &p_motion, uint64_t p_mask, uint64_t p_layer) {
	join_async_step();
	ensure_world();
	return run_cast_proxy(capsule_proxy(p_point_a, p_point_b, p_radius), p_motion, p_mask, p_layer);
}

Dictionary Box3DWorld::shape_cast_convex(const PackedVector3Array &p_points, const Vector3 &p_motion,
		uint64_t p_mask, uint64_t p_layer) {
	join_async_step();
	ensure_world();
	return run_cast_proxy(convex_proxy(p_points), p_motion, p_mask, p_layer);
}

Array Box3DWorld::overlap_aabb(const AABB &p_aabb, uint64_t p_mask, uint64_t p_layer) {
	join_async_step();
	Array result;
	ensure_world();
	if (!b3World_IsValid(world_id)) {
		return result;
	}
	const Vector3 lower = p_aabb.position;
	const Vector3 upper = p_aabb.position + p_aabb.size;
	b3AABB aabb;
	aabb.lowerBound = to_b3(lower.min(upper));
	aabb.upperBound = to_b3(lower.max(upper));
	b3QueryFilter filter = b3DefaultQueryFilter();
	filter.maskBits = p_mask;
	filter.categoryBits = p_layer;
	OverlapContext ctx;
	ctx.world = this;
	// Broad phase only: upstream says "potentially overlap" (box3d.h:74-75),
	// because it tests the fattened tree proxies, not the shapes.
	last_query_stats = b3World_OverlapAABB(world_id, aabb, filter, overlap_result_cb, &ctx);
	for (Box3DBody *body : ctx.bodies) {
		result.push_back(body);
	}
	return result;
}

Dictionary Box3DWorld::shape_cast_box(const Vector3 &p_from, const Vector3 &p_to, const Vector3 &p_size, uint64_t p_mask, uint64_t p_layer) {
	join_async_step();
	Dictionary result;
	ensure_world();
	if (!b3World_IsValid(world_id)) {
		result["hit"] = false;
		return result;
	}
	b3Vec3 points[8];
	fill_box_proxy(points, p_size);
	b3ShapeProxy proxy;
	proxy.points = points;
	proxy.count = 8;
	proxy.radius = 0.0f;
	b3QueryFilter filter = b3DefaultQueryFilter();
	filter.maskBits = p_mask;
	filter.categoryBits = p_layer;
	CastContext ctx;
	ctx.world = this;
	last_query_stats = b3World_CastShape(world_id, to_b3_pos(p_from), &proxy, to_b3(p_to - p_from), filter, cast_result_cb, &ctx);
	if (ctx.hit) {
		result["hit"] = true;
		result["position"] = to_gd_pos(ctx.point);
		result["normal"] = to_gd(ctx.normal);
		result["fraction"] = ctx.fraction;
		if (ctx.body != nullptr) {
			result["collider"] = static_cast<Object *>(ctx.body);
		}
	} else {
		result["hit"] = false;
	}
	return result;
}

bool Box3DWorld::is_contact_valid(const Vector3i &p_contact) const {
	// Reads the world's contact array, so an in-flight step has to be joined
	// even though b3Contact_IsValid itself takes no world id.
	join_async_step();
	return b3Contact_IsValid(load_contact_id(p_contact));
}

Dictionary Box3DWorld::get_contact_data(const Vector3i &p_contact) const {
	join_async_step();
	Dictionary out;
	const b3ContactId id = load_contact_id(p_contact);
	// Not optional: b3Contact_GetData indexes the contact array and
	// dereferences the shapes without a check (src/contact.c:62-66), so a stale
	// handle is an assert in a debug build of Box3D and garbage in a release
	// one. b3Contact_IsValid is the documented guard (box3d.h:1745-1746).
	if (!b3Contact_IsValid(id)) {
		return out;
	}
	const b3ContactData data = b3Contact_GetData(id);
	out["contact_id"] = p_contact;
	const b3BodyId body_a = b3Shape_GetBody(data.shapeIdA);
	const b3BodyId body_b = b3Shape_GetBody(data.shapeIdB);
	out["body_a"] = (Box3DBody *)b3Body_GetUserData(body_a);
	out["body_b"] = (Box3DBody *)b3Body_GetUserData(body_b);
	out["shape_a"] = shape_node_from(data.shapeIdA);
	out["shape_b"] = shape_node_from(data.shapeIdB);
	out["manifold_count"] = data.manifoldCount;

	// Anchors are relative to each body's center of mass (types.h:2585-2590), so
	// both witness points are re-based to world space here. They coincide on a
	// touching point and separate on a speculative one.
	const Vector3 center_a = to_gd_pos(b3Body_GetWorldCenter(body_a));
	const Vector3 center_b = to_gd_pos(b3Body_GetWorldCenter(body_b));
	Vector3 first_normal;
	double impulse = 0.0;
	Array points;
	for (int m = 0; m < data.manifoldCount; ++m) {
		// Never stored: the manifold array is internal solver memory and is only
		// valid for this call (types.h:1275-1277).
		const b3Manifold &manifold = data.manifolds[m];
		const Vector3 normal = to_gd(manifold.normal);
		if (m == 0) {
			first_normal = normal;
		}
		for (int p = 0; p < manifold.pointCount; ++p) {
			const b3ManifoldPoint &mp = manifold.points[p];
			Dictionary point;
			point["position"] = center_a + to_gd(mp.anchorA);
			point["position_b"] = center_b + to_gd(mp.anchorB);
			point["separation"] = (double)mp.separation;
			// Box3D is speculative, so a listed point can be separated and idle.
			// totalNormalImpulse is what says it actually interacted
			// (types.h:2601-2603).
			point["impulse"] = (double)mp.totalNormalImpulse;
			point["velocity"] = (double)mp.normalVelocity;
			point["normal"] = normal;
			point["manifold"] = m;
			point["triangle_index"] = mp.triangleIndex;
			point["persisted"] = mp.persisted;
			impulse += mp.totalNormalImpulse;
			points.push_back(point);
		}
	}
	// A valid contact with no points is a registered pair that is not touching
	// this step — upstream says so at box3d.h:1748-1749.
	out["touching"] = !points.is_empty();
	out["normal"] = first_normal;
	out["impulse"] = impulse;
	out["points"] = points;
	return out;
}

int Box3DWorld::get_awake_body_count() const {
	if (!is_world_alive()) {
		return 0;
	}
	return b3World_GetAwakeBodyCount(world_id);
}

AABB Box3DWorld::get_bounds() const {
	if (!is_world_alive()) {
		return AABB();
	}
	join_async_step();
	const b3AABB bounds = b3World_GetBounds(world_id);
	const Vector3 lower = to_gd(bounds.lowerBound);
	const Vector3 upper = to_gd(bounds.upperBound);
	return AABB(lower, upper - lower);
}

Dictionary Box3DWorld::shape_cast_sphere(const Vector3 &p_from, const Vector3 &p_to, double p_radius, uint64_t p_mask, uint64_t p_layer) {
	join_async_step();
	Dictionary result;
	ensure_world();
	if (!b3World_IsValid(world_id)) {
		result["hit"] = false;
		return result;
	}
	b3Vec3 point = b3Vec3{ 0.0f, 0.0f, 0.0f };
	b3ShapeProxy proxy;
	proxy.points = &point;
	proxy.count = 1;
	proxy.radius = (float)p_radius;
	b3Vec3 translation = to_b3(p_to - p_from);
	b3QueryFilter filter = b3DefaultQueryFilter();
	filter.maskBits = p_mask;
	filter.categoryBits = p_layer;
	CastContext ctx;
	ctx.world = this;
	last_query_stats = b3World_CastShape(world_id, to_b3_pos(p_from), &proxy, translation, filter, cast_result_cb, &ctx);
	if (ctx.hit) {
		result["hit"] = true;
		result["position"] = to_gd_pos(ctx.point);
		result["normal"] = to_gd(ctx.normal);
		result["fraction"] = ctx.fraction;
		if (ctx.body != nullptr) {
			result["collider"] = static_cast<Object *>(ctx.body);
		}
	} else {
		result["hit"] = false;
	}
	return result;
}

void Box3DWorld::explode(const Vector3 &p_center, double p_radius, double p_impulse_per_area, double p_falloff, uint64_t p_mask) {
	join_async_step();
	ensure_world();
	if (!b3World_IsValid(world_id)) {
		return;
	}
	b3ExplosionDef def = b3DefaultExplosionDef();
	def.position = to_b3_pos(p_center);
	def.radius = (float)p_radius;
	def.falloff = (float)p_falloff;
	def.impulsePerArea = (float)p_impulse_per_area;
	// One-way by upstream design: b3ExplosionDef carries maskBits and no
	// category (types.h:1020-1038), so unlike the queries there is no second
	// half to fill in here.
	def.maskBits = p_mask;
	b3World_Explode(world_id, &def);
}


// ---------------------------------------------------------------------------
// Upstream debug draw (b3World_Draw, box3d.h:56).
//
// b3World_Draw is a pull API: it walks the broad phase and calls back into the
// host once per thing it wants drawn (types.h:2973-3057). Every callback runs
// SYNCHRONOUSLY on the thread that called b3World_Draw — the function fans out
// to nothing and does its own single-threaded walk (src/physics_world.c:1365-
// 1710) — so the callbacks below are main-thread Godot code by construction.
// b3World_Draw also refuses a locked world (b3GetUnlockedWorldFromId,
// src/physics_world.c:102-106), which is why update_debug_overlay() joins any
// in-flight async step before calling it.
//
// Shapes are NOT drawn through this path: DrawShapeFcn only fires for shapes
// the host built with b3CreateDebugShapeCallback (src/physics_world.c:1308-
// 1353), which this binding never registers. The MultiMesh shells above remain
// the shape renderer and this overlay supplies what they cannot: joints,
// contact points/normals/forces, islands, graph colors, mass, sleep state,
// body names and shape bounds.
namespace {

struct OverlayContext {
	ImmediateMesh *mesh = nullptr;
	Node3D *parent = nullptr; // labels are parented here, top-level
	std::vector<Label3D *> *labels = nullptr;
	int label_used = 0;
	int label_budget = 0;
};

// b3HexColor is 0x00RRGGBB with an optional b3DebugMaterial preset packed into
// the high byte (types.h:2939-2942). The preset drives PBR roughness in
// upstream's renderer; these overlays are unshaded lines, so it is masked off.
inline Color ov_color(b3HexColor p_color, float p_alpha = 1.0f) {
	Color c = Color::hex((uint32_t)(((uint32_t)p_color & 0x00FFFFFFu) << 8) | 0xFFu);
	c.a = p_alpha;
	return c;
}

inline void ov_line(OverlayContext *c, const Vector3 &p_a, const Vector3 &p_b, const Color &p_col) {
	c->mesh->surface_set_color(p_col);
	c->mesh->surface_add_vertex(p_a);
	c->mesh->surface_set_color(p_col);
	c->mesh->surface_add_vertex(p_b);
}

// Any two unit vectors perpendicular to p_axis, for drawing rings.
inline void ov_frame(const Vector3 &p_axis, Vector3 &r_u, Vector3 &r_v) {
	const Vector3 a = p_axis.normalized();
	const Vector3 ref = Math::abs(a.y) < 0.9f ? Vector3(0, 1, 0) : Vector3(1, 0, 0);
	r_u = a.cross(ref).normalized();
	r_v = a.cross(r_u);
}

void ov_circle(OverlayContext *c, const Vector3 &p_center, const Vector3 &p_u, const Vector3 &p_v,
		float p_radius, const Color &p_col) {
	const int SEGMENTS = 16;
	Vector3 prev = p_center + p_u * p_radius;
	for (int i = 1; i <= SEGMENTS; ++i) {
		const float t = (float)i / (float)SEGMENTS * (float)Math_TAU;
		const Vector3 next = p_center + (p_u * Math::cos(t) + p_v * Math::sin(t)) * p_radius;
		ov_line(c, prev, next, p_col);
		prev = next;
	}
}

// Never called: see the note above (no b3CreateDebugShapeCallback is
// registered, so Box3D has no user shape to hand back). Present because
// b3World_Draw dereferences every function pointer unconditionally.
void ov_draw_shape(void *p_user_shape, b3WorldTransform p_transform, b3HexColor p_color, void *p_context) {
	(void)p_user_shape;
	(void)p_transform;
	(void)p_color;
	(void)p_context;
}

void ov_draw_segment(b3Pos p_p1, b3Pos p_p2, b3HexColor p_color, void *p_context) {
	OverlayContext *c = static_cast<OverlayContext *>(p_context);
	ov_line(c, to_gd_pos(p_p1), to_gd_pos(p_p2), ov_color(p_color));
}

void ov_draw_transform(b3WorldTransform p_transform, void *p_context) {
	OverlayContext *c = static_cast<OverlayContext *>(p_context);
	// Upstream's own axis length at 1 length unit per meter
	// (src/physics_world.c:1376).
	const float AXIS = 0.3f;
	const Basis basis(to_gd(p_transform.q));
	const Vector3 o = to_gd_pos(p_transform.p);
	ov_line(c, o, o + basis.get_column(0) * AXIS, Color(1, 0, 0));
	ov_line(c, o, o + basis.get_column(1) * AXIS, Color(0, 1, 0));
	ov_line(c, o, o + basis.get_column(2) * AXIS, Color(0, 0, 1));
}

void ov_draw_point(b3Pos p_p, float p_size, b3HexColor p_color, void *p_context) {
	OverlayContext *c = static_cast<OverlayContext *>(p_context);
	// Deviation: upstream's size is a screen-space point size in pixels (the
	// callers pass 4..20, src/physics_world.c:1581-1615). Lines have no point
	// size, so it is mapped to a world-space cross a millimetre per pixel
	// across — the relative sizes upstream uses to rank contact states still
	// read, but they do not stay constant on screen.
	const float h = p_size * 0.001f;
	const Vector3 o = to_gd_pos(p_p);
	const Color col = ov_color(p_color);
	ov_line(c, o - Vector3(h, 0, 0), o + Vector3(h, 0, 0), col);
	ov_line(c, o - Vector3(0, h, 0), o + Vector3(0, h, 0), col);
	ov_line(c, o - Vector3(0, 0, h), o + Vector3(0, 0, h), col);
}

void ov_draw_sphere(b3Pos p_p, float p_radius, b3HexColor p_color, float p_alpha, void *p_context) {
	OverlayContext *c = static_cast<OverlayContext *>(p_context);
	const Vector3 o = to_gd_pos(p_p);
	const Color col = ov_color(p_color, p_alpha);
	ov_circle(c, o, Vector3(1, 0, 0), Vector3(0, 1, 0), p_radius, col);
	ov_circle(c, o, Vector3(0, 1, 0), Vector3(0, 0, 1), p_radius, col);
	ov_circle(c, o, Vector3(0, 0, 1), Vector3(1, 0, 0), p_radius, col);
}

void ov_draw_capsule(b3Pos p_p1, b3Pos p_p2, float p_radius, b3HexColor p_color, float p_alpha, void *p_context) {
	OverlayContext *c = static_cast<OverlayContext *>(p_context);
	const Vector3 a = to_gd_pos(p_p1);
	const Vector3 b = to_gd_pos(p_p2);
	const Color col = ov_color(p_color, p_alpha);
	Vector3 axis = b - a;
	if (axis.is_zero_approx()) {
		ov_draw_sphere(p_p1, p_radius, p_color, p_alpha, p_context);
		return;
	}
	Vector3 u, v;
	ov_frame(axis, u, v);
	ov_circle(c, a, u, v, p_radius, col);
	ov_circle(c, b, u, v, p_radius, col);
	// Cap outlines, so the ends read as round rather than flat.
	const Vector3 n = axis.normalized();
	ov_circle(c, a, u, -n, p_radius, col);
	ov_circle(c, b, u, n, p_radius, col);
	for (int i = 0; i < 4; ++i) {
		const float t = (float)i / 4.0f * (float)Math_TAU;
		const Vector3 off = (u * Math::cos(t) + v * Math::sin(t)) * p_radius;
		ov_line(c, a + off, b + off, col);
	}
}

// The 12 edges of an axis-aligned box given by its two corners.
void ov_box_edges(OverlayContext *c, const Vector3 p_corner[8], const Color &p_col) {
	static const int EDGES[12][2] = {
		{ 0, 1 }, { 1, 3 }, { 3, 2 }, { 2, 0 }, // -Z face
		{ 4, 5 }, { 5, 7 }, { 7, 6 }, { 6, 4 }, // +Z face
		{ 0, 4 }, { 1, 5 }, { 2, 6 }, { 3, 7 }
	};
	for (int i = 0; i < 12; ++i) {
		ov_line(c, p_corner[EDGES[i][0]], p_corner[EDGES[i][1]], p_col);
	}
}

void ov_draw_bounds(b3AABB p_aabb, b3HexColor p_color, void *p_context) {
	OverlayContext *c = static_cast<OverlayContext *>(p_context);
	const Vector3 lo = to_gd_pos(p_aabb.lowerBound);
	const Vector3 hi = to_gd_pos(p_aabb.upperBound);
	const Vector3 corner[8] = {
		Vector3(lo.x, lo.y, lo.z), Vector3(hi.x, lo.y, lo.z),
		Vector3(lo.x, hi.y, lo.z), Vector3(hi.x, hi.y, lo.z),
		Vector3(lo.x, lo.y, hi.z), Vector3(hi.x, lo.y, hi.z),
		Vector3(lo.x, hi.y, hi.z), Vector3(hi.x, hi.y, hi.z)
	};
	ov_box_edges(c, corner, ov_color(p_color));
}

void ov_draw_box(b3Vec3 p_extents, b3WorldTransform p_transform, b3HexColor p_color, void *p_context) {
	OverlayContext *c = static_cast<OverlayContext *>(p_context);
	// Half extents: upstream's only caller passes 0.1/0.05/0.025 times the
	// joint draw scale for a small marker box (src/weld_joint.c:311-313).
	const Basis basis(to_gd(p_transform.q));
	const Vector3 o = to_gd_pos(p_transform.p);
	const Vector3 e = to_gd(p_extents);
	Vector3 corner[8];
	for (int i = 0; i < 8; ++i) {
		const Vector3 local(
				(i & 1) ? e.x : -e.x,
				(i & 2) ? e.y : -e.y,
				(i & 4) ? e.z : -e.z);
		corner[i] = o + basis.xform(local);
	}
	ov_box_edges(c, corner, ov_color(p_color));
}

void ov_draw_string(b3Pos p_p, const char *p_s, b3HexColor p_color, void *p_context) {
	OverlayContext *c = static_cast<OverlayContext *>(p_context);
	if (c->label_used >= c->label_budget) {
		// A 16k-body scene with body names on would otherwise author 16k
		// Label3D nodes; the budget caps the overlay instead.
		return;
	}
	if (c->label_used >= (int)c->labels->size()) {
		Label3D *label = memnew(Label3D);
		label->set_as_top_level(true); // world space, like the shells
		label->set_billboard_mode(BaseMaterial3D::BILLBOARD_ENABLED);
		label->set_draw_flag(Label3D::FLAG_DOUBLE_SIDED, true);
		label->set_font_size(24);
		label->set_pixel_size(0.003f);
		c->parent->add_child(label);
		c->labels->push_back(label);
	}
	Label3D *label = (*c->labels)[c->label_used];
	c->label_used += 1;
	label->set_position(to_gd_pos(p_p));
	label->set_text(String::utf8(p_s));
	label->set_modulate(ov_color(p_color));
	label->set_visible(true);
}

} // namespace

bool Box3DWorld::debug_overlay_any() const {
	return debug_draw_joints || debug_draw_joint_extras || debug_draw_shape_bounds ||
			debug_draw_mass || debug_draw_sleep || debug_draw_body_names ||
			debug_draw_contacts || debug_draw_graph_colors || debug_draw_contact_features ||
			debug_draw_contact_normals || debug_draw_contact_forces || debug_draw_islands;
}

void Box3DWorld::update_debug_overlay() {
	if (!b3World_IsValid(world_id)) {
		return;
	}
	if (debug_overlay_mi == nullptr) {
		Ref<Shader> shader;
		shader.instantiate();
		// Same sRGB linearization as the shells: upstream's b3HexColor palette
		// is sRGB, and vertex alpha carries b3World_Draw's alpha argument.
		shader->set_code(R"(shader_type spatial;
render_mode unshaded, cull_disabled;

void fragment() {
	ALBEDO = pow(COLOR.rgb, vec3(2.2));
	ALPHA = COLOR.a;
}
)");
		Ref<ShaderMaterial> mat;
		mat.instantiate();
		mat->set_shader(shader);

		Ref<ImmediateMesh> mesh;
		mesh.instantiate();
		debug_overlay_mesh = mesh.ptr();

		debug_overlay_mi = memnew(MeshInstance3D);
		debug_overlay_mi->set_name("Box3DDebugOverlay");
		debug_overlay_mi->set_as_top_level(true); // draw in world space
		debug_overlay_mi->set_physics_interpolation_mode(Node::PHYSICS_INTERPOLATION_MODE_OFF);
		debug_overlay_mi->set_mesh(mesh);
		debug_overlay_mi->set_material_override(mat);
		add_child(debug_overlay_mi);
	}

	// b3World_Draw walks live solver state, so it must not run beside an
	// in-flight step; it would refuse the locked world anyway.
	join_async_step();

	b3DebugDraw draw = b3DefaultDebugDraw();
	// Shapes stay with the MultiMesh shells; without a create-debug-shape
	// callback this flag can only cost a colour computation per shape.
	draw.drawShapes = false;
	draw.drawJoints = debug_draw_joints;
	draw.drawJointExtras = debug_draw_joint_extras;
	draw.drawBounds = debug_draw_shape_bounds;
	draw.drawMass = debug_draw_mass;
	draw.drawSleep = debug_draw_sleep;
	draw.drawBodyNames = debug_draw_body_names;
	draw.drawContacts = debug_draw_contacts;
	draw.drawAnchorA = debug_draw_anchor_a;
	draw.drawGraphColors = debug_draw_graph_colors;
	draw.drawContactFeatures = debug_draw_contact_features;
	draw.drawContactNormals = debug_draw_contact_normals;
	draw.drawContactForces = debug_draw_contact_forces;
	draw.drawIslands = debug_draw_islands;
	draw.forceScale = (float)debug_force_scale;
	draw.jointScale = (float)debug_joint_scale;
	const AABB bounds = debug_drawing_bounds.abs();
	draw.drawingBounds.lowerBound = to_b3(bounds.position);
	draw.drawingBounds.upperBound = to_b3(bounds.position + bounds.size);

	draw.DrawShapeFcn = ov_draw_shape;
	draw.DrawSegmentFcn = ov_draw_segment;
	draw.DrawTransformFcn = ov_draw_transform;
	draw.DrawPointFcn = ov_draw_point;
	draw.DrawSphereFcn = ov_draw_sphere;
	draw.DrawCapsuleFcn = ov_draw_capsule;
	draw.DrawBoundsFcn = ov_draw_bounds;
	draw.DrawBoxFcn = ov_draw_box;
	draw.DrawStringFcn = ov_draw_string;

	OverlayContext ctx;
	ctx.mesh = debug_overlay_mesh;
	ctx.parent = this;
	ctx.labels = &debug_labels;
	ctx.label_budget = debug_label_budget;
	draw.context = &ctx;

	debug_overlay_mesh->clear_surfaces();
	debug_overlay_mesh->surface_begin(Mesh::PRIMITIVE_LINES);
	// maskBits selects which collision categories are visited by the broad
	// phase query (src/physics_world.c:1406-1409); the overlay never hides a
	// category, so every bit is set.
	b3World_Draw(world_id, &draw, UINT64_MAX);
	debug_overlay_mesh->surface_end();
	debug_overlay_mi->set_visible(true);

	for (size_t i = (size_t)ctx.label_used; i < debug_labels.size(); ++i) {
		debug_labels[i]->set_visible(false);
	}
}

void Box3DWorld::refresh_debug_overlay_visibility() {
	if (debug_overlay_any()) {
		debug_step_dirty = true; // repaint even in a frozen scene
		return;
	}
	if (debug_overlay_mi != nullptr) {
		debug_overlay_mesh->clear_surfaces();
		debug_overlay_mi->set_visible(false);
	}
	for (Label3D *label : debug_labels) {
		label->set_visible(false);
	}
}

void Box3DWorld::update_debug_draw() {
	if (!b3World_IsValid(world_id)) {
		return;
	}
	if (debug_mm[DEBUG_BOX] == nullptr) {
		// Solid state-colored shells, like upstream box3d's sample viewer. One
		// MultiMesh per primitive keeps thousands of bodies at a handful of
		// draw calls. A fixed-direction half-lambert ignores the sample's own
		// lighting/tonemap so the state colors read the same everywhere.
		Ref<Shader> shader;
		shader.instantiate();
		shader->set_code(R"(shader_type spatial;
render_mode unshaded;

void fragment() {
	vec3 light_vs = normalize((VIEW_MATRIX * vec4(0.35, 0.8, 0.45, 0.0)).xyz);
	float shade = clamp(dot(normalize(NORMAL), light_vs), 0.0, 1.0) * 0.55 + 0.45;
	// Instance colors are upstream's sRGB hex palette; linearize so the
	// rendered output matches it.
	ALBEDO = pow(COLOR.rgb, vec3(2.2)) * shade;
}
)");
		Ref<ShaderMaterial> mat;
		mat.instantiate();
		mat->set_shader(shader);

		Ref<BoxMesh> box_mesh;
		box_mesh.instantiate();
		box_mesh->set_size(Vector3(1, 1, 1));
		Ref<SphereMesh> sphere_mesh;
		sphere_mesh.instantiate();
		sphere_mesh->set_radius(0.5);
		sphere_mesh->set_height(1.0);
		Ref<CapsuleMesh> capsule_mesh;
		capsule_mesh.instantiate();
		capsule_mesh->set_radius(0.5);
		capsule_mesh->set_height(2.0);
		Ref<CylinderMesh> cylinder_mesh;
		cylinder_mesh.instantiate();
		cylinder_mesh->set_top_radius(0.5);
		cylinder_mesh->set_bottom_radius(0.5);
		cylinder_mesh->set_height(1.0);
		Ref<CylinderMesh> cone_mesh;
		cone_mesh.instantiate();
		cone_mesh->set_top_radius(0.0);
		cone_mesh->set_bottom_radius(0.5);
		cone_mesh->set_height(1.0);
		Ref<Mesh> meshes[DEBUG_PRIM_MAX] = { box_mesh, sphere_mesh, capsule_mesh, cylinder_mesh, cone_mesh };

		for (int p = 0; p < DEBUG_PRIM_MAX; ++p) {
			MultiMeshInstance3D *mi = memnew(MultiMeshInstance3D);
			mi->set_name(String("Box3DDebugDraw") + String::num_int64(p));
			mi->set_as_top_level(true); // draw in world space
			// Bulk multimesh_set_buffer uploads bypass the engine's own
			// multimesh physics interpolation; opt out so they render as-is.
			mi->set_physics_interpolation_mode(Node::PHYSICS_INTERPOLATION_MODE_OFF);
			// The shells are rewritten every physics tick already; interpolating
			// them too would just smear the debug view a frame behind.
			mi->set_physics_interpolation_mode(Node::PHYSICS_INTERPOLATION_MODE_OFF);
			Ref<MultiMesh> mm;
			mm.instantiate();
			mm->set_transform_format(MultiMesh::TRANSFORM_3D);
			mm->set_use_colors(true);
			mm->set_mesh(meshes[p]);
			// Without a custom AABB every buffer upload makes the renderer
			// recompute the bounds over all instances — half the refresh cost
			// at 16k bodies. Debug shells don't need accurate culling.
			mm->set_custom_aabb(AABB(Vector3(-100000, -100000, -100000), Vector3(200000, 200000, 200000)));
			mi->set_multimesh(mm);
			mi->set_material_override(mat);
			mi->set_visible(debug_draw);
			add_child(mi);
			debug_mm[p] = mi;
		}
	}

	// Callers are already post-join (sync step done, or async post-apply), so
	// this is a single atomic load; it guards any stray toggle-time path. The
	// per-body loops below therefore call the raw b3 API on cached ids instead
	// of the guarded wrappers — at 16k bodies the wrappers' per-call join +
	// revalidation dominated the whole refresh.
	join_async_step();

	// While every body sleeps nothing moves or changes color, so skip the
	// instance rewrite entirely. The first quiet frame still rebuilds, which
	// is what paints the pile in its sleeping colors. Members only: even one
	// b3 lookup per body here is measurable at this scale.
	bool any_awake = false;
	int body_count = 0;
	for (Box3DBody *body : bodies) {
		if (body == nullptr) {
			continue;
		}
		++body_count;
		if (!any_awake) {
			int type = body->get_body_type();
			// Kinematic bodies count as awake: scripts move them without the
			// cached dynamic-body sleep state ever seeing it.
			if (type == Box3DBody::KINEMATIC || (type == Box3DBody::DYNAMIC && body->get_snap_awake())) {
				any_awake = true;
			}
		}
	}
	if (!any_awake && !debug_last_any_awake && body_count == debug_last_body_count) {
		return;
	}
	debug_last_any_awake = any_awake;
	debug_last_body_count = body_count;

	const float INFLATE = 1.02f; // shells cover the samples' own visuals

	// Shells are written straight into the persistent upload buffers (grown
	// geometrically, never shrunk); the old intermediate Transform3D/Color
	// vectors doubled the memory traffic for nothing.
	int shell_count[DEBUG_PRIM_MAX] = {};
	float *shell_w[DEBUG_PRIM_MAX];
	for (int p = 0; p < DEBUG_PRIM_MAX; ++p) {
		shell_w[p] = debug_buffer[p].ptrw();
	}
	auto push_shell = [&](int prim, const Basis &basis, const Vector3 &origin, Vector3 scale, const Color &col) {
		PackedFloat32Array &buf = debug_buffer[prim];
		const int64_t need = ((int64_t)shell_count[prim] + 1) * 16;
		if (buf.size() < need) {
			const int64_t grow = buf.size() * 2;
			buf.resize(grow < need ? need : grow);
			shell_w[prim] = buf.ptrw();
		}
		scale *= INFLATE;
		float *inst = shell_w[prim] + (int64_t)shell_count[prim] * 16;
		++shell_count[prim];
		// Right-multiply the basis by diag(scale): component-scale each row.
		inst[0] = (float)(basis.rows[0][0] * scale.x);
		inst[1] = (float)(basis.rows[0][1] * scale.y);
		inst[2] = (float)(basis.rows[0][2] * scale.z);
		inst[3] = (float)origin.x;
		inst[4] = (float)(basis.rows[1][0] * scale.x);
		inst[5] = (float)(basis.rows[1][1] * scale.y);
		inst[6] = (float)(basis.rows[1][2] * scale.z);
		inst[7] = (float)origin.y;
		inst[8] = (float)(basis.rows[2][0] * scale.x);
		inst[9] = (float)(basis.rows[2][1] * scale.y);
		inst[10] = (float)(basis.rows[2][2] * scale.z);
		inst[11] = (float)origin.z;
		inst[12] = col.r;
		inst[13] = col.g;
		inst[14] = col.b;
		inst[15] = col.a;
	};

	for (Box3DBody *body : bodies) {
		if (body == nullptr || !body->get_debug_visualize()) {
			continue;
		}
		// A registered body's id is live by construction (bodies register only
		// after successful creation and unregister on destroy), so a null check
		// replaces a 16k-times-per-refresh b3Body_IsValid lookup.
		const b3BodyId id = body->get_body_id();
		if (B3_IS_NULL(id)) {
			continue;
		}
		// State colors: upstream box3d's exact palette and priority order
		// (physics_world.c). Red bad body, slate disabled, wheat sensor, lime
		// recent impact (hit event, standing in for the internal TOI flag),
		// turquoise awake bullet, yellow speed-capped, orange fast (moves
		// over half its min extent per step, the CCD criterion), dark gray
		// static, steel blues kinematic, tan awake / light slate asleep.
		const int type = body->get_body_type();
		const bool dynamic = type == Box3DBody::DYNAMIC;
		const bool awake = dynamic ? body->get_snap_awake() : (type == Box3DBody::KINEMATIC && b3Body_IsAwake(id));
		float lin_speed = 0.0f;
		float motion_speed = 0.0f; // upstream: |v| + |w| * maxExtent (farthest point)
		// Computed only when a branch below can use them (speed cap or CCD on),
		// and from the render snapshots rather than b3 velocity lookups: the
		// per-step transform delta over the step time IS the step's effective
		// velocity, and two more validated b3 calls per body are measurable
		// at 16k bodies.
		if (dynamic && awake && (max_linear_speed > 0.0 || continuous_collision)) {
			const b3WorldTransform &sp = body->get_snap_prev();
			const b3WorldTransform &sc = body->get_snap_curr();
			const float inv_dt = last_step_delta > 0.0 ? (float)(1.0 / last_step_delta) : 0.0f;
			const float dx = (float)(sc.p.x - sp.p.x);
			const float dy = (float)(sc.p.y - sp.p.y);
			const float dz = (float)(sc.p.z - sp.p.z);
			lin_speed = std::sqrt(dx * dx + dy * dy + dz * dz) * inv_dt;
			if (continuous_collision) {
				// Rotation delta angle between the two snapshots.
				float qd = std::abs(b3DotQuat(sp.q, sc.q));
				float ang = 2.0f * std::acos(qd < 1.0f ? qd : 1.0f);
				motion_speed = lin_speed + ang * inv_dt * body->get_cached_max_extent();
			}
		}
		Color col;
		if (dynamic && body->get_cached_mass() == 0.0f) {
			col = Color::hex(0xFF0000FF); // red: bad body
		} else if (!body->get_cached_enabled()) {
			col = Color::hex(0x708090FF); // slate gray: disabled
		} else if (body->get_is_sensor()) {
			col = Color::hex(0xF5DEB3FF); // wheat: sensor
		} else if (body->debug_hit_active()) {
			col = Color::hex(0x00FF00FF); // lime: recent impact
		} else if (body->get_continuous() && dynamic && awake) {
			col = Color::hex(0x40E0D0FF); // turquoise: awake bullet
		} else if (max_linear_speed > 0.0 && lin_speed >= (float)max_linear_speed * 0.99f) {
			col = Color::hex(0xFFFF00FF); // yellow: speed capped
		} else if (dynamic && continuous_collision && motion_speed * (float)last_step_delta > 0.5f * body->get_cached_min_extent()) {
			col = Color::hex(0xFFA500FF); // orange: fast (CCD territory)
		} else if (type == Box3DBody::STATIC) {
			col = Color::hex(0xA9A9A9FF); // dark gray: static
		} else if (type == Box3DBody::KINEMATIC) {
			col = awake ? Color::hex(0x4682B4FF) : Color::hex(0xB0C4DEFF); // steel blues
		} else {
			col = awake ? Color::hex(0xD2B48CFF) : Color::hex(0x778899FF); // tan / light slate
		}
		// Compound bodies: shell each Box3DCollisionShape child. The physics
		// ignores the body's own shape_type when child shapes exist, so drawing
		// it would show a collider that isn't there. The cached flag keeps the
		// common single-shape body from paying a get_child_count engine call.
		if (body->has_cached_child_shapes()) {
			for (int i = 0; i < body->get_child_count(); ++i) {
				Box3DCollisionShape *cs = Object::cast_to<Box3DCollisionShape>(body->get_child(i));
				if (cs == nullptr) {
					continue;
				}
				Transform3D cxf = cs->get_global_transform();
				float cr2 = (float)cs->get_capsule_radius();
				switch (cs->get_shape_type()) {
					case Box3DCollisionShape::SPHERE: {
						float r = (float)cs->get_sphere_radius();
						push_shell(DEBUG_SPHERE, cxf.basis, cxf.origin, Vector3(2 * r, 2 * r, 2 * r), col);
					} break;
					case Box3DCollisionShape::CAPSULE:
						push_shell(DEBUG_CAPSULE, cxf.basis, cxf.origin, Vector3(2 * cr2, (float)cs->get_capsule_height() * 0.5f, 2 * cr2), col);
						break;
					case Box3DCollisionShape::CYLINDER:
						push_shell(DEBUG_CYLINDER, cxf.basis, cxf.origin, Vector3(2 * cr2, (float)cs->get_capsule_height(), 2 * cr2), col);
						break;
					case Box3DCollisionShape::CONE:
						push_shell(DEBUG_CONE, cxf.basis, cxf.origin, Vector3(2 * cr2, (float)cs->get_capsule_height(), 2 * cr2), col);
						break;
					case Box3DCollisionShape::BOX:
					default:
						push_shell(DEBUG_BOX, cxf.basis, cxf.origin, cs->get_box_size(), col);
						break;
				}
			}
			continue;
		}
		// From the solver, not the node: renderer-managed bodies (with
		// sync_node_transform off) keep a stale node pose. Dynamic bodies read
		// the snapshot sync_from_physics already recorded this tick; kinematic
		// and static bodies (few, and not snapshotted) ask b3 directly.
		const b3WorldTransform bxf = dynamic ? body->get_snap_curr() : b3Body_GetTransform(id);
		const Basis basis(to_gd(bxf.q));
		const Vector3 origin = to_gd_pos(bxf.p);
		float cr = (float)body->get_capsule_radius();
		float ch = (float)body->get_capsule_height();
		// Node scale is baked into the collider at creation and does NOT reach
		// the solver transform (b3WorldTransform is position + rotation only),
		// so the shell has to reapply it — the same way box3d_body.cpp applied
		// it to the geometry: componentwise for boxes and hulls, the widest
		// horizontal component for radii Box3D cannot make elliptical
		// (box3d_body.cpp:280, :289-293). Reading the baked value costs nothing;
		// an unscaled body takes the exact previous arithmetic.
		const bool scaled = body->is_node_scaled();
		const Vector3 ns = scaled ? body->get_node_scale() : Vector3(1, 1, 1);
		const float rad_s = scaled ? (float)MAX(Math::abs(ns.x), Math::abs(ns.z)) : 1.0f;
		switch (body->get_shape_type()) {
			case Box3DBody::SPHERE: {
				// b3Sphere has one radius, so a scaled sphere collider grows by
				// the largest absolute component.
				float r = (float)body->get_sphere_radius() *
						(scaled ? (float)MAX(Math::abs(ns.x), MAX(Math::abs(ns.y), Math::abs(ns.z))) : 1.0f);
				push_shell(DEBUG_SPHERE, basis, origin, Vector3(2 * r, 2 * r, 2 * r), col);
			} break;
			case Box3DBody::CAPSULE: {
				// Caps follow y, radius follows the widest of x/z: total height
				// is (ch - 2r) * |y| + 2 * r * rad_s, matching the collider.
				float cap_r = cr * rad_s;
				float straight = ch - 2.0f * cr;
				if (straight < 0.0f) {
					straight = 0.0f;
				}
				float total_h = straight * (scaled ? (float)Math::abs(ns.y) : 1.0f) + 2.0f * cap_r;
				push_shell(DEBUG_CAPSULE, basis, origin, Vector3(2 * cap_r, total_h * 0.5f, 2 * cap_r), col);
			} break;
			case Box3DBody::CYLINDER:
				push_shell(DEBUG_CYLINDER, basis, origin,
						Vector3(2 * cr * (float)Math::abs(ns.x), ch * (float)Math::abs(ns.y), 2 * cr * (float)Math::abs(ns.z)), col);
				break;
			case Box3DBody::CONE:
				push_shell(DEBUG_CONE, basis, origin,
						Vector3(2 * cr * (float)Math::abs(ns.x), ch * (float)Math::abs(ns.y), 2 * cr * (float)Math::abs(ns.z)), col);
				break;
			case Box3DBody::BOX:
				push_shell(DEBUG_BOX, basis, origin, body->get_box_size() * ns.abs(), col);
				break;
			default:
				break; // Hull / mesh colliders are not shelled
		}
	}

	for (int p = 0; p < DEBUG_PRIM_MAX; ++p) {
		Ref<MultiMesh> mm = debug_mm[p]->get_multimesh();
		const int n = shell_count[p];
		// One bulk buffer upload instead of two RenderingServer calls per
		// instance — per-instance writes cost ~160 ms/frame at 16k bodies. The
		// multimesh is kept sized to the whole (grow-only) buffer; instances
		// past n are zeroed and invisible.
		const int alloc = (int)(debug_buffer[p].size() / 16);
		if (alloc == 0) {
			mm->set_visible_instance_count(0);
			continue; // no shells of this primitive; 0-size uploads error out
		}
		if (mm->get_instance_count() != alloc) {
			mm->set_instance_count(alloc);
		}
		mm->set_visible_instance_count(n);
		if (alloc > n) {
			memset(shell_w[p] + (int64_t)n * 16, 0, ((int64_t)alloc - n) * 16 * sizeof(float));
		}
		RenderingServer::get_singleton()->multimesh_set_buffer(mm->get_rid(), debug_buffer[p]);
	}
}

void Box3DWorld::set_debug_draw(bool p_enabled) {
	debug_draw = p_enabled;
	debug_last_body_count = -1; // force a rebuild on the next step
	debug_step_dirty = true; // even without a step (paused / standstill scene)
	for (int p = 0; p < DEBUG_PRIM_MAX; ++p) {
		if (debug_mm[p] != nullptr) {
			debug_mm[p]->set_visible(p_enabled);
		}
	}
}

bool Box3DWorld::get_debug_draw() const {
	return debug_draw;
}

// One pair per b3DebugDraw option. Every setter goes through
// refresh_debug_overlay_visibility() so switching the last one off clears the
// lines and hides the labels in the same frame, even if the scene is frozen.
#define BOX3D_DEBUG_OVERLAY_FLAG(m_name, m_field)      \
	void Box3DWorld::set_##m_name(bool p_enabled) {    \
		m_field = p_enabled;                           \
		refresh_debug_overlay_visibility();            \
	}                                                  \
	bool Box3DWorld::get_##m_name() const {            \
		return m_field;                                \
	}

BOX3D_DEBUG_OVERLAY_FLAG(debug_draw_joints, debug_draw_joints)
BOX3D_DEBUG_OVERLAY_FLAG(debug_draw_joint_extras, debug_draw_joint_extras)
BOX3D_DEBUG_OVERLAY_FLAG(debug_draw_shape_bounds, debug_draw_shape_bounds)
BOX3D_DEBUG_OVERLAY_FLAG(debug_draw_mass, debug_draw_mass)
BOX3D_DEBUG_OVERLAY_FLAG(debug_draw_sleep, debug_draw_sleep)
BOX3D_DEBUG_OVERLAY_FLAG(debug_draw_body_names, debug_draw_body_names)
BOX3D_DEBUG_OVERLAY_FLAG(debug_draw_contacts, debug_draw_contacts)
BOX3D_DEBUG_OVERLAY_FLAG(debug_draw_anchor_a, debug_draw_anchor_a)
BOX3D_DEBUG_OVERLAY_FLAG(debug_draw_graph_colors, debug_draw_graph_colors)
BOX3D_DEBUG_OVERLAY_FLAG(debug_draw_contact_features, debug_draw_contact_features)
BOX3D_DEBUG_OVERLAY_FLAG(debug_draw_contact_normals, debug_draw_contact_normals)
BOX3D_DEBUG_OVERLAY_FLAG(debug_draw_contact_forces, debug_draw_contact_forces)
BOX3D_DEBUG_OVERLAY_FLAG(debug_draw_islands, debug_draw_islands)

#undef BOX3D_DEBUG_OVERLAY_FLAG

void Box3DWorld::set_debug_force_scale(double p_scale) {
	debug_force_scale = p_scale;
	debug_step_dirty = true;
}

double Box3DWorld::get_debug_force_scale() const {
	return debug_force_scale;
}

void Box3DWorld::set_debug_joint_scale(double p_scale) {
	debug_joint_scale = p_scale;
	debug_step_dirty = true;
}

double Box3DWorld::get_debug_joint_scale() const {
	return debug_joint_scale;
}

void Box3DWorld::set_debug_drawing_bounds(const AABB &p_bounds) {
	debug_drawing_bounds = p_bounds;
	debug_step_dirty = true;
}

AABB Box3DWorld::get_debug_drawing_bounds() const {
	return debug_drawing_bounds;
}

void Box3DWorld::set_contact_hertz(double p_hertz) {
	contact_hertz = p_hertz;
	apply_contact_tuning();
}

double Box3DWorld::get_contact_hertz() const {
	return contact_hertz;
}

void Box3DWorld::set_contact_damping(double p_damping) {
	contact_damping = p_damping;
	apply_contact_tuning();
}

double Box3DWorld::get_contact_damping() const {
	return contact_damping;
}

void Box3DWorld::set_enable_sleep(bool p_enabled) {
	enable_sleep = p_enabled;
	if (b3World_IsValid(world_id)) {
		join_async_step();
		b3World_EnableSleeping(world_id, enable_sleep);
	}
}

bool Box3DWorld::get_enable_sleep() const {
	return enable_sleep;
}

void Box3DWorld::set_enable_warm_starting(bool p_enabled) {
	enable_warm_starting = p_enabled;
	if (b3World_IsValid(world_id)) {
		join_async_step();
		b3World_EnableWarmStarting(world_id, enable_warm_starting);
	}
}

bool Box3DWorld::get_enable_warm_starting() const {
	return enable_warm_starting;
}

void Box3DWorld::set_contact_speed(double p_speed) {
	contact_speed = p_speed;
	apply_contact_tuning();
}

double Box3DWorld::get_contact_speed() const {
	return contact_speed;
}

void Box3DWorld::set_hit_event_threshold(double p_speed) {
	hit_event_threshold = p_speed;
	if (b3World_IsValid(world_id)) {
		join_async_step();
		b3World_SetHitEventThreshold(world_id, (float)hit_event_threshold);
	}
}

double Box3DWorld::get_hit_event_threshold() const {
	return hit_event_threshold;
}

void Box3DWorld::set_restitution_threshold(double p_speed) {
	restitution_threshold = p_speed;
	if (b3World_IsValid(world_id)) {
		join_async_step();
		b3World_SetRestitutionThreshold(world_id, (float)restitution_threshold);
	}
}

double Box3DWorld::get_restitution_threshold() const {
	return restitution_threshold;
}

void Box3DWorld::set_contact_recycle_distance(double p_distance) {
	contact_recycle_distance = p_distance;
	if (b3World_IsValid(world_id)) {
		join_async_step();
		b3World_SetContactRecycleDistance(world_id, (float)contact_recycle_distance);
	}
}

// b3WorldDef.capacity is read once, by b3CreateWorld. Setting one of these on
// a live world stores it for the next creation and changes nothing now, which
// is why they are plain fields with no join and no b3 call.
#define BOX3D_CAPACITY_FIELD(m_name)                     \
	void Box3DWorld::set_##m_name(int p_count) {         \
		m_name = p_count < 0 ? 0 : p_count;              \
	}                                                    \
	int Box3DWorld::get_##m_name() const {               \
		return m_name;                                   \
	}

BOX3D_CAPACITY_FIELD(capacity_static_shapes)
BOX3D_CAPACITY_FIELD(capacity_dynamic_shapes)
BOX3D_CAPACITY_FIELD(capacity_static_bodies)
BOX3D_CAPACITY_FIELD(capacity_dynamic_bodies)
BOX3D_CAPACITY_FIELD(capacity_contacts)

#undef BOX3D_CAPACITY_FIELD

double Box3DWorld::get_contact_recycle_distance() const {
	return contact_recycle_distance;
}

void Box3DWorld::_bind_methods() {
	// Before anything else this class can do, and before any scene exists:
	// b3SetLengthUnitsPerMeter has to precede every other Box3D call
	// (constants.h:11). See apply_length_units_setting().
	apply_length_units_setting();

	ClassDB::bind_method(D_METHOD("step", "delta"), &Box3DWorld::step);
	// Both filter halves default to b3DefaultQueryFilter's UINT64_MAX
	// (types.h:13-14, src/types.c:55), so an omitted argument is exactly the
	// filter these queries used before the category half existed.
	ClassDB::bind_method(D_METHOD("raycast", "from", "to", "collision_mask", "collision_layer"), &Box3DWorld::raycast, DEFVAL(B3_DEFAULT_MASK_BITS), DEFVAL(B3_DEFAULT_CATEGORY_BITS));
	ClassDB::bind_method(D_METHOD("raycast_all", "from", "to", "collision_mask", "collision_layer"), &Box3DWorld::raycast_all, DEFVAL(B3_DEFAULT_MASK_BITS), DEFVAL(B3_DEFAULT_CATEGORY_BITS));
	ClassDB::bind_method(D_METHOD("overlap_sphere", "center", "radius", "collision_mask", "collision_layer"), &Box3DWorld::overlap_sphere, DEFVAL(B3_DEFAULT_MASK_BITS), DEFVAL(B3_DEFAULT_CATEGORY_BITS));
	ClassDB::bind_method(D_METHOD("overlap_box", "center", "size", "collision_mask", "collision_layer"), &Box3DWorld::overlap_box, DEFVAL(B3_DEFAULT_MASK_BITS), DEFVAL(B3_DEFAULT_CATEGORY_BITS));
	ClassDB::bind_method(D_METHOD("overlap_aabb", "aabb", "collision_mask", "collision_layer"), &Box3DWorld::overlap_aabb, DEFVAL(B3_DEFAULT_MASK_BITS), DEFVAL(B3_DEFAULT_CATEGORY_BITS));
	ClassDB::bind_method(D_METHOD("overlap_capsule", "point_a", "point_b", "radius", "collision_mask", "collision_layer"), &Box3DWorld::overlap_capsule, DEFVAL(B3_DEFAULT_MASK_BITS), DEFVAL(B3_DEFAULT_CATEGORY_BITS));
	ClassDB::bind_method(D_METHOD("overlap_convex", "points", "collision_mask", "collision_layer"), &Box3DWorld::overlap_convex, DEFVAL(B3_DEFAULT_MASK_BITS), DEFVAL(B3_DEFAULT_CATEGORY_BITS));
	ClassDB::bind_method(D_METHOD("shape_cast_capsule", "point_a", "point_b", "radius", "motion", "collision_mask", "collision_layer"), &Box3DWorld::shape_cast_capsule, DEFVAL(B3_DEFAULT_MASK_BITS), DEFVAL(B3_DEFAULT_CATEGORY_BITS));
	ClassDB::bind_method(D_METHOD("shape_cast_convex", "points", "motion", "collision_mask", "collision_layer"), &Box3DWorld::shape_cast_convex, DEFVAL(B3_DEFAULT_MASK_BITS), DEFVAL(B3_DEFAULT_CATEGORY_BITS));
	ClassDB::bind_method(D_METHOD("get_last_query_stats"), &Box3DWorld::get_last_query_stats);
	ClassDB::bind_method(D_METHOD("set_contact_rules", "rules"), &Box3DWorld::set_contact_rules);
	ClassDB::bind_method(D_METHOD("get_contact_rules"), &Box3DWorld::get_contact_rules);
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "contact_rules", PROPERTY_HINT_RESOURCE_TYPE, "Box3DContactRules"),
			"set_contact_rules", "get_contact_rules");
	ClassDB::bind_method(D_METHOD("start_recording", "recording"), &Box3DWorld::start_recording);
	ClassDB::bind_method(D_METHOD("stop_recording"), &Box3DWorld::stop_recording);
	ClassDB::bind_method(D_METHOD("is_recording"), &Box3DWorld::is_recording);
	ClassDB::bind_method(D_METHOD("get_recording"), &Box3DWorld::get_recording);
	ClassDB::bind_method(D_METHOD("shape_cast_box", "from", "to", "size", "collision_mask", "collision_layer"), &Box3DWorld::shape_cast_box, DEFVAL(B3_DEFAULT_MASK_BITS), DEFVAL(B3_DEFAULT_CATEGORY_BITS));
	ClassDB::bind_method(D_METHOD("is_contact_valid", "contact_id"), &Box3DWorld::is_contact_valid);
	ClassDB::bind_method(D_METHOD("get_contact_data", "contact_id"), &Box3DWorld::get_contact_data);
	ClassDB::bind_method(D_METHOD("get_awake_body_count"), &Box3DWorld::get_awake_body_count);
	ClassDB::bind_method(D_METHOD("get_bounds"), &Box3DWorld::get_bounds);
	ClassDB::bind_method(D_METHOD("shape_cast_sphere", "from", "to", "radius", "collision_mask", "collision_layer"), &Box3DWorld::shape_cast_sphere, DEFVAL(B3_DEFAULT_MASK_BITS), DEFVAL(B3_DEFAULT_CATEGORY_BITS));
	ClassDB::bind_method(D_METHOD("explode", "center", "radius", "impulse_per_area", "falloff", "collision_mask"), &Box3DWorld::explode, DEFVAL(0.0), DEFVAL(B3_DEFAULT_MASK_BITS));

	ClassDB::bind_method(D_METHOD("set_gravity", "gravity"), &Box3DWorld::set_gravity);
	ClassDB::bind_method(D_METHOD("get_gravity"), &Box3DWorld::get_gravity);
	ClassDB::bind_method(D_METHOD("set_substep_count", "count"), &Box3DWorld::set_substep_count);
	ClassDB::bind_method(D_METHOD("get_substep_count"), &Box3DWorld::get_substep_count);
	ClassDB::bind_method(D_METHOD("set_auto_step", "enabled"), &Box3DWorld::set_auto_step);
	ClassDB::bind_method(D_METHOD("get_auto_step"), &Box3DWorld::get_auto_step);
	ClassDB::bind_method(D_METHOD("set_continuous_collision", "enabled"), &Box3DWorld::set_continuous_collision);
	ClassDB::bind_method(D_METHOD("get_continuous_collision"), &Box3DWorld::get_continuous_collision);
	ClassDB::bind_method(D_METHOD("set_max_linear_speed", "speed"), &Box3DWorld::set_max_linear_speed);
	ClassDB::bind_method(D_METHOD("get_max_linear_speed"), &Box3DWorld::get_max_linear_speed);
	ClassDB::bind_method(D_METHOD("set_worker_count", "count"), &Box3DWorld::set_worker_count);
	ClassDB::bind_method(D_METHOD("get_step_time_ms"), &Box3DWorld::get_step_time_ms);
	ClassDB::bind_method(D_METHOD("get_profile"), &Box3DWorld::get_profile);
	ClassDB::bind_method(D_METHOD("get_counters"), &Box3DWorld::get_counters);
	ClassDB::bind_method(D_METHOD("get_live_settings"), &Box3DWorld::get_live_settings);
	ClassDB::bind_method(D_METHOD("get_max_capacity"), &Box3DWorld::get_max_capacity);
	ClassDB::bind_static_method("Box3DWorld", D_METHOD("get_length_units_per_meter"), &Box3DWorld::get_length_units_per_meter);
	ClassDB::bind_static_method("Box3DWorld", D_METHOD("set_length_units_per_meter", "units"), &Box3DWorld::set_length_units_per_meter);
	ClassDB::bind_static_method("Box3DWorld", D_METHOD("get_world_count"), &Box3DWorld::get_world_count);
	ClassDB::bind_static_method("Box3DWorld", D_METHOD("get_max_world_count"), &Box3DWorld::get_max_world_count);
	ClassDB::bind_static_method("Box3DWorld", D_METHOD("get_graph_color_count"), &Box3DWorld::get_graph_color_count);
	ClassDB::bind_static_method("Box3DWorld", D_METHOD("get_graph_color", "index"), &Box3DWorld::get_graph_color);
	ClassDB::bind_static_method("Box3DWorld", D_METHOD("make_debug_color", "color", "material"), &Box3DWorld::make_debug_color, DEFVAL(DEBUG_MATERIAL_DEFAULT));
	ClassDB::bind_method(D_METHOD("set_capacity_static_shapes", "count"), &Box3DWorld::set_capacity_static_shapes);
	ClassDB::bind_method(D_METHOD("get_capacity_static_shapes"), &Box3DWorld::get_capacity_static_shapes);
	ClassDB::bind_method(D_METHOD("set_capacity_dynamic_shapes", "count"), &Box3DWorld::set_capacity_dynamic_shapes);
	ClassDB::bind_method(D_METHOD("get_capacity_dynamic_shapes"), &Box3DWorld::get_capacity_dynamic_shapes);
	ClassDB::bind_method(D_METHOD("set_capacity_static_bodies", "count"), &Box3DWorld::set_capacity_static_bodies);
	ClassDB::bind_method(D_METHOD("get_capacity_static_bodies"), &Box3DWorld::get_capacity_static_bodies);
	ClassDB::bind_method(D_METHOD("set_capacity_dynamic_bodies", "count"), &Box3DWorld::set_capacity_dynamic_bodies);
	ClassDB::bind_method(D_METHOD("get_capacity_dynamic_bodies"), &Box3DWorld::get_capacity_dynamic_bodies);
	ClassDB::bind_method(D_METHOD("set_capacity_contacts", "count"), &Box3DWorld::set_capacity_contacts);
	ClassDB::bind_method(D_METHOD("get_capacity_contacts"), &Box3DWorld::get_capacity_contacts);
	ClassDB::bind_method(D_METHOD("set_async_step", "enabled"), &Box3DWorld::set_async_step);
	ClassDB::bind_method(D_METHOD("get_async_step"), &Box3DWorld::get_async_step);
	ClassDB::bind_method(D_METHOD("get_worker_count"), &Box3DWorld::get_worker_count);
	ClassDB::bind_method(D_METHOD("set_debug_draw", "enabled"), &Box3DWorld::set_debug_draw);
	ClassDB::bind_method(D_METHOD("get_debug_draw"), &Box3DWorld::get_debug_draw);
	ClassDB::bind_method(D_METHOD("set_debug_draw_joints", "enabled"), &Box3DWorld::set_debug_draw_joints);
	ClassDB::bind_method(D_METHOD("get_debug_draw_joints"), &Box3DWorld::get_debug_draw_joints);
	ClassDB::bind_method(D_METHOD("set_debug_draw_joint_extras", "enabled"), &Box3DWorld::set_debug_draw_joint_extras);
	ClassDB::bind_method(D_METHOD("get_debug_draw_joint_extras"), &Box3DWorld::get_debug_draw_joint_extras);
	ClassDB::bind_method(D_METHOD("set_debug_draw_shape_bounds", "enabled"), &Box3DWorld::set_debug_draw_shape_bounds);
	ClassDB::bind_method(D_METHOD("get_debug_draw_shape_bounds"), &Box3DWorld::get_debug_draw_shape_bounds);
	ClassDB::bind_method(D_METHOD("set_debug_draw_mass", "enabled"), &Box3DWorld::set_debug_draw_mass);
	ClassDB::bind_method(D_METHOD("get_debug_draw_mass"), &Box3DWorld::get_debug_draw_mass);
	ClassDB::bind_method(D_METHOD("set_debug_draw_sleep", "enabled"), &Box3DWorld::set_debug_draw_sleep);
	ClassDB::bind_method(D_METHOD("get_debug_draw_sleep"), &Box3DWorld::get_debug_draw_sleep);
	ClassDB::bind_method(D_METHOD("set_debug_draw_body_names", "enabled"), &Box3DWorld::set_debug_draw_body_names);
	ClassDB::bind_method(D_METHOD("get_debug_draw_body_names"), &Box3DWorld::get_debug_draw_body_names);
	ClassDB::bind_method(D_METHOD("set_debug_draw_contacts", "enabled"), &Box3DWorld::set_debug_draw_contacts);
	ClassDB::bind_method(D_METHOD("get_debug_draw_contacts"), &Box3DWorld::get_debug_draw_contacts);
	ClassDB::bind_method(D_METHOD("set_debug_draw_anchor_a", "enabled"), &Box3DWorld::set_debug_draw_anchor_a);
	ClassDB::bind_method(D_METHOD("get_debug_draw_anchor_a"), &Box3DWorld::get_debug_draw_anchor_a);
	ClassDB::bind_method(D_METHOD("set_debug_draw_graph_colors", "enabled"), &Box3DWorld::set_debug_draw_graph_colors);
	ClassDB::bind_method(D_METHOD("get_debug_draw_graph_colors"), &Box3DWorld::get_debug_draw_graph_colors);
	ClassDB::bind_method(D_METHOD("set_debug_draw_contact_features", "enabled"), &Box3DWorld::set_debug_draw_contact_features);
	ClassDB::bind_method(D_METHOD("get_debug_draw_contact_features"), &Box3DWorld::get_debug_draw_contact_features);
	ClassDB::bind_method(D_METHOD("set_debug_draw_contact_normals", "enabled"), &Box3DWorld::set_debug_draw_contact_normals);
	ClassDB::bind_method(D_METHOD("get_debug_draw_contact_normals"), &Box3DWorld::get_debug_draw_contact_normals);
	ClassDB::bind_method(D_METHOD("set_debug_draw_contact_forces", "enabled"), &Box3DWorld::set_debug_draw_contact_forces);
	ClassDB::bind_method(D_METHOD("get_debug_draw_contact_forces"), &Box3DWorld::get_debug_draw_contact_forces);
	ClassDB::bind_method(D_METHOD("set_debug_draw_islands", "enabled"), &Box3DWorld::set_debug_draw_islands);
	ClassDB::bind_method(D_METHOD("get_debug_draw_islands"), &Box3DWorld::get_debug_draw_islands);
	ClassDB::bind_method(D_METHOD("set_debug_force_scale", "scale"), &Box3DWorld::set_debug_force_scale);
	ClassDB::bind_method(D_METHOD("get_debug_force_scale"), &Box3DWorld::get_debug_force_scale);
	ClassDB::bind_method(D_METHOD("set_debug_joint_scale", "scale"), &Box3DWorld::set_debug_joint_scale);
	ClassDB::bind_method(D_METHOD("get_debug_joint_scale"), &Box3DWorld::get_debug_joint_scale);
	ClassDB::bind_method(D_METHOD("set_debug_drawing_bounds", "bounds"), &Box3DWorld::set_debug_drawing_bounds);
	ClassDB::bind_method(D_METHOD("get_debug_drawing_bounds"), &Box3DWorld::get_debug_drawing_bounds);
	ClassDB::bind_method(D_METHOD("set_contact_hertz", "hertz"), &Box3DWorld::set_contact_hertz);
	ClassDB::bind_method(D_METHOD("get_contact_hertz"), &Box3DWorld::get_contact_hertz);
	ClassDB::bind_method(D_METHOD("set_contact_damping", "damping"), &Box3DWorld::set_contact_damping);
	ClassDB::bind_method(D_METHOD("get_contact_damping"), &Box3DWorld::get_contact_damping);
	ClassDB::bind_method(D_METHOD("set_enable_sleep", "enabled"), &Box3DWorld::set_enable_sleep);
	ClassDB::bind_method(D_METHOD("get_enable_sleep"), &Box3DWorld::get_enable_sleep);
	ClassDB::bind_method(D_METHOD("set_enable_warm_starting", "enabled"), &Box3DWorld::set_enable_warm_starting);
	ClassDB::bind_method(D_METHOD("get_enable_warm_starting"), &Box3DWorld::get_enable_warm_starting);
	ClassDB::bind_method(D_METHOD("set_contact_speed", "speed"), &Box3DWorld::set_contact_speed);
	ClassDB::bind_method(D_METHOD("get_contact_speed"), &Box3DWorld::get_contact_speed);
	ClassDB::bind_method(D_METHOD("set_hit_event_threshold", "speed"), &Box3DWorld::set_hit_event_threshold);
	ClassDB::bind_method(D_METHOD("get_hit_event_threshold"), &Box3DWorld::get_hit_event_threshold);
	ClassDB::bind_method(D_METHOD("set_restitution_threshold", "speed"), &Box3DWorld::set_restitution_threshold);
	ClassDB::bind_method(D_METHOD("get_restitution_threshold"), &Box3DWorld::get_restitution_threshold);
	ClassDB::bind_method(D_METHOD("set_contact_recycle_distance", "distance"), &Box3DWorld::set_contact_recycle_distance);
	ClassDB::bind_method(D_METHOD("get_contact_recycle_distance"), &Box3DWorld::get_contact_recycle_distance);

	// One entry per b3ContactHitEvent, emitted after the step that produced it:
	//   body_a / body_b          the two Box3DBody nodes
	//   shape_a / shape_b        their Box3DCollisionShape, or null for a
	//                            body's own shape_type shape
	//   point                    world-space mid-point between the surfaces
	//   normal                   unit normal pointing from A towards B
	//   approach_speed           closing speed in m/s, always positive
	//   user_material_a/_b       the shapes' b3SurfaceMaterial.userMaterialId
	//   contact_id               opaque handle, see is_contact_valid()
	// Only collisions faster than hit_event_threshold are reported.
	ADD_SIGNAL(MethodInfo("contact_hit", PropertyInfo(Variant::DICTIONARY, "hit")));

	// One entry per b3ContactBeginTouchEvent / b3ContactEndTouchEvent:
	//   body_a / body_b          the two Box3DBody nodes
	//   shape_a / shape_b        their Box3DCollisionShape, or null for a
	//                            body's own shape_type shape
	//   contact_id               opaque handle for get_contact_data()
	// Box3DBody.body_entered / body_exited report the same touches from each
	// body's point of view; these two exist because the contact HANDLE belongs
	// to the pair, and upstream reports the event once per pair. On an end
	// event every id in the payload may already be dangling — the shapes are
	// filtered through b3Shape_IsValid, and the contact id is exactly what
	// is_contact_valid() answers false for.
	ADD_SIGNAL(MethodInfo("contact_began", PropertyInfo(Variant::DICTIONARY, "contact")));
	ADD_SIGNAL(MethodInfo("contact_ended", PropertyInfo(Variant::DICTIONARY, "contact")));

	// A joint whose constraint force or torque reached the threshold set on the
	// node (Box3DJoint.force_threshold / torque_threshold) during the step, with
	// the world-frame force and torque read back at event time. This is the
	// breakable-joint primitive: connect it and free or disable the joint.
	// A body that fell asleep during the step, from b3BodyMoveEvent.fellAsleep.
	// There is no matching "woke" event in Box3D; poll Box3DBody.is_awake() for
	// the level.
	ADD_SIGNAL(MethodInfo("body_fell_asleep",
			PropertyInfo(Variant::OBJECT, "body", PROPERTY_HINT_RESOURCE_TYPE, "Box3DBody")));

	ADD_SIGNAL(MethodInfo("joint_threshold_exceeded",
			PropertyInfo(Variant::OBJECT, "joint", PROPERTY_HINT_RESOURCE_TYPE, "Box3DJoint"),
			PropertyInfo(Variant::VECTOR3, "force", PROPERTY_HINT_NONE, "suffix:N"),
			PropertyInfo(Variant::VECTOR3, "torque", PROPERTY_HINT_NONE, String::utf8("suffix:N\xc2\xb7m"))));

	// Inspector layout. Property ORDER here is inspector order, and ADD_GROUP
	// applies to every property declared after it, so the two ungrouped
	// properties (the ones a first scene actually needs) come first.
	//
	// Units: this binding is fixed at one Box3D length unit per metre, so every
	// suffix below is literal, not a convention. The "\xc2\xb2" is a UTF-8
	// superscript two written as bytes so the source stays ASCII (MSVC without
	// /utf-8 would otherwise re-encode it).
	ADD_PROPERTY(PropertyInfo(Variant::VECTOR3, "gravity", PROPERTY_HINT_NONE, String::utf8("suffix:m/s\xc2\xb2")), "set_gravity", "get_gravity");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "auto_step"), "set_auto_step", "get_auto_step");

	ADD_GROUP("Solver", "");
	// Not capped at 16: more substeps are legal, just progressively more
	// expensive, so the slider stops where the useful range does.
	ADD_PROPERTY(PropertyInfo(Variant::INT, "substep_count", PROPERTY_HINT_RANGE, "1,16,1,or_greater"), "set_substep_count", "get_substep_count");
	// Box3D clamps workers to [1, B3_MAX_WORKERS] (32, constants.h).
	ADD_PROPERTY(PropertyInfo(Variant::INT, "worker_count", PROPERTY_HINT_RANGE, "1,32,1"), "set_worker_count", "get_worker_count");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "async_step"), "set_async_step", "get_async_step");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "continuous_collision"), "set_continuous_collision", "get_continuous_collision");
	// 0 is not "no limit": it means "leave Box3D's own default alone", which is
	// 400 m/s (b3DefaultWorldDef).
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "max_linear_speed", PROPERTY_HINT_RANGE, "0,1000,0.1,or_greater,suffix:m/s"), "set_max_linear_speed", "get_max_linear_speed");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "enable_sleep"), "set_enable_sleep", "get_enable_sleep");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "enable_warm_starting"), "set_enable_warm_starting", "get_enable_warm_starting");

	ADD_GROUP("Contact", "contact_");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "contact_hertz", PROPERTY_HINT_RANGE, "0,120,0.1,or_greater,suffix:Hz"), "set_contact_hertz", "get_contact_hertz");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "contact_damping", PROPERTY_HINT_RANGE, "0,20,0.01,or_greater"), "set_contact_damping", "get_contact_damping");
	// Maximum speed the solver may push overlapping shapes apart with.
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "contact_speed", PROPERTY_HINT_RANGE, "0,20,0.01,or_greater,suffix:m/s"), "set_contact_speed", "get_contact_speed");
	// 0 disables contact point recycling entirely (box3d.h:187-188).
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "contact_recycle_distance", PROPERTY_HINT_RANGE, "0,1,0.001,or_greater,suffix:m"), "set_contact_recycle_distance", "get_contact_recycle_distance");
	// Gates the contact_hit signal: below this closing speed no hit event is
	// produced at all, so raising it is how an impact sound stops firing on
	// every settling crate.
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "hit_event_threshold", PROPERTY_HINT_RANGE, "0,20,0.01,or_greater,suffix:m/s"), "set_hit_event_threshold", "get_hit_event_threshold");
	// Upstream warns against very small values here: they keep bodies awake.
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "restitution_threshold", PROPERTY_HINT_RANGE, "0,20,0.01,or_greater,suffix:m/s"), "set_restitution_threshold", "get_restitution_threshold");

	// b3WorldDef.capacity: expected counts, read ONLY when the world is created.
	// 0 means "let Box3D grow on demand", which is its own default. Measure a
	// representative run with get_max_capacity(), then author those numbers here
	// to remove the reallocations from the steady state.
	ADD_GROUP("Capacity", "capacity_");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "capacity_static_shapes", PROPERTY_HINT_RANGE, "0,100000,1,or_greater"), "set_capacity_static_shapes", "get_capacity_static_shapes");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "capacity_dynamic_shapes", PROPERTY_HINT_RANGE, "0,100000,1,or_greater"), "set_capacity_dynamic_shapes", "get_capacity_dynamic_shapes");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "capacity_static_bodies", PROPERTY_HINT_RANGE, "0,100000,1,or_greater"), "set_capacity_static_bodies", "get_capacity_static_bodies");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "capacity_dynamic_bodies", PROPERTY_HINT_RANGE, "0,100000,1,or_greater"), "set_capacity_dynamic_bodies", "get_capacity_dynamic_bodies");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "capacity_contacts", PROPERTY_HINT_RANGE, "0,100000,1,or_greater"), "set_capacity_contacts", "get_capacity_contacts");

	ADD_GROUP("Debug", "debug_");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "debug_draw"), "set_debug_draw", "get_debug_draw");
	// b3World_Draw overlays. debug_draw above is the binding's own collider
	// shells; everything below is drawn by Box3D itself through b3DebugDraw and
	// is independent of it, so contact points can be shown over the sample's
	// real visuals with the shells off.
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "debug_draw_joints"), "set_debug_draw_joints", "get_debug_draw_joints");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "debug_draw_joint_extras"), "set_debug_draw_joint_extras", "get_debug_draw_joint_extras");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "debug_draw_contacts"), "set_debug_draw_contacts", "get_debug_draw_contacts");
	// Which side of the pair the contact anchors are drawn from (upstream
	// drawAnchorA); off means anchor B.
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "debug_draw_anchor_a"), "set_debug_draw_anchor_a", "get_debug_draw_anchor_a");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "debug_draw_contact_normals"), "set_debug_draw_contact_normals", "get_debug_draw_contact_normals");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "debug_draw_contact_forces"), "set_debug_draw_contact_forces", "get_debug_draw_contact_forces");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "debug_draw_contact_features"), "set_debug_draw_contact_features", "get_debug_draw_contact_features");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "debug_draw_graph_colors"), "set_debug_draw_graph_colors", "get_debug_draw_graph_colors");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "debug_draw_islands"), "set_debug_draw_islands", "get_debug_draw_islands");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "debug_draw_mass"), "set_debug_draw_mass", "get_debug_draw_mass");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "debug_draw_sleep"), "set_debug_draw_sleep", "get_debug_draw_sleep");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "debug_draw_body_names"), "set_debug_draw_body_names", "get_debug_draw_body_names");
	// Upstream calls this drawBounds; renamed because it sits beside
	// debug_drawing_bounds, which is a completely different thing (the cull
	// volume). These are the shapes' fattened broad-phase AABBs.
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "debug_draw_shape_bounds"), "set_debug_draw_shape_bounds", "get_debug_draw_shape_bounds");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "debug_force_scale", PROPERTY_HINT_RANGE, "0,10,0.01,or_greater"), "set_debug_force_scale", "get_debug_force_scale");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "debug_joint_scale", PROPERTY_HINT_RANGE, "0,10,0.01,or_greater"), "set_debug_joint_scale", "get_debug_joint_scale");
	// Everything outside this box is culled before Box3D calls back, so a big
	// world can draw overlays for one region only. Upstream's default is
	// +/-100 m.
	ADD_PROPERTY(PropertyInfo(Variant::AABB, "debug_drawing_bounds"), "set_debug_drawing_bounds", "get_debug_drawing_bounds");

	// b3DebugMaterial (types.h:2927-2935), for make_debug_color().
	BIND_ENUM_CONSTANT(DEBUG_MATERIAL_DEFAULT);
	BIND_ENUM_CONSTANT(DEBUG_MATERIAL_MATTE);
	BIND_ENUM_CONSTANT(DEBUG_MATERIAL_SOFT);
	BIND_ENUM_CONSTANT(DEBUG_MATERIAL_DEAD);
	BIND_ENUM_CONSTANT(DEBUG_MATERIAL_GLOSSY);
	BIND_ENUM_CONSTANT(DEBUG_MATERIAL_METALLIC);
}
