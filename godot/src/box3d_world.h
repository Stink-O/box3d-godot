// SPDX-FileCopyrightText: 2026 box3d-godot contributors
// SPDX-License-Identifier: MIT

#pragma once

#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/variant/aabb.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/color.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/vector3i.hpp>

#include <box3d/box3d.h>

#include "box3d_contact_rules.h"
#include "box3d_replay.h"

#include <atomic>
#include <condition_variable>
#include <mutex>
#include <thread>
#include <unordered_map>
#include <vector>

namespace godot {

class Box3DBody;
// A query point cloud plus its origin and radius; defined in box3d_world.cpp,
// where the queries that build it live.
struct Box3DQueryProxy;
class ImmediateMesh;
class Label3D;
class MeshInstance3D;
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
	// Solver tuning, forwarded to b3World_SetContactTuning. Hertz 60 is a
	// DELIBERATE DEVIATION from upstream: b3DefaultWorldDef is 30
	// (src/types.c:20) and the sample app inherits it unmodified
	// (samples/sample.cpp:398-406). This port's samples are tuned against 60;
	// changing it alters every existing scene and is the user's call.
	// Damping matches the core, at 1 length unit per meter (this binding
	// never changes that scale).
	double contact_hertz = 60.0;
	double contact_damping = 10.0;
	// Maximum contact push-out speed, b3World_SetContactTuning's third argument
	// (box3d.h:181). 3 m/s is b3DefaultWorldDef's value (src/types.c:19).
	double contact_speed = 3.0;
	// Speed a collision must reach to produce a contact_hit event, and the speed
	// below which restitution is ignored. Both default to b3DefaultWorldDef's
	// 1 m/s (src/types.c:17-18) so the defaults change nothing.
	double hit_event_threshold = 1.0;
	double restitution_threshold = 1.0;
	// Contact point recycling distance; 0 disables recycling (box3d.h:187-188).
	// The default is B3_CONTACT_RECYCLE_DISTANCE = 10 * B3_LINEAR_SLOP = 0.05 m
	// at this binding's fixed 1 length unit per meter (constants.h:53, :88).
	double contact_recycle_distance = 0.05;
	bool enable_sleep = true;
	bool enable_warm_starting = true;
	// b3WorldDef.capacity (b3Capacity, types.h:120-137): expected counts used to
	// pre-size the world so a scene that grows into them never reallocates
	// mid-step. Read ONLY when the world is created; 0 keeps Box3D's own
	// growth-on-demand (b3DefaultWorldDef leaves the whole struct zeroed,
	// src/types.c:14). Measure with get_max_capacity() once, then author.
	int capacity_static_shapes = 0;
	int capacity_dynamic_shapes = 0;
	int capacity_static_bodies = 0;
	int capacity_dynamic_bodies = 0;
	int capacity_contacts = 0;
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
	PackedFloat32Array debug_buffer[DEBUG_PRIM_MAX]; // reused bulk upload buffers
	// Arbitrary geometry has no primitive to instance, so the five MultiMeshes
	// above cannot draw it: mesh, convex hull and height-field colliders used to
	// get no shell at all, which made them the shapes Debug could not see. Each
	// such shape gets its own MeshInstance3D instead, drawing the collider's OWN
	// geometry as a wireframe read back from Box3D (b3Shape_GetMesh,
	// b3Shape_GetHull, b3Shape_GetHeightField), so what is drawn is what the
	// solver holds and not the node's visual. Keyed by b3StoreShapeId; the
	// surface is rebuilt only when the shape's blob, kind, element count or
	// scale changes, which is what makes a live set_mesh_scale cycle cost one
	// rebuild instead of one per frame.
	enum DebugShellKind {
		SHELL_MESH = 0,
		SHELL_HULL = 1,
		SHELL_HEIGHT_FIELD = 2,
	};
	struct DebugMeshShell {
		MeshInstance3D *mi = nullptr; // owns its ArrayMesh and its material
		const void *data = nullptr; // the blob the surface was built from
		Vector3 scale = Vector3(1, 1, 1);
		int triangle_count = 0; // mesh triangles, hull half-edges, or field cells
		// b3HullData::hash / b3HeightFieldData::hash (types.h:1985, :2295): a
		// content hash of the whole blob. The allocator can hand a replacement
		// hull the address the old one just freed, so the pointer alone is not
		// enough to notice a live b3Shape_SetHull. Zero for meshes, which have
		// no such setter reachable from this binding.
		uint32_t hash = 0;
		int kind = SHELL_MESH;
		bool used = false;
	};
	std::unordered_map<uint64_t, DebugMeshShell> debug_mesh_shells;
	// Line vertices a single mesh shell will draw. A ground mesh is a few
	// thousand triangles; a shell past this is refused rather than turned into
	// a million-vertex line soup nobody can read anyway.
	static const int debug_mesh_shell_triangle_limit = 20000;
	// Upstream debug draw (b3World_Draw + b3DebugDraw, box3d.h:56,
	// types.h:2973-3057). The MultiMesh shells above stay the shape renderer —
	// b3World_Draw only draws shapes through b3CreateDebugShapeCallback, which
	// this binding does not register — so these flags cover exactly the overlays
	// the shells cannot produce: joints, contacts, normals, forces, islands,
	// graph colors, mass, sleep, names and shape bounds. One name per upstream
	// b3DebugDraw field, all default off.
	bool debug_draw_joints = false;
	bool debug_draw_joint_extras = false;
	bool debug_draw_shape_bounds = false; // upstream: drawBounds
	bool debug_draw_mass = false;
	bool debug_draw_sleep = false;
	bool debug_draw_body_names = false;
	bool debug_draw_contacts = false;
	bool debug_draw_anchor_a = false;
	bool debug_draw_graph_colors = false;
	bool debug_draw_contact_features = false;
	bool debug_draw_contact_normals = false;
	bool debug_draw_contact_forces = false;
	bool debug_draw_islands = false;
	double debug_force_scale = 1.0;
	double debug_joint_scale = 1.0;
	// b3DebugDraw.drawingBounds: everything outside is culled before any
	// callback fires. b3DefaultDebugDraw's own default is +/-100 m
	// (src/types.c:144-149), copied here.
	AABB debug_drawing_bounds = AABB(Vector3(-100, -100, -100), Vector3(200, 200, 200));
	MeshInstance3D *debug_overlay_mi = nullptr;
	// Raw, but kept alive by the Ref the MeshInstance3D above holds.
	ImmediateMesh *debug_overlay_mesh = nullptr;
	std::vector<Label3D *> debug_labels; // pooled, grown to debug_label_budget
	static const int debug_label_budget = 512;
	bool debug_last_any_awake = false;
	int debug_last_body_count = -1; // -1 forces a rebuild on the next step
	// Synchronous mode only refreshes the shells after a step actually ran:
	// between ticks the solver data is frozen, so re-reading it every rendered
	// frame (144+ Hz vs 60 Hz physics) was pure waste. Async mode refreshes
	// from apply_step_results and never reads this flag.
	bool debug_step_dirty = true;
	double last_step_delta = 1.0 / 60.0; // for the fast-body debug criterion
	// Wall-clock cost of the last b3World_Step. Godot's TIME_PHYSICS_PROCESS
	// monitor is not usable for this: it reads roughly 2x high under vsync
	// pacing (it reported 20-28 ms on a scene whose steps provably cost 7-12 ms
	// while the loop still held 60 ticks a second). Timed around the call
	// instead. Written by whichever thread ran the step, which is the worker in
	// async mode, so it is atomic.
	std::atomic<int64_t> last_step_usec{ 0 };
	std::vector<Box3DBody *> bodies;
	// Broad-phase traversal counters from the last query (b3TreeStats,
	// types.h:1772-1779). Written by every query method, read by
	// get_last_query_stats().
	b3TreeStats last_query_stats = {};

