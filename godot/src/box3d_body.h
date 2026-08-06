// SPDX-FileCopyrightText: 2026 box3d-godot contributors
// SPDX-License-Identifier: MIT

#pragma once

#include <godot_cpp/classes/mesh.hpp>
#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/variant/aabb.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector2i.hpp>

#include <box3d/box3d.h>

#include <vector>

namespace godot {

class Box3DWorld;
class Box3DCollisionShape;
class MeshInstance3D;

// A rigid body simulated by the nearest Box3DWorld ancestor. The node's
// transform is driven by the simulation for dynamic bodies, and drives the
// simulation for kinematic bodies. Attach a MeshInstance3D child for visuals.
class Box3DBody : public Node3D {
	GDCLASS(Box3DBody, Node3D)

public:
	enum BodyType {
		STATIC = 0,
		KINEMATIC = 1,
		DYNAMIC = 2,
	};

	enum ShapeType {
		BOX = 0,
		SPHERE = 1,
		CAPSULE = 2,
		CYLINDER = 3,
		CONE = 4,
		HULL = 5,
		MESH = 6,
		FIT_MESH = 7, // box collider auto-sized to the child MeshInstance3D's bounds
		// b3CreateHeightFieldShape: a terrain grid in the XZ plane. Static
		// bodies only (box3d.h:823-829). The one shape that ignores the node's
		// scale: b3CreateHeightFieldShape takes neither a transform nor a
		// scale, and height_field_scale is upstream's own knob for it.
		HEIGHT_FIELD = 8,
	};

	// b3HeightFieldDef.materialIndices entry that marks a cell as a hole
	// (B3_HEIGHT_FIELD_HOLE, types.h:2274).
	enum { HEIGHT_FIELD_HOLE = 0xFF };

private:
	b3BodyId body_id = b3_nullBodyId;
	// A triangle-mesh shape references this data (Box3D does not copy it), so it
	// must outlive the shape; freed in destroy_body().
	b3MeshData *mesh_data = nullptr;
	// Same contract for a height-field shape (box3d.h:826-828): Box3D keeps a
	// reference, so this blob must outlive the shape. Freed in destroy_body().
	b3HeightFieldData *height_field_data = nullptr;
	// And again for a baked compound. Upstream documents no @warning for this
	// one, but b3CreateShape stores the pointer rather than copying
	// (src/shape.c:126), so the same rule applies. Freed in destroy_body().
	// The child hulls and meshes handed to b3CreateCompound are a different
	// matter: those really are copied into the blob (src/compound.c:585, :606,
	// deduplicated by content first), so they only have to survive the create
	// call.
	b3CompoundData *compound_data = nullptr;
	Box3DWorld *world = nullptr;

