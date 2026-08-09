// SPDX-FileCopyrightText: 2026 box3d-godot contributors
// SPDX-License-Identifier: MIT

#include "box3d_body.h"

#include "box3d_collision_shape.h"
#include "box3d_conversions.h"
#include "box3d_joint.h"
#include "box3d_world.h"

#include <godot_cpp/classes/box_mesh.hpp>
#include <godot_cpp/classes/capsule_mesh.hpp>
#include <godot_cpp/classes/cylinder_mesh.hpp>
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/mesh_instance3d.hpp>
#include <godot_cpp/classes/sphere_mesh.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <cstring>
#include <vector>

using namespace godot;

// b3Matrix3 is column-major (cx, cy, cz) and Godot's Basis(x, y, z) constructor
// takes columns too, so inertia tensors map across 1:1.
static Basis to_gd_basis(const b3Matrix3 &m) {
	return Basis(to_gd(m.cx), to_gd(m.cy), to_gd(m.cz));
}

// b3SurfaceMaterial <-> Dictionary, the representation surface_materials and
// get_mesh_material() use. Absent keys keep b3DefaultSurfaceMaterial's value.
// customColor's high byte carries a b3DebugMaterial preset (types.h:418-421).
static b3SurfaceMaterial to_b3_material(const Dictionary &d) {
	b3SurfaceMaterial m = b3DefaultSurfaceMaterial();
	// Upstream asserts on negative friction / restitution / rolling resistance.
	m.friction = MAX(0.0f, (float)(double)d.get("friction", (double)m.friction));
	m.restitution = MAX(0.0f, (float)(double)d.get("restitution", (double)m.restitution));
	m.rollingResistance = MAX(0.0f, (float)(double)d.get("rolling_resistance", (double)m.rollingResistance));
	m.tangentVelocity = to_b3((Vector3)d.get("tangent_velocity", Vector3()));
	m.userMaterialId = (uint64_t)(int64_t)d.get("user_material_id", (int64_t)0);
	m.customColor = (uint32_t)(int64_t)d.get("custom_color", (int64_t)0);
	return m;
}

static Dictionary to_gd_material(const b3SurfaceMaterial &m) {
	Dictionary d;
	d["friction"] = m.friction;
	d["restitution"] = m.restitution;
	d["rolling_resistance"] = m.rollingResistance;
	d["tangent_velocity"] = to_gd(m.tangentVelocity);
	d["user_material_id"] = (int64_t)m.userMaterialId;
	d["custom_color"] = (int64_t)m.customColor;
	return d;
}

// Largest absolute component of a node scale. Spheres (and a capsule's radius)
// have no non-uniform form in Box3D, so they take the largest factor rather
// than silently shrinking below the visual.
static float max_abs_scale(const Vector3 &s) {
	return (float)MAX(Math::abs(s.x), MAX(Math::abs(s.y), Math::abs(s.z)));
}

static b3Matrix3 to_b3_matrix3(const Basis &b) {
	b3Matrix3 m;
	m.cx = to_b3(b.get_column(0));
	m.cy = to_b3(b.get_column(1));
	m.cz = to_b3(b.get_column(2));
	return m;
}

Box3DBody::Box3DBody() {}

Box3DBody::~Box3DBody() {
	if (mesh_data != nullptr) {
		b3DestroyMesh(mesh_data);
		mesh_data = nullptr;
	}
	if (height_field_data != nullptr) {
		b3DestroyHeightField(height_field_data);
		height_field_data = nullptr;
	}
	// A body deleted without ever leaving the tree never runs destroy_body(),
	// so the baked compound blob has to be released here too — the other two
	// teardown paths free all three.
	if (compound_data != nullptr) {
		b3DestroyCompound(compound_data);
		compound_data = nullptr;
	}
}

PackedStringArray Box3DBody::_get_configuration_warnings() const {
	PackedStringArray warnings;
	// box3d.h:914 says enableSensorEvents is "ignored for sensors", but
	// src/sensor.c:208-215 drops every overlap of a sensor whose own shape does
	// not carry the flag, and says so in its own comment. So this combination
	// is a trigger that silently never fires.
	if (is_sensor && !sensor_events) {
		warnings.push_back(
				"Is Sensor is on but Sensor Events is off, so this sensor drops every "
				"overlap it finds and will never report one.\nTurn Sensor Events back "
				"on, or turn Is Sensor off if this body is not a trigger.");
	}
	// A mesh or height field only generates contacts on a static body; the
	// creation path warns at runtime, this catches it in the editor.
	if (body_type != STATIC && !is_sensor && (shape_type == MESH || shape_type == HEIGHT_FIELD)) {
		warnings.push_back(
				"Mesh and Height Field colliders only generate contacts on a static "
				"body.\nSet Body Type to Static, or use Hull / Fit Mesh for a moving "
				"body.");
	}
	return warnings;
}

Box3DWorld *Box3DBody::find_world() {
	Node *node = get_parent();
	while (node != nullptr) {
		Box3DWorld *w = Object::cast_to<Box3DWorld>(node);
		if (w != nullptr) {
			return w;
		}
		node = node->get_parent();
	}
	return nullptr;
}

bool Box3DBody::is_body_valid() const {
	return body_live();
}

// Validity check that also syncs with an in-flight async world step: touching
// the b3 API while the solver thread runs would race, so wait it out first
// (a single atomic load when nothing is in flight).
bool Box3DBody::body_live() const {
	if (world != nullptr) {
		world->join_async_step();
	}
	return b3Body_IsValid(body_id);
}

std::vector<b3ShapeId> Box3DBody::own_shape_ids() const {
	std::vector<b3ShapeId> ids;
	if (!body_live()) {
		return ids;
	}
	int capacity = b3Body_GetShapeCount(body_id);
	if (capacity <= 0) {
		return ids;
	}
	ids.resize((size_t)capacity);
	// The fill call returns the valid count, which may be lower than capacity.
	int count = b3Body_GetShapes(body_id, ids.data(), capacity);
	ids.resize((size_t)(count < 0 ? 0 : count));
	return ids;
}

b3Filter Box3DBody::make_filter() const {
	b3Filter filter = b3DefaultFilter();
	filter.categoryBits = ((uint64_t)collision_layer_high << 32) | (uint64_t)collision_layer;
	filter.maskBits = ((uint64_t)collision_mask_high << 32) | (uint64_t)collision_mask;
	filter.groupIndex = collision_group;
	return filter;
}

// True when this shape id belongs to a Box3DCollisionShape child that carries
// its own filter or its own answer for one of the event enables. Such a shape
// is not the body's to overwrite (P-019). The shape's userData is the authoring
// node, or null for a body's own shape_type shape.
static Box3DCollisionShape *shape_node_of(b3ShapeId p_id) {
	return (Box3DCollisionShape *)b3Shape_GetUserData(p_id);
}

void Box3DBody::apply_filter() {
	std::vector<b3ShapeId> ids = own_shape_ids();
	b3Filter filter = make_filter();
	for (size_t i = 0; i < ids.size(); ++i) {
		Box3DCollisionShape *node = shape_node_of(ids[i]);
		if (node != nullptr && node->has_filter_override()) {
			continue;
		}
		// invokeContacts: upstream calls this nearly as expensive as recreating
		// the shape, but without it a widened mask only takes effect for pairs
		// that happen to move afterwards.
		b3Shape_SetFilter(ids[i], filter, true);
	}
}

bool Box3DBody::apply_surface_material() {
	if (debug_has_child_shapes) {
		return false;
	}
	std::vector<b3ShapeId> ids = own_shape_ids();
	if (ids.empty()) {
		return false;
	}
	for (size_t i = 0; i < ids.size(); ++i) {
		// Read-modify-write: userMaterialId and customColor belong to whoever
		// set them, and mesh shapes keep their per-triangle materials.
		b3SurfaceMaterial mat = b3Shape_GetSurfaceMaterial(ids[i]);
		// Upstream asserts on negative material values.
		mat.friction = MAX(0.0f, (float)friction);
		mat.restitution = MAX(0.0f, (float)restitution);
		mat.rollingResistance = MAX(0.0f, (float)rolling_resistance);
		mat.tangentVelocity = to_b3(tangent_velocity);
		mat.userMaterialId = (uint64_t)user_material_id;
		b3Shape_SetSurfaceMaterial(ids[i], mat);
	}
	return true;
}

// P-010: b3Shape_SetDensity (box3d.h:870-872) does this in place, so changing
// the density no longer costs the body its velocity, sleep state and contacts.
// A runtime compound is the one case with nothing to push to — each
// Box3DCollisionShape child authors its own density, which create_child_shape
// reads from the node — so there this is deliberately a no-op rather than a
// rebuild that would produce byte-identical shapes. A BAKED compound is a
// single shape carrying the body's density, and does take it.
void Box3DBody::apply_density() {
	if (debug_has_child_shapes && compound_data == nullptr) {
		return;
	}
	std::vector<b3ShapeId> ids = own_shape_ids();
	if (ids.empty()) {
		return;
	}
	for (size_t i = 0; i < ids.size(); ++i) {
		// updateBodyMass false: one recompute below covers every shape
		// (types.h:514-516). Upstream asserts a non-negative density.
		b3Shape_SetDensity(ids[i], MAX(0.0f, (float)density), false);
	}
	b3Body_ApplyMassFromShapes(body_id);
	debug_mass = b3Body_GetMass(body_id);
}

// All three enables are pushed together, not just the one that changed: they
// are idempotent, the other two are already at these values, and one loop over
// the shapes is cheaper than three. A child shape that answers for itself
// (EventMode other than INHERIT, P-019) is skipped for that one enable only —
// which is also why hit events go through the per-shape
// b3Shape_EnableHitEvents rather than upstream's coarser
// b3Body_EnableHitEvents (box3d.h:731-733), whose "all shapes" would overwrite
// a child's override.
bool Box3DBody::apply_shape_events() {
	std::vector<b3ShapeId> ids = own_shape_ids();
	if (ids.empty()) {
		return false;
	}
	for (size_t i = 0; i < ids.size(); ++i) {
		Box3DCollisionShape *node = shape_node_of(ids[i]);
		if (node == nullptr || node->get_contact_event_mode() == Box3DCollisionShape::EVENT_INHERIT) {
			b3Shape_EnableContactEvents(ids[i], contact_monitor);
		}
		if (node == nullptr || node->get_sensor_event_mode() == Box3DCollisionShape::EVENT_INHERIT) {
			b3Shape_EnableSensorEvents(ids[i], sensor_events);
		}
		if (node == nullptr || node->get_hit_event_mode() == Box3DCollisionShape::EVENT_INHERIT) {
			b3Shape_EnableHitEvents(ids[i], hit_events);
		}
	}
	return true;
}

void Box3DBody::create_in_world() {
	if (Engine::get_singleton()->is_editor_hint()) {
		return;
	}
	world = find_world();
	if (world == nullptr) {
		UtilityFunctions::push_warning("Box3DBody has no Box3DWorld ancestor; it will not be simulated.");
		return;
	}
	b3WorldId world_id = world->get_world_id();
	if (!b3World_IsValid(world_id)) {
		return;
	}

	Transform3D xform = get_global_transform();
	Quaternion rotation = xform.basis.get_rotation_quaternion();
	// Box3D bodies have no scale: b3WorldTransform is position + rotation only.
	// A scaled node therefore has to scale its geometry instead, which upstream
	// supports on meshes and transformed hulls (box3d.h:805-822, collision.h:255).
	node_scale = xform.basis.get_scale();
	node_scaled = !node_scale.is_equal_approx(Vector3(1, 1, 1));
	if (!node_scaled) {
		// Snap to exactly one: get_scale() on a rotated basis can come back a
		// float ulp off, and every unscaled body must build bit-identically to
		// how it did before scale was honored at all.
		node_scale = Vector3(1, 1, 1);
	}

	b3BodyDef body_def = b3DefaultBodyDef();
	body_def.type = (b3BodyType)body_type;
	body_def.position = to_b3_pos(xform.origin);
	body_def.rotation = to_b3(rotation);
	body_def.linearDamping = (float)linear_damping;
	body_def.angularDamping = (float)angular_damping;
	body_def.gravityScale = (float)gravity_scale;
	body_def.sleepThreshold = (float)sleep_threshold;
	body_def.enableSleep = can_sleep;
	body_def.isEnabled = enabled;
	body_def.isBullet = continuous;
	body_def.enableContactRecycling = contact_recycling;
	body_def.allowFastRotation = allow_fast_rotation;
	body_def.motionLocks.linearX = lock_linear_x;
	body_def.motionLocks.linearY = lock_linear_y;
	body_def.motionLocks.linearZ = lock_linear_z;
	body_def.motionLocks.angularX = lock_angular_x;
	body_def.motionLocks.angularY = lock_angular_y;
	body_def.motionLocks.angularZ = lock_angular_z;
	body_def.userData = this;
	// Upstream copies the name into the world's name table, so this temporary
	// only has to outlive the create call. It makes solver logs and upstream's
	// drawBodyNames debug option readable.
	CharString node_name = String(get_name()).utf8();
	body_def.name = node_name.get_data();
	body_id = b3CreateBody(world_id, &body_def);
	snap_prev = b3Body_GetTransform(body_id);
	snap_curr = snap_prev;
	snap_awake = b3Body_IsAwake(body_id);
	debug_enabled = b3Body_IsEnabled(body_id);

	build_shapes();
	world->register_body(this);
}

