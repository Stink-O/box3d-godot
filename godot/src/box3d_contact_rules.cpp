// SPDX-FileCopyrightText: 2026 box3d-godot contributors
// SPDX-License-Identifier: MIT

#include "box3d_contact_rules.h"

#include "box3d_world.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/error_macros.hpp>
#include <godot_cpp/core/math.hpp>
#include <godot_cpp/core/memory.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <cmath>

using namespace godot;

// ---------------------------------------------------------------------------
// The mixing bank
// ---------------------------------------------------------------------------
// b3FrictionCallback and b3RestitutionCallback take NO context object, on
// purpose: "This intentionally provides no context objects because this is
// called from a worker thread" (types.h:50-52, :56-58). A callback therefore
// cannot ask which world (or which table) invoked it. The way out is to hand
// each table its own pair of functions: a fixed bank of slots, each slot a file
// scope atomic snapshot pointer, each function a template instantiation that
// knows its slot at compile time. b3World_SetFrictionCallback is per world
// (src/physics_world.c:2254), so world A can hold slot 0's function while world
// B holds slot 1's, and the rules follow the resource rather than the process.
//
// A slot is only claimed by a table that actually has a mixing rule, so the
// common case (filter and pre-solve rules only, or no rules at all) consumes
// none, and the world keeps upstream's own default functions.
static std::atomic<const Box3DRuleSnapshot *> g_mix_snapshot[Box3DContactRules::MAX_MIXING_TABLES];
// Slot ownership. Main thread only: worlds and resources are created there.
static Box3DContactRules *g_mix_owner[Box3DContactRules::MAX_MIXING_TABLES] = {};

// Upstream's defaults, reproduced EXACTLY (src/physics_world.c:154-164, with
// b3MaxFloat from math_functions.h). A table with no rule for a pair must not
// approximate the default, it must BE the default, or installing an empty table
// would move the simulation.
static inline float default_friction(float p_a, float p_b) {
	return sqrtf(p_a * p_b);
}

static inline float default_restitution(float p_a, float p_b) {
	return p_a > p_b ? p_a : p_b;
}

// The hot path shared by both mixing functions. One acquire load, one binary
// search, no allocation, no lock, no engine call.
static inline float mix_friction(int p_slot, float p_fa, uint64_t p_ma, float p_fb, uint64_t p_mb) {
	const Box3DRuleSnapshot *snap = g_mix_snapshot[p_slot].load(std::memory_order_acquire);
	if (snap != nullptr && (snap->kinds & Box3DContactRules::KIND_FRICTION) != 0) {
		const Box3DContactRule *rule = snap->find(p_ma, p_mb);
		if (rule != nullptr && (rule->kinds & Box3DContactRules::KIND_FRICTION) != 0) {
			return rule->friction;
		}
	}
	return default_friction(p_fa, p_fb);
}

static inline float mix_restitution(int p_slot, float p_ra, uint64_t p_ma, float p_rb, uint64_t p_mb) {
	const Box3DRuleSnapshot *snap = g_mix_snapshot[p_slot].load(std::memory_order_acquire);
	if (snap != nullptr && (snap->kinds & Box3DContactRules::KIND_RESTITUTION) != 0) {
		const Box3DContactRule *rule = snap->find(p_ma, p_mb);
		if (rule != nullptr && (rule->kinds & Box3DContactRules::KIND_RESTITUTION) != 0) {
			return rule->restitution;
		}
	}
	return default_restitution(p_ra, p_rb);
}

template <int Slot>
static float slot_friction(float p_fa, uint64_t p_ma, float p_fb, uint64_t p_mb) {
	return mix_friction(Slot, p_fa, p_ma, p_fb, p_mb);
}

template <int Slot>
static float slot_restitution(float p_ra, uint64_t p_ma, float p_rb, uint64_t p_mb) {
	return mix_restitution(Slot, p_ra, p_ma, p_rb, p_mb);
}

static b3FrictionCallback *const g_friction_fn[Box3DContactRules::MAX_MIXING_TABLES] = {
	slot_friction<0>, slot_friction<1>, slot_friction<2>, slot_friction<3>,
	slot_friction<4>, slot_friction<5>, slot_friction<6>, slot_friction<7>
};

