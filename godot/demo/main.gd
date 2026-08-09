extends Node3D

## Box3D sample browser. A dropdown menu lists samples in a submenu per
## category; picking one instances its scene into SampleHost and points the
## shared camera at its world. Add new samples to SAMPLES and drop the scene in
## samples/ -- the menu, the touch picker, `--sample=` and the selftest all read
## that one registry.

const SAMPLES := {
	"Basics": {
		"Cube Pile": "res://samples/cube_pile.tscn",
		"Joint Sampler": "res://samples/joint_sampler.tscn",
		"Body Types": "res://samples/body_types.tscn",
		"Disable Body": "res://samples/disable_body.tscn",
		"Weeble": "res://samples/weeble.tscn",
	},
	"Shapes": {
		"Shape Zoo": "res://samples/shape_zoo.tscn",
		"Restitution": "res://samples/restitution.tscn",
		"Conveyor Belt": "res://samples/conveyor_belt.tscn",
		"Wind": "res://samples/wind.tscn",
		"Live Geometry": "res://samples/live_geometry.tscn",
	},
	"Geometry": {
		"Box Hull": "res://samples/box_hull.tscn",
		"Hull Reduction": "res://samples/hull_reduction.tscn",
	},
	"Stacking & Friction": {
		"Friction Ramp": "res://samples/friction_ramp.tscn",
		"Pyramid": "res://samples/pyramid.tscn",
		"Large Pyramid": "res://samples/large_pyramid.tscn",
		"Huge Pyramid": "res://samples/huge_pyramid.tscn",
		"Mixed Stacks": "res://samples/mixed_stacks.tscn",
		"Jenga Stack": "res://samples/jenga.tscn",
		"Wedge": "res://samples/wedge.tscn",
	},
	"Constraints": {
		"Motion Locks": "res://samples/motion_locks.tscn",
	},
	"Compound": {
		"Compound Shapes": "res://samples/compound.tscn",
		"Tile Floor": "res://samples/tile_floor.tscn",
		"Mesh Tile": "res://samples/mesh_tile.tscn",
	},
	"Toys": {
		"Pool Break": "res://samples/pool.tscn",
		"Marble Run": "res://samples/marble_run.tscn",
		"Tumbling Tower": "res://samples/tower.tscn",
		"Ball Pit": "res://samples/ball_pit.tscn",
		"Wrecking Ball": "res://samples/wrecking.tscn",
		"Ball Fountain": "res://samples/fountain.tscn",
		"Ball Flood": "res://samples/ball_flood.tscn",
	},
	"Dynamics": {
		"Dominoes": "res://samples/dominoes.tscn",
		"Bridge": "res://samples/bridge.tscn",
		"Ragdoll": "res://samples/ragdoll.tscn",
		"Motorized": "res://samples/motor.tscn",
		"Newton's Cradle": "res://samples/cradle.tscn",
		"Motor Joint": "res://samples/motor_joint.tscn",
		"Top Down Friction": "res://samples/top_down_friction.tscn",
		"Gear Lift": "res://samples/gear_lift.tscn",
	},
	"Gyroscopes": {
		"Gyroscopic Torque": "res://samples/gyro_torque.tscn",
		"Gyroscopic Precession": "res://samples/gyro_precession.tscn",
		"Spinning Books": "res://samples/spinning_books.tscn",
		"Class Ring": "res://samples/class_ring.tscn",
	},
	"Gameplay": {
		"Character Controller": "res://samples/character.tscn",
		"Contact Pit": "res://samples/contacts.tscn",
		"Bowling": "res://samples/bowling.tscn",
	},
	"Queries": {
		"Radar Sweep": "res://samples/raycast.tscn",
		"Explosion": "res://samples/explosion.tscn",
		"Overlap World": "res://samples/overlap_world.tscn",
	},
	"Continuous": {
		"Bullets (CCD)": "res://samples/bullets.tscn",
		"Bounce House": "res://samples/bounce_house.tscn",
		"Spinning Stick": "res://samples/spinning_stick.tscn",
		"Bullet vs Stack": "res://samples/bullet_vs_stack.tscn",
	},
	"Vehicles": {
		"Car": "res://samples/car.tscn",
	},
	"Events": {
		"Sensor Visit": "res://samples/sensor_visit.tscn",
		"Persistent Contact": "res://samples/persistent_contact.tscn",
		"Hit": "res://samples/hit_events.tscn",
		"Sensor Hits": "res://samples/sensor_hits.tscn",
	},
	"Robustness": {
		"Overlap Recovery": "res://samples/overlap_recovery.tscn",
		"High Mass Ratio": "res://samples/high_mass_ratio.tscn",
	},
	"Determinism": {
		"Wave Pile": "res://samples/wave_pile.tscn",
	},
	"World": {
		"Far Stack": "res://samples/far_stack.tscn",
	},
	"Mesh": {
		"Height Field": "res://samples/height_field.tscn",
		"Big Box": "res://samples/big_box_mesh.tscn",
		"Grid": "res://samples/grid_mesh.tscn",
		"Hollow Box": "res://samples/hollow_box.tscn",
		"Reflection": "res://samples/mesh_reflection.tscn",
	},
	"Collision": {
		"Manifold": "res://samples/manifold.tscn",
	},
	"Benchmark": {
		"Joint Grid": "res://samples/joint_grid.tscn",
	},
	"Recording": {
		"Rewind": "res://samples/rewind.tscn",
	},
}


## What each sample is showing, one or two plain sentences. Optional: a sample
## with no entry here simply has no description. Shown on hover over its entry
## in the Samples menu (and on the touch sample list), and as a muted line at
## the top of the settings sidebar while it is open, so it is there for anyone
## who goes looking and out of the way for everyone else.
const DESCRIPTIONS := {
	"Cube Pile": "Four thousand boxes dropped into a heap, the demo's headline stress test. Watch the step time in the profiler as the pile settles and goes to sleep.",
	"Joint Sampler": "One of each joint type side by side: hinge, slider, ball, weld, distance, wheel and motor. The slider's motor oscillates and the chain sways so every joint is doing something.",
	"Body Types": "Static, kinematic and dynamic bodies together. The kinematic platform is driven by its node transform and shoves dynamic crates around; nothing pushes back on it.",
	"Disable Body": "A welded capsule chain hanging from an anchor, with the middle link switchable. Disabling a link removes it from the simulation and the tail below it hangs in mid air until something wakes it.",
	"Weeble": "A capsule that will not stay knocked over, because its centre of mass sits well below its middle. Tip it right over with Activate and watch it walk itself back upright.",
	"Shape Zoo": "One of every collider box3d offers, dropped together: spheres, capsules, boxes, cylinders, cones and convex hulls.",
	"Restitution": "A row of balls with restitution rising from 0 to 1, dropped from the same height. Each one bounces back to a different fraction of the drop.",
	"Conveyor Belt": "The ramp never moves. Its surface has a tangent velocity, so it carries crates uphill the way a real belt does, and the crates stop dead when they leave it.",
	"Wind": "A jointed ribbon in a steady 6 m/s wind. This is real aerodynamic drag and lift on each plate's cross section, not a push, which is why the ribbon streams and flutters. Turn the wind off with the toggle and it falls limp.",
	"Box Hull": "The same box built two ways at once: eight corners transformed by hand and handed to the hull builder, against the one call that does it for you. Their largest disagreement is measured rather than eyeballed, and it is zero for a rotation with a uniform scale.",
	"Hull Reduction": "One cloud of 128 points hulled again and again under a rising vertex budget, one body per budget in a row. Left to right the collider goes from a tetrahedron to a faceted ball, and every one of them is a real collider, so the coarse ones rock on their flat faces while the fine ones roll.",
	"Wave Pile": "A hundred convex bodies, spheres and capsules and boxes and rocks, dropped onto a wave field and left to fall asleep. The world records itself as it runs and the recording is then replayed at one, two, four and eight workers with every step's state hash checked, so the verdict is a live cross-thread determinism test.",
	"Far Stack": "The same six box column rebuilt at the origin, ten kilometres out and a hundred kilometres out. Its settled height agrees to a tenth of a millimetre at every offset, because contacts are solved in delta space rather than in absolute coordinates.",
	"Live Geometry": "Colliders being resized while the simulation runs: a growing box lifts a tower, a sphere breathes and its mass follows r cubed, and two spheres on a bar swap size so the body rolls toward the heavy end. Freeze it with the toggle and the whole scene goes to sleep.",
	"Friction Ramp": "Identical boxes on one slope with different friction. The low friction ones slide away, the high friction ones stay put.",
	"Pyramid": "The classic stacking test: a pyramid of boxes that has to stay square and then fall asleep.",
	"Large Pyramid": "The same pyramid, much taller. Deep stacks are where a solver's contact accuracy shows.",
	"Huge Pyramid": "Sixteen thousand boxes in one pyramid. It stands because matching contacts are recycled between steps rather than rebuilt.",
	"Mixed Stacks": "Stacks built from different shapes at once, so the manifolds between unlike colliders have to hold each other up.",
	"Jenga Stack": "Sixty beams, two per layer, each layer turned a quarter turn. It settles by a few centimetres as the gaps close, then sleeps.",
	"Wedge": "A six vertex hull balanced on its own ridge. The contact is a line rather than a face, which is the case a manifold is most likely to get wrong; here it should settle and sleep instead of jittering off.",
	"Motion Locks": "Bodies with individual axes locked. The pucks are held flat to the table and the beads are held to a single axis, so they glide instead of tumbling.",
	"Compound Shapes": "Single bodies made of several child colliders, so one rigid body can have any shape you like.",
	"Tile Floor": "Two and a half thousand slabs baked into ONE collider. The world keeps a single broad phase entry and the compound's own tree finds the slab under the marble.",
	"Mesh Tile": "One box mesh placed four times at different heights, so the tiles meet in steps. Props dropped on it land on the tile below them, not on the gap.",
	"Pool Break": "Fifteen balls racked and broken by the cue ball. Rolling resistance is what makes them slow and settle rather than roll forever.",
	"Marble Run": "Marbles cascade down a zig zag of tilted ramps into the tray at the bottom. Rolling contact, nothing scripted.",
	"Tumbling Tower": "A tall tower built to be knocked down. Shoot it with F or grab a block out of it and watch the rest go.",
	"Ball Pit": "A tank of hundreds of balls, the sphere-on-sphere contact case at scale.",
	"Wrecking Ball": "The rope is a real chain of jointed links, not an animation, so the ball's swing builds from the joints themselves before it smashes the wall.",
	"Ball Fountain": "A spout sprays balls into the air and they rain back into the basin, a steady few hundred bodies coming and going.",
	"Ball Flood": "Three emitters hose balls into a tank as fast as they can fire and nothing is ever recycled, so the body count only climbs. The body count readout is the point.",
	"Dominoes": "A line of slabs toppled by a nudge to the first one. Reset to run it again.",
	"Bridge": "A plank bridge on hinge joints that sags under whatever crosses it.",
	"Ragdoll": "A jointed figure of capsules linked by ball joints with cone and twist limits, so it collapses like a body rather than a bag of parts.",
	"Motorized": "Hinge motors driving a turntable and a windmill. The turntable's riders slide off as it spins up; the motor holds its speed against their weight.",
	"Newton's Cradle": "Five balls on rigid rods. Momentum passes along the touching row and comes out at the far end, which needs the contacts to be solved together rather than one at a time.",
	"Motor Joint": "A soft six degree of freedom drive: give it a target frame and it pulls the body there against gravity, within a force budget. The bar tracks its moving target within a few centimetres.",
	"Top Down Friction": "A hundred pieces in a gravity free arena, each held still by its own motor joint acting as top down friction. Set off the blast and they scatter, then the joints bring them all back to a dead stop.",
	"Gear Lift": "Eighty three revolute joints and one prismatic: a motorised gear turns a second gear, which winds two chains over its rim and hauls a gate up out of a stairwell. Switch the motor off and the gate sinks back down.",
	"Gyroscopic Torque": "The Dzhanibekov effect: a T handle spun about its intermediate axis flips over and over on its own. This only happens if the solver integrates the inertia tensor properly.",
	"Gyroscopic Precession": "Sixty four spinning tops. A leaning top does not fall over, it circles, because its spin turns gravity's torque sideways.",
	"Spinning Books": "Three identical slabs spun about each of their three axes in free fall. Two spins are stable and the third, about the middle axis, tumbles.",
	"Class Ring": "A ring of welded capsules with a heavy gem, spun on its rim. It needs a 960 Hz step to behave: at 60 Hz the contact patch cannot keep up with the rim and the ring never falls over properly.",
	"Character Controller": "Upstream's mover on its full course: a capsule riding a spring suspension (the hover gap is the suspension, shown by the green ray) over ramps, stairs, platforms and a wave field with real holes. WASD moves, Shift sprints, Space jumps, C toggles velocity clipping, V shows the mover debug; the switch follows in third person.",
	"Contact Pit": "Every peg reports its contacts, so each one flashes as a ball hits it. A steady rain of balls keeps the ricochets coming.",
	"Bowling": "Ten pins and a rolling ball. Shoot more balls down the lane with F or reset to re-rack.",
	"Radar Sweep": "A ray sweeping around an emitter, raycasting the world every frame. Whatever it hits lights up and a marker sits at the impact point.",
	"Explosion": "A radial blast applied to everything in range, with the impulse falling off with distance. Press Activate to set it off under the building.",
	"Overlap World": "Every shape type crossed with every body type, with three rows of query probes sweeping through them. A probe turns red for the frame it overlaps something; the three rows are the three kinds of shape an overlap query can use, a sphere, a tilted capsule and an arbitrary point cloud.",
	"Bullets (CCD)": "Fast bullets fired at a thin wall. With continuous collision on they are caught; switch it off with C and they pass straight through.",
	"Bounce House": "One frictionless, perfectly elastic ball fired across a walled pen at 170 m/s with no gravity. It should never escape the pen and never lose speed.",
	"Spinning Stick": "A stick dropped onto the edge of a thin wall at 100 m/s while spinning at up to 50 rad/s. The toggle switches fast rotation handling on and off.",
	"Bullet vs Stack": "A small, very dense sphere fired at 500 m/s through a ten box tower with a thin backstop behind it. The tower is demolished and neither the bullet nor any box gets past the wall.",
	"Car": "A jointed vehicle: wheel joints with springs and motors, driven only through the wheels. Everything the chassis does comes from suspension and tyre contact.",
	"Sensor Visit": "A sensor takes part in collision detection but never pushes anything. The box reports what enters and leaves it while bodies pass straight through.",
	"Persistent Contact": "One sphere rolling across a triangle mesh floor with its live contact drawn every frame, so you can watch a single manifold be held and updated rather than rebuilt.",
	"Hit": "Impact events with an approach speed attached. A welded capsule tower is toppled onto a striped mesh floor and every hard landing reports where it hit, how fast, and which surface material it hit.",
	"Sensor Hits": "Three sensors, one static, one kinematic and one on a motorised joint, shot through at 200 to 300 m/s. With bullet handling on, every pass is caught going in and coming out.",
	"Overlap Recovery": "Ten boxes spawned deliberately interlocked. They push apart smoothly instead of exploding, because the depenetration speed is capped.",
	"High Mass Ratio": "Pyramids topped by a box of the same size but 100, 200 and 400 times the mass. Heavy on light is the hardest case for a solver to hold up.",
	"Height Field": "A terrain stored as one height per grid point rather than as triangles, so it costs a fraction of the memory and a cast only visits the cells it crosses. The probe sphere tracks the surface as it moves.",
	"Big Box": "A ground made of twelve enormous triangles. A contact can sit a long way from any vertex here, so any precision loss shows up as a body that drifts or sinks. Activate cycles the shape resting on it.",
	"Grid": "A tessellated plane collided at twice the size it was authored, since a mesh carries its own scale. A body rolling across it should not catch on the edges between triangles.",
	"Hollow Box": "The same twelve triangles wound inward, which makes them a room rather than a box. Props start halfway through the walls and are pushed back inside.",
	"Reflection": "The same mesh drawn twice, once as authored and once mirrored, with the mirroring changed live. A negative scale reflects the collider too, not just the drawing; Activate cycles through the sign combinations.",
	"Manifold": "The narrow phase called directly on two shapes that are in no world at all, which is what a spawn check or a level tool needs. Yellow points are touching, white ones are close but not yet touching, and the line out of each is the contact normal. Activate steps through the nine shape pairs.",
	"Joint Grid": "A lattice of a thousand bodies tied together by two thousand joints, hung from a static top row. A joint heavy scene is a different cost profile from a contact heavy one.",
	"Rewind": "The world records itself as it runs, then freezes and scrubs the last few seconds backwards as ghosts before running them forward again. The ghosts are a second simulation rebuilt from the recorded bytes rather than stored positions, and every replayed frame is checked against the hash the recording embedded.",
}

