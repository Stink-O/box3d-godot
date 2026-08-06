// SPDX-FileCopyrightText: 2026 box3d-godot contributors
// SPDX-License-Identifier: MIT
//
// P-007: Box3D's four solver callbacks, reached WITHOUT a script callback.
//
// Upstream lets an application override four decisions the solver makes about a
// contact pair (box3d.h:159-163, :224-228):
//
//   bool  b3CustomFilterFcn ( b3ShapeId a, b3ShapeId b, void* context );
//   bool  b3PreSolveFcn     ( b3ShapeId a, b3ShapeId b, b3Pos point, b3Vec3 n, void* context );
//   float b3FrictionCallback   ( float fA, uint64_t materialA, float fB, uint64_t materialB );
//   float b3RestitutionCallback( float rA, uint64_t materialA, float rB, uint64_t materialB );
//
// ALL FOUR RUN ON SOLVER WORKER THREADS. Upstream says so in as many words —
// "this function must be thread-safe" and "do not attempt to modify the world
// inside this callback" for the first two (types.h:63-71, :78-86), "should not
// attempt to modify Box3D state or user application state" for the mixing pair
// (types.h:50-60) — and `worker_count == 1` is NOT a sufficient gate here,
// because with Box3DWorld.async_step on, even the inline task runs on the
// binding's step thread rather than the main thread. A GDScript Callable is
// therefore unsafe in every configuration, which is why this item was parked
// twice before this design.
//
// So script does not get a callback. Script AUTHORS DATA — a Box3DContactRules
// resource of rules keyed on pairs of b3SurfaceMaterial::userMaterialId — and
// C++ evaluates that data inside the callbacks. The hot path allocates nothing,
// takes no lock, calls nothing in the engine and touches no Godot object: it is
// one acquire load of an immutable snapshot pointer, two Box3D shape reads and a
// binary search over a flat array.
//
// The key is userMaterialId because it is the ONLY thing the mixing callbacks
// receive (they get no shape and no context at all), and because the filter and
// pre-solve callbacks can read it back off a shape with b3Shape_GetSurfaceMaterial
// (a pure array read, src/shape.c:19-25, :1102-1107). One key space serves all
// four callbacks.
//
// See "Threading and memory ordering" on Box3DContactRules below for why the
// snapshot swap is safe, and box3d_contact_rules.cpp for the per-callback
// upstream contracts (which flag enables what, and what the no-rule answer has
// to be to keep the solver bit-identical).

#pragma once

#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <box3d/box3d.h>

#include <atomic>
#include <cstdint>
#include <vector>

namespace godot {

class Box3DWorld;

// One rule, for one unordered pair of user material ids. Plain old data: this is
// what a worker thread reads, so it holds no pointers, no Godot types and
// nothing that needs a destructor.
struct Box3DContactRule {
	// Canonical order, material_a <= material_b, so a pair has exactly one entry
	// however it was authored.
	uint64_t material_a = 0;
	uint64_t material_b = 0;
	// Which of the four rule kinds this entry carries (Box3DContactRules::Kind).
	uint32_t kinds = 0;
	float friction = 0.0f;
	float restitution = 0.0f;
	// One-way (pre-solve) rule: a contact survives only when the normal pointing
	// from one_way_from's material towards the other lies within acos(cos_limit)
	// of axis. Axis is world space and unit length; see set_one_way_rule().
	float axis_x = 0.0f;
	float axis_y = 1.0f;
	float axis_z = 0.0f;
	float cos_limit = 0.0f;
	// The material the axis points AWAY from, i.e. the `a` of set_one_way_rule.
	// The canonical ordering above loses which side was authored first; this
	// keeps it, and it is the only asymmetric rule kind.
	uint64_t one_way_from = 0;
};

// An immutable compiled rule table. Built on the main thread, published with one
// atomic release store, and from then on read-only for as long as any solver
// thread can see it. Never mutated after publication.
struct Box3DRuleSnapshot {
	// Sorted by (material_a, material_b) so a lookup is a branch-predictable
	// binary search with no allocation. Rule counts are tiny in practice, but
	// sorted-and-flat costs nothing to keep and never degrades.
	std::vector<Box3DContactRule> entries;
	// The union of every entry's `kinds`. Lets each callback answer "no rule of
	// my kind exists anywhere" with a single test, before it touches a shape.
	uint32_t kinds = 0;

