class_name RigNative
extends RefCounted

## Rig (SPEC A) -> live native-physics scene.
##
## The extractor turns an authored Box3D sample into a backend-neutral Rig;
## this turns a Rig into RigidBody3D / StaticBody3D / AnimatableBody3D nodes
## with CollisionShape3D children and Joint3D constraints, so the identical
## scenario can be stepped by GodotPhysics3D or Jolt and put next to Box3D.
##
## FAIRNESS IS THE POINT. Most of this file exists to delete differences that
## are accidents of the API rather than properties of the solver:
##
##   mass       Godot has no density anywhere and no shape-volume API, so mass
##              is integrated here from the shape set (r6 section 4).
##   inertia    GodotPhysics approximates capsule, cylinder, convex-hull and
##              concave inertia from the shape AABB -- its own source says
##              "use bad AABB approximation" -- while Jolt is exact. Both
##              honour an explicit RigidBody3D.inertia plus a custom centre of
##              mass, so every dynamic body gets one, computed analytically.
##   materials  Box3D materials are per shape, Godot's are per body.
##   filtering  Box3D ANDs layer/mask, Godot ORs. Solved for, not copied.
##
## What cannot be removed becomes a warning string. Those are drawn on screen
## beside the run, so they are written for a viewer, not for a log.
##
## Gravity is NOT set here: it lives on the space, not on any node. Call
## apply_world_settings() with the space RID after build().
##
## Everything is static; the builder holds no state between calls.

# --- Tunables ---------------------------------------------------------------

## Godot needs a non-zero report cap before body_entered / body_exited fire at
## all, where Box3D only needs the flag. Small enough not to tax the 64
## contact-monitored pegs in the contacts sample.
const CONTACT_REPORTS := 8

## How many names one warning line spells out before it summarises the rest.
## A 5050-body scenario must not produce a 5050-name string.
const NAME_CAP := 8

## Godot exposes 32 collision layers, which is also the budget for the
## synthesized layer bits below.
const MAX_LAYER_BITS := 32

## Off-diagonal inertia above this fraction of the trace is called out: Godot
## stores only a diagonal, so such a body's principal axes cannot be matched.
const PRODUCT_INERTIA_WARN := 0.05


# --- Public -----------------------------------------------------------------

## Build `rig` under `parent`. Returns
##   { "bodies": Array[PhysicsBody3D], "joints": Array[Joint3D],
##     "warnings": Array[String] }
##
## `bodies` is index-aligned with rig.bodies (Body.id indexes it), because the
## joints resolve their endpoints through those indices. `joints` is dense:
## kinds with no native form are dropped, not nulled, and each surviving joint
## node keeps the authored Joint.name so a caller can find it again.
static func build(rig: Dictionary, parent: Node3D) -> Dictionary:
	var out_bodies: Array[PhysicsBody3D] = []
	var out_joints: Array[Joint3D] = []
	var ctx := {
		"warn": {},          # reason String -> Array[String] of subject names
		"notes": {},         # ordered set of standalone lines
		"materials": {},     # "friction|restitution" -> PhysicsMaterial
		"hulls": {},         # PackedVector3Array -> cached mass properties
		"frictions": {},     # value set, for the combine-rule note
		"restitutions": {},  # value set, ditto
	}
	if parent == null:
		var refused: Array[String] = ["No parent node was given; nothing was built."]
		return {"bodies": out_bodies, "joints": out_joints, "warnings": refused}

	var bodies: Array = rig.get("bodies", [])
	var filters := _plan_filters(bodies, ctx)

	for i in bodies.size():
		var b: Dictionary = bodies[i]
		var node := _build_body(b, filters[i], ctx)
		node.name = _safe_name(String(b.get("name", "")), "Body%d" % i)
		parent.add_child(node)
		out_bodies.append(node)

	_build_joints(rig, parent, out_bodies, out_joints, ctx)
	_combine_rule_notes(ctx)
	return {"bodies": out_bodies, "joints": out_joints,
			"warnings": _collect_warnings(ctx)}


## Per-world gravity has no native node equivalent, and 30 of the 32 samples
## set it (car -10, gyro_torque zero). Both servers route a SPACE rid through
## area_set_param to that space's default area, which is where the project's
## default_gravity lands too, so this overrides exactly that.
static func apply_world_settings(rig: Dictionary, space: RID) -> void:
	if not space.is_valid():
		return
	var g: Vector3 = rig.get("gravity", Vector3(0, -9.8, 0))
	var magnitude := g.length()
	PhysicsServer3D.area_set_param(space,
			PhysicsServer3D.AREA_PARAM_GRAVITY, magnitude)
	# A zero-gravity rig has no meaningful direction; leave the vector alone
	# rather than feeding the server a zero-length axis.
	if magnitude > 0.0:
		PhysicsServer3D.area_set_param(space,
				PhysicsServer3D.AREA_PARAM_GRAVITY_VECTOR, g / magnitude)
	PhysicsServer3D.area_set_param(space,
			PhysicsServer3D.AREA_PARAM_GRAVITY_IS_POINT, false)


# --- Bodies -----------------------------------------------------------------