## What a game would actually use each sample's feature for, one short line, no
## trailing full stop. Keys match DESCRIPTIONS; a sample with no entry here
## simply shows no use case line. Rendered under the blurb in the sidebar and
## on the second line of the picker tooltip.
const USE_CASES := {
	"Cube Pile": "Debris fields and rubble piles that still have to hold frame rate",
	"Joint Sampler": "Picking the right joint for a door, a lift or a vehicle",
	"Body Types": "Moving platforms and lifts that carry the player",
	"Disable Body": "Switching destroyed or distant parts out of the simulation without deleting them",
	"Weeble": "Punching bags and buoys that right themselves",
	"Shape Zoo": "Choosing a collider that fits the art without paying for a hull you don't need",
	"Restitution": "Bouncy balls, grenades and anything that should rebound",
	"Conveyor Belt": "Conveyors, treadmills and moving walkways",
	"Wind": "Flags, banners and cloth strips that answer to the weather",
	"Box Hull": "Knowing when the cheap scaled-box shortcut is safe for a transformed prop",
	"Hull Reduction": "Choosing the vertex budget for a collider baked from an art mesh",
	"Wave Pile": "Proving a build reproduces the same run whatever the thread count",
	"Far Stack": "Deciding whether a large open world needs its origin rebased",
	"Live Geometry": "Props that grow or shrink in play, like an inflating balloon",
	"Friction Ramp": "Ice, mud and other surfaces that change how things slide",
	"Pyramid": "Stackable crates the player can build with",
	"Large Pyramid": "Tall crate stacks that have to stay put instead of jittering apart",
	"Huge Pyramid": "Checking a big destructible structure survives before you ship it",
	"Mixed Stacks": "Clutter piles built from whatever props are to hand",
	"Jenga Stack": "Tower games where the player pulls pieces out of a stack",
	"Wedge": "Angular props like rocks and rubble that come to rest on an edge",
	"Motion Locks": "Air hockey pucks, rail-bound crates and 2.5D movement",
	"Compound Shapes": "Awkward props like tables and machinery as one rigid body",
	"Tile Floor": "Baking a whole tiled floor into one cheap collider",
	"Mesh Tile": "Level geometry assembled from one mesh repeated at different heights",
	"Pool Break": "Balls that roll to a natural stop instead of rolling forever",
	"Marble Run": "Marble tracks, pinball ramps and chute puzzles",
	"Tumbling Tower": "Destructible towers the player knocks down",
	"Ball Pit": "Ball pits, coin showers and pickups heaped in a container",
	"Wrecking Ball": "Cranes, wrecking balls and anything hung on a swinging rope",
	"Ball Fountain": "Fountains and spawner effects with bodies constantly coming and going",
	"Ball Flood": "Finding the body count where your target hardware gives up",
	"Dominoes": "Chain-reaction puzzles and toppling set pieces",
	"Bridge": "Rope bridges and planks that sag under whatever crosses them",
	"Ragdoll": "Ragdolls that collapse like a body when a character dies",
	"Motorized": "Turntables, windmills and powered machinery that holds its speed",
	"Newton's Cradle": "Puzzles where an impact travels along a row of touching objects",
	"Motor Joint": "Tractor beams and carry tools that pull a prop to where you point",
	"Top Down Friction": "Top-down games where sliding objects settle on their own",
	"Gear Lift": "Gear trains, winches and gates driven by machinery",
	"Gyroscopic Torque": "Tumbling debris in zero gravity that spins the way real objects do",
	"Gyroscopic Precession": "Spinning tops, gyroscopes and wobbling wheels",
	"Spinning Books": "Thrown props that tumble differently depending on the spin axis",
	"Class Ring": "Tuning the step rate for fast-spinning props like coins and wheels",
	"Character Controller": "Player and NPC movement that walks, climbs steps and shoves props",
	"Contact Pit": "Sound, sparks and score fired off every time something is hit",
	"Bowling": "Bowling, skittles and knock-down mini games",
	"Radar Sweep": "Enemy vision cones, scanners and laser sights",
	"Explosion": "Grenades and exploding barrels that throw nearby objects clear",
	"Overlap World": "Checking a spot is clear before spawning a body or placing a building",
	"Bullets (CCD)": "Fast projectiles that must never tunnel through walls",
	"Bounce House": "Frictionless arcade balls that keep their speed forever",
	"Spinning Stick": "Thrown weapons that spin fast without passing through geometry",
	"Bullet vs Stack": "High-powered weapons that punch through cover but not through the level",
	"Car": "Drivable vehicles with real suspension and tyre grip",
	"Sensor Visit": "Pickups and trigger zones",
	"Persistent Contact": "Effects that need one contact tracked over time, like skid marks",
	"Hit": "Impact sounds and effects that scale with how hard something landed",
	"Sensor Hits": "Triggers that catch bullet-speed passes, like finish lines and target hoops",
	"Overlap Recovery": "Spawning bodies in tight spaces without them exploding apart",
	"High Mass Ratio": "Heavy objects resting on lighter ones, like a car parked on crates",
	"Height Field": "Large outdoor terrain that is cheap to store and cheap to cast against",
	"Big Box": "Ground planes built from a handful of enormous triangles",
	"Grid": "Reusing one authored mesh at another scale without seams a body catches on",
	"Hollow Box": "Rooms and interiors built from a single inward-facing mesh",
	"Reflection": "Mirrored level pieces reused with a negative scale",
	"Manifold": "Build-placement checks that ask whether two shapes touch before anything is spawned",
	"Joint Grid": "Budgeting for joint-heavy scenes like chain nets and cloth",
	"Rewind": "Killcams, action replays and reproducing a reported desync from the bytes",
}


## SAMPLES flattened to `{category, name, path}` rows, in registry order. One
## place that walks the registry, so the menu, the touch picker, the `--sample=`
## lookup and the selftest can never disagree about what a sample is called or
## which category it lives in. Static: the selftest reads it off the script
## without booting the shell.
static func sample_rows() -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	for category in SAMPLES:
		for sample_name in SAMPLES[category]:
			rows.append({
				"category": category,
				"name": sample_name,
				"path": SAMPLES[category][sample_name],
			})
	return rows


## The `--sample=` lookup, case-insensitive, returning that sample's row. An
## empty dictionary means "no such sample" and the caller keeps its default,
## which is why a typo on the command line silently opens the first sample.
static func find_sample(wanted: String) -> Dictionary:
	if wanted.is_empty():
		return {}
	var lower := wanted.to_lower()
	for row in sample_rows():
		if String(row["name"]).to_lower() == lower:
			return row
	return {}


## Which category a sample is filed under, "" if it is not in the registry.
static func category_of(sample_name: String) -> String:
	for row in sample_rows():
		if row["name"] == sample_name:
			return String(row["category"])
	return ""


## A category's row in the Samples popup. The mark is what says "your sample is
## in here"; every other row is padded to the same lead-in so moving the mark
## never reflows the popup, and the count is there because a submenu hides how
## much is behind it.
static func menu_category_label(category: String, current: bool) -> String:
	return "%s%s  (%d)" % ["•  " if current else "   ", category, SAMPLES[category].size()]

## Which solver runs the samples. Box3D is the default and the tested path; the
## native engines exist so the same shell -- same menu, camera, tools, reset --
## can be pointed at a different solver. Selecting one restarts the process
## (Godot reads physics/3d/physics_engine once at startup and offers no runtime
## switch and no command-line flag), see _restart_with_engine.
const ENGINE_IDS := ["box3d", "godot", "jolt"]
const ENGINE_TITLES := {
	"box3d": "Box3D",
	"godot": "Godot Physics",
	"jolt": "Jolt Physics",
}
## Values for physics/3d/physics_engine. The exact strings matter and are easy
## to get wrong: an unregistered name is NOT an error, Godot falls back to
## DEFAULT silently with nothing on stderr, which is why the live server is
## identified behaviourally instead (_identify_native). Registered values on
## 4.7: DEFAULT, GodotPhysics3D, "Jolt Physics", Dummy. Box3D runs its own
## world, so it takes Dummy rather than pay for a native server stepping an
## empty space -- nothing outside compare/ and common/native_world.gd touches
## the native physics API.
const ENGINE_SETTINGS := {
	"box3d": "Dummy",
	"godot": "GodotPhysics3D",
	"jolt": "Jolt Physics",
}
## Physics ticks to wait before trusting the behavioural engine probe. The
## counters it reads only mean something while bodies are still awake.
const ENGINE_PROBE_TICK := 12
## Where the browser build opens. See the note in _ready().
const WEB_FIRST_SAMPLE := "Pyramid"
## Profiler tint per engine, so a recording is identifiable from a thumbnail.
const ENGINE_ACCENTS := {
	"box3d": Color(0.35, 0.85, 1.0),
	"godot": Color(0.45, 0.7, 1.0),
	"jolt": Color(1.0, 0.62, 0.2),
}

@onready var _host: Node3D = $SampleHost
@onready var _camera: Camera3D = $Camera3D
@onready var _menu: MenuButton = $UI/Bar/Menu
@onready var _engine_option: OptionButton = $UI/Sidebar/Margin/VBox/EngineOption
@onready var _engine_sep: Control = $UI/Sidebar/Margin/VBox/EngineSep
@onready var _engine_label: Label = $UI/Sidebar/Margin/VBox/EngineLabel
@onready var _engine_hint: Label = $UI/Sidebar/Margin/VBox/EngineHint
@onready var _engine_note: Label = $UI/Bar/EngineNote
@onready var _shot_mode: OptionButton = $UI/Bar/ShotMode
@onready var _blast_label: Label = $UI/Bar/BlastLabel
@onready var _blast_slider: HSlider = $UI/Bar/BlastSlider
@onready var _impact_check: CheckBox = $UI/Bar/ImpactCheck
@onready var _activate: Button = $UI/Bar/Activate
@onready var _sample_toggle: CheckButton = $UI/Bar/SampleToggle
@onready var _info: Label = $UI/Bar/Info
@onready var _reset: Button = $UI/Reset
@onready var _debug_toggle: CheckButton = $UI/DebugToggle
@onready var _charge_bar: ProgressBar = $UI/ChargeBar

@onready var _sidebar_toggle: Button = $UI/SettingsToggle
@onready var _sidebar: Control = $UI/Sidebar
@onready var _substep_spin: SpinBox = $UI/Sidebar/Margin/VBox/SubstepRow/SubstepSpin
@onready var _worker_spin: SpinBox = $UI/Sidebar/Margin/VBox/WorkerRow/WorkerSpin
@onready var _max_speed_spin: SpinBox = $UI/Sidebar/Margin/VBox/MaxSpeedRow/MaxSpeedSpin
@onready var _gravity_spin: SpinBox = $UI/Sidebar/Margin/VBox/GravityRow/GravitySpin
@onready var _continuous_check: CheckBox = $UI/Sidebar/Margin/VBox/ContinuousCheck
@onready var _sleep_check: CheckBox = $UI/Sidebar/Margin/VBox/SleepCheck
@onready var _recycling_check: CheckBox = $UI/Sidebar/Margin/VBox/RecyclingCheck
@onready var _sidebar_debug_check: CheckBox = $UI/Sidebar/Margin/VBox/DebugDrawCheck
@onready var _stats_check: CheckBox = $UI/Sidebar/Margin/VBox/StatsCheck
@onready var _async_check: CheckBox = $UI/Sidebar/Margin/VBox/AsyncCheck
@onready var _async_hint: Label = $UI/Sidebar/Margin/VBox/AsyncHint
@onready var _vsync_option: OptionButton = $UI/Sidebar/Margin/VBox/VsyncOption
@onready var _stats_overlay: Control = $UI/StatsOverlay
@onready var _profiler: ProfilerPanel = $UI/Profiler
@onready var _profiler_check: CheckBox = $UI/Sidebar/Margin/VBox/ProfilerCheck
@onready var _body_count_check: CheckBox = $UI/Sidebar/Margin/VBox/BodyCountCheck
@onready var _body_count_label: Label = $UI/BodyCount
@onready var _contact_hertz_row: Control = $UI/Sidebar/Margin/VBox/ContactHertzRow
@onready var _contact_hertz_spin: SpinBox = $UI/Sidebar/Margin/VBox/ContactHertzRow/ContactHertzSpin
@onready var _contact_damping_row: Control = $UI/Sidebar/Margin/VBox/ContactDampingRow
@onready var _contact_damping_spin: SpinBox = $UI/Sidebar/Margin/VBox/ContactDampingRow/ContactDampingSpin
@onready var _readout: Label = $UI/Sidebar/Margin/VBox/Readout
@onready var _set_start_btn: Button = $UI/Sidebar/Margin/VBox/StartViewRow/SetStartView
@onready var _clear_start_btn: Button = $UI/Sidebar/Margin/VBox/StartViewRow/ClearStartView
@onready var _bar: HBoxContainer = $UI/Bar

## Start views saved at runtime with the sidebar's "Set Start View" button,
## keyed by sample scene path. Highest-priority spawn view, survives restarts.
const START_VIEWS_PATH := "user://start_views.cfg"
var _start_views := ConfigFile.new()

var _current: Node = null
var _items: Dictionary = {}  ## popup item id -> {path, name, category}
var _cat_popups: Dictionary = {}  ## category -> its submenu PopupMenu
var _cat_rows: Dictionary = {}  ## category -> its row index in the root popup
var _current_path := ""
var _current_name := ""
var _debug_draw := false
var _step_count := 0
var _updating_sidebar := false  ## guard while pushing values into the controls
var _sample_blurb: Label  ## muted one-liner in the sidebar, see DESCRIPTIONS
var _sample_use_case: Label  ## dimmer line under it, see USE_CASES
var _sample_blurb_box: Control  ## holds both labels, hidden while collapsed
var _sample_blurb_toggle: Button  ## discloses the blurb; collapsed on every sample load
var _side_scroll: ScrollContainer  ## the sidebar's scrollable middle, all platforms
## Solver settings the user has explicitly changed with the sidebar this
## session, as `key -> the value they chose`. Every world the shell loads
## afterwards gets these pushed back onto it -- Reset, the engine-switch
## restart, the worker-count reload and a plain sample switch alike -- so a
## tuning session survives a rebuild instead of being wiped by the fresh
## scene's own defaults.
##
## It tracks INTENT, not a snapshot of the panel: a setting the user never
## touched is not in here and keeps following whatever each sample authors
## (Class Ring's 960 Hz substeps, a benchmark's worker count). That is the whole
## reason this is a dirty set rather than "remember every control".
##
## Only real user edits are recorded -- every handler marks it AFTER the
## _updating_sidebar guard, so the programmatic pushes in
## _refresh_sidebar_from_world / _apply_sticky_settings never dirty anything.
## An entry is dropped again the moment its control is put back to the value the
## sample loaded with, which is what the ⟲ revert button beside it does; a
## restart of the demo clears the lot.
var _sticky := {}
## Screenshot-on-tick, see _save_shot.
var _shot_path := ""
var _shot_tick := 200
var _debug_hidden: Array = []  ## MeshInstance3Ds hidden while the debug view is on
var _debug_hidden_node_count := -1  ## tree size at the last hide walk (skip cheaply when unchanged)
## Off by default; sticky across sample loads and resets once turned on.
var _async_step := false

## The sidebar's Recording section (F-R2), mirroring upstream's own
## (`samples/sample.cpp:2005-2033`). All of it is built in code rather than in
## main.tscn, the way the sample blurb and the ⟲ buttons are: the section only
## exists on Box3D worlds and the scene should not carry rows that spend most of
## their life hidden.
var _recorder := ShellRecorder.new()
var _record_box: Control = null  ## the whole section, hidden on native engines
var _record_arm_row: Control = null  ## the two arm buttons, shown when idle
var _record_stop_btn: Button = null  ## shown instead, while a session is live
var _record_status: Label = null  ## upstream's "recording (from step N)" line
var _record_status_row: Control = null  ## the status line plus its busy spinner
var _record_spinner: ShellSpinner = null  ## shown while a save is in flight
var _rec_spinner: ShellSpinner = null  ## the same, beside the top bar's pill
var _rec_pill: Label = null  ## the same state in the top bar, so a closed sidebar cannot hide it
## Replay (F-R3). The bar owns the player, the renderer and the transport; the
## shell owns only "which sample is paused behind it" and how to get back.
var _record_replay_row: Control = null
var _record_open_btn: MenuButton = null
var _record_last_btn: Button = null
var _replay_paths := PackedStringArray()  ## what the Open menu is currently listing
var _replay: ReplayTimeline = null