static b3RestitutionCallback *const g_restitution_fn[Box3DContactRules::MAX_MIXING_TABLES] = {
	slot_restitution<0>, slot_restitution<1>, slot_restitution<2>, slot_restitution<3>,
	slot_restitution<4>, slot_restitution<5>, slot_restitution<6>, slot_restitution<7>
};

// ---------------------------------------------------------------------------
// Snapshot lookup
// ---------------------------------------------------------------------------

const Box3DContactRule *Box3DRuleSnapshot::find(uint64_t p_a, uint64_t p_b) const {
	uint64_t lo = p_a <= p_b ? p_a : p_b;
	uint64_t hi = p_a <= p_b ? p_b : p_a;
	size_t first = 0;
	size_t last = entries.size();
	while (first < last) {
		size_t mid = first + (last - first) / 2;
		const Box3DContactRule &e = entries[mid];
		if (e.material_a < lo || (e.material_a == lo && e.material_b < hi)) {
			first = mid + 1;
		} else if (e.material_a == lo && e.material_b == hi) {
			return &entries[mid];
		} else {
			last = mid;
		}
	}
	return nullptr;
}

// ---------------------------------------------------------------------------
// The two callbacks that DO get a context
// ---------------------------------------------------------------------------
// b3CustomFilterFcn and b3PreSolveFcn both carry a void* (box3d.h:159-163), so
// these two are per world with the rule table itself as the context. Both are
// only ever called for a pair where at least one shape opted in, so an installed
// table with no rules of that kind costs one predictable branch.
//
// b3Shape_GetSurfaceMaterial is a pure read of the world's shape array
// (src/shape.c:1102-1107 -> :19-25): no allocation, no lock, and nothing can
// resize that array mid-step because shape creation and destruction require an
// unlocked world. It is the safe way to get a userMaterialId from a b3ShapeId on
// a worker thread. For a mesh or height field shape it reports material [0];
// per-triangle materials are not visible here, which is a limit of the callback,
// not of this table.

bool Box3DContactRules::solver_custom_filter(b3ShapeId p_shape_a, b3ShapeId p_shape_b, void *p_context) {
	const Box3DContactRules *self = static_cast<const Box3DContactRules *>(p_context);
	const Box3DRuleSnapshot *snap = self->published.load(std::memory_order_acquire);
	if (snap == nullptr || (snap->kinds & KIND_NO_COLLIDE) == 0) {
		return true; // upstream's answer when no callback is registered
	}
	uint64_t ma = b3Shape_GetSurfaceMaterial(p_shape_a).userMaterialId;
	uint64_t mb = b3Shape_GetSurfaceMaterial(p_shape_b).userMaterialId;
	const Box3DContactRule *rule = snap->find(ma, mb);
	return rule == nullptr || (rule->kinds & KIND_NO_COLLIDE) == 0;
}

bool Box3DContactRules::solver_pre_solve(b3ShapeId p_shape_a, b3ShapeId p_shape_b, b3Pos p_point, b3Vec3 p_normal,
		void *p_context) {
	(void)p_point;
	const Box3DContactRules *self = static_cast<const Box3DContactRules *>(p_context);
	const Box3DRuleSnapshot *snap = self->published.load(std::memory_order_acquire);
	if (snap == nullptr || (snap->kinds & KIND_ONE_WAY) == 0) {
		return true; // keep the contact, which is what no callback would do
	}
	uint64_t ma = b3Shape_GetSurfaceMaterial(p_shape_a).userMaterialId;
	uint64_t mb = b3Shape_GetSurfaceMaterial(p_shape_b).userMaterialId;
	const Box3DContactRule *rule = snap->find(ma, mb);
	if (rule == nullptr || (rule->kinds & KIND_ONE_WAY) == 0) {
		return true;
	}
	// The manifold normal points from shape A to shape B (types.h:2627), and the
	// rule's axis was authored pointing away from one_way_from. Flip when this
	// contact happens to name the materials the other way round.
	float sign = (ma == rule->one_way_from) ? 1.0f : -1.0f;
	float dot = sign * (p_normal.x * rule->axis_x + p_normal.y * rule->axis_y + p_normal.z * rule->axis_z);
	return dot >= rule->cos_limit;
}

// ---------------------------------------------------------------------------
// Authoring
// ---------------------------------------------------------------------------

Box3DContactRules::Box3DContactRules() {
}