void Box3DBody::build_shapes() {
	// Compound bodies: if there are Box3DCollisionShape children, build a shape
	// for each and skip the body's own shape_type.
	{
		Transform3D body_inv = get_global_transform().affine_inverse();
		bool has_child_shapes = false;
		// A baked compound collapses every child into one shape and one
		// broad-phase proxy; it falls back to the runtime path if it cannot.
		if (baked_compound && create_baked_compound(body_inv)) {
			debug_mass = b3Body_GetMass(body_id);
			debug_has_child_shapes = true;
			debug_min_ext = debug_min_extent();
			debug_max_ext = debug_max_extent();
			return;
		}
		for (int i = 0; i < get_child_count(); ++i) {
			Box3DCollisionShape *cs = Object::cast_to<Box3DCollisionShape>(get_child(i));
			// A child mid-unparent is still in the list at
			// NOTIFICATION_UNPARENTED time (Godot 4.7); building a shape for it
			// would leave a collider behind and, once the node is freed, a
			// dangling userData on every event dispatch.
			if (cs != nullptr && !cs->is_leaving()) {
				has_child_shapes = true;
				create_child_shape(cs, body_inv);
			}
		}
		if (has_child_shapes) {
			// Every child was created with updateBodyMass = false, so the mass
			// properties are due exactly one recompute (types.h:514-516).
			b3Body_ApplyMassFromShapes(body_id);
			debug_mass = b3Body_GetMass(body_id);
			debug_has_child_shapes = true;
			debug_min_ext = debug_min_extent();
			debug_max_ext = debug_max_extent();
			return;
		}
	}

	b3ShapeDef shape_def = b3DefaultShapeDef();
	shape_def.density = (float)density;
	shape_def.baseMaterial.friction = (float)friction;
	shape_def.baseMaterial.restitution = (float)restitution;
	shape_def.baseMaterial.rollingResistance = (float)rolling_resistance;
	shape_def.baseMaterial.tangentVelocity = to_b3(tangent_velocity);
	// The body's own shape carries the same material id its surface_materials
	// entries can, so a Box3DContactRules table works on a plain body with no
	// Box3DCollisionShape children.
	shape_def.baseMaterial.userMaterialId = (uint64_t)user_material_id;
	shape_def.enableContactEvents = contact_monitor;
	shape_def.filter = make_filter();
	shape_def.isSensor = is_sensor;
	shape_def.explosionScale = (float)explosion_scale;
	shape_def.invokeContactCreation = invoke_contact_creation;
	shape_def.enableSpeculativeContact = speculative_contact;
	// On by default so sensors detect any body (like an Area3D) and the debug
	// draw's impact flash works; Box3D only does work here in proportion to the
	// number of sensors, and hit events only fire above the world's hit-event
	// speed threshold (default 1 m/s). Both are properties now (P-009), so a
	// scene that listens to neither can turn them off.
	shape_def.enableSensorEvents = sensor_events;
	shape_def.enableHitEvents = hit_events;
	// P-001 / P-017: a body's own shape has no Box3DCollisionShape node, so its
	// userData stays null on purpose — shape_node_of() would otherwise hand a
	// Box3DBody* back as a shape node. The owner is still reachable the way
	// every query and event payload reaches it, through b3Shape_GetBody plus
	// b3Body_GetUserData. What it CAN have is the body's name, so upstream's
	// drawShapeNames and its solver logs read the same for a plain body as for
	// a compound child. Copied into the world's name table by the create call.
	CharString shape_name = String(get_name()).utf8();
	shape_def.name = shape_name.get_data();
	// Per-triangle materials for mesh / height field shapes. Box3D copies the
	// array in b3CreateShape (src/shape.c:202-213), so this local outlives it.
	std::vector<b3SurfaceMaterial> materials = build_surface_materials();
	if (!materials.empty()) {
		shape_def.materials = materials.data();
		shape_def.materialCount = (int)materials.size();
	}

	switch (shape_type) {
		case SPHERE: {
			b3Sphere sphere;
			sphere.center = b3Vec3{ 0.0f, 0.0f, 0.0f };
			sphere.radius = (float)sphere_radius * (node_scaled ? max_abs_scale(node_scale) : 1.0f);
			b3CreateSphereShape(body_id, &shape_def, &sphere);
		} break;
		case CAPSULE: {
			float radius = (float)capsule_radius;
			float half = (float)(capsule_height * 0.5) - radius;
			if (half < 0.0f) {
				half = 0.0f;
			}
			if (node_scaled) {
				// The axis is y, so the caps follow the y scale and the radius
				// follows the widest of the other two.
				half *= (float)Math::abs(node_scale.y);
				radius *= (float)MAX(Math::abs(node_scale.x), Math::abs(node_scale.z));
			}
			b3Capsule capsule;
			capsule.center1 = b3Vec3{ 0.0f, -half, 0.0f };
			capsule.center2 = b3Vec3{ 0.0f, half, 0.0f };
			capsule.radius = radius;
			b3CreateCapsuleShape(body_id, &shape_def, &capsule);
		} break;
		case CYLINDER: {
			// yOffset centers the cylinder on the body origin (Box3D builds it
			// base-up from the offset), matching Godot's centered CylinderMesh.
			float half = (float)capsule_height * 0.5f;
			b3HullData *hull = b3CreateCylinder((float)capsule_height, (float)capsule_radius, -half, cylinder_sides);
			if (hull != nullptr) {
				if (node_scaled) {
					b3Transform xf;
					xf.p = b3Vec3_zero;
					xf.q = b3Quat_identity;
					b3CreateTransformedHullShape(body_id, &shape_def, hull, xf, to_b3(node_scale));
				} else {
					b3CreateHullShape(body_id, &shape_def, hull);
				}
				b3DestroyHull(hull);
			}
		} break;
		case CONE: {
			// radius1 = base, radius2 = 0 (the point). b3CreateCone has no offset,
			// so bake a -height/2 shift to center it on the body origin.
			b3HullData *hull = b3CreateCone((float)capsule_height, (float)capsule_radius, 0.0f, cylinder_sides);
			if (hull != nullptr) {
				b3Transform xf;
				// b3CreateTransformedHullShape applies the scale FIRST, so the
				// centering offset is in already-scaled space (box3d.h:806-807).
				xf.p = to_b3(Vector3(0.0, -capsule_height * 0.5, 0.0) * node_scale);
				xf.q = b3Quat_identity;
				b3CreateTransformedHullShape(body_id, &shape_def, hull, xf, to_b3(node_scale));
				b3DestroyHull(hull);
			}
		} break;
		case HULL: {
			Ref<Mesh> src_mesh;
			Transform3D src_local;
			if (resolve_collision_mesh(src_mesh, src_local)) {
				PackedVector3Array faces = src_mesh->get_faces();
				int count = faces.size();
				if (count >= 4) {
					std::vector<b3Vec3> points((size_t)count);
					for (int i = 0; i < count; ++i) {
						points[(size_t)i] = to_b3(src_local.xform(faces[i]));
					}
					int max_verts = count < 255 ? count : 255;
					b3HullData *hull = b3CreateHull(points.data(), count, max_verts);
					if (hull != nullptr) {
						if (node_scaled) {
							// Non-uniform and mirrored scale are supported here
							// (box3d.h:805-809).
							b3Transform xf;
							xf.p = b3Vec3_zero;
							xf.q = b3Quat_identity;
							b3CreateTransformedHullShape(body_id, &shape_def, hull, xf, to_b3(node_scale));
						} else {
							b3CreateHullShape(body_id, &shape_def, hull);
						}
						b3DestroyHull(hull);
					}
				}
			} else {
				UtilityFunctions::push_warning("Box3DBody shape_type is Hull but no collision_mesh or child MeshInstance3D was found.");
			}
		} break;
		case MESH: {
			if (mesh_data != nullptr) {
				b3DestroyMesh(mesh_data);
				mesh_data = nullptr;
			}
			// A sensor mesh is exempt: sensors are resolved by overlap
			// (src/sensor.c:65 handles the mesh case), not by the contact path
			// the static-only rule is about. Upstream's own Sensor Hits sample
			// puts a mesh sensor on a KINEMATIC body
			// (samples/sample_events.cpp:720-731).
			if (body_type != STATIC && !is_sensor) {
				UtilityFunctions::push_warning("Box3DBody: Mesh colliders only generate contacts on static bodies.");
			}
			if (!mesh_vertices.is_empty()) {
				// Raw triangle data straight from script (b3MeshDef,
				// types.h:2067-2098). Winding is passed through untouched.
				int vcount = mesh_vertices.size();
				int icount = mesh_indices.size();
				if (vcount < 3 || icount < 3 || (icount % 3) != 0) {
					UtilityFunctions::push_warning("Box3DBody: mesh_vertices needs 3+ vertices and mesh_indices a non-zero multiple of 3.");
					break;
				}
				int tri_count = icount / 3;
				std::vector<b3Vec3> verts((size_t)vcount);
				for (int i = 0; i < vcount; ++i) {
					verts[(size_t)i] = to_b3(mesh_vertices[i]);
				}
				std::vector<int32_t> idx((size_t)icount);
				bool bad_index = false;
				for (int i = 0; i < icount; ++i) {
					int32_t v = mesh_indices[i];
					if (v < 0 || v >= vcount) {
						bad_index = true;
						break;
					}
					idx[(size_t)i] = v;
				}
				if (bad_index) {
					UtilityFunctions::push_warning("Box3DBody: mesh_indices contains an index outside mesh_vertices.");
					break;
				}
				std::vector<uint8_t> tri_materials;
				if (!mesh_materials.is_empty()) {
					if (mesh_materials.size() != tri_count) {
						UtilityFunctions::push_warning("Box3DBody: mesh_materials must hold one index per triangle; ignoring it.");
					} else {
						tri_materials.resize((size_t)tri_count);
						for (int i = 0; i < tri_count; ++i) {
							tri_materials[(size_t)i] = mesh_materials[i];
						}
					}
				}
				b3MeshDef def = {};
				def.vertices = verts.data();
				def.indices = idx.data();
				def.materialIndices = tri_materials.empty() ? nullptr : tri_materials.data();
				def.vertexCount = vcount;
				def.triangleCount = tri_count;
				def.weldVertices = mesh_weld_tolerance > 0.0;
				def.weldTolerance = (float)mesh_weld_tolerance;
				def.useMedianSplit = mesh_median_split;
				def.identifyEdges = true;
				// Box3D keeps a pointer to mesh_data (box3d.h:816-820), so it
				// must live until the body is destroyed (see destroy_body()).
				mesh_data = b3CreateMesh(&def, nullptr, 0);
				if (mesh_data != nullptr) {
					b3CreateMeshShape(body_id, &shape_def, mesh_data, to_b3(node_scale));
				}
				break;
			}
			Ref<Mesh> src_mesh;
			Transform3D src_local;
			if (resolve_collision_mesh(src_mesh, src_local)) {
				PackedVector3Array faces = src_mesh->get_faces();
				int vcount = faces.size();
				if (vcount >= 3 && (vcount % 3) == 0) {
					std::vector<b3Vec3> verts((size_t)vcount);
					std::vector<int32_t> idx((size_t)vcount);
					for (int i = 0; i < vcount; ++i) {
						verts[(size_t)i] = to_b3(src_local.xform(faces[i]));
					}
					// Reverse triangle winding: Godot winds faces so the normal
					// points outward, but Box3D's one-sided mesh collision uses the
					// opposite winding, so flip to collide with the outer surface.
					for (int t = 0; t < vcount / 3; ++t) {
						idx[(size_t)(t * 3 + 0)] = t * 3 + 0;
						idx[(size_t)(t * 3 + 1)] = t * 3 + 2;
						idx[(size_t)(t * 3 + 2)] = t * 3 + 1;
					}
					b3MeshDef def = {};
					def.vertices = verts.data();
					def.indices = idx.data();
					def.vertexCount = vcount;
					def.triangleCount = vcount / 3;
					def.weldVertices = mesh_weld_tolerance > 0.0;
					def.weldTolerance = (float)mesh_weld_tolerance;
					def.useMedianSplit = mesh_median_split;
					def.identifyEdges = true;
					// Box3D keeps a pointer to mesh_data, so it must live until the
					// body is destroyed (see destroy_body()).
					mesh_data = b3CreateMesh(&def, nullptr, 0);
					if (mesh_data != nullptr) {
						b3CreateMeshShape(body_id, &shape_def, mesh_data, to_b3(node_scale));
					}
				}
			} else {
				UtilityFunctions::push_warning("Box3DBody shape_type is Mesh but no collision_mesh or child MeshInstance3D was found.");
			}
		} break;
		case FIT_MESH: {
			// Box collider auto-sized to the child MeshInstance3D's mesh bounds, so
			// resizing the visual mesh resizes the collider — no separate box_size.
			Ref<Mesh> src_mesh;
			Transform3D src_local;
			if (resolve_collision_mesh(src_mesh, src_local)) {
				AABB aabb = src_mesh->get_aabb();
				// Transform the 8 corners into body space and take their bounds.
				AABB local_aabb;
				for (int c = 0; c < 8; ++c) {
					Vector3 corner = src_local.xform(aabb.get_endpoint(c));
					if (c == 0) {
						local_aabb = AABB(corner, Vector3());
					} else {
						local_aabb = local_aabb.expand(corner);
					}
				}
				Vector3 h = local_aabb.size * 0.5;
				Vector3 center = local_aabb.position + h;
				b3Transform xf;
				xf.p = to_b3(center);
				xf.q = b3Quat_identity;
				if (node_scaled) {
					// b3MakeScaledBoxHull applies the scale AFTER the transform
					// (collision.h:249-255), so the fitted center scales with it.
					b3BoxHull box = b3MakeScaledBoxHull(to_b3(h), xf, to_b3(node_scale));
					b3CreateHullShape(body_id, &shape_def, &box.base);
				} else {
					b3BoxHull box = b3MakeTransformedBoxHull((float)h.x, (float)h.y, (float)h.z, xf);
					b3CreateHullShape(body_id, &shape_def, &box.base);
				}
			} else {
				UtilityFunctions::push_warning("Box3DBody shape_type is Fit Mesh but no child MeshInstance3D was found.");
			}
		} break;
		case HEIGHT_FIELD: {
			if (height_field_data != nullptr) {
				b3DestroyHeightField(height_field_data);
				height_field_data = nullptr;
			}
			if (body_type != STATIC) {
				UtilityFunctions::push_warning("Box3DBody: Height field colliders are only allowed on static bodies.");
			}
			height_field_data = build_height_field();
			if (height_field_data != nullptr) {
				// Box3D keeps a reference to the field (box3d.h:826-828), so it
				// is released only in destroy_body().
				b3CreateHeightFieldShape(body_id, &shape_def, height_field_data);
			}
		} break;
		case BOX:
		default: {
			if (node_scaled) {
				b3Transform xf;
				xf.p = b3Vec3_zero;
				xf.q = b3Quat_identity;
				b3BoxHull box = b3MakeScaledBoxHull(to_b3(box_size * 0.5), xf, to_b3(node_scale));
				b3CreateHullShape(body_id, &shape_def, &box.base);
			} else {
				b3BoxHull box = b3MakeBoxHull((float)(box_size.x * 0.5), (float)(box_size.y * 0.5), (float)(box_size.z * 0.5));
				b3CreateHullShape(body_id, &shape_def, &box.base);
			}
		} break;
	}

	debug_mass = b3Body_GetMass(body_id);
	debug_has_child_shapes = false;
	debug_min_ext = debug_min_extent();
	debug_max_ext = debug_max_extent();
	update_auto_visual();
}

std::vector<b3SurfaceMaterial> Box3DBody::build_surface_materials() const {
	std::vector<b3SurfaceMaterial> out;
	int count = surface_materials.size();
	out.reserve((size_t)count);
	for (int i = 0; i < count; ++i) {
		out.push_back(to_b3_material((Dictionary)surface_materials[i]));
	}
	return out;
}

b3HeightFieldData *Box3DBody::build_height_field() const {
	const int count_x = height_field_size.x;
	const int count_z = height_field_size.y;
	// b3CreateHeightField asserts countX * countZ >= 4 (src/height_field.c:109).
	if (count_x < 2 || count_z < 2) {
		UtilityFunctions::push_warning("Box3DBody: height_field_size needs at least 2 grid lines on each axis.");
		return nullptr;
	}
	if (height_field_scale.x <= 0.0 || height_field_scale.y <= 0.0 || height_field_scale.z <= 0.0) {
		// types.h:2260 — "All components must be positive values."
		UtilityFunctions::push_warning("Box3DBody: every component of height_field_scale must be positive.");
		return nullptr;
	}
	const b3Vec3 scale = to_b3(height_field_scale);

	if (height_field_heights.is_empty()) {
		// Procedural field. Both take (rowCount = countZ, columnCount = countX)
		// (src/height_field.c:1332, :1384), and b3CreateWave's rowFrequency
		// runs along z while columnFrequency runs along x (:1391-1392).
		if (height_field_wave == Vector2()) {
			return b3CreateGrid(count_z, count_x, scale, height_field_holes);
		}
		return b3CreateWave(count_z, count_x, scale, (float)height_field_wave.y, (float)height_field_wave.x,
				height_field_holes);
	}

	const int height_count = count_x * count_z;
	if (height_field_heights.size() != height_count) {
		UtilityFunctions::push_warning("Box3DBody: height_field_heights must hold height_field_size.x * height_field_size.y entries.");
		return nullptr;
	}
	std::vector<float> heights((size_t)height_count);
	float lo = height_field_heights[0];
	float hi = lo;
	for (int i = 0; i < height_count; ++i) {
		float h = height_field_heights[i];
		heights[(size_t)i] = h;
		lo = MIN(lo, h);
		hi = MAX(hi, h);
	}

	const int cell_count = (count_x - 1) * (count_z - 1);
	std::vector<uint8_t> cell_materials;
	if (!height_field_materials.is_empty()) {
		if (height_field_materials.size() != cell_count) {
			UtilityFunctions::push_warning("Box3DBody: height_field_materials must hold one index per cell, (countX - 1) * (countZ - 1); ignoring it.");
		} else {
			cell_materials.resize((size_t)cell_count);
			for (int i = 0; i < cell_count; ++i) {
				cell_materials[(size_t)i] = height_field_materials[i];
			}
		}
	}

	b3HeightFieldDef def = {};
	def.heights = heights.data();
	def.materialIndices = cell_materials.empty() ? nullptr : cell_materials.data();
	def.scale = scale;
	def.countX = count_x;
	def.countZ = count_z;
	// An unset (or inverted) range means "fit the data"; upstream asserts
	// globalMinimumHeight <= globalMaximumHeight (src/height_field.c:143).
	if (height_field_height_range.x < height_field_height_range.y) {
		def.globalMinimumHeight = (float)height_field_height_range.x;
		def.globalMaximumHeight = (float)height_field_height_range.y;
	} else {
		def.globalMinimumHeight = lo;
		def.globalMaximumHeight = hi;
	}
	def.clockwiseWinding = height_field_clockwise;
	return b3CreateHeightField(&def);
}

bool Box3DBody::resolve_collision_mesh(Ref<Mesh> &r_mesh, Transform3D &r_local) {
	if (collision_mesh.is_valid()) {
		r_mesh = collision_mesh;
		r_local = Transform3D();
		return true;
	}
	// Fall back to the first child MeshInstance3D's mesh, at its transform
	// relative to this body — so devs can drop in their own model as a collider
	// without assigning collision_mesh separately.
	Transform3D body_inv = get_global_transform().affine_inverse();
	for (int i = 0; i < get_child_count(); ++i) {
		MeshInstance3D *mi = Object::cast_to<MeshInstance3D>(get_child(i));
		// Skip our own auto_visual mesh: it's derived FROM the collision shape,
		// so it must never be used as a collision source (would self-reference).
		if (mi != nullptr && mi != auto_mesh_instance && mi->get_mesh().is_valid()) {
			r_mesh = mi->get_mesh();
			r_local = body_inv * mi->get_global_transform();
			return true;
		}
	}
	return false;
}

void Box3DBody::update_auto_visual() {
	if (Engine::get_singleton()->is_editor_hint()) {
		return;
	}
	if (!auto_visual) {
		if (auto_mesh_instance != nullptr) {
			auto_mesh_instance->queue_free();
			auto_mesh_instance = nullptr;
		}
		return;
	}
	// Defer to a user-provided MeshInstance3D child: auto_visual only fills in
	// when there's nothing else drawing the body.
	for (int i = 0; i < get_child_count(); ++i) {
		MeshInstance3D *mi = Object::cast_to<MeshInstance3D>(get_child(i));
		if (mi != nullptr && mi != auto_mesh_instance) {
			if (auto_mesh_instance != nullptr) {
				auto_mesh_instance->queue_free();
				auto_mesh_instance = nullptr;
			}
			return;
		}
	}

	// Build a mesh matching the current primitive collider. Hull/Mesh/Fit Mesh
	// have no size of their own to mirror (they derive the collider FROM a
	// mesh, the opposite direction), so nothing is generated for those.
	Ref<Mesh> mesh;
	switch (shape_type) {
		case SPHERE: {
			Ref<SphereMesh> m;
			m.instantiate();
			m->set_radius((float)sphere_radius);
			m->set_height((float)sphere_radius * 2.0f);
			mesh = m;
		} break;
		case CAPSULE: {
			Ref<CapsuleMesh> m;
			m.instantiate();
			m->set_radius((float)capsule_radius);
			m->set_height((float)capsule_height);
			mesh = m;
		} break;
		case CYLINDER: {
			Ref<CylinderMesh> m;
			m.instantiate();
			m->set_top_radius((float)capsule_radius);
			m->set_bottom_radius((float)capsule_radius);
			m->set_height((float)capsule_height);
			mesh = m;
		} break;
		case CONE: {
			// Apex up, base down — matches b3CreateCone's centering (see the
			// CONE case above) and Godot's CylinderMesh (top face at +height/2).
			Ref<CylinderMesh> m;
			m.instantiate();
			m->set_top_radius(0.0f);
			m->set_bottom_radius((float)capsule_radius);
			m->set_height((float)capsule_height);
			mesh = m;
		} break;
		case BOX: {
			Ref<BoxMesh> m;
			m.instantiate();
			m->set_size(box_size); // BoxMesh size is full extents, like box_size
			mesh = m;
		} break;
		default:
			break;
	}

	if (!mesh.is_valid()) {
		if (auto_mesh_instance != nullptr) {
			auto_mesh_instance->queue_free();
			auto_mesh_instance = nullptr;
		}
		return;
	}

	if (auto_mesh_instance == nullptr) {
		auto_mesh_instance = memnew(MeshInstance3D);
		auto_mesh_instance->set_name("Box3DAutoVisual");
		add_child(auto_mesh_instance);
	}
	auto_mesh_instance->set_mesh(mesh);
}