var _touch: TouchControls = null  ## touch overlay, only on touchscreen devices
var _sample_panel: PanelContainer = null  ## touch sample picker (desktop uses the popup)
var _sample_scroll: ScrollContainer = null  ## its scrollable list, for scrolling to the current row
var _touch_rows: Dictionary = {}  ## sample name -> its Button in the touch picker
var _touch_sections: Dictionary = {}  ## category -> {head: Button, box: VBoxContainer}
var _touch_layer: CanvasLayer = null  ## panels above the touch overlay, mobile only

## Engine selection. `_engine` is what was ASKED for (`--engine=`, written by
## the restart); `_engine_live` is what the behavioural probe actually found,
## and `_engine_alert` holds the message when they disagree.
var _engine := "box3d"
var _engine_live := ""
var _engine_alert := ""
var _engine_probed := false
var _restarting := false
## Port notes for the sample currently loaded on a native engine: what the rig
## could not express (RigExtract.unsupported) plus what the rebuild had to
## approximate (RigNative.warnings). Empty on Box3D, which runs as authored.
var _native_notes: Array = []
var _native_dynamic := 0  ## dynamic bodies in the rebuilt rig; the probe needs some
var _has_recycling := false  ## this build's Box3DBody exposes contact_recycling
var _has_async := false  ## this build's Box3DWorld accepts async_step


func _ready() -> void:
	# Delete a stale override.cfg the moment we are up. Godot read
	# physics/3d/physics_engine once at startup and never looks again, so the
	# file has already done its job; removing it here is what keeps a crash or a
	# kill -9 from leaving the demo silently switched to another engine.
	_sweep_override()
	_parse_engine_arg()
	_make_sidebar_scrollable()  # before _setup_touch: touch layers onto _side_scroll
	_setup_touch()
	_build_menu()

	# Keep keyboard focus off every shell button so a click doesn't leave it
	# holding focus and swallowing later keypresses (F / X / etc.) meant for
	# the camera or the loaded sample.
	_reset.focus_mode = Control.FOCUS_NONE
	_reset.pressed.connect(_on_reset)
	_debug_toggle.focus_mode = Control.FOCUS_NONE
	_debug_toggle.toggled.connect(_on_debug_toggled)
	_menu.focus_mode = Control.FOCUS_NONE
	_sidebar_toggle.focus_mode = Control.FOCUS_NONE
	_sidebar_toggle.toggled.connect(_on_sidebar_toggled)
	_build_sample_blurb()
	_build_record_section()

	# Engine selector: same shell, different solver underneath.
	_engine_option.focus_mode = Control.FOCUS_NONE
	_engine_option.add_item("Box3D")
	_engine_option.add_item("Godot Physics")
	_engine_option.add_item("Jolt Physics")
	_engine_option.select(ENGINE_IDS.find(_engine))
	_engine_option.item_selected.connect(_on_engine_selected)
	# Switching engines means relaunching the process, which only desktop can
	# do; elsewhere the control would just close the app.
	# Android / iOS / Web cannot relaunch themselves, so the whole section
	# goes rather than leaving a heading and a hint over nothing.
	var can_switch := _can_restart()
	for node: Control in [_engine_sep, _engine_label, _engine_option, _engine_hint]:
		node.visible = can_switch
	# Labels ignore the mouse, and the full note list lives in the tooltip.
	_engine_note.mouse_filter = Control.MOUSE_FILTER_PASS
	_engine_note.visible = false

	# Shot mode: what F fires (a ball, or a fused bomb).
	_shot_mode.focus_mode = Control.FOCUS_NONE
	_shot_mode.add_item("Shot: Ball")
	_shot_mode.add_item("Shot: Bomb")
	_shot_mode.add_item("Shot: Ragdoll")
	_shot_mode.item_selected.connect(_on_shot_mode_selected)
	_blast_slider.focus_mode = Control.FOCUS_NONE
	_blast_slider.value_changed.connect(_on_blast_changed)
	_impact_check.focus_mode = Control.FOCUS_NONE
	_impact_check.toggled.connect(_on_impact_toggled)
	# The bar can fill up (bomb controls + a sample toggle + the hint text);
	# trim the hint with an ellipsis instead of letting it run under the
	# right-anchored Settings/Debug/Reset cluster.
	_info.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS

	# Reusable Activate button: calls activate() on samples that define one.
	_activate.focus_mode = Control.FOCUS_NONE
	_activate.pressed.connect(_on_activate)

	# Reusable sample toggle: shown for samples that define set_toggled(on),
	# labelled by their get_toggle_label() (the Car's third-person camera).
	_sample_toggle.focus_mode = Control.FOCUS_NONE
	_sample_toggle.toggled.connect(_on_sample_toggle)

	_camera.set_charge_bar(_charge_bar)

	_start_views.load(START_VIEWS_PATH)  # missing on first run, that's fine

	_sidebar.visible = false
	_set_start_btn.focus_mode = Control.FOCUS_NONE
	_set_start_btn.pressed.connect(_on_set_start_view)
	_clear_start_btn.focus_mode = Control.FOCUS_NONE
	_clear_start_btn.pressed.connect(_on_clear_start_view)
	_substep_spin.value_changed.connect(_on_substep_changed)
	_worker_spin.value_changed.connect(_on_worker_changed)
	_max_speed_spin.value_changed.connect(_on_max_speed_changed)
	_gravity_spin.value_changed.connect(_on_gravity_changed)
	_continuous_check.toggled.connect(_on_continuous_changed)
	_sleep_check.focus_mode = Control.FOCUS_NONE
	_sleep_check.toggled.connect(_on_sleep_changed)
	_recycling_check.focus_mode = Control.FOCUS_NONE
	_recycling_check.toggled.connect(_on_recycling_changed)
	# Hide the row on builds whose extension predates the property.
	var body_probe := Box3DBody.new()
	_has_recycling = "contact_recycling" in body_probe
	_recycling_check.visible = _has_recycling
	body_probe.free()
	# Async stepping is REFUSED on some builds (all web builds: a main-thread
	# join on a queued worker deadlocks the tab), where the setter bounces and
	# the property reads back false. Probe a scratch world so the sidebar hides
	# the checkbox instead of offering a toggle that silently does nothing.
	var world_probe := Box3DWorld.new()
	world_probe.async_step = true
	_has_async = world_probe.async_step
	world_probe.free()
	_sidebar_debug_check.toggled.connect(_on_sidebar_debug_changed)
	_contact_hertz_spin.value_changed.connect(_on_contact_hertz_changed)
	_contact_damping_spin.value_changed.connect(_on_contact_damping_changed)
	_stats_check.focus_mode = Control.FOCUS_NONE
	_stats_check.toggled.connect(_on_stats_toggled)
	_profiler_check.focus_mode = Control.FOCUS_NONE
	_profiler_check.toggled.connect(_on_profiler_toggled)
	_body_count_check.focus_mode = Control.FOCUS_NONE
	_body_count_check.toggled.connect(_on_body_count_toggled)
	_async_check.focus_mode = Control.FOCUS_NONE
	_async_check.toggled.connect(_on_async_toggled)

	# V-Sync mode: a global display setting (never reset on sample load). The
	# control starts from whatever mode the window actually has, and after each
	# change reads the mode back — the platform may refuse one (e.g. mailbox),
	# and the dropdown should show reality, not the request.
	_vsync_option.focus_mode = Control.FOCUS_NONE
	_vsync_option.add_item("VSync: On")
	_vsync_option.add_item("VSync: Off")
	_vsync_option.add_item("VSync: Mailbox")
	_vsync_option.select(_vsync_index(DisplayServer.window_get_vsync_mode()))
	_vsync_option.item_selected.connect(_on_vsync_selected)

	_setup_reverts()

	_restore_overlay_state()
	_take_sticky_handoff()  # sidebar edits carried across an engine switch
	_add_web_notice()

	# `-- --sample=Ragdoll` (case-insensitive) opens straight to that sample.
	# `-- --profiler` opens with the solver profiler already up, so a recording
	# setup does not have to click through the sidebar every launch.
	var wanted := ""
	var replay_arg := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--sample="):
			wanted = arg.get_slice("=", 1).to_lower()
		elif arg == "--settings":
			_sidebar.visible = true
		elif arg == "--profiler":
			_profiler_check.set_pressed_no_signal(true)
			_profiler.visible = true
		elif arg.begins_with("--shot="):
			_shot_path = arg.get_slice("=", 1)
		elif arg.begins_with("--shot-tick="):
			_shot_tick = maxi(1, int(arg.get_slice("=", 1)))
		elif arg.begins_with("--replay="):
			# Open straight into the timeline on a saved recording. Same reason
			# --sample= and --profiler exist: it makes the path scriptable, and
			# replay smoothness is a thing that has to be MEASURED rather than
			# eyeballed (`--replay=... --profiler --shot=out.png`).
			replay_arg = arg.get_slice("=", 1)
	var first_cat: String = SAMPLES.keys()[0]
	var first_name: String = SAMPLES[first_cat].keys()[0]
	# The browser build opens somewhere lighter. Cube Pile is 4096 bodies and
	# asks for 4 solver workers; on web there is one, so it is the single worst
	# scene to land on first and it is the one everyone would land on. Measured
	# on this machine, natively: 0.39 ms/step at 4 workers vs 1.24 ms at 1, and
	# only while the pile is awake -- asleep it costs nothing either way.
	# Every sample is still one menu click away.
	if OS.has_feature("web") and not WEB_FIRST_SAMPLE.is_empty():
		for category in SAMPLES:
			if SAMPLES[category].has(WEB_FIRST_SAMPLE):
				first_cat = category
				first_name = WEB_FIRST_SAMPLE
	var asked := find_sample(wanted)
	if not asked.is_empty():
		first_cat = String(asked["category"])
		first_name = String(asked["name"])
	if not wanted.is_empty():
		# A --sample= that matches nothing is not an error, it just leaves the
		# default in place -- which reads exactly like the sample being broken.
		# Say which one actually opened, so a scripted run can check.
		if asked.is_empty():
			push_warning("--sample=%s matched no sample; opening %s" % [wanted, first_name])
		print("[shell] --sample=%s -> %s (%s)" % [wanted, first_name, first_cat])
	_load(SAMPLES[first_cat][first_name], first_name)
	if not replay_arg.is_empty():
		_enter_replay(replay_arg)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_TAB:
		_sidebar_toggle.button_pressed = not _sidebar_toggle.button_pressed


## The shell keeps FOCUS_NONE on every button (see _ready), but the sidebar's
## SpinBox text fields must take focus to be typed in — and a LineEdit holds it
## until something else takes it, so W A S D after editing a field kept typing
## into the field instead of flying the camera. Any mouse press outside the
## focused field commits the edit (focus_exited applies a SpinBox's text) and
## hands the keyboard back to the camera / sample.
func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		var focused := get_viewport().gui_get_focus_owner()
		if focused != null \
				and not focused.get_global_rect().has_point(focused.get_global_mouse_position()):
			focused.release_focus()


# --- Engine selection --------------------------------------------------------
#
# `-- --engine=box3d|godot|jolt`, written by the restart below (and usable by
# hand). The setting itself is never trusted: the live server is identified
# behaviourally a few ticks into the first sample.

func _parse_engine_arg() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--engine="):
			var id := arg.get_slice("=", 1).to_lower()
			if ENGINE_TITLES.has(id):
				_engine = id
			else:
				push_error("[engine] unknown engine '%s', running Box3D" % id)


func _native() -> bool:
	return _engine != "box3d"


## Relaunching is a desktop facility; Android, iOS and Web have no restart, so
## picking an engine there would only close the app.
func _can_restart() -> bool:
	return not (OS.get_name() in ["Android", "iOS", "Web"])


func _override_path() -> String:
	# Exported builds map res:// to the executable's directory, which is exactly
	# where Godot looks for override.cfg, so globalizing works in both layouts.
	return ProjectSettings.globalize_path("res://override.cfg")


func _sweep_override() -> void:
	var path := _override_path()
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)


## Godot ConfigFile: comments are ';', never '#'. Written just before the
## process restarts, consumed at the next startup, swept in _ready.
func _write_override(id: String) -> bool:
	var cfg := ConfigFile.new()
	cfg.set_value("physics", "3d/physics_engine", String(ENGINE_SETTINGS[id]))
	var err := cfg.save(_override_path())
	if err != OK:
		push_error("[engine] could not write %s (error %d)" % [_override_path(), err])
		return false
	return true


func _on_engine_selected(index: int) -> void:
	var id: String = String(ENGINE_IDS[index])
	if id == _engine or _restarting:
		_engine_option.select(ENGINE_IDS.find(_engine))
		return
	_restart_with_engine(id)


## The engine cannot change in-process, so this writes the override and comes
## back as a new process on the same sample.
func _restart_with_engine(id: String) -> void:
	_restarting = true
	_engine_option.disabled = true
	_info.text = "Switching to %s   ·   restarting the demo..." % ENGINE_TITLES[id]
	_info_flash_id += 1  # nothing should overwrite that message now
	# Order matters: a platform that cannot relaunch must not be left holding an
	# override.cfg that would switch the engine behind the user's back.
	if not _can_restart() or not _write_override(id):
		_restarting = false
		_engine_option.disabled = false
		_engine_option.select(ENGINE_IDS.find(_engine))
		_flash_info("Could not switch to %s: the demo cannot restart itself here."
				% ENGINE_TITLES[id])
		return
	_stash_sticky_for_restart()
	var args := _restart_args(id)
	print("[engine] restarting on %s: %s" % [ENGINE_TITLES[id], " ".join(args)])
	if not _spawn_replacement(args):
		_restarting = false
		_engine_option.disabled = false
		_engine_option.select(ENGINE_IDS.find(_engine))
		_flash_info("Could not launch %s. Run the demo from a terminal and try again."
				% ENGINE_TITLES[id])
		return
	# Two frames so the message actually reaches the screen before the window
	# goes away.
	await get_tree().process_frame
	await get_tree().process_frame
	get_tree().quit()


## Start the replacement process, detached from this one.
##
## OS.set_restart_on_exit() looks like the right tool and is not: the process it
## spawns stays in OUR process group, so anything supervising this process takes
## the replacement down with it a moment later. That is exactly what happens
## when the demo is played from the Godot editor -- the editor owns the play
## session and reaps the group when the game exits -- and the symptom is an app
## that closes and never comes back. A shell that cleans up its job control does
## the same.
##
## `setsid` puts the replacement in a fresh session so nothing can reap it by
## association. It is util-linux, present on any Linux desktop, and the BSD/macOS
## layout is close enough to try. If it is missing, or on Windows, fall back to
## spawning directly, which is still correct when nobody is supervising us.
func _spawn_replacement(args: PackedStringArray) -> bool:
	var exe := OS.get_executable_path()
	if OS.get_name() not in ["Windows", "UWP"]:
		var detached := PackedStringArray([exe])
		detached.append_array(args)
		if OS.create_process("setsid", detached) > 0:
			return true
	return OS.create_process(exe, args) > 0


## Command line for the relaunch. OS.get_cmdline_args() holds what the engine
## did NOT consume (the scene path, if one was given), so `--path` is rebuilt
## rather than read back; an exported build carries its own project and must not
## get one. Everything after "--" is ours to rewrite, and that is where
## --engine / --sample live.
func _restart_args(id: String) -> PackedStringArray:
	var args := PackedStringArray()
	args.append_array(OS.get_cmdline_args())
	if OS.has_feature("editor"):
		args.append("--path")
		args.append(ProjectSettings.globalize_path("res://"))
	args.append("--")
	for arg in OS.get_cmdline_user_args():
		if not arg.begins_with("--engine=") and not arg.begins_with("--sample="):
			args.append(arg)
	args.append("--engine=%s" % id)
	if _current_name != "":
		args.append("--sample=%s" % _current_name)
	return args


## Which native server is ACTUALLY running.
##
## The project setting cannot be trusted: an unregistered name falls back to
## DEFAULT silently, so a typo would mislabel the whole session, and
## PhysicsServer3D.get_class() returns "PhysicsServer3D" for both native
## engines. Behaviour discriminates. JoltPhysicsServer3D::get_process_info() is
## literally `return 0;`, so these counters read the real numbers under
## GodotPhysics3D and zero under Jolt. Verified on 4.7.stable.
func _identify_native() -> String:
	if PhysicsServer3D.get_class() == "PhysicsServer3DDummy":
		return "Dummy"
	# The rig's own count, or anything spawned since (emitter scenes start
	# with zero dynamic bodies and grow them at runtime).
	if _native_dynamic <= 0 and not _any_live_dynamic():
		return ""  # nothing to probe with; stay honest rather than guess
	# All three counters, not just active objects: a scene that has already
	# settled reports 0 awake bodies under GodotPhysics too, but keeps a live
	# collision-pair count. Under Jolt every one of them is 0 always.
	var signals := 0
	signals += PhysicsServer3D.get_process_info(PhysicsServer3D.INFO_ACTIVE_OBJECTS)
	signals += PhysicsServer3D.get_process_info(PhysicsServer3D.INFO_COLLISION_PAIRS)
	signals += PhysicsServer3D.get_process_info(PhysicsServer3D.INFO_ISLAND_COUNT)
	return "Godot Physics" if signals > 0 else "Jolt Physics"