static func _build_body(b: Dictionary, filter: Array, ctx: Dictionary) -> PhysicsBody3D:
	var body_name := String(b.get("name", "body"))
	var kind := String(b.get("type", "dynamic"))
	var shapes: Array = b.get("shapes", [])

	var node: PhysicsBody3D
	match kind:
		"static":
			node = StaticBody3D.new()
		"kinematic":
			var anim := AnimatableBody3D.new()
			# Box3D drives kinematic bodies with b3Body_SetTargetTransform,
			# i.e. it derives a velocity from the transform delta and lets that
			# velocity shove dynamics. sync_to_physics is the same contract.
			anim.sync_to_physics = true
			node = anim
		_:
			node = RigidBody3D.new()

	# Mass properties are needed for the material choice as well as for the
	# body's mass, so integrate every shape exactly once.
	var props: Array = []
	for sh: Dictionary in shapes:
		props.append(_shape_props(sh, body_name, ctx))

	for i in shapes.size():
		var s: Dictionary = shapes[i]
		var shape := _make_shape(s, body_name, ctx)
		if shape == null:
			continue
		var cs := CollisionShape3D.new()
		cs.shape = shape
		# A Box3D shape frame is rigid (position plus quaternion); the port
		# never reads a scale off the node, so neither do we. This also keeps
		# Godot from warning about scaled collision shapes.
		var xf: Transform3D = s.get("transform", Transform3D())
		cs.transform = Transform3D(xf.basis.orthonormalized(), xf.origin)
		node.add_child(cs)
		if kind == "dynamic" and String(s.get("kind", "")) == "mesh":
			_warn(ctx, "Triangle-mesh collider on a dynamic body: "
					+ "ConcavePolygonShape3D is documented static-only and will "
					+ "tunnel or jitter (Box3D warns about this case too)", body_name)

	# Visuals reuse the Mesh and Material resources the Box3D scene already
	# owns. Sharing is mandatory: a 5050-body scenario must not allocate 5050
	# meshes just to look at them.
	for vis: Dictionary in b.get("visuals", []):
		var mesh: Mesh = vis.get("mesh")
		if mesh == null:
			continue
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.transform = vis.get("transform", Transform3D())
		var mat: Material = vis.get("material")
		if mat != null:
			mi.material_override = mat
		mi.layers = int(vis.get("layers", 1))
		node.add_child(mi)

	node.collision_layer = int(filter[0])
	node.collision_mask = int(filter[1])
	node.transform = b.get("transform", Transform3D())

	# physics_material_override is declared on RigidBody3D and StaticBody3D
	# separately, not on their common base, so it takes a branch to set.
	var body_mat := _body_material(b, props, ctx)
	if node is RigidBody3D:
		(node as RigidBody3D).physics_material_override = body_mat
	elif node is StaticBody3D:
		# AnimatableBody3D inherits this from StaticBody3D.
		(node as StaticBody3D).physics_material_override = body_mat

	if bool(b.get("is_sensor", false)):
		# A Box3D sensor reports overlaps without generating contacts. The
		# native equivalent is Area3D, which is not a PhysicsBody3D and so
		# cannot stand in here. Keep the node so body indices stay aligned, but
		# take it out of the collision world instead of letting it push things.
		node.collision_layer = 0
		node.collision_mask = 0
		_warn(ctx, "Sensor body has no PhysicsBody3D equivalent (Godot needs an "
				+ "Area3D); built as a non-colliding placeholder", body_name)

	if node is RigidBody3D:
		_apply_dynamics(node as RigidBody3D, b, props, ctx)
	return node


static func _apply_dynamics(rb: RigidBody3D, b: Dictionary, props: Array,
		ctx: Dictionary) -> void:
	var body_name := String(b.get("name", "body"))

	# Box3D damps the body and nothing else. Godot's default COMBINE mode adds
	# the space's damp on top, which would quietly drag every sample.
	rb.linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	rb.linear_damp = float(b.get("linear_damping", 0.0))
	rb.angular_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	rb.angular_damp = float(b.get("angular_damping", 0.05))
	rb.gravity_scale = float(b.get("gravity_scale", 1.0))
	rb.continuous_cd = bool(b.get("continuous", false))
	if bool(b.get("contact_monitor", false)):
		rb.contact_monitor = true
		rb.max_contacts_reported = CONTACT_REPORTS

	# Generated bodies carry these directly (the gyro tops spawn spinning);
	# authored bodies get them from the sample's rig_body_motion().
	if b.has("linear_velocity"):
		rb.linear_velocity = b["linear_velocity"]
	if b.has("angular_velocity"):
		rb.angular_velocity = b["angular_velocity"]

	# Both engines apply their locks in the body's own axes, so these are 1:1.
	var lin: Array = b.get("lock_linear", [])
	var ang: Array = b.get("lock_angular", [])
	if lin.size() == 3:
		rb.axis_lock_linear_x = bool(lin[0])
		rb.axis_lock_linear_y = bool(lin[1])
		rb.axis_lock_linear_z = bool(lin[2])
	if ang.size() == 3:
		rb.axis_lock_angular_x = bool(ang[0])
		rb.axis_lock_angular_y = bool(ang[1])
		rb.axis_lock_angular_z = bool(ang[2])

	var mp := _mass_props(b.get("shapes", []), props)
	var mass: float = mp["mass"]
	if mass <= 0.0:
		_warn(ctx, "No mass could be integrated from this body's shapes; left "
				+ "at Godot's default 1 kg with automatic inertia, so it will "
				+ "not weigh what Box3D says it weighs", body_name)
		return
	rb.mass = mass
	# Setting all three explicitly is the only way GodotPhysics, Jolt and Box3D
	# agree: GodotPhysics then skips its AABB estimate, and Jolt overwrites its
	# exact diagonal whenever any inertia component is positive.
	rb.center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	rb.center_of_mass = mp["com"]
	rb.inertia = mp["inertia"]
	if float(mp["product_ratio"]) > PRODUCT_INERTIA_WARN:
		_warn(ctx, "Body inertia is not diagonal in its own axes and Godot only "
				+ "stores a diagonal, so the products of inertia are lost and it "
				+ "will tumble differently", body_name)