bool Box3DBody::resize_own_shape() {
	// Only the body's OWN single shape. A compound's geometry belongs to its
	// children, and a baked compound is immutable once built.
	if (debug_has_child_shapes || compound_data != nullptr || !body_live()) {
		return false;
	}
	std::vector<b3ShapeId> ids = own_shape_ids();
	if (ids.size() != 1) {
		return false;
	}
	const b3ShapeId id = ids[0];
	// Every b3Shape_Set* interns and reallocates exactly as the matching
	// b3Create*Shape does (b3AddHullToDatabase, src/shape.c:1608, which even
	// short-circuits when the shared hull is unchanged), so this is the same
	// geometry the rebuild would have produced.
	b3HullData *owned = nullptr;
	switch (shape_type) {
		case SPHERE: {
			b3Sphere sphere;
			sphere.center = b3Vec3{ 0.0f, 0.0f, 0.0f };
			sphere.radius = (float)sphere_radius * (node_scaled ? max_abs_scale(node_scale) : 1.0f);
			b3Shape_SetSphere(id, &sphere);
		} break;
		case CAPSULE: {
			float radius = (float)capsule_radius;
			float half = (float)(capsule_height * 0.5) - radius;
			if (half < 0.0f) {
				half = 0.0f;
			}
			if (node_scaled) {
				half *= (float)Math::abs(node_scale.y);
				radius *= (float)MAX(Math::abs(node_scale.x), Math::abs(node_scale.z));
			}
			b3Capsule capsule;
			capsule.center1 = b3Vec3{ 0.0f, -half, 0.0f };
			capsule.center2 = b3Vec3{ 0.0f, half, 0.0f };
			capsule.radius = radius;
			b3Shape_SetCapsule(id, &capsule);
		} break;
		case CYLINDER: {
			float half = (float)capsule_height * 0.5f;
			b3HullData *hull = b3CreateCylinder((float)capsule_height, (float)capsule_radius, -half, cylinder_sides);
			if (hull == nullptr) {
				return false;
			}
			if (node_scaled) {
				// b3Shape_SetHull takes no transform or scale, so the scale is
				// baked in first, exactly as b3CreateTransformedHullShape does
				// it at creation (collision.h:231).
				b3Transform xf;
				xf.p = b3Vec3_zero;
				xf.q = b3Quat_identity;
				owned = b3CloneAndTransformHull(hull, xf, to_b3(node_scale));
				b3DestroyHull(hull);
				if (owned == nullptr) {
					return false;
				}
				b3Shape_SetHull(id, owned);
			} else {
				b3Shape_SetHull(id, hull);
				b3DestroyHull(hull);
			}
		} break;
		case CONE: {
			b3HullData *hull = b3CreateCone((float)capsule_height, (float)capsule_radius, 0.0f, cylinder_sides);
			if (hull == nullptr) {
				return false;
			}
			b3Transform xf;
			// The scale is applied first, so the centering offset is in
			// already-scaled space (box3d.h:806-807), as at creation.
			xf.p = to_b3(Vector3(0.0, -capsule_height * 0.5, 0.0) * node_scale);
			xf.q = b3Quat_identity;
			owned = b3CloneAndTransformHull(hull, xf, to_b3(node_scale));
			b3DestroyHull(hull);
			if (owned == nullptr) {
				return false;
			}
			b3Shape_SetHull(id, owned);
		} break;
		case BOX: {
			if (node_scaled) {
				b3Transform xf;
				xf.p = b3Vec3_zero;
				xf.q = b3Quat_identity;
				b3BoxHull box = b3MakeScaledBoxHull(to_b3(box_size * 0.5), xf, to_b3(node_scale));
				b3Shape_SetHull(id, &box.base);
			} else {
				b3BoxHull box = b3MakeBoxHull((float)(box_size.x * 0.5), (float)(box_size.y * 0.5), (float)(box_size.z * 0.5));
				b3Shape_SetHull(id, &box.base);
			}
		} break;
		default:
			// HULL / MESH / FIT_MESH / HEIGHT_FIELD: their geometry comes from a
			// resource or an owned blob, so changing it still goes through a
			// rebuild. (There is no b3Shape_SetHeightField at all.)
			return false;
	}
	if (owned != nullptr) {
		// b3Shape_SetHull interned a copy, so the local one goes now.
		b3DestroyHull(owned);
	}
	// The Set* family deliberately leaves mass alone (box3d.h:959-980), and the
	// rebuild this replaces recomputed it.
	b3Body_ApplyMassFromShapes(body_id);
	debug_mass = b3Body_GetMass(body_id);
	// The debug draw reads these cached extents rather than the live shape.
	debug_min_ext = debug_min_extent();
	debug_max_ext = debug_max_extent();
	update_auto_visual();
	return true;
}

void Box3DBody::refresh_gizmos() {
	if (Engine::get_singleton()->is_editor_hint()) {
		update_gizmos();
	}
}

void Box3DBody::resize_or_rebuild() {
	refresh_gizmos();
	if (!resize_own_shape()) {
		recreate_shapes();
	}
}

void Box3DBody::create_child_shape(Box3DCollisionShape *p_shape, const Transform3D &p_body_inv) {
	b3ShapeDef sd = b3DefaultShapeDef();
	sd.density = (float)p_shape->get_density();
	sd.baseMaterial.friction = (float)p_shape->get_friction();
	sd.baseMaterial.restitution = (float)p_shape->get_restitution();
	sd.baseMaterial.rollingResistance = (float)p_shape->get_rolling_resistance();
	sd.baseMaterial.tangentVelocity = to_b3(p_shape->get_tangent_velocity());
	sd.baseMaterial.userMaterialId = (uint64_t)p_shape->get_user_material_id();
	// Events and the filter are the body's unless this shape overrides them
	// (P-019). EVENT_INHERIT resolves to exactly what the body would have set.
	sd.enableContactEvents = Box3DCollisionShape::resolve_event(p_shape->get_contact_event_mode(), contact_monitor);
	sd.filter = p_shape->has_filter_override() ? p_shape->make_filter() : make_filter();
	sd.isSensor = is_sensor;
	// Shape-def flags that live on the body, as the material and filter do.
	sd.explosionScale = (float)explosion_scale;
	sd.invokeContactCreation = invoke_contact_creation;
	sd.enableSpeculativeContact = speculative_contact;
	// A compound rebuilds every child in one pass, so the mass is recomputed
	// once at the end instead of per shape (types.h:514-516).
	sd.updateBodyMass = false;
	// The two Box3DContactRules opt-ins (P-019's stated omission and P-020's
	// enableCustomFiltering): a rule table only sees a pair when at least one
	// of its shapes asks for it.
	sd.enableCustomFiltering = p_shape->get_custom_filtering();
	sd.enablePreSolveEvents = p_shape->get_pre_solve_events();
	sd.enableSensorEvents = Box3DCollisionShape::resolve_event(p_shape->get_sensor_event_mode(), sensor_events);
	sd.enableHitEvents = Box3DCollisionShape::resolve_event(p_shape->get_hit_event_mode(), hit_events);
	// Shape userData points at the Box3DCollisionShape that authored the shape;
	// it stays null for a body's own shape_type shape. Either way the owning
	// Box3DBody is reachable through b3Shape_GetBody + b3Body_GetUserData.
	sd.userData = p_shape;
	// Copied into the world's name table by the create call, like the body name.
	CharString node_name = String(p_shape->get_name()).utf8();
	sd.name = node_name.get_data();

	b3ShapeId created = b3_nullShapeId;

	// The shape's transform relative to the body. Its origin is in the body's
	// UNSCALED local units, so the body's own scale still has to be applied to
	// the offset (Box3D's body transform carries no scale), and the child
	// node's own scale goes onto the geometry.
	Transform3D local = p_body_inv * p_shape->get_global_transform();
	Vector3 child_scale = local.basis.get_scale();
	if (child_scale.is_equal_approx(Vector3(1, 1, 1))) {
		child_scale = Vector3(1, 1, 1); // exact, so unscaled children build as before
	}
	// Total factor on the child's geometry, and its offset in scaled body space.
	const Vector3 geom_scale = node_scale * child_scale;
	const Vector3 offset = local.origin * node_scale;
	const bool child_scaled = !geom_scale.is_equal_approx(Vector3(1, 1, 1));
	switch (p_shape->get_shape_type()) {
		case Box3DCollisionShape::CYLINDER: {
			// Centered on the child node origin (yOffset -h/2, like the body's
			// own CYLINDER), then placed by the child's local transform.
			float ch_h = (float)p_shape->get_capsule_height();
			b3HullData *hull = b3CreateCylinder(ch_h, (float)p_shape->get_capsule_radius(), -ch_h * 0.5f, p_shape->get_sides());
			if (hull != nullptr) {
				b3Transform xf;
				xf.p = to_b3(offset);
				xf.q = to_b3(local.basis.get_rotation_quaternion());
				created = b3CreateTransformedHullShape(body_id, &sd, hull, xf, to_b3(geom_scale));
				b3DestroyHull(hull);
			}
		} break;
		case Box3DCollisionShape::CONE: {
			// b3CreateCone has no offset; bake the -h/2 centering shift into
			// the placement transform (mirrors the body's own CONE case).
			float ch_h = (float)p_shape->get_capsule_height();
			b3HullData *hull = b3CreateCone(ch_h, (float)p_shape->get_capsule_radius(), 0.0f, p_shape->get_sides());
			if (hull != nullptr) {
				b3Transform xf;
				// local.xform already carries the child's own scale; the body
				// scale turns the result into scaled body space.
				xf.p = to_b3(local.xform(Vector3(0, -ch_h * 0.5f, 0)) * node_scale);
				xf.q = to_b3(local.basis.get_rotation_quaternion());
				created = b3CreateTransformedHullShape(body_id, &sd, hull, xf, to_b3(geom_scale));
				b3DestroyHull(hull);
			}
		} break;
		case Box3DCollisionShape::SPHERE: {
			b3Sphere sphere;
			sphere.center = to_b3(offset);
			sphere.radius = (float)p_shape->get_sphere_radius() * (child_scaled ? max_abs_scale(geom_scale) : 1.0f);
			created = b3CreateSphereShape(body_id, &sd, &sphere);
		} break;
		case Box3DCollisionShape::CAPSULE: {
			float radius = (float)p_shape->get_capsule_radius();
			float half = (float)(p_shape->get_capsule_height() * 0.5) - radius;
			if (half < 0.0f) {
				half = 0.0f;
			}
			if (child_scaled) {
				radius *= (float)MAX(Math::abs(geom_scale.x), Math::abs(geom_scale.z));
			}
			b3Capsule capsule;
			// The caps take the axial scale through local.xform / node_scale.
			capsule.center1 = to_b3(local.xform(Vector3(0, -half, 0)) * node_scale);
			capsule.center2 = to_b3(local.xform(Vector3(0, half, 0)) * node_scale);
			capsule.radius = radius;
			created = b3CreateCapsuleShape(body_id, &sd, &capsule);
		} break;
		case Box3DCollisionShape::BOX:
		default: {
			if (child_scaled) {
				// The child's own scale resizes the box exactly; the body scale
				// is the post-scale b3ScaleBox resolves (collision.h:249-255).
				Vector3 h = p_shape->get_box_size() * 0.5 * child_scale.abs();
				b3BoxHull box = b3MakeScaledBoxHull(to_b3(h), to_b3_transform(local), to_b3(node_scale));
				created = b3CreateHullShape(body_id, &sd, &box.base);
			} else {
				Vector3 h = p_shape->get_box_size() * 0.5;
				b3BoxHull box = b3MakeTransformedBoxHull((float)h.x, (float)h.y, (float)h.z, to_b3_transform(local));
				created = b3CreateHullShape(body_id, &sd, &box.base);
			}
		} break;
	}
	p_shape->on_shape_created(created, this);
}

bool Box3DBody::create_baked_compound(const Transform3D &p_body_inv) {
	// Box3D asserts both of these inside b3CreateShape (src/shape.c:122-127),
	// so they are checked here rather than tripped there.
	if (body_type != STATIC) {
		UtilityFunctions::push_warning("Box3DBody: baked_compound is only allowed on static bodies; building a runtime compound instead.");
		return false;
	}
	if (is_sensor) {
		UtilityFunctions::push_warning("Box3DBody: a baked compound cannot be a sensor; building a runtime compound instead.");
		return false;
	}

	std::vector<Box3DCollisionShape *> children;
	for (int i = 0; i < get_child_count(); ++i) {
		Box3DCollisionShape *cs = Object::cast_to<Box3DCollisionShape>(get_child(i));
		// Same skip as build_shapes: a child on its way out is not baked in.
		if (cs != nullptr && !cs->is_leaving()) {
			children.push_back(cs);
		}
	}
	if (children.empty()) {
		return false;
	}

	std::vector<b3CompoundHullDef> hull_defs;
	std::vector<b3CompoundSphereDef> sphere_defs;
	std::vector<b3CompoundCapsuleDef> capsule_defs;
	// b3CompoundHullDef holds a POINTER, so these two backing stores must not
	// reallocate while the defs are being filled. Reserved to the worst case.
	std::vector<b3BoxHull> box_hulls;
	std::vector<b3HullData *> owned_hulls;
	box_hulls.reserve(children.size());
	owned_hulls.reserve(children.size());
	hull_defs.reserve(children.size());
	sphere_defs.reserve(children.size());
	capsule_defs.reserve(children.size());

	bool warned_override = false;
	for (size_t c = 0; c < children.size(); ++c) {
		Box3DCollisionShape *p_shape = children[c];
		// A baked compound is ONE shape, so it carries one filter and one set of
		// event enables — the body's. Per-shape overrides cannot survive baking.
		if (!warned_override && (p_shape->has_filter_override() ||
										p_shape->get_contact_event_mode() != Box3DCollisionShape::EVENT_INHERIT ||
										p_shape->get_sensor_event_mode() != Box3DCollisionShape::EVENT_INHERIT ||
										p_shape->get_hit_event_mode() != Box3DCollisionShape::EVENT_INHERIT)) {
			UtilityFunctions::push_warning("Box3DBody: a baked compound is a single shape, so per-shape filter and event overrides on its children are ignored.");
			warned_override = true;
		}

		b3SurfaceMaterial material = b3DefaultSurfaceMaterial();
		material.friction = MAX(0.0f, (float)p_shape->get_friction());
		material.restitution = MAX(0.0f, (float)p_shape->get_restitution());
		material.rollingResistance = MAX(0.0f, (float)p_shape->get_rolling_resistance());
		material.tangentVelocity = to_b3(p_shape->get_tangent_velocity());
		material.userMaterialId = (uint64_t)p_shape->get_user_material_id();

		// Same placement math as create_child_shape: the child's own scale goes
		// onto its geometry, the body's scale onto both geometry and offset.
		Transform3D local = p_body_inv * p_shape->get_global_transform();
		Vector3 child_scale = local.basis.get_scale();
		if (child_scale.is_equal_approx(Vector3(1, 1, 1))) {
			child_scale = Vector3(1, 1, 1);
		}
		const Vector3 geom_scale = node_scale * child_scale;
		const Vector3 offset = local.origin * node_scale;
		const bool child_scaled = !geom_scale.is_equal_approx(Vector3(1, 1, 1));

		switch (p_shape->get_shape_type()) {
			case Box3DCollisionShape::SPHERE: {
				b3CompoundSphereDef def = {};
				def.sphere.center = to_b3(offset);
				def.sphere.radius = (float)p_shape->get_sphere_radius() * (child_scaled ? max_abs_scale(geom_scale) : 1.0f);
				def.material = material;
				sphere_defs.push_back(def);
			} break;
			case Box3DCollisionShape::CAPSULE: {
				float radius = (float)p_shape->get_capsule_radius();
				float half = (float)(p_shape->get_capsule_height() * 0.5) - radius;
				if (half < 0.0f) {
					half = 0.0f;
				}
				if (child_scaled) {
					radius *= (float)MAX(Math::abs(geom_scale.x), Math::abs(geom_scale.z));
				}
				b3CompoundCapsuleDef def = {};
				def.capsule.center1 = to_b3(local.xform(Vector3(0, -half, 0)) * node_scale);
				def.capsule.center2 = to_b3(local.xform(Vector3(0, half, 0)) * node_scale);
				def.capsule.radius = radius;
				def.material = material;
				capsule_defs.push_back(def);
			} break;
			case Box3DCollisionShape::CYLINDER:
			case Box3DCollisionShape::CONE: {
				const bool is_cone = p_shape->get_shape_type() == Box3DCollisionShape::CONE;
				float ch_h = (float)p_shape->get_capsule_height();
				b3HullData *hull = is_cone
						? b3CreateCone(ch_h, (float)p_shape->get_capsule_radius(), 0.0f, p_shape->get_sides())
						: b3CreateCylinder(ch_h, (float)p_shape->get_capsule_radius(), -ch_h * 0.5f, p_shape->get_sides());
				if (hull == nullptr) {
					break;
				}
				b3Transform xf;
				xf.p = is_cone
						? to_b3(local.xform(Vector3(0, -ch_h * 0.5f, 0)) * node_scale)
						: to_b3(offset);
				xf.q = to_b3(local.basis.get_rotation_quaternion());
				// b3CompoundHullDef carries a transform but no scale, so the
				// scale is baked into a clone. b3CloneAndTransformHull applies
				// the scale FIRST, like b3CreateTransformedHullShape does
				// (collision.h:231), so the placement stays in the transform.
				b3HullData *placed = b3CloneAndTransformHull(hull, b3Transform_identity, to_b3(geom_scale));
				b3DestroyHull(hull);
				if (placed == nullptr) {
					break;
				}
				owned_hulls.push_back(placed);
				b3CompoundHullDef def = {};
				def.hull = placed;
				def.transform = xf;
				def.material = material;
				hull_defs.push_back(def);
			} break;
			case Box3DCollisionShape::BOX:
			default: {
				box_hulls.push_back(b3BoxHull());
				b3BoxHull &box = box_hulls.back();
				b3Transform placement = b3Transform_identity;
				// b3CreateCompound deduplicates hulls by CONTENT
				// (src/compound.c:358-373), which is most of the point of a
				// baked level: a thousand identical crates should store one
				// hull. So the placement goes in the def's transform and the
				// hull itself stays at the origin, unlike the runtime path
				// which bakes the transform into the points.
				const bool uniform_body_scale =
						Math::is_equal_approx(node_scale.x, node_scale.y) &&
						Math::is_equal_approx(node_scale.y, node_scale.z);
				if (uniform_body_scale) {
					Vector3 h = p_shape->get_box_size() * 0.5 * geom_scale.abs();
					box = b3MakeBoxHull((float)h.x, (float)h.y, (float)h.z);
					placement.p = to_b3(offset);
					placement.q = to_b3(local.basis.get_rotation_quaternion());
				} else {
					// Non-uniform body scale under a rotated child is the shear
					// case b3ScaleBox resolves approximately (collision.h:249-255,
					// src/hull.c:2888-2946). Correctness wins over dedup here:
					// this takes the runtime path's exact math, which bakes the
					// placement in and therefore cannot be shared.
					Vector3 h = p_shape->get_box_size() * 0.5 * child_scale.abs();
					box = b3MakeScaledBoxHull(to_b3(h), to_b3_transform(local), to_b3(node_scale));
				}
				b3CompoundHullDef def = {};
				def.hull = &box.base;
				def.transform = placement;
				def.material = material;
				hull_defs.push_back(def);
			} break;
		}
	}

	bool created = false;
	if (!hull_defs.empty() || !sphere_defs.empty() || !capsule_defs.empty()) {
		b3CompoundDef def = {};
		def.hulls = hull_defs.empty() ? nullptr : hull_defs.data();
		def.hullCount = (int)hull_defs.size();
		def.spheres = sphere_defs.empty() ? nullptr : sphere_defs.data();
		def.sphereCount = (int)sphere_defs.size();
		def.capsules = capsule_defs.empty() ? nullptr : capsule_defs.data();
		def.capsuleCount = (int)capsule_defs.size();
		// No meshes: a Box3DCollisionShape cannot author one, and a mesh inside
		// a compound is capped at B3_MAX_COMPOUND_MESH_MATERIALS (4) materials
		// (types.h:2428-2430).
		compound_data = b3CreateCompound(&def);
		if (compound_data != nullptr) {
			b3ShapeDef sd = b3DefaultShapeDef();
			sd.density = (float)density;
			sd.enableContactEvents = contact_monitor;
			sd.filter = make_filter();
			sd.isSensor = false;
			sd.explosionScale = (float)explosion_scale;
			sd.invokeContactCreation = invoke_contact_creation;
			sd.enableSpeculativeContact = speculative_contact;
			sd.enableSensorEvents = sensor_events;
			sd.enableHitEvents = hit_events;
			// No userData: the compound is one shape with many authors, so it
			// cannot point back at a single Box3DCollisionShape. The owning
			// Box3DBody is still reachable through b3Shape_GetBody.
			CharString node_name = String(get_name()).utf8();
			sd.name = node_name.get_data();
			// Box3D keeps the pointer (src/shape.c:126), so compound_data is
			// released only in destroy_body().
			b3CreateBakedCompoundShape(body_id, &sd, compound_data);
			created = true;
		} else {
			UtilityFunctions::push_warning("Box3DBody: b3CreateCompound failed; building a runtime compound instead.");
		}
	}

	// The hulls were copied into the compound blob, so the originals go now.
	for (size_t i = 0; i < owned_hulls.size(); ++i) {
		b3DestroyHull(owned_hulls[i]);
	}
	if (!created && compound_data != nullptr) {
		b3DestroyCompound(compound_data);
		compound_data = nullptr;
	}
	if (created) {
		// A baked compound is a single shape with no per-child handle: handing
		// every child the compound's id would let a child's set_friction() reach
		// b3Shape_SetSurfaceMaterial, which asserts on a compound
		// (src/shape.c:1258-1269). The children keep a null id, so their live
		// mutators are inert and the authored values (already baked in) stand.
		for (size_t i = 0; i < children.size(); ++i) {
			children[i]->on_shape_destroyed();
		}
	}
	return created;
}