	BodyType body_type = DYNAMIC;
	ShapeType shape_type = BOX;
	// True once the node transform was synced after the body fell asleep, so
	// sleeping bodies cost nothing in the per-step sync loop.
	bool asleep_synced = false;
	// When false, sync_from_physics still records the render snapshots but
	// leaves the Godot node transform alone. Box3DMultiMeshRenderer turns
	// this off for its bodies: at tens of thousands of nodes, per-tick
	// set_global_transform plus the engine's own per-frame interpolation
	// bookkeeping costs more than the solver. Scripts reading such a body's
	// node position see its spawn pose.
	bool sync_node_transform = true;
	// The node's own scale, baked into the colliders at creation (Box3D bodies
	// carry no scale of their own, so it lives in the geometry). Cached because
	// sync_from_physics has to put it back on the node: the solver only reports
	// position and rotation. Changing the node scale later needs a rebuild.
	Vector3 node_scale = Vector3(1, 1, 1);
	bool node_scaled = false; // node_scale differs from one
	b3WorldTransform snap_prev = {}; // last two tick transforms, for render
	b3WorldTransform snap_curr = {}; // interpolation without node reads
	// Solver state mirrored at the last sync, so the world's debug draw can
	// read 16k bodies per refresh without one b3 lookup per field per body.
	bool snap_awake = false; // b3Body_IsAwake at the last sync_from_physics
	float debug_mass = 0.0f; // b3Body_GetMass, cached at (re)creation
	// b3Body_IsEnabled, cached at (re)creation and refreshed by set_enabled(),
	// the only other thing that can change it.
	bool debug_enabled = true;
	// Shape topology mirrors, cached at (re)creation: reading them live means
	// get_child_count()/get_child() engine calls through the extension
	// boundary for every body every refresh. Any shape change (own setters or
	// a child Box3DCollisionShape's request_rebuild) recreates the body and
	// recomputes these.
	bool debug_has_child_shapes = false;
	float debug_min_ext = 0.5f;
	float debug_max_ext = 0.5f;
	Vector3 box_size = Vector3(1, 1, 1); // full extents
	double sphere_radius = 0.5;
	double capsule_radius = 0.5;
	double capsule_height = 2.0; // total height, including the two caps
	// Cylinder and cone reuse capsule_radius / capsule_height. Sides sets their
	// tessellation (they are built as convex hulls).
	int cylinder_sides = 16;
	Ref<Mesh> collision_mesh; // convex hull is built from this mesh's vertices
	// --- shape_type MESH, built from raw data instead of a Godot Mesh ---
	// b3MeshDef.vertices / .indices (types.h:2069-2073). When mesh_vertices is
	// non-empty it wins over collision_mesh and any child MeshInstance3D.
	// Indices are handed to Box3D unchanged (upstream's CCW winding); the Godot
	// Mesh path flips winding because Godot's face order is the opposite one.
	PackedVector3Array mesh_vertices;
	PackedInt32Array mesh_indices;
	// b3MeshDef.materialIndices: one per triangle, indexing surface_materials
	// (types.h:2076-2079).
	PackedByteArray mesh_materials;
	// b3MeshDef.weldTolerance / .weldVertices (types.h:2081-2094); 0 disables
	// welding. 0.001 mirrors what the Godot Mesh path has always used.
	double mesh_weld_tolerance = 0.001;
	// b3MeshDef.useMedianSplit: faster build, better for grid-like meshes.
	bool mesh_median_split = false;
	// --- shape_type HEIGHT_FIELD (b3HeightFieldDef, types.h:2239-2272) ---
	// (countX, countZ): grid LINE counts, not cell counts. Minimum 2 each.
	Vector2i height_field_size = Vector2i(16, 16);
	// b3HeightFieldDef.scale; every component must be positive.
	Vector3 height_field_scale = Vector3(1, 1, 1);
	// Row-major grid point heights, count = countX * countZ, index
	// z * countX + x (src/height_field.c:1336-1343). Empty means the field is
	// generated by b3CreateGrid / b3CreateWave instead.
	PackedFloat32Array height_field_heights;
	// One material index per cell, count = (countX - 1) * (countZ - 1).
	// HEIGHT_FIELD_HOLE (0xFF) punches a hole. Explicit-heights path only.
	PackedByteArray height_field_materials;
	// b3CreateWave frequencies: x along the X axis (columnFrequency), y along
	// the Z axis (rowFrequency). Zero means a flat b3CreateGrid.
	Vector2 height_field_wave;
	// b3HeightFieldDef.globalMinimumHeight / .globalMaximumHeight, the
	// quantization range every height is clamped to. Two height fields that
	// must line up need the same range. min >= max means "derive from the
	// height data" (explicit-heights path only).
	Vector2 height_field_height_range;
	bool height_field_holes = false; // b3CreateGrid / b3CreateWave makeHoles
	bool height_field_clockwise = false; // b3HeightFieldDef.clockwiseWinding
	// b3ShapeDef.materials / .materialCount (types.h:462-468): per-triangle
	// materials for mesh and height field shapes, indexed by mesh_materials /
	// height_field_materials. One Dictionary per material; see the .cpp for the
	// keys. Empty means the shape uses baseMaterial alone.
	Array surface_materials;
	double density = 1.0;
	double friction = 0.6;
	double restitution = 0.0;
	// b3SurfaceMaterial extras: rolling resistance only applies to spheres and
	// capsules, tangent velocity is the conveyor-belt drive, expressed in the
	// shape's local space and projected onto the contact surface.
	double rolling_resistance = 0.0;
	Vector3 tangent_velocity;
	// b3SurfaceMaterial.userMaterialId (types.h:414-416) for the body's OWN
	// shape: not used by the solver, but it rides on query and hit-event
	// results, reaches the friction/restitution mixing callbacks, and is what a
	// Box3DContactRules table keys its rules on — so a plain body needs it as
	// much as a Box3DCollisionShape child does. A non-empty surface_materials
	// replaces baseMaterial wholesale (src/shape.c:202-213) and carries its own.
	int64_t user_material_id = 0;
	// b3ShapeDef.explosionScale (types.h:479): per-shape multiplier on the
	// impulse b3World_Explode applies. 1 is upstream's default.
	double explosion_scale = 1.0;
	// b3ShapeDef.invokeContactCreation (types.h:507-512): with this off a new
	// shape does not scan for contacts on the next step, which is upstream's
	// documented fix for slow static-body spawning in big levels. Ignored for
	// dynamic and kinematic shapes.
	bool invoke_contact_creation = true;
	// b3ShapeDef.enableSpeculativeContact (types.h:519-522): off trades
	// continuous collision under rotation for fewer ghost collisions.
	bool speculative_contact = true;
	// b3CreateBakedCompoundShape (box3d.h:831-834): collapses every
	// Box3DCollisionShape child into ONE baked shape with a single broad-phase
	// proxy, instead of one runtime shape per child. Static bodies only, and
	// never a sensor — Box3D asserts both (src/shape.c:122-127).
	bool baked_compound = false;
	double linear_damping = 0.0;
	double angular_damping = 0.05;
	double gravity_scale = 1.0;
	// Mirrors b3BodyDef.sleepThreshold; upstream's default is
	// 0.05 * b3GetLengthUnitsPerMeter() (src/types.c:37), i.e. 0.05 m/s at the
	// default length unit.
	double sleep_threshold = 0.05;
	bool can_sleep = true; // b3BodyDef.enableSleep / b3Body_EnableSleep
	bool enabled = true; // b3BodyDef.isEnabled / b3Body_Enable|Disable
	bool contact_monitor = false; // b3ShapeDef.enableContactEvents
	// b3ShapeDef.enableSensorEvents / .enableHitEvents (types.h:496-505), the
	// other two of the three enables Box3D keeps per shape. Both were hardcoded
	// true at every creation site (P-009); they stay true by default, so no
	// existing scene moves, and both push live through
	// b3Shape_Enable{Sensor,Hit}Events. Named for the events rather than
	// mirrored on contact_monitor's Godot-idiom name, because that is what the
	// per-shape overrides on Box3DCollisionShape are called.
	// sensor_events is what makes a body VISIBLE to other bodies' sensors —
	// and, on a body that IS a sensor, what keeps that sensor alive: box3d.h:914
	// says "ignored for sensors", but src/sensor.c:208-215 drops every overlap
	// of a sensor whose own shape lacks the flag ("this sensor is dropping all
	// overlaps because it has been disabled"). is_sensor with sensor_events off
	// is therefore a dead trigger, which is what the configuration warning is
	// for. hit_events feed the world's contact_hit signal and the debug draw's
	// impact flash.
	bool sensor_events = true;
	bool hit_events = true;
	bool is_sensor = false;
	bool debug_visualize = true; // false = no shell in the world's debug draw
	int debug_hit_frames = 0; // >0: recent hit event, debug draw flashes lime
	bool continuous = false; // continuous collision (bullet)
	// Upstream stabilizer for big stacks: matching contacts are reused between
	// steps while a pair barely moves, keeping warm-start impulses intact.
	bool contact_recycling = true; // mirrors b3BodyDef.enableContactRecycling
	bool allow_fast_rotation = false;
	bool lock_linear_x = false;
	bool lock_linear_y = false;
	bool lock_linear_z = false;
	bool lock_angular_x = false;
	bool lock_angular_y = false;
	bool lock_angular_z = false;
	uint32_t collision_layer = 1;
	uint32_t collision_mask = 0xFFFFFFFFu;
	// b3Filter.categoryBits / maskBits are 64 bits wide; Godot's layer inspector
	// is 32. These carry categories 33-64 (the high dword of each field).
	uint32_t collision_layer_high = 0;
	uint32_t collision_mask_high = 0xFFFFFFFFu;
	// b3Filter.groupIndex: non-zero wins over the mask bits entirely — negative
	// means never collide with the same group, positive means always.
	int collision_group = 0;
	// When true and no MeshInstance3D child is present, a MeshInstance3D is
	// generated at runtime whose mesh mirrors the collision shape (box/sphere/
	// capsule/cylinder/cone), so box_size/sphere_radius/etc. drive both the
	// collider and the visual from one place. Default false for backward
	// compatibility with existing scenes.
	bool auto_visual = false;
	// The node auto_visual generates; nullptr when there is none (auto_visual
	// is off, or the body already has its own MeshInstance3D child).
	MeshInstance3D *auto_mesh_instance = nullptr;