	// The buffer this world is recording into, or null. Held as a Ref for the
	// whole session so the buffer cannot be freed under a recording world.
	Ref<Box3DRecording> active_recording;

	// P-007: the rule table installed on this world, or null. Reinstalled by
	// ensure_world() so a world that is destroyed and recreated keeps its rules.
	Ref<Box3DContactRules> contact_rules;

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
	// Reads physics/box3d/length_units_per_meter and hands it to
	// b3SetLengthUnitsPerMeter. Runs once per process; see the definition.
	static void apply_length_units_setting();
	// Editor-only: true when any descendant is a Box3DBody. Walks the subtree,
	// so it is only ever called from _get_configuration_warnings().
	static bool has_body_descendant(const Node *p_node);
	void dispatch_contact_events();
	// b3StoreContactId / b3LoadContactId (id.h:154-172), upstream's own packing
	// for a handle that has to leave C++. Used here and nowhere else: every
	// other id in this binding is held as a C++ member and never escapes.
	static Vector3i store_contact_id(b3ContactId p_id);
	static b3ContactId load_contact_id(const Vector3i &p_handle);
	// The Box3DCollisionShape behind a shape id, or null for a body's own
	// shape_type shape. Checks b3Shape_IsValid first: end-touch events may name
	// a shape that was destroyed before the step ended (types.h:1075-1086).
	static Object *shape_node_from(b3ShapeId p_shape);
	// Shared tail of the capsule and convex queries: everything but how the
	// point cloud was built.
	Array run_overlap_proxy(const Box3DQueryProxy &p_shape, uint64_t p_mask, uint64_t p_layer);
	Dictionary run_cast_proxy(const Box3DQueryProxy &p_shape, const Vector3 &p_motion, uint64_t p_mask, uint64_t p_layer);
	void dispatch_sensor_events();
	void dispatch_joint_events();
	void dispatch_body_events();
	// Reads the transforms back out of b3World_GetBodyEvents instead of polling
	// every registered body. See the definition for why the two are equivalent.
	void sync_bodies_from_move_events();
	void update_debug_draw();
	// Draws one mesh collider's own triangles, in the body's frame and the
	// body's state color. No-op for any shape that is not a live mesh.
	void push_mesh_shell(b3ShapeId p_shape, const Transform3D &p_transform, const Color &p_color);
	// Draws one convex hull collider's half-edges, in the body's frame and the
	// body's state color. The hull Box3D hands back already has the node scale
	// and any placement transform baked in (b3CreateTransformedHullShape bakes
	// both at create time, src/shape.c:370-374), so the caller passes the plain
	// body transform. No-op for any shape that is not a live hull.
	void push_hull_shell(b3ShapeId p_shape, const Transform3D &p_transform, const Color &p_color);
	// Draws one height-field collider's cell grid plus each cell's collision
	// diagonal, in the body's frame and the body's state color. Hole cells are
	// skipped. The field ignores node scale entirely (height_field_scale is its
	// own knob) and its corner sits at the body origin growing +X/+Z, which is
	// exactly what the local-space vertices below encode. No-op for any shape
	// that is not a live height field.
	void push_height_field_shell(b3ShapeId p_shape, const Transform3D &p_transform, const Color &p_color);
	// Shared plumbing for the three above: finds or creates this shape's
	// MeshInstance3D (and its unshaded two-sided material) and marks it used.
	DebugMeshShell &acquire_geom_shell(b3ShapeId p_shape);
	// The tail of the three above: state color, world transform, visibility.
	static void finish_geom_shell(DebugMeshShell &p_shell, const Transform3D &p_transform, const Color &p_color);
	// Hides (and forgets) every mesh shell the last refresh did not touch, so a
	// freed body or a shape retyped away from a mesh leaves nothing behind.
	void sweep_mesh_shells();
	// True when at least one b3DebugDraw option above is on, i.e. when
	// b3World_Draw has anything to report. Everything overlay-related is
	// skipped when this is false, so an unused overlay costs one bool test.
	bool debug_overlay_any() const;
	// Runs b3World_Draw and rebuilds the line/label overlay from its callbacks.
	// Main thread, post-join, after a step: b3World_Draw refuses a locked world
	// (src/physics_world.c:1367 -> :102-106).
	void update_debug_overlay();
	// Hides (and clears) the overlay when every option has been switched off.
	void refresh_debug_overlay_visibility();
	void apply_contact_tuning();
	void async_thread_main();
	void launch_async_step(double p_delta);
	// b3World_Step plus the timing that feeds get_step_time_ms().
	void step_world(b3WorldId p_id, double p_delta, int p_substeps);
	void apply_step_results();
	void stop_step_thread();

protected:
	static void _bind_methods();
	void _notification(int p_what);

public:
	// Mirrors b3DebugMaterial (types.h:2927-2935): a shading preset the renderer
	// reads from the high byte of a packed colour. Only meaningful to a renderer
	// that honours it — the overlay here is unshaded lines and masks it off —
	// but it travels with b3SurfaceMaterial::customColor, so a scene can author
	// it for its own materials.
	enum DebugMaterial {
		DEBUG_MATERIAL_DEFAULT,
		DEBUG_MATERIAL_MATTE,
		DEBUG_MATERIAL_SOFT,
		DEBUG_MATERIAL_DEAD,
		DEBUG_MATERIAL_GLOSSY,
		DEBUG_MATERIAL_METALLIC,
	};

