# Physics engine comparison harness

Runs the demo's **own sample scenes** under three different 3D physics engines,
behind a fixed camera and a recording-legible HUD, so three captures of the same
sample line up and the only variable is the solver.

- **Box3D** - this repo's GDExtension (`Box3DWorld` / `Box3DBody`).
- **Godot Physics** - Godot's built-in server.
- **Jolt Physics** - the Jolt server bundled with Godot 4.4+.

This is deliberately a side project inside the repo. It reads the samples; it
does not change them, the demo shell, or the GDExtension. Nothing under
`godot/demo/samples/` or `godot/demo/common/` is touched, and the extension has
no comparison-specific code paths.

## Running

```sh
export GODOT=/path/to/Godot_v4.7-stable_linux.x86_64   # or rely on the default
godot/tools/compare.sh <engine> [sample] [extra godot args...]

# engine = box3d | godot | jolt
# sample = any scene name under godot/demo/samples/ (default: pyramid)
```

```sh
godot/tools/compare.sh box3d pyramid
godot/tools/compare.sh godot pyramid
godot/tools/compare.sh jolt  pyramid --resolution 1920x1080
```

Keys: `Left` / `Right` (or `[` / `]`) change sample, `R` reloads, `Tab` toggles
the profiler panel, `Esc` quits. **Samples switch live; engines do not** - see
below.

## How the same scene runs on three engines

Box3D runs each sample **exactly as authored**: the `Box3DWorld` and `Box3DBody`
nodes in the `.tscn`, untouched.

The native engines cannot do that. 18 of the samples carry `: Box3DBody`
static type annotations, and `common/cube.gd` and `common/bomb.gd` literally
`extends Box3DBody`, so swapping nodes for `RigidBody3D` breaks GDScript
type-checking before physics is even involved. `tests/test_samples.gd` also
asserts every sample has a child named exactly `Box3DWorld`, which rules out
shipping per-engine scene variants.

So instead:

```
sample .tscn --> RigExtract --> neutral rig --> RigNative --> RigidBody3D etc.
```

`PackedScene.instantiate()` runs `_init` but **not** `_ready` or `_enter_tree`,
so `rig_extract.gd` can instantiate a sample, walk the still-unparented tree
reading authored physics properties, and free it again with no Box3D world ever
created and no sample script side effects. `rig_native.gd` then rebuilds that
description natively.

| file | role |
|---|---|
| `rig_extract.gd` | sample scene to backend-neutral rig description |
| `rig_native.gd` | rig to `RigidBody3D` / `StaticBody3D` / `Joint3D` + fairness corrections |
| `profiler_panel.gd` | the profiler UI, cloned from upstream's sample app |
| `profile_feeds.gd` | three profiler data sources behind one interface |
| `compare.gd` / `overlay.gd` | the harness shell and its HUD |
| `_verify.gd` | headless check that every sample extracts and rebuilds |

## Choosing the engine, and why it needs a relaunch

`physics/3d/physics_engine` is read **once at startup**. There is no runtime
switch and no command-line flag, so `compare.sh` writes a throwaway
`override.cfg` next to `project.godot` before launching.

A stale `override.cfg` would silently switch the normal demo to another engine,
so it is removed three ways: `compare.gd` deletes it in `_ready()` (Godot has
already read it by then, and this is the one that survives a crash or a
`kill -9`), `compare.sh` traps `EXIT`, and the next launch sweeps before writing.
It is also gitignored.

**Do not trust the setting to tell you what ran.** An unregistered engine name
is not an error: Godot falls back to `DEFAULT` silently with nothing on stderr.
(An earlier version of this harness wrote `"GodotPhysics"`, which is not a
registered server; it worked only because `DEFAULT` resolves to GodotPhysics3D
anyway.) `PhysicsServer3D.get_class()` does not help either - it returns
`PhysicsServer3D` for both native engines.

What does discriminate is behaviour. `JoltPhysicsServer3D::get_process_info()`
is literally `return 0;`, so the active-object, collision-pair and island
counters all read 0 under Jolt and real values under GodotPhysics3D. The harness
probes that at physics tick 12 and paints a **red MISMATCH banner** across the
bottom of the screen if the live engine is not the requested one, so a bad
recording is impossible to miss.

Valid values, verified on 4.7.stable: `DEFAULT`, `GodotPhysics3D`,
`"Jolt Physics"`, `Dummy`. The Box3D run uses `Dummy` so the native server is
not also stepping an empty space on our frame budget.

## The profiler

`Tab` toggles a panel cloned from the upstream box3d sample app
(`samples/sample.cpp`), with the same rows, the same labels, and the same
statistics - so a number here means what it means there:

- 512-sample ring, one sample per **physics tick**, not per rendered frame
- `now` = mean of the last 10 ticks, `avg` = mean over the whole live ring,
  `max` = max over the live ring, recomputed each draw and self-healing
  (spikes age out; there is no sticky max)
- columns `section | now | avg | max | % step`, optional per-row sparklines
- a flame strip normalised to step time
- a collapsible tree derived from row indent

**Box3D gets all 22 rows** (`pairs`, `collide`, `solve`, and inside `solve`:
`prepare`, `velocities`, `warm start`, `bias`, `positions`, `relax`,
`restitution`, `store`, `split islands`, then `transforms`, `joint events`,
`hit events`, `refit BVH`, `sleep`, `bullets`, `sensors`), fed by
`Box3DWorld.get_profile()` and `get_counters()`, which forward upstream's
`b3World_GetProfile` / `b3World_GetCounters`.

**Godot Physics and Jolt get one row.** This is not an oversight, and it is
worth knowing before you pick an engine:

> Both native engines *do* compute per-phase timings and emit them to the
> `"servers"` debugger profiler. But `EngineDebugger.profiler_enable()` is a
> no-op outside a debug session: `_toggle` is never called, `is_profiling()`
> stays `false`, and every engine-side emitter is wrapped in `is_profiling()`,
> so zero payloads arrive. Launching with `--remote-debug` does not help
> either - `ServersDebugger` then owns the `"servers"` name and our tap cannot
> register at all. Measured on 4.7.stable: 0 payloads after 200 physics ticks
> under both engines.

So a shipped game can read Box3D's solver breakdown at runtime and cannot read
Godot's or Jolt's. The panel says so on screen rather than quietly showing a
flat bar.

Counters are similarly lopsided: GodotPhysics reports active objects, collision
pairs and islands; **Jolt reports 0 for all three**, so the panel shows the
harness's own body count there and says why.

## What is matched, and what cannot be

`rig_native.gd` corrects the things that would otherwise make the comparison
dishonest. Each of these is a real divergence, not a rounding difference:

| quantity | how it is matched |
|---|---|
| geometry, spawn transforms | one source of truth: the authored `.tscn` |
| box / sphere / capsule | direct shape equivalents |
| cylinder / cone | emitted as N-gon `ConvexPolygonShape3D`, because Box3D builds them as `cylinder_sides`-gon hulls internally. Godot's `CylinderShape3D` is a different (and experimental) shape |
| mass | Godot has no density: `mass = sum(density * volume)` computed analytically per shape |
| inertia + centre of mass | set explicitly. GodotPhysics otherwise uses an AABB approximation for capsule, cylinder, hull and concave shapes (its own source says `// use bad AABB approximation`); Jolt is exact. Unset, the two native engines would not even match each other |
| friction / restitution values | written explicitly, never left to defaults (`PhysicsMaterial` defaults to friction 1.0, Box3D to 0.6) |
| collision filtering | Box3D ANDs (`(A.layer & B.mask) && (B.layer & A.mask)`), Godot ORs. Where the OR model cannot express the authored matrix, layers are re-synthesized and the substitution is reported on screen |
| per-world gravity | no native node equivalent, so it goes on the space via `PhysicsServer3D.area_set_param` |
| timestep | fixed 60 Hz for all three |
| camera | the sample's own `CameraStart`, identical per engine |
| vsync | disabled, so a shared refresh cap cannot flatten the difference |

**Not matchable**, and reported as on-screen badges when a sample hits them:

- **Friction and restitution combine rules.** Box3D uses `sqrt(fA*fB)` and
  `max(rA,rB)`; both native engines use `abs(min(fA,fB))` and
  `clamp(rA+rB,0,1)`. Equal-valued pairs agree on friction but *not* on
  restitution, where the native result is about double.
- **Substeps vs iterations.** Box3D uses TGS Soft: each substep is a full pass
  at `dt/N`. GodotPhysics' `solver_iterations` and Jolt's velocity/position
  steps are iterations *within* one timestep. There is no equivalent setting, so
  each engine runs at its own defaults and no iteration-parity claim is made.
- **Threading.** Jolt multithreads internally through `WorkerThreadPool`
  regardless of `run_on_separate_thread`; GodotPhysics3D is single-threaded;
  Box3D has its own worker count. This is a real shipping property of each
  engine and is left alone.
- **Joints with no native equivalent.** Godot has 5 joint types. Wheel,
  parallel and motor joints are skipped with a badge; slider motors are rebuilt
  on `Generic6DOFJoint3D` because `SliderJoint3D` has no motor at all; joint
  softness is ignored outright by Jolt.
- **Per-shape materials.** Box3D sets friction and restitution per shape;
  Godot's `PhysicsMaterial` is per body. Compound bodies are collapsed and the
  substitution is reported.

## Samples that do not port

Six of them are Box3D-only, which is a result rather than a gap in the
harness. They still run, badged:

| sample | why |
|---|---|
| `gyro_torque` | the Dzhanibekov effect needs the gyroscopic `w x (Iw)` term. GodotPhysics does not integrate it and Godot's Jolt module does not expose Jolt's toggle |
| `car` | `Box3DWheelJoint` packs suspension spring, spin motor and steering into one constraint. `VehicleBody3D` is a raycast vehicle, a different model |
| `explosion` | `b3World_Explode` applies impulse by projected area facing the blast. Nothing native does this |
| `ragdoll` | the pose holds because every joint has an angular spring plus dry friction torque. Jolt ignores soft-limit parameters entirely |
| `gyro_precession` | needs `allow_fast_rotation` to bypass the per-step rotation cap at 75 rad/s |
| `huge_pyramid` | `Box3DMultiMeshRenderer` has no native equivalent, and Jolt's default `max_bodies` is 10240 against this scene's 16k |

`gyro_precession` and `huge_pyramid` additionally build their bodies in
`_ready()`, which the extractor deliberately never runs, so their native side
shows only the authored ground plane.

## Recording

1. Launch each engine full-screen at a fixed resolution, one at a time. The
   camera comes from the sample's own `CameraStart`, so the three clips register
   when laid side by side.
2. `Tab` for the profiler when you want the Box3D breakdown on screen.
3. The HUD carries engine name, data-source proof, sample name, body count,
   fps, frame avg/1%/max and sustained physics ticks per second, so a clip is
   self-describing without a voiceover.

## Verifying

```sh
"$GODOT" --headless --path godot/demo res://compare/_verify.tscn --quit-after 600
```

Extracts and rebuilds every sample under `samples/`, asserting rig well-formedness (every shape
carries its kind-specific parameters, every body has a shape, every joint
endpoint is in range). Prints one line per scene plus `[verify] ALL -> PASS`.

This lives in `compare/`, not `samples/`, so it does not change the 33
`[samples]` lines the repo's verification ritual expects.
