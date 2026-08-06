// SPDX-FileCopyrightText: 2026 box3d-godot contributors
// SPDX-License-Identifier: MIT

#pragma once

#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/variant/aabb.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>

#include <box3d/box3d.h>

namespace godot {

class Box3DBody;
class Box3DWorld;

// One shape of a compound Box3DBody. Add these as children of a Box3DBody to
// give it multiple shapes at different local transforms. If a body has no
// Box3DCollisionShape children it falls back to its own shape_type.
class Box3DCollisionShape : public Node3D {
	GDCLASS(Box3DCollisionShape, Node3D)

public:
	enum ShapeType {
		BOX = 0,
		SPHERE = 1,
		CAPSULE = 2,
		CYLINDER = 3, // capsule_radius / capsule_height, tessellated by sides
		CONE = 4, // base radius capsule_radius, height capsule_height, apex up
	};

	// What the SOLVER holds, from b3Shape_GetType (box3d.h:845), in b3ShapeType's
	// own order (types.h:433-454). Distinct from ShapeType above, which is what
	// this node authors: BOX, CYLINDER and CONE all become GEOMETRY_HULL, and the
	// mesh / height field / compound entries only ever come back from a shape
	// this node did not build (a body's own shape, reached through a query or
	// event payload).
	enum GeometryType {
		GEOMETRY_NONE = -1, // no live shape
		GEOMETRY_CAPSULE = 0,
		GEOMETRY_COMPOUND = 1,
		GEOMETRY_HEIGHT_FIELD = 2,
		GEOMETRY_HULL = 3,
		GEOMETRY_MESH = 4,
		GEOMETRY_SPHERE = 5,
	};

	// Per-shape override for the three event enables Box3D keeps on a shape
	// (b3Shape_Enable{Contact,Sensor,Hit}Events, box3d.h:914-941). INHERIT is
	// the default and means "whatever the parent Box3DBody gives its shapes":
	// contact events follow the body's contact_monitor, sensor and hit events
	// are on. Anything else overrides it for this shape alone.
	enum EventMode {
		EVENT_INHERIT = 0,
		EVENT_ENABLED = 1,
		EVENT_DISABLED = 2,
	};

private:
	// The shape this node owns in the solver, handed back by Box3DBody when it
	// builds the compound. Null until then, and again after the body is
	// destroyed or rebuilt.
	b3ShapeId shape_id = b3_nullShapeId;
	Box3DBody *owner = nullptr;
	// The mesh blob a set_mesh() call handed to the solver. Box3D stores the
	// POINTER rather than copying (`shape->mesh.data = meshData`,
	// src/shape.c:1664, exactly as b3CreateMeshShape does at src/shape.c:156),
	// so the blob has to outlive the shape and this node owns it — the same
	// contract Box3DBody's own mesh_data and a baked compound's blob live
	// under. Freed when the shape goes (on_shape_destroyed), when another
	// set_mesh() replaces it, and in the destructor.
	b3MeshData *owned_mesh = nullptr;
	// Frees owned_mesh. Only safe once no live shape references it.
	void release_owned_mesh();

	ShapeType shape_type = BOX;
	Vector3 box_size = Vector3(1, 1, 1);
	double sphere_radius = 0.5;
	double capsule_radius = 0.5;
	double capsule_height = 2.0;
	int sides = 16; // hull tessellation for CYLINDER / CONE
	double density = 1.0;
	double friction = 0.6;
	double restitution = 0.0;
	// b3SurfaceMaterial extras, as on Box3DBody: rolling resistance applies to
	// spheres and capsules, tangent velocity is the conveyor drive in shape
	// local space.
	double rolling_resistance = 0.0;
	Vector3 tangent_velocity;
	// b3SurfaceMaterial.userMaterialId (types.h:414-416): not used by the
	// solver, but it rides along on query and hit-event results and reaches the
	// friction/restitution mixing callbacks, which get no other context.
	int64_t user_material_id = 0;
	// --- per-shape filter override (b3Shape_SetFilter, box3d.h:907-912) ---
	// Off by default: a child shape inherits the body's filter, which is what
	// every existing scene expects. Turning it on lets one limb of a ragdoll
	// differ from the rest.
	bool filter_override = false;
	uint32_t collision_layer = 1;
	uint32_t collision_mask = 0xFFFFFFFFu;
	// Categories 33-64, as on Box3DBody: b3Filter is 64 bits wide and Godot's
	// layer inspector is 32.
	uint32_t collision_layer_high = 0;
	uint32_t collision_mask_high = 0xFFFFFFFFu;
	int collision_group = 0;
	// b3Shape_SetFilter's invokeContacts argument. True recomputes every contact
	// on the next step, which upstream calls almost as expensive as recreating
	// the shape; without it a widened mask only takes effect for pairs that
	// happen to move afterwards.
	bool filter_invoke_contacts = true;
	// True only for the span of a NOTIFICATION_UNPARENTED rebuild: Godot still
	// lists this node among its old parent's children at that point, and a
	// shape must not be built for a child that is on its way out.
	bool leaving = false;
	// b3ShapeDef.enableCustomFiltering (types.h:485-486): lets a
	// Box3DContactRules table see this shape's pairs. Creation-time only —
	// upstream has no b3Shape_EnableCustomFiltering — so changing it rebuilds
	// the shape. Only ONE shape of a pair has to enable it
	// (src/broad_phase.c:284), and it gates sensor overlaps too
	// (src/sensor.c:135).
	bool custom_filtering = false;
	// b3ShapeDef.enablePreSolveEvents (types.h:505-507): lets a
	// Box3DContactRules one-way rule see this shape's contacts. Live, through
	// b3Shape_EnablePreSolveEvents (box3d.h:931). WARNING: src/solver.c:445-451
	// calls the world's pre-solve callback with no null check, so only turn
	// this on for a world that has a Box3DContactRules installed.
	bool pre_solve_events = false;
	EventMode contact_events = EVENT_INHERIT;
	EventMode sensor_events = EVENT_INHERIT;
	EventMode hit_events = EVENT_INHERIT;

