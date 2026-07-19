extends Box3DBody

## A thrown bomb: a Box3D sphere with a lit fuse. Once spawned it counts down
## FUSE seconds, blinking red faster and faster, then detonates -- reusing the
## shared ExplosionFX (flash + Box3DWorld.explode) -- and frees itself. Shot by
## the fly camera when the shell's "Shot" mode is set to Bomb.

const ExplosionFX = preload("res://common/explosion_fx.gd")

const FUSE := 3.0
const BLAST_RADIUS := 8.0
const BLAST_IMPULSE := 9.0
## A hit harder than this cuts the fuse to IMPACT_FUSE, so a shot bomb blows
## where it lands instead of bouncing out of blast range first (a 40 m/s
## rebound off something heavy carries it well past BLAST_RADIUS in the 3 s
## fuse). Gentle lobs and rolls stay on the full fuse.
const IMPACT_SPEED := 12.0
const IMPACT_FUSE := 0.1

## Set by the shell's blast slider / impact checkbox via the camera at
## spawn; the constants above stay the defaults.
var blast_impulse := BLAST_IMPULSE
var impact_detonation := true

var _t := 0.0
var _exploded := false
var _mat: StandardMaterial3D
var _speed_before_hit := 0.0  ## last pre-solve speed, for the impact check


func _ready() -> void:
	var mi := get_node_or_null("MeshInstance3D") as MeshInstance3D
	if mi != null and mi.material_override is StandardMaterial3D:
		# Duplicate so each bomb blinks on its own material (the scene's is shared).
		_mat = (mi.material_override as StandardMaterial3D).duplicate()
		_mat.emission_enabled = true
		mi.material_override = _mat
	body_entered.connect(_on_body_entered)


func _physics_process(_delta: float) -> void:
	# Sampled once per tick after the world (parent) has stepped, so when a
	# contact event fires during the NEXT step this still holds the speed
	# from before that impact was resolved.
	_speed_before_hit = get_linear_velocity().length()


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
	var world := _find_world()
	if world != null:
		ExplosionFX.blast(world, global_position, BLAST_RADIUS, blast_impulse)
	queue_free()


func _find_world() -> Box3DWorld:
	var n := get_parent()
	while n != null:
		if n is Box3DWorld:
			return n as Box3DWorld
		n = n.get_parent()
	return null
