// SPDX-FileCopyrightText: 2026 box3d-godot contributors
// SPDX-License-Identifier: MIT

#pragma once

#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>

#include <box3d/box3d.h>

#include <atomic>
#include <condition_variable>
#include <mutex>
#include <thread>
#include <vector>

namespace godot {

class Box3DBody;
class MultiMeshInstance3D;

// A Box3DWorld owns a Box3D simulation. Add Box3DBody nodes anywhere beneath it.
// The world drives the simulation every physics frame: it pushes kinematic
// bodies in, steps Box3D, then reads dynamic bodies out.
class Box3DWorld : public Node3D {
	GDCLASS(Box3DWorld, Node3D)

private:
	b3WorldId world_id = b3_nullWorldId;
	Vector3 gravity = Vector3(0, -9.8f, 0);
	int substep_count = 4;
	bool auto_step = true;
	bool continuous_collision = true;
	double max_linear_speed = 0.0; // 0 = keep Box3D's default
	int worker_count = 1; // >1 enables Box3D's internal multithreaded solver
	bool debug_draw = false;
	// Solver tuning, forwarded to b3World_SetContactTuning. Defaults match
	// Box3D's own (b3DefaultWorldDef): 30 Hz, damping ratio 10, at 1 length
	// unit per meter (this binding never changes that scale).
	double contact_hertz = 30.0;
	double contact_damping = 10.0;
	bool enable_sleep = true;
	bool enable_warm_starting = true;
	// Debug draw: solid state-colored collider shells, upstream-sample style.
	// One MultiMesh per primitive keeps huge scenes at a few draw calls.
	enum DebugPrim {
		DEBUG_BOX,
		DEBUG_SPHERE,
		DEBUG_CAPSULE,
		DEBUG_CYLINDER,
		DEBUG_CONE,
		DEBUG_PRIM_MAX,
	};
	MultiMeshInstance3D *debug_mm[DEBUG_PRIM_MAX] = {};
	bool debug_last_any_awake = false;
	int debug_last_body_count = -1; // -1 forces a rebuild on the next step
	double last_step_delta = 1.0 / 60.0; // for the fast-body debug criterion
	std::vector<Box3DBody *> bodies;

	// Asynchronous stepping. When async_step is on, b3World_Step runs on a
	// dedicated thread while the engine renders; results are applied at the
	// start of the NEXT physics frame. If a step overruns a whole physics
	// frame, that tick is skipped (the sim briefly lags real time) instead of
	// stalling rendering. Any API call that touches the Box3D world first
	// calls join_async_step() so scripts never race the solver.
	bool async_step = false;
	std::thread step_thread;
	mutable std::mutex step_mutex;
	mutable std::condition_variable step_cv;
	bool worker_busy = false; // guarded by step_mutex
	bool worker_exit = false; // guarded by step_mutex
	double worker_dt = 1.0 / 60.0; // guarded by step_mutex
	int worker_substeps = 4; // guarded by step_mutex
	mutable std::atomic<bool> step_inflight{ false };
	mutable bool step_pending_apply = false; // main thread only

	void ensure_world();
	void dispatch_contact_events();
	void dispatch_sensor_events();
	void update_debug_draw();
	void apply_contact_tuning();
	void async_thread_main();
	void launch_async_step(double p_delta);
	void apply_step_results();
	void stop_step_thread();

protected:
	static void _bind_methods();
	void _notification(int p_what);

public:
	Box3DWorld();
	~Box3DWorld();

	// Internal: returns a valid world id, creating the world on demand.
	b3WorldId get_world_id();
	bool is_world_alive() const;
	void register_body(Box3DBody *p_body);
	void unregister_body(Box3DBody *p_body);

	// Advance the simulation by delta seconds (called automatically when
	// auto_step is enabled, or manually from script). With async_step enabled
	// this launches the step in the background and returns immediately; if the
	// previous step is still running the call is a no-op (the tick is skipped).
	void step(double p_delta);

	// Blocks until any in-flight async step finishes (no-op otherwise). Every
	// wrapper method that touches the b3 API calls this first; the fast path
	// is a single relaxed atomic load. Results are applied on the next tick.
	void join_async_step() const;

	void set_async_step(bool p_enabled);
	bool get_async_step() const;

	void set_gravity(const Vector3 &p_gravity);
	Vector3 get_gravity() const;
	void set_substep_count(int p_count);
	int get_substep_count() const;
	void set_auto_step(bool p_enabled);
	bool get_auto_step() const;
	void set_continuous_collision(bool p_enabled);
	bool get_continuous_collision() const;
	void set_max_linear_speed(double p_speed);
	double get_max_linear_speed() const;
	void set_worker_count(int p_count);
	int get_worker_count() const;
	void set_debug_draw(bool p_enabled);
	bool get_debug_draw() const;
	void set_contact_hertz(double p_hertz);
	double get_contact_hertz() const;
	void set_contact_damping(double p_damping);
	double get_contact_damping() const;
	void set_enable_sleep(bool p_enabled);
	bool get_enable_sleep() const;
	void set_enable_warm_starting(bool p_enabled);
	bool get_enable_warm_starting() const;

	// Cast a ray from -> to. Returns a Dictionary:
	//   { hit: bool, position: Vector3, normal: Vector3,
	//     fraction: float, collider: Box3DBody }
	Dictionary raycast(const Vector3 &p_from, const Vector3 &p_to, uint32_t p_mask = 0xFFFFFFFFu);

	// Maps a shape to the Box3DBody that owns it (via userData). Public so the
	// query callbacks can use it.
	Box3DBody *body_from_shape(b3ShapeId p_shape);

	// Queries.
	Array overlap_sphere(const Vector3 &p_center, double p_radius, uint32_t p_mask = 0xFFFFFFFFu);
	Dictionary shape_cast_sphere(const Vector3 &p_from, const Vector3 &p_to, double p_radius, uint32_t p_mask = 0xFFFFFFFFu);
	void explode(const Vector3 &p_center, double p_radius, double p_impulse_per_area, double p_falloff = 0.0, uint32_t p_mask = 0xFFFFFFFFu);
};

} // namespace godot