	void notify_parent();
	// notify_parent(), but tries a live in-place resize of this shape first.
	void resize_or_notify();
	// b3Shape_IsValid plus a join of any in-flight async world step.
	bool shape_live() const;
	// Pushes the whole surface material onto a live shape. Returns false when
	// there is no live shape to push to.
	bool apply_surface_material();
	// Pushes this shape's own filter onto the live shape. No-op unless
	// filter_override is on.
	void apply_filter_override();

protected:
	static void _bind_methods();
	void _notification(int p_what);

public:
	~Box3DCollisionShape();

	// Called by Box3DBody as it builds and tears down the compound.
	void on_shape_created(b3ShapeId p_id, Box3DBody *p_owner);
	void on_shape_destroyed();
	b3ShapeId get_shape_id() const { return shape_id; }
	// Read by Box3DBody while it fills a b3ShapeDef for this shape, and by its
	// apply_filter(), which must not stomp a shape that carries its own.
	bool has_filter_override() const { return filter_override; }
	// True while this node is being unparented; Box3DBody skips such a child
	// when it walks its children to build shapes.
	bool is_leaving() const { return leaving; }
	b3Filter make_filter() const;
	// Resolves one EventMode against what the body would have given the shape.
	static bool resolve_event(EventMode p_mode, bool p_inherited) {
		return p_mode == EVENT_INHERIT ? p_inherited : p_mode == EVENT_ENABLED;
	}
	EventMode get_contact_event_mode() const { return contact_events; }
	EventMode get_sensor_event_mode() const { return sensor_events; }
	EventMode get_hit_event_mode() const { return hit_events; }
	// Read by Box3DBody::create_child_shape while it fills the b3ShapeDef.
	bool get_custom_filtering() const { return custom_filtering; }
	bool get_pre_solve_events() const { return pre_solve_events; }

	// Scripting API. All of these need a live shape, i.e. a body that has been
	// created in a world.
	bool is_shape_valid() const;
	bool is_sensor() const;
	AABB get_aabb() const; // world space, from the broad phase
	Vector3 get_closest_point(const Vector3 &p_target) const;
	Dictionary compute_mass_data() const; // keys: mass, center, inertia
	void set_shape_name(const String &p_name);
	String get_shape_name() const;
	// b3Shape_GetBody / b3Shape_GetWorld (box3d.h:847-851), resolved back to
	// the nodes behind them. Both are the answer Box3D holds, not this node's
	// cached parentage: a shape id that came out of a query or an event is
	// exactly what these are for.
	Box3DBody *get_body() const;
	Box3DWorld *get_world() const;