	Box3DWorld *find_world();
	// b3Body_IsValid plus a join of any in-flight async world step.
	bool body_live() const;
	// Builds every shape this body should have from its current properties: the
	// baked compound, the runtime compound over the Box3DCollisionShape
	// children, or the body's own shape_type shape. Assumes a live b3 body that
	// currently has no shapes, and refreshes the debug caches on the way out.
	void build_shapes();
	// Replaces every shape on a live body WITHOUT destroying the body (P-010).
	// The b3 body id survives, and with it the velocity, the sleep state, the
	// solver pose, the attached joints, the body name and every b3BodyDef
	// property; only what belonged to the old shapes goes — their contacts and
	// warm-start impulses, and any set_mass_data override, which upstream drops
	// on any shape change anyway (box3d.h:638-639).
	//
	// This is the fallback for the shape-def fields upstream gives no live
	// setter for: isSensor (src/shape.c:236-248 assigns sensorIndex only inside
	// b3CreateShapeInternal), explosionScale, invokeContactCreation,
	// enableSpeculativeContact, and re-authored mesh / height-field geometry.
	// Returns false when there is no live body, in which case nothing is due:
	// the next create_in_world() reads the same properties.
	//
	// One deliberate difference from the destroy-and-recreate it replaced: the
	// body is NOT moved to the node's current transform, because it is not
	// re-created. Use teleport() to move a body.
	bool recreate_shapes();
	void apply_motion_locks();
	// The body's shape ids, straight from b3Body_GetShapes. Empty when the body
	// is not live. The ids are only valid until the next shape change.
	std::vector<b3ShapeId> own_shape_ids() const;
	// The contact filter this body's shapes are created with.
	b3Filter make_filter() const;
	// Pushes the current filter onto every shape of a live body (child shapes
	// inherit the body's filter), so layer/mask/group changes need no rebuild.
	void apply_filter();
	// Pushes the body-level surface material onto every shape of a live body.
	// Returns false when it cannot: the body is not live, or it is a compound,
	// whose Box3DCollisionShape children carry their own materials.
	bool apply_surface_material();
	// Pushes the body-level density onto the shapes it owns and recomputes the
	// mass. No-op on a runtime compound, whose children carry their own.
	void apply_density();
	// Pushes the body's three event answers onto every shape it owns, through
	// b3Shape_Enable{Contact,Sensor,Hit}Events (box3d.h:914-941). A child shape
	// whose own EventMode is not INHERIT keeps its answer. Returns false when
	// there is no shape to push to.
	bool apply_shape_events();
	// Resizes the body's OWN shape in place through the b3Shape_Set* family
	// instead of building a new shape (P-010). Returns false when it cannot —
	// a compound, a mesh/height field/hull shape, or no live body — and the
	// caller then falls back to recreate_shapes().
	bool resize_own_shape();
	// resize_own_shape() if it can, recreate_shapes() if it cannot. This is
	// what every shape-dimension setter calls.
	void resize_or_rebuild();
	void create_child_shape(Box3DCollisionShape *p_shape, const Transform3D &p_body_inv);

public:
	// Resizes ONE compound child's geometry in place, so a Box3DCollisionShape
	// dimension setter no longer rebuilds the whole body (P-010). Returns false
	// when it cannot, and the child then falls back to request_rebuild().
	// The placement math here mirrors create_child_shape() exactly; the two must
	// be changed together.
	bool resize_child_shape(Box3DCollisionShape *p_shape);

private:
	// Bakes every Box3DCollisionShape child into one b3CompoundData and attaches
	// it as a single shape. Returns false (having created nothing) when the
	// children describe no bakeable geometry, so the caller can fall back to the
	// runtime compound.
	bool create_baked_compound(const Transform3D &p_body_inv);
	// Mesh used for Hull/Mesh/FitMesh colliders: an explicit collision_mesh (at
	// identity), else the first child MeshInstance3D's mesh (at its local
	// transform). Returns false if neither is available.
	bool resolve_collision_mesh(Ref<Mesh> &r_mesh, Transform3D &r_local);
	// Builds the b3HeightFieldData for the current height_field_* properties.
	// Returns nullptr (after a warning) if they do not describe a legal field.
	// The caller owns the result and must b3DestroyHeightField it.
	b3HeightFieldData *build_height_field() const;
	// b3ShapeDef.materials backing store for one create call: surface_materials
	// converted to b3SurfaceMaterial. Box3D clones the array (src/shape.c:202-213),
	// so it only has to outlive the b3Create*Shape call.
	std::vector<b3SurfaceMaterial> build_surface_materials() const;
	// Creates/updates/removes auto_mesh_instance to match auto_visual and the
	// current shape_type/size. No-op in the editor (runtime feature only).
	void update_auto_visual();

protected:
	static void _bind_methods();
	void _notification(int p_what);

public:
	// Editor-side sanity checks on property combinations that compile but do
	// nothing in the solver.
	PackedStringArray _get_configuration_warnings() const override;

