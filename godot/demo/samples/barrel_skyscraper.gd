extends Node3D

## Barrel Skyscraper: 3000 steel drums stacked into one hollow square tower,
## which is what the Crysis clip is actually building. The camera in that video
## sits at the foot of it looking up, and perspective turns a straight tower
## into a spire -- the Barrel Spire sample is that misreading, kept because it
## is a good stack in its own right. This one is the shape.
##
## Same barrels, same rule: the walls are one drum thick and the inside is
## empty all the way up, so the tower is a tube rather than a pile. Fly in
## through a gap at the bottom and the whole height of it is open above you.
##
## The arithmetic, chosen so the headline number is exact rather than
## approximate: SIDE drums along each wall, corners shared between two walls,
## is 4 * SIDE - 4 a floor, and
##   60 a floor x 50 floors = 3000
## Every drum sits squarely on the one below it, so each column carries its own
## load straight down and the four walls only have to hold each other square.
##
## What the walls cannot do is hold themselves square for free, and that is the
## one setting this sample needs: **8 substeps, not the default 4.** A closed
## ring of barrels (the Spire) is a compression hoop that locks itself; four
## straight walls are not, and at 4 substeps the contact compliance adds up
## over 50 courses until the tower splays a metre and a half outward at the top
## and never stops moving. At 8 it settles under 20 cm and the whole stack is
## asleep inside twenty seconds. The Settings sidebar's substep spinner is
## right there: wind it back to 4 and watch the walls let go.
##
## ## The three boxes in the sidebar
##
## The tower is really two numbers -- how wide a wall is, and how many drums
## there are -- and the sidebar shows both plus the floor count they imply,
## because all three are things you might want to type (see main.gd's sample
## size dial for the shell side):
##
##   Wall width  drums along one wall. Changing it KEEPS EVERY BARREL: the same
##               count is re-laid onto a wider floor plan, so a wider tower is
##               a shorter one. 3000 drums stay 3000 drums, 4 wide or 40 wide.
##   Floors      how tall, in whole floors. Setting it fills every floor, so it
##               moves the barrel count with it.
##   Barrels     the count itself, and the one that is authoritative. A number
##               the width does not divide leaves the top floor part-built,
##               which is what a real stack looks like and is far better than
##               quietly dropping drums to keep the arithmetic tidy.
##
## They are declared in that order because that is also the order the shell
## puts them back in after a Reset, and only applying the count LAST reproduces
## a part-built top floor exactly. The line under the boxes says what any of
## them would build -- count first -- before anything is built, because this is
## the one control in the shell that can spawn five figures of bodies.

const Barrel = preload("res://common/barrel.gd")
const BarrelCluster = preload("res://common/barrel_cluster.gd")

const DEFAULT_SIDE := 16    ## drums along one wall, corners included
const DEFAULT_LEVELS := 50  ## floors, unless the sidebar says otherwise
## (4 * DEFAULT_SIDE - 4) * DEFAULT_LEVELS. Stated so the number the sample is
## named after is visible in one place; the selftest checks the layout makes it.
const BARREL_COUNT := 3000

## What the sidebar's boxes will accept. Four drums a wall is the narrowest
## thing still shaped like a tower (2.4 m across); 40 is 16 floors of the
## default 3000. MAX_BODIES caps what the Floors box can ask for: 12,000 drums
## is past the Huge Pyramid in bodies and is where this stops being a tower and
## starts being a benchmark. Nothing breaks above these, it only gets slow, so
## they are a courtesy rather than a limit.
const MIN_SIDE := 4
const MAX_SIDE := 40
const MIN_LEVELS := 2
const MAX_LEVELS := 400
const MAX_BODIES := 12000

## Centre-to-centre spacing along a wall: exactly a barrel diameter, so the
## drums touch rim to rim without overlapping (the collider is a SIDES-gon
## inscribed in Barrel.RADIUS, so its widest reach is that radius).
const SPACING := Barrel.RADIUS * 2.0
## One floor per barrel height, no gap: the tower starts in contact instead of
## dropping into contact on the first step.
const LEVEL := Barrel.HEIGHT

## ~9.5 kg a drum, as in the Spire, so the blast slider reads the same here.
const DENSITY := 40.0


## Drums in one floor: four walls of `side` with the corners shared, not
## doubled.
static func per_floor(side := DEFAULT_SIDE) -> int:
	return 4 * side - 4


## The outer wall of the footprint, corner to corner.
static func footprint(side := DEFAULT_SIDE) -> float:
	return (side - 1) * SPACING + Barrel.RADIUS * 2.0


## Floors needed to hold `total` drums at this width. The last one is part
## built when the width does not divide the count.
static func levels_for(side: int, total: int) -> int:
	return ceili(float(total) / float(per_floor(side)))


## One floor's worth of drum centres, in the XZ plane: two full walls and the
## two short courses between them, which is how the corners end up shared
## rather than doubled.
static func floor_plan(side := DEFAULT_SIDE) -> PackedVector2Array:
	var out := PackedVector2Array()
	var half := (side - 1) * SPACING * 0.5
	for i in side:
		out.append(Vector2(-half + i * SPACING, -half))
	for i in side:
		out.append(Vector2(-half + i * SPACING, half))
	for i in range(1, side - 1):
		out.append(Vector2(-half, -half + i * SPACING))
		out.append(Vector2(half, -half + i * SPACING))
	return out


## Where every barrel starts, bottom floor first, filling each floor in plan
## order and stopping dead on the last one when `total` runs out. Static so the
## selftest can check the layout without building 3000 bodies.
static func barrel_positions(side := DEFAULT_SIDE, total := BARREL_COUNT) -> PackedVector3Array:
	var out := PackedVector3Array()
	var plan := floor_plan(side)
	var placed := 0
	for level in levels_for(side, total):
		var y := Barrel.HEIGHT * 0.5 + level * LEVEL
		for p in plan:
			if placed >= total:
				break
			out.append(Vector3(p.x, y, p.y))
			placed += 1
	return out


