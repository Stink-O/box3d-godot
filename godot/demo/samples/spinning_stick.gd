extends Node3D

## Spinning Stick -- a port of upstream's "Continuous / Spinning Stick" sample
## (samples/sample_continuous.cpp). A 4 m stick is dropped onto the edge of a
## thin wall at 100 m/s while spinning at up to 50 rad/s about a random axis.
## That combination is the hard case for continuous collision: the body's
## CENTRE barely moves per step while its ends sweep several metres, so a
## solver that only sweeps the centre lets the stick scissor straight through
## the wall.
##
## Upstream's numbers are kept: wall 0.25 x 1 x 20 m with its top at y = 1,
## stick 4 x 0.2 x 0.2 m at box3d's own defaults (density 1000, angular damping
## 0) dropped from y = 20 with rolling resistance 0.1, gravity -10, and an
## angular velocity drawn uniformly from [-50, 50] rad/s per axis. Like
## upstream it relies on box3d's default sweep -- `continuous` (isBullet) and
## `allow_fast_rotation` are both left off, and the stick still stays out of
## the wall.
##
## Activate drops a fresh stick with the next spin in upstream's own random
## sequence (upstream restarts the sample). The toggle arms
## `allow_fast_rotation` on the NEXT stick: that lifts box3d's cap of half a
## revolution per substep, which is what upstream's b3BodyDef.allowFastRotation
## is for.
##
## The spin is not "a random spin": it is upstream's XorShift32 generator
## (shared/utils.h:29-38) walked from upstream's own start state RAND_SEED =
## 12345 (shared/utils.h:9), through upstream's RandomFloatRange
## (shared/utils.h:56-62) and RandomVec3 (:65-71) in the same x, y, z order as
## sample_continuous.cpp:169. So the first stick this scene drops carries the
## exact omega a freshly launched og sample app draws, and every Activate is
## the next og restart.
##
## That matters because the outcome is a coin flip. Measured over 300 draws of
## the native sample (this repo's own libbox3d, upstream's setup verbatim), 101
## of them end with the stick kicked clean off the 20 x 20 ground -- a 4 m bar
## whose tips are already moving at 100 m/s from the spin alone, landing on a
## 0.25 m wall edge at another 100 m/s, legitimately launches about a third of
## the time. Seeding a Godot RandomNumberGenerator with an arbitrary number
## instead (this scene used 20260805) froze one draw of that coin forever, and
## that draw was a launch: the stick left the ground at ~24 m/s every single
## time the sample was opened and was 438 m below the floor ten seconds later,
## which reads as a port bug and is not what og shows on a fresh launch.
## Upstream's start state lands (final rest at about (2.2, 0.1, 1.0)), so ours
## does too.

const STICK_SIZE := Vector3(4.0, 0.2, 0.2)
const STICK_START := Vector3(0.0, 20.0, 0.5)
const DROP_SPEED := 100.0
const SPIN_RANGE := 50.0
const ROLLING_RESISTANCE := 0.1
## b3DefaultShapeDef's density is 1000 kg/m^3, "density of water"
## (src/types.c:72-73), while Box3DBody.density defaults to 1. Upstream's stick
## weighs 160 kg; at the node default it weighs 160 g, and a 160 g stick hit by
## its own 100 m/s impact is thrown clean off the 20 x 20 ground.
const DENSITY := 1000.0
## b3DefaultBodyDef leaves angularDamping at 0 (src/types.c:32-45); the node
## defaults it to 0.05. This sample IS the spin, and 0.05 bleeds it away: the
## stick lost a fifth of its rate in the first 10 s and kept slowing.
const ANGULAR_DAMPING := 0.0
## shared/utils.h:8-9. RAND_SEED is where every upstream binary starts its
## XorShift32; RAND_LIMIT is the modulus RandomInt folds the 32-bit state into.
const RAND_SEED := 12345
const RAND_LIMIT := 32767
const UINT32_MASK := 0xFFFFFFFF

var camera_home := Vector3(12.8, 10.5, 12.8)
var camera_look_at := Vector3(0.0, 2.0, 0.0)

var _sticks: Node3D
var _fast_rotation := false
## Upstream's g_randomSeed (shared/utils.c:17), advanced by _random_int().
var _random_seed := RAND_SEED
var _mesh := BoxMesh.new()
var _material := StandardMaterial3D.new()


func _ready() -> void:
	_mesh.size = STICK_SIZE
	_material.albedo_color = Color(0.9, 0.6, 0.25)
	_material.roughness = 0.4

	_sticks = Node3D.new()
	_sticks.name = "Sticks"
	$Box3DWorld.add_child(_sticks)
	_drop()


## The shell's reusable Activate button: another stick, another random spin.
func activate() -> void:
	_drop()


func get_toggle_label() -> String:
	return "Fast Rotation"


func set_toggled(on: bool) -> void:
	_fast_rotation = on


func _drop() -> void:
	var stick := Box3DBody.new()
	stick.box_size = STICK_SIZE
	stick.density = DENSITY
	stick.angular_damping = ANGULAR_DAMPING
	stick.rolling_resistance = ROLLING_RESISTANCE
	stick.allow_fast_rotation = _fast_rotation
	stick.position = STICK_START
	var visual := MeshInstance3D.new()
	visual.mesh = _mesh
	visual.material_override = _material
	stick.add_child(visual)
	_sticks.add_child(stick)
	stick.set_linear_velocity(Vector3(0.0, -DROP_SPEED, 0.0))
	# RandomVec3(-range, range), x then y then z (shared/utils.h:65-71).
	stick.set_angular_velocity(Vector3(
			_random_float_range(-SPIN_RANGE, SPIN_RANGE),
			_random_float_range(-SPIN_RANGE, SPIN_RANGE),
			_random_float_range(-SPIN_RANGE, SPIN_RANGE)))


## Upstream's RandomInt, XorShift32 (shared/utils.h:27-38). GDScript ints are
## 64-bit and signed, so every step is masked back into uint32 -- without the
## mask the left shifts run away and `>> 17` stops being the logical shift the
## C version performs on an unsigned.
func _random_int() -> int:
	var x: int = _random_seed
	x ^= (x << 13) & UINT32_MASK
	x ^= x >> 17
	x ^= (x << 5) & UINT32_MASK
	x &= UINT32_MASK
	_random_seed = x
	return x % (RAND_LIMIT + 1)


## Upstream's RandomFloatRange (shared/utils.h:56-62). The `& RAND_LIMIT` is
## upstream's and is a no-op after RandomInt's modulus; it is kept so the two
## read the same.
func _random_float_range(lo: float, hi: float) -> float:
	var r := float(_random_int() & RAND_LIMIT) / float(RAND_LIMIT)
	return (hi - lo) * r + lo