bool Box3DBody::resize_child_shape(Box3DCollisionShape *p_shape) {
	// A baked compound is one immutable shape; its children hold no handle.
	if (compound_data != nullptr || p_shape == nullptr || !body_live()) {
		return false;
	}
	const b3ShapeId id = p_shape->get_shape_id();
	if (!b3Shape_IsValid(id)) {
		return false;
	}
	// Mirrors create_child_shape: the child's own scale goes onto its geometry,
	// the body's scale onto both the geometry and the offset.
	Transform3D body_inv = get_global_transform().affine_inverse();
	Transform3D local = body_inv * p_shape->get_global_transform();
	Vector3 child_scale = local.basis.get_scale();
	if (child_scale.is_equal_approx(Vector3(1, 1, 1))) {
		child_scale = Vector3(1, 1, 1);
	}
	const Vector3 geom_scale = node_scale * child_scale;
	const Vector3 offset = local.origin * node_scale;
	const bool child_scaled = !geom_scale.is_equal_approx(Vector3(1, 1, 1));

	b3HullData *owned = nullptr;
	switch (p_shape->get_shape_type()) {
		case Box3DCollisionShape::SPHERE: {
			b3Sphere sphere;
			sphere.center = to_b3(offset);
			sphere.radius = (float)p_shape->get_sphere_radius() * (child_scaled ? max_abs_scale(geom_scale) : 1.0f);
			b3Shape_SetSphere(id, &sphere);
		} break;
		case Box3DCollisionShape::CAPSULE: {
			float radius = (float)p_shape->get_capsule_radius();
			float half = (float)(p_shape->get_capsule_height() * 0.5) - radius;
			if (half < 0.0f) {
				half = 0.0f;
			}
			if (child_scaled) {
				radius *= (float)MAX(Math::abs(geom_scale.x), Math::abs(geom_scale.z));
			}
			b3Capsule capsule;
			capsule.center1 = to_b3(local.xform(Vector3(0, -half, 0)) * node_scale);
			capsule.center2 = to_b3(local.xform(Vector3(0, half, 0)) * node_scale);
			capsule.radius = radius;
			b3Shape_SetCapsule(id, &capsule);
		} break;
		case Box3DCollisionShape::CYLINDER:
		case Box3DCollisionShape::CONE: {
			const bool is_cone = p_shape->get_shape_type() == Box3DCollisionShape::CONE;
			float ch_h = (float)p_shape->get_capsule_height();
			b3HullData *hull = is_cone
					? b3CreateCone(ch_h, (float)p_shape->get_capsule_radius(), 0.0f, p_shape->get_sides())
					: b3CreateCylinder(ch_h, (float)p_shape->get_capsule_radius(), -ch_h * 0.5f, p_shape->get_sides());
			if (hull == nullptr) {
				return false;
			}
			b3Transform xf;
			xf.p = is_cone
					? to_b3(local.xform(Vector3(0, -ch_h * 0.5f, 0)) * node_scale)
					: to_b3(offset);
			xf.q = to_b3(local.basis.get_rotation_quaternion());
			// b3Shape_SetHull takes no transform or scale, so both are baked in
			// first. b3CloneAndTransformHull applies the scale first, exactly as
			// b3CreateTransformedHullShape does at creation (collision.h:231).
			owned = b3CloneAndTransformHull(hull, xf, to_b3(geom_scale));
			b3DestroyHull(hull);
			if (owned == nullptr) {
				return false;
			}
			b3Shape_SetHull(id, owned);
		} break;
		case Box3DCollisionShape::BOX:
		default: {
			if (child_scaled) {
				Vector3 h = p_shape->get_box_size() * 0.5 * child_scale.abs();
				b3BoxHull box = b3MakeScaledBoxHull(to_b3(h), to_b3_transform(local), to_b3(node_scale));
				b3Shape_SetHull(id, &box.base);
			} else {
				Vector3 h = p_shape->get_box_size() * 0.5;
				b3BoxHull box = b3MakeTransformedBoxHull((float)h.x, (float)h.y, (float)h.z, to_b3_transform(local));
				b3Shape_SetHull(id, &box.base);
			}
		} break;
	}
	if (owned != nullptr) {
		b3DestroyHull(owned);
	}
	// The Set* family leaves mass alone by design (box3d.h:959-980).
	b3Body_ApplyMassFromShapes(body_id);
	debug_mass = b3Body_GetMass(body_id);
	debug_min_ext = debug_min_extent();
	debug_max_ext = debug_max_extent();
	return true;
}

void Box3DBody::request_rebuild() {
	recreate_shapes();
}

void Box3DBody::join_world_step() const {
	if (world != nullptr) {
		world->join_async_step();
	}
}

void Box3DBody::destroy_body() {
	if (world != nullptr) {
		world->unregister_body(this);
	}
	if (body_live()) {
		b3DestroyBody(body_id);
	}
	body_id = b3_nullBodyId;
	// Destroying the body destroyed its shapes, so no child may keep an id.
	for (int i = 0; i < get_child_count(); ++i) {
		Box3DCollisionShape *cs = Object::cast_to<Box3DCollisionShape>(get_child(i));
		if (cs != nullptr) {
			cs->on_shape_destroyed();
		}
	}
	// The shape (and its mesh reference) is gone now, so the mesh data is free
	// to release.
	if (mesh_data != nullptr) {
		b3DestroyMesh(mesh_data);
		mesh_data = nullptr;
	}
	if (height_field_data != nullptr) {
		b3DestroyHeightField(height_field_data);
		height_field_data = nullptr;
	}
	if (compound_data != nullptr) {
		b3DestroyCompound(compound_data);
		compound_data = nullptr;
	}
}

// Every shape goes and is built again from the current properties, on the SAME
// b3 body. See the header for what that keeps and what it costs.
bool Box3DBody::recreate_shapes() {
	// Before the live-body bail-out: in the editor there is never a live body,
	// and this is the funnel every geometry setter reaches, so it is the one
	// place the gizmo has to hear about a change.
	refresh_gizmos();
	if (!body_live()) {
		return false;
	}
	// updateBodyMass false on the way out: the shapes that replace these are
	// about to recompute it, and a body with no shapes has none to compute
	// (types.h:514-516).
	std::vector<b3ShapeId> ids = own_shape_ids();
	for (size_t i = 0; i < ids.size(); ++i) {
		b3DestroyShape(ids[i], false);
	}
	// No child may hold an id into a shape that no longer exists.
	for (int i = 0; i < get_child_count(); ++i) {
		Box3DCollisionShape *cs = Object::cast_to<Box3DCollisionShape>(get_child(i));
		if (cs != nullptr) {
			cs->on_shape_destroyed();
		}
	}
	// The shapes that referenced these blobs are gone, so the blobs can go too;
	// build_shapes() allocates whatever the current properties call for.
	if (mesh_data != nullptr) {
		b3DestroyMesh(mesh_data);
		mesh_data = nullptr;
	}
	if (height_field_data != nullptr) {
		b3DestroyHeightField(height_field_data);
		height_field_data = nullptr;
	}
	if (compound_data != nullptr) {
		b3DestroyCompound(compound_data);
		compound_data = nullptr;
	}
	// The node scale is baked into the geometry (P-024), and the geometry is
	// being built again, so re-read it exactly as create_in_world() does. The
	// body's POSE is deliberately not re-read: the body is not being recreated.
	node_scale = get_global_transform().basis.get_scale();
	node_scaled = !node_scale.is_equal_approx(Vector3(1, 1, 1));
	if (!node_scaled) {
		node_scale = Vector3(1, 1, 1);
	}
	build_shapes();
	return true;
}

void Box3DBody::apply_motion_locks() {
	if (!body_live()) {
		return;
	}
	b3MotionLocks locks;
	locks.linearX = lock_linear_x;
	locks.linearY = lock_linear_y;
	locks.linearZ = lock_linear_z;
	locks.angularX = lock_angular_x;
	locks.angularY = lock_angular_y;
	locks.angularZ = lock_angular_z;
	b3Body_SetMotionLocks(body_id, locks);
}

void Box3DBody::sync_to_physics(double p_delta) {
	if (!body_live() || body_type != KINEMATIC) {
		return;
	}
	Transform3D xform = get_global_transform();
	b3WorldTransform target;
	target.p = to_b3_pos(xform.origin);
	target.q = to_b3(xform.basis.get_rotation_quaternion());
	// Solves for the velocity that reaches the target over one step, so the
	// kinematic body pushes dynamic bodies correctly instead of teleporting.
	b3Body_SetTargetTransform(body_id, target, (float)p_delta, true);
}

void Box3DBody::sync_from_physics() {
	if (body_type != DYNAMIC || !body_live()) {
		return;
	}
	// Sleeping bodies don't move, so skip the node update once their final
	// transform has been written — big scenes idle for free this way.
	if (b3Body_IsAwake(body_id)) {
		asleep_synced = false;
		snap_awake = true;
	} else {
		snap_awake = false;
		if (asleep_synced) {
			return;
		}
		asleep_synced = true;
	}
	b3WorldTransform t = b3Body_GetTransform(body_id);
	snap_prev = snap_curr;
	snap_curr = t;
	if (sync_node_transform) {
		// The solver reports position and rotation only, so a scaled node gets
		// its scale written back (it is baked into the collider, not simulated).
		Basis basis(to_gd(t.q));
		if (node_scaled) {
			basis = basis.scaled_local(node_scale);
		}
		set_global_transform(Transform3D(basis, to_gd_pos(t.p)));
	}
}

void Box3DBody::sync_from_move_event(const b3WorldTransform &p_transform, bool p_fell_asleep) {
	if (body_type != DYNAMIC) {
		return;
	}
	// A move event means the body was awake this step; fellAsleep is the
	// transition, and it is the last event this body produces until it wakes.
	// b3BodyMoveEvent.transform is the post-CCD pose (src/solver.c:570-572
	// rewrites it after the sweep), i.e. exactly what b3Body_GetTransform
	// would return — so this needs neither of the two b3 calls
	// sync_from_physics makes per awake body.
	snap_awake = !p_fell_asleep;
	asleep_synced = p_fell_asleep;
	snap_prev = snap_curr;
	snap_curr = p_transform;
	if (sync_node_transform) {
		// The solver reports position and rotation only, so a scaled node gets
		// its scale written back (it is baked into the collider, not simulated).
		Basis basis(to_gd(p_transform.q));
		if (node_scaled) {
			basis = basis.scaled_local(node_scale);
		}
		set_global_transform(Transform3D(basis, to_gd_pos(p_transform.p)));
	}
}

bool Box3DBody::is_awake_now() const {
	return body_live() && b3Body_IsAwake(body_id);
}

bool Box3DBody::is_enabled_now() const {
	return body_live() && b3Body_IsEnabled(body_id);
}

void Box3DBody::_notification(int p_what) {
	switch (p_what) {
		case NOTIFICATION_READY: {
			if (!Engine::get_singleton()->is_editor_hint()) {
				create_in_world();
			}
		} break;
		case NOTIFICATION_EXIT_TREE: {
			destroy_body();
			world = nullptr;
		} break;
	}
}

void Box3DBody::emit_contact_begin(Box3DBody *p_other) {
	emit_signal("body_entered", p_other);
}

void Box3DBody::emit_contact_end(Box3DBody *p_other) {
	emit_signal("body_exited", p_other);
}

void Box3DBody::emit_area_begin(Box3DBody *p_visitor) {
	emit_signal("area_entered", p_visitor);
}

void Box3DBody::emit_area_end(Box3DBody *p_visitor) {
	emit_signal("area_exited", p_visitor);
}

// --- Scripting API ---

void Box3DBody::apply_central_force(const Vector3 &p_force) {
	if (body_live()) {
		b3Body_ApplyForceToCenter(body_id, to_b3(p_force), true);
	}
}

void Box3DBody::apply_central_impulse(const Vector3 &p_impulse) {
	if (body_live()) {
		b3Body_ApplyLinearImpulseToCenter(body_id, to_b3(p_impulse), true);
	}
}

void Box3DBody::apply_torque(const Vector3 &p_torque) {
	if (body_live()) {
		b3Body_ApplyTorque(body_id, to_b3(p_torque), true);
	}
}

void Box3DBody::apply_force_at_point(const Vector3 &p_force, const Vector3 &p_point) {
	if (body_live()) {
		b3Body_ApplyForce(body_id, to_b3(p_force), to_b3_pos(p_point), true);
	}
}

void Box3DBody::apply_impulse_at_point(const Vector3 &p_impulse, const Vector3 &p_point) {
	if (body_live()) {
		b3Body_ApplyLinearImpulse(body_id, to_b3(p_impulse), to_b3_pos(p_point), true);
	}
}

void Box3DBody::apply_angular_impulse(const Vector3 &p_impulse) {
	if (body_live()) {
		b3Body_ApplyAngularImpulse(body_id, to_b3(p_impulse), true);
	}
}

Vector3 Box3DBody::get_world_point(const Vector3 &p_local_point) const {
	if (body_live()) {
		return to_gd_pos(b3Body_GetWorldPoint(body_id, to_b3(p_local_point)));
	}
	return Vector3();
}