	Box3DBody();
	~Box3DBody();

	// Internal, called by the owning world / node lifecycle.
	void create_in_world();
	void destroy_body();
	// Called by child Box3DCollisionShape nodes when their own geometry or
	// parentage changes. Rebuilds the shapes, never the body.
	void request_rebuild();
	// Joins any in-flight async world step. Child Box3DCollisionShape nodes call
	// this before touching the b3 API through their own shape id.
	void join_world_step() const;
	void sync_to_physics(double p_delta);
	void sync_from_physics();
	// The move-event form of sync_from_physics: takes the transform the world
	// was just handed by b3World_GetBodyEvents instead of asking Box3D for it
	// again. Box3DWorld::sync_bodies_from_move_events() can call this in place
	// of sync_from_physics() — see the board; the world half is not mine.
	void sync_from_move_event(const b3WorldTransform &p_transform, bool p_fell_asleep);
	bool is_body_valid() const;
	// Live solver state, for the world's state-colored debug draw.
	bool is_awake_now() const;
	bool is_enabled_now() const;
	float debug_min_extent() const;
	float debug_max_extent() const;
	// Hit-event flash: the world marks qualifying impacts, the debug draw
	// shows them lime, upstream's "had time of impact" look. Upstream's flag
	// lasts exactly one step; two frames keeps the flash visible at 60 Hz.
	void debug_hit_mark() { debug_hit_frames = 2; }
	void debug_hit_decay() {
		if (debug_hit_frames > 0) {
			--debug_hit_frames;
		}
	}
	bool debug_hit_active() const { return debug_hit_frames > 0; }
	b3BodyId get_body_id() const { return body_id; }
	// Previous/current tick transforms, kept by sync_from_physics for
	// Box3DMultiMeshRenderer to interpolate between at render rate.
	void get_render_snapshots(b3WorldTransform &r_prev, b3WorldTransform &r_curr) const {
		r_prev = snap_prev;
		r_curr = snap_curr;
	}
	// Cached solver state for the debug draw's per-refresh scan (no b3 calls).
	// snap_awake is only maintained for DYNAMIC bodies (sync_from_physics skips
	// the rest); the debug draw queries b3 directly for kinematic bodies.
	bool get_snap_awake() const { return snap_awake; }
	const b3WorldTransform &get_snap_curr() const { return snap_curr; }
	const b3WorldTransform &get_snap_prev() const { return snap_prev; }
	float get_cached_mass() const { return debug_mass; }
	bool get_cached_enabled() const { return debug_enabled; }
	bool has_cached_child_shapes() const { return debug_has_child_shapes; }
	float get_cached_min_extent() const { return debug_min_ext; }
	float get_cached_max_extent() const { return debug_max_ext; }
	// The node scale that was BAKED into this body's collider at creation.
	// b3WorldTransform carries no scale, so the debug shells have to reapply it
	// themselves; reading it from here rather than from get_global_transform()
	// keeps the refresh free of a per-body engine call and guarantees the shell
	// matches the geometry actually in the solver, not the node's current scale.
	bool is_node_scaled() const { return node_scaled; }
	const Vector3 &get_node_scale() const { return node_scale; }