	// --- b3Shape_GetType and the per-geometry accessors (box3d.h:845-980) ---
	// Every reader is guarded by b3Shape_GetType, because the Get* family
	// asserts on a type mismatch (box3d.h:947-957); a mismatch returns an empty
	// Dictionary instead of tripping the assert.
	int get_geometry_type() const;
	Dictionary get_sphere() const; // keys: center, radius
	Dictionary get_capsule() const; // keys: center1, center2, radius
	// keys: points, center, aabb, volume, surface_area, inner_radius,
	// vertex_count, face_count. Points are the hull's own, in shape local space.
	Dictionary get_hull() const;
	// keys: scale, vertex_count, triangle_count, material_count. b3Mesh is a
	// (data, scale) pair (types.h:2222-2230); the triangle data itself stays
	// with whoever authored it.
	Dictionary get_mesh() const;
	// The Set* family retypes the shape in place and deliberately does NOT touch
	// the body's mass (box3d.h:959-980), so each takes an update_mass flag that
	// pays for b3Body_ApplyMassFromShapes. They also bypass this node's authored
	// shape_type / box_size / radius properties, which then no longer describe
	// the collider; a later rebuild rebuilds from the properties.
	void set_sphere(const Vector3 &p_center, double p_radius, bool p_update_mass);
	void set_capsule(const Vector3 &p_center1, const Vector3 &p_center2, double p_radius, bool p_update_mass);
	void set_hull(const PackedVector3Array &p_points, bool p_update_mass);
	// b3Shape_SetMesh (box3d.h:976-980): retypes this shape into a triangle
	// mesh built from raw vertices and indices, at p_scale. Winding is Box3D's
	// own (CCW by the right hand rule) and is passed through untouched, as
	// Box3DBody.mesh_indices is; Box3D's mesh collision is ONE-SIDED, so a
	// reversed triangle is not solid from the side you expect. Returns false,
	// having changed nothing, when the data does not describe a mesh.
	//
	// Unlike the three setters above, this one hands the solver a blob it keeps
	// a pointer to (src/shape.c:1664), so the node owns that blob from here on.
	// A mesh only generates contacts on a static body (or a sensor), which is
	// why this warns on anything else. p_update_mass defaults to FALSE here,
	// unlike the three setters above: a mesh has no volume, so recomputing the
	// body's mass from a lone mesh shape would leave it with none. Pass true
	// only when the body has other shapes to weigh.
	bool set_mesh(const PackedVector3Array &p_vertices, const PackedInt32Array &p_indices,
			const Vector3 &p_scale, bool p_update_mass);
	// Rescales the mesh this shape already holds, keeping its triangles. This
	// is the only route to changing a mesh collider's scale after creation:
	// P-024 bakes the node scale into the geometry, and b3Shape_SetMesh's scale
	// argument is the one place upstream lets it move. False if this shape is
	// not a mesh.
	bool set_mesh_scale(const Vector3 &p_scale);
	// b3Shape_RayCast: origin plus translation, hit point in world space. Keys:
	// hit, point, normal, fraction, triangle_index, child_index,
	// material_index, iterations. Note the hit position is "point" here, as it
	// is in Box3DWorld's contact_hit signal and in b3WorldCastOutput itself,
	// but Box3DWorld.raycast calls the same value "position" — see the board.
	Dictionary raycast(const Vector3 &p_origin, const Vector3 &p_translation) const;

	void set_shape_type(int p_type);
	int get_shape_type() const;
	void set_box_size(const Vector3 &p_size);
	Vector3 get_box_size() const;
	void set_sphere_radius(double p_radius);
	double get_sphere_radius() const;
	void set_capsule_radius(double p_radius);
	double get_capsule_radius() const;
	void set_capsule_height(double p_height);
	double get_capsule_height() const;
	void set_sides(int p_sides);
	int get_sides() const;
	void set_density(double p_density);
	double get_density() const;
	void set_friction(double p_friction);
	double get_friction() const;
	void set_restitution(double p_restitution);
	double get_restitution() const;
	void set_rolling_resistance(double p_resistance);
	double get_rolling_resistance() const;
	void set_tangent_velocity(const Vector3 &p_velocity);
	Vector3 get_tangent_velocity() const;
	void set_user_material_id(int64_t p_id);
	int64_t get_user_material_id() const;

	// --- per-shape filter (P-019) ---
	void set_filter_override(bool p_enabled);
	bool get_filter_override() const;
	void set_collision_layer(int p_layer);
	int get_collision_layer() const;
	void set_collision_mask(int p_mask);
	int get_collision_mask() const;
	void set_collision_layer_high(int p_layer);
	int get_collision_layer_high() const;
	void set_collision_mask_high(int p_mask);
	int get_collision_mask_high() const;
	void set_collision_group(int p_group);
	int get_collision_group() const;
	void set_filter_invoke_contacts(bool p_enabled);
	bool get_filter_invoke_contacts() const;
	// b3Shape_GetFilter: what the SOLVER holds for this shape, which is the
	// body's filter unless filter_override is on. Keys: layer, mask,
	// layer_high, mask_high, group.
	Dictionary get_filter() const;

	// --- per-shape event enables (P-019) ---
	void set_contact_events(int p_mode);
	int get_contact_events() const;
	void set_sensor_events(int p_mode);
	int get_sensor_events() const;
	void set_hit_events(int p_mode);
	int get_hit_events() const;
	// The live readings, straight from b3Shape_Are*EventsEnabled — the answer
	// after inheritance and after Box3D's own "ignored for sensors" rules.
	void set_custom_filtering(bool p_enabled);
	void set_pre_solve_events(bool p_enabled);
	bool are_contact_events_enabled() const;
	bool are_sensor_events_enabled() const;
	bool are_hit_events_enabled() const;
};

} // namespace godot

VARIANT_ENUM_CAST(godot::Box3DCollisionShape::ShapeType);
VARIANT_ENUM_CAST(godot::Box3DCollisionShape::GeometryType);
VARIANT_ENUM_CAST(godot::Box3DCollisionShape::EventMode);