func _any_live_dynamic() -> bool:
	var world = _current.get_node_or_null("Box3DWorld") if _current != null else null
	if world == null:
		return false
	return not world.find_children("*", "RigidBody3D", true, false).is_empty()


func _check_engine() -> void:
	if not _native():
		_engine_probed = true
		return
	var live := _identify_native()
	if live == "":
		return  # nothing to probe with yet; stay unprobed and retry
	_engine_probed = true
	_engine_live = live
	var want: String = String(ENGINE_TITLES[_engine])
	if live != want:
		_engine_alert = "ENGINE MISMATCH: asked for %s, running %s" % [want, live]
		push_error("[engine] " + _engine_alert)
		print("[engine] " + _engine_alert)
	else:
		print("[engine] running %s (verified)" % live)
	_update_engine_note()
	var world = null if _current == null else _current.get_node_or_null("Box3DWorld")
	if world != null and "engine_name" in world:
		world.engine_name = live


## The badge beside the hint: what is really stepping the bodies, and how much
## of the sample the rig could not carry across. Box3D runs the scene as
## authored and has nothing to report, so it shows nothing at all.
func _update_engine_note() -> void:
	if not _native():
		_engine_note.visible = false
		return
	var parts := PackedStringArray()
	if _engine_alert != "":
		parts.append(_engine_alert)
	elif _engine_live != "":
		parts.append("Running: " + _engine_live)
	else:
		parts.append("Running: %s (unverified)" % ENGINE_TITLES[_engine])
	if not _native_notes.is_empty():
		parts.append("%d port note%s" % [_native_notes.size(),
				"" if _native_notes.size() == 1 else "s"])
	_engine_note.text = "   ·   ".join(parts)
	_engine_note.tooltip_text = "\n".join(PackedStringArray(_native_notes))
	_engine_note.modulate = Color(1, 0.45, 0.4) if _engine_alert != "" else Color(1, 0.8, 0.4)
	_engine_note.visible = true


## Phones/tablets: scale the whole UI up to a readable physical size, and add
## the touch overlay (virtual joystick / SHOOT / JUMP -- touch_controls.gd).
## Desktop has no touchscreen, so none of this runs there and the demo is
## exactly what it always was.
func _setup_touch() -> void:
	if not DisplayServer.is_touchscreen_available():
		return
	# The project lays the UI out for a 1080p desktop monitor; on a phone that
	# UI is physically tiny. DPI would be the natural scale source, but web
	# browsers report a fake 96 dpi, so the scale comes from the stretched
	# canvas instead: with the 'expand' stretch the shorter side always spans
	# 1080 logical px in landscape (1920 in portrait) whatever the device, and
	# dividing that down to ~480 keeps text readable on a phone. Recomputed on
	# resize so rotating the device rescales with it.
	_apply_touch_scale()
	get_window().size_changed.connect(_apply_touch_scale)
	# The scaled-up bar can outgrow the screen on samples with extra buttons;
	# trim the hint text with an ellipsis instead of letting it run under the
	# right-anchored Settings/Debug/Reset cluster.
	_info.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	# The settings sidebar and the sample picker move to a layer ABOVE the
	# touch overlay (which sits on layer 10 so its buttons beat the shell UI).
	# Left underneath it, the joystick's input rect — most of the lower-left
	# screen — swallowed every drag over the panels ("can't scroll except by
	# the scrollbar") and the stick drew on top of them. Above it, an open
	# panel occludes the stick both visually and for input.
	_touch_layer = CanvasLayer.new()
	_touch_layer.layer = 15
	add_child(_touch_layer)
	var ui: Node = _sidebar.get_parent()
	ui.remove_child(_sidebar)
	_touch_layer.add_child(_sidebar)
	# The default panel style is translucent — fine over a desktop scene, but
	# with game controls underneath it reads as broken. Solid on mobile.
	_sidebar.add_theme_stylebox_override("panel", _touch_panel_style())
	# Wider than desktop's 308: the scrollbar eats width, and the row labels
	# clip at the bigger fonts otherwise.
	_sidebar.offset_left = -384.0
	# The sidebar is scrollable on every platform (_make_sidebar_scrollable);
	# touch additionally needs a drag deadzone and pass-through so a finger
	# drag anywhere on the panel scrolls it, not just the scrollbar.
	_side_scroll.scroll_deadzone = 24  # a slightly wobbly tap still hits controls
	_pass_through_for_scroll(_side_scroll.get_node("Margin"))
	_setup_touch_sample_picker()
	_touch = TouchControls.new()
	_touch.setup(_camera)
	add_child(_touch)


## One scale for every touch platform, derived from the post-stretch canvas
## (never from content_scale_factor itself, so re-running is stable). Capped:
## above ~2.75 the top bar outgrows a portrait phone's width.
func _apply_touch_scale() -> void:
	var win := Vector2(get_window().size)
	if win.x <= 0.0 or win.y <= 0.0:
		return
	var base := Vector2(
			ProjectSettings.get_setting("display/window/size/viewport_width"),
			ProjectSettings.get_setting("display/window/size/viewport_height"))
	var stretch := minf(win.x / base.x, win.y / base.y)
	if stretch <= 0.0:
		return
	# Two goals pull against each other: text toward a readable physical size
	# (shorter side toward ~480 logical px) without the fixed-width top bar
	# outgrowing a narrow-aspect device (longer side kept >= ~1100). The min
	# takes whichever is the tighter constraint, so a 16:9 phone gets a
	# smaller-but-complete UI instead of a readable-but-clipped one.
	var short_logical := minf(win.x, win.y) / stretch
	var long_logical := maxf(win.x, win.y) / stretch
	get_window().content_scale_factor = clampf(
			minf(short_logical / 480.0, long_logical / 1100.0), 1.0, 2.5)


## The MenuButton's popup is desktop furniture: a 69-row list that scrolls on
## hover and reads at desktop sizes. On touch it is swapped for a left-side
## panel of big drag-scrollable rows, the mirror image of the settings sidebar.
##
## The desktop menu's structure is mirrored here rather than reinvented: one
## COLLAPSIBLE section per category (a finger cannot hover a submenu open, so
## nesting becomes folding), the current sample's row outlined, and the current
## category expanded and scrolled to whenever the panel is opened.
func _setup_touch_sample_picker() -> void:
	var bar: Control = _menu.get_parent()
	var btn := Button.new()
	btn.text = "Samples"
	btn.focus_mode = Control.FOCUS_NONE
	btn.toggle_mode = true
	bar.add_child(btn)
	bar.move_child(btn, _menu.get_index())
	_menu.visible = false
	btn.toggled.connect(func(on: bool):
		_sample_panel.visible = on
		if on:
			_reveal_current_sample())

	_sample_panel = PanelContainer.new()
	_sample_panel.visible = false
	_sample_panel.anchor_bottom = 1.0
	_sample_panel.offset_left = 12.0
	_sample_panel.offset_top = 56.0
	_sample_panel.offset_right = 384.0
	_sample_panel.offset_bottom = -12.0
	_sample_panel.add_theme_stylebox_override("panel", _touch_panel_style())
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.scroll_deadzone = 24
	_sample_panel.add_child(scroll)
	_sample_scroll = scroll
	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(vbox)
	_touch_rows.clear()
	_touch_sections.clear()
	for category in SAMPLES:
		var head := Button.new()
		head.toggle_mode = true
		head.focus_mode = Control.FOCUS_NONE
		head.alignment = HORIZONTAL_ALIGNMENT_LEFT
		head.custom_minimum_size = Vector2(0.0, 44.0)
		head.add_theme_color_override("font_color", Color(1, 1, 1, 0.6))
		vbox.add_child(head)
		var section := VBoxContainer.new()
		section.visible = false
		vbox.add_child(section)
		_touch_sections[category] = {"head": head, "box": section}
		head.toggled.connect(func(on: bool):
			section.visible = on
			_refresh_touch_headers())
		for sample_name in SAMPLES[category]:
			var row := Button.new()
			row.text = sample_name
			row.focus_mode = Control.FOCUS_NONE
			row.alignment = HORIZONTAL_ALIGNMENT_LEFT
			row.custom_minimum_size = Vector2(0.0, 48.0)
			row.tooltip_text = _sample_tooltip(sample_name)
			var path: String = SAMPLES[category][sample_name]
			var title: String = sample_name
			row.pressed.connect(func():
				btn.button_pressed = false  # also hides the panel via toggled
				_load(path, title))
			section.add_child(row)
			_touch_rows[sample_name] = row
	_refresh_touch_headers()
	_pass_through_for_scroll(vbox)
	_touch_layer.add_child(_sample_panel)


## Fold arrow, category, a bullet when the current sample is inside it, and how
## many samples it holds -- a folded section otherwise says nothing about what
## it is hiding.
func _refresh_touch_headers() -> void:
	var current_cat := category_of(_current_name)
	for category in _touch_sections:
		var head: Button = _touch_sections[category]["head"]
		head.text = "%s %s%s (%d)" % [
			"v" if head.button_pressed else ">",
			"• " if category == current_cat else "",
			category,
			SAMPLES[category].size(),
		]


## The touch picker's answer to the popup's radio check: the current row keeps
## an outlined, tinted background so it is findable at a glance in a list of
## identical buttons.
func _mark_touch_current() -> void:
	if _sample_panel == null:
		return
	for sample_name in _touch_rows:
		var row: Button = _touch_rows[sample_name]
		if sample_name == _current_name:
			row.add_theme_stylebox_override("normal", _touch_current_row_style())
			row.add_theme_color_override("font_color", Color(1, 1, 1))
		else:
			row.remove_theme_stylebox_override("normal")
			row.remove_theme_color_override("font_color")
	_refresh_touch_headers()


func _touch_current_row_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.16, 0.34, 0.46, 0.85)
	sb.border_color = Color(0.45, 0.82, 1.0, 0.95)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(4)
	sb.set_content_margin_all(6)
	return sb


## Opening the panel should land on the sample you are running, not on the top
## of an alphabet of categories: expand the one holding it and scroll its row
## into view. Deferred by a frame because a section that has just been unfolded
## has no size yet and ensure_control_visible would aim at the wrong place.
func _reveal_current_sample() -> void:
	var current_cat := category_of(_current_name)
	if current_cat.is_empty():
		return
	var section: Dictionary = _touch_sections.get(current_cat, {})
	if not section.is_empty():
		var head: Button = section["head"]
		head.button_pressed = true  # toggled shows the box and relabels
	var row: Button = _touch_rows.get(_current_name)
	if row == null or _sample_scroll == null:
		return
	await get_tree().process_frame
	if is_instance_valid(row) and is_instance_valid(_sample_scroll):
		_sample_scroll.ensure_control_visible(row)


## A Control whose mouse_filter is STOP (every Button/CheckBox default) ends
## event propagation at itself even when it doesn't handle the event, so a
## touch drag that starts on one never reaches the ScrollContainer and the
## list refuses to pan. PASS keeps taps working — the ScrollContainer sends
## NOTIFICATION_SCROLL_BEGIN once the drag passes its deadzone, which cancels
## the button's press — while letting the drag bubble up and scroll. SpinBox
## and LineEdit keep their own rect: text-selection drags should not pan.
func _pass_through_for_scroll(node: Node) -> void:
	for child in node.get_children():
		if child is SpinBox or child is LineEdit:
			continue
		if child is Control and child.mouse_filter == Control.MOUSE_FILTER_STOP:
			child.mouse_filter = Control.MOUSE_FILTER_PASS
		_pass_through_for_scroll(child)


## Solid panel background for the mobile overlays. The theme default is
## translucent, which reads fine over a desktop scene but looks broken with
## the joystick and scene controls underneath.
func _touch_panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.12, 0.14, 0.18, 1.0)
	style.set_corner_radius_all(10)
	style.content_margin_left = 8.0
	style.content_margin_top = 8.0
	style.content_margin_right = 8.0
	style.content_margin_bottom = 8.0
	return style


func _physics_process(_delta: float) -> void:
	_step_count += 1
	if _profiler.visible:
		_profiler.poll()
	if _shot_path != "" and _step_count == _shot_tick:
		_save_shot()
	# Identify the live server once per sample, late enough that its bodies are
	# awake -- that is what the probe reads.
	# Retries every half second until it can conclude: a scene whose dynamic
	# bodies are all spawned at runtime (Ball Flood) has nothing to probe with
	# at tick 12 and used to stay "(unverified)" forever.
	if _native() and not _engine_probed and _step_count >= ENGINE_PROBE_TICK \
			and (_step_count - ENGINE_PROBE_TICK) % 30 == 0:
		_check_engine()
	if _sidebar.visible:
		_update_readout()
	# The recording readout is a byte count climbing, so 4 Hz is plenty and a
	# per-frame refresh would be the only cost recording adds to the shell.
	if _recorder.is_recording():
		# F-048: the appearance capture that used to happen all at once on the
		# Stop click is amortised here instead, a slice a frame. Sub-0.1 ms per
		# call on every sample measured, and it stops of its own accord once it
		# has been round the world.
		_recorder.poll_capture()
		if _step_count % 15 == 0:
			_update_record_indicator()
	elif _recorder.is_saving():
		# Only does anything on a build with no threads (the single-threaded web
		# fallback), where the save is sliced across frames instead.
		_recorder.poll_save()
	# Body counting is a full tree walk, so refresh the overlay's count at 1 Hz.
	if _stats_overlay.visible and _step_count % 60 == 0:
		_push_stats_bodies()
	# The bottom-of-screen counter refreshes faster (4 Hz): watching the number
	# climb is its entire job in the stress scenes.
	if _body_count_label.visible and _step_count % 15 == 0:
		_update_body_count()
	# Catch bodies spawned after the toggle (emitters, shots): re-hide their
	# visuals every half second while the debug view is on. The walk touches
	# every node (16k+ in the big samples), so skip it while the tree hasn't
	# changed size — nothing new can need hiding then.
	if _debug_draw and _step_count % 30 == 0 and _current != null:
		var node_count := get_tree().get_node_count()
		if node_count != _debug_hidden_node_count:
			_debug_hidden_node_count = node_count
			var world = _current.get_node_or_null("Box3DWorld")
			if world != null:
				_hide_shelled_visuals(world)


func _on_reset() -> void:
	# Rebuild the physics demo from scratch but LEAVE THE CAMERA where it is, so
	# a view you flew to survives a reset.
	if _current_path != "":
		_load(_current_path, _current_name, true)


func _on_shot_mode_selected(index: int) -> void:
	if _camera.has_method("set_shot_kind"):
		_camera.set_shot_kind(index)
	# The blast slider only means something while F fires bombs.
	var bomb_mode := index == 1
	_blast_label.visible = bomb_mode
	_blast_slider.visible = bomb_mode
	_impact_check.visible = bomb_mode


func _on_impact_toggled(pressed: bool) -> void:
	if "bomb_impact_detonation" in _camera:
		_camera.bomb_impact_detonation = pressed


func _on_blast_changed(value: float) -> void:
	_blast_label.text = "Blast: %d" % int(value)
	if "bomb_blast_impulse" in _camera:
		_camera.bomb_blast_impulse = value


func _on_activate() -> void:
	# Reusable: fire the current sample's activate() action, if it has one.
	if _current != null and _current.has_method("activate"):
		_current.activate()


func _on_sample_toggle(pressed: bool) -> void:
	if _current != null and _current.has_method("set_toggled"):
		_current.set_toggled(pressed)


func _on_debug_toggled(pressed: bool) -> void:
	# Global overlay: draw every body's collider wireframe in the current sample.
	_debug_draw = pressed
	_sidebar_debug_check.set_pressed_no_signal(pressed)
	_apply_debug()


