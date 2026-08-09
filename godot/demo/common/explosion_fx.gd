extends Node3D

## Reusable explosion effect: an opaque emissive sphere that pops into existence,
## expands, and quickly fades out, then frees itself. It exists ONLY while
## playing -- nothing is left in the scene between blasts. Use it anywhere:
##
##   ExplosionFX.burst(world, position)                       # just the visual
##   ExplosionFX.blast(world, position, radius, impulse)      # visual + Box3D push
##
## `blast` also shoves nearby bodies outward: through Box3DWorld.explode on
## Box3D, or a sphere-overlap approximation of it on a native engine, so the
## same call works against a NativeWorld too.

const _Self = preload("res://common/explosion_fx.gd")  # self-ref so static funcs can instance it

@export var visual_radius := 3.0
@export var color := Color(1.0, 0.55, 0.15)
@export var duration := 0.45


## Spawn just the visual flash at a world position.
static func burst(parent: Node, at: Vector3, radius := 3.0, tint := Color(1.0, 0.55, 0.15)) -> void:
	var fx := _Self.new()
	fx.visual_radius = radius
	fx.color = tint
	parent.add_child(fx)
	fx.global_position = at


## Impulse-per-area is NOT scale free, and that is why the shell's one bomb
## could not move half the sample library. b3World_Explode gives a body
## `impulsePerArea * projectedArea` of impulse (src/physics_world.c:3403-3417),
## and its mass is density * volume, so the velocity a blast imparts falls off
## as 1/density. Samples that keep upstream's b3DefaultShapeDef density of 1000
## (src/types.c:72-73) -- Gear Lift, Wave Pile, Top Down Friction, Spinning
## Stick, Character -- are a THOUSAND times harder to shift than the demo's
## density-1 cubes, and the bomb's 9.0 did essentially nothing to them:
## measured Gear Lift 0.06 m/s and Wave Pile 0.015 m/s, against Cube Pile's
## 32 m/s from the identical call.
##
## Upstream has no such problem because it tunes impulsePerArea per sample:
## 10000 for its density-1000 Top Down Friction (samples/sample_joint.cpp:535,
## which this port already carries verbatim in samples/top_down_friction.gd:53),
## 200 / 1000 for the benchmark ones (samples/sample_benchmark.cpp:1303). The
## shell's bomb has no per-sample knob, so instead it CALIBRATES: it fires,
## measures what the blast actually did, and tops the same blast up if the
## median kick landed far under what an explosion should feel like.
##
## A scene that already responds is left exactly alone -- one explode call,
## bit-identical to before this existed.
##
## A kick under this many m/s is not a push you can see, and no sample tunes
## for one: sweeping the bomb across all 69 samples, the median kick lands
## between 0.68 (Persistent Contact) and 53 (Bowling) everywhere the scene is
## in demo units, and between 0.002 and 0.032 in the six that carry upstream's
## density. The band from 0.032 to 0.68 is EMPTY -- a factor of twenty of clear
## air -- which is what makes this threshold safe rather than a tuning knob.
## Everything above it, including the deliberately heavy ones (Huge Pyramid at
## density 10, Wind's tiny plates), is left exactly alone.
const CALIBRATION_DEADBAND := 0.3
## Where a blast that DOES engage is taken to, in m/s. Bridge is 3.8 and Class
## Ring is 5.1, so this sits at the quiet end of what the library already does
## -- a clear shove, not a cartoon.
const CALIBRATION_FLOOR := 6.0
## Ceiling on the top-up, as a multiple of the impulse asked for. 1000 is the
## density-1-to-density-1000 ratio, which is the entire observed gap; it puts
## the bomb inside upstream's own 200..10000 range for those scenes rather
## than past it. Only Spinning Stick's single 160 kg bar needs the clamp.
const CALIBRATION_MAX := 1000.0
## The impulse the floor above is defined AT (common/bomb.gd BLAST_IMPULSE).
## Calibrating against a fixed nominal rather than against whatever was passed
## keeps the shell's blast slider proportional: half the slider still means
## half the blast, on every sample. This is a units correction, not an override.
const CALIBRATION_NOMINAL := 9.0

const _FALLOFF := 1.0  ## metres past blast_radius over which the impulse fades to zero


## Physics blast plus the visual flash, in one call. Works on either backend:
## Box3DWorld gets its own explode, a NativeWorld gets the approximation below.
static func blast(world: Node, at: Vector3, blast_radius := 8.0,
		impulse := 8.0, tint := Color(1.0, 0.55, 0.15)) -> void:
	if world == null:
		return
	if world is Box3DWorld:
		_box3d_explode(world as Box3DWorld, at, blast_radius, impulse)
	else:
		_native_explode(world, at, blast_radius, impulse)
	burst(world, at, blast_radius * 0.55, tint)