Box3DContactRules::~Box3DContactRules() {
	// Every world still holding these callbacks would be left with a context
	// pointing at freed memory, so detach before dying.
	std::vector<Box3DWorld *> worlds = live_worlds();
	for (size_t i = 0; i < worlds.size(); ++i) {
		uninstall(worlds[i]);
	}
	attached.clear();
	release_mixing_slot();
	// memdelete, NOT delete: the snapshot came from memnew, which allocates
	// through Godot's allocator with its own size prefix. Freeing it with the
	// C++ operator hands the payload pointer straight to free() and corrupts the
	// heap (`free(): invalid size`, seen as a crash in a selftest that merely let
	// the resource go out of scope).
	if (owned != nullptr) {
		memdelete(const_cast<Box3DRuleSnapshot *>(owned));
	}
	owned = nullptr;
	published.store(nullptr, std::memory_order_release);
}

Box3DContactRule *Box3DContactRules::find_authored(uint64_t p_a, uint64_t p_b) {
	uint64_t lo = p_a <= p_b ? p_a : p_b;
	uint64_t hi = p_a <= p_b ? p_b : p_a;
	for (size_t i = 0; i < authored.size(); ++i) {
		if (authored[i].material_a == lo && authored[i].material_b == hi) {
			return &authored[i];
		}
	}
	return nullptr;
}

const Box3DContactRule *Box3DContactRules::find_authored(uint64_t p_a, uint64_t p_b) const {
	return const_cast<Box3DContactRules *>(this)->find_authored(p_a, p_b);
}

Box3DContactRule &Box3DContactRules::edit_authored(uint64_t p_a, uint64_t p_b) {
	Box3DContactRule *found = find_authored(p_a, p_b);
	if (found != nullptr) {
		return *found;
	}
	Box3DContactRule rule;
	rule.material_a = p_a <= p_b ? p_a : p_b;
	rule.material_b = p_a <= p_b ? p_b : p_a;
	authored.push_back(rule);
	return authored.back();
}

void Box3DContactRules::prune(uint64_t p_a, uint64_t p_b) {
	uint64_t lo = p_a <= p_b ? p_a : p_b;
	uint64_t hi = p_a <= p_b ? p_b : p_a;
	for (size_t i = 0; i < authored.size(); ++i) {
		if (authored[i].material_a == lo && authored[i].material_b == hi) {
			if (authored[i].kinds == 0) {
				authored.erase(authored.begin() + (long)i);
			}
			return;
		}
	}
}

void Box3DContactRules::set_collision_rule(int64_t p_material_a, int64_t p_material_b, bool p_collide) {
	uint64_t a = (uint64_t)p_material_a;
	uint64_t b = (uint64_t)p_material_b;
	Box3DContactRule &rule = edit_authored(a, b);
	if (p_collide) {
		rule.kinds &= ~(uint32_t)KIND_NO_COLLIDE;
	} else {
		rule.kinds |= (uint32_t)KIND_NO_COLLIDE;
	}
	prune(a, b);
	publish();
}

bool Box3DContactRules::get_collision_rule(int64_t p_material_a, int64_t p_material_b) const {
	const Box3DContactRule *rule = find_authored((uint64_t)p_material_a, (uint64_t)p_material_b);
	return rule == nullptr || (rule->kinds & (uint32_t)KIND_NO_COLLIDE) == 0;
}

void Box3DContactRules::set_friction_rule(int64_t p_material_a, int64_t p_material_b, double p_friction) {
	if (!std::isfinite(p_friction)) {
		ERR_PRINT("Box3DContactRules: friction must be a finite number.");
		return;
	}
	uint64_t a = (uint64_t)p_material_a;
	uint64_t b = (uint64_t)p_material_b;
	Box3DContactRule &rule = edit_authored(a, b);
	// Upstream asserts the mixed value is finite and >= 0 (src/mesh_contact.c:1152-1153).
	rule.friction = (float)MAX(0.0, p_friction);
	rule.kinds |= (uint32_t)KIND_FRICTION;
	publish();
}

void Box3DContactRules::clear_friction_rule(int64_t p_material_a, int64_t p_material_b) {
	uint64_t a = (uint64_t)p_material_a;
	uint64_t b = (uint64_t)p_material_b;
	Box3DContactRule *rule = find_authored(a, b);
	if (rule == nullptr) {
		return;
	}
	rule->kinds &= ~(uint32_t)KIND_FRICTION;
	prune(a, b);
	publish();
}

