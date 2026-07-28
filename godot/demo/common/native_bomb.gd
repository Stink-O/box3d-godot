extends RigidBody3D

## The native twin of bomb.gd, attached by WorldOps._native_root_body when the
## authored bomb is rebuilt for Godot Physics or Jolt. Same fuse, same blink,
## same impact rule; the detonation goes through ExplosionFX.blast, whose
## native branch approximates Box3D's impulse-per-area explode.

const ExplosionFX = preload("res://common/explosion_fx.gd")

const FUSE := 3.0
const BLAST_RADIUS := 8.0
const BLAST_IMPULSE := 9.0
const IMPACT_SPEED := 12.0
const IMPACT_FUSE := 0.1

## Set by the shell's blast slider / impact checkbox via the camera at spawn.
var blast_impulse := BLAST_IMPULSE
var impact_detonation := true

var _t := 0.0
var _exploded := false
var _mat: StandardMaterial3D
var _speed_before_hit := 0.0


func _ready() -> void:
	# bomb.gd gets contact events from Box3D's contact_monitor default; a
	# RigidBody3D reports none until asked.
	contact_monitor = true
	max_contacts_reported = 8
	var mi := get_node_or_null("MeshInstance3D") as MeshInstance3D
	if mi != null and mi.material_override is StandardMaterial3D:
		# Duplicate so each bomb blinks on its own material (the scene's is shared).
		_mat = (mi.material_override as StandardMaterial3D).duplicate()
		_mat.emission_enabled = true
		mi.material_override = _mat
	body_entered.connect(_on_body_entered)


func _physics_process(_delta: float) -> void:
	# Sampled once per tick, so when a contact event fires during the NEXT
	# step this still holds the speed from before that impact was resolved.
	_speed_before_hit = linear_velocity.length()


func _on_body_entered(_other: Node) -> void:
	if impact_detonation and _speed_before_hit > IMPACT_SPEED:
		_t = maxf(_t, FUSE - IMPACT_FUSE)


func _process(delta: float) -> void:
	if _exploded:
		return
	_t += delta
	var remaining := FUSE - _t
	if _mat != null:
		# Blink rate ramps up as the fuse burns down (2 Hz -> ~11 Hz).
		var freq := lerpf(2.0, 11.0, clampf(1.0 - remaining / FUSE, 0.0, 1.0))
		var lit := sin(_t * freq * TAU) > 0.0
		_mat.emission_energy_multiplier = 3.5 if lit else 0.0
	if _t >= FUSE:
		_detonate()


func _detonate() -> void:
	_exploded = true
	var n := get_parent()
	while n != null and not (n is NativeWorld):
		n = n.get_parent()
	if n != null:
		ExplosionFX.blast(n, global_position, BLAST_RADIUS, blast_impulse)
	queue_free()
