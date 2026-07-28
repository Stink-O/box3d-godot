extends Node3D

## Reusable ball emitter. Spawns Box3DBody spheres at the emitter's OWN
## current world transform, on a repeating timer -- move (or animate) this
## node in the editor/game and the spawn point moves with it, since the
## transform is read fresh at every shot rather than cached at _ready().
##
## Balls launch with an initial velocity along the emitter's local -Y axis
## (straight down for an unrotated emitter; tilt or rotate the node to fire
## sideways/"forward" instead) and are added to the nearest world ancestor --
## a Box3DWorld, or the NativeWorld stand-in when the engine selector rebuilt
## the sample for Godot Physics / Jolt (main.gd carries this node across the
## rebuild whole, script and exports included, because RigExtract has nothing
## to extract from a spawner).
##
## Drop one of these into a Box3DWorld, position it, tweak the exports, done.

const Despawn = preload("res://common/despawn.gd")

@export var rate: float = 0.65 ## seconds between spawns
@export var speed: float = 1.0 ## initial speed along local -Y (down/forward)
@export var radius: float = 0.25 ## sphere radius
@export var restitution: float = 0.15
@export var friction: float = 0.3
@export var lifetime: float = 13.0 ## seconds before a spawned ball self-frees
## Hard cap on how many of THIS emitter's balls exist at once. When a new ball
## would exceed it, the oldest one is freed immediately (0 = no cap, rely on
## lifetime only). Set this to decide how busy the scene gets.
@export var max_alive: int = 80
@export var random_color: bool = true ## pick a random hue per ball
@export var color: Color = Color(0.8, 0.8, 0.9) ## used when random_color is false
@export var autostart: bool = true ## start spawning as soon as it's ready

var _timer: Timer
var _rng := RandomNumberGenerator.new()
var _alive: Array[Node3D] = []  ## live balls, oldest first (for the max_alive cap)


func _ready() -> void:
	_rng.randomize()
	_timer = Timer.new()
	_timer.one_shot = false
	_timer.wait_time = maxf(rate, 0.01)
	_timer.process_callback = Timer.TIMER_PROCESS_PHYSICS
	add_child(_timer)
	_timer.timeout.connect(_spawn)
	if autostart:
		_timer.start()


func _find_world() -> Node3D:
	var n: Node = get_parent()
	while n != null:
		if n is Box3DWorld or n is NativeWorld:
			return n
		n = n.get_parent()
	return null


func _spawn() -> void:
	# Pick up @export edits to `rate` made at runtime (e.g. from the debugger).
	_timer.wait_time = maxf(rate, 0.01)

	var world := _find_world()
	if world == null:
		return

	if WorldOps.is_native(world):
		_spawn_native(world)
		return

	var b := Box3DBody.new()
	b.shape_type = Box3DBody.SPHERE
	b.sphere_radius = radius
	b.restitution = restitution
	b.friction = friction

	var mi := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	mi.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color.from_hsv(_rng.randf(), 0.7, 0.95) if random_color else color
	mat.roughness = 0.3
	mat.metallic = 0.2
	mi.material_override = mat
	b.add_child(mi)

	# Place the body at the emitter's CURRENT world transform BEFORE adding it
	# to the world. A Box3DBody creates its physics body in _ready -- which
	# add_child() fires synchronously -- reading its global transform *then*, so
	# a transform set after add_child would only move the node (the physics body
	# would stay at the origin and the node would snap back next step). Since the
	# body becomes a direct child of `world`, express the emitter's world pose in
	# the world's local space.
	b.transform = world.global_transform.affine_inverse() * global_transform
	world.add_child(b)
	b.set_linear_velocity(-global_transform.basis.y.normalized() * speed)

	# Self-owned lifetime -- the timer lives and dies with the ball (see
	# common/despawn.gd for why that matters).
	Despawn.attach(b, lifetime)

	_alive.append(b)
	_track_alive()


## The native twin of the spawn above: same material, same launch, but the
## body construction goes through WorldOps so a RigidBody3D comes out.
func _spawn_native(world: Node3D) -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color.from_hsv(_rng.randf(), 0.7, 0.95) if random_color else color
	mat.roughness = 0.3
	mat.metallic = 0.2

	var pos: Vector3 = world.global_transform.affine_inverse() * global_position
	# A couple of centimetres of jitter: at fast rates consecutive balls
	# overlap on the exact same line, and Godot Physics resolves a perfectly
	# axis-aligned sphere column purely vertically -- the stack extrudes
	# upward forever instead of toppling and rolling. Box3D happens to break
	# that symmetry on its own, so its branch stays untouched.
	pos += Vector3(_rng.randf_range(-0.02, 0.02), 0.0, _rng.randf_range(-0.02, 0.02))
	var b := WorldOps.spawn_sphere(world, pos, radius, 1.0, mat, false,
			restitution, 0xFFFFFFFF, friction)
	if b == null:
		return
	WorldOps.set_linear_velocity(b, -global_transform.basis.y.normalized() * speed)
	Despawn.attach(b, lifetime)
	_alive.append(b)
	_track_alive()


func _track_alive() -> void:
	# Count-based cap: drop refs to balls that already died on their own
	# (lifetime timer), then if we're still over max_alive free the oldest
	# living ones so only max_alive of this emitter's balls ever coexist.
	_alive = _alive.filter(func(x): return is_instance_valid(x))
	if max_alive > 0:
		while _alive.size() > max_alive:
			var oldest: Node3D = _alive.pop_front()
			oldest.queue_free()