void Box3DContactRules::set_restitution_rule(int64_t p_material_a, int64_t p_material_b, double p_restitution) {
	if (!std::isfinite(p_restitution)) {
		ERR_PRINT("Box3DContactRules: restitution must be a finite number.");
		return;
	}
	uint64_t a = (uint64_t)p_material_a;
	uint64_t b = (uint64_t)p_material_b;
	Box3DContactRule &rule = edit_authored(a, b);
	rule.restitution = (float)MAX(0.0, p_restitution);
	rule.kinds |= (uint32_t)KIND_RESTITUTION;
	publish();
}

void Box3DContactRules::clear_restitution_rule(int64_t p_material_a, int64_t p_material_b) {
	uint64_t a = (uint64_t)p_material_a;
	uint64_t b = (uint64_t)p_material_b;
	Box3DContactRule *rule = find_authored(a, b);
	if (rule == nullptr) {
		return;
	}
	rule->kinds &= ~(uint32_t)KIND_RESTITUTION;
	prune(a, b);
	publish();
}

void Box3DContactRules::set_one_way_rule(int64_t p_material_a, int64_t p_material_b, const Vector3 &p_axis,
		double p_max_angle_degrees) {
	if (p_material_a == p_material_b) {
		ERR_PRINT("Box3DContactRules: a one-way rule needs two different materials — with one material on "
				  "both sides there is no way to tell which way round the axis points.");
		return;
	}
	Vector3 axis = p_axis;
	if (!axis.is_finite() || axis.length_squared() <= 0.0) {
		ERR_PRINT("Box3DContactRules: the one-way axis must be a finite, non-zero vector.");
		return;
	}
	axis = axis.normalized();
	double angle = CLAMP(p_max_angle_degrees, 0.0, 180.0);
	uint64_t a = (uint64_t)p_material_a;
	uint64_t b = (uint64_t)p_material_b;
	Box3DContactRule &rule = edit_authored(a, b);
	rule.axis_x = (float)axis.x;
	rule.axis_y = (float)axis.y;
	rule.axis_z = (float)axis.z;
	rule.cos_limit = (float)Math::cos(Math::deg_to_rad(angle));
	rule.one_way_from = a;
	rule.kinds |= (uint32_t)KIND_ONE_WAY;
	publish();
}

void Box3DContactRules::clear_one_way_rule(int64_t p_material_a, int64_t p_material_b) {
	uint64_t a = (uint64_t)p_material_a;
	uint64_t b = (uint64_t)p_material_b;
	Box3DContactRule *rule = find_authored(a, b);
	if (rule == nullptr) {
		return;
	}
	rule->kinds &= ~(uint32_t)KIND_ONE_WAY;
	prune(a, b);
	publish();
}

void Box3DContactRules::clear_rule(int64_t p_material_a, int64_t p_material_b) {
	uint64_t a = (uint64_t)p_material_a;
	uint64_t b = (uint64_t)p_material_b;
	Box3DContactRule *rule = find_authored(a, b);
	if (rule == nullptr) {
		return;
	}
	rule->kinds = 0;
	prune(a, b);
	publish();
}

void Box3DContactRules::clear_rules() {
	authored.clear();
	publish();
}

int Box3DContactRules::get_rule_count() const {
	return (int)authored.size();
}

static Dictionary rule_to_dict(const Box3DContactRule &p_rule) {
	Dictionary d;
	d["material_a"] = (int64_t)p_rule.material_a;
	d["material_b"] = (int64_t)p_rule.material_b;
	d["collide"] = (p_rule.kinds & (uint32_t)Box3DContactRules::KIND_NO_COLLIDE) == 0;
	if ((p_rule.kinds & (uint32_t)Box3DContactRules::KIND_FRICTION) != 0) {
		d["friction"] = (double)p_rule.friction;
	}
	if ((p_rule.kinds & (uint32_t)Box3DContactRules::KIND_RESTITUTION) != 0) {
		d["restitution"] = (double)p_rule.restitution;
	}
	if ((p_rule.kinds & (uint32_t)Box3DContactRules::KIND_ONE_WAY) != 0) {
		d["one_way_axis"] = Vector3(p_rule.axis_x, p_rule.axis_y, p_rule.axis_z);
		d["one_way_max_angle"] = Math::rad_to_deg(Math::acos((double)CLAMP(p_rule.cos_limit, -1.0f, 1.0f)));
		d["one_way_from"] = (int64_t)p_rule.one_way_from;
	}
	return d;
}