	Box3DWorld();
	~Box3DWorld();

	// Editor-only diagnostics: every case here is one where the scene loads and
	// runs but the simulation quietly does nothing a newcomer would expect.
	PackedStringArray _get_configuration_warnings() const override;

	// b3SetLengthUnitsPerMeter / b3GetLengthUnitsPerMeter (constants.h:8-15).
	// The scale is PROCESS-WIDE and upstream requires it to be set once, before
	// any other Box3D call, so it is a project setting rather than a property:
	//
	//     physics/box3d/length_units_per_meter   (float, default 1)
	//
	// applied at class registration. The setter exists for tools and tests that
	// have to do it in code; it refuses once any world exists, because a live
	// world has already baked the old scale into its slop and margins. Returns
	// whether it took effect. Leave the scale at 1 unless the game really uses
	// another unit — every inspector suffix in this binding says metres.
	static double get_length_units_per_meter();
	static bool set_length_units_per_meter(double p_units);

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

	// Milliseconds the last solver step took. Not a property: it is live
	// telemetry, not scene state.
	double get_step_time_ms() const;

	// Per-phase solver timings (b3Profile, milliseconds) and simulation size
	// counters (b3Counters) for the most recent step. Keys are the upstream
	// struct field names verbatim, so the sample app's profiler rows and any
	// port of them index the same names. Like get_step_time_ms these are live
	// telemetry rather than scene state, so they are methods, not properties.
	// Both return an empty Dictionary when the world is dead.
	Dictionary get_profile() const;
	Dictionary get_counters() const;