Vector3 Box3DBody::get_local_point(const Vector3 &p_world_point) const {
	if (body_live()) {
		return to_gd(b3Body_GetLocalPoint(body_id, to_b3_pos(p_world_point)));
	}
	return Vector3();
}

Vector3 Box3DBody::get_world_vector(const Vector3 &p_local_vector) const {
	if (body_live()) {
		return to_gd(b3Body_GetWorldVector(body_id, to_b3(p_local_vector)));
	}
	return Vector3();
}

Vector3 Box3DBody::get_local_vector(const Vector3 &p_world_vector) const {
	if (body_live()) {
		return to_gd(b3Body_GetLocalVector(body_id, to_b3(p_world_vector)));
	}
	return Vector3();
}

Vector3 Box3DBody::get_point_velocity(const Vector3 &p_world_point) const {
	if (body_live()) {
		return to_gd(b3Body_GetWorldPointVelocity(body_id, to_b3_pos(p_world_point)));
	}
	return Vector3();
}

Vector3 Box3DBody::get_local_point_velocity(const Vector3 &p_local_point) const {
	if (body_live()) {
		return to_gd(b3Body_GetLocalPointVelocity(body_id, to_b3(p_local_point)));
	}
	return Vector3();
}

void Box3DBody::set_awake(bool p_awake) {
	if (body_live()) {
		b3Body_SetAwake(body_id, p_awake);
		// A body woken by script must have its node transform tracked again.
		asleep_synced = false;
		// And one put to sleep BETWEEN steps produces no further move event, so
		// nothing else would ever clear the cached awake flag and the debug
		// shells would keep painting it awake. sync_from_physics masks this by
		// polling; sync_from_move_event cannot.
		snap_awake = p_awake;
	}
}

void Box3DBody::set_linear_velocity(const Vector3 &p_velocity) {
	if (body_live()) {
		b3Body_SetLinearVelocity(body_id, to_b3(p_velocity));
	}
}

Vector3 Box3DBody::get_linear_velocity() const {
	if (body_live()) {
		return to_gd(b3Body_GetLinearVelocity(body_id));
	}
	return Vector3();
}

void Box3DBody::set_angular_velocity(const Vector3 &p_velocity) {
	if (body_live()) {
		b3Body_SetAngularVelocity(body_id, to_b3(p_velocity));
	}
}

Vector3 Box3DBody::get_angular_velocity() const {
	if (body_live()) {
		return to_gd(b3Body_GetAngularVelocity(body_id));
	}
	return Vector3();
}

double Box3DBody::get_mass() const {
	if (body_live()) {
		return b3Body_GetMass(body_id);
	}
	return 0.0;
}

double Box3DBody::get_inverse_mass() const {
	if (body_live()) {
		return b3Body_GetInverseMass(body_id);
	}
	return 0.0;
}

Vector3 Box3DBody::get_center_of_mass() const {
	if (body_live()) {
		return to_gd_pos(b3Body_GetWorldCenter(body_id));
	}
	return get_global_position();
}

Vector3 Box3DBody::get_local_center_of_mass() const {
	if (body_live()) {
		return to_gd(b3Body_GetLocalCenter(body_id));
	}
	return Vector3();
}

Basis Box3DBody::get_inertia_tensor() const {
	if (body_live()) {
		return to_gd_basis(b3Body_GetLocalRotationalInertia(body_id));
	}
	return Basis();
}

Basis Box3DBody::get_inverse_inertia_tensor() const {
	if (body_live()) {
		return to_gd_basis(b3Body_GetWorldInverseRotationalInertia(body_id));
	}
	return Basis();
}

void Box3DBody::set_mass_data(double p_mass, const Vector3 &p_local_center, const Basis &p_inertia) {
	if (!body_live()) {
		return;
	}
	b3MassData data;
	data.mass = (float)p_mass;
	data.center = to_b3(p_local_center);
	data.inertia = to_b3_matrix3(p_inertia);
	b3Body_SetMassData(body_id, data);
	debug_mass = b3Body_GetMass(body_id);
}

Dictionary Box3DBody::get_mass_data() const {
	Dictionary out;
	b3MassData data = {};
	if (body_live()) {
		data = b3Body_GetMassData(body_id);
	}
	out["mass"] = (double)data.mass;
	out["center"] = to_gd(data.center);
	out["inertia"] = to_gd_basis(data.inertia);
	return out;
}

void Box3DBody::apply_mass_from_shapes() {
	if (body_live()) {
		b3Body_ApplyMassFromShapes(body_id);
		debug_mass = b3Body_GetMass(body_id);
	}
}

AABB Box3DBody::get_aabb() const {
	if (body_live()) {
		b3AABB box = b3Body_ComputeAABB(body_id);
		Vector3 lower = to_gd(box.lowerBound);
		return AABB(lower, to_gd(box.upperBound) - lower);
	}
	return AABB();
}

Vector3 Box3DBody::get_closest_point(const Vector3 &p_target) const {
	if (body_live()) {
		b3Vec3 result = b3Vec3_zero;
		b3Body_GetClosestPoint(body_id, &result, to_b3(p_target));
		return to_gd(result);
	}
	return Vector3();
}

double Box3DBody::get_closest_distance(const Vector3 &p_target) const {
	if (body_live()) {
		b3Vec3 result = b3Vec3_zero;
		return b3Body_GetClosestPoint(body_id, &result, to_b3(p_target));
	}
	return 0.0;
}

namespace {

// The pose a per-body query tests against: the caller's hypothetical transform,
// or the body's real one when they pass identity.
b3WorldTransform query_pose(b3BodyId p_body, const Transform3D &p_xform) {
	if (p_xform == Transform3D()) {
		return b3Body_GetTransform(p_body);
	}
	b3WorldTransform t;
	t.p = to_b3_pos(p_xform.origin);
	t.q = to_b3(p_xform.basis.get_rotation_quaternion());
	return t;
}

// Eight corners of an axis-aligned box of FULL size p_size, expressed relative
// to p_origin — the proxy points are origin-relative, which is what keeps the
// query precise far from the world origin (box3d.h:78-80).
void box_proxy_points(const Vector3 &p_center, const Vector3 &p_size, const Vector3 &p_origin, b3Vec3 r_points[8]) {
	const Vector3 h = p_size * 0.5;
	const Vector3 c = p_center - p_origin;
	int n = 0;
	for (int i = 0; i < 8; ++i) {
		r_points[n++] = to_b3(c + Vector3(
										 (i & 1) ? h.x : -h.x,
										 (i & 2) ? h.y : -h.y,
										 (i & 4) ? h.z : -h.z));
	}
}

// b3BodyCastResult -> Dictionary, shared by cast_ray and cast_box.
Dictionary cast_result_to_dict(const b3BodyCastResult &r) {
	Dictionary out;
	out["hit"] = r.hit;
	if (!r.hit) {
		return out;
	}
	out["position"] = to_gd_pos(r.point);
	out["normal"] = to_gd(r.normal);
	out["fraction"] = (double)r.fraction;
	out["shape"] = (Box3DCollisionShape *)b3Shape_GetUserData(r.shapeId);
	out["triangle_index"] = r.triangleIndex;
	out["user_material"] = (int64_t)r.userMaterialId;
	out["iterations"] = r.iterations;
	return out;
}

} // namespace

Dictionary Box3DBody::cast_ray(const Vector3 &p_from, const Vector3 &p_to, const Transform3D &p_body_xform,
		uint64_t p_mask, uint64_t p_layer) const {
	Dictionary out;
	if (!body_live()) {
		out["hit"] = false;
		return out;
	}
	// Two-way filtering: maskBits is what the query looks for, categoryBits is
	// what it is (src/shape.h:151-155).
	b3QueryFilter filter = b3DefaultQueryFilter();
	filter.maskBits = p_mask;
	filter.categoryBits = p_layer;
	b3BodyCastResult r = b3Body_CastRay(body_id, to_b3_pos(p_from), to_b3(p_to - p_from), filter,
			1.0f, query_pose(body_id, p_body_xform));
	return cast_result_to_dict(r);
}

Dictionary Box3DBody::cast_box(const Vector3 &p_from, const Vector3 &p_to, const Vector3 &p_size, const Transform3D &p_body_xform,
		uint64_t p_mask, uint64_t p_layer) const {
	Dictionary out;
	if (!body_live()) {
		out["hit"] = false;
		return out;
	}
	b3Vec3 points[8];
	box_proxy_points(p_from, p_size, p_from, points);
	b3ShapeProxy proxy;
	proxy.points = points;
	proxy.count = 8;
	proxy.radius = 0.0f;
	b3QueryFilter filter = b3DefaultQueryFilter();
	filter.maskBits = p_mask;
	filter.categoryBits = p_layer;
	// canEncroach false: a cast that starts already overlapping reports a zero
	// fraction rather than sweeping out of the overlap, which is the answer a
	// "can I move there" test wants.
	b3BodyCastResult r = b3Body_CastShape(body_id, to_b3_pos(p_from), &proxy, to_b3(p_to - p_from),
			filter, 1.0f, false, query_pose(body_id, p_body_xform));
	return cast_result_to_dict(r);
}

bool Box3DBody::overlaps_box(const Vector3 &p_center, const Vector3 &p_size, const Transform3D &p_body_xform,
		uint64_t p_mask, uint64_t p_layer) const {
	if (!body_live()) {
		return false;
	}
	b3Vec3 points[8];
	box_proxy_points(p_center, p_size, p_center, points);
	b3ShapeProxy proxy;
	proxy.points = points;
	proxy.count = 8;
	proxy.radius = 0.0f;
	b3QueryFilter filter = b3DefaultQueryFilter();
	filter.maskBits = p_mask;
	filter.categoryBits = p_layer;
	return b3Body_OverlapShape(body_id, to_b3_pos(p_center), &proxy, filter, query_pose(body_id, p_body_xform));
}

int Box3DBody::get_shape_count() const {
	if (body_live()) {
		return b3Body_GetShapeCount(body_id);
	}
	return 0;
}

int Box3DBody::get_joint_count() const {
	if (body_live()) {
		return b3Body_GetJointCount(body_id);
	}
	return 0;
}

Array Box3DBody::get_shape_nodes() const {
	Array out;
	std::vector<b3ShapeId> ids = own_shape_ids();
	for (size_t i = 0; i < ids.size(); ++i) {
		// Null for a body's own shape_type shape and for a baked compound:
		// neither has a single authoring node to hand back.
		Box3DCollisionShape *node = shape_node_of(ids[i]);
		if (node != nullptr) {
			out.push_back(node);
		}
	}
	return out;
}

PackedStringArray Box3DBody::get_shape_names() const {
	PackedStringArray out;
	std::vector<b3ShapeId> ids = own_shape_ids();
	for (size_t i = 0; i < ids.size(); ++i) {
		// Upstream returns an empty string rather than null for an unnamed
		// shape (box3d.h:856-860).
		out.push_back(String::utf8(b3Shape_GetName(ids[i])));
	}
	return out;
}

Array Box3DBody::get_joints() const {
	Array out;
	if (!body_live()) {
		return out;
	}
	int capacity = b3Body_GetJointCount(body_id);
	if (capacity <= 0) {
		return out;
	}
	std::vector<b3JointId> ids((size_t)capacity);
	// The fill call returns the valid count, which may be lower than capacity
	// (box3d.h:745-750).
	int count = b3Body_GetJoints(body_id, ids.data(), capacity);
	for (int i = 0; i < count; ++i) {
		if (!b3Joint_IsValid(ids[(size_t)i])) {
			continue;
		}
		// Set by Box3DJoint at creation, the same route the world's joint
		// events take back to a node.
		Box3DJoint *node = (Box3DJoint *)b3Joint_GetUserData(ids[(size_t)i]);
		if (node != nullptr) {
			out.push_back(node);
		}
	}
	return out;
}

Box3DWorld *Box3DBody::get_world() const {
	if (!body_live()) {
		return nullptr;
	}
	// Asking Box3D rather than trusting the cached pointer: if the two ever
	// disagreed, the cached one would be the wrong answer.
	// B3_ID_EQUALS is documented as not working for a b3WorldId (id.h:104);
	// b3StoreWorldId packs index and generation into the comparable uint32_t
	// upstream provides for exactly this (id.h:108-112).
	const uint32_t owner_world = b3StoreWorldId(b3Body_GetWorld(body_id));
	if (world == nullptr || owner_world != b3StoreWorldId(world->get_world_id())) {
		return nullptr;
	}
	return world;
}

// One entry per touching contact:
//   collider        the other Box3DBody
//   shape           this body's Box3DCollisionShape, or null for its own shape
//   collider_shape  the other body's Box3DCollisionShape, or null
//   normal          unit normal pointing from this body towards the collider
//   impulse         summed totalNormalImpulse over every manifold point
//   points          [{ position, separation, impulse, velocity }] in world space
Array Box3DBody::get_contacts() const {
	Array out;
	if (!body_live()) {
		return out;
	}
	int capacity = b3Body_GetContactCapacity(body_id);
	if (capacity <= 0) {
		return out;
	}
	std::vector<b3ContactData> contacts((size_t)capacity);
	// The fill call returns the touching count, which is what must be iterated.
	int count = b3Body_GetContactData(body_id, contacts.data(), capacity);
	for (int i = 0; i < count; ++i) {
		const b3ContactData &c = contacts[(size_t)i];
		b3BodyId owner_a = b3Shape_GetBody(c.shapeIdA);
		bool self_is_a = B3_ID_EQUALS(owner_a, body_id);
		b3ShapeId own_shape = self_is_a ? c.shapeIdA : c.shapeIdB;
		b3ShapeId other_shape = self_is_a ? c.shapeIdB : c.shapeIdA;

		Dictionary entry;
		entry["collider"] = (Box3DBody *)b3Body_GetUserData(b3Shape_GetBody(other_shape));
		entry["shape"] = (Box3DCollisionShape *)b3Shape_GetUserData(own_shape);
		entry["collider_shape"] = (Box3DCollisionShape *)b3Shape_GetUserData(other_shape);

		// Anchors are relative to each body's center of mass, and the manifold
		// normal points from shape A to shape B.
		Vector3 center_a = to_gd_pos(b3Body_GetWorldCenter(owner_a));
		Vector3 center_b = to_gd_pos(b3Body_GetWorldCenter(b3Shape_GetBody(c.shapeIdB)));
		Vector3 normal;
		double impulse = 0.0;
		Array points;
		for (int m = 0; m < c.manifoldCount; ++m) {
			const b3Manifold &manifold = c.manifolds[m];
			normal = to_gd(manifold.normal);
			for (int p = 0; p < manifold.pointCount; ++p) {
				const b3ManifoldPoint &mp = manifold.points[p];
				Dictionary point;
				point["position"] = self_is_a ? center_a + to_gd(mp.anchorA) : center_b + to_gd(mp.anchorB);
				point["separation"] = (double)mp.separation;
				// Box3D is speculative, so a point can be separated and idle;
				// the total impulse is what says whether it interacted.
				point["impulse"] = (double)mp.totalNormalImpulse;
				point["velocity"] = (double)mp.normalVelocity;
				impulse += mp.totalNormalImpulse;
				points.push_back(point);
			}
		}
		entry["normal"] = self_is_a ? normal : -normal;
		entry["impulse"] = impulse;
		entry["points"] = points;
		out.push_back(entry);
	}
	return out;
}

Array Box3DBody::get_touching_bodies() const {
	Array out;
	Array contacts = get_contacts();
	for (int i = 0; i < contacts.size(); ++i) {
		Variant collider = ((Dictionary)contacts[i])["collider"];
		if (collider.get_type() == Variant::OBJECT && !out.has(collider)) {
			out.push_back(collider);
		}
	}
	return out;
}

Array Box3DBody::get_overlapping_bodies() const {
	Array out;
	std::vector<b3ShapeId> ids = own_shape_ids();
	for (size_t i = 0; i < ids.size(); ++i) {
		int capacity = b3Shape_GetSensorCapacity(ids[i]);
		if (capacity <= 0) {
			continue;
		}
		std::vector<b3ShapeId> visitors((size_t)capacity);
		int count = b3Shape_GetSensorData(ids[i], visitors.data(), capacity);
		for (int v = 0; v < count; ++v) {
			// Overlaps may name shapes destroyed since the last step.
			if (!b3Shape_IsValid(visitors[(size_t)v])) {
				continue;
			}
			Box3DBody *other = (Box3DBody *)b3Body_GetUserData(b3Shape_GetBody(visitors[(size_t)v]));
			if (other != nullptr && !out.has(other)) {
				out.push_back(other);
			}
		}
	}
	return out;
}

void Box3DBody::apply_wind(const Vector3 &p_wind, double p_drag, double p_lift, double p_max_speed) {
	std::vector<b3ShapeId> ids = own_shape_ids();
	for (size_t i = 0; i < ids.size(); ++i) {
		b3Shape_ApplyWind(ids[i], to_b3(p_wind), (float)p_drag, (float)p_lift, (float)p_max_speed, true);
	}
}

void Box3DBody::set_body_name(const String &p_name) {
	if (body_live()) {
		CharString utf8 = p_name.utf8();
		b3Body_SetName(body_id, utf8.get_data());
	}
}

String Box3DBody::get_body_name() const {
	if (body_live()) {
		return String::utf8(b3Body_GetName(body_id));
	}
	return String();
}