# --- Materials --------------------------------------------------------------

## Godot has ONE PhysicsMaterial per body where Box3D has one per shape, so a
## compound has to collapse. The largest shape wins, on the argument that it
## owns most of the contact area. Materials are shared between bodies with the
## same numbers, for the same reason meshes are.
static func _body_material(b: Dictionary, props: Array, ctx: Dictionary) -> PhysicsMaterial:
	var shapes: Array = b.get("shapes", [])
	if shapes.is_empty():
		return null

	var first: Dictionary = shapes[0]
	var pick := 0
	var best := -1.0
	var mixed := false
	var f0 := float(first.get("friction", 0.6))
	var r0 := float(first.get("restitution", 0.0))
	for i in shapes.size():
		var s: Dictionary = shapes[i]
		if not is_equal_approx(float(s.get("friction", 0.6)), f0) \
				or not is_equal_approx(float(s.get("restitution", 0.0)), r0):
			mixed = true
		var vol := 0.0
		if i < props.size():
			var pr: Array = props[i]
			vol = float(pr[0])
		if vol > best:
			best = vol
			pick = i
	if mixed:
		_warn(ctx, "Compound body materials collapsed to the largest shape's "
				+ "values: Box3D carries friction and restitution per shape, "
				+ "Godot only per body", String(b.get("name", "body")))

	var dominant: Dictionary = shapes[pick]
	var friction := float(dominant.get("friction", 0.6))
	var restitution := float(dominant.get("restitution", 0.0))
	ctx["frictions"][friction] = true
	ctx["restitutions"][restitution] = true

	var key := "%.6f|%.6f" % [friction, restitution]
	var cache: Dictionary = ctx["materials"]
	if not cache.has(key):
		var m := PhysicsMaterial.new()
		# PhysicsMaterial defaults to friction 1.0 / bounce 0.0 while Box3D's
		# shape defaults are 0.6 / 0.0, so both are always written out; and
		# rough/absorbent are sign flips on those values, so both are pinned.
		m.friction = friction
		m.bounce = restitution
		m.rough = false
		m.absorbent = false
		cache[key] = m
	return cache[key]


static func _combine_rule_notes(ctx: Dictionary) -> void:
	var restitutions: Dictionary = ctx["restitutions"]
	var bouncy := false
	for r in restitutions:
		if float(r) > 0.0:
			bouncy = true
			break
	if bouncy:
		_note(ctx, "Restitution combines differently and cannot be matched: "
				+ "Box3D takes max(a, b), both native engines take "
				+ "clamp(a + b, 0, 1), so equal-restitution pairs bounce about "
				+ "twice as hard here.")
	var frictions: Dictionary = ctx["frictions"]
	if frictions.size() > 1:
		var mix := "This rig mixes %d friction values, so unlike pairs " % frictions.size()
		_note(ctx, "Friction combines differently: Box3D takes sqrt(fA * fB), "
				+ "both native engines take min(fA, fB). " + mix
				+ "grip differently (equal pairs still agree).")


# --- Collision filtering ----------------------------------------------------

## Box3D collides a pair iff (A.layer & B.mask) AND (B.layer & A.mask); Godot
## collides iff EITHER side matches. Copying the numbers across silently
## changes what touches what, and the samples that use layers -- wrecking's
## rope links (layer 4, mask 0), marble_run's guard walls (layer 2),
## motion_locks' inert puck (layer 0, mask 0), ragdoll bones (layer 1, mask 1)
## -- are exactly the cases where the two rules disagree.
##
## So the layer set is solved for rather than copied. With layer == mask on
## every body Godot's OR rule collapses to "the two layer sets intersect", and
## reproducing an arbitrary collision matrix under that rule is an edge-clique
## cover: one bit per clique of mutually-colliding filter classes. That is
## exact when it fits, and it cannot express a class that collides with others
## but not with itself, so the result is verified and the failures named.
##
## Returns one [layer, mask] pair per body, index-aligned with `bodies`.
static func _plan_filters(bodies: Array, ctx: Dictionary) -> Array:
	var class_of := {}
	var layers: Array[int] = []
	var masks: Array[int] = []
	var per_body: Array[int] = []
	for body: Dictionary in bodies:
		var lay := int(body.get("collision_layer", 1))
		var msk := int(body.get("collision_mask", 0xFFFFFFFF))
		var key := "%d|%d" % [lay, msk]
		if not class_of.has(key):
			class_of[key] = layers.size()
			layers.append(lay)
			masks.append(msk)
		per_body.append(int(class_of[key]))

	var k := layers.size()
	var want := []
	for i in k:
		var row := []
		for j in k:
			row.append((layers[i] & masks[j]) != 0 and (layers[j] & masks[i]) != 0)
		want.append(row)

	# When a straight copy already behaves, keep the authored numbers: they are
	# what any query mask elsewhere in the harness expects to see.
	var raw_ok := true
	for i in k:
		for j in range(i, k):
			var or_rule := (layers[i] & masks[j]) != 0 or (layers[j] & masks[i]) != 0
			if or_rule != bool(want[i][j]):
				raw_ok = false
	if raw_ok:
		var kept := []
		for c in per_body:
			kept.append([layers[c], masks[c]])
		return kept

	var bits: Array[int] = []
	bits.resize(k)
	bits.fill(0)
	var covered := []
	for i in k:
		var row := []
		row.resize(k)
		row.fill(false)
		covered.append(row)

	var next_bit := 0
	for i in k:
		for j in range(i, k):
			if not bool(want[i][j]) or bool(covered[i][j]):
				continue
			# Sharing a bit forces self-collision on every member, so a class
			# that must not collide with itself can never join a clique.
			if not (bool(want[i][i]) and bool(want[j][j])):
				continue
			if next_bit >= MAX_LAYER_BITS:
				continue
			var members: Array[int] = [i]
			if j != i:
				members.append(j)
			for c in k:
				if c in members or not bool(want[c][c]):
					continue
				var fits := true
				for mem in members:
					if not bool(want[c][mem]):
						fits = false
						break
				if fits:
					members.append(c)
			var bit := 1 << next_bit
			next_bit += 1
			for a in members:
				bits[a] |= bit
				for b2 in members:
					covered[a][b2] = true

	var broken := {}
	for i in k:
		for j in range(i, k):
			if (((bits[i] & bits[j]) != 0) != bool(want[i][j])):
				broken[i] = true
				broken[j] = true

	var head := "Collision layers rewritten to %d synthesized bit(s) across " % next_bit
	_note(ctx, head + "%d layer/mask combinations" % k
			+ ", so Godot's OR filtering reproduces Box3D's AND filtering. The "
			+ "authored layer numbers no longer mean anything on this side.")

	var out := []
	for idx in per_body.size():
		var c: int = per_body[idx]
		out.append([bits[c], bits[c]])
		if broken.has(c):
			var bd: Dictionary = bodies[idx]
			_warn(ctx, "Collision filtering could not be reproduced: Box3D lets "
					+ "each body veto a pair on its own, and no Godot layer/mask "
					+ "assignment reproduces that here, so this body collides "
					+ "with the wrong set", String(bd.get("name", "body")))
	return out