	// Every remaining b3World_Get*/b3World_Is* reading, asked of Box3D rather
	// than mirrored from the properties above. The properties are the AUTHORED
	// values; this is what the solver actually holds, which is the pair that
	// matters the moment anything else can write to the world. Keys are the
	// upstream getter names minus the b3World_ prefix, matching get_profile()
	// and get_counters(). Empty when the world is dead.
	Dictionary get_live_settings() const;
	// b3World_GetMaxCapacity: the high-water marks this world reached. Feed the
	// numbers back into the capacity_* properties to pre-size a rebuild.
	// Keys are b3Capacity's field names (types.h:120-137).
	Dictionary get_max_capacity() const;
	// Process-wide, not per-world (b3GetWorldCount / b3GetMaxWorldCount,
	// box3d.h:41, :44): how many Box3D worlds exist right now, and the most
	// that have ever existed at once. The second is a HIGH-WATER MARK, not a
	// cap (src/physics_world.c:236, :541-544) — it reads 0 until the first
	// world is created.
	static int get_world_count();
	static int get_max_world_count();
	// Which Box3D this binary wraps, and how it was built (F-014). Both are
	// process-wide, hence static: b3GetVersion (base.h:169) and
	// b3IsDoublePrecision (base.h:172), the pair upstream puts in its window
	// title and its Help > About box (samples/main.cpp:557-560,
	// samples/sample.cpp:1810-1811). The version comes back formatted the way
	// upstream formats it, "major.minor.revision", because the three fields are
	// only ever read together.
	static String get_box3d_version();
	static bool is_double_precision();
	// b3World_DumpMemoryStats (box3d.h:237), the allocator breakdown behind
	// upstream's Sim > Dump Mem Stats (samples/sample.cpp:1623-1626): id pools,
	// island links, world arrays, solver sets, constraint graph, the hull
	// database, the broad phase, the manifold allocators and a total.
	//
	// Upstream writes it a line at a time through b3Log, which has no return
	// value and no context pointer, so this installs a capture handler for the
	// span of the call and hands the lines back joined by newlines — nothing is
	// printed. Empty when the world is dead. NOT thread-safe: b3SetLogFcn is
	// process-global, so two threads dumping at once would interleave.
	String dump_memory_stats() const;