func _apply_debug() -> void:
	# F-038. A replay used to draw itself in the debug shells' own flat state-
	# palette treatment whatever this switch said, so opening the timeline with
	# Debug off put a debug view on screen while the checkbox still read off.
	# The timeline follows the switch instead, in both directions, and NEVER
	# writes back to it -- which is why the two cannot desync, and why leaving a
	# replay restores nothing: nothing was changed to restore.
	if _replay != null and is_instance_valid(_replay):
		_replay.set_debug_style(_debug_draw)
	if _current == null:
		return
	var world = _current.get_node_or_null("Box3DWorld")
	if world != null and "debug_draw" in world:
		world.debug_draw = _debug_draw
	# The debug shells REPLACE the sample's look, like upstream's viewer: hide
	# every shelled body's own visuals so nothing pokes through the shells, and
	# restore them when the toggle goes off.
	if _debug_draw:
		if world != null:
			_hide_shelled_visuals(world)
			_debug_hidden_node_count = get_tree().get_node_count()
	else:
		for mi in _debug_hidden:
			if is_instance_valid(mi):
				mi.visible = true
		_debug_hidden.clear()
		_debug_hidden_node_count = -1


## Bodies the world shells (primitive shape types or compound children) get
## their MeshInstance3D visuals hidden. Hull/mesh bodies and bodies opted out
## via debug_visualize keep their looks — they have no shell covering them.
func _hide_shelled_visuals(node: Node) -> void:
	if node is Box3DBody and node.debug_visualize:
		var shelled: bool = node.shape_type <= Box3DBody.CONE
		if not shelled:
			for child in node.get_children():
				if child is Box3DCollisionShape:
					shelled = true
					break
		if shelled:
			_hide_visuals_under(node)
			return
	for child in node.get_children():
		_hide_shelled_visuals(child)


func _hide_visuals_under(node: Node) -> void:
	for child in node.get_children():
		if child is MeshInstance3D and child.visible:
			child.visible = false
			_debug_hidden.append(child)
		_hide_visuals_under(child)


## The settings column has outgrown short windows (and keeps growing), so the
## sidebar's middle scrolls on every platform. Touch layers its own deadzone
## and drag pass-through on top of this later.
func _make_sidebar_scrollable() -> void:
	var margin: Control = _sidebar.get_node("Margin")
	_side_scroll = ScrollContainer.new()
	_side_scroll.name = "SideScroll"
	_side_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_sidebar.remove_child(margin)
	_sidebar.add_child(_side_scroll)
	_side_scroll.add_child(margin)
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.size_flags_vertical = Control.SIZE_EXPAND_FILL


## What the current sample shows, behind a small disclosure so it never takes
## sidebar space uninvited: collapsed on every sample load, revealed on click.
## The same text is the sample entry's tooltip in the picker.
##
## Sizes and alphas here are the quiet end of the sidebar's scale, not the
## faint end: the block is meant to be read comfortably once it is open, while
## still sitting below the controls in the visual order. The use case line is
## one step smaller and dimmer again so it reads as a footnote to the blurb.
func _build_sample_blurb() -> void:
	var vbox: Control = _side_scroll.get_node("Margin/VBox")
	_sample_blurb_toggle = Button.new()
	_sample_blurb_toggle.name = "SampleBlurbToggle"
	_sample_blurb_toggle.toggle_mode = true
	_sample_blurb_toggle.flat = true
	_sample_blurb_toggle.focus_mode = Control.FOCUS_NONE
	_sample_blurb_toggle.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_sample_blurb_toggle.add_theme_color_override("font_color", Color(1, 1, 1, 0.8))
	_sample_blurb_toggle.add_theme_font_size_override("font_size", 13)
	# The two labels ride together in a margin container: one show/hide for the
	# whole block, and a few px of air before the controls under it.
	var box := MarginContainer.new()
	box.name = "SampleBlurbBox"
	box.add_theme_constant_override("margin_bottom", 8)
	box.visible = false
	_sample_blurb_box = box
	var text_vbox := VBoxContainer.new()
	text_vbox.name = "SampleBlurbText"
	text_vbox.add_theme_constant_override("separation", 4)
	box.add_child(text_vbox)
	_sample_blurb = Label.new()
	_sample_blurb.name = "SampleBlurb"
	_sample_blurb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_sample_blurb.add_theme_color_override("font_color", Color(1, 1, 1, 0.8))
	_sample_blurb.add_theme_font_size_override("font_size", 13)
	text_vbox.add_child(_sample_blurb)
	_sample_use_case = Label.new()
	_sample_use_case.name = "SampleUseCase"
	_sample_use_case.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_sample_use_case.add_theme_color_override("font_color", Color(1, 1, 1, 0.6))
	_sample_use_case.add_theme_font_size_override("font_size", 12)
	_sample_use_case.visible = false
	text_vbox.add_child(_sample_use_case)
	_sample_blurb_toggle.toggled.connect(func(pressed: bool) -> void:
		_sample_blurb_box.visible = pressed and not _sample_blurb.text.is_empty()
		_update_blurb_toggle_text())
	vbox.add_child(_sample_blurb_toggle)
	vbox.add_child(box)
	# Above the sidebar's own "Solver" title, so it reads as being about the
	# sample rather than about the controls under it.
	vbox.move_child(_sample_blurb_toggle, 0)
	vbox.move_child(box, 1)


## Picker tooltip for a sample: the description, plus the use case on its own
## line where there is one. Empty for a sample with no description at all.
func _sample_tooltip(sample_name: String) -> String:
	var blurb: String = DESCRIPTIONS.get(sample_name, "")
	if blurb.is_empty():
		return ""
	var use_case: String = USE_CASES.get(sample_name, "")
	return blurb if use_case.is_empty() else "%s\nUse case: %s" % [blurb, use_case]


func _update_blurb_toggle_text() -> void:
	var arrow := "v" if _sample_blurb_toggle.button_pressed else ">"
	_sample_blurb_toggle.text = "%s About this sample" % arrow


# --- Recording (F-R2): capture any sample, from the sidebar ------------------

## Upstream's Recording panel, ported: two ways to arm and one to stop
## (`samples/sample.cpp:2005-2033`).
##
##  * "Record (restart)" restarts the sample and arms at step 0, so the file is
##    a whole clean session -- upstream's `SelectSample( ..., true )` followed by
##    `StartRecording()` (`sample.cpp:2014-2018`), in that order.
##  * "Record now" arms the world as it stands. This is not a lesser capture:
##    `b3World_StartRecording` seeds the buffer from a snapshot of the live
##    world (`src/recording.c:1017`), so the pile you are looking at is in the
##    file even though it was built hundreds of steps ago.
##
## EVERYTHING THE SHELL DOES IS CAPTURED, with no special casing anywhere: the
## F-key balls, the bombs and their blast impulses, the thrown ragdolls and the
## mouse grab joint are all ordinary Box3D mutations of the recorded world, and
## world mutations are exactly what the stream is made of.
##
## The section is Box3D-only. Godot Physics and Jolt have no recording API to
## port, so on those engines it goes away entirely rather than offering buttons
## that would have to explain themselves.
func _build_record_section() -> void:
	var vbox: Control = _side_scroll.get_node("Margin/VBox")
	var box := VBoxContainer.new()
	box.name = "RecordSection"
	box.add_theme_constant_override("separation", 6)
	_record_box = box

	box.add_child(HSeparator.new())
	var title := Label.new()
	title.text = "Recording"
	box.add_child(title)

	var arm := HBoxContainer.new()
	arm.name = "RecordArmRow"
	_record_arm_row = arm
	var restart_btn := Button.new()
	restart_btn.text = "Record (restart)"
	restart_btn.focus_mode = Control.FOCUS_NONE
	restart_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	restart_btn.tooltip_text = "Restart this sample, then capture from step 0."
	restart_btn.pressed.connect(_on_record_restart)
	arm.add_child(restart_btn)
	var now_btn := Button.new()
	now_btn.text = "Record now"
	now_btn.focus_mode = Control.FOCUS_NONE
	now_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	now_btn.tooltip_text = "Capture from here. The world as it stands is seeded into the file."
	now_btn.pressed.connect(_on_record_now)
	arm.add_child(now_btn)
	box.add_child(arm)

	_record_stop_btn = Button.new()
	_record_stop_btn.text = "Stop and save"
	_record_stop_btn.focus_mode = Control.FOCUS_NONE
	_record_stop_btn.visible = false
	_record_stop_btn.pressed.connect(_on_record_stop)
	box.add_child(_record_stop_btn)

	# The status line and its busy indicator share a row so the spinner sits
	# BESIDE the text rather than above it, and so hiding the spinner leaves the
	# text exactly where it was: the row keeps its height either way.
	var status_row := HBoxContainer.new()
	status_row.name = "RecordStatusRow"
	status_row.add_theme_constant_override("separation", 6)
	_record_spinner = ShellSpinner.make(16.0, Color(0.35, 0.85, 0.6))
	status_row.add_child(_record_spinner)
	_record_status = Label.new()
	_record_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_record_status.add_theme_font_size_override("font_size", 12)
	_record_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status_row.add_child(_record_status)
	_record_status_row = status_row
	status_row.visible = false
	box.add_child(status_row)

	# Playback (F-R3). A popup listing user://recordings rather than a file
	# dialog: the shell has no native picker to offer in a browser tab or on
	# Android, and that directory is the only place it ever writes.
	var replay_row := HBoxContainer.new()
	replay_row.name = "ReplayRow"
	_record_replay_row = replay_row
	_record_open_btn = MenuButton.new()
	_record_open_btn.text = "Open recording"
	_record_open_btn.focus_mode = Control.FOCUS_NONE
	_record_open_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_record_open_btn.about_to_popup.connect(_refresh_replay_menu)
	_record_open_btn.get_popup().id_pressed.connect(_on_replay_menu_id)
	replay_row.add_child(_record_open_btn)
	_record_last_btn = Button.new()
	_record_last_btn.text = "Replay last"
	_record_last_btn.focus_mode = Control.FOCUS_NONE
	_record_last_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_record_last_btn.tooltip_text = "Play back the recording that was saved most recently."
	_record_last_btn.pressed.connect(func() -> void: _enter_replay(ShellRecorder.last_path()))
	replay_row.add_child(_record_last_btn)
	box.add_child(replay_row)

	vbox.add_child(box)
	# Above the engine selector, below the world controls: it is about the
	# sample, not about which solver is running it.
	vbox.move_child(box, _engine_sep.get_index())

	# The sidebar starts closed and a recording can run for minutes, so the same
	# state also rides in the top bar where it cannot be hidden by accident.
	_rec_pill = Label.new()
	_rec_pill.name = "RecPill"
	_rec_pill.visible = false
	_rec_pill.add_theme_color_override("font_color", Color(1.0, 0.42, 0.42))
	_bar.add_child(_rec_pill)
	# F-048: the top bar carries the SAVING state too, for the same reason it
	# carries the REC one -- the sidebar starts closed, and "why is the Stop
	# button gone?" must be answerable without opening it.
	_rec_spinner = ShellSpinner.make(16.0, Color(1.0, 0.42, 0.42))
	_rec_spinner.name = "RecSpinner"
	_bar.add_child(_rec_spinner)

	_recorder.save_finished.connect(_on_record_saved)
	_update_record_ui()


func _record_world():
	if _current == null:
		return null
	return _current.get_node_or_null("Box3DWorld")


func _on_record_restart() -> void:
	if _recorder.is_recording():
		return
	# Restart FIRST, arm second: upstream's order, and the reason the two
	# buttons differ at all (`samples/sample.cpp:2014-2018`). Reset's own
	# keep-the-camera behaviour is kept, so the view you framed the shot from
	# survives the restart.
	if _current_path != "":
		_load(_current_path, _current_name, true)
	_arm_recording()


func _on_record_now() -> void:
	if _recorder.is_recording():
		return
	_arm_recording()


func _arm_recording() -> void:
	if _recorder.start(_record_world(), _current_name, _step_count):
		_flash_info("Recording from step %d" % _recorder.start_step)
	else:
		_flash_info("Recording could not start on this world")
	_update_record_ui()


## THE CLICK THE FIX IS ABOUT (F-048). It stops the session and hands the two
## files to a background thread, which is why it does NOT report a save here:
## the path it has is a promise, and `_on_record_saved` reports the receipt.
## What the user sees in between is the record indicator turning into a
## "Saving..." with a spinner, and the replay controls staying out of reach --
## an honest busy state instead of a frozen window.
func _on_record_stop() -> void:
	var saved := _stop_recording()
	if saved.is_empty():
		_flash_info("Recording not saved: %s" % _recorder.last_error)
	else:
		_flash_info("Saving %s..." % saved.get_file())


## The background save landed. Fires on the main thread, once per stop.
func _on_record_saved(path: String, error: String) -> void:
	if not error.is_empty():
		_flash_info("Recording not saved: %s" % error)
	elif not path.is_empty():
		_flash_info("Saved %s" % path.get_file())
	_update_record_ui()


## Stop and WRITE. Also the single teardown path: a sample switch, a Reset, an
## engine switch and quitting all come through here.
##
## SAVE, NOT DISCARD, and that is upstream's answer rather than a preference.
## `Sample::~Sample()` and `Sample::CreateWorld()` both call `FinishRecording()`
## before destroying the world (`samples/sample.cpp:343-348` and `:386-391`),
## and `FinishRecording` writes the file (`:367-383`). Switching sample in
## upstream's viewer destroys the sample, so a recording in flight is written
## out, not thrown away. Discarding would also be the crueller default: the
## bytes are unrecoverable and the file is cheap.
func _stop_recording() -> String:
	if not _recorder.is_recording():
		return ""
	var saved := _recorder.stop()
	_update_record_ui()
	return saved


func _update_record_ui() -> void:
	# `is_instance_valid`, not a null test: _exit_tree stops a live session
	# while the UI may already be coming down around it.
	if _record_box == null or not is_instance_valid(_record_box):
		return
	var live := _recorder.is_recording()
	var saving := _recorder.is_saving()
	var replaying := _replay != null and is_instance_valid(_replay)
	# SAVING IS ITS OWN STATE, and the section says so honestly: the session is
	# over (no Stop button, and clicking it again must be impossible), the file
	# is not there yet (no replay row -- "Replay last" would open a recording
	# that is still being written), and neither is a new session (no arm row,
	# because arming would have to join the save it is meant to be hiding).
	_record_arm_row.visible = not live and not replaying and not saving
	_record_stop_btn.visible = live
	_record_stop_btn.disabled = saving
	_record_replay_row.visible = not live and not replaying and not saving
	_rec_pill.visible = live or saving
	_rec_spinner.visible = saving
	# Probed here rather than per frame: it is a stat() on a remembered path.
	_record_last_btn.disabled = ShellRecorder.last_path().is_empty()
	if replaying:
		_record_status.add_theme_color_override("font_color", Color(1, 1, 1, 0.6))
		_record_status.text = "Replaying. Close the timeline to come back to the sample."
		_record_status_row.visible = true
		_record_spinner.visible = false
		return
	if saving:
		# Deliberately the SAME green the live indicator uses: this is the tail
		# of the recording, not a new kind of event, and the spinner is what
		# says it is still going.
		_record_status.add_theme_color_override("font_color", Color(0.35, 0.85, 0.6))
		_record_status.text = "Saving the recording..."
		_record_status_row.visible = true
		_record_spinner.visible = true
		_rec_pill.text = "SAVING"
		return
	_record_spinner.visible = false
	if live:
		_record_status.add_theme_color_override("font_color", Color(0.35, 0.85, 0.6))
		_record_status.text = _recorder.status_text()
		_record_status_row.visible = true
	elif not _recorder.last_error.is_empty():
		_record_status.add_theme_color_override("font_color", Color(1.0, 0.5, 0.45))
		_record_status.text = "Not saved: %s" % _recorder.last_error
		_record_status_row.visible = true
	elif not _recorder.last_saved.is_empty():
		_record_status.add_theme_color_override("font_color", Color(1, 1, 1, 0.6))
		_record_status.text = "Saved %s" % _recorder.last_saved.get_file()
		_record_status_row.visible = true
	else:
		_record_status_row.visible = false
	_update_record_indicator()


## The climbing byte count, refreshed on a timer rather than on an event. Cheap:
## `b3Recording_GetSize` is live during a session, unlike the bytes themselves.
func _update_record_indicator() -> void:
	if not _recorder.is_recording():
		return
	var text := _recorder.status_text()
	_record_status.text = text
	_rec_pill.text = "REC  %s" % text


# --- Replay (F-R3): the timeline takes over the viewport ---------------------

## Fill the Open menu from `user://recordings`, newest first. Rebuilt on every
## popup because a recording can be made between two openings of it.
func _refresh_replay_menu() -> void:
	var popup: PopupMenu = _record_open_btn.get_popup()
	popup.clear()
	_replay_paths = ShellRecorder.list_saved()
	if _replay_paths.is_empty():
		popup.add_item("No recordings yet", -1)
		popup.set_item_disabled(0, true)
		return
	# Enough to pick from without turning into a scrolling wall.
	var shown := mini(_replay_paths.size(), 24)
	for i in range(shown):
		popup.add_item(_replay_paths[i].get_file(), i)