## The tower as it stands: drums along a wall, and how many drums in total.
## Everything else about the shape falls out of these two.
var _side := DEFAULT_SIDE
var _total := BARREL_COUNT
var _cluster: Node3D = null


func _ready() -> void:
	_build()


func _build() -> void:
	var world: Node = get_node("Box3DWorld")
	# Built detached and added once: the cluster's _ready adopts the bodies it
	# finds under it, so they all have to exist before it enters the tree.
	var cluster := BarrelCluster.new()
	cluster.name = "Barrels"
	for pos in barrel_positions(_side, _total):
		var b := Barrel.make_body(DENSITY)
		b.position = pos
		cluster.add_child(b)
	world.add_child(cluster)
	_cluster = cluster


# --- The sidebar's three boxes (main.gd's sample size dial) ------------------

## Order is not decoration: the shell applies stored dials in this order when a
## Reset puts the user's tower back. Width keeps the count, floors rounds it to
## whole floors, and the count itself comes last and has the final word, which
## is what reproduces a part-built top floor exactly.
func sample_size_dials() -> Array:
	return [
		{
			"key": "width",
			"label": "Wall width",
			"value": _side,
			"min": MIN_SIDE,
			"max": MAX_SIDE,
			"step": 1,
			"tooltip": "Drums along one wall (the corners are shared, so a floor"
					+ " is 4 x width - 4). The barrel count does not change: the"
					+ " same drums are re-laid onto a wider floor plan, so a"
					+ " wider tower is a shorter one.",
		},
		{
			"key": "floors",
			"label": "Floors",
			"value": levels_for(_side, _total),
			"min": MIN_LEVELS,
			"max": mini(MAX_LEVELS, MAX_BODIES / per_floor(_side)),
			"step": 1,
			"tooltip": "How tall to stack it. A floor is %d drums at this width,"
					% per_floor(_side)
					+ " so setting this fills every floor and moves the barrel"
					+ " count with it. The tower is rebuilt from the ground up"
					+ " when you let go of the box.",
		},
		{
			"key": "barrels",
			"label": "Barrels",
			"value": _total,
			"min": MIN_LEVELS * per_floor(_side),
			"max": mini(MAX_BODIES, MAX_LEVELS * per_floor(_side)),
			"step": 1,
			"tooltip": "How many drums to stack, exactly. This is the number the"
					+ " tower is built from; a count the width does not divide"
					+ " leaves the top floor part-built rather than losing any.",
		},
	]


## What a dial would build if it were set to `value`, count first. Shown under
## the boxes BEFORE anything is built: nobody should discover that they asked
## for twelve thousand bodies by watching the frame rate drop.
func sample_size_hint(key: String, value: int) -> String:
	var side := _side
	var total := _total
	if key == "width":
		side = clampi(value, MIN_SIDE, MAX_SIDE)
		total = _fit(side, total)
	elif key == "floors":
		total = _fit(side, clampi(value, MIN_LEVELS, MAX_LEVELS) * per_floor(side))
	elif key == "barrels":
		total = _fit(side, value)
	var levels := levels_for(side, total)
	var line := "%d barrels: %d floors of %d drums, %.1f m across, %.0f m tall" % [
		total, levels, per_floor(side), footprint(side), levels * LEVEL]
	var remainder := total % per_floor(side)
	if remainder != 0:
		line += " (top floor %d of %d)" % [remainder, per_floor(side)]
	return line


## Turn one of the dials and rebuild. Also called BEFORE _ready when the shell
## is putting back a size the user had dialled, in which case there is nothing
## to tear down yet and _ready builds it once, at the right size.
func set_sample_size(key: String, value: int) -> void:
	var side := _side
	var total := _total
	if key == "width":
		# Keep every barrel: only the plan they are laid on changes.
		side = clampi(value, MIN_SIDE, MAX_SIDE)
	elif key == "floors":
		var levels := clampi(value, MIN_LEVELS, MAX_LEVELS)
		# Nudging the box to the number it already reads changes nothing, which
		# matters because the floor count is derived: rounding a part-built top
		# floor up to a full one is a change nobody asked for.
		if levels == levels_for(side, total):
			return
		total = levels * per_floor(side)
	elif key == "barrels":
		total = value
	else:
		return
	total = _fit(side, total)
	if side == _side and total == _total and _cluster != null:
		return
	_side = side
	_total = total
	if not is_inside_tree():
		return
	if _cluster != null:
		# Freed immediately, not queued: a queued free would leave the old
		# tower's bodies in the world for the rest of the frame, and two towers
		# of 3000 drums occupying the same space is a scene the solver has to
		# depenetrate before it can be told they are gone.
		_cluster.free()
		_cluster = null
	_build()


## Clamp a barrel count to what this width is allowed to stack. Only bites at
## the extremes (4 drums a wall is 12 a floor, so MAX_LEVELS runs out before
## MAX_BODIES does); everywhere else the count the caller asked for survives,
## which is the whole promise of the width dial.
static func _fit(side: int, total: int) -> int:
	var ceiling := mini(MAX_BODIES, MAX_LEVELS * per_floor(side))
	return clampi(total, MIN_LEVELS * per_floor(side), ceiling)


## The compare harness reads bodies out of the .tscn and never runs _ready, so
## it would find nothing but the floor here. Saying so beats a blank scene with
## no explanation (see compare/README.md).
func rig_notes() -> Array:
	return ["The %d barrels are built in _ready(), which the extractor never "
			% BARREL_COUNT
			+ "runs, so the native rebuild shows the floor alone."]