Dictionary Box3DContactRules::get_rule(int64_t p_material_a, int64_t p_material_b) const {
	const Box3DContactRule *rule = find_authored((uint64_t)p_material_a, (uint64_t)p_material_b);
	if (rule == nullptr) {
		return Dictionary();
	}
	return rule_to_dict(*rule);
}

Array Box3DContactRules::get_rules() const {
	Array out;
	for (size_t i = 0; i < authored.size(); ++i) {
		out.push_back(rule_to_dict(authored[i]));
	}
	return out;
}

void Box3DContactRules::set_rules(const Array &p_rules) {
	authored.clear();
	for (int i = 0; i < p_rules.size(); ++i) {
		Dictionary d = p_rules[i];
		int64_t a = (int64_t)d.get("material_a", (int64_t)0);
		int64_t b = (int64_t)d.get("material_b", (int64_t)0);
		uint64_t ua = (uint64_t)a;
		uint64_t ub = (uint64_t)b;
		Box3DContactRule &rule = edit_authored(ua, ub);
		if (!(bool)d.get("collide", true)) {
			rule.kinds |= (uint32_t)KIND_NO_COLLIDE;
		}
		if (d.has("friction")) {
			rule.friction = (float)MAX(0.0, (double)d["friction"]);
			rule.kinds |= (uint32_t)KIND_FRICTION;
		}
		if (d.has("restitution")) {
			rule.restitution = (float)MAX(0.0, (double)d["restitution"]);
			rule.kinds |= (uint32_t)KIND_RESTITUTION;
		}
		if (d.has("one_way_axis") && a != b) {
			Vector3 axis = d["one_way_axis"];
			if (axis.is_finite() && axis.length_squared() > 0.0) {
				axis = axis.normalized();
				rule.axis_x = (float)axis.x;
				rule.axis_y = (float)axis.y;
				rule.axis_z = (float)axis.z;
				double angle = CLAMP((double)d.get("one_way_max_angle", 90.0), 0.0, 180.0);
				rule.cos_limit = (float)Math::cos(Math::deg_to_rad(angle));
				rule.one_way_from = (uint64_t)(int64_t)d.get("one_way_from", a);
				rule.kinds |= (uint32_t)KIND_ONE_WAY;
			}
		}
		prune(ua, ub);
	}
	publish();
}

// ---------------------------------------------------------------------------
// Publication
// ---------------------------------------------------------------------------

void Box3DContactRules::publish() {
	// Joining every attached world is what makes the retire below safe: after
	// this loop no b3World_Step is in flight anywhere this table is installed,
	// so no callback can be holding the old snapshot, and no step can start
	// because starting one is also a main thread act.
	std::vector<Box3DWorld *> worlds = live_worlds();
	for (size_t i = 0; i < worlds.size(); ++i) {
		worlds[i]->join_async_step();
	}

	Box3DRuleSnapshot *snap = memnew(Box3DRuleSnapshot);
	snap->entries.reserve(authored.size());
	for (size_t i = 0; i < authored.size(); ++i) {
		if (authored[i].kinds == 0) {
			continue;
		}
		snap->entries.push_back(authored[i]);
		snap->kinds |= authored[i].kinds;
	}
	std::sort(snap->entries.begin(), snap->entries.end(),
			[](const Box3DContactRule &l, const Box3DContactRule &r) {
				return l.material_a != r.material_a ? l.material_a < r.material_a : l.material_b < r.material_b;
			});

	const Box3DRuleSnapshot *retired = owned;
	owned = snap;
	// Release: a worker that acquires this pointer sees every entry behind it.
	published.store(snap, std::memory_order_release);
	if (mixing_slot >= 0) {
		g_mix_snapshot[mixing_slot].store(snap, std::memory_order_release);
	}
	if (retired != nullptr) {
		memdelete(const_cast<Box3DRuleSnapshot *>(retired));
	}

	// A table that has just gained (or lost) its first mixing rule has to gain
	// (or free) a bank slot, and the worlds it is installed on have to be told.
	bool wants_mixing = (snap->kinds & ((uint32_t)KIND_FRICTION | (uint32_t)KIND_RESTITUTION)) != 0;
	if (wants_mixing && mixing_slot < 0 && !worlds.empty()) {
		claim_mixing_slot();
		if (mixing_slot >= 0) {
			g_mix_snapshot[mixing_slot].store(snap, std::memory_order_release);
			for (size_t i = 0; i < worlds.size(); ++i) {
				apply_mixing(worlds[i]->get_world_id(), true);
			}
		}
	} else if (!wants_mixing && mixing_slot >= 0) {
		for (size_t i = 0; i < worlds.size(); ++i) {
			apply_mixing(worlds[i]->get_world_id(), false);
		}
		release_mixing_slot();
	}
}