func _on_replay_menu_id(id: int) -> void:
	if id < 0 or id >= _replay_paths.size():
		return
	_enter_replay(_replay_paths[id])


## Hand the viewport to a recording.
##
## The live sample is PAUSED AND HIDDEN rather than freed: a recording is a
## different world standing beside this one, not this one rewound (the player
## builds its own world and retargets every recorded id onto it), and keeping
## the sample means coming back is a restart rather than a reload from disk.
func _enter_replay(path: String) -> void:
	# F-048: a recording still being written is not openable, and the buttons
	# that lead here are hidden while a save is in flight. This is the belt to
	# that braces -- `--replay=` and a script can still arrive mid-save.
	_recorder.flush_save()
	if path.is_empty() or not FileAccess.file_exists(path):
		_flash_info("No recording to replay yet -- record one first")
		return
	var carried := _stop_recording()
	if not carried.is_empty():
		# Entering replay straight after arming is a plausible slip; the file is
		# written rather than lost, as everywhere else -- and waited for, since
		# the very next thing this does is open a file from that directory.
		_recorder.flush_save()
		print("[shell] recording saved before replay -> %s" % carried)
	_teardown_replay()

	_set_live_stepping(false)
	if _current != null:
		_current.visible = false
	# The web banner is bottom-wide and so is the timeline.
	var notice := $UI.get_node_or_null("WebNotice")
	if notice != null:
		notice.visible = false

	var bar := ReplayTimeline.new()
	bar.name = "ReplayTimeline"
	# F-038: the timeline inherits the debug state the shell is already in,
	# before it opens anything, so the first frame drawn is already right.
	bar.set_debug_style(_debug_draw)
	$UI.add_child(bar)
	if not bar.open_recording(path, _host):
		bar.queue_free()
		if _current != null:
			_current.visible = true
		_set_live_stepping(true)
		if notice != null:
			notice.visible = true
		_flash_info("Could not open %s" % path.get_file())
		return
	_replay = bar
	bar.closed.connect(_exit_replay)
	# Detach the camera from the live world WITHOUT moving it: a shot or a grab
	# would otherwise land in a world that is hidden and not stepping.
	# set_world_keep_view is the no-move door; plain set_world would re-pose.
	_camera.set_world_keep_view(null)
	_update_record_ui()
	# Printed, not just flashed: `--replay=` makes this scriptable, and a run
	# that silently failed to enter replay would otherwise look like a run that
	# entered it and drew nothing.
	print("[shell] replaying %s (%d frames)" % [path, bar.get_frame_count()])
	_flash_info("Replaying %s   ·   Close returns to the sample" % path.get_file())


## THE CAMERA IS NEVER WRITTEN TO BY REPLAY -- a deliberate deviation from
## upstream (user decision, 2026-08-08). Upstream's replay viewer overrides
## `FocusHome` to fit the recording's own bounds (`samples/sample.h:154-156`,
## `b3RecPlayerInfo.bounds`), which reads as the view teleporting somewhere
## unrelated the moment you press play. Here replay behaves like the Reset
## button: it rebuilds what you are looking AT and leaves where you are looking
## FROM exactly alone, on entry, throughout, and on the way back out. The
## recording's own bounds are still available through `get_info()` if a framing
## affordance is ever wanted; it would have to be opt-in.


## Free the bar without touching the sample. Idempotent, and safe to call from
## `_load`, which is where a sample switch made from inside replay arrives.
func _teardown_replay() -> void:
	if _replay == null:
		return
	var bar := _replay
	_replay = null
	if is_instance_valid(bar):
		# Explicit, not left to the queued free: this releases the replay world
		# and every debug-shape handle the renderer was given, and those handles
		# are the host's to free (upstream only destroys them from
		# b3DestroyShape and from snapshot restore).
		bar.close_recording()
		bar.queue_free()
	if _current != null and is_instance_valid(_current):
		_current.visible = true
	var notice := $UI.get_node_or_null("WebNotice")
	if notice != null:
		notice.visible = true
	_update_record_ui()


## Back to the live sample. The restart path already knows how to rebuild the
## world, re-frame the spawn view, re-attach the camera and the profiler and
## push the dirty set back on, so this reuses it wholesale rather than
## un-hiding a world that has been sitting frozen.
func _exit_replay() -> void:
	if _replay == null:
		return
	_teardown_replay()
	if _current_path != "":
		# keep_camera, like the Reset button: coming back from a replay must not
		# move the view either (see the note above _teardown_replay).
		_load(_current_path, _current_name, true)


## Whether the live sample keeps stepping. Only Box3D worlds have `auto_step`;
## a native rig has no equivalent, and hiding it is enough there.
func _set_live_stepping(on: bool) -> void:
	if _current == null or not is_instance_valid(_current):
		return
	var world = _current.get_node_or_null("Box3DWorld")
	if world != null and "auto_step" in world:
		world.auto_step = on


func _on_sidebar_toggled(pressed: bool) -> void:
	_sidebar.visible = pressed
	if pressed:
		_update_readout()


# --- Sidebar: live-edit the current sample's Box3DWorld ---

func _with_world(fn: Callable) -> void:
	if _current == null:
		return
	var world = _current.get_node_or_null("Box3DWorld")
	if world != null:
		fn.call(world)


func _on_substep_changed(value: float) -> void:
	if _updating_sidebar:
		return
	_mark_sticky("substep_count", _substep_spin, int(value))
	_with_world(func(world):
		if "substep_count" in world:
			world.substep_count = int(value))


func _on_worker_changed(value: float) -> void:
	if _updating_sidebar:
		return
	_mark_sticky("worker_count", _worker_spin, int(value))
	if _current_path != "":
		_load(_current_path, _current_name, true)


func _on_max_speed_changed(value: float) -> void:
	if _updating_sidebar:
		return
	_mark_sticky("max_linear_speed", _max_speed_spin, value)
	_with_world(func(world):
		if "max_linear_speed" in world:
			world.max_linear_speed = value)


func _on_gravity_changed(value: float) -> void:
	if _updating_sidebar:
		return
	_mark_sticky("gravity_y", _gravity_spin, value)
	_with_world(func(world):
		var g: Vector3 = world.gravity
		g.y = value
		world.gravity = g)


func _on_continuous_changed(pressed: bool) -> void:
	if _updating_sidebar:
		return
	_mark_sticky("continuous_collision", _continuous_check, pressed)
	_with_world(func(world):
		if "continuous_collision" in world:
			world.continuous_collision = pressed)


func _on_sidebar_debug_changed(pressed: bool) -> void:
	if _updating_sidebar:
		return
	_debug_draw = pressed
	_debug_toggle.set_pressed_no_signal(pressed)
	_apply_debug()


func _on_profiler_toggled(pressed: bool) -> void:
	_profiler.visible = pressed
	_save_overlay_state()


func _on_stats_toggled(pressed: bool) -> void:
	_stats_overlay.visible = pressed
	if pressed:
		_push_stats_bodies()
	_save_overlay_state()


func _on_async_toggled(pressed: bool) -> void:
	if _updating_sidebar:
		return
	_async_step = pressed
	_apply_async()


## Dropdown order for the V-Sync control; indices match the items added in
## _ready. Adaptive isn't offered (it behaves like On above the refresh rate),
## so an externally-set adaptive mode just displays as On until changed here.
const _VSYNC_MODES: Array = [
	DisplayServer.VSYNC_ENABLED,
	DisplayServer.VSYNC_DISABLED,
	DisplayServer.VSYNC_MAILBOX,
]


func _vsync_index(mode: int) -> int:
	var i: int = _VSYNC_MODES.find(mode)
	return i if i >= 0 else 0


func _on_vsync_selected(index: int) -> void:
	DisplayServer.window_set_vsync_mode(_VSYNC_MODES[index])
	# Reflect what the platform actually granted (select() doesn't re-signal).
	_vsync_option.select(_vsync_index(DisplayServer.window_get_vsync_mode()))


## async_step toggles live (the world absorbs any in-flight step when turned
## off), so unlike worker_count no reload is needed.
func _apply_async() -> void:
	_with_world(func(world):
		if "async_step" in world:
			world.async_step = _async_step)


func _on_body_count_toggled(pressed: bool) -> void:
	_body_count_label.visible = pressed
	if pressed:
		_update_body_count()
	_save_overlay_state()


func _update_body_count() -> void:
	var world = _current.get_node_or_null("Box3DWorld") if _current != null else null
	if world == null:
		_body_count_label.text = "Bodies: 0"
		return
	_body_count_label.text = "Bodies: %s" % _thousands(_count_bodies(world))


## 16290 reads better as 16,290 when the whole point is watching it grow.
func _thousands(n: int) -> String:
	var s := str(n)
	var out := ""
	while s.length() > 3:
		out = "," + s.right(3) + out
		s = s.left(s.length() - 3)
	return s + out


func _push_stats_bodies() -> void:
	if _current == null:
		_stats_overlay.bodies = -1
		_stats_overlay.world = null
		return
	var world = _current.get_node_or_null("Box3DWorld")
	_stats_overlay.bodies = _count_bodies(world) if world != null else -1
	# The overlay samples the solver itself every tick; it just needs the handle.
	_stats_overlay.world = world


# --- Start view: fly the camera somewhere, save it as this sample's spawn ---

func _on_set_start_view() -> void:
	if _current_path == "":
		return
	var xform: Transform3D = _camera.global_transform
	_start_views.set_value("views", _current_path, xform)
	_start_views.save(START_VIEWS_PATH)
	# Authoring helper: the same pose as a scene-file line, ready to paste onto
	# a sample's CameraStart node in the editor to ship it in the repo.
	DisplayServer.clipboard_set("transform = " + var_to_str(xform))
	_flash_info("Start view saved for %s   ·   transform also copied to clipboard" % _current_name)


func _on_clear_start_view() -> void:
	if _current_path == "":
		return
	if _start_views.has_section_key("views", _current_path):
		_start_views.erase_section_key("views", _current_path)
		_start_views.save(START_VIEWS_PATH)
	_flash_info("Start view cleared for %s (scene default applies on next load)" % _current_name)


## Show a transient message in the info bar, then restore the controls hint.
## The id check keeps a stale timer from clobbering a newer message or sample.
var _info_flash_id := 0

func _flash_info(msg: String) -> void:
	_info_flash_id += 1
	var id := _info_flash_id
	_info.text = msg
	await get_tree().create_timer(3.0).timeout
	if id == _info_flash_id:
		_show_controls_hint()


func _show_controls_hint() -> void:
	if _touch != null:
		_info.text = "%s      Stick: move   ·   Drag: look   ·   Touch a body: grab   ·   Two fingers: zoom / pan" % _current_name
	else:
		_info.text = "%s      Right-click: fly (WASD / Q E, Shift boost)   ·   Left-drag: grab (scroll: reel)   ·   Hold F: charge shot" % _current_name


func _on_contact_hertz_changed(value: float) -> void:
	if _updating_sidebar:
		return
	_mark_sticky("contact_hertz", _contact_hertz_spin, value)
	_with_world(func(world):
		if "contact_hertz" in world:
			world.contact_hertz = value)


func _on_contact_damping_changed(value: float) -> void:
	if _updating_sidebar:
		return
	_mark_sticky("contact_damping", _contact_damping_spin, value)
	_with_world(func(world):
		if "contact_damping" in world:
			world.contact_damping = value)


func _on_sleep_changed(pressed: bool) -> void:
	if _updating_sidebar:
		return
	_mark_sticky("enable_sleep", _sleep_check, pressed)
	_with_world(func(world):
		if "enable_sleep" in world:
			world.enable_sleep = pressed)


func _on_recycling_changed(pressed: bool) -> void:
	if _updating_sidebar:
		return
	_mark_sticky("contact_recycling", _recycling_check, pressed)
	_with_world(func(world): _set_recycling(world, pressed))


func _set_recycling(node: Node, on: bool) -> void:
	if node is Box3DBody and "contact_recycling" in node:
		node.contact_recycling = on
	for child in node.get_children():
		_set_recycling(child, on)


# --- The dirty set: sidebar edits that outlive the world they were made in ---

## Record (or drop) one user edit. Called from the control handlers only, past
## their _updating_sidebar guard, so it hears real edits and nothing else.
##
## An edit that lands back ON the control's revert baseline -- the value this
## sample loaded with -- removes the key instead of storing it, so a setting can
## be handed back to the scene without leaving the shell. That is what the ⟲
## button next to each control does: it sets the control through its own signal,
## which arrives here as an ordinary edit that happens to match the baseline.
func _mark_sticky(key: String, ctrl: Control, value: Variant) -> void:
	var info: Dictionary = _reverts.get(ctrl, {})
	if not info.is_empty() and not _revert_changed(_revert_value(ctrl), info["baseline"]):
		_sticky.erase(key)
	else:
		_sticky[key] = value


## Push the dirty set onto a freshly loaded world and onto the controls showing
## it. Settings absent from the set are left exactly as the sample authored
## them.
##
## `worker_count` is not applied here: Box3D fixes it when the world is created,
## so _load writes it onto the scene's world node before add_child runs _ready,
## and the sidebar picks the result up in _refresh_sidebar_from_world.
##
## Every property is probed with `in` first: on a native engine the rebuilt rig
## has gravity and nothing else from this list, and a build whose extension
## predates a property must not error on it.
func _apply_sticky_settings(world) -> void:
	if world == null or _sticky.is_empty():
		return
	_updating_sidebar = true
	if _sticky.has("substep_count") and "substep_count" in world:
		world.substep_count = int(_sticky["substep_count"])
		_substep_spin.set_value_no_signal(world.substep_count)
	if _sticky.has("max_linear_speed") and "max_linear_speed" in world:
		world.max_linear_speed = float(_sticky["max_linear_speed"])
		_max_speed_spin.set_value_no_signal(world.max_linear_speed)
	if _sticky.has("gravity_y") and "gravity" in world:
		var g: Vector3 = world.gravity
		g.y = float(_sticky["gravity_y"])
		world.gravity = g
		_gravity_spin.set_value_no_signal(world.gravity.y)
	if _sticky.has("continuous_collision") and "continuous_collision" in world:
		world.continuous_collision = bool(_sticky["continuous_collision"])
		_continuous_check.set_pressed_no_signal(world.continuous_collision)
	if _sticky.has("enable_sleep") and "enable_sleep" in world:
		world.enable_sleep = bool(_sticky["enable_sleep"])
		_sleep_check.set_pressed_no_signal(world.enable_sleep)
	if _sticky.has("contact_recycling") and _has_recycling:
		# Per BODY, not per world: the fresh scene's bodies all start recycling.
		var on := bool(_sticky["contact_recycling"])
		_set_recycling(world, on)
		_recycling_check.set_pressed_no_signal(on)
	if _sticky.has("contact_hertz") and "contact_hertz" in world:
		world.contact_hertz = float(_sticky["contact_hertz"])
		_contact_hertz_spin.set_value_no_signal(world.contact_hertz)
	if _sticky.has("contact_damping") and "contact_damping" in world:
		world.contact_damping = float(_sticky["contact_damping"])
		_contact_damping_spin.set_value_no_signal(world.contact_damping)
	_updating_sidebar = false


## Hand the dirty set to the process that replaces us on an engine switch.
##
## Comparing one scene on two solvers is the reason the engine selector exists,
## and comparing it at DIFFERENT substep counts would be comparing nothing --
## the same argument that already persists the overlays across the restart. The
## handoff is consumed and erased at the next startup, so it only ever crosses
## the one relaunch: a demo the user restarts themselves comes up following the
## scenes again.
func _stash_sticky_for_restart() -> void:
	var layout := ConfigFile.new()
	layout.load(SHELL_LAYOUT_PATH)
	# has_section_key first: erasing a key that was never written is an engine
	# error, not a no-op.
	if _sticky.is_empty():
		if layout.has_section_key("shell", "sticky_settings"):
			layout.erase_section_key("shell", "sticky_settings")
	else:
		layout.set_value("shell", "sticky_settings", _sticky)
	layout.save(SHELL_LAYOUT_PATH)


func _take_sticky_handoff() -> void:
	var layout := ConfigFile.new()
	if layout.load(SHELL_LAYOUT_PATH) != OK:
		return
	if not layout.has_section_key("shell", "sticky_settings"):
		return
	var handed = layout.get_value("shell", "sticky_settings")
	if handed is Dictionary:
		_sticky = (handed as Dictionary).duplicate()
	layout.erase_section_key("shell", "sticky_settings")
	layout.save(SHELL_LAYOUT_PATH)