void Box3DBody::teleport(const Transform3D &p_xform) {
	// Reposition the body instantly (respawn / reset), clearing momentum so it
	// starts at rest. Unlike a kinematic move this doesn't sweep through the
	// world, so don't teleport into overlapping geometry.
	set_global_transform(p_xform);
	// With physics interpolation on, an instant jump must not be smeared
	// across the render frame.
	reset_physics_interpolation();
	if (body_live()) {
		// The render snapshots must jump too, not smear the teleport.
		snap_curr.p = to_b3_pos(p_xform.origin);
		snap_curr.q = to_b3(p_xform.basis.get_rotation_quaternion());
		snap_prev = snap_curr;
		b3Body_SetTransform(body_id, to_b3_pos(p_xform.origin),
				to_b3(p_xform.basis.get_rotation_quaternion()));
		b3Body_SetLinearVelocity(body_id, to_b3(Vector3()));
		b3Body_SetAngularVelocity(body_id, to_b3(Vector3()));
		b3Body_SetAwake(body_id, true);
	}
}

// --- Properties ---

void Box3DBody::set_body_type(int p_type) {
	body_type = (BodyType)p_type;
	// The outline colour is upstream's body-state colour, so the type is part
	// of what the gizmo draws.
	refresh_gizmos();
	if (body_live()) {
		// Upstream switches the type in place (expensive, but it keeps the
		// shapes, joints and velocity a rebuild would throw away) and updates
		// the mass properties itself.
		b3Body_SetType(body_id, (b3BodyType)body_type);
		debug_mass = b3Body_GetMass(body_id);
		asleep_synced = false;
	}
}

int Box3DBody::get_body_type() const {
	return (int)body_type;
}

void Box3DBody::set_shape_type(int p_type) {
	shape_type = (ShapeType)p_type;
	recreate_shapes();
}

int Box3DBody::get_shape_type() const {
	return (int)shape_type;
}

void Box3DBody::set_box_size(const Vector3 &p_size) {
	box_size = p_size;
	resize_or_rebuild();
}

Vector3 Box3DBody::get_box_size() const {
	return box_size;
}

void Box3DBody::set_sphere_radius(double p_radius) {
	sphere_radius = p_radius;
	resize_or_rebuild();
}

double Box3DBody::get_sphere_radius() const {
	return sphere_radius;
}

void Box3DBody::set_capsule_radius(double p_radius) {
	capsule_radius = p_radius;
	resize_or_rebuild();
}

double Box3DBody::get_capsule_radius() const {
	return capsule_radius;
}

void Box3DBody::set_capsule_height(double p_height) {
	capsule_height = p_height;
	resize_or_rebuild();
}

double Box3DBody::get_capsule_height() const {
	return capsule_height;
}

void Box3DBody::set_cylinder_sides(int p_sides) {
	cylinder_sides = p_sides < 3 ? 3 : p_sides;
	resize_or_rebuild();
}

int Box3DBody::get_cylinder_sides() const {
	return cylinder_sides;
}

void Box3DBody::set_collision_mesh(const Ref<Mesh> &p_mesh) {
	collision_mesh = p_mesh;
	recreate_shapes();
}

Ref<Mesh> Box3DBody::get_collision_mesh() const {
	return collision_mesh;
}

void Box3DBody::set_mesh_vertices(const PackedVector3Array &p_vertices) {
	mesh_vertices = p_vertices;
	recreate_shapes();
}

PackedVector3Array Box3DBody::get_mesh_vertices() const {
	return mesh_vertices;
}

void Box3DBody::set_mesh_indices(const PackedInt32Array &p_indices) {
	mesh_indices = p_indices;
	recreate_shapes();
}

PackedInt32Array Box3DBody::get_mesh_indices() const {
	return mesh_indices;
}

void Box3DBody::set_mesh_materials(const PackedByteArray &p_materials) {
	mesh_materials = p_materials;
	recreate_shapes();
}

PackedByteArray Box3DBody::get_mesh_materials() const {
	return mesh_materials;
}

void Box3DBody::set_mesh_weld_tolerance(double p_tolerance) {
	mesh_weld_tolerance = p_tolerance;
	recreate_shapes();
}

double Box3DBody::get_mesh_weld_tolerance() const {
	return mesh_weld_tolerance;
}

void Box3DBody::set_mesh_median_split(bool p_enabled) {
	mesh_median_split = p_enabled;
	recreate_shapes();
}

bool Box3DBody::get_mesh_median_split() const {
	return mesh_median_split;
}

void Box3DBody::set_surface_materials(const Array &p_materials) {
	surface_materials = p_materials;
	recreate_shapes();
}

Array Box3DBody::get_surface_materials() const {
	return surface_materials;
}

// The body's own mesh / height field shape, i.e. the first shape it owns. A
// compound's Box3DCollisionShape children are convex, so they never carry a
// per-triangle material array.
int Box3DBody::get_mesh_material_count() const {
	std::vector<b3ShapeId> ids = own_shape_ids();
	if (ids.empty()) {
		return 0;
	}
	return b3Shape_GetMeshMaterialCount(ids[0]);
}

Dictionary Box3DBody::get_mesh_material(int p_index) const {
	std::vector<b3ShapeId> ids = own_shape_ids();
	// Upstream asserts on an out-of-range index (src/shape.c:1296).
	if (ids.empty() || p_index < 0 || p_index >= b3Shape_GetMeshMaterialCount(ids[0])) {
		return Dictionary();
	}
	return to_gd_material(b3Shape_GetMeshSurfaceMaterial(ids[0], p_index));
}

void Box3DBody::set_mesh_material(int p_index, const Dictionary &p_material) {
	std::vector<b3ShapeId> ids = own_shape_ids();
	if (ids.empty() || p_index < 0 || p_index >= b3Shape_GetMeshMaterialCount(ids[0])) {
		return;
	}
	b3Shape_SetMeshMaterial(ids[0], to_b3_material(p_material), p_index);
}

void Box3DBody::set_height_field_size(const Vector2i &p_size) {
	height_field_size = p_size;
	recreate_shapes();
}

Vector2i Box3DBody::get_height_field_size() const {
	return height_field_size;
}

void Box3DBody::set_height_field_scale(const Vector3 &p_scale) {
	height_field_scale = p_scale;
	recreate_shapes();
}

Vector3 Box3DBody::get_height_field_scale() const {
	return height_field_scale;
}

void Box3DBody::set_height_field_heights(const PackedFloat32Array &p_heights) {
	height_field_heights = p_heights;
	recreate_shapes();
}

PackedFloat32Array Box3DBody::get_height_field_heights() const {
	return height_field_heights;
}

void Box3DBody::set_height_field_materials(const PackedByteArray &p_materials) {
	height_field_materials = p_materials;
	recreate_shapes();
}

PackedByteArray Box3DBody::get_height_field_materials() const {
	return height_field_materials;
}

void Box3DBody::set_height_field_wave(const Vector2 &p_frequencies) {
	height_field_wave = p_frequencies;
	recreate_shapes();
}

Vector2 Box3DBody::get_height_field_wave() const {
	return height_field_wave;
}

void Box3DBody::set_height_field_height_range(const Vector2 &p_range) {
	height_field_height_range = p_range;
	recreate_shapes();
}

Vector2 Box3DBody::get_height_field_height_range() const {
	return height_field_height_range;
}

void Box3DBody::set_height_field_holes(bool p_enabled) {
	height_field_holes = p_enabled;
	recreate_shapes();
}

bool Box3DBody::get_height_field_holes() const {
	return height_field_holes;
}

void Box3DBody::set_height_field_clockwise(bool p_enabled) {
	height_field_clockwise = p_enabled;
	recreate_shapes();
}

bool Box3DBody::get_height_field_clockwise() const {
	return height_field_clockwise;
}

Vector3 Box3DBody::get_height_field_extent() const {
	if (height_field_size.x < 2 || height_field_size.y < 2) {
		return Vector3();
	}
	// The field spans (count - 1) cells on each axis (src/height_field.c:188-190).
	return Vector3(height_field_scale.x * (height_field_size.x - 1), 0.0,
			height_field_scale.z * (height_field_size.y - 1));
}

Dictionary Box3DBody::get_height_field() const {
	Dictionary out;
	if (!body_live()) {
		return out;
	}
	// The body's own shape, which is the only place a height field can be: a
	// Box3DCollisionShape child cannot author one, and there is no setter that
	// retypes a shape into one.
	b3ShapeId sid;
	if (b3Body_GetShapes(body_id, &sid, 1) != 1 || !b3Shape_IsValid(sid) ||
			b3Shape_GetType(sid) != b3_heightShape) {
		return out; // b3Shape_GetHeightField asserts on a type mismatch
	}
	const b3HeightFieldData *hf = b3Shape_GetHeightField(sid);
	if (hf == nullptr) {
		return out;
	}
	// columnCount runs along x, rowCount along z (src/height_field.c:19-40), and
	// both count grid lines.
	const int cols = hf->columnCount;
	const int rows = hf->rowCount;
	PackedFloat32Array heights;
	const uint16_t *stored = b3GetHeightFieldCompressedHeights(hf);
	if (stored != nullptr && cols > 0 && rows > 0) {
		heights.resize((int64_t)cols * rows);
		float *w = heights.ptrw();
		for (int64_t i = 0, n = (int64_t)cols * rows; i < n; ++i) {
			// The one decompression upstream documents (src/height_field.c:23).
			w[i] = hf->minHeight + hf->heightScale * (float)stored[i];
		}
	}
	PackedByteArray materials;
	const uint8_t *cells = b3GetHeightFieldMaterialIndices(hf);
	if (cells != nullptr && cols > 1 && rows > 1) {
		const int64_t cell_count = (int64_t)(cols - 1) * (rows - 1);
		materials.resize(cell_count);
		memcpy(materials.ptrw(), cells, (size_t)cell_count);
	}
	const Vector3 lower = to_gd(hf->aabb.lowerBound);
	out["size"] = Vector2i(cols, rows);
	out["scale"] = to_gd(hf->scale);
	out["min_height"] = (double)hf->minHeight;
	out["max_height"] = (double)hf->maxHeight;
	out["aabb"] = AABB(lower, to_gd(hf->aabb.upperBound) - lower);
	out["clockwise"] = hf->clockwise;
	out["heights"] = heights;
	out["materials"] = materials;
	return out;
}

void Box3DBody::set_density(double p_density) {
	density = p_density;
	apply_density();
}

double Box3DBody::get_density() const {
	return density;
}

void Box3DBody::set_friction(double p_friction) {
	friction = p_friction;
	if (!apply_surface_material()) {
		recreate_shapes();
	}
}

double Box3DBody::get_friction() const {
	return friction;
}

void Box3DBody::set_restitution(double p_restitution) {
	restitution = p_restitution;
	if (!apply_surface_material()) {
		recreate_shapes();
	}
}

double Box3DBody::get_restitution() const {
	return restitution;
}

void Box3DBody::set_rolling_resistance(double p_resistance) {
	rolling_resistance = p_resistance;
	if (!apply_surface_material()) {
		recreate_shapes();
	}
}

double Box3DBody::get_rolling_resistance() const {
	return rolling_resistance;
}

void Box3DBody::set_tangent_velocity(const Vector3 &p_velocity) {
	tangent_velocity = p_velocity;
	if (!apply_surface_material()) {
		recreate_shapes();
	}
}

Vector3 Box3DBody::get_tangent_velocity() const {
	return tangent_velocity;
}

void Box3DBody::set_user_material_id(int64_t p_id) {
	user_material_id = p_id;
	if (!apply_surface_material()) {
		recreate_shapes();
	}
}

int64_t Box3DBody::get_user_material_id() const {
	return user_material_id;
}

void Box3DBody::set_explosion_scale(double p_scale) {
	explosion_scale = p_scale;
	recreate_shapes();
}

double Box3DBody::get_explosion_scale() const {
	return explosion_scale;
}

void Box3DBody::set_invoke_contact_creation(bool p_enabled) {
	invoke_contact_creation = p_enabled;
	recreate_shapes();
}

bool Box3DBody::get_invoke_contact_creation() const {
	return invoke_contact_creation;
}

void Box3DBody::set_speculative_contact(bool p_enabled) {
	speculative_contact = p_enabled;
	recreate_shapes();
}

void Box3DBody::set_baked_compound(bool p_enabled) {
	baked_compound = p_enabled;
	recreate_shapes();
}

bool Box3DBody::get_baked_compound() const {
	return baked_compound;
}

Dictionary Box3DBody::get_compound_info() const {
	Dictionary out;
	if (compound_data == nullptr) {
		return out;
	}
	out["capsule_count"] = compound_data->capsuleCount;
	out["hull_count"] = compound_data->hullCount;
	out["mesh_count"] = compound_data->meshCount;
	out["sphere_count"] = compound_data->sphereCount;
	// Diagnostics: b3CreateCompound deduplicates identical hulls and meshes by
	// content before copying them in (src/compound.c:358-373).
	out["shared_hull_count"] = compound_data->sharedHullCount;
	out["shared_mesh_count"] = compound_data->sharedMeshCount;
	out["material_count"] = compound_data->materialCount;
	out["byte_count"] = compound_data->byteCount;
	return out;
}

bool Box3DBody::get_speculative_contact() const {
	return speculative_contact;
}

void Box3DBody::set_linear_damping(double p_damping) {
	linear_damping = p_damping;
	if (body_live()) {
		b3Body_SetLinearDamping(body_id, (float)linear_damping);
	}
}

double Box3DBody::get_linear_damping() const {
	return linear_damping;
}

void Box3DBody::set_angular_damping(double p_damping) {
	angular_damping = p_damping;
	if (body_live()) {
		b3Body_SetAngularDamping(body_id, (float)angular_damping);
	}
}

double Box3DBody::get_angular_damping() const {
	return angular_damping;
}

void Box3DBody::set_gravity_scale(double p_scale) {
	gravity_scale = p_scale;
	if (body_live()) {
		b3Body_SetGravityScale(body_id, (float)gravity_scale);
	}
}

double Box3DBody::get_gravity_scale() const {
	return gravity_scale;
}

void Box3DBody::set_can_sleep(bool p_enabled) {
	can_sleep = p_enabled;
	if (body_live()) {
		// Upstream wakes the body when sleeping is turned off.
		b3Body_EnableSleep(body_id, can_sleep);
		asleep_synced = false;
	}
}

bool Box3DBody::get_can_sleep() const {
	return can_sleep;
}

void Box3DBody::set_sleep_threshold(double p_threshold) {
	sleep_threshold = p_threshold;
	if (body_live()) {
		b3Body_SetSleepThreshold(body_id, (float)sleep_threshold);
	}
}

double Box3DBody::get_sleep_threshold() const {
	return sleep_threshold;
}

void Box3DBody::set_enabled(bool p_enabled) {
	enabled = p_enabled;
	refresh_gizmos(); // slate gray when disabled, as upstream draws it
	if (body_live()) {
		// Disabling removes the body from the simulation entirely; upstream
		// calls both directions expensive, so this is a state change, not a
		// per-frame knob.
		if (enabled) {
			b3Body_Enable(body_id);
		} else {
			b3Body_Disable(body_id);
		}
		// The debug draw reads the cached flag rather than querying every body.
		debug_enabled = b3Body_IsEnabled(body_id);
		asleep_synced = false;
	}
}

bool Box3DBody::get_enabled() const {
	return enabled;
}

void Box3DBody::set_contact_monitor(bool p_enabled) {
	contact_monitor = p_enabled;
	apply_shape_events();
}

bool Box3DBody::get_contact_monitor() const {
	return contact_monitor;
}

void Box3DBody::set_sensor_events(bool p_enabled) {
	sensor_events = p_enabled;
	apply_shape_events();
}

bool Box3DBody::get_sensor_events() const {
	return sensor_events;
}

void Box3DBody::set_hit_events(bool p_enabled) {
	hit_events = p_enabled;
	apply_shape_events();
}

bool Box3DBody::get_hit_events() const {
	return hit_events;
}

// Upstream has no live sensor toggle and cannot have one cheaply: a sensor owns
// an entry in the world's sensor array with its own overlap buffers, and
// shape->sensorIndex is assigned exactly once, inside b3CreateShapeInternal
// (src/shape.c:236-248). b3Shape_EnableSensorEvents (box3d.h:914-916) is about
// event delivery, not about being a sensor, and is explicitly "ignored for
// sensors". So the shape genuinely has to be built again — but only the shape:
// recreate_shapes() keeps the body, its velocity, its sleep state and its
// joints, which the destroy-and-recreate this replaced did not.
void Box3DBody::set_is_sensor(bool p_sensor) {
	if (is_sensor == p_sensor) {
		return;
	}
	is_sensor = p_sensor;
	recreate_shapes();
}

bool Box3DBody::get_is_sensor() const {
	return is_sensor;
}

void Box3DBody::set_debug_visualize(bool p_enabled) {
	debug_visualize = p_enabled;
}

bool Box3DBody::get_debug_visualize() const {
	return debug_visualize;
}

float Box3DBody::debug_max_extent() const {
	// Distance from the body origin to its farthest collider point, mirroring
	// upstream's sim->maxExtent (rotation's contribution to the fast check).
	// The node scale is baked into the collider, so it is baked in here too.
	const float scale_factor = node_scaled ? max_abs_scale(node_scale) : 1.0f;
	bool has_child_shapes = false;
	float max_extent = 0.0f;
	for (int i = 0; i < get_child_count(); ++i) {
		Box3DCollisionShape *cs = Object::cast_to<Box3DCollisionShape>(get_child(i));
		if (cs == nullptr) {
			continue;
		}
		has_child_shapes = true;
		float e = 0.0f;
		switch (cs->get_shape_type()) {
			case Box3DCollisionShape::SPHERE:
				e = (float)cs->get_sphere_radius();
				break;
			case Box3DCollisionShape::CAPSULE:
				e = (float)cs->get_capsule_height() * 0.5f;
				break;
			case Box3DCollisionShape::BOX:
			default:
				e = (float)(cs->get_box_size() * 0.5).length();
				break;
		}
		max_extent = MAX(max_extent, (float)cs->get_position().length() + e);
	}
	if (has_child_shapes) {
		return scale_factor * (max_extent);
	}
	switch (shape_type) {
		case SPHERE:
			return scale_factor * ((float)sphere_radius);
		case CAPSULE:
		case CYLINDER:
		case CONE: {
			float half_h = (float)capsule_height * 0.5f;
			float r = (float)capsule_radius;
			return scale_factor * (Math::sqrt(half_h * half_h + r * r));
		}
		case BOX:
		case FIT_MESH:
			return scale_factor * ((float)(box_size * 0.5).length());
		default:
			return scale_factor * (0.0f); // hull/mesh: no rotation contribution
	}
}