# --- Shapes -----------------------------------------------------------------

static func _make_shape(s: Dictionary, body_name: String, ctx: Dictionary) -> Shape3D:
	var kind := String(s.get("kind", "box"))
	match kind:
		"box":
			var box := BoxShape3D.new()
			box.size = s.get("size", Vector3.ONE)
			return box
		"sphere":
			var sph := SphereShape3D.new()
			sph.radius = float(s.get("radius", 0.5))
			return sph
		"capsule":
			var cap := CapsuleShape3D.new()
			# Both heights are tip to tip, so the numbers transfer directly.
			# Radius first: CapsuleShape3D.set_radius GROWS height to keep the
			# invariant, while set_height would shrink an oversized radius.
			cap.radius = float(s.get("radius", 0.5))
			cap.height = maxf(float(s.get("height", 2.0)), 2.0 * cap.radius)
			return cap
		"hull":
			var pts: PackedVector3Array = s.get("points", PackedVector3Array())
			if pts.size() < 4:
				_warn(ctx, "Convex hull collider dropped: fewer than 4 points", body_name)
				return null
			var hull := ConvexPolygonShape3D.new()
			hull.points = pts
			return hull
		"mesh":
			var faces: PackedVector3Array = s.get("faces", PackedVector3Array())
			if faces.size() < 3:
				_warn(ctx, "Triangle-mesh collider dropped: no triangles", body_name)
				return null
			var soup := ConcavePolygonShape3D.new()
			soup.set_faces(faces)
			return soup
	_warn(ctx, "Collider of unknown kind '%s' dropped" % kind, body_name)
	return null


# --- Mass and inertia -------------------------------------------------------
#
# Godot exposes no volume or mass-properties API on Shape3D, so all of this is
# integrated here. Every tensor below is a Basis used as a plain symmetric 3x3
# matrix; because it is symmetric, Godot's rows-versus-columns convention for
# Basis.x/y/z does not change any result.

## Total mass, centre of mass and body-local inertia diagonal for one body.
## `props` holds the per-shape result of _shape_props, in shape order.
static func _mass_props(shapes: Array, props: Array) -> Dictionary:
	var mass := 0.0
	var moment := Vector3.ZERO                 # sum of m_i * c_i
	var about_origin := _t_zero()              # inertia about the body origin
	for i in shapes.size():
		if i >= props.size():
			break
		var p: Array = props[i]
		var vol := float(p[0])
		if vol <= 0.0:
			continue
		var s: Dictionary = shapes[i]
		var density := float(s.get("density", 1.0))
		var m := density * vol
		var xf: Transform3D = s.get("transform", Transform3D())
		var rot := xf.basis.orthonormalized()
		var local_com: Vector3 = p[1]
		var local_t: Basis = p[2]
		var c := xf.origin + rot * local_com
		# Rotate the shape's own tensor into body axes, scale unit density up
		# to the real one, then parallel-axis it out to the body origin.
		var rotated := rot * local_t * rot.transposed()
		about_origin = _t_add(about_origin, _t_add(rotated * density, _t_shift(m, c)))
		mass += m
		moment += c * m

	if mass <= 0.0:
		return {"mass": 0.0, "com": Vector3.ZERO, "inertia": Vector3.ZERO,
				"product_ratio": 0.0}

	var com := moment / mass
	var about_com := _t_add(about_origin, _t_shift(mass, com) * -1.0)
	var diag := Vector3(maxf(about_com.x.x, 0.0), maxf(about_com.y.y, 0.0),
			maxf(about_com.z.z, 0.0))
	var trace := diag.x + diag.y + diag.z
	var product := maxf(maxf(absf(about_com.x.y), absf(about_com.x.z)),
			absf(about_com.y.z))
	return {"mass": mass, "com": com, "inertia": diag,
			"product_ratio": product / maxf(trace, 1e-9)}