void Box3DContactRules::claim_mixing_slot() {
	if (mixing_slot >= 0) {
		return;
	}
	for (int i = 0; i < MAX_MIXING_TABLES; ++i) {
		if (g_mix_owner[i] == nullptr) {
			g_mix_owner[i] = this;
			mixing_slot = i;
			return;
		}
	}
	ERR_PRINT("Box3DContactRules: no free mixing slot (MAX_MIXING_TABLES tables already carry friction or "
			  "restitution rules). This table keeps Box3D's default mixing; free another table to get one.");
}

void Box3DContactRules::release_mixing_slot() {
	if (mixing_slot < 0) {
		return;
	}
	g_mix_snapshot[mixing_slot].store(nullptr, std::memory_order_release);
	g_mix_owner[mixing_slot] = nullptr;
	mixing_slot = -1;
}

// ---------------------------------------------------------------------------
// Installation
// ---------------------------------------------------------------------------

std::vector<Box3DWorld *> Box3DContactRules::live_worlds() {
	std::vector<Box3DWorld *> out;
	for (size_t i = 0; i < attached.size();) {
		Object *obj = UtilityFunctions::instance_from_id((int64_t)attached[i]);
		Box3DWorld *world = Object::cast_to<Box3DWorld>(obj);
		if (world == nullptr) {
			// The world was freed without detaching; its callbacks died with it.
			attached.erase(attached.begin() + (long)i);
			continue;
		}
		out.push_back(world);
		++i;
	}
	return out;
}

void Box3DContactRules::apply_mixing(b3WorldId p_world_id, bool p_enable) {
	// NULL restores upstream's own default functions (src/physics_world.c:2257, :2268).
	if (p_enable && mixing_slot >= 0) {
		b3World_SetFrictionCallback(p_world_id, g_friction_fn[mixing_slot]);
		b3World_SetRestitutionCallback(p_world_id, g_restitution_fn[mixing_slot]);
	} else {
		b3World_SetFrictionCallback(p_world_id, nullptr);
		b3World_SetRestitutionCallback(p_world_id, nullptr);
	}
}

void Box3DContactRules::install(Box3DWorld *p_world) {
	ERR_FAIL_NULL(p_world);
	uint64_t id = p_world->get_instance_id();
	live_worlds(); // drops any dead ids first
	if (std::find(attached.begin(), attached.end(), id) == attached.end()) {
		attached.push_back(id);
	}
	// get_world_id() creates the world if it does not exist yet and joins any
	// in-flight async step; the four setters below take the UNLOCKED world and
	// silently do nothing on a locked one (src/physics_world.c:3299, :3310).
	b3WorldId world_id = p_world->get_world_id();

	// The filter and pre-solve callbacks are installed unconditionally, even
	// with no rules of their kind. They cost nothing until a shape opts in
	// (upstream only calls them for a pair where one shape set
	// enableCustomFiltering / enablePreSolveEvents), and installing pre-solve
	// closes an upstream hazard: src/solver.c:445-451 calls world->preSolveFcn
	// with NO null check when a fast body's shape has pre-solve events enabled,
	// so a scene that enables the flag with no callback registered would
	// dereference null during CCD.
	b3World_SetCustomFilterCallback(world_id, &Box3DContactRules::solver_custom_filter, this);
	b3World_SetPreSolveCallback(world_id, &Box3DContactRules::solver_pre_solve, this);

	const Box3DRuleSnapshot *snap = owned;
	bool wants_mixing = snap != nullptr &&
			(snap->kinds & ((uint32_t)KIND_FRICTION | (uint32_t)KIND_RESTITUTION)) != 0;
	if (wants_mixing) {
		claim_mixing_slot();
		if (mixing_slot >= 0) {
			g_mix_snapshot[mixing_slot].store(snap, std::memory_order_release);
		}
	}
	apply_mixing(world_id, wants_mixing);
	if (snap == nullptr) {
		publish(); // first install with nothing authored yet: give the callbacks a table
	}
}