	// Upstream's debug palette (P-044). b3GetGraphColor (types.h:2946) hands
	// back the colour box3d itself paints constraint-graph slot i with, so a
	// script legend for debug_draw_graph_colors matches the overlay instead of
	// guessing. The last index is the overflow colour
	// (B3_OVERFLOW_INDEX == B3_GRAPH_COLOR_COUNT - 1, constants.h:44); an index
	// outside the range is clamped, because b3GetGraphColor asserts on one
	// (src/constraint_graph.c:35) and script must not be able to trip that.
	static int get_graph_color_count();
	static Color get_graph_color(int p_index);
	// b3MakeDebugColor (types.h:2939-2942): pack an RGB colour with a material
	// preset for Box3DCollisionShape's custom_color. The preset rides in the
	// high byte, which the colour converters ignore, so the low 24 bits stay
	// plain RGB and a colour packed with DEBUG_MATERIAL_DEFAULT is unchanged.
	static int64_t make_debug_color(const Color &p_color, DebugMaterial p_material);

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

	// b3DebugDraw options, one per upstream field (types.h:3013-3053). These
	// drive b3World_Draw's overlay; the shape shells stay on debug_draw above.
	void set_debug_draw_joints(bool p_enabled);
	bool get_debug_draw_joints() const;
	void set_debug_draw_joint_extras(bool p_enabled);
	bool get_debug_draw_joint_extras() const;
	void set_debug_draw_shape_bounds(bool p_enabled);
	bool get_debug_draw_shape_bounds() const;
	void set_debug_draw_mass(bool p_enabled);
	bool get_debug_draw_mass() const;
	void set_debug_draw_sleep(bool p_enabled);
	bool get_debug_draw_sleep() const;
	void set_debug_draw_body_names(bool p_enabled);
	bool get_debug_draw_body_names() const;
	void set_debug_draw_contacts(bool p_enabled);
	bool get_debug_draw_contacts() const;
	void set_debug_draw_anchor_a(bool p_enabled);
	bool get_debug_draw_anchor_a() const;
	void set_debug_draw_graph_colors(bool p_enabled);
	bool get_debug_draw_graph_colors() const;
	void set_debug_draw_contact_features(bool p_enabled);
	bool get_debug_draw_contact_features() const;
	void set_debug_draw_contact_normals(bool p_enabled);
	bool get_debug_draw_contact_normals() const;
	void set_debug_draw_contact_forces(bool p_enabled);
	bool get_debug_draw_contact_forces() const;
	void set_debug_draw_islands(bool p_enabled);
	bool get_debug_draw_islands() const;
	void set_debug_force_scale(double p_scale);
	double get_debug_force_scale() const;
	void set_debug_joint_scale(double p_scale);
	double get_debug_joint_scale() const;
	void set_debug_drawing_bounds(const AABB &p_bounds);
	AABB get_debug_drawing_bounds() const;
	void set_contact_hertz(double p_hertz);
	double get_contact_hertz() const;
	void set_contact_damping(double p_damping);
	double get_contact_damping() const;
	void set_enable_sleep(bool p_enabled);
	bool get_enable_sleep() const;
	void set_enable_warm_starting(bool p_enabled);
	bool get_enable_warm_starting() const;
	void set_contact_speed(double p_speed);
	double get_contact_speed() const;
	void set_hit_event_threshold(double p_speed);
	double get_hit_event_threshold() const;
	void set_restitution_threshold(double p_speed);
	double get_restitution_threshold() const;
	void set_contact_recycle_distance(double p_distance);
	double get_contact_recycle_distance() const;
	void set_capacity_static_shapes(int p_count);
	int get_capacity_static_shapes() const;
	void set_capacity_dynamic_shapes(int p_count);
	int get_capacity_dynamic_shapes() const;
	void set_capacity_static_bodies(int p_count);
	int get_capacity_static_bodies() const;
	void set_capacity_dynamic_bodies(int p_count);
	int get_capacity_dynamic_bodies() const;
	void set_capacity_contacts(int p_count);
	int get_capacity_contacts() const;

