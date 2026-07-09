// SPDX-FileCopyrightText: 2026 box3d-godot contributors
// SPDX-License-Identifier: MIT

#include "box3d_world.h"

#include "box3d_body.h"
#include "box3d_collision_shape.h"
#include "box3d_conversions.h"

#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/immediate_mesh.hpp>
#include <godot_cpp/classes/mesh_instance3d.hpp>
#include <godot_cpp/classes/standard_material3d.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/math.hpp>

using namespace godot;

Box3DWorld::Box3DWorld() {}

Box3DWorld::~Box3DWorld() {
	if (b3World_IsValid(world_id)) {
		b3DestroyWorld(world_id);
		world_id = b3_nullWorldId;
	}
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
	// contactSpeed left at Box3D's own default (3 m/s at this binding's fixed
	// 1-length-unit-per-meter scale); only stiffness/damping are exposed.
	b3World_SetContactTuning(world_id, (float)contact_hertz, (float)contact_damping, 3.0f);
}

b3WorldId Box3DWorld::get_world_id() {
	ensure_world();
	return world_id;
}

bool Box3DWorld::is_world_alive() const {
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
	// Push user-driven (kinematic) transforms into the solver.
	for (Box3DBody *body : bodies) {
		if (body != nullptr) {
			body->sync_to_physics(p_delta);
		}
	}
	b3World_Step(world_id, (float)p_delta, substep_count);
	// Read simulated (dynamic) transforms back out to the nodes.
	for (Box3DBody *body : bodies) {
		if (body != nullptr) {
			body->sync_from_physics();
		}
	}
	dispatch_contact_events();
	dispatch_sensor_events();
	if (debug_draw) {
		update_debug_draw();
	}
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
			}
		} break;
		case NOTIFICATION_EXIT_TREE: {
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
		b3World_EnableContinuous(world_id, p_enabled);
	}
}

bool Box3DWorld::get_continuous_collision() const {
	return continuous_collision;
}