## Controls backed by a Box3DWorld property and by nothing else. NativeWorld
## deliberately omits those properties, so one probe decides the whole set --
## and each control's PARENT is its row: the authored HBox for the spin boxes,
## the wrapper _add_revert built around each standalone check.
func _set_box3d_rows_visible(on: bool) -> void:
	for ctrl: Control in [_substep_spin, _worker_spin, _max_speed_spin,
			_continuous_check, _sleep_check, _sidebar_debug_check]:
		var row := ctrl.get_parent()
		if row is Control:
			(row as Control).visible = on
	var recycling_row := _recycling_check.get_parent()
	if recycling_row is Control:
		(recycling_row as Control).visible = on and _has_recycling
	# The debug shells are drawn by the Box3D world itself; there is nothing
	# behind the toggle on a native engine.
	_debug_toggle.visible = on
	# Same for recording: Godot Physics and Jolt have no equivalent to bind, so
	# the whole section goes rather than explaining an absence.
	if _record_box != null:
		_record_box.visible = on


# Pull the just-loaded sample's world settings into the sidebar controls
# without re-triggering the handlers above.
func _refresh_sidebar_from_world(world) -> void:
	_updating_sidebar = true
	# Reading these off a NativeWorld would error, and showing them would leave
	# dead controls on screen, so one probe gates both. With no world at all the
	# rows are left exactly as they were, as they always have been.
	var box3d_world: bool = world != null and "substep_count" in world
	if world != null:
		_set_box3d_rows_visible(box3d_world)
		if box3d_world:
			_substep_spin.set_value_no_signal(world.substep_count)
			_worker_spin.set_value_no_signal(world.worker_count)
			_max_speed_spin.set_value_no_signal(world.max_linear_speed)
			_continuous_check.set_pressed_no_signal(world.continuous_collision)
		_gravity_spin.set_value_no_signal(world.gravity.y)
		_sidebar_debug_check.set_pressed_no_signal(_debug_draw)
		if "enable_sleep" in world:
			_sleep_check.set_pressed_no_signal(world.enable_sleep)
		# A fresh sample's bodies start with recycling on (the Box3D default).
		_recycling_check.set_pressed_no_signal(true)
		# The async checkbox reflects the sticky user preference, and hides on
		# builds whose extension predates the property or refuses the feature
		# (all web builds — see the _has_async probe in _ready).
		_async_check.visible = _has_async and "async_step" in world
		_async_hint.visible = _async_check.visible
		_async_check.set_pressed_no_signal(_async_step)
		# contact_hertz / contact_damping arrived together in the binding; show
		# their rows only when the loaded build actually exposes them.
		var has_hertz: bool = "contact_hertz" in world
		_contact_hertz_row.visible = has_hertz
		_contact_damping_row.visible = has_hertz
		if has_hertz:
			_contact_hertz_spin.set_value_no_signal(world.contact_hertz)
			_contact_damping_spin.set_value_no_signal(world.contact_damping)
	else:
		_contact_hertz_row.visible = false
		_contact_damping_row.visible = false
	_updating_sidebar = false
	_update_readout()


## Body counting walks the whole sample tree, which is real work at 16k+
## bodies — refresh the cached count at most once a second.
var _body_count_cache := -1
var _body_count_step := -999


func _update_readout() -> void:
	var world = null if _current == null else _current.get_node_or_null("Box3DWorld")
	if world == null:
		_readout.text = "Physics Steps: %d\nBodies: --" % _step_count
		return
	if _step_count - _body_count_step >= 60 or _body_count_cache < 0:
		# Samples nest bodies under sub-nodes (e.g. Blocks): count descendants.
		_body_count_cache = _count_bodies(world)
		_body_count_step = _step_count
	var text := "Physics Steps: %d\nBodies: %d" % [_step_count, _body_count_cache]
	# On a native engine the readout also answers "which solver is this really",
	# from the behavioural probe rather than from the setting we asked for.
	if _native():
		var live := _engine_live
		if live == "":
			live = "%s (unverified)" % ENGINE_TITLES[_engine]
		text += "\nEngine: %s" % live
	_readout.text = text


func _count_bodies(node: Node) -> int:
	var n := 0
	for child in node.get_children():
		# PhysicsBody3D covers the rebuilt rig on a native engine; no sample has
		# one, so the Box3D count is unchanged.
		if child is Box3DBody or child is PhysicsBody3D:
			n += 1
		n += _count_bodies(child)
	return n


## The Samples dropdown: a SUBMENU per category rather than one 69-row list
## with separators in it, which is what it had grown into. Category order and
## the order inside each category are the registry's, so the menu is SAMPLES
## read out loud.
##
## The sample you are on is marked in three places, because the ask was to be
## able to see it without hunting:
##
##  * a header line at the top of the root popup naming it outright,
##  * a bullet on its CATEGORY row (menu_category_label pads every other row to
##    the same lead-in, so moving the mark never reflows the popup), and
##  * a radio check on the item itself, inside its category.
##
## Opening either popup also lands on it: `set_focused_item` draws the row in
## the hover style (the outline) and `scroll_to_item` brings it into view, so
## the menu opens looking at where you already are rather than at the top.
func _build_menu() -> void:
	var popup: PopupMenu = _menu.get_popup()
	popup.clear()
	# clear() drops the ITEMS; the submenu nodes are children and stay behind.
	for child in popup.get_children():
		if child is PopupMenu:
			popup.remove_child(child)
			child.free()
	_items.clear()
	_cat_popups.clear()
	_cat_rows.clear()
	# Index 0, kept in place and rewritten by _mark_current_sample.
	popup.add_separator("Samples")
	var id := 0
	for category in SAMPLES:
		var sub := PopupMenu.new()
		sub.name = "Cat%d" % _cat_popups.size()
		for sample_name in SAMPLES[category]:
			sub.add_radio_check_item(sample_name, id)
			var blurb: String = _sample_tooltip(sample_name)
			if not blurb.is_empty():
				sub.set_item_tooltip(sub.get_item_index(id), blurb)
			_items[id] = {
				"path": SAMPLES[category][sample_name],
				"name": sample_name,
				"category": category,
			}
			id += 1
		sub.id_pressed.connect(_on_menu_id)
		# about_to_popup is the documented hook, but a submenu is also shown
		# straight from a hover timer, so visibility_changed is the belt to its
		# braces. Focusing twice is harmless.
		sub.about_to_popup.connect(_focus_current_in_category.bind(category))
		sub.visibility_changed.connect(func():
			if sub.visible:
				_focus_current_in_category(category))
		popup.add_submenu_node_item(menu_category_label(category, false), sub)
		_cat_popups[category] = sub
		_cat_rows[category] = popup.item_count - 1
	if not popup.about_to_popup.is_connected(_focus_current_category):
		popup.about_to_popup.connect(_focus_current_category)
	_mark_current_sample()


## Point the whole picker at whatever is loaded now: the popup's header line,
## the category mark, the radio check on the item, the top-bar tooltip, and the
## touch panel's highlighted row. Called from _load, so Reset and the engine
## switch keep it honest too.
func _mark_current_sample() -> void:
	var current_cat := category_of(_current_name)
	var popup: PopupMenu = _menu.get_popup()
	if popup.item_count > 0:
		popup.set_item_text(0, "Samples" if _current_name.is_empty()
				else "Current:  %s" % _current_name)
	for category in _cat_popups:
		popup.set_item_text(_cat_rows[category],
				menu_category_label(category, category == current_cat))
		var sub: PopupMenu = _cat_popups[category]
		for i in range(sub.item_count):
			var entry: Dictionary = _items.get(sub.get_item_id(i), {})
			sub.set_item_checked(i, entry.get("name", "") == _current_name)
	_menu.tooltip_text = "Samples" if _current_name.is_empty() \
			else "Current sample: %s  (%s)" % [_current_name, current_cat]
	_mark_touch_current()


## Open the root popup on the current sample's category rather than on the top
## of the list.
func _focus_current_category() -> void:
	var row: int = _cat_rows.get(category_of(_current_name), -1)
	if row < 0:
		return
	var popup: PopupMenu = _menu.get_popup()
	popup.set_focused_item(row)
	popup.scroll_to_item(row)


## Same inside a category: the checked item is the one the submenu opens on.
func _focus_current_in_category(category: String) -> void:
	var sub: PopupMenu = _cat_popups.get(category)
	if sub == null:
		return
	for i in range(sub.item_count):
		if sub.is_item_checked(i):
			sub.set_focused_item(i)
			sub.scroll_to_item(i)
			return


func _on_menu_id(id: int) -> void:
	var entry: Dictionary = _items.get(id, {})
	if entry.is_empty():
		return
	_load(entry["path"], entry["name"])


func _load(path: String, sample_name: String, keep_camera := false) -> void:
	var fresh_sample := path != _current_path
	# A recording binds to ONE world, and this function is where every world in
	# the shell dies -- sample switch, Reset, engine switch, worker reload. Stop
	# and write first, matching upstream, which finishes the recording before it
	# destroys the world in both places it does so (`samples/sample.cpp:343-348`,
	# `:386-391`).
	var carried_over := _stop_recording()
	# F-048: a save is in flight after `_stop_recording` returns, and the world
	# it captured is about to be freed. Joined rather than left running, because
	# a sample switch already costs far more than the ~85 ms this can wait --
	# see `ShellRecorder.flush_save` for the argument.
	_recorder.flush_save()
	if not carried_over.is_empty():
		print("[shell] recording saved on sample change -> %s" % carried_over)
	# Picking a sample from inside replay leaves replay. (_exit_replay comes
	# back through here, which is why teardown is idempotent.)
	_teardown_replay()
	_debug_hidden.clear()  # the old sample's nodes are freed with it
	if _current != null:
		# Free immediately, not deferred: a queued free would leave both the
		# old and new sample alive within one frame, and two 4096-cube piles
		# overflow the per-instance shader parameter buffer (black cubes).
		_current.free()
		_current = null
	if _native():
		# Native engines cannot run the authored scene at all -- 18 samples
		# carry `: Box3DBody` annotations and common/cube.gd literally extends
		# it -- so the scene is read into a backend-neutral rig and rebuilt with
		# RigidBody3D and friends. _build_native parents the result itself: a
		# body only joins the space once it is in the tree.
		_current_path = path
		_current_name = sample_name
		_current = _build_native(path)
	else:
		var scene: PackedScene = load(path)
		if scene == null:
			return
		_current = scene.instantiate()
		_current_path = path
		_current_name = sample_name
		# worker_count only takes effect at world creation, so a user-chosen count
		# has to be written before add_child triggers _ready. Samples that author
		# their own count keep it unless the user has picked one.
		var worker_override := int(_sticky.get("worker_count", -1))
		if worker_override > 0:
			var override_world = _current.get_node_or_null("Box3DWorld")
			if override_world != null:
				override_world.worker_count = worker_override
		_host.add_child(_current)
	_step_count = 0
	_body_count_cache = -1
	_engine_probed = false
	var world = _current.get_node_or_null("Box3DWorld")
	if world != null and _camera.has_method("set_world"):
		if keep_camera:
			# Reset: rebuild the world but don't move the camera.
			_camera.set_world_keep_view(world)
		else:
			_camera.set_world(world)
			# Spawn view, by priority:
			# 1. A view saved at runtime with the sidebar's "Set Start View"
			#    button (fly to the shot, click, done).
			# 2. A node named CameraStart at the scene root. Make it a
			#    Camera3D: the editor then shows a frustum, a Preview
			#    checkbox, and View > Align Transform with View (fly the
			#    editor camera to the shot, then snap the node to it). The
			#    spawn view faces the node's -Z; give it a Node3D child named
			#    LookAt and the view aims at that point instead — two
			#    draggable position gizmos, no rotation rings.
			# 3. Script-exported camera_home / camera_look_at Vector3s.
			# (has_section_key first: get_value treats a null default as "no
			# default" and logs an error for samples with no saved view.)
			var saved_view = null
			if _start_views.has_section_key("views", path):
				saved_view = _start_views.get_value("views", path)
			var cam_start = _current.get_node_or_null("CameraStart")
			if saved_view is Transform3D:
				_camera.frame_view(saved_view.origin,
						saved_view.origin - saved_view.basis.z)
			elif cam_start is Node3D:
				var eye: Vector3 = cam_start.global_position
				var target: Vector3 = eye - cam_start.global_basis.z
				var aim = cam_start.get_node_or_null("LookAt")
				if aim is Node3D and not aim.global_position.is_equal_approx(eye):
					target = aim.global_position
				_camera.frame_view(eye, target)
			elif "camera_home" in _current and "camera_look_at" in _current:
				_camera.frame_view(_current.camera_home, _current.camera_look_at)
	_apply_debug()  # carry the debug-draw toggle into the newly loaded sample
	_apply_async()  # same for the async-step preference
	# A sample can ask for the body counter (Ball Flood, whose whole point IS
	# the number). Opting in switches it on only when the sample is freshly
	# PICKED: a same-path reload (engine switch, Reset) keeps whatever the
	# user chose, like the stats overlay and profiler keep theirs. On a
	# native engine the flag arrives as metadata (the script does not).
	var wants_counter := false
	if _current != null:
		wants_counter = bool(_current.get_meta("wants_body_counter", false)) \
				or ("wants_body_counter" in _current and _current.wants_body_counter)
	if wants_counter and fresh_sample:
		_body_count_check.set_pressed_no_signal(true)
		_body_count_label.visible = true
	if _body_count_label.visible:
		_update_body_count()
	if _stats_overlay.visible:
		_push_stats_bodies()
	_refresh_sidebar_from_world(world)
	_attach_profiler(world)
	# A newly picked sample defines fresh "original" values for the world
	# rows; a Reset of the same sample keeps them (so sticky tuning that
	# survived the reload still shows its revert button).
	if fresh_sample and not _reverts.is_empty():
		_capture_world_baselines()
	# ONLY NOW put the user's own edits back on top. The baselines above are the
	# values this sample authored, which is what makes every ⟲ a way back to the
	# scene -- and what keeps a setting nobody touched following the scene in the
	# first place.
	_apply_sticky_settings(world)
	_update_all_reverts()
	# Show the Activate button only for samples that expose an activate() action.
	_activate.visible = _current != null and _current.has_method("activate")
	# Same idea for the sample toggle (set_toggled + get_toggle_label). The
	# switch has to MATCH the sample's startup behaviour, not assume it is off:
	# a sample that loads with its effect already running (Live Geometry
	# resizing, Wind blowing) says so with get_toggle_initial() -> bool. The
	# state is only mirrored onto the switch -- set_toggled() is NOT called, so
	# the sample's own initial value stays the single source of truth.
	var has_toggle: bool = _current != null and _current.has_method("set_toggled")
	_sample_toggle.visible = has_toggle
	var toggle_on := false
	if has_toggle and _current.has_method("get_toggle_initial"):
		toggle_on = bool(_current.get_toggle_initial())
	_sample_toggle.set_pressed_no_signal(toggle_on)
	if has_toggle and _current.has_method("get_toggle_label"):
		_sample_toggle.text = _current.get_toggle_label()
	if _touch != null:
		_touch.set_sample(path)  # joystick/JUMP/key pills for samples that use them
	if _sample_blurb != null:
		var blurb: String = DESCRIPTIONS.get(sample_name, "")
		var use_case: String = USE_CASES.get(sample_name, "")
		_sample_blurb.text = "" if blurb.is_empty() else "%s: %s" % [sample_name, blurb]
		_sample_use_case.text = "" if use_case.is_empty() else "Use case: %s" % use_case
		# A sample can have a blurb and no use case, so the line carries its own
		# visibility inside the block.
		_sample_use_case.visible = not _sample_use_case.text.is_empty()
		# Collapsed on every load; the toggle only exists where there is text.
		_sample_blurb_box.visible = false
		_sample_blurb_toggle.set_pressed_no_signal(false)
		_sample_blurb_toggle.visible = not _sample_blurb.text.is_empty()
		_update_blurb_toggle_text()
	# Both pickers follow the load rather than the click, so the mark is right
	# after a Reset, an engine switch, a --sample= boot and a replay exit too.
	_mark_current_sample()
	_info_flash_id += 1  # cancel any pending flash from the previous sample
	_show_controls_hint()
	_update_engine_note()  # this sample's port notes, if it is running natively


# --- Native engines: the same sample, rebuilt for another solver -------------