float Box3DBody::debug_min_extent() const {
	// Smallest half-extent of the collider, mirroring upstream's sim->minExtent
	// (used by its "fast body" debug state). Child shapes take over for
	// compounds, exactly like collision creation does. The node scale is baked
	// into the collider, so the smallest of its components applies here.
	const float scale_factor = node_scaled
			? (float)MIN(Math::abs(node_scale.x), MIN(Math::abs(node_scale.y), Math::abs(node_scale.z)))
			: 1.0f;
	bool has_child_shapes = false;
	float min_extent = 1e9f;
	for (int i = 0; i < get_child_count(); ++i) {
		Box3DCollisionShape *cs = Object::cast_to<Box3DCollisionShape>(get_child(i));
		if (cs == nullptr) {
			continue;
		}
		has_child_shapes = true;
		float e = 1e9f;
		switch (cs->get_shape_type()) {
			case Box3DCollisionShape::SPHERE:
				e = (float)cs->get_sphere_radius();
				break;
			case Box3DCollisionShape::CAPSULE:
				e = (float)cs->get_capsule_radius();
				break;
			case Box3DCollisionShape::BOX:
			default: {
				Vector3 half = cs->get_box_size() * 0.5;
				e = (float)MIN(half.x, MIN(half.y, half.z));
			} break;
		}
		min_extent = MIN(min_extent, e);
	}
	if (has_child_shapes) {
		return scale_factor * (min_extent);
	}
	switch (shape_type) {
		case SPHERE:
			return scale_factor * ((float)sphere_radius);
		case CAPSULE:
			return scale_factor * ((float)capsule_radius);
		case CYLINDER:
		case CONE:
			return scale_factor * (MIN((float)capsule_radius, (float)capsule_height * 0.5f));
		case BOX:
		case FIT_MESH: {
			Vector3 half = box_size * 0.5;
			return scale_factor * ((float)MIN(half.x, MIN(half.y, half.z)));
		}
		default:
			return scale_factor * (1e9f); // hull/mesh: never flagged fast
	}
}

void Box3DBody::set_continuous(bool p_enabled) {
	continuous = p_enabled;
	if (body_live()) {
		b3Body_SetBullet(body_id, p_enabled);
	}
}

bool Box3DBody::get_continuous() const {
	return continuous;
}

void Box3DBody::set_contact_recycling(bool p_enabled) {
	contact_recycling = p_enabled;
	if (body_live()) {
		b3Body_EnableContactRecycling(body_id, p_enabled);
	}
}

bool Box3DBody::get_contact_recycling() const {
	return contact_recycling;
}

void Box3DBody::set_sync_node_transform(bool p_enabled) {
	sync_node_transform = p_enabled;
	// Turning it back on catches the node up on the next tick.
	asleep_synced = false;
}

bool Box3DBody::get_sync_node_transform() const {
	return sync_node_transform;
}

void Box3DBody::set_allow_fast_rotation(bool p_enabled) {
	allow_fast_rotation = p_enabled;
	if (body_live()) {
		b3Body_AllowFastRotation(body_id, allow_fast_rotation);
	}
}

bool Box3DBody::get_allow_fast_rotation() const {
	return allow_fast_rotation;
}

void Box3DBody::set_lock_linear_x(bool p_v) { lock_linear_x = p_v; apply_motion_locks(); }
bool Box3DBody::get_lock_linear_x() const { return lock_linear_x; }
void Box3DBody::set_lock_linear_y(bool p_v) { lock_linear_y = p_v; apply_motion_locks(); }
bool Box3DBody::get_lock_linear_y() const { return lock_linear_y; }
void Box3DBody::set_lock_linear_z(bool p_v) { lock_linear_z = p_v; apply_motion_locks(); }
bool Box3DBody::get_lock_linear_z() const { return lock_linear_z; }
void Box3DBody::set_lock_angular_x(bool p_v) { lock_angular_x = p_v; apply_motion_locks(); }
bool Box3DBody::get_lock_angular_x() const { return lock_angular_x; }
void Box3DBody::set_lock_angular_y(bool p_v) { lock_angular_y = p_v; apply_motion_locks(); }
bool Box3DBody::get_lock_angular_y() const { return lock_angular_y; }
void Box3DBody::set_lock_angular_z(bool p_v) { lock_angular_z = p_v; apply_motion_locks(); }
bool Box3DBody::get_lock_angular_z() const { return lock_angular_z; }

void Box3DBody::set_collision_layer(int p_layer) {
	collision_layer = (uint32_t)p_layer;
	apply_filter();
}

int Box3DBody::get_collision_layer() const {
	return (int)collision_layer;
}

void Box3DBody::set_collision_mask(int p_mask) {
	collision_mask = (uint32_t)p_mask;
	apply_filter();
}

int Box3DBody::get_collision_mask() const {
	return (int)collision_mask;
}

void Box3DBody::set_collision_layer_high(int p_layer) {
	collision_layer_high = (uint32_t)p_layer;
	apply_filter();
}

int Box3DBody::get_collision_layer_high() const {
	return (int)collision_layer_high;
}

void Box3DBody::set_collision_mask_high(int p_mask) {
	collision_mask_high = (uint32_t)p_mask;
	apply_filter();
}

int Box3DBody::get_collision_mask_high() const {
	return (int)collision_mask_high;
}

void Box3DBody::set_collision_group(int p_group) {
	collision_group = p_group;
	apply_filter();
}

int Box3DBody::get_collision_group() const {
	return collision_group;
}

void Box3DBody::set_auto_visual(bool p_enabled) {
	auto_visual = p_enabled;
	update_auto_visual();
}

bool Box3DBody::get_auto_visual() const {
	return auto_visual;
}