void Box3DWorld::set_max_linear_speed(double p_speed) {
	max_linear_speed = p_speed;
	if (b3World_IsValid(world_id) && p_speed > 0.0) {
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

Dictionary Box3DWorld::raycast(const Vector3 &p_from, const Vector3 &p_to, uint32_t p_mask) {
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

// --- Debug draw ---

namespace {

struct DrawBuffer {
	PackedVector3Array verts;
	PackedColorArray colors;
	void add_line(const Vector3 &a, const Vector3 &b, const Color &c) {
		verts.push_back(a);
		colors.push_back(c);
		verts.push_back(b);
		colors.push_back(c);
	}
};

void add_circle(DrawBuffer *buf, const Vector3 &center, const Vector3 &u, const Vector3 &v, float radius, const Color &color) {
	const int SEG = 16;
	Vector3 prev = center + u * radius;
	for (int i = 1; i <= SEG; ++i) {
		float a = (float)i / SEG * 6.2831853f;
		Vector3 cur = center + (u * (real_t)Math::cos(a) + v * (real_t)Math::sin(a)) * radius;
		buf->add_line(prev, cur, color);
		prev = cur;
	}
}

void draw_ball(DrawBuffer *buf, const Vector3 &c, float r, const Color &color) {
	add_circle(buf, c, Vector3(1, 0, 0), Vector3(0, 1, 0), r, color);
	add_circle(buf, c, Vector3(0, 1, 0), Vector3(0, 0, 1), r, color);
	add_circle(buf, c, Vector3(1, 0, 0), Vector3(0, 0, 1), r, color);
}

void add_box_corners(DrawBuffer *buf, const Vector3 c[8], const Color &col) {
	static const int edges[12][2] = { { 0, 1 }, { 1, 2 }, { 2, 3 }, { 3, 0 }, { 4, 5 }, { 5, 6 }, { 6, 7 }, { 7, 4 }, { 0, 4 }, { 1, 5 }, { 2, 6 }, { 3, 7 } };
	for (int i = 0; i < 12; ++i) {
		buf->add_line(c[edges[i][0]], c[edges[i][1]], col);
	}
}

void draw_box(DrawBuffer &buf, const Transform3D &xf, const Vector3 &half, const Color &col) {
	const Basis &b = xf.basis;
	const Vector3 &o = xf.origin;
	Vector3 c[8] = {
		o + b.xform(Vector3(-half.x, -half.y, -half.z)), o + b.xform(Vector3(half.x, -half.y, -half.z)),
		o + b.xform(Vector3(half.x, -half.y, half.z)), o + b.xform(Vector3(-half.x, -half.y, half.z)),
		o + b.xform(Vector3(-half.x, half.y, -half.z)), o + b.xform(Vector3(half.x, half.y, -half.z)),
		o + b.xform(Vector3(half.x, half.y, half.z)), o + b.xform(Vector3(-half.x, half.y, half.z))
	};
	add_box_corners(&buf, c, col);
}

// Draws two rings joined by struts along the local Y axis (used for capsule /
// cylinder). For a capsule the rings sit at the hemisphere centers and get end
// caps; for a cylinder they sit at the flat ends.
void draw_barrel(DrawBuffer &buf, const Transform3D &xf, float radius, float ring_offset, const Color &col, bool caps) {
	Vector3 up = xf.basis.get_column(1).normalized();
	Vector3 u = xf.basis.get_column(0).normalized();
	Vector3 w = xf.basis.get_column(2).normalized();
	Vector3 top = xf.origin + up * ring_offset;
	Vector3 bot = xf.origin - up * ring_offset;
	add_circle(&buf, top, u, w, radius, col);
	add_circle(&buf, bot, u, w, radius, col);
	for (int i = 0; i < 4; ++i) {
		float a = (float)i / 4 * 6.2831853f;
		Vector3 off = (u * (real_t)Math::cos(a) + w * (real_t)Math::sin(a)) * radius;
		buf.add_line(bot + off, top + off, col);
	}
	if (caps) {
		draw_ball(&buf, top, radius, col);
		draw_ball(&buf, bot, radius, col);
	}
}

void draw_cone(DrawBuffer &buf, const Transform3D &xf, float radius, float height, const Color &col) {
	Vector3 up = xf.basis.get_column(1).normalized();
	Vector3 u = xf.basis.get_column(0).normalized();
	Vector3 w = xf.basis.get_column(2).normalized();
	Vector3 apex = xf.origin + up * (height * 0.5f);
	Vector3 base = xf.origin - up * (height * 0.5f);
	add_circle(&buf, base, u, w, radius, col);
	for (int i = 0; i < 4; ++i) {
		float a = (float)i / 4 * 6.2831853f;
		Vector3 off = (u * (real_t)Math::cos(a) + w * (real_t)Math::sin(a)) * radius;
		buf.add_line(base + off, apex, col);
	}
}

} // namespace

void Box3DWorld::update_debug_draw() {
	if (!b3World_IsValid(world_id)) {
		return;
	}
	if (debug_mi == nullptr) {
		debug_mi = memnew(MeshInstance3D);
		debug_mi->set_name("Box3DDebugDraw");
		debug_mi->set_as_top_level(true); // draw in world space
		Ref<ImmediateMesh> im;
		im.instantiate();
		debug_mi->set_mesh(im);
		Ref<StandardMaterial3D> mat;
		mat.instantiate();
		mat->set_shading_mode(BaseMaterial3D::SHADING_MODE_UNSHADED);
		mat->set_flag(BaseMaterial3D::FLAG_ALBEDO_FROM_VERTEX_COLOR, true);
		debug_mi->set_material_override(mat);
		add_child(debug_mi);
	}
	Ref<ImmediateMesh> im = debug_mi->get_mesh();
	im->clear_surfaces();

	DrawBuffer buffer;
	const Color col(0.25f, 1.0f, 0.4f);
	for (Box3DBody *body : bodies) {
		if (body == nullptr || !body->is_body_valid()) {
			continue;
		}
		// Compound bodies: outline each Box3DCollisionShape child. The physics
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
			switch (cs->get_shape_type()) {
				case Box3DCollisionShape::SPHERE:
					draw_ball(&buffer, cxf.origin, (float)cs->get_sphere_radius(), col);
					break;
				case Box3DCollisionShape::CAPSULE: {
					float cr2 = (float)cs->get_capsule_radius();
					float ring = (float)cs->get_capsule_height() * 0.5f - cr2;
					if (ring < 0.0f) {
						ring = 0.0f;
					}
					draw_barrel(buffer, cxf, cr2, ring, col, true);
				} break;
				case Box3DCollisionShape::BOX:
				default:
					draw_box(buffer, cxf, cs->get_box_size() * 0.5, col);
					break;
			}
		}
		if (has_child_shapes) {
			continue;
		}
		Transform3D xf = body->get_global_transform();
		float cr = (float)body->get_capsule_radius();
		float ch = (float)body->get_capsule_height();
		switch (body->get_shape_type()) {
			case Box3DBody::SPHERE:
				draw_ball(&buffer, xf.origin, (float)body->get_sphere_radius(), col);
				break;
			case Box3DBody::CAPSULE: {
				float ring = ch * 0.5f - cr;
				if (ring < 0.0f) {
					ring = 0.0f;
				}
				draw_barrel(buffer, xf, cr, ring, col, true);
			} break;
			case Box3DBody::CYLINDER:
				draw_barrel(buffer, xf, cr, ch * 0.5f, col, false);
				break;
			case Box3DBody::CONE:
				draw_cone(buffer, xf, cr, ch, col);
				break;
			case Box3DBody::BOX:
				draw_box(buffer, xf, body->get_box_size() * 0.5, col);
				break;
			default:
				break; // Hull / mesh colliders are not outlined
		}
	}

	if (buffer.verts.size() >= 2) {
		im->surface_begin(Mesh::PRIMITIVE_LINES);
		for (int64_t i = 0; i < buffer.verts.size(); ++i) {
			im->surface_set_color(buffer.colors[i]);
			im->surface_add_vertex(buffer.verts[i]);
		}
		im->surface_end();
	}
}

void Box3DWorld::set_debug_draw(bool p_enabled) {
	debug_draw = p_enabled;
	if (debug_mi != nullptr) {
		debug_mi->set_visible(p_enabled);
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
		b3World_EnableSleeping(world_id, enable_sleep);
	}
}

bool Box3DWorld::get_enable_sleep() const {
	return enable_sleep;
}

void Box3DWorld::set_enable_warm_starting(bool p_enabled) {
	enable_warm_starting = p_enabled;
	if (b3World_IsValid(world_id)) {
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
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "debug_draw"), "set_debug_draw", "get_debug_draw");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "contact_hertz", PROPERTY_HINT_RANGE, "0,120,0.1,or_greater"), "set_contact_hertz", "get_contact_hertz");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "contact_damping", PROPERTY_HINT_RANGE, "0,20,0.01,or_greater"), "set_contact_damping", "get_contact_damping");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "enable_sleep"), "set_enable_sleep", "get_enable_sleep");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "enable_warm_starting"), "set_enable_warm_starting", "get_enable_warm_starting");
}