	// The entry for this material pair, or null. Order-insensitive.
	const Box3DContactRule *find(uint64_t p_a, uint64_t p_b) const;
};

// Data-driven overrides for Box3D's four solver callbacks. Author rules from
// script (or a .tres), install the resource on a Box3DWorld, and the rules are
// evaluated inside the solver with no script involvement:
//
//   var rules := Box3DContactRules.new()
//   rules.set_collision_rule(MAT_GHOST, MAT_WALL, false)   # never collide
//   rules.set_friction_rule(MAT_ICE, MAT_CRATE, 0.0)       # slides forever
//   rules.set_one_way_rule(MAT_PLATFORM, MAT_PLAYER, Vector3.UP, 90.0)
//   rules.install(world)
//
// Two rule kinds need a per-shape opt-in, because upstream gates them per shape
// and only calls the world callback when at least one shape of the pair asks
// for it: collision rules need b3ShapeDef.enableCustomFiltering (types.h:485-486,
// checked at src/broad_phase.c:284, src/solver.c:401, src/sensor.c:135), and
// one-way rules need b3ShapeDef.enablePreSolveEvents (types.h:505-507, checked
// at src/contact.c:325). Friction and restitution rules need no flag: upstream
// runs the mixing callbacks for EVERY contact (src/contact.c:646-649).
//
// Threading and memory ordering
// -----------------------------
// `published` is the only thing a worker thread ever reads through, and it is
// read with std::memory_order_acquire. Every store to it is a release store made
// on the main thread, so a worker that sees the new pointer necessarily sees the
// fully built entries behind it — the release/acquire pair is what orders the
// construction of the snapshot before its publication.
//
// A retired snapshot is deleted immediately after the swap, and that is safe for
// a reason stronger than the atomic: publish() first calls join_async_step() on
// every world this resource is installed on, so no b3World_Step is in flight on
// any of them, so no callback can be running. Steps are only ever launched from
// the main thread (synchronously, or by handing work to the world's own step
// thread), and publish() runs on the main thread, so no step can start under it
// either. There is therefore no window in which a worker holds the old pointer,
// and no reclamation scheme (hazard pointers, RCU, refcounts) is needed.
//
// Nothing in the hot path takes a lock, allocates, calls into the engine, or
// dereferences a Godot object other than this resource itself — whose lifetime
// covers every installation, because the destructor uninstalls from every world
// it is still attached to.
class Box3DContactRules : public Resource {
	GDCLASS(Box3DContactRules, Resource)

public:
	// Bits in Box3DContactRule::kinds.
	enum Kind {
		// The pair never collides. Absence of the bit means "collide", so a table
		// with no collision rules answers every pair the way upstream would.
		KIND_NO_COLLIDE = 1 << 0,
		KIND_FRICTION = 1 << 1,
		KIND_RESTITUTION = 1 << 2,
		KIND_ONE_WAY = 1 << 3,
	};

	// How many DISTINCT rule resources can carry friction/restitution rules at
	// the same time. See the mixing bank in the .cpp: b3FrictionCallback and
	// b3RestitutionCallback take no context object at all ("This intentionally
	// provides no context objects because this is called from a worker thread",
	// types.h:50-52), so the only way to tell one table from another inside them
	// is to hand each table its own function. Eight is far past any real scene;
	// a ninth table logs an error and keeps upstream's default mixing rather
	// than silently answering with another table's rules.
	enum { MAX_MIXING_TABLES = 8 };

	Box3DContactRules();
	~Box3DContactRules();

	// --- authoring (main thread) ---------------------------------------------
	// Every setter republishes the table, which joins any in-flight async step
	// first, so authoring rules mid-frame is safe. Rules are authored between
	// steps and are immutable for the duration of a step, which is what keeps
	// the simulation deterministic.

	// collide = false makes the pair never collide. Needs enableCustomFiltering
	// on at least one shape of the pair. NOTE this also hides the pair from
	// SENSOR overlaps: upstream consults the same callback there
	// (src/sensor.c:135-145).
	void set_collision_rule(int64_t p_material_a, int64_t p_material_b, bool p_collide);
	bool get_collision_rule(int64_t p_material_a, int64_t p_material_b) const;

	// Replaces upstream's sqrtf(frictionA * frictionB) for this pair
	// (src/physics_world.c:154-158). Clamped at 0: a mesh contact asserts the
	// mixed value is finite and non-negative (src/mesh_contact.c:1152-1153).
	void set_friction_rule(int64_t p_material_a, int64_t p_material_b, double p_friction);
	void clear_friction_rule(int64_t p_material_a, int64_t p_material_b);

	// Replaces upstream's max(restitutionA, restitutionB) for this pair
	// (src/physics_world.c:160-164). Clamped at 0, same assert.
	void set_restitution_rule(int64_t p_material_a, int64_t p_material_b, double p_restitution);
	void clear_restitution_rule(int64_t p_material_a, int64_t p_material_b);