void Box3DBody::_bind_methods() {
	ClassDB::bind_method(D_METHOD("apply_central_force", "force"), &Box3DBody::apply_central_force);
	ClassDB::bind_method(D_METHOD("apply_central_impulse", "impulse"), &Box3DBody::apply_central_impulse);
	ClassDB::bind_method(D_METHOD("apply_torque", "torque"), &Box3DBody::apply_torque);
	ClassDB::bind_method(D_METHOD("apply_force_at_point", "force", "point"), &Box3DBody::apply_force_at_point);
	ClassDB::bind_method(D_METHOD("apply_impulse_at_point", "impulse", "point"), &Box3DBody::apply_impulse_at_point);
	ClassDB::bind_method(D_METHOD("apply_angular_impulse", "impulse"), &Box3DBody::apply_angular_impulse);
	ClassDB::bind_method(D_METHOD("get_world_point", "local_point"), &Box3DBody::get_world_point);
	ClassDB::bind_method(D_METHOD("get_local_point", "world_point"), &Box3DBody::get_local_point);
	ClassDB::bind_method(D_METHOD("get_world_vector", "local_vector"), &Box3DBody::get_world_vector);
	ClassDB::bind_method(D_METHOD("get_local_vector", "world_vector"), &Box3DBody::get_local_vector);
	ClassDB::bind_method(D_METHOD("get_point_velocity", "world_point"), &Box3DBody::get_point_velocity);
	ClassDB::bind_method(D_METHOD("get_local_point_velocity", "local_point"), &Box3DBody::get_local_point_velocity);
	ClassDB::bind_method(D_METHOD("set_awake", "awake"), &Box3DBody::set_awake);
	ClassDB::bind_method(D_METHOD("is_awake"), &Box3DBody::is_awake_now);
	ClassDB::bind_method(D_METHOD("set_linear_velocity", "velocity"), &Box3DBody::set_linear_velocity);
	ClassDB::bind_method(D_METHOD("get_linear_velocity"), &Box3DBody::get_linear_velocity);
	ClassDB::bind_method(D_METHOD("set_angular_velocity", "velocity"), &Box3DBody::set_angular_velocity);
	ClassDB::bind_method(D_METHOD("get_angular_velocity"), &Box3DBody::get_angular_velocity);
	ClassDB::bind_method(D_METHOD("get_mass"), &Box3DBody::get_mass);
	ClassDB::bind_method(D_METHOD("get_inverse_mass"), &Box3DBody::get_inverse_mass);
	ClassDB::bind_method(D_METHOD("get_center_of_mass"), &Box3DBody::get_center_of_mass);
	ClassDB::bind_method(D_METHOD("get_local_center_of_mass"), &Box3DBody::get_local_center_of_mass);
	ClassDB::bind_method(D_METHOD("get_inertia_tensor"), &Box3DBody::get_inertia_tensor);
	ClassDB::bind_method(D_METHOD("get_inverse_inertia_tensor"), &Box3DBody::get_inverse_inertia_tensor);
	ClassDB::bind_method(D_METHOD("set_mass_data", "mass", "local_center", "inertia"), &Box3DBody::set_mass_data);
	ClassDB::bind_method(D_METHOD("get_mass_data"), &Box3DBody::get_mass_data);
	ClassDB::bind_method(D_METHOD("apply_mass_from_shapes"), &Box3DBody::apply_mass_from_shapes);
	ClassDB::bind_method(D_METHOD("get_aabb"), &Box3DBody::get_aabb);
	ClassDB::bind_method(D_METHOD("get_closest_point", "target"), &Box3DBody::get_closest_point);
	ClassDB::bind_method(D_METHOD("get_closest_distance", "target"), &Box3DBody::get_closest_distance);
	ClassDB::bind_method(D_METHOD("get_shape_count"), &Box3DBody::get_shape_count);
	ClassDB::bind_method(D_METHOD("get_joint_count"), &Box3DBody::get_joint_count);
	ClassDB::bind_method(D_METHOD("get_shape_nodes"), &Box3DBody::get_shape_nodes);
	ClassDB::bind_method(D_METHOD("get_shape_names"), &Box3DBody::get_shape_names);
	ClassDB::bind_method(D_METHOD("get_joints"), &Box3DBody::get_joints);
	ClassDB::bind_method(D_METHOD("get_world"), &Box3DBody::get_world);
	ClassDB::bind_method(D_METHOD("get_contacts"), &Box3DBody::get_contacts);
	ClassDB::bind_method(D_METHOD("get_touching_bodies"), &Box3DBody::get_touching_bodies);
	ClassDB::bind_method(D_METHOD("get_overlapping_bodies"), &Box3DBody::get_overlapping_bodies);
	ClassDB::bind_method(D_METHOD("apply_wind", "wind", "drag", "lift", "max_speed"), &Box3DBody::apply_wind);
	ClassDB::bind_method(D_METHOD("set_body_name", "name"), &Box3DBody::set_body_name);
	ClassDB::bind_method(D_METHOD("get_body_name"), &Box3DBody::get_body_name);
	ClassDB::bind_method(D_METHOD("teleport", "transform"), &Box3DBody::teleport);

	ClassDB::bind_method(D_METHOD("set_body_type", "type"), &Box3DBody::set_body_type);
	ClassDB::bind_method(D_METHOD("get_body_type"), &Box3DBody::get_body_type);
	ClassDB::bind_method(D_METHOD("set_shape_type", "type"), &Box3DBody::set_shape_type);
	ClassDB::bind_method(D_METHOD("get_shape_type"), &Box3DBody::get_shape_type);
	ClassDB::bind_method(D_METHOD("set_box_size", "size"), &Box3DBody::set_box_size);
	ClassDB::bind_method(D_METHOD("get_box_size"), &Box3DBody::get_box_size);
	ClassDB::bind_method(D_METHOD("set_sphere_radius", "radius"), &Box3DBody::set_sphere_radius);
	ClassDB::bind_method(D_METHOD("get_sphere_radius"), &Box3DBody::get_sphere_radius);
	ClassDB::bind_method(D_METHOD("set_capsule_radius", "radius"), &Box3DBody::set_capsule_radius);
	ClassDB::bind_method(D_METHOD("get_capsule_radius"), &Box3DBody::get_capsule_radius);
	ClassDB::bind_method(D_METHOD("set_capsule_height", "height"), &Box3DBody::set_capsule_height);
	ClassDB::bind_method(D_METHOD("get_capsule_height"), &Box3DBody::get_capsule_height);
	ClassDB::bind_method(D_METHOD("set_cylinder_sides", "sides"), &Box3DBody::set_cylinder_sides);
	ClassDB::bind_method(D_METHOD("get_cylinder_sides"), &Box3DBody::get_cylinder_sides);
	ClassDB::bind_method(D_METHOD("set_collision_mesh", "mesh"), &Box3DBody::set_collision_mesh);
	ClassDB::bind_method(D_METHOD("get_collision_mesh"), &Box3DBody::get_collision_mesh);
	ClassDB::bind_method(D_METHOD("set_mesh_vertices", "vertices"), &Box3DBody::set_mesh_vertices);
	ClassDB::bind_method(D_METHOD("get_mesh_vertices"), &Box3DBody::get_mesh_vertices);
	ClassDB::bind_method(D_METHOD("set_mesh_indices", "indices"), &Box3DBody::set_mesh_indices);
	ClassDB::bind_method(D_METHOD("get_mesh_indices"), &Box3DBody::get_mesh_indices);
	ClassDB::bind_method(D_METHOD("set_mesh_materials", "materials"), &Box3DBody::set_mesh_materials);
	ClassDB::bind_method(D_METHOD("get_mesh_materials"), &Box3DBody::get_mesh_materials);
	ClassDB::bind_method(D_METHOD("set_mesh_weld_tolerance", "tolerance"), &Box3DBody::set_mesh_weld_tolerance);
	ClassDB::bind_method(D_METHOD("get_mesh_weld_tolerance"), &Box3DBody::get_mesh_weld_tolerance);
	ClassDB::bind_method(D_METHOD("set_mesh_median_split", "enabled"), &Box3DBody::set_mesh_median_split);
	ClassDB::bind_method(D_METHOD("get_mesh_median_split"), &Box3DBody::get_mesh_median_split);
	ClassDB::bind_method(D_METHOD("set_surface_materials", "materials"), &Box3DBody::set_surface_materials);
	ClassDB::bind_method(D_METHOD("get_surface_materials"), &Box3DBody::get_surface_materials);
	ClassDB::bind_method(D_METHOD("get_mesh_material_count"), &Box3DBody::get_mesh_material_count);
	ClassDB::bind_method(D_METHOD("get_mesh_material", "index"), &Box3DBody::get_mesh_material);
	ClassDB::bind_method(D_METHOD("set_mesh_material", "index", "material"), &Box3DBody::set_mesh_material);
	ClassDB::bind_method(D_METHOD("set_height_field_size", "size"), &Box3DBody::set_height_field_size);
	ClassDB::bind_method(D_METHOD("get_height_field_size"), &Box3DBody::get_height_field_size);
	ClassDB::bind_method(D_METHOD("set_height_field_scale", "scale"), &Box3DBody::set_height_field_scale);
	ClassDB::bind_method(D_METHOD("get_height_field_scale"), &Box3DBody::get_height_field_scale);
	ClassDB::bind_method(D_METHOD("set_height_field_heights", "heights"), &Box3DBody::set_height_field_heights);
	ClassDB::bind_method(D_METHOD("get_height_field_heights"), &Box3DBody::get_height_field_heights);
	ClassDB::bind_method(D_METHOD("set_height_field_materials", "materials"), &Box3DBody::set_height_field_materials);
	ClassDB::bind_method(D_METHOD("get_height_field_materials"), &Box3DBody::get_height_field_materials);
	ClassDB::bind_method(D_METHOD("set_height_field_wave", "frequencies"), &Box3DBody::set_height_field_wave);
	ClassDB::bind_method(D_METHOD("get_height_field_wave"), &Box3DBody::get_height_field_wave);
	ClassDB::bind_method(D_METHOD("set_height_field_height_range", "range"), &Box3DBody::set_height_field_height_range);
	ClassDB::bind_method(D_METHOD("get_height_field_height_range"), &Box3DBody::get_height_field_height_range);
	ClassDB::bind_method(D_METHOD("set_height_field_holes", "enabled"), &Box3DBody::set_height_field_holes);
	ClassDB::bind_method(D_METHOD("get_height_field_holes"), &Box3DBody::get_height_field_holes);
	ClassDB::bind_method(D_METHOD("set_height_field_clockwise", "enabled"), &Box3DBody::set_height_field_clockwise);
	ClassDB::bind_method(D_METHOD("get_height_field_clockwise"), &Box3DBody::get_height_field_clockwise);
	ClassDB::bind_method(D_METHOD("get_height_field_extent"), &Box3DBody::get_height_field_extent);
	ClassDB::bind_method(D_METHOD("get_height_field"), &Box3DBody::get_height_field);
	ClassDB::bind_method(D_METHOD("set_density", "density"), &Box3DBody::set_density);
	ClassDB::bind_method(D_METHOD("get_density"), &Box3DBody::get_density);
	ClassDB::bind_method(D_METHOD("set_friction", "friction"), &Box3DBody::set_friction);
	ClassDB::bind_method(D_METHOD("get_friction"), &Box3DBody::get_friction);
	ClassDB::bind_method(D_METHOD("set_restitution", "restitution"), &Box3DBody::set_restitution);
	ClassDB::bind_method(D_METHOD("get_restitution"), &Box3DBody::get_restitution);
	ClassDB::bind_method(D_METHOD("set_rolling_resistance", "resistance"), &Box3DBody::set_rolling_resistance);
	ClassDB::bind_method(D_METHOD("get_rolling_resistance"), &Box3DBody::get_rolling_resistance);
	ClassDB::bind_method(D_METHOD("set_tangent_velocity", "velocity"), &Box3DBody::set_tangent_velocity);
	ClassDB::bind_method(D_METHOD("get_tangent_velocity"), &Box3DBody::get_tangent_velocity);
	ClassDB::bind_method(D_METHOD("set_user_material_id", "id"), &Box3DBody::set_user_material_id);
	ClassDB::bind_method(D_METHOD("get_user_material_id"), &Box3DBody::get_user_material_id);
	ClassDB::bind_method(D_METHOD("set_explosion_scale", "scale"), &Box3DBody::set_explosion_scale);
	ClassDB::bind_method(D_METHOD("get_explosion_scale"), &Box3DBody::get_explosion_scale);
	ClassDB::bind_method(D_METHOD("set_invoke_contact_creation", "enabled"), &Box3DBody::set_invoke_contact_creation);
	ClassDB::bind_method(D_METHOD("get_invoke_contact_creation"), &Box3DBody::get_invoke_contact_creation);
	ClassDB::bind_method(D_METHOD("set_speculative_contact", "enabled"), &Box3DBody::set_speculative_contact);
	ClassDB::bind_method(D_METHOD("get_speculative_contact"), &Box3DBody::get_speculative_contact);
	ClassDB::bind_method(D_METHOD("set_baked_compound", "enabled"), &Box3DBody::set_baked_compound);
	ClassDB::bind_method(D_METHOD("get_baked_compound"), &Box3DBody::get_baked_compound);
	ClassDB::bind_method(D_METHOD("get_compound_info"), &Box3DBody::get_compound_info);
	ClassDB::bind_method(D_METHOD("cast_ray", "from", "to", "body_transform", "collision_mask", "collision_layer"), &Box3DBody::cast_ray, DEFVAL(Transform3D()), DEFVAL(B3_DEFAULT_MASK_BITS), DEFVAL(B3_DEFAULT_CATEGORY_BITS));
	ClassDB::bind_method(D_METHOD("cast_box", "from", "to", "size", "body_transform", "collision_mask", "collision_layer"), &Box3DBody::cast_box, DEFVAL(Transform3D()), DEFVAL(B3_DEFAULT_MASK_BITS), DEFVAL(B3_DEFAULT_CATEGORY_BITS));
	ClassDB::bind_method(D_METHOD("overlaps_box", "center", "size", "body_transform", "collision_mask", "collision_layer"), &Box3DBody::overlaps_box, DEFVAL(Transform3D()), DEFVAL(B3_DEFAULT_MASK_BITS), DEFVAL(B3_DEFAULT_CATEGORY_BITS));
	ClassDB::bind_method(D_METHOD("set_linear_damping", "damping"), &Box3DBody::set_linear_damping);
	ClassDB::bind_method(D_METHOD("get_linear_damping"), &Box3DBody::get_linear_damping);
	ClassDB::bind_method(D_METHOD("set_angular_damping", "damping"), &Box3DBody::set_angular_damping);
	ClassDB::bind_method(D_METHOD("get_angular_damping"), &Box3DBody::get_angular_damping);
	ClassDB::bind_method(D_METHOD("set_gravity_scale", "scale"), &Box3DBody::set_gravity_scale);
	ClassDB::bind_method(D_METHOD("get_gravity_scale"), &Box3DBody::get_gravity_scale);
	ClassDB::bind_method(D_METHOD("set_can_sleep", "enabled"), &Box3DBody::set_can_sleep);
	ClassDB::bind_method(D_METHOD("get_can_sleep"), &Box3DBody::get_can_sleep);
	ClassDB::bind_method(D_METHOD("set_sleep_threshold", "threshold"), &Box3DBody::set_sleep_threshold);
	ClassDB::bind_method(D_METHOD("get_sleep_threshold"), &Box3DBody::get_sleep_threshold);
	ClassDB::bind_method(D_METHOD("set_enabled", "enabled"), &Box3DBody::set_enabled);
	ClassDB::bind_method(D_METHOD("get_enabled"), &Box3DBody::get_enabled);
	ClassDB::bind_method(D_METHOD("set_contact_monitor", "enabled"), &Box3DBody::set_contact_monitor);
	ClassDB::bind_method(D_METHOD("get_contact_monitor"), &Box3DBody::get_contact_monitor);
	ClassDB::bind_method(D_METHOD("set_sensor_events", "enabled"), &Box3DBody::set_sensor_events);
	ClassDB::bind_method(D_METHOD("get_sensor_events"), &Box3DBody::get_sensor_events);
	ClassDB::bind_method(D_METHOD("set_hit_events", "enabled"), &Box3DBody::set_hit_events);
	ClassDB::bind_method(D_METHOD("get_hit_events"), &Box3DBody::get_hit_events);
	ClassDB::bind_method(D_METHOD("set_is_sensor", "sensor"), &Box3DBody::set_is_sensor);
	ClassDB::bind_method(D_METHOD("get_is_sensor"), &Box3DBody::get_is_sensor);
	ClassDB::bind_method(D_METHOD("set_debug_visualize", "enabled"), &Box3DBody::set_debug_visualize);
	ClassDB::bind_method(D_METHOD("get_debug_visualize"), &Box3DBody::get_debug_visualize);
	ClassDB::bind_method(D_METHOD("set_continuous", "enabled"), &Box3DBody::set_continuous);
	ClassDB::bind_method(D_METHOD("set_contact_recycling", "enabled"), &Box3DBody::set_contact_recycling);
	ClassDB::bind_method(D_METHOD("get_contact_recycling"), &Box3DBody::get_contact_recycling);
	ClassDB::bind_method(D_METHOD("set_sync_node_transform", "enabled"), &Box3DBody::set_sync_node_transform);
	ClassDB::bind_method(D_METHOD("get_sync_node_transform"), &Box3DBody::get_sync_node_transform);
	ClassDB::bind_method(D_METHOD("get_continuous"), &Box3DBody::get_continuous);
	ClassDB::bind_method(D_METHOD("set_allow_fast_rotation", "enabled"), &Box3DBody::set_allow_fast_rotation);
	ClassDB::bind_method(D_METHOD("get_allow_fast_rotation"), &Box3DBody::get_allow_fast_rotation);
	ClassDB::bind_method(D_METHOD("set_lock_linear_x", "enabled"), &Box3DBody::set_lock_linear_x);
	ClassDB::bind_method(D_METHOD("get_lock_linear_x"), &Box3DBody::get_lock_linear_x);
	ClassDB::bind_method(D_METHOD("set_lock_linear_y", "enabled"), &Box3DBody::set_lock_linear_y);
	ClassDB::bind_method(D_METHOD("get_lock_linear_y"), &Box3DBody::get_lock_linear_y);
	ClassDB::bind_method(D_METHOD("set_lock_linear_z", "enabled"), &Box3DBody::set_lock_linear_z);
	ClassDB::bind_method(D_METHOD("get_lock_linear_z"), &Box3DBody::get_lock_linear_z);
	ClassDB::bind_method(D_METHOD("set_lock_angular_x", "enabled"), &Box3DBody::set_lock_angular_x);
	ClassDB::bind_method(D_METHOD("get_lock_angular_x"), &Box3DBody::get_lock_angular_x);
	ClassDB::bind_method(D_METHOD("set_lock_angular_y", "enabled"), &Box3DBody::set_lock_angular_y);
	ClassDB::bind_method(D_METHOD("get_lock_angular_y"), &Box3DBody::get_lock_angular_y);
	ClassDB::bind_method(D_METHOD("set_lock_angular_z", "enabled"), &Box3DBody::set_lock_angular_z);
	ClassDB::bind_method(D_METHOD("get_lock_angular_z"), &Box3DBody::get_lock_angular_z);
	ClassDB::bind_method(D_METHOD("set_collision_layer", "layer"), &Box3DBody::set_collision_layer);
	ClassDB::bind_method(D_METHOD("get_collision_layer"), &Box3DBody::get_collision_layer);
	ClassDB::bind_method(D_METHOD("set_collision_mask", "mask"), &Box3DBody::set_collision_mask);
	ClassDB::bind_method(D_METHOD("get_collision_mask"), &Box3DBody::get_collision_mask);
	ClassDB::bind_method(D_METHOD("set_collision_layer_high", "layer"), &Box3DBody::set_collision_layer_high);
	ClassDB::bind_method(D_METHOD("get_collision_layer_high"), &Box3DBody::get_collision_layer_high);
	ClassDB::bind_method(D_METHOD("set_collision_mask_high", "mask"), &Box3DBody::set_collision_mask_high);
	ClassDB::bind_method(D_METHOD("get_collision_mask_high"), &Box3DBody::get_collision_mask_high);
	ClassDB::bind_method(D_METHOD("set_collision_group", "group"), &Box3DBody::set_collision_group);
	ClassDB::bind_method(D_METHOD("get_collision_group"), &Box3DBody::get_collision_group);
	ClassDB::bind_method(D_METHOD("set_auto_visual", "enabled"), &Box3DBody::set_auto_visual);
	ClassDB::bind_method(D_METHOD("get_auto_visual"), &Box3DBody::get_auto_visual);

	ADD_PROPERTY(PropertyInfo(Variant::INT, "body_type", PROPERTY_HINT_ENUM, "Static,Kinematic,Dynamic"), "set_body_type", "get_body_type");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "shape_type", PROPERTY_HINT_ENUM, "Box,Sphere,Capsule,Cylinder,Cone,Hull,Mesh,Fit Mesh,Height Field"), "set_shape_type", "get_shape_type");
	ADD_PROPERTY(PropertyInfo(Variant::VECTOR3, "box_size"), "set_box_size", "get_box_size");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "sphere_radius", PROPERTY_HINT_RANGE, "0.01,100,0.01,or_greater"), "set_sphere_radius", "get_sphere_radius");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "capsule_radius", PROPERTY_HINT_RANGE, "0.01,100,0.01,or_greater"), "set_capsule_radius", "get_capsule_radius");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "capsule_height", PROPERTY_HINT_RANGE, "0.02,100,0.01,or_greater"), "set_capsule_height", "get_capsule_height");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "cylinder_sides", PROPERTY_HINT_RANGE, "3,64,1"), "set_cylinder_sides", "get_cylinder_sides");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "collision_mesh", PROPERTY_HINT_RESOURCE_TYPE, "Mesh"), "set_collision_mesh", "get_collision_mesh");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "auto_visual"), "set_auto_visual", "get_auto_visual");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "density", PROPERTY_HINT_RANGE, "0.01,100,0.01,or_greater"), "set_density", "get_density");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "friction", PROPERTY_HINT_RANGE, "0,1,0.01,or_greater"), "set_friction", "get_friction");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "restitution", PROPERTY_HINT_RANGE, "0,1,0.01"), "set_restitution", "get_restitution");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "rolling_resistance", PROPERTY_HINT_RANGE, "0,1,0.01"), "set_rolling_resistance", "get_rolling_resistance");
	ADD_PROPERTY(PropertyInfo(Variant::VECTOR3, "tangent_velocity"), "set_tangent_velocity", "get_tangent_velocity");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "user_material_id"), "set_user_material_id", "get_user_material_id");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "explosion_scale", PROPERTY_HINT_RANGE, "0,10,0.01,or_greater"), "set_explosion_scale", "get_explosion_scale");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "invoke_contact_creation"), "set_invoke_contact_creation", "get_invoke_contact_creation");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "speculative_contact"), "set_speculative_contact", "get_speculative_contact");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "baked_compound"), "set_baked_compound", "get_baked_compound");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "linear_damping", PROPERTY_HINT_RANGE, "0,10,0.01,or_greater"), "set_linear_damping", "get_linear_damping");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "angular_damping", PROPERTY_HINT_RANGE, "0,10,0.01,or_greater"), "set_angular_damping", "get_angular_damping");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "gravity_scale", PROPERTY_HINT_RANGE, "-10,10,0.01"), "set_gravity_scale", "get_gravity_scale");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "can_sleep"), "set_can_sleep", "get_can_sleep");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "sleep_threshold", PROPERTY_HINT_RANGE, "0,1,0.001,or_greater"), "set_sleep_threshold", "get_sleep_threshold");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "enabled"), "set_enabled", "get_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "contact_monitor"), "set_contact_monitor", "get_contact_monitor");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "sensor_events"), "set_sensor_events", "get_sensor_events");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "hit_events"), "set_hit_events", "get_hit_events");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "is_sensor"), "set_is_sensor", "get_is_sensor");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "debug_visualize"), "set_debug_visualize", "get_debug_visualize");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "continuous"), "set_continuous", "get_continuous");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "contact_recycling"), "set_contact_recycling", "get_contact_recycling");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "sync_node_transform"), "set_sync_node_transform", "get_sync_node_transform");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "allow_fast_rotation"), "set_allow_fast_rotation", "get_allow_fast_rotation");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "collision_layer", PROPERTY_HINT_LAYERS_3D_PHYSICS), "set_collision_layer", "get_collision_layer");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "collision_mask", PROPERTY_HINT_LAYERS_3D_PHYSICS), "set_collision_mask", "get_collision_mask");
	// Categories 33-64 of b3Filter, which Godot's 32-slot layer inspector cannot reach.
	ADD_PROPERTY(PropertyInfo(Variant::INT, "collision_layer_high", PROPERTY_HINT_LAYERS_3D_PHYSICS), "set_collision_layer_high", "get_collision_layer_high");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "collision_mask_high", PROPERTY_HINT_LAYERS_3D_PHYSICS), "set_collision_mask_high", "get_collision_mask_high");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "collision_group"), "set_collision_group", "get_collision_group");

	ADD_GROUP("Mesh Data", "mesh_");
	ADD_PROPERTY(PropertyInfo(Variant::PACKED_VECTOR3_ARRAY, "mesh_vertices"), "set_mesh_vertices", "get_mesh_vertices");
	ADD_PROPERTY(PropertyInfo(Variant::PACKED_INT32_ARRAY, "mesh_indices"), "set_mesh_indices", "get_mesh_indices");
	ADD_PROPERTY(PropertyInfo(Variant::PACKED_BYTE_ARRAY, "mesh_materials"), "set_mesh_materials", "get_mesh_materials");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "mesh_weld_tolerance", PROPERTY_HINT_RANGE, "0,1,0.0001,or_greater,suffix:m"), "set_mesh_weld_tolerance", "get_mesh_weld_tolerance");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "mesh_median_split"), "set_mesh_median_split", "get_mesh_median_split");

	ADD_GROUP("Height Field", "height_field_");
	ADD_PROPERTY(PropertyInfo(Variant::VECTOR2I, "height_field_size"), "set_height_field_size", "get_height_field_size");
	ADD_PROPERTY(PropertyInfo(Variant::VECTOR3, "height_field_scale", PROPERTY_HINT_NONE, "suffix:m"), "set_height_field_scale", "get_height_field_scale");
	ADD_PROPERTY(PropertyInfo(Variant::PACKED_FLOAT32_ARRAY, "height_field_heights"), "set_height_field_heights", "get_height_field_heights");
	ADD_PROPERTY(PropertyInfo(Variant::PACKED_BYTE_ARRAY, "height_field_materials"), "set_height_field_materials", "get_height_field_materials");
	ADD_PROPERTY(PropertyInfo(Variant::VECTOR2, "height_field_wave"), "set_height_field_wave", "get_height_field_wave");
	ADD_PROPERTY(PropertyInfo(Variant::VECTOR2, "height_field_height_range"), "set_height_field_height_range", "get_height_field_height_range");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "height_field_holes"), "set_height_field_holes", "get_height_field_holes");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "height_field_clockwise"), "set_height_field_clockwise", "get_height_field_clockwise");

	ADD_GROUP("Surface Materials", "surface_");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "surface_materials", PROPERTY_HINT_ARRAY_TYPE, "Dictionary"), "set_surface_materials", "get_surface_materials");

	ADD_GROUP("Axis Lock", "lock_");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "lock_linear_x"), "set_lock_linear_x", "get_lock_linear_x");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "lock_linear_y"), "set_lock_linear_y", "get_lock_linear_y");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "lock_linear_z"), "set_lock_linear_z", "get_lock_linear_z");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "lock_angular_x"), "set_lock_angular_x", "get_lock_angular_x");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "lock_angular_y"), "set_lock_angular_y", "get_lock_angular_y");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "lock_angular_z"), "set_lock_angular_z", "get_lock_angular_z");

	ADD_SIGNAL(MethodInfo("body_entered", PropertyInfo(Variant::OBJECT, "body", PROPERTY_HINT_RESOURCE_TYPE, "Box3DBody")));
	ADD_SIGNAL(MethodInfo("body_exited", PropertyInfo(Variant::OBJECT, "body", PROPERTY_HINT_RESOURCE_TYPE, "Box3DBody")));
	ADD_SIGNAL(MethodInfo("area_entered", PropertyInfo(Variant::OBJECT, "visitor", PROPERTY_HINT_RESOURCE_TYPE, "Box3DBody")));
	ADD_SIGNAL(MethodInfo("area_exited", PropertyInfo(Variant::OBJECT, "visitor", PROPERTY_HINT_RESOURCE_TYPE, "Box3DBody")));

	BIND_ENUM_CONSTANT(STATIC);
	BIND_ENUM_CONSTANT(KINEMATIC);
	BIND_ENUM_CONSTANT(DYNAMIC);
	BIND_ENUM_CONSTANT(BOX);
	BIND_ENUM_CONSTANT(SPHERE);
	BIND_ENUM_CONSTANT(CAPSULE);
	BIND_ENUM_CONSTANT(CYLINDER);
	BIND_ENUM_CONSTANT(CONE);
	BIND_ENUM_CONSTANT(HULL);
	BIND_ENUM_CONSTANT(MESH);
	BIND_ENUM_CONSTANT(FIT_MESH);
	BIND_ENUM_CONSTANT(HEIGHT_FIELD);
	BIND_CONSTANT(HEIGHT_FIELD_HOLE);
}
