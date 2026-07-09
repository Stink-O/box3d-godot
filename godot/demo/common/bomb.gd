extends Box3DBody

## A thrown bomb: a Box3D sphere with a lit fuse. Once spawned it counts down
## FUSE seconds, blinking red faster and faster, then detonates -- reusing the
## shared ExplosionFX (flash + Box3DWorld.explode) -- and frees itself. Shot by
## the fly camera when the shell's "Shot" mode is set to Bomb.

const ExplosionFX = preload("res://common/explosion_fx.gd")

const FUSE := 3.0
const BLAST_RADIUS := 8.0
const BLAST_IMPULSE := 9.0

var _t := 0.0
var _exploded := false
var _mat: StandardMaterial3D


func _ready() -> void:
	var mi := get_node_or_null("MeshInstance3D") as MeshInstance3D
	if mi != null and mi.material_override is StandardMaterial3D:
		# Duplicate so each bomb blinks on its own material (the scene's is shared).
		_mat = (mi.material_override as StandardMaterial3D).duplicate()
		_mat.emission_enabled = true
		mi.material_override = _mat


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
		ExplosionFX.blast(world, global_position, BLAST_RADIUS, BLAST_IMPULSE)
	queue_free()


func _find_world() -> Box3DWorld:
	var n := get_parent()
	while n != null:
		if n is Box3DWorld:
			return n as Box3DWorld
		n = n.get_parent()
	return null
