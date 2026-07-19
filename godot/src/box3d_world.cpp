// SPDX-FileCopyrightText: 2026 box3d-godot contributors
// SPDX-License-Identifier: MIT

#include "box3d_world.h"

#include "box3d_body.h"
#include "box3d_collision_shape.h"
#include "box3d_conversions.h"

#include <godot_cpp/classes/box_mesh.hpp>
#include <godot_cpp/classes/capsule_mesh.hpp>
#include <godot_cpp/classes/cylinder_mesh.hpp>
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/multi_mesh.hpp>
#include <godot_cpp/classes/multi_mesh_instance3d.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/classes/shader.hpp>
#include <godot_cpp/classes/shader_material.hpp>
#include <godot_cpp/classes/sphere_mesh.hpp>
#include <godot_cpp/templates/local_vector.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/math.hpp>

using namespace godot;

Box3DWorld::Box3DWorld() {}

Box3DWorld::~Box3DWorld() {
	stop_step_thread();
	if (b3World_IsValid(world_id)) {
		b3DestroyWorld(world_id);
		world_id = b3_nullWorldId;
	}
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
		b3World_Step(id, (float)dt, substeps);
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
	for (Box3DBody *body : bodies) {
		if (body != nullptr) {
			body->sync_from_physics();
			body->debug_hit_decay();
		}
	}
	dispatch_contact_events();
	dispatch_sensor_events();
	// Async mode refreshes the debug shells here: we are post-join, and apply
	// runs at most once per physics frame so it cannot catch-up-spiral like
	// the old per-tick update in the synchronous path could.
	if (debug_draw) {
		update_debug_draw();
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

void Box3DWorld::ensure_world() {
	if (b3World_IsValid(world_id)) {
		return;
	}
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
	world_id = b3CreateWorld(&def);
	apply_contact_tuning();
	b3World_EnableWarmStarting(world_id, enable_warm_starting);
}

void Box3DWorld::apply_contact_tuning() {
	if (!b3World_IsValid(world_id)) {
		return;
	}
	join_async_step();
	// contactSpeed left at Box3D's own default (3 m/s at this binding's fixed
	// 1-length-unit-per-meter scale); only stiffness/damping are exposed.
	b3World_SetContactTuning(world_id, (float)contact_hertz, (float)contact_damping, 3.0f);
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
	b3World_Step(world_id, (float)p_delta, substep_count);
	// Read simulated (dynamic) transforms back out to the nodes.
	for (Box3DBody *body : bodies) {
		if (body != nullptr) {
			body->sync_from_physics();
			body->debug_hit_decay();
		}
	}
	dispatch_contact_events();
	dispatch_sensor_events();
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

void Box3DWorld::dispatch_contact_events() {
	if (!b3World_IsValid(world_id)) {
		return;
	}
	b3ContactEvents events = b3World_GetContactEvents(world_id);
	for (int i = 0; i < events.beginCount; ++i) {
		Box3DBody *a = body_from_shape(events.beginEvents[i].shapeIdA);
		Box3DBody *b = body_from_shape(events.beginEvents[i].shapeIdB);
		if (a != nullptr && b != nullptr) {
			a->emit_contact_begin(b);
			b->emit_contact_begin(a);
		}
	}
	for (int i = 0; i < events.endCount; ++i) {
		Box3DBody *a = body_from_shape(events.endEvents[i].shapeIdA);
		Box3DBody *b = body_from_shape(events.endEvents[i].shapeIdB);
		if (a != nullptr && b != nullptr) {
			a->emit_contact_end(b);
			b->emit_contact_end(a);
		}
	}
	// Hit events stand in for upstream's internal TOI flag (lime flash).
	// Upstream sets it during the continuous-collision sweep, i.e. only for
	// bodies moving over half their min extent per step, and CCD only sweeps
	// against static geometry (bullets also sweep dynamic bodies). Mirror
	// both conditions using the hit event's approach speed.
	float dt = (float)last_step_delta;
	for (int i = 0; i < events.hitCount; ++i) {
		const b3ContactHitEvent &hit = events.hitEvents[i];
		Box3DBody *a = body_from_shape(hit.shapeIdA);
		Box3DBody *b = body_from_shape(hit.shapeIdB);
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

void Box3DWorld::_notification(int p_what) {
	switch (p_what) {
		case NOTIFICATION_ENTER_TREE: {
			if (!Engine::get_singleton()->is_editor_hint()) {
				ensure_world();
				set_physics_process(true);
				set_process(true);
			}
		} break;
		case NOTIFICATION_PROCESS: {
			// Synchronous mode refreshes the debug shells once per frame here,
			// never per tick — updating inside step() made every catch-up tick
			// pay the full rebuild, which spiraled heavy scenes to a
			// standstill. Async mode updates from apply_step_results instead:
			// a step is in flight during most process callbacks, and joining
			// here would stall the rendering async exists to protect.
			if (debug_draw && !async_step && !Engine::get_singleton()->is_editor_hint()) {
				update_debug_draw();
			}
		} break;
		case NOTIFICATION_EXIT_TREE: {
			stop_step_thread();
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
	// Takes effect when the world is (re)created; set it before the sim starts.
}

int Box3DWorld::get_worker_count() const {
	return worker_count;
}

void Box3DWorld::set_async_step(bool p_enabled) {
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
}

bool Box3DWorld::get_async_step() const {
	return async_step;
}

Dictionary Box3DWorld::raycast(const Vector3 &p_from, const Vector3 &p_to, uint32_t p_mask) {
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
	b3RayResult r = b3World_CastRayClosest(world_id, origin, translation, filter);

	if (B3_IS_NON_NULL(r.shapeId)) {
		result["hit"] = true;
		result["position"] = to_gd_pos(r.point);
		result["normal"] = to_gd(r.normal);
		result["fraction"] = r.fraction;
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

} // namespace

Array Box3DWorld::overlap_sphere(const Vector3 &p_center, double p_radius, uint32_t p_mask) {
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
	OverlapContext ctx;
	ctx.world = this;
	b3World_OverlapShape(world_id, to_b3_pos(p_center), &proxy, filter, overlap_result_cb, &ctx);
	for (Box3DBody *body : ctx.bodies) {
		result.push_back(body);
	}
	return result;
}

Dictionary Box3DWorld::shape_cast_sphere(const Vector3 &p_from, const Vector3 &p_to, double p_radius, uint32_t p_mask) {
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
	CastContext ctx;
	ctx.world = this;
	b3World_CastShape(world_id, to_b3_pos(p_from), &proxy, translation, filter, cast_result_cb, &ctx);
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

void Box3DWorld::explode(const Vector3 &p_center, double p_radius, double p_impulse_per_area, double p_falloff, uint32_t p_mask) {
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
	def.maskBits = p_mask;
	b3World_Explode(world_id, &def);
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
			mi->set_multimesh(mm);
			mi->set_material_override(mat);
			mi->set_visible(debug_draw);
			add_child(mi);
			debug_mm[p] = mi;
		}
	}

	// While every body sleeps nothing moves or changes color, so skip the
	// instance rewrite entirely. The first quiet frame still rebuilds, which
	// is what paints the pile in its sleeping colors.
	bool any_awake = false;
	int body_count = 0;
	for (Box3DBody *body : bodies) {
		if (body != nullptr && body->is_body_valid()) {
			++body_count;
			if (!any_awake && body->is_awake_now()) {
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

	LocalVector<Transform3D> xforms[DEBUG_PRIM_MAX];
	LocalVector<Color> colors[DEBUG_PRIM_MAX];
	auto push_shell = [&](int prim, Transform3D xf, Vector3 scale, const Color &col) {
		scale *= INFLATE;
		// Right-multiply the basis by diag(scale): component-scale each row.
		xf.basis[0] = xf.basis[0] * scale;
		xf.basis[1] = xf.basis[1] * scale;
		xf.basis[2] = xf.basis[2] * scale;
		xforms[prim].push_back(xf);
		colors[prim].push_back(col);
	};

	for (Box3DBody *body : bodies) {
		if (body == nullptr || !body->is_body_valid() || !body->get_debug_visualize()) {
			continue;
		}
		// State colors: upstream box3d's exact palette and priority order
		// (physics_world.c). Red bad body, slate disabled, wheat sensor, lime
		// recent impact (hit event, standing in for the internal TOI flag),
		// turquoise awake bullet, yellow speed-capped, orange fast (moves
		// over half its min extent per step, the CCD criterion), dark gray
		// static, steel blues kinematic, tan awake / light slate asleep.
		bool awake = body->is_awake_now();
		bool dynamic = body->get_body_type() == Box3DBody::DYNAMIC;
		float lin_speed = 0.0f;
		float motion_speed = 0.0f; // upstream: |v| + |w| * maxExtent (farthest point)
		if (dynamic && awake) {
			lin_speed = (float)body->get_linear_velocity().length();
			motion_speed = lin_speed + (float)body->get_angular_velocity().length() * body->debug_max_extent();
		}
		Color col;
		if (dynamic && body->get_mass() == 0.0) {
			col = Color::hex(0xFF0000FF); // red: bad body
		} else if (!body->is_enabled_now()) {
			col = Color::hex(0x708090FF); // slate gray: disabled
		} else if (body->get_is_sensor()) {
			col = Color::hex(0xF5DEB3FF); // wheat: sensor
		} else if (body->debug_hit_active()) {
			col = Color::hex(0x00FF00FF); // lime: recent impact
		} else if (body->get_continuous() && dynamic && awake) {
			col = Color::hex(0x40E0D0FF); // turquoise: awake bullet
		} else if (max_linear_speed > 0.0 && lin_speed >= (float)max_linear_speed * 0.99f) {
			col = Color::hex(0xFFFF00FF); // yellow: speed capped
		} else if (dynamic && continuous_collision && motion_speed * (float)last_step_delta > 0.5f * body->debug_min_extent()) {
			col = Color::hex(0xFFA500FF); // orange: fast (CCD territory)
		} else if (body->get_body_type() == Box3DBody::STATIC) {
			col = Color::hex(0xA9A9A9FF); // dark gray: static
		} else if (body->get_body_type() == Box3DBody::KINEMATIC) {
			col = awake ? Color::hex(0x4682B4FF) : Color::hex(0xB0C4DEFF); // steel blues
		} else {
			col = awake ? Color::hex(0xD2B48CFF) : Color::hex(0x778899FF); // tan / light slate
		}
		// Compound bodies: shell each Box3DCollisionShape child. The physics
		// ignores the body's own shape_type when child shapes exist, so drawing
		// it would show a collider that isn't there.
		bool has_child_shapes = false;
		for (int i = 0; i < body->get_child_count(); ++i) {
			Box3DCollisionShape *cs = Object::cast_to<Box3DCollisionShape>(body->get_child(i));
			if (cs == nullptr) {
				continue;
			}
			has_child_shapes = true;
			Transform3D cxf = cs->get_global_transform();
			float cr2 = (float)cs->get_capsule_radius();
			switch (cs->get_shape_type()) {
				case Box3DCollisionShape::SPHERE: {
					float r = (float)cs->get_sphere_radius();
					push_shell(DEBUG_SPHERE, cxf, Vector3(2 * r, 2 * r, 2 * r), col);
				} break;
				case Box3DCollisionShape::CAPSULE:
					push_shell(DEBUG_CAPSULE, cxf, Vector3(2 * cr2, (float)cs->get_capsule_height() * 0.5f, 2 * cr2), col);
					break;
				case Box3DCollisionShape::BOX:
				default:
					push_shell(DEBUG_BOX, cxf, cs->get_box_size(), col);
					break;
			}
		}
		if (has_child_shapes) {
			continue;
		}
		// From the solver, not the node: renderer-managed bodies (with
		// sync_node_transform off) keep a stale node pose.
		b3WorldTransform bxf = b3Body_GetTransform(body->get_body_id());
		Transform3D xf(Basis(to_gd(bxf.q)), to_gd_pos(bxf.p));
		float cr = (float)body->get_capsule_radius();
		float ch = (float)body->get_capsule_height();
		switch (body->get_shape_type()) {
			case Box3DBody::SPHERE: {
				float r = (float)body->get_sphere_radius();
				push_shell(DEBUG_SPHERE, xf, Vector3(2 * r, 2 * r, 2 * r), col);
			} break;
			case Box3DBody::CAPSULE:
				push_shell(DEBUG_CAPSULE, xf, Vector3(2 * cr, ch * 0.5f, 2 * cr), col);
				break;
			case Box3DBody::CYLINDER:
				push_shell(DEBUG_CYLINDER, xf, Vector3(2 * cr, ch, 2 * cr), col);
				break;
			case Box3DBody::CONE:
				push_shell(DEBUG_CONE, xf, Vector3(2 * cr, ch, 2 * cr), col);
				break;
			case Box3DBody::BOX:
				push_shell(DEBUG_BOX, xf, body->get_box_size(), col);
				break;
			default:
				break; // Hull / mesh colliders are not shelled
		}
	}

	for (int p = 0; p < DEBUG_PRIM_MAX; ++p) {
		Ref<MultiMesh> mm = debug_mm[p]->get_multimesh();
		int n = (int)xforms[p].size();
		if (mm->get_instance_count() < n) {
			mm->set_instance_count(n);
		}
		mm->set_visible_instance_count(n);
		// One bulk buffer upload instead of two RenderingServer calls per
		// instance — per-instance writes cost ~160 ms/frame at 16k bodies.
		int alloc = mm->get_instance_count();
		if (alloc == 0) {
			continue; // no shells of this primitive; 0-size uploads error out
		}
		PackedFloat32Array &buf = debug_buffer[p];
		buf.resize((int64_t)alloc * 16);
		float *w = buf.ptrw();
		for (int i = 0; i < n; ++i) {
			const Transform3D &xf = xforms[p][i];
			const Color &col = colors[p][i];
			float *inst = w + (int64_t)i * 16;
			inst[0] = (float)xf.basis.rows[0][0];
			inst[1] = (float)xf.basis.rows[0][1];
			inst[2] = (float)xf.basis.rows[0][2];
			inst[3] = (float)xf.origin.x;
			inst[4] = (float)xf.basis.rows[1][0];
			inst[5] = (float)xf.basis.rows[1][1];
			inst[6] = (float)xf.basis.rows[1][2];
			inst[7] = (float)xf.origin.y;
			inst[8] = (float)xf.basis.rows[2][0];
			inst[9] = (float)xf.basis.rows[2][1];
			inst[10] = (float)xf.basis.rows[2][2];
			inst[11] = (float)xf.origin.z;
			inst[12] = col.r;
			inst[13] = col.g;
			inst[14] = col.b;
			inst[15] = col.a;
		}
		if (alloc > n) {
			memset(w + (int64_t)n * 16, 0, ((int64_t)alloc - n) * 16 * sizeof(float));
		}
		RenderingServer::get_singleton()->multimesh_set_buffer(mm->get_rid(), buf);
	}
}

void Box3DWorld::set_debug_draw(bool p_enabled) {
	debug_draw = p_enabled;
	debug_last_body_count = -1; // force a rebuild on the next step
	for (int p = 0; p < DEBUG_PRIM_MAX; ++p) {
		if (debug_mm[p] != nullptr) {
			debug_mm[p]->set_visible(p_enabled);
		}
	}
}

bool Box3DWorld::get_debug_draw() const {
	return debug_draw;
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

void Box3DWorld::_bind_methods() {
	ClassDB::bind_method(D_METHOD("step", "delta"), &Box3DWorld::step);
	ClassDB::bind_method(D_METHOD("raycast", "from", "to", "collision_mask"), &Box3DWorld::raycast, DEFVAL(0xFFFFFFFF));
	ClassDB::bind_method(D_METHOD("overlap_sphere", "center", "radius", "collision_mask"), &Box3DWorld::overlap_sphere, DEFVAL(0xFFFFFFFF));
	ClassDB::bind_method(D_METHOD("shape_cast_sphere", "from", "to", "radius", "collision_mask"), &Box3DWorld::shape_cast_sphere, DEFVAL(0xFFFFFFFF));
	ClassDB::bind_method(D_METHOD("explode", "center", "radius", "impulse_per_area", "falloff", "collision_mask"), &Box3DWorld::explode, DEFVAL(0.0), DEFVAL(0xFFFFFFFF));

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
	ClassDB::bind_method(D_METHOD("set_async_step", "enabled"), &Box3DWorld::set_async_step);
	ClassDB::bind_method(D_METHOD("get_async_step"), &Box3DWorld::get_async_step);
	ClassDB::bind_method(D_METHOD("get_worker_count"), &Box3DWorld::get_worker_count);
	ClassDB::bind_method(D_METHOD("set_debug_draw", "enabled"), &Box3DWorld::set_debug_draw);
	ClassDB::bind_method(D_METHOD("get_debug_draw"), &Box3DWorld::get_debug_draw);
	ClassDB::bind_method(D_METHOD("set_contact_hertz", "hertz"), &Box3DWorld::set_contact_hertz);
	ClassDB::bind_method(D_METHOD("get_contact_hertz"), &Box3DWorld::get_contact_hertz);
	ClassDB::bind_method(D_METHOD("set_contact_damping", "damping"), &Box3DWorld::set_contact_damping);
	ClassDB::bind_method(D_METHOD("get_contact_damping"), &Box3DWorld::get_contact_damping);
	ClassDB::bind_method(D_METHOD("set_enable_sleep", "enabled"), &Box3DWorld::set_enable_sleep);
	ClassDB::bind_method(D_METHOD("get_enable_sleep"), &Box3DWorld::get_enable_sleep);
	ClassDB::bind_method(D_METHOD("set_enable_warm_starting", "enabled"), &Box3DWorld::set_enable_warm_starting);
	ClassDB::bind_method(D_METHOD("get_enable_warm_starting"), &Box3DWorld::get_enable_warm_starting);

	ADD_PROPERTY(PropertyInfo(Variant::VECTOR3, "gravity"), "set_gravity", "get_gravity");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "substep_count", PROPERTY_HINT_RANGE, "1,16,1"), "set_substep_count", "get_substep_count");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "auto_step"), "set_auto_step", "get_auto_step");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "continuous_collision"), "set_continuous_collision", "get_continuous_collision");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "max_linear_speed", PROPERTY_HINT_RANGE, "0,1000,0.1,or_greater"), "set_max_linear_speed", "get_max_linear_speed");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "worker_count", PROPERTY_HINT_RANGE, "1,16,1"), "set_worker_count", "get_worker_count");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "async_step"), "set_async_step", "get_async_step");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "debug_draw"), "set_debug_draw", "get_debug_draw");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "contact_hertz", PROPERTY_HINT_RANGE, "0,120,0.1,or_greater"), "set_contact_hertz", "get_contact_hertz");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "contact_damping", PROPERTY_HINT_RANGE, "0,20,0.01,or_greater"), "set_contact_damping", "get_contact_damping");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "enable_sleep"), "set_enable_sleep", "get_enable_sleep");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "enable_warm_starting"), "set_enable_warm_starting", "get_enable_warm_starting");
}