## Box3D's explode, calibrated (see the block above). Because the impulse is
## linear in impulsePerArea, the top-up is just a second explode with the
## REMAINING impulse -- the same upstream call, no state touched, no per-body
## fudging, and a recording replays it exactly as it happened.
static func _box3d_explode(world: Box3DWorld, at: Vector3, radius: float,
		impulse: float) -> void:
	# Bodies the blast can reach, by the same surface-distance test the
	# explosion callback uses (src/physics_world.c:3374). Only dynamic ones:
	# b3World_Explode queries the dynamic tree alone (:3457), so a static or
	# kinematic body in the ball would read as a zero and skew the median.
	var reachable: Array = []
	var before: Array = []
	for b in world.overlap_sphere(at, radius + _FALLOFF):
		var body := b as Box3DBody
		if body == null or body.body_type != Box3DBody.DYNAMIC:
			continue
		reachable.append(body)
		before.append(body.get_linear_velocity())

	world.explode(at, radius, impulse, _FALLOFF)

	if reachable.is_empty() or is_zero_approx(impulse):
		return
	# b3World_Explode writes straight into the solver's velocity state
	# (:3417-3421), so reading back now measures the blast and nothing else.
	# Only bodies that moved count: b3GetShapeProjectedArea is 0 for anything
	# that is not a sphere, capsule or hull (src/shape.c:689-712) and a shape
	# with explosionScale 0 opts out (:3349), and neither of those is a units
	# problem -- letting them into the median would just mask a real one.
	var kicks := PackedFloat64Array()
	for i in reachable.size():
		var body: Box3DBody = reachable[i]
		var kick := (body.get_linear_velocity() - (before[i] as Vector3)).length()
		if kick > 0.0:
			kicks.append(kick)
	if kicks.is_empty():
		return
	kicks.sort()
	var scale := _calibration_scale(kicks[kicks.size() / 2], impulse)
	if scale <= 1.0:
		return
	world.explode(at, radius, impulse * (scale - 1.0), _FALLOFF)


## The factor a blast has to be multiplied by, given the median kick it just
## delivered and the impulse-per-area that delivered it. 1.0 means "this scene
## is in demo units, leave it alone", which is the answer for all but six of
## the samples.
static func _calibration_scale(median_kick: float, impulse: float) -> float:
	if median_kick <= 0.0 or is_zero_approx(impulse):
		return 1.0
	# Normalised back to the nominal impulse, so the same scene always gets the
	# same verdict no matter where the shell's blast slider sits.
	var nominal_kick := median_kick * CALIBRATION_NOMINAL / absf(impulse)
	if nominal_kick >= CALIBRATION_DEADBAND:
		return 1.0
	return minf(CALIBRATION_FLOOR / nominal_kick, CALIBRATION_MAX)


## Box3D's explode applies an impulse per unit of exposed area, fading with
## distance. The native stand-in: overlap a sphere, push every RigidBody3D
## outward from the blast point, scaled by an area estimate of its shape and a
## linear falloff to zero at the radius edge. Not the same solver-level effect
## (no per-contact application), but the same feel at demo scales — and the
## area term keeps the response density-honest: a heavy pyramid block moves
## 10x less than a demo cube, exactly as it does on Box3D.
static func _native_explode(world: Node, at: Vector3, radius: float,
		impulse: float) -> void:
	var w3d := world as Node3D
	if w3d == null or not w3d.is_inside_tree():
		return
	var world_3d := w3d.get_viewport().find_world_3d()
	if world_3d == null:
		return
	var state := PhysicsServer3D.space_get_direct_state(world_3d.space)
	if state == null:
		return
	var query := PhysicsShapeQueryParameters3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = radius
	query.shape = sphere
	query.transform = Transform3D(Basis(), at)
	query.collide_with_areas = false
	query.collide_with_bodies = true
	# The default cap is 32 results; a blast inside the Huge Pyramid overlaps
	# hundreds of blocks.
	var hits := state.intersect_shape(query, 2048)
	var seen := {}
	# Gathered first, applied second, because the same calibration the Box3D
	# branch does by measuring is done here by arithmetic: this branch computes
	# every impulse itself, so the kick each body would get is known before any
	# of it is applied.
	var targets: Array[RigidBody3D] = []
	var pushes: Array[Vector3] = []
	var kicks := PackedFloat64Array()
	for hit: Dictionary in hits:
		var rb := hit.get("collider") as RigidBody3D
		if rb == null or seen.has(rb):
			continue
		seen[rb] = true
		var com: Vector3 = rb.global_transform * rb.center_of_mass
		var dir := com - at
		var dist := dir.length()
		if dist >= radius:
			continue
		dir = dir / dist if dist > 0.001 else Vector3.UP
		var falloff := 1.0 - dist / radius
		var push := dir * impulse * falloff * _area_estimate(rb)
		targets.append(rb)
		pushes.append(push)
		var kick := push.length() / maxf(rb.mass, 0.0001)
		if kick > 0.0:
			kicks.append(kick)

	var scale := 1.0
	if not kicks.is_empty():
		kicks.sort()
		scale = _calibration_scale(kicks[kicks.size() / 2], impulse)
	for i in targets.size():
		targets[i].apply_central_impulse(pushes[i] * scale)


## Rough exposed-area of a body's first collision shape, the term Box3D's
## explode scales its impulse by. Unknown shapes count as 1 m^2 (a demo cube).
static func _area_estimate(rb: RigidBody3D) -> float:
	for child in rb.get_children():
		var cs := child as CollisionShape3D
		if cs == null or cs.shape == null:
			continue
		var s := cs.shape
		if s is BoxShape3D:
			var v: Vector3 = (s as BoxShape3D).size
			return (v.x * v.y + v.y * v.z + v.z * v.x) / 3.0
		if s is SphereShape3D:
			var r := (s as SphereShape3D).radius
			return PI * r * r
		if s is CapsuleShape3D:
			var c := s as CapsuleShape3D
			return c.radius * 2.0 * c.height
		break
	return 1.0


func _ready() -> void:
	var mesh := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 1.0
	sphere.height = 2.0
	mesh.mesh = sphere
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 4.0
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mesh.material_override = mat
	add_child(mesh)

	# Pop in small, expand out, fade to nothing -- then delete self.
	scale = Vector3.ONE * (visual_radius * 0.15)
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(self, "scale", Vector3.ONE * visual_radius, duration) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(mat, "albedo_color:a", 0.0, duration).set_ease(Tween.EASE_IN)
	tw.tween_property(mat, "emission_energy_multiplier", 0.0, duration).set_ease(Tween.EASE_IN)
	tw.chain().tween_callback(queue_free)
