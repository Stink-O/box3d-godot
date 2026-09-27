extends Node3D

## Barrel Spire: 3000 steel drums stacked into one hollow cone, from a reading
## of the Crysis clip that turned out to be the camera's doing -- that tower is
## square, and the shot everyone knows is taken at its foot looking up, where
## perspective does the tapering. Barrel Skyscraper is the shape; this is the
## cone, kept because a self-locking cone of 3000 drums is a good stack in its
## own right and behaves nothing like the tower.
##
## The barrels are a MODEL and nothing else -- red paint, hazard band, cylinder
## collider. Nothing in this sample explodes on its own; the shell's blast
## slider and F key are the only things that will ever touch it.
##
## The stack is a SHELL, one barrel thick, not a solid pile: every drum sits on
## the rim of the ring below it with an empty cone inside, which is the whole
## point. A solid cone of 3000 barrels would be a heap with a crust, and the
## bottom rings would never see the load at all.
##
## The layout is integer arithmetic rather than a tuned taper, because the
## headline number has to be exact. Ring k holds one barrel fewer than ring
## k - 1, from BASE_RING at the floor to APEX_RING at the top, and
##   77 + 76 + ... + 3 = 3003 - 3 = 3000
## exactly. Each ring is then given the radius that packs that many barrels
## edge to edge, so the wall steps inward about 9.7 cm a level -- a third of a
## barrel radius, which is what keeps 75 levels standing rather than peeling
## off. Change BASE_RING or APEX_RING and the total changes with them; the
## selftest checks the sum, the packing and the step.
##
## What it does on load is worth knowing before you call it a bug: 75 courses
## of loose drums are a compliant column, so the spire settles about 30 cm and
## then SWAYS, up to a metre at the apex on a period of several seconds, before
## damping out and falling asleep around the twenty-second mark. Nothing leaves
## the wall while that happens -- which is the half of it the selftest pins.

const Barrel = preload("res://common/barrel.gd")
const BarrelCluster = preload("res://common/barrel_cluster.gd")

const BASE_RING := 77  ## barrels in the bottom ring
const APEX_RING := 3   ## barrels in the top ring
## Sum of BASE_RING..APEX_RING. Stated rather than derived so the number this
## sample is named after is visible in one place, and asserted in the selftest.
const BARREL_COUNT := 3000

## Centre-to-centre spacing of neighbours in a ring: exactly a barrel diameter,
## so a ring is a closed hoop of drums touching rim to rim with nothing
## overlapping. The collider is a SIDES-gon inscribed in Barrel.RADIUS, so its
## widest reach in any direction is that radius and two barrels a diameter
## apart can only ever touch, never interpenetrate.
const CHORD := Barrel.RADIUS * 2.0
## One level per barrel height, with no gap at all. A gap here would mean the
## whole spire dropping a level's worth of slack the moment it loads (the
## Wrecking Ball's wall used to do exactly that, six centimetres of it); at
## zero the drums start in contact and the spire stands still until something
## hits it.
const LEVEL := Barrel.HEIGHT

## ~9.5 kg a drum, the same per-body mass as the Huge Pyramid's blocks, so the
## blast slider and the shootable ball behave here the way they do there.
const DENSITY := 40.0


## Barrels per ring, bottom to top.
static func ring_counts() -> PackedInt32Array:
	var counts := PackedInt32Array()
	var n := BASE_RING
	while n >= APEX_RING:
		counts.append(n)
		n -= 1
	return counts


## The radius that packs `count` barrels around a ring with CHORD between
## neighbouring centres. The chord, not the arc: at the apex three barrels
## sit at 120 degrees, where the two differ by a fifth.
static func ring_radius(count: int) -> float:
	if count < 2:
		return 0.0
	return CHORD / (2.0 * sin(PI / count))


## Where every barrel starts, bottom ring first. Static so the selftest can
## check the layout without building 3000 bodies.
static func barrel_positions() -> PackedVector3Array:
	var out := PackedVector3Array()
	var counts := ring_counts()
	for level in counts.size():
		var count := counts[level]
		var radius := ring_radius(count)
		var y := Barrel.HEIGHT * 0.5 + level * LEVEL
		# Half a step of phase per ring, so consecutive rings do not line their
		# first barrel up into a seam running the height of the spire.
		var phase := PI / count
		for j in count:
			var a := phase + TAU * j / count
			out.append(Vector3(radius * cos(a), y, radius * sin(a)))
	return out


func _ready() -> void:
	var world: Node = get_node("Box3DWorld")
	# Built detached and added once: the cluster's _ready adopts the bodies it
	# finds under it, so they all have to exist before it enters the tree.
	var cluster := BarrelCluster.new()
	cluster.name = "Barrels"
	for pos in barrel_positions():
		var b := Barrel.make_body(DENSITY)
		b.position = pos
		cluster.add_child(b)
	world.add_child(cluster)


## The compare harness reads bodies out of the .tscn and never runs _ready, so
## it would find nothing but the floor here. Saying so beats a blank scene with
## no explanation (see compare/README.md).
func rig_notes() -> Array:
	return ["The %d barrels are built in _ready(), which the extractor never "
			% BARREL_COUNT
			+ "runs, so the native rebuild shows the floor alone."]
