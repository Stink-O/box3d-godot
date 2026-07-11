# Box3D for Godot

A [Godot 4](https://godotengine.org) GDExtension that embeds
[Box3D](https://github.com/erincatto/box3d) — Erin Catto's 3D rigid-body
physics engine — and exposes it as ready-to-use nodes.

This lives inside a fork of the upstream Box3D repository. The engine sources
under `../src` and `../include` are unmodified; everything Godot-specific is in
this `godot/` folder, so the fork stays easy to sync with upstream. The layout
mirrors the [`box3d-unity`](https://github.com/timskap/box3d-unity) binding,
which does the same thing for Unity via P/Invoke.

> **Status: very early / experimental.** Box3D itself is v0.1.0 and this binding
> is young — expect rough edges, missing pieces, and API churn; it is **not
> production-ready**, it's a starting point. That said, it's already fairly
> broad: it targets **Godot 4.7** and covers worlds, rigid bodies, every
> primitive shape plus convex-hull/triangle-mesh colliders, the full joint set,
> contact/sensor events, world queries, a character controller, and live solver
> tuning — see the roadmap below (all checked).

## Nodes

| Node | Extends | What it is |
| --- | --- | --- |
| `Box3DWorld` | `Node3D` | Owns a Box3D simulation. Steps automatically every physics frame. |
| `Box3DBody` | `Node3D` | A rigid body simulated by the nearest `Box3DWorld` ancestor. |
| `Box3DCharacterBody` | `Node3D` | A kinematic capsule controller with `move_and_slide`. See [Character controller](#character-controller). |
| `Box3DCollisionShape` | `Node3D` | An extra shape for a compound `Box3DBody` (add as a child). |
| `Box3DHingeJoint`, `Box3DSliderJoint`, `Box3DDistanceJoint`, `Box3DBallJoint`, `Box3DFixedJoint`, `Box3DMotorJoint`, `Box3DWheelJoint`, `Box3DParallelJoint` | `Node3D` | Constraints connecting two bodies. See [Joints](#joints). |

A `Box3DBody` finds the closest `Box3DWorld` above it in the tree, so you just
nest bodies (with a `MeshInstance3D` child for visuals) under a world.

### Box3DWorld

| Property | Type | Default | Notes |
| --- | --- | --- | --- |
| `gravity` | `Vector3` | `(0, -9.8, 0)` | Box3D has no fixed up-axis; this defaults to Godot's Y-up. |
| `substep_count` | `int` | `4` | Solver sub-steps per frame. Higher = more accurate. |
| `auto_step` | `bool` | `true` | Step automatically in `_physics_process`. Turn off to call `step(delta)` yourself. |
| `continuous_collision` | `bool` | `true` | CCD so fast bodies don't tunnel through thin/static geometry. |
| `max_linear_speed` | `float` | `0` | Speed clamp in m/s; `0` keeps Box3D's default. Raise for very fast bodies. |
| `debug_draw` | `bool` | `false` | Overlay a wireframe of every body's collider (box/sphere/capsule/cylinder/cone). |
| `worker_count` | `int` | `1` | `>1` uses Box3D's internal multithreaded solver. Set before the sim starts. |
| `contact_hertz` | `float` | `30.0` | Contact stiffness (cycles/sec). Higher recovers overlap faster but can jitter. |
| `contact_damping` | `float` | `10.0` | Contact bounciness (damping ratio, non-dimensional). Lower resolves overlap more energetically. |
| `enable_sleep` | `bool` | `true` | Let resting bodies sleep. Disable if your game needs every body simulated every frame. |
| `enable_warm_starting` | `bool` | `true` | Constraint warm starting. Advanced/testing only — disabling it hurts stability for no gain. |

`contact_hertz` / `contact_damping` forward to `b3World_SetContactTuning` (the
push-out speed cap is left at Box3D's default) and both take effect immediately
on an already-running world — handy for a live-tuning settings panel.

Methods: `step(delta)`, `raycast(from, to, collision_mask = all)` → `Dictionary`
with `hit`, `position`, `normal`, `fraction`, and `collider` (the `Box3DBody`
hit). `collision_mask` filters which layers the ray can hit.

Queries: `overlap_sphere(center, radius, mask = all)` → `Array` of overlapping
`Box3DBody`s; `shape_cast_sphere(from, to, radius, mask = all)` → the same
`Dictionary` shape as `raycast`; `explode(center, radius, impulse_per_area,
falloff = 0, mask = all)` applies a radial impulse to nearby bodies.

### Box3DBody

| Property | Type | Default |
| --- | --- | --- |
| `body_type` | `Static` / `Kinematic` / `Dynamic` | `Dynamic` |
| `shape_type` | `Box` / `Sphere` / `Capsule` / `Cylinder` / `Cone` / `Hull` / `Mesh` / `Fit Mesh` | `Box` |
| `box_size` | `Vector3` (full extents) | `(1, 1, 1)` |
| `sphere_radius` | `float` | `0.5` |
| `capsule_radius` / `capsule_height` | `float` | `0.5` / `2.0` |
| `cylinder_sides` | `int` | `16` (cylinder/cone tessellation) |
| `collision_mesh` | `Mesh` | — (source for `Hull`/`Mesh`; **optional** — falls back to the child `MeshInstance3D`) |
| `auto_visual` | `bool` | `false` | Generate a matching `MeshInstance3D` from the collision shape. See below. |
| `density`, `friction`, `restitution` | `float` | `1.0`, `0.6`, `0.0` |
| `linear_damping`, `angular_damping`, `gravity_scale` | `float` | `0.0`, `0.05`, `1.0` |
| `contact_monitor` | `bool` | `false` | Emit `body_entered` / `body_exited` on contact. |
| `is_sensor` | `bool` | `false` | Trigger volume: detects overlaps but has no collision response. |
| `continuous` / `allow_fast_rotation` | `bool` | `false` | Bullet CCD for fast movers; let round bodies spin past the rotation clamp. |
| `lock_linear_{x,y,z}` / `lock_angular_{x,y,z}` | `bool` | `false` (Axis Lock group: freeze translation/rotation per axis) |
| `collision_layer` / `collision_mask` | `int` (32-bit) | `1` / all | Standard Godot layer/mask collision filtering. |

Cylinder and cone reuse `capsule_radius` / `capsule_height` for their radius
and height, and are centered on the body origin (so they line up with a
Godot `CylinderMesh`).

**Using your own models / sizing once.** You don't have to keep the visual mesh
and the collider in sync by hand. Add a `MeshInstance3D` child with any mesh
(a primitive, or an imported `.obj`/`.glb`), then pick a `shape_type`:

- `Fit Mesh` — a **box** collider auto-sized to the child mesh's bounding box.
  Resize the mesh and the collider follows, so there's no separate `box_size`
  to keep in step (the demo floors use this).
- `Hull` — a **convex hull** built from the child mesh's vertices.
- `Mesh` — a full **triangle-mesh** collider from the child mesh, for **static**
  level geometry (Box3D only generates mesh contacts against static bodies).

`Hull`/`Mesh` still accept an explicit `collision_mesh` if you want the collider
to differ from what's drawn; when it's left empty they use the child
`MeshInstance3D`'s mesh (honouring its local transform/scale).

**The other direction: collider → mesh.** Set `auto_visual = true` and, if the
body has no `MeshInstance3D` child of its own, it generates one at runtime that
mirrors the primitive collider: `Box` → `BoxMesh`, `Sphere` → `SphereMesh`,
`Capsule` → `CapsuleMesh`, `Cylinder`/`Cone` → `CylinderMesh` (apex up for a
cone). Editing `box_size`, `sphere_radius`, `capsule_radius`/`capsule_height`,
etc. then drives the collider *and* the visual from one property — no matching
mesh to keep in sync by hand. It's a no-op for `Hull`/`Mesh`/`Fit Mesh` (there's
no size to mirror — those already build the collider from a mesh, the opposite
direction) and defers entirely to a `MeshInstance3D` you add yourself. Off by
default, so existing scenes are unaffected.

Methods: `apply_central_force(v)`, `apply_central_impulse(v)`,
`apply_torque(v)`, `set/get_linear_velocity`, `set/get_angular_velocity`,
`get_mass()`, `teleport(transform)` (instantly reposition a body and clear its
momentum — for respawns/resets; don't teleport into overlapping geometry).

Signals: `body_entered(Box3DBody)` / `body_exited(Box3DBody)` (require
`contact_monitor = true`); on a sensor (`is_sensor = true`),
`area_entered(Box3DBody)` / `area_exited(Box3DBody)` fire for bodies that
overlap it.

Dynamic bodies are driven by the simulation (their node transform is updated
each step). Kinematic bodies are driven by *you* — animate the node's transform
and the body follows, pushing dynamic bodies out of the way. Static bodies
don't move.

**Compound bodies:** for more than one shape, add `Box3DCollisionShape`
children (each with its own `shape_type` — box/sphere/capsule — local transform,
and material). If a body has any such children it uses those instead of its own
`shape_type`.

### Joints

Joints connect two bodies (`body_a` and `body_b`). Leave `body_b` empty to
anchor `body_a` to the world at the joint node's position. The joint node's
**transform is the joint frame** — its position is the anchor, and the axes
come from the node's basis: hinge about local Z, slider along local X, wheel
suspension/steering along local Y with the axle on local Z, parallel
alignment on local Z.

| Node | What it does | Key properties |
| --- | --- | --- |
| `Box3DHingeJoint` | Rotates about the node's local Z (revolute). | `limit_enabled`, `lower/upper_limit`, `motor_enabled`, `motor_speed`, `max_motor_torque`, `spring_*` (spring toward the spawn angle) |
| `Box3DSliderJoint` | Slides along the node's local X (prismatic). | same shape as hinge, plus `max_motor_force` |
| `Box3DDistanceJoint` | Holds two bodies a set distance apart (rope / rod / spring). | `length` (-1 = auto), `spring_enabled`, `spring_hertz`, `spring_damping`, `limit_enabled`, `min/max_length` |
| `Box3DBallJoint` | Pins a point, free rotation (spherical). | `cone_limit_enabled`, `cone_angle`, `twist_limit_enabled`, `twist_lower/upper`, `spring_*` (spring toward the spawn pose), `friction_torque` (dry joint friction) |
| `Box3DFixedJoint` | Rigidly welds two bodies. | `linear_hertz`, `angular_hertz` (0 = rigid) |
| `Box3DMotorJoint` | Drives the relative linear/angular velocity (a servo). | `linear_velocity`, `max_force`, `angular_velocity`, `max_torque` |
| `Box3DWheelJoint` | A vehicle wheel: `body_b` (the wheel) rides a suspension spring along the node's local Y and spins about its local Z (the axle), with an optional spin motor and spring steering. | `suspension_*` (spring + travel limits), `spin_motor_*`, `steering_*` (target angle, spring, limits), `get_spin_speed()`, `get_steering_angle()` |
| `Box3DParallelJoint` | A spring keeping the two bodies' joint-frame Z axes parallel — point the node's Z up (and leave `body_b` empty) to hold a body upright while it yaws freely. | `spring_hertz`, `spring_damping`, `max_torque` (0 = unlimited) |

All share `body_a`, `body_b`, and `collide_connected`. Drive targets — motor
speeds, the wheel joint's spin/steering targets and tuning, distance length —
can be changed live from script (changing one also wakes the bodies, so a
parked vehicle responds); most other properties rebuild the joint. Jointed
bodies may start overlapping (wheels inside a chassis, say): creating a joint
with `collide_connected` off removes any contact that already formed between
the pair, so a stale contact can't fight the joint.

### Character controller

`Box3DCharacterBody` is a kinematic capsule (properties: `radius`, `height`,
`collision_mask`) that isn't simulated — you move it yourself:

```gdscript
var velocity := Vector3.ZERO
func _physics_process(delta):
    velocity.y -= 9.8 * delta            # gravity
    velocity.x = Input.get_axis("left", "right") * 5.0
    velocity = $Box3DCharacterBody.move_and_slide(velocity, delta)
```

`move_and_slide(velocity, delta)` moves the capsule by `velocity * delta`,
sliding it along and stopping it at world geometry (via `b3World_CollideMover`
+ `b3SolvePlanes`), and returns the actual resulting velocity.

## Quick start (GDScript)

```gdscript
extends Node3D

func _ready() -> void:
    var world := Box3DWorld.new()
    add_child(world)

    var floor := Box3DBody.new()
    floor.body_type = Box3DBody.STATIC
    floor.box_size = Vector3(20, 1, 20)
    floor.position = Vector3(0, -0.5, 0)
    world.add_child(floor)

    var crate := Box3DBody.new()
    crate.body_type = Box3DBody.DYNAMIC   # this is the default
    crate.position = Vector3(0, 5, 0)
    world.add_child(crate)
```

## Demo

[`demo/`](demo) is a **sample browser** (like Box3D's own samples app):
`main.tscn` is a shell with a small **Samples** dropdown menu (categorized),
a shared fly camera, and lighting; picking a sample instances its scene from
`samples/` into the host. Each sample is a plain, self-contained scene in
[`demo/samples/`](demo/samples) — open any of them in the editor to inspect or
tweak it. The project is resolution-independent (`canvas_items` / `expand`
stretch), so the UI scales crisply and the 3D renders at native resolution.

The demo is organized so it stays easy to browse:

```
demo/
  main.tscn, main.gd      shell: dropdown menu + sample host
  common/                 shared building blocks (fly camera, sky, cube.tscn, emitter.tscn)
  samples/                one editable scene per sample (+ its behaviour script)
  tests/                  headless self-test scenes
  tools/                  Python generators for the procedural scenes
```

Some scenes with many bodies (cube pile, pyramid, dominoes, bridge) are
authored by a small generator in `tools/`, but the committed `.tscn` is the
source of truth — it's a normal editable scene you can open and change.

Samples so far (more are added by the `/demo` loop):
- **Cube Pile** — a 6×6×6 stack of 216 cubes.
- **Joint Sampler** — a hinge arm, a ball-joint pendulum, a swaying chain, a
  motorized slider, and a contact-event dropper.
- **Body Types** — static, kinematic and dynamic side by side (labelled): a
  kinematic platform slides back and forth carrying (and toppling) a stack of
  dynamic crates, and a kinematic piston pops up to launch them.
- **Shape Zoo** — one of each collider (box, sphere, capsule, cylinder, cone,
  and a convex hull) dropped onto a floor.
- **Restitution** — six balls dropped side by side with restitution from `0.0`
  to `0.95`, so you can watch bounce height climb across the row.
- **Friction Ramp** — five boxes with rising friction on an inclined plane; the
  frictionless one slides right off while the grippier ones slow and stop.
- **Pyramid** — a 140-cube stepped pyramid (7 cubes per side at the base); a
  stacking-stability stress test that holds its shape once it settles.
- **Mixed Stacks** — five columns of randomly mixed boxes, spheres, capsules,
  and cylinders, so you can watch different colliders settle against each other.
- **Motion Locks** — an air-hockey table of pucks locked to the table plane
  (`lock_linear_y` + `lock_angular_x/z`) that glide and ricochet flat, plus a rail
  of beads locked to a single axis that clack back and forth like an abacus.
- **Compound Shapes** — a table, a cross, a dumbbell, and a jack, each one body
  built from several `Box3DCollisionShape` children; shoot (**F**) or drag them
  and watch each multi-part object tumble as a single rigid piece.
- **Dominoes** — a line of 18 slabs; the first is spun over to start the
  cascade.
- **Bridge** — a 12-plank walkway hung from hinge joints between two posts; it
  sags into a catenary under its own weight and flexes when boxes drop on it.
- **Motorized** — a hinge-motor turntable spins up and flings its riding boxes
  off (shoot more onto it with **F**), next to a free-spinning windmill blade on
  a second motor. Motor speeds are set live from script.
- **Newton's Cradle** — five balls hang from rigid rods (a `Box3DDistanceJoint`
  each, spring disabled → inextensible), locked to the swing plane so each is a
  true pendulum; the raised end ball swings down and the impact ripples along
  the touching line, kicking the far ball out. Grab or shoot the balls yourself.
- **Ragdoll** — a wooden-mannequin humanoid in the style of box3d's own human
  prefab: every bone is a capsule (a four-segment torso stack, an egg head,
  capsule limbs) linked by ball joints (spine, neck, shoulders, hips) and hinge
  joints (elbows, knees) with human-range limits — knees only fold backward,
  elbows only forward. Each joint carries a soft spring toward the spawn pose
  plus a little dry friction (upstream's ragdoll tuning), so it stands like a
  posed mannequin until you grab, shoot, or bomb it — then it crumples
  believably (non-adjacent bones collide, so it can't fold through itself).
- **Character Controller** — a `Box3DCharacterBody` capsule turned loose in a
  Box3D **playground**: walk it (**W A S D**, camera-relative, **Space** to jump,
  while the mouse is free) up a ramp to a platform and along walls, and shove
  the dynamic crates, barrels, and balls it walks into — the same props the rest
  of the demo uses — so the mover clearly reads as one more body sharing the
  world. Shows `move_and_slide` sliding, slope-climbing, and pushing dynamics.
- **Contact Pit** — a pachinko-style field of 64 pegs, each `contact_monitor`
  on; balls rain in (and you can shoot more with **F**), lighting up every peg
  they clatter against via `body_entered` and fading out behind them.
- **Bowling** — ten pins racked at the end of a lane; a ball rolls in on load
  for an opening strike, then shoot more with **F** or **Reset** to re-rack.
- **Pool Break** — fifteen balls racked in a triangle on a cushioned table; the
  cue ball breaks the rack on load. Grab a ball to line up your own shot, or
  **Reset** to re-rack.
- **Marble Run** — marbles drip from a reusable `Emitter` node at the top and
  cascade down a zig-zag of alternately-tilted ramps into a tray at the bottom.
  Move the emitter to re-aim the stream; shoot more in with **F**.
- **Tumbling Tower** — a Jenga-style stack (14 layers of three blocks, each
  layer turned 90°). It stands stable; shoot it (**F**) or drag a block to bring
  it crashing down, then **Reset** to re-stack.
- **Ball Pit** — a container brim-full of 243 colourful balls that settle into a
  pile; shoot into them (**F**), grab and fling them, or **Reset** to refill.
- **Wrecking Ball** — a heavy ball on a real jointed rope (a chain of small
  dynamic links pinned with `Box3DBallJoint`) swings down and smashes a brick
  wall on load; grab or shoot the ball for another swing, or **Reset** to
  rebuild the wall.
- **Ball Fountain** — a spout sprays a steady stream of balls up into the air;
  they arc over and rain back into the basin (and fade out so it loops forever).
- **Radar Sweep** — a laser beam rotates around a central emitter, `raycast`ing
  each frame; every target pillar it sweeps across lights up with a marker at
  the hit point. Targets are dynamic — knock them around and the sweep tracks them.
- **Explosion** — a 150-block building over a pulsing bomb; hit the top-bar
  **Activate** button to set off `Box3DWorld.explode` with a bright expanding
  flash (the reusable `ExplosionFX`), then **Reset** to rebuild it.
- **Bullets (CCD)** — a firing range that shoots fast bullets at a thin wall.
  Press **C** to toggle the world's `continuous_collision`: on, the wall catches
  them; off, they tunnel straight through to the backstop. (**B** fires a volley.)
- **Car** — a port of box3d's own *Driving* sample (same construction, same
  numbers): a box chassis on four sphere wheels, each hanging on a
  `Box3DWheelJoint` — the joint's suspension spring carries the chassis, the
  rear pair drives via the spin motor, and the front pair steers by spring
  toward the target angle — with a soft `Box3DParallelJoint` holding the body
  upright. Nothing pushes the chassis; all motion comes from wheel traction.
  Drive with the **arrow keys** (Up/Down throttle, Left/Right steer — W A S D
  works too while you're not flying the camera) over 240 m of rolling
  two-scale sine terrain — long swells plus short ripples, vertex-tinted by
  height and slope so the relief reads clearly (a triangle-mesh stand-in for
  upstream's wave height field; `tools/gen_car_terrain.gd` bakes it). A
  floating readout shows your speed (the wheels wear a baked checkerboard so
  you can see them spin and steer), and the top bar's **🎥 Third Person**
  toggle glides the camera onto a chase rig centred on the chassis — hold
  **right mouse** there to orbit the view around the car (vertical inverted,
  flight-style; the view stays where you put it, and W A S D keeps driving
  while you drag), and toggling off glides the free camera back to exactly
  where you left it.

**Controls:** hold **right mouse** to fly (**W A S D** + **Q/E**, **Shift** to
boost); **left-click and drag** (when not flying) to grab a body *at the point
you clicked* (grab an edge and it pivots, not re-centres); **hold F** to charge a
shot (a bar fills bottom-centre) and release to fire a ball from the camera —
harder the longer you hold — aimed through the mouse, or straight ahead while
flying (it's a CCD "bullet", so it won't tunnel through walls). The top bar's
**Shot** selector switches F between a plain ball and a **bomb** — a thrown bomb
blinks faster and faster over a 3-second fuse, then detonates with the same
`ExplosionFX`. The **Activate** button (shown for samples that define an
`activate()` action, e.g. Explosion) fires that action; a sample can likewise
put a labelled toggle in the top bar by defining `set_toggled(on)` (and
optionally `get_toggle_label()`) — the Car's **Third Person** camera uses it. The **Reset** button
rebuilds the current sample; the **Debug** toggle overlays every body's collider
wireframe (`Box3DWorld.debug_draw`) and stays on as you switch samples; and
**⚙ Settings** (or **Tab**) opens a right-hand panel that live-edits the current
world's solver (substeps, worker count, gravity, CCD, contact stiffness and
damping, …). A
sample can frame its own opening view by exporting `camera_home` /
`camera_look_at` (two Vector3s) on its root script.

Launching with `-- --sample=<Name>` (e.g. `godot --path demo -- --sample=Ragdoll`,
case-insensitive) opens straight to that sample instead of the first menu entry.

Headless checks: `res://tests/test_samples.tscn -- --selftest` loads and steps
every sample; `res://tests/test_features.tscn -- --selftest` exercises the
binding feature-by-feature; `res://tests/test_shoot.tscn -- --selftest` loads the
shell and verifies the menu + ball shooting.

## Building

Prebuilt **Windows x86_64** binaries are committed in `demo/bin/`, so on Windows
the demo runs straight from a fresh clone. On **Linux and macOS you build the
library yourself** (only the Windows binaries ship; `.so` files are gitignored).
On Windows, build only if you change the C/C++ sources.

You need Python 3, SCons, and a C++17 compiler (GCC, Clang, or MSVC), plus the
`godot-cpp` submodule. A plain clone will not build, so clone with submodules:

```sh
git clone --recurse-submodules https://github.com/Stink-O/box3d-godot.git
# or, in a clone you already have:
git submodule update --init
```

### Linux

Install the toolchain:

```sh
sudo dnf install gcc gcc-c++ scons git      # Fedora
sudo apt install build-essential scons git  # Debian / Ubuntu / Mint
```

Build both targets from this `godot/` folder:

```sh
cd box3d-godot/godot
scons -j$(nproc)                          # debug build (what the editor loads)
scons -j$(nproc) target=template_release  # optimized build for exports
```

The first build also compiles all of godot-cpp and takes a few minutes;
rebuilds after that are quick. (On a low-RAM machine, drop the `-j` flag.) The
libraries land in `demo/bin/libbox3d_godot.linux.template_debug.x86_64.so` and
`...template_release...`, exactly where `box3d.gdextension` expects them.

Then install Godot 4.7 for Linux (godotengine.org download, Flatpak, or
Steam), open `demo/project.godot`, and press play. To sanity-check the build
without opening the editor:

```sh
cd demo
godot --headless --path . res://tests/test_samples.tscn -- --selftest
```

### Windows

When SCons is installed through pip it is often not on `PATH`; running it
through Python always works:

```sh
cd godot
py -3 -m SCons target=template_debug
py -3 -m SCons target=template_release
```

The libraries are written to `demo/bin/`. Open `demo/` in Godot 4.7 and press
play (see [Demo](#demo) below for controls).

To use it in your own project, copy `demo/bin/box3d.gdextension` and the built
library into your project's `bin/` folder.

### Cross-compiling

`scons platform=<windows|linux|macos|android|web> target=template_release`.
Box3D's C sources are compiled from source with the same toolchain as
godot-cpp, so no prebuilt engine binary is needed.

## How it works

- The C++ wrapper in `src/` calls Box3D's C API directly — no marshaling layer.
  Godot `Vector3`/`Quaternion` map 1:1 onto Box3D's `b3Vec3`/`b3Quat`.
- The `Box3DWorld` drives the whole simulation each physics tick: it pushes
  kinematic bodies in, calls `b3World_Step`, then reads dynamic bodies back out.
  Bodies are passive, so there's no update-order ambiguity.
- Box3D is compiled statically into the extension. Its symbols stay internal;
  only Godot's extension entry point is exported.

## Roadmap

- [x] Joints (hinge, slider, distance, ball, fixed)
- [x] Contact events as signals (`body_entered` / `body_exited`)
- [x] Cylinder & cone colliders
- [x] Convex hull collider (from a `Mesh`)
- [x] Triangle-mesh colliders (static level geometry)
- [x] Collision layers / masks
- [x] Sensor / trigger volumes (`is_sensor` + `area_entered` / `area_exited`)
- [x] Continuous collision (bullets) & fast-rotation flags
- [x] Motion locks (freeze position / rotation per axis)
- [x] Character controller (capsule mover, `move_and_slide`)
- [x] World queries (shape cast, overlap, explode)
- [x] Ball joint cone & twist limits
- [x] Motor joint
- [x] Wheel & parallel joints (suspension, spin motor, steering, upright assist — see the Car sample)
- [x] Separate `Box3DCollisionShape` nodes (multiple shapes per body)
- [x] Debug draw (collider wireframes)
- [x] Multithreaded stepping (`worker_count`, Box3D's internal scheduler)
- [x] Unified visual+collision (`auto_visual`: size the collider once, get a matching mesh free)
- [x] Live solver tuning (`contact_hertz`, `contact_damping`, `enable_sleep`, `enable_warm_starting`)

## License

MIT, matching upstream Box3D. See [`../LICENSE`](../LICENSE).