## Unit-density mass properties of one shape in the SHAPE's own frame, as
## [volume, centroid, inertia tensor about that centroid].
static func _shape_props(s: Dictionary, body_name: String, ctx: Dictionary) -> Array:
	match String(s.get("kind", "box")):
		"box":
			# Solid cuboid about its centre: I = m/12 * (a^2 + b^2) per axis.
			var sz: Vector3 = s.get("size", Vector3.ONE)
			var vb := sz.x * sz.y * sz.z
			var d := Vector3(sz.y * sz.y + sz.z * sz.z,
					sz.x * sz.x + sz.z * sz.z,
					sz.x * sz.x + sz.y * sz.y) * (vb / 12.0)
			return [vb, Vector3.ZERO, _t_diag(d)]
		"sphere":
			# Solid sphere: I = 2/5 m r^2 about every axis.
			var r := float(s.get("radius", 0.5))
			var vs := 4.0 / 3.0 * PI * r * r * r
			return [vs, Vector3.ZERO, _t_diag(Vector3.ONE * (0.4 * vs * r * r))]
		"capsule":
			# Godot's CapsuleShape3D.height and Box3D's capsule_height are both
			# TOTAL, caps included, so the cylindrical section is h - 2r.
			# Cylinder about its centre, plus two hemispheres pushed out to
			# +-hc/2. A hemisphere has I = 2/5 m r^2 about its symmetry axis and
			# 83/320 m r^2 about a transverse axis through its own centroid,
			# which sits 3r/8 from the flat face. At hc = 0 this collapses back
			# to 2/5 m r^2 on all three axes, i.e. a sphere.
			var cr := float(s.get("radius", 0.5))
			var ch := float(s.get("height", 2.0))
			var hc := maxf(ch - 2.0 * cr, 0.0)
			var vcyl := PI * cr * cr * hc
			var vcap := 4.0 / 3.0 * PI * cr * cr * cr    # both caps = one sphere
			var iy := 0.5 * vcyl * cr * cr + 0.4 * vcap * cr * cr
			var off := hc * 0.5 + 0.375 * cr
			var ix := vcyl * (3.0 * cr * cr + hc * hc) / 12.0 \
					+ vcap * (83.0 / 320.0 * cr * cr + off * off)
			return [vcyl + vcap, Vector3.ZERO, _t_diag(Vector3(ix, iy, ix))]
		"hull":
			var pts: PackedVector3Array = s.get("points", PackedVector3Array())
			var cache: Dictionary = ctx["hulls"]
			if cache.has(pts):
				return cache[pts]
			var hp := _hull_props(pts)
			if hp.is_empty():
				_warn(ctx, "Convex hull volume could not be integrated "
						+ "(degenerate or coplanar points); its bounding box was "
						+ "used for mass and inertia instead", body_name)
				hp = _aabb_props(pts)
			cache[pts] = hp
			return hp
		"mesh":
			var faces: PackedVector3Array = s.get("faces", PackedVector3Array())
			var sp := _soup_props(faces)
			if sp.is_empty():
				return _aabb_props(faces)
			return sp
	return [0.0, Vector3.ZERO, _t_zero()]


## Volume, centroid and unit-density inertia of a convex point set.
##
## A Delaunay tetrahedralisation of a point set fills exactly its convex hull,
## which is the shape both Box3D and ConvexPolygonShape3D build from the same
## points, so summing the cells is the signed-tetrahedron sum with the
## triangles supplied for us.
static func _hull_props(points: PackedVector3Array) -> Array:
	if points.size() < 4:
		return []
	var tets := Geometry3D.tetrahedralize_delaunay(points)
	if tets.is_empty():
		return []
	var vol := 0.0
	var moment := Vector3.ZERO
	var cov := _t_zero()
	for t in range(0, tets.size() - 3, 4):
		var w0 := points[tets[t]]
		var w1 := points[tets[t + 1]]
		var w2 := points[tets[t + 2]]
		var w3 := points[tets[t + 3]]
		# The cells are disjoint but carry no orientation guarantee, so each
		# contributes its unsigned volume.
		var v := absf((w1 - w0).cross(w2 - w0).dot(w3 - w0)) / 6.0
		if v <= 0.0:
			continue
		vol += v
		moment += (w0 + w1 + w2 + w3) * (v * 0.25)
		cov = _t_add(cov, _tet_covariance(w0, w1, w2, w3, v))
	return _from_covariance(vol, moment, cov)


## Same integral over a closed triangle soup, each triangle closed to the
## origin. The signs cancel over a consistently wound closed surface, and a
## negative total just means the winding points inward.
static func _soup_props(faces: PackedVector3Array) -> Array:
	if faces.size() < 12:
		return []
	var vol := 0.0
	var moment := Vector3.ZERO
	var cov := _t_zero()
	for t in range(0, faces.size() - 2, 3):
		var w1 := faces[t]
		var w2 := faces[t + 1]
		var w3 := faces[t + 2]
		var v := w1.cross(w2).dot(w3) / 6.0
		vol += v
		moment += (w1 + w2 + w3) * (v * 0.25)
		cov = _t_add(cov, _tet_covariance(Vector3.ZERO, w1, w2, w3, v))
	if vol < 0.0:
		vol = -vol
		moment = -moment
		cov = cov * -1.0
	return _from_covariance(vol, moment, cov)