	// The one-way platform, with no script in the loop. A contact between the
	// two materials survives only while the contact normal pointing FROM
	// p_material_a TOWARDS p_material_b lies within p_max_angle_degrees of
	// p_axis; otherwise the contact is dropped for that step.
	//
	// For a platform you can jump up through and then land on, make the platform
	// material a, the passenger material b, p_axis Vector3.UP and the angle 90:
	// a passenger resting on top produces a normal pointing up out of the
	// platform (kept), a passenger rising from below produces one pointing down
	// (dropped). Needs enablePreSolveEvents on at least one shape of the pair.
	//
	// The axis is WORLD space and is not re-based on either body's transform:
	// reading a body pose from a worker thread is exactly what this design
	// exists to avoid. A rotating one-way platform is out of scope.
	//
	// p_max_angle_degrees is clamped to [0, 180]; 180 makes the rule a no-op.
	// a == b is refused: with one material on both sides there is no way to tell
	// which way round the normal was authored.
	void set_one_way_rule(int64_t p_material_a, int64_t p_material_b, const Vector3 &p_axis,
			double p_max_angle_degrees = 90.0);
	void clear_one_way_rule(int64_t p_material_a, int64_t p_material_b);

	// Drops every rule for one pair, or all of them.
	void clear_rule(int64_t p_material_a, int64_t p_material_b);
	void clear_rules();

	int get_rule_count() const;
	// The rules for one pair, or {} when the pair has none. Keys: material_a,
	// material_b, collide, friction, restitution, one_way_axis,
	// one_way_max_angle, one_way_from. The mixing keys are absent unless
	// authored, so `has("friction")` is how you tell "0 friction" from "no rule".
	Dictionary get_rule(int64_t p_material_a, int64_t p_material_b) const;

	// Every rule, one Dictionary each, in canonical pair order. This is also the
	// serialised form of the resource (the `rules` property), so a .tres round
	// trips through it.
	Array get_rules() const;
	void set_rules(const Array &p_rules);

	// --- installation ---------------------------------------------------------
	// Registers this table's four callbacks on p_world's Box3D world and keeps
	// them in sync. Idempotent. The world must be alive (install() creates it if
	// it is not, exactly as any other world API call does).
	//
	// A world that is destroyed and recreated (leaving and re-entering the tree)
	// loses its callbacks, so re-install after that — or use the Box3DWorld
	// property, which does it for you.
	void install(Box3DWorld *p_world);
	// Restores upstream's defaults on p_world: no filter, no pre-solve, and the
	// stock mixing functions (upstream resets to those when handed NULL,
	// src/physics_world.c:2257, :2268).
	void uninstall(Box3DWorld *p_world);
	bool is_installed(Box3DWorld *p_world) const;

	// Which mixing-bank slot this table holds, or -1 when it holds none. A table
	// with no friction and no restitution rules never claims one. Diagnostic:
	// nothing needs it to use the feature.
	int get_mixing_slot() const;

	// --- solver-side entry points (not for script) ----------------------------
	// The static functions Box3D itself calls. Public so the callbacks can be
	// registered from one place; never call them yourself.
	static bool solver_custom_filter(b3ShapeId p_shape_a, b3ShapeId p_shape_b, void *p_context);
	static bool solver_pre_solve(b3ShapeId p_shape_a, b3ShapeId p_shape_b, b3Pos p_point, b3Vec3 p_normal,
			void *p_context);

protected:
	static void _bind_methods();

private:
	// Authored rules, main thread only. Unsorted; publish() sorts a copy.
	std::vector<Box3DContactRule> authored;
	// What the callbacks read. See "Threading and memory ordering" above.
	std::atomic<const Box3DRuleSnapshot *> published{ nullptr };
	// The same pointer, owned. Only the main thread touches this.
	const Box3DRuleSnapshot *owned = nullptr;
	// Slot in the mixing bank, or -1. Claimed on the first publish that has a
	// mixing rule and an installation, released when the last world detaches.
	int mixing_slot = -1;
	// Instance ids (not pointers) of the Box3DWorlds this table is installed on,
	// so a world freed behind our back resolves to null instead of dangling.
	std::vector<uint64_t> attached;

	// Finds or creates the authored entry for a pair, canonicalising the order.
	Box3DContactRule *find_authored(uint64_t p_a, uint64_t p_b);
	const Box3DContactRule *find_authored(uint64_t p_a, uint64_t p_b) const;
	Box3DContactRule &edit_authored(uint64_t p_a, uint64_t p_b);
	// Drops an entry that no longer carries any rule.
	void prune(uint64_t p_a, uint64_t p_b);
	// Compiles `authored` into a fresh snapshot and swaps it in. Joins every
	// attached world first; deletes the retired snapshot.
	void publish();
	// Installs (or clears) this table's mixing functions on one world.
	void apply_mixing(b3WorldId p_world_id, bool p_enable);
	// Claims / releases a bank slot. Main thread only.
	void claim_mixing_slot();
	void release_mixing_slot();
	// Live Box3DWorlds from `attached`, dropping ids that no longer resolve.
	std::vector<Box3DWorld *> live_worlds();
};

} // namespace godot

VARIANT_ENUM_CAST(godot::Box3DContactRules::Kind);