	// Query filtering is TWO-WAY (src/shape.h:151-155): a shape is reported
	// only if (shape.categoryBits & query.maskBits) and
	// (shape.maskBits & query.categoryBits) are both non-zero. So every query
	// below takes both halves — `collision_mask` is what the query looks for
	// (b3QueryFilter.maskBits) and `collision_layer` is what the query IS
	// (b3QueryFilter.categoryBits), which is how a shape gets to ignore a
	// line-of-sight ray while still stopping a projectile one. Both default to
	// b3DefaultQueryFilter's value, every bit set (types.h:13-14), and both are
	// 64 bits wide like b3Filter, so they reach the categories Box3DBody
	// exposes as collision_layer_high / collision_mask_high.

	// Cast a ray from -> to. Returns a Dictionary:
	//   { hit: bool, position: Vector3, normal: Vector3,
	//     fraction: float, collider: Box3DBody }
	Dictionary raycast(const Vector3 &p_from, const Vector3 &p_to,
			uint64_t p_mask = B3_DEFAULT_MASK_BITS, uint64_t p_layer = B3_DEFAULT_CATEGORY_BITS);

	// Maps a shape to the Box3DBody that owns it (via userData). Public so the
	// query callbacks can use it.
	Box3DBody *body_from_shape(b3ShapeId p_shape);

	// Every hit along the ray, nearest first, one Dictionary each:
	//   { collider, shape, position, normal, fraction, user_material,
	//     triangle_index, child_index }
	// Unlike raycast() this uses the general b3World_CastRay, which does report
	// initial overlap.
	Array raycast_all(const Vector3 &p_from, const Vector3 &p_to,
			uint64_t p_mask = B3_DEFAULT_MASK_BITS, uint64_t p_layer = B3_DEFAULT_CATEGORY_BITS);

