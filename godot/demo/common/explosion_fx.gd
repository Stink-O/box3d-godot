extends Node3D

## Reusable explosion effect: an opaque emissive sphere that pops into existence,
## expands, and quickly fades out, then frees itself. It exists ONLY while
## playing -- nothing is left in the scene between blasts. Use it anywhere:
##
##   ExplosionFX.burst(world, position)                       # just the visual
##   ExplosionFX.blast(world, position, radius, impulse)      # visual + Box3D push
##
## `blast` also calls Box3DWorld.explode so the same call both shows the flash
## and shoves nearby bodies outward.

const _Self = preload("res://common/explosion_fx.gd")  # self-ref so static funcs can instance it

@export var visual_radius := 3.0
@export var color := Color(1.0, 0.55, 0.15)
@export var duration := 0.45


## Spawn just the visual flash at a world position.
static func burst(parent: Node, position: Vector3, radius := 3.0, tint := Color(1.0, 0.55, 0.15)) -> void:
	var fx := _Self.new()
	fx.visual_radius = radius
	fx.color = tint
	parent.add_child(fx)
	fx.global_position = position


## Physics blast (Box3DWorld.explode) plus the visual flash, in one call.
static func blast(world: Box3DWorld, position: Vector3, blast_radius := 8.0,
		impulse := 8.0, tint := Color(1.0, 0.55, 0.15)) -> void:
	if world != null:
		world.explode(position, blast_radius, impulse, 1.0)
		burst(world, position, blast_radius * 0.55, tint)


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