## Last resort when a point set will not integrate: the axis-aligned box that
## contains it. Wrong, but bounded, and always flagged by the caller.
static func _aabb_props(points: PackedVector3Array) -> Array:
	if points.is_empty():
		return [0.0, Vector3.ZERO, _t_zero()]
	var lo := points[0]
	var hi := points[0]
	for p in points:
		lo = lo.min(p)
		hi = hi.max(p)
	var sz := hi - lo
	var v := sz.x * sz.y * sz.z
	var d := Vector3(sz.y * sz.y + sz.z * sz.z,
			sz.x * sz.x + sz.z * sz.z,
			sz.x * sz.x + sz.y * sz.y) * (v / 12.0)
	return [v, (lo + hi) * 0.5, _t_diag(d)]


## Second-moment integral of one tetrahedron w0..w3 of volume `v`:
##     integral(x x^T) dV = v/20 * (S S^T + sum_i w_i w_i^T),  S = sum_i w_i,
## which follows from integral(lambda_i lambda_j) dV / V = (1 + delta_ij) / 20
## in barycentric coordinates.
static func _tet_covariance(w0: Vector3, w1: Vector3, w2: Vector3, w3: Vector3,
		v: float) -> Basis:
	var s := w0 + w1 + w2 + w3
	var acc := _t_add(_outer(s), _outer(w0))
	acc = _t_add(acc, _outer(w1))
	acc = _t_add(acc, _outer(w2))
	acc = _t_add(acc, _outer(w3))
	return acc * (v / 20.0)


## Turn an accumulated covariance about the origin into
## [volume, centroid, inertia about the centroid], at unit density. The
## inertia about the origin is trace(C) * Id - C; the shift to the centroid is
## the usual parallel-axis term.
static func _from_covariance(vol: float, moment: Vector3, cov: Basis) -> Array:
	if vol <= 0.0:
		return []
	var com := moment / vol
	var trace := cov.x.x + cov.y.y + cov.z.z
	var about_origin := _t_add(_t_diag(Vector3.ONE * trace), cov * -1.0)
	return [vol, com, _t_add(about_origin, _t_shift(vol, com) * -1.0)]


# --- Symmetric 3x3 helpers --------------------------------------------------

static func _t_zero() -> Basis:
	return Basis(Vector3.ZERO, Vector3.ZERO, Vector3.ZERO)


static func _t_diag(d: Vector3) -> Basis:
	return Basis(Vector3(d.x, 0, 0), Vector3(0, d.y, 0), Vector3(0, 0, d.z))


static func _t_add(a: Basis, b: Basis) -> Basis:
	return Basis(a.x + b.x, a.y + b.y, a.z + b.z)


## v v^T. Only ever used with a single vector, which is why every tensor here
## stays symmetric and the Basis row/column question stays moot.
static func _outer(v: Vector3) -> Basis:
	return Basis(v * v.x, v * v.y, v * v.z)


## The parallel-axis term for mass `m` displaced by `d`: m * (|d|^2 Id - d d^T).
static func _t_shift(m: float, d: Vector3) -> Basis:
	return _t_add(_t_diag(Vector3.ONE * (m * d.length_squared())),
			_outer(d) * -m)


# --- Joints -----------------------------------------------------------------

static func _build_joints(rig: Dictionary, parent: Node3D,
		out_bodies: Array[PhysicsBody3D], out_joints: Array[Joint3D],
		ctx: Dictionary) -> void:
	var joints: Array = rig.get("joints", [])
	if joints.is_empty():
		return

	# A Box3D joint with an empty body slot anchors to an implicit static body
	# at the joint's own origin. Godot's "empty node path means the world" is
	# not the same thing -- Jolt even has a joints/world_node project setting
	# choosing which side the world stands in for -- so pin to a real, shared,
	# non-colliding static body instead and let each joint's own frame place it.
	var anchor: StaticBody3D = null

	for jd: Dictionary in joints:
		var kind := String(jd.get("kind", ""))
		var jname := String(jd.get("name", kind))
		var ia := int(jd.get("body_a", -1))
		var ib := int(jd.get("body_b", -1))
		if ia < 0 and ib < 0:
			_warn(ctx, "Joint dropped: neither end is attached to a body", jname)
			continue
		if ia >= out_bodies.size() or ib >= out_bodies.size():
			_warn(ctx, "Joint dropped: it names a body that is not in the rig", jname)
			continue

		var params: Dictionary = jd.get("params", {})
		var xf: Transform3D = jd.get("transform", Transform3D())
		var node := _make_joint(kind, params, xf, jname, ia >= 0 and ib >= 0, ctx)
		if node == null:
			continue
		node.name = _safe_name(jname, "Joint")
		# Box3D's collide_connected is Godot's flag inverted.
		node.exclude_nodes_from_collision = not bool(params.get("collide_connected", false))
		parent.add_child(node)

		if (ia < 0 or ib < 0) and anchor == null:
			anchor = StaticBody3D.new()
			anchor.name = "RigWorldAnchor"
			anchor.collision_layer = 0
			anchor.collision_mask = 0
			parent.add_child(anchor)
		var end_a: Node = anchor if ia < 0 else out_bodies[ia]
		var end_b: Node = anchor if ib < 0 else out_bodies[ib]
		node.node_a = node.get_path_to(end_a)
		node.node_b = node.get_path_to(end_b)
		out_joints.append(node)