	// Queries.
	Array overlap_sphere(const Vector3 &p_center, double p_radius,
			uint64_t p_mask = B3_DEFAULT_MASK_BITS, uint64_t p_layer = B3_DEFAULT_CATEGORY_BITS);
	// Axis-aligned box overlap, exact (the box is cast as an 8-point proxy).
	Array overlap_box(const Vector3 &p_center, const Vector3 &p_size,
			uint64_t p_mask = B3_DEFAULT_MASK_BITS, uint64_t p_layer = B3_DEFAULT_CATEGORY_BITS);
	// Capsule and arbitrary-convex overlaps. A b3ShapeProxy is a point cloud
	// plus a radius (types.h:1370-1384), so a capsule is its two end centers
	// with the radius, and any convex volume is the cloud of its points with
	// radius 0 — no hull has to be built for a query.
	//
	// The capsule is given as its two END CENTERS in world space rather than as
	// a center plus a height, which is what b3Capsule itself is (types.h:1917-
	// 1930) and what lets a query be tilted at all; overlap_sphere / overlap_box
	// take a center because a sphere and an axis-aligned box have nothing else.
	Array overlap_capsule(const Vector3 &p_point_a, const Vector3 &p_point_b, double p_radius,
			uint64_t p_mask = B3_DEFAULT_MASK_BITS, uint64_t p_layer = B3_DEFAULT_CATEGORY_BITS);
	// The convex hull of p_points, in world space. Concave input is queried as
	// its hull. At most B3_MAX_SHAPE_CAST_POINTS (128) points are used
	// (constants.h:115, :127); extra points are dropped with a warning.
	Array overlap_convex(const PackedVector3Array &p_points,
			uint64_t p_mask = B3_DEFAULT_MASK_BITS, uint64_t p_layer = B3_DEFAULT_CATEGORY_BITS);
	// Broad-phase only: returns every body whose fat AABB overlaps p_aabb, so
	// results are conservative (b3World_OverlapAABB says "potentially overlap").
	Array overlap_aabb(const AABB &p_aabb,
			uint64_t p_mask = B3_DEFAULT_MASK_BITS, uint64_t p_layer = B3_DEFAULT_CATEGORY_BITS);
	Dictionary shape_cast_sphere(const Vector3 &p_from, const Vector3 &p_to, double p_radius,
			uint64_t p_mask = B3_DEFAULT_MASK_BITS, uint64_t p_layer = B3_DEFAULT_CATEGORY_BITS);
	Dictionary shape_cast_box(const Vector3 &p_from, const Vector3 &p_to, const Vector3 &p_size,
			uint64_t p_mask = B3_DEFAULT_MASK_BITS, uint64_t p_layer = B3_DEFAULT_CATEGORY_BITS);
	// Sweeps of the two proxies above. The shape is where it starts and
	// p_motion is how far it travels, because a capsule and a point cloud carry
	// their own pose — the from/to pair the sphere and box casts take only
	// works for a shape described by a single center.
	Dictionary shape_cast_capsule(const Vector3 &p_point_a, const Vector3 &p_point_b, double p_radius,
			const Vector3 &p_motion,
			uint64_t p_mask = B3_DEFAULT_MASK_BITS, uint64_t p_layer = B3_DEFAULT_CATEGORY_BITS);
	Dictionary shape_cast_convex(const PackedVector3Array &p_points, const Vector3 &p_motion,
			uint64_t p_mask = B3_DEFAULT_MASK_BITS, uint64_t p_layer = B3_DEFAULT_CATEGORY_BITS);

	// b3TreeStats from the most recent query (types.h:1772-1779): how many
	// broad-phase nodes and leaves it visited. Every b3World_Overlap*/Cast*
	// returns it and b3RayResult carries the same two counters, so this covers
	// all seven world queries. Keys are `node_visits` and `leaf_visits`.
	// It is a cost readout, not scene state: use it to see whether a query is
	// walking the whole tree. Only a query that actually reached Box3D writes
	// it — every one of the seven calls ensure_world() first, so a "dead" world
	// is recreated rather than skipped, but a query that still finds no valid
	// world returns before the call and leaves the previous reading. Nothing
	// else touches it, so it survives until the next query.
	// Zero-initialised, so it reads 0/0 before the first query.
	Dictionary get_last_query_stats() const;

	// --- Recording (P-045) ---------------------------------------------------
	// Record every mutation of this world, and every step, into the given
	// buffer. See box3d_replay.h for what a recording is for and what its
	// embedded state hashes do and do not cover.
	//
	// ASYNC STEP: recording is SAFE while async_step is on, and is neither
	// refused nor disabled. Traced rather than assumed: upstream writes to the
	// recording from exactly two places inside a step, both on the thread that
	// called b3World_Step (the Step op before the world is locked,
	// src/physics_world.c:1034-1038, and the per-step state hash after it is
	// unlocked, :1173-1180), and every other write comes from an API mutator on
	// the calling thread. Nothing records from a solver worker. The buffer also
	// carries its own mutex (src/recording.h:141), held across each whole
	// record (src/recording.c:698-722). So the only race a binding can create
	// is reading the bytes while the step thread is writing them, and that is
	// closed from the other side: Box3DRecording::get_data() and save_to_file()
	// refuse outright while a session is live, because the bytes are not a
	// loadable recording until stop_recording() has written the registry.
	//
	// start_recording() and stop_recording() themselves must be at a step
	// BOUNDARY: both go through b3GetUnlockedWorldFromId, which B3_ASSERTs on a
	// locked world (src/physics_world.c:96-106, :2300-2320). Both join the async
	// step first, so script cannot trip that.
	//
	// Starting a second session on a buffer that already holds one is REFUSED
	// here rather than silently resetting it: upstream's own guard makes a
	// second b3World_StartRecording on an already-recording world a no-op
	// (src/physics_world.c:2305), while starting on a NEW world would reset the
	// buffer and discard the first session (box3d.h:277-278).
	// --- Contact rules (P-007, engineer-K's table) ---------------------------
	// The rule table driving this world's custom filter, pre-solve, friction
	// and restitution callbacks. Setting it installs it; clearing it or
	// replacing it uninstalls the old one first. A world that is destroyed and
	// recreated reinstalls its rules from ensure_world(), which is the whole
	// reason this is a property rather than a bare rules.install(world) call.
	void set_contact_rules(const Ref<Box3DContactRules> &p_rules);
	Ref<Box3DContactRules> get_contact_rules() const;