void Box3DContactRules::uninstall(Box3DWorld *p_world) {
	ERR_FAIL_NULL(p_world);
	uint64_t id = p_world->get_instance_id();
	std::vector<uint64_t>::iterator it = std::find(attached.begin(), attached.end(), id);
	if (it != attached.end()) {
		attached.erase(it);
	}
	if (p_world->is_world_alive()) {
		b3WorldId world_id = p_world->get_world_id();
		b3World_SetCustomFilterCallback(world_id, nullptr, nullptr);
		b3World_SetPreSolveCallback(world_id, nullptr, nullptr);
		apply_mixing(world_id, false);
	}
	if (attached.empty()) {
		release_mixing_slot();
	}
}

bool Box3DContactRules::is_installed(Box3DWorld *p_world) const {
	if (p_world == nullptr) {
		return false;
	}
	uint64_t id = p_world->get_instance_id();
	return std::find(attached.begin(), attached.end(), id) != attached.end();
}

int Box3DContactRules::get_mixing_slot() const {
	return mixing_slot;
}

void Box3DContactRules::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_collision_rule", "material_a", "material_b", "collide"),
			&Box3DContactRules::set_collision_rule);
	ClassDB::bind_method(D_METHOD("get_collision_rule", "material_a", "material_b"),
			&Box3DContactRules::get_collision_rule);
	ClassDB::bind_method(D_METHOD("set_friction_rule", "material_a", "material_b", "friction"),
			&Box3DContactRules::set_friction_rule);
	ClassDB::bind_method(D_METHOD("clear_friction_rule", "material_a", "material_b"),
			&Box3DContactRules::clear_friction_rule);
	ClassDB::bind_method(D_METHOD("set_restitution_rule", "material_a", "material_b", "restitution"),
			&Box3DContactRules::set_restitution_rule);
	ClassDB::bind_method(D_METHOD("clear_restitution_rule", "material_a", "material_b"),
			&Box3DContactRules::clear_restitution_rule);
	ClassDB::bind_method(D_METHOD("set_one_way_rule", "material_a", "material_b", "axis", "max_angle_degrees"),
			&Box3DContactRules::set_one_way_rule, DEFVAL(90.0));
	ClassDB::bind_method(D_METHOD("clear_one_way_rule", "material_a", "material_b"),
			&Box3DContactRules::clear_one_way_rule);
	ClassDB::bind_method(D_METHOD("clear_rule", "material_a", "material_b"), &Box3DContactRules::clear_rule);
	ClassDB::bind_method(D_METHOD("clear_rules"), &Box3DContactRules::clear_rules);
	ClassDB::bind_method(D_METHOD("get_rule_count"), &Box3DContactRules::get_rule_count);
	ClassDB::bind_method(D_METHOD("get_rule", "material_a", "material_b"), &Box3DContactRules::get_rule);
	ClassDB::bind_method(D_METHOD("get_rules"), &Box3DContactRules::get_rules);
	ClassDB::bind_method(D_METHOD("set_rules", "rules"), &Box3DContactRules::set_rules);
	ClassDB::bind_method(D_METHOD("install", "world"), &Box3DContactRules::install);
	ClassDB::bind_method(D_METHOD("uninstall", "world"), &Box3DContactRules::uninstall);
	ClassDB::bind_method(D_METHOD("is_installed", "world"), &Box3DContactRules::is_installed);
	ClassDB::bind_method(D_METHOD("get_mixing_slot"), &Box3DContactRules::get_mixing_slot);

	// The serialised form: a .tres keeps its rules through this one property.
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "rules", PROPERTY_HINT_NONE, "",
						  PROPERTY_USAGE_DEFAULT | PROPERTY_USAGE_ALWAYS_DUPLICATE),
			"set_rules", "get_rules");

	BIND_ENUM_CONSTANT(KIND_NO_COLLIDE);
	BIND_ENUM_CONSTANT(KIND_FRICTION);
	BIND_ENUM_CONSTANT(KIND_RESTITUTION);
	BIND_ENUM_CONSTANT(KIND_ONE_WAY);
	BIND_CONSTANT(MAX_MIXING_TABLES);
}