static func _make_joint(kind: String, p: Dictionary, xf: Transform3D,
		jname: String, linked: bool, ctx: Dictionary) -> Joint3D:
	match kind:
		"ball":
			return _make_ball(p, xf, jname, ctx)
		"hinge":
			return _make_hinge(p, xf, jname, ctx)
		"slider":
			return _make_slider(p, xf)
		"distance":
			return _make_distance(p, xf, jname, linked, ctx)
		"fixed":
			return _make_fixed(p, xf, jname, ctx)
		"wheel":
			_warn(ctx, "Wheel joint dropped: Godot has no wheel constraint. Its "
					+ "suspension spring, travel limits, spin motor and steering "
					+ "spring are one Box3D constraint with no native counterpart "
					+ "(VehicleBody3D is a raycast model, not a jointed one)", jname)
		"parallel":
			_warn(ctx, "Parallel joint dropped: no native constraint holds two "
					+ "bodies' axes parallel through a spring", jname)
		"motor":
			_warn(ctx, "Motor joint dropped: no native constraint drives one body "
					+ "to another's pose with capped force and torque", jname)
		_:
			_warn(ctx, "Joint of unknown kind '%s' dropped" % kind, jname)
	return null


static func _make_ball(p: Dictionary, xf: Transform3D, jname: String,
		ctx: Dictionary) -> Joint3D:
	if bool(p.get("spring_enabled", false)):
		_warn(ctx, "Ball joint spring dropped: ConeTwistJoint3D has softness and "
				+ "bias, not a hertz/damping spring, and Jolt ignores those "
				+ "parameters outright. Anything posed by its springs will sag", jname)
	if float(p.get("friction_torque", 0.0)) > 0.0:
		_warn(ctx, "Ball joint friction torque dropped: no native joint has dry "
				+ "friction", jname)

	var cone := bool(p.get("cone_limit_enabled", false))
	var twist := bool(p.get("twist_limit_enabled", false))
	if not cone and not twist:
		var pin := PinJoint3D.new()
		pin.transform = xf
		return pin

	var ct := ConeTwistJoint3D.new()
	# Box3D twists about the joint node's local Z; ConeTwistJoint3D twists
	# about its local X. Rotating the frame -90 degrees about Y puts the node's
	# Z where Godot looks for the twist axis, so the cone opens the same way.
	ct.transform = Transform3D(xf.basis * Basis(Vector3.UP, -PI / 2.0), xf.origin)
	ct.set_param(ConeTwistJoint3D.PARAM_SWING_SPAN,
			float(p.get("cone_angle", 0.5)) if cone else PI)
	if twist:
		var lo := float(p.get("twist_lower", 0.0))
		var hi := float(p.get("twist_upper", 0.0))
		if not is_equal_approx(lo, -hi):
			_warn(ctx, "Ball joint twist limits are asymmetric but Godot only has "
					+ "one symmetric twist span, so the wider side was used and "
					+ "the joint twists further one way than authored", jname)
		ct.set_param(ConeTwistJoint3D.PARAM_TWIST_SPAN, maxf(absf(lo), absf(hi)))
	else:
		ct.set_param(ConeTwistJoint3D.PARAM_TWIST_SPAN, PI)
	return ct


static func _make_hinge(p: Dictionary, xf: Transform3D, jname: String,
		ctx: Dictionary) -> Joint3D:
	# Both engines hinge about the frame's local Z, so the transform carries
	# straight across.
	var h := HingeJoint3D.new()
	h.transform = xf
	if bool(p.get("limit_enabled", false)):
		h.set_flag(HingeJoint3D.FLAG_USE_LIMIT, true)
		h.set_param(HingeJoint3D.PARAM_LIMIT_LOWER, float(p.get("lower_limit", 0.0)))
		h.set_param(HingeJoint3D.PARAM_LIMIT_UPPER, float(p.get("upper_limit", 0.0)))
	if bool(p.get("motor_enabled", false)):
		h.set_flag(HingeJoint3D.FLAG_ENABLE_MOTOR, true)
		h.set_param(HingeJoint3D.PARAM_MOTOR_TARGET_VELOCITY,
				float(p.get("motor_speed", 0.0)))
		# Box3D caps the motor by TORQUE; Godot caps the IMPULSE it may spend in
		# one step. Integrating the torque over a tick is the conversion, and it
		# only holds while the tick rate does.
		var delta := 1.0 / maxf(float(Engine.physics_ticks_per_second), 1.0)
		h.set_param(HingeJoint3D.PARAM_MOTOR_MAX_IMPULSE,
				float(p.get("max_motor_torque", 0.0)) * delta)
	if bool(p.get("spring_enabled", false)):
		_warn(ctx, "Hinge joint spring dropped: HingeJoint3D has no spring, and "
				+ "Jolt ignores its softness parameters", jname)
	return h


