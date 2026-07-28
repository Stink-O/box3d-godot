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


## Physics blast plus the visual flash, in one call. Works on either backend:
## Box3DWorld gets its own explode, a NativeWorld gets the approximation below.
static func blast(world: Node, at: Vector3, blast_radius := 8.0,
		impulse := 8.0, tint := Color(1.0, 0.55, 0.15)) -> void:
	if world == null:
		return
	if world is Box3DWorld:
		(world as Box3DWorld).explode(at, blast_radius, impulse, 1.0)
	else:
		_native_explode(world, at, blast_radius, impulse)
	burst(world, at, blast_radius * 0.55, tint)


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
		rb.apply_central_impulse(dir * impulse * falloff * _area_estimate(rb))


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