	// Called by the world when it dispatches contact / sensor events.
	void emit_contact_begin(Box3DBody *p_other);
	void emit_contact_end(Box3DBody *p_other);
	void emit_area_begin(Box3DBody *p_visitor);
	void emit_area_end(Box3DBody *p_visitor);

	// Scripting API.
	void apply_central_force(const Vector3 &p_force);
	void apply_central_impulse(const Vector3 &p_impulse);
	void apply_torque(const Vector3 &p_torque);
	// Point of application is a WORLD point, as upstream takes it — unlike
	// Godot's RigidBody3D, whose "position" argument is an offset from the
	// body origin.
	void apply_force_at_point(const Vector3 &p_force, const Vector3 &p_point);
	void apply_impulse_at_point(const Vector3 &p_impulse, const Vector3 &p_point);
	void apply_angular_impulse(const Vector3 &p_impulse);
	// The four b3Body space conversions (box3d.h:530-544). They read the
	// SOLVER's body-origin frame, which is not the same as Node3D's to_local /
	// to_global in two cases the binding creates: a body whose node scale is
	// baked into its collider (Box3D's frame has no scale), and one with
	// sync_node_transform off, whose node pose is frozen at spawn.
	Vector3 get_world_point(const Vector3 &p_local_point) const;
	Vector3 get_local_point(const Vector3 &p_world_point) const;
	Vector3 get_world_vector(const Vector3 &p_local_vector) const;
	Vector3 get_local_vector(const Vector3 &p_world_vector) const;
	Vector3 get_point_velocity(const Vector3 &p_world_point) const;
	Vector3 get_local_point_velocity(const Vector3 &p_local_point) const;
	void set_awake(bool p_awake);
	void set_linear_velocity(const Vector3 &p_velocity);
	Vector3 get_linear_velocity() const;
	void set_angular_velocity(const Vector3 &p_velocity);
	Vector3 get_angular_velocity() const;
	double get_mass() const;
	double get_inverse_mass() const;
	Vector3 get_center_of_mass() const; // world space
	Vector3 get_local_center_of_mass() const;
	// Rotational inertia about the center of mass, as a Basis whose columns are
	// b3Matrix3's cx / cy / cz.
	Basis get_inertia_tensor() const;
	Basis get_inverse_inertia_tensor() const; // world space, inverted
	// Overrides the density-derived mass properties. Upstream drops the override
	// whenever a shape is added or removed or the body type changes.
	void set_mass_data(double p_mass, const Vector3 &p_local_center, const Basis &p_inertia);
	Dictionary get_mass_data() const; // keys: mass, center, inertia
	void apply_mass_from_shapes(); // recompute from the shapes, dropping any override
	// World AABB of every attached shape. May not contain the body origin, and
	// is empty and centered on the origin when the body has no shapes.
	AABB get_aabb() const;
	Vector3 get_closest_point(const Vector3 &p_target) const;
	double get_closest_distance(const Vector3 &p_target) const;
	// --- per-body queries (P-018, box3d.h:765-780) ---
	// Each takes an OPTIONAL hypothetical pose for the body: pass an identity
	// Transform3D to use where the body actually is. That is the whole point of
	// the family — "would this fit if I moved there" without touching the world
	// or disturbing the simulation.
	//
	// Each also takes both halves of the query filter, exactly as the
	// Box3DWorld queries do: filtering is TWO-WAY (src/shape.h:151-155), so
	// `collision_mask` is what the query looks for (b3QueryFilter.maskBits) and
	// `collision_layer` is what the query IS (b3QueryFilter.categoryBits) —
	// which is how a shape gets to ignore one kind of query and answer another.
	// Both default to b3DefaultQueryFilter's every-bit value (types.h:13-14)
	// and both are 64 bits wide, so they reach the categories Box3DBody exposes
	// as collision_layer_high / collision_mask_high.
	// Keys: hit, position, normal, fraction, shape, triangle_index,
	// user_material, iterations.
	Dictionary cast_ray(const Vector3 &p_from, const Vector3 &p_to, const Transform3D &p_body_xform,
			uint64_t p_mask = B3_DEFAULT_MASK_BITS, uint64_t p_layer = B3_DEFAULT_CATEGORY_BITS) const;
	// Sweeps an axis-aligned box of FULL size p_size (Godot convention, as
	// Box3DWorld.shape_cast_box takes it) from p_from to p_to.
	Dictionary cast_box(const Vector3 &p_from, const Vector3 &p_to, const Vector3 &p_size, const Transform3D &p_body_xform,
			uint64_t p_mask = B3_DEFAULT_MASK_BITS, uint64_t p_layer = B3_DEFAULT_CATEGORY_BITS) const;
	// True when a box of FULL size p_size centered at p_center overlaps this
	// body at the given pose.
	bool overlaps_box(const Vector3 &p_center, const Vector3 &p_size, const Transform3D &p_body_xform,
			uint64_t p_mask = B3_DEFAULT_MASK_BITS, uint64_t p_layer = B3_DEFAULT_CATEGORY_BITS) const;
	int get_shape_count() const;
	int get_joint_count() const;
	// --- introspection back into the scene tree (P-016, box3d.h:736-763) ---
	// The Box3DCollisionShape nodes behind this body's shapes, from
	// b3Body_GetShapes and each shape's userData. A body's OWN shape_type shape
	// has no node and is skipped, so this can be shorter than get_shape_count()
	// — and empty on a plain non-compound body. A baked compound is one shape
	// with many authors and has no node either (P-022).
	Array get_shape_nodes() const;
	// b3Shape_GetName for every shape this body owns, in b3Body_GetShapes
	// order. The one way to observe the name a body's OWN shape carries, since
	// that shape has no Box3DCollisionShape node to ask.
	PackedStringArray get_shape_names() const;
	// The Box3DJoint nodes attached to this body, from b3Body_GetJoints and
	// each joint's userData.
	Array get_joints() const;
	// The Box3DWorld node simulating this body, confirmed through
	// b3Body_GetWorld rather than just handed back from the node's own cache.
	Box3DWorld *get_world() const;
	// What this body is touching right now, without waiting for a contact event
	// edge. One Dictionary per touching contact; see the .cpp for the keys.
	Array get_contacts() const;
	Array get_touching_bodies() const; // unique Box3DBody nodes from get_contacts
	// Bodies currently overlapping this body's sensor shapes. Empty unless the
	// body is a sensor.
	Array get_overlapping_bodies() const;
	// Projected-area drag and lift against the shape's relative velocity. The
	// speed cap is required for stability (upstream suggests 10 m/s or less).
	// Only sphere, capsule and hull shapes respond.
	void apply_wind(const Vector3 &p_wind, double p_drag, double p_lift, double p_max_speed);
	void set_body_name(const String &p_name);
	String get_body_name() const;
	void teleport(const Transform3D &p_xform);