static func _make_slider(p: Dictionary, xf: Transform3D) -> Joint3D:
	# SliderJoint3D has limits but NO motor at all, and the samples drive their
	# sliders, so the general joint is the only option: lock everything, then
	# hand back the X axis that Box3D's prismatic joint slides along.
	var g := Generic6DOFJoint3D.new()
	g.transform = xf
	_lock_6dof(g)
	g.set_flag_x(Generic6DOFJoint3D.FLAG_ENABLE_LINEAR_LIMIT,
			bool(p.get("limit_enabled", false)))
	g.set_param_x(Generic6DOFJoint3D.PARAM_LINEAR_LOWER_LIMIT,
			float(p.get("lower_limit", 0.0)))
	g.set_param_x(Generic6DOFJoint3D.PARAM_LINEAR_UPPER_LIMIT,
			float(p.get("upper_limit", 0.0)))
	if bool(p.get("motor_enabled", false)):
		g.set_flag_x(Generic6DOFJoint3D.FLAG_ENABLE_LINEAR_MOTOR, true)
		g.set_param_x(Generic6DOFJoint3D.PARAM_LINEAR_MOTOR_TARGET_VELOCITY,
				float(p.get("motor_speed", 0.0)))
		g.set_param_x(Generic6DOFJoint3D.PARAM_LINEAR_MOTOR_FORCE_LIMIT,
				float(p.get("max_motor_force", 0.0)))
	return g


static func _make_distance(p: Dictionary, xf: Transform3D, jname: String,
		linked: bool, ctx: Dictionary) -> Joint3D:
	if bool(p.get("spring_enabled", false)):
		_warn(ctx, "Distance joint spring dropped: Godot has no distance "
				+ "constraint, so the link was built as a rigid pin", jname)
	if bool(p.get("limit_enabled", false)):
		_warn(ctx, "Distance joint min/max length dropped: a pin holds one fixed "
				+ "separation, not a range", jname)
	if linked:
		# Anchored to the world this is exact -- pinning a body at a point is
		# the same constraint as holding its origin a fixed distance from that
		# point. Between two moving bodies it is not: Box3D leaves each body
		# free to spin without moving its origin, a pin does not.
		_warn(ctx, "Distance joint between two moving bodies approximated by a "
				+ "pin: Box3D holds the two body origins a fixed distance apart, "
				+ "a pin holds one point of each together", jname)
	var pin := PinJoint3D.new()
	pin.transform = xf
	return pin


static func _make_fixed(p: Dictionary, xf: Transform3D, jname: String,
		ctx: Dictionary) -> Joint3D:
	var g := Generic6DOFJoint3D.new()
	g.transform = xf
	_lock_6dof(g)
	if float(p.get("linear_hertz", 0.0)) > 0.0 or float(p.get("angular_hertz", 0.0)) > 0.0:
		_warn(ctx, "Fixed joint softness (linear/angular hertz) dropped; built as "
				+ "a rigid weld, so it will not give under load", jname)
	return g


## All six degrees of freedom clamped to lower == upper == 0. Callers reopen
## whichever axis they need afterwards.
static func _lock_6dof(g: Generic6DOFJoint3D) -> void:
	g.set_flag_x(Generic6DOFJoint3D.FLAG_ENABLE_LINEAR_LIMIT, true)
	g.set_flag_y(Generic6DOFJoint3D.FLAG_ENABLE_LINEAR_LIMIT, true)
	g.set_flag_z(Generic6DOFJoint3D.FLAG_ENABLE_LINEAR_LIMIT, true)
	g.set_flag_x(Generic6DOFJoint3D.FLAG_ENABLE_ANGULAR_LIMIT, true)
	g.set_flag_y(Generic6DOFJoint3D.FLAG_ENABLE_ANGULAR_LIMIT, true)
	g.set_flag_z(Generic6DOFJoint3D.FLAG_ENABLE_ANGULAR_LIMIT, true)
	var pinned: Array[int] = [
		Generic6DOFJoint3D.PARAM_LINEAR_LOWER_LIMIT,
		Generic6DOFJoint3D.PARAM_LINEAR_UPPER_LIMIT,
		Generic6DOFJoint3D.PARAM_ANGULAR_LOWER_LIMIT,
		Generic6DOFJoint3D.PARAM_ANGULAR_UPPER_LIMIT,
	]
	for prm in pinned:
		g.set_param_x(prm, 0.0)
		g.set_param_y(prm, 0.0)
		g.set_param_z(prm, 0.0)


# --- Misc -------------------------------------------------------------------

## Node names carry over from the Box3D scene so warnings and any live driving
## code can still find things, but Godot refuses an empty name.
static func _safe_name(wanted: String, fallback: String) -> String:
	return wanted if not wanted.is_empty() else fallback


# --- Warnings ---------------------------------------------------------------

## Bucket one subject under a reason. Bucketing, rather than one line per node,
## is what keeps a 5050-body rig from producing a 5050-line panel.
static func _warn(ctx: Dictionary, reason: String, subject: String) -> void:
	var buckets: Dictionary = ctx["warn"]
	if not buckets.has(reason):
		buckets[reason] = []
	var names: Array = buckets[reason]
	names.append(subject)


## A standalone line with no subjects. Keyed so it can only be said once.
static func _note(ctx: Dictionary, line: String) -> void:
	var notes: Dictionary = ctx["notes"]
	notes[line] = true


static func _collect_warnings(ctx: Dictionary) -> Array[String]:
	var out: Array[String] = []
	var notes: Dictionary = ctx["notes"]
	var buckets: Dictionary = ctx["warn"]
	for note in notes:
		out.append(String(note))
	for reason in buckets:
		var names: Array = buckets[reason]
		var shown := PackedStringArray()
		for i in mini(names.size(), NAME_CAP):
			shown.append(String(names[i]))
		var line := "%s  [%d]: %s" % [String(reason), names.size(), ", ".join(shown)]
		if names.size() > NAME_CAP:
			line += ", and %d more" % (names.size() - NAME_CAP)
		out.append(line)
	return out