	bool start_recording(const Ref<Box3DRecording> &p_recording);
	// Ends the session, which is what makes the buffer loadable. Returns false
	// if nothing was recording. Called automatically when the world leaves the
	// tree or is deleted, so a scene that quits mid-recording still leaves a
	// complete buffer.
	bool stop_recording();
	bool is_recording() const;
	// The buffer this world is recording into, or null.
	Ref<Box3DRecording> get_recording() const;

	// --- Contact handles (b3ContactId) ---------------------------------------
	// The contact_began / contact_ended / contact_hit payloads carry a
	// `contact_id`, which is upstream's handle to the contact itself rather than
	// to either shape. It is the only way to follow one contact across steps
	// (types.h:1263-1266): shape ids identify the PAIR, and a pair can lose and
	// remake its contact between steps.
	//
	// The handle is a Vector3i and it is OPAQUE — the components are not
	// coordinates and nothing outside these two methods may read them.
	// b3ContactId is 32 + 16 + 32 bits of payload (id.h:65-71), which does not
	// fit an int; b3StoreContactId packs it into exactly three uint32s
	// (id.h:154-160), so three int32 lanes is the natural carrier. Vector3i is
	// a value type, compares by value and can key a Dictionary, which is what a
	// script tracking contacts over time needs.
	//
	// A handle is transient: Box3D may destroy the contact whenever the world is
	// modified or stepped (types.h:1115-1117). Always ask is_contact_valid()
	// before get_contact_data() — b3Contact_GetData asserts on a stale handle
	// (src/contact.c:62-64 dereferences without checking) rather than returning
	// empty, so the check is not optional. get_contact_data() does it for you.
	//
	// Both are instance methods, not statics, even though b3Contact_IsValid
	// takes no world: they read solver arrays, so they must join an in-flight
	// async step first. Use them on the world that emitted the handle.
	bool is_contact_valid(const Vector3i &p_contact) const;
	// Empty Dictionary when the handle is stale. Otherwise:
	//   contact_id                     the handle back, as given
	//   body_a / body_b                the two Box3DBody nodes
	//   shape_a / shape_b              their Box3DCollisionShape, or null for a
	//                                  body's own shape_type shape
	//   touching                       false when the pair is registered but the
	//                                  manifolds hold no points
	//   normal                         first manifold's unit normal, A towards B
	//   impulse                        summed totalNormalImpulse over all points
	//   manifold_count                 mesh and height-field contacts report more
	//                                  than one manifold
	//   points                         every manifold point, flattened, each:
	//     position (world), separation, impulse, velocity, normal, manifold,
	//     triangle_index, persisted
	Dictionary get_contact_data(const Vector3i &p_contact) const;

	// Live introspection: read from Box3D rather than from the cached property
	// fields. Methods, not properties — these are readings, not scene state.
	int get_awake_body_count() const;
	// World-space bounds of the broad phase (fattened AABBs, so slightly
	// larger than the geometry). Empty when the world is dead.
	AABB get_bounds() const;
	void explode(const Vector3 &p_center, double p_radius, double p_impulse_per_area, double p_falloff = 0.0,
			uint64_t p_mask = B3_DEFAULT_MASK_BITS);
};

} // namespace godot

VARIANT_ENUM_CAST(godot::Box3DWorld::DebugMaterial);