	// Properties.
	void set_body_type(int p_type);
	int get_body_type() const;
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
	void set_cylinder_sides(int p_sides);
	int get_cylinder_sides() const;
	void set_collision_mesh(const Ref<Mesh> &p_mesh);
	Ref<Mesh> get_collision_mesh() const;
	void set_mesh_vertices(const PackedVector3Array &p_vertices);
	PackedVector3Array get_mesh_vertices() const;
	void set_mesh_indices(const PackedInt32Array &p_indices);
	PackedInt32Array get_mesh_indices() const;
	void set_mesh_materials(const PackedByteArray &p_materials);
	PackedByteArray get_mesh_materials() const;
	void set_mesh_weld_tolerance(double p_tolerance);
	double get_mesh_weld_tolerance() const;
	void set_mesh_median_split(bool p_enabled);
	bool get_mesh_median_split() const;
	void set_surface_materials(const Array &p_materials);
	Array get_surface_materials() const;
	// Live per-triangle materials of the body's own mesh / height field shape
	// (b3Shape_GetMeshMaterialCount / GetMeshSurfaceMaterial / SetMeshMaterial).
	int get_mesh_material_count() const;
	Dictionary get_mesh_material(int p_index) const;
	void set_mesh_material(int p_index, const Dictionary &p_material);
	void set_height_field_size(const Vector2i &p_size);
	Vector2i get_height_field_size() const;
	void set_height_field_scale(const Vector3 &p_scale);
	Vector3 get_height_field_scale() const;
	void set_height_field_heights(const PackedFloat32Array &p_heights);
	PackedFloat32Array get_height_field_heights() const;
	void set_height_field_materials(const PackedByteArray &p_materials);
	PackedByteArray get_height_field_materials() const;
	void set_height_field_wave(const Vector2 &p_frequencies);
	Vector2 get_height_field_wave() const;
	void set_height_field_height_range(const Vector2 &p_range);
	Vector2 get_height_field_height_range() const;
	void set_height_field_holes(bool p_enabled);
	bool get_height_field_holes() const;
	void set_height_field_clockwise(bool p_enabled);
	bool get_height_field_clockwise() const;
	// Span of the field in body space. Its corner sits at the body origin and
	// it grows along +X / +Z, because b3CreateHeightFieldShape takes no local
	// transform — offset the body by -0.5 * this to center it.
	Vector3 get_height_field_extent() const;
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
	void set_explosion_scale(double p_scale);
	double get_explosion_scale() const;
	void set_invoke_contact_creation(bool p_enabled);
	bool get_invoke_contact_creation() const;
	void set_speculative_contact(bool p_enabled);
	bool get_speculative_contact() const;
	void set_baked_compound(bool p_enabled);
	bool get_baked_compound() const;
	// What the baked compound actually holds, from b3CompoundData's own counters.
	// Empty unless this body is carrying a baked compound. Keys: capsule_count,
	// hull_count, mesh_count, sphere_count, shared_hull_count, shared_mesh_count,
	// material_count, byte_count.
	Dictionary get_compound_info() const;
	void set_linear_damping(double p_damping);
	double get_linear_damping() const;
	void set_angular_damping(double p_damping);
	double get_angular_damping() const;
	void set_gravity_scale(double p_scale);
	double get_gravity_scale() const;
	void set_can_sleep(bool p_enabled);
	bool get_can_sleep() const;
	void set_sleep_threshold(double p_threshold);
	double get_sleep_threshold() const;
	void set_enabled(bool p_enabled);
	bool get_enabled() const;
	void set_contact_monitor(bool p_enabled);
	bool get_contact_monitor() const;
	void set_sensor_events(bool p_enabled);
	bool get_sensor_events() const;
	void set_hit_events(bool p_enabled);
	bool get_hit_events() const;
	void set_is_sensor(bool p_sensor);
	bool get_is_sensor() const;
	void set_debug_visualize(bool p_enabled);
	bool get_debug_visualize() const;
	void set_continuous(bool p_enabled);
	bool get_continuous() const;
	void set_contact_recycling(bool p_enabled);
	bool get_contact_recycling() const;
	void set_sync_node_transform(bool p_enabled);
	bool get_sync_node_transform() const;
	void set_allow_fast_rotation(bool p_enabled);
	bool get_allow_fast_rotation() const;
	void set_lock_linear_x(bool p_v);
	bool get_lock_linear_x() const;
	void set_lock_linear_y(bool p_v);
	bool get_lock_linear_y() const;
	void set_lock_linear_z(bool p_v);
	bool get_lock_linear_z() const;
	void set_lock_angular_x(bool p_v);
	bool get_lock_angular_x() const;
	void set_lock_angular_y(bool p_v);
	bool get_lock_angular_y() const;
	void set_lock_angular_z(bool p_v);
	bool get_lock_angular_z() const;
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
	void set_auto_visual(bool p_enabled);
	bool get_auto_visual() const;
};

} // namespace godot

VARIANT_ENUM_CAST(godot::Box3DBody::BodyType);
VARIANT_ENUM_CAST(godot::Box3DBody::ShapeType);