## Build one sample for Godot Physics or Jolt.
##
## RigExtract reads the authored scene into a backend-neutral description --
## PackedScene.instantiate() runs _init only, so no Box3DWorld is created and no
## sample script fires -- and RigNative rebuilds it with RigidBody3D /
## CollisionShape3D / Joint3D, correcting mass, inertia, materials and collision
## filtering so the solver is the only thing that differs.
##
## The result is shaped like a sample scene on purpose: a root Node3D whose
## child "Box3DWorld" holds the bodies, because that name is what the shell, the
## camera and tests/test_shoot.gd all reach for.
func _build_native(path: String) -> Node3D:
	var stage := Node3D.new()
	stage.name = "Sample"
	var world := NativeWorld.new()
	world.name = "Box3DWorld"
	world.engine_name = ENGINE_TITLES[_engine]
	stage.add_child(world)
	# In the tree BEFORE the rig is built: a body registers with the space when
	# it enters, and NativeWorld reaches the space through the viewport.
	_host.add_child(stage)

	var rig := RigExtract.from_scene(path)
	var built := RigNative.build(rig, world)
	# Per-world gravity has no native node equivalent; NativeWorld forwards it to
	# the space. Some samples set a value of their own -- the count and how to
	# recount it live on RigExtract.NON_DEFAULT_GRAVITY_SAMPLES.
	var gravity: Vector3 = rig.get("gravity", Vector3(0, -9.8, 0))
	world.gravity = gravity

	_native_dynamic = 0
	for body in built.get("bodies", []):
		if body is RigidBody3D:
			_native_dynamic += 1
	_native_notes = []
	_native_notes.append_array(rig.get("unsupported", []))
	_native_notes.append_array(built.get("warnings", []))
	for note in _native_notes:
		print("[engine] %s: %s" % [path.get_file(), note])

	_add_native_dressing(path, stage)
	return stage


## Everything the rig does not carry.
##
## Samples park decorative meshes directly under the scene root, OUTSIDE the
## Box3DWorld -- wrecking's gantry post and arm, marble_run's chute, the Label3D
## captions -- and RigExtract only walks the world, so without this they simply
## vanish. Meshes that belong to a body are already rebuilt as that body's
## visuals and are skipped by the world test.
##
## The same throwaway instance also yields a CameraStart marker, which is what
## lets the shell's own spawn-view code below run unchanged on both engines.
func _add_native_dressing(path: String, stage: Node3D) -> void:
	var packed: PackedScene = load(path)
	if packed == null:
		return
	var root := packed.instantiate()
	if root == null:
		return
	var world := root.get_node_or_null("Box3DWorld")
	var deco := Node3D.new()
	deco.name = "Decoration"
	stage.add_child(deco)
	for node in root.find_children("*", "VisualInstance3D", true, false):
		if world != null and world.is_ancestor_of(node):
			continue
		# A nested visual already travelled inside its parent's duplicate;
		# copying it again would draw it twice.
		if _has_visual_ancestor(node, root):
			continue
		var xf := _relative_xform(node as Node3D, root)
		var copy := (node as Node3D).duplicate(0) as Node3D
		_strip_scripts(copy)
		deco.add_child(copy)
		copy.transform = xf
	# Runtime spawners survive by COPY, not by rig: an emitter is a plain
	# Node3D whose script spawns balls, so RigExtract has nothing to extract
	# and the decoration pass above skips everything under the world. Its
	# script is backend-aware (emitter.gd spawns through WorldOps), so the
	# node comes across whole -- script, exports and children -- parented
	# under the stand-in world its spawn loop looks for.
	var native_world := stage.get_node_or_null("Box3DWorld")
	var carried_emitters := 0
	if world != null and native_world != null:
		for node in root.find_children("*", "", true, false):
			var s := node.get_script() as Script
			if s == null or s.resource_path != "res://common/emitter.gd":
				continue
			var copy := (node as Node3D).duplicate() as Node3D
			native_world.add_child(copy)
			copy.transform = _relative_xform(node as Node3D, world)
			carried_emitters += 1
	# The flood's pause toggle must exist on this engine too. The authored
	# sample script cannot run here, but when it exposed a toggle AND its
	# emitters were carried, the toggle's whole job is pausing those emitters
	# -- which the stage-level forwarder does, under the authored label.
	if carried_emitters > 0 and root.has_method(&"set_toggled") \
			and root.has_method(&"get_toggle_label"):
		stage.set_script(load("res://common/native_emitter_toggle.gd"))
		stage.toggle_label = root.get_toggle_label()
	# The authored script's shell opt-ins ride across as metadata -- the
	# script itself cannot (_load reads the meta alongside the property).
	if bool(root.get("wants_body_counter")):
		stage.set_meta("wants_body_counter", true)
	_add_camera_marker(root, stage)
	root.free()


func _has_visual_ancestor(node: Node, root: Node) -> bool:
	var n: Node = node.get_parent()
	while n != null and n != root:
		if n is VisualInstance3D:
			return true
		n = n.get_parent()
	return false


## Transform of `node` relative to `root`, accumulated by walking up: the scene
## is unparented while we read it, and global_transform hard-fails outside the
## tree.
func _relative_xform(node: Node3D, root: Node) -> Transform3D:
	var xf := Transform3D.IDENTITY
	var n: Node = node
	while n != null and n != root:
		if n is Node3D:
			xf = (n as Node3D).transform * xf
		n = n.get_parent()
	return xf


## A duplicated decoration node must not carry its script: those scripts expect
## Box3D siblings that do not exist on this side, and would error on _ready.
func _strip_scripts(node: Node) -> void:
	node.set_script(null)
	for child in node.get_children():
		_strip_scripts(child)


## Reduce whichever spawn view the sample declares -- a CameraStart node with an
## optional LookAt child, or exported camera_home / camera_look_at Vector3s --
## to the CameraStart form, so _load's framing code needs no native branch. A
## plain Node3D, not a copy of the authored Camera3D: a second Camera3D entering
## the tree can take over the viewport.
func _add_camera_marker(root: Node, stage: Node3D) -> void:
	var marker := Node3D.new()
	marker.name = "CameraStart"
	var cam_start := root.get_node_or_null("CameraStart")
	if cam_start is Node3D:
		marker.transform = _relative_xform(cam_start as Node3D, root)
		var authored_aim := cam_start.get_node_or_null("LookAt")
		if authored_aim is Node3D:
			marker.add_child(_look_at_marker((authored_aim as Node3D).position))
	elif "camera_home" in root and "camera_look_at" in root:
		var home: Vector3 = root.camera_home
		var target: Vector3 = root.camera_look_at
		marker.position = home
		# LookAt is read in the marker's own space, and the marker is unrotated.
		marker.add_child(_look_at_marker(target - home))
	else:
		marker.free()  # never entered the tree, so nothing else will free it
		return
	stage.add_child(marker)


func _look_at_marker(local: Vector3) -> Node3D:
	var aim := Node3D.new()
	aim.name = "LookAt"
	aim.position = local
	return aim


# --- Settings revert buttons: a small "⟲" appears next to any sidebar
# control whose value differs from its baseline (what the sample loaded
# with, or the shell's startup default) and puts it back on click. ---

var _reverts := {}  ## Control -> {"btn": Button, "baseline": Variant}


func _revert_value(ctrl: Control) -> Variant:
	if ctrl is SpinBox:
		return (ctrl as SpinBox).value
	if ctrl is OptionButton:
		return (ctrl as OptionButton).selected
	return (ctrl as BaseButton).button_pressed  # CheckBox / CheckButton


func _revert_apply(ctrl: Control, value: Variant) -> void:
	# Set THROUGH the signal so the normal handler applies the change.
	if ctrl is SpinBox:
		(ctrl as SpinBox).value = value
	elif ctrl is OptionButton:
		(ctrl as OptionButton).selected = value
		(ctrl as OptionButton).item_selected.emit(value)
	else:
		(ctrl as BaseButton).button_pressed = value


func _revert_changed(a: Variant, b: Variant) -> bool:
	if a is float and b is float:
		return not is_equal_approx(a, b)
	return a != b


func _update_revert(ctrl: Control) -> void:
	var info: Dictionary = _reverts.get(ctrl, {})
	if info.is_empty():
		return
	(info["btn"] as Button).visible = _revert_changed(_revert_value(ctrl), info["baseline"])


func _set_revert_baseline(ctrl: Control, value: Variant) -> void:
	if ctrl in _reverts:
		_reverts[ctrl]["baseline"] = value
		_update_revert(ctrl)


## `follows_scene` marks the controls backed by the loaded world. For those the
## button is also the way OUT of the dirty set (_mark_sticky drops a key whose
## control is back on its baseline), i.e. the affordance for "let this setting
## follow the scene again" -- so it says so, and the settings currently
## overriding their sample are exactly the \u27F2s on screen.
func _add_revert(ctrl: Control, follows_scene := false) -> void:
	var btn := Button.new()
	btn.text = "\u27F2"
	btn.focus_mode = Control.FOCUS_NONE
	btn.visible = false
	btn.tooltip_text = "Back to this sample's value, and follow each scene again" \
			if follows_scene else "Revert to the original value"
	btn.pressed.connect(func() -> void:
		_revert_apply(ctrl, _reverts[ctrl]["baseline"])
		_update_revert(ctrl))
	var parent := ctrl.get_parent()
	if parent is HBoxContainer:
		parent.add_child(btn)
	else:
		# Standalone checkbox in the VBox: wrap it in a row so the button
		# can sit beside it. Node identity survives, signals stay wired.
		var row := HBoxContainer.new()
		var idx := ctrl.get_index()
		parent.remove_child(ctrl)
		parent.add_child(row)
		parent.move_child(row, idx)
		row.add_child(ctrl)
		ctrl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(btn)
	_reverts[ctrl] = {"btn": btn, "baseline": _revert_value(ctrl)}
	# Any user change re-evaluates the button (set_*_no_signal paths are
	# handled by _update_all_reverts after a sidebar refresh instead).
	if ctrl is SpinBox:
		(ctrl as SpinBox).value_changed.connect(func(_v: float) -> void: _update_revert(ctrl))
	elif ctrl is OptionButton:
		(ctrl as OptionButton).item_selected.connect(func(_i: int) -> void: _update_revert(ctrl))
	else:
		(ctrl as BaseButton).toggled.connect(func(_on: bool) -> void: _update_revert(ctrl))


func _setup_reverts() -> void:
	for c in [_substep_spin, _worker_spin, _max_speed_spin, _gravity_spin,
			_continuous_check, _sleep_check, _recycling_check,
			_contact_hertz_spin, _contact_damping_spin]:
		_add_revert(c, true)
	# Shell-level display preferences: they belong to the session, not to the
	# sample, and already outlive a load on their own.
	for c in [_sidebar_debug_check, _stats_check, _async_check, _vsync_option]:
		_add_revert(c)


## Fresh sample load: the values just pushed into the world controls ARE the
## originals for this sample. Shell-level controls (debug, stats, async,
## vsync) keep their startup baselines.
func _capture_world_baselines() -> void:
	for c in [_substep_spin, _worker_spin, _max_speed_spin, _gravity_spin,
			_continuous_check, _sleep_check, _recycling_check,
			_contact_hertz_spin, _contact_damping_spin]:
		_set_revert_baseline(c, _revert_value(c))


func _update_all_reverts() -> void:
	for c in _reverts:
		_update_revert(c)


## Point the solver profiler at the freshly loaded world.
##
## The feed differs per engine and the row set differs with it (Box3D reports
## all 22 b3Profile phases; the native servers expose no solver timing to a
## running game at all, so theirs is a single wall-clock total). Re-attaching
## per sample is also what clears the ring, so two samples never share history.
func _attach_profiler(world) -> void:
	if _profiler == null:
		return
	_profiler.accent = ENGINE_ACCENTS.get(_engine, Color(0.35, 0.85, 1.0))
	_profiler.set_feed(ProfileFeeds.make(_engine, world if not _native() else null))
	_profiler.reset()


## `-- --shot=out.png --shot-tick=200` renders one frame and quits. Captures the
## game viewport only, never the desktop, so it is safe to run on a machine that
## is streaming, and it lands the same physics tick on every engine, which is
## what makes three captures of a sample directly comparable.
func _save_shot() -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var err := img.save_png(_shot_path)
	print("[shot] %s -> %s" % [_shot_path, "ok" if err == OK else str(err)])
	get_tree().quit()


## Whether the two overlays are up, remembered across launches.
##
## Switching engine relaunches the process, so anything not on disk is lost --
## and having the profiler vanish every time you change solver is exactly wrong
## for the one workflow it exists to serve, which is comparing the same scene on
## two engines. The panels already persist their own geometry to this file
## (stats_overlay.gd on drag, profiler_panel.gd on drag, resize and expand), so
## this only adds whether they are shown.
const SHELL_LAYOUT_PATH := "user://ui.cfg"


func _restore_overlay_state() -> void:
	var layout := ConfigFile.new()
	if layout.load(SHELL_LAYOUT_PATH) != OK:
		return
	# has_section_key first: a null default makes ConfigFile log an engine error
	# for any file that lacks the section.
	if layout.has_section_key("shell", "stats_overlay"):
		var on := bool(layout.get_value("shell", "stats_overlay"))
		_stats_check.set_pressed_no_signal(on)
		_stats_overlay.visible = on
	if layout.has_section_key("shell", "solver_profiler"):
		var on := bool(layout.get_value("shell", "solver_profiler"))
		_profiler_check.set_pressed_no_signal(on)
		_profiler.visible = on
	if layout.has_section_key("shell", "body_counter"):
		var on := bool(layout.get_value("shell", "body_counter"))
		_body_count_check.set_pressed_no_signal(on)
		_body_count_label.visible = on


## Quitting mid-recording still writes the file, which is upstream's behaviour
## (`Sample::~Sample()` finishes the recording before destroying the world,
## `samples/sample.cpp:343-348`). The buffer survives its world either way --
## `b3DestroyWorld` stops the session itself (`src/physics_world.c:414-415`) --
## so this is safe however the tree comes down around it.
func _exit_tree() -> void:
	var saved := _stop_recording()
	# Nothing will poll or reap the save after this, so it finishes here.
	_recorder.flush_save()
	if not saved.is_empty():
		print("[shell] recording saved on exit -> %s" % saved)
	# The replay world and its debug-shape handles are ours to release; the bar
	# does it on close, and a quit mid-replay has to reach that path.
	_teardown_replay()


func _save_overlay_state() -> void:
	var layout := ConfigFile.new()
	layout.load(SHELL_LAYOUT_PATH)  # keep the panels' own sections intact
	layout.set_value("shell", "stats_overlay", _stats_overlay.visible)
	layout.set_value("shell", "solver_profiler", _profiler.visible)
	layout.set_value("shell", "body_counter", _body_count_label.visible)
	layout.save(SHELL_LAYOUT_PATH)


## Browser-only banner. The web build exists so people can try the project
## before installing anything, and it is slower than the real thing twice over:
## wasm costs something across the board, and the solver is single-threaded
## because a threaded module cannot link without cross-origin isolation, which
## static hosting does not provide. Someone judging performance from the page
## would be judging the wrong build, so the page says so itself. Dismissible,
## and never built on any other platform.
func _add_web_notice() -> void:
	if not OS.has_feature("web"):
		return
	# The Reset button's ⟲ is not in Godot's bundled font. Desktop quietly
	# falls back to a system font for it; the web has no system fonts, so it
	# rendered as a hex tofu box there. Plain text on web.
	_reset.text = "Reset"
	var panel := PanelContainer.new()
	panel.name = "WebNotice"
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.09, 0.12, 0.92)
	style.border_color = Color(1.0, 0.78, 0.42, 0.9)
	style.set_border_width_all(0)
	style.border_width_top = 2
	style.content_margin_left = 14.0
	style.content_margin_right = 8.0
	style.content_margin_top = 7.0
	style.content_margin_bottom = 7.0
	panel.add_theme_stylebox_override("panel", style)
	panel.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	panel.grow_vertical = Control.GROW_DIRECTION_BEGIN

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	panel.add_child(row)

	var label := Label.new()
	# The threaded build (hosted with real COOP/COEP headers) runs the solver
	# on multiple workers; the single-threaded fallback does not. Same banner,
	# honest wording for each.
	if OS.has_feature("threads"):
		label.text = "Browser preview on WebGL2. Faster than the fallback build, still not how the project is meant to run -- for real performance, run the demo natively in Godot."
	else:
		label.text = "Browser preview: single-threaded solver on WebGL2. This is not how the project is meant to run -- for real performance, run the demo natively in Godot."
	label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.6))
	label.add_theme_font_size_override("font_size", 15)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	row.add_child(label)

	var link := LinkButton.new()
	link.text = "Get the native demo"
	link.underline = LinkButton.UNDERLINE_MODE_ALWAYS
	link.add_theme_font_size_override("font_size", 15)
	link.focus_mode = Control.FOCUS_NONE
	link.pressed.connect(func() -> void:
		OS.shell_open("https://github.com/Stink-O/box3d-godot"))
	row.add_child(link)

	var close := Button.new()
	close.text = "X"
	close.flat = true
	close.focus_mode = Control.FOCUS_NONE
	close.pressed.connect(panel.queue_free)
	row.add_child(close)

	$UI.add_child(panel)
