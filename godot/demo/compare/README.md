# Physics engine comparison harness

A fair, video-ready side-by-side of three 3D physics engines running the same
scenarios in Godot 4.7:

- **Box3D** — this repo's GDExtension (`Box3DWorld` / `Box3DBody`).
- **Godot Physics** — Godot's built-in server.
- **Jolt Physics** — the Jolt server that ships with Godot 4.4+.

One scene (`compare.tscn`) drives everything. A single seeded builder
(`compare.gd`) emits the geometry, then instantiates it with **either** Box3D
nodes **or** native `RigidBody3D` / `StaticBody3D` nodes — same positions, same
sizes, same mass, friction, restitution, gravity and 60 Hz timestep. A fixed
camera and a big overlay make two recordings line up frame-for-frame, so the
only thing that differs on screen is the solver.

## Scenarios

| scenario | what happens | bodies |
|----------|--------------|--------|
| `pyramid` | A solid 14-wide square pyramid; at physics tick 90 a heavy sphere is fired into it on a flat arc. Stacking stability + a deterministic collapse. | 1015 boxes + 1 ball |
| `pile`    | 1152 boxes rain from a staggered grid into a walled bin and settle. Many-contact throughput. | 1152 boxes |
| `stir`    | A dense bed of boxes churned continuously by a rotating kinematic cross-paddle. Sustained solver load. | 784 boxes + paddle |
| `chain`   | 20 hanging chains of 25 links each, joined by ball / pin joints, anchored to the world. Joint-heavy. | 500 links + 500 joints |

Spawning is seeded (`SEED = 1337`), so every run of a given scenario is
identical, and the two engines being compared get byte-identical layouts.

## Running

Use the launcher (it handles engine selection, see below):

```sh
export GODOT=/path/to/Godot_v4.7-stable_linux.x86_64   # or rely on the default
godot/tools/compare.sh <engine> <scenario> [extra godot args...]

# engine   = box3d | godot | jolt
# scenario = pyramid | pile | stir | chain
```

Examples:

```sh
godot/tools/compare.sh box3d pyramid          # windowed, for recording
godot/tools/compare.sh godot pyramid
godot/tools/compare.sh jolt  pyramid

godot/tools/compare.sh jolt pile --headless --quit-after 600 --fixed-fps 60   # timing / CI
```

Or launch the scene directly (box3d only, since it needs no engine setting):

```sh
"$GODOT" --path godot/demo res://compare/compare.tscn -- --engine=box3d --scenario=stir
```

## How the engine is selected — and how each proves it engaged

Box3D is a GDExtension with its own world; it ignores Godot's physics server
entirely. The native engines (Godot Physics, Jolt) are chosen by the project
setting `physics/3d/physics_engine`, which Godot reads **once at startup** —
there is no runtime switch and no command-line flag.

`compare.sh` therefore writes a throwaway `override.cfg` next to
`project.godot` (`3d/physics_engine="Jolt Physics"` or `"GodotPhysics"`),
launches, and **always deletes it again** on exit (bash `trap`), so the normal
demo is never left altered. For `box3d` no override is written. `override.cfg`
is also `.gitignore`d so a stray one can't be committed.

**Proof.** The overlay's second line, and a `[compare] ENGINE PROOF:` line
printed to stdout at startup, report the engine actually in force:

- box3d → `Box3D GDExtension · b3World_Step, substeps=4, 4 workers`
- native → `native PhysicsServer3D · physics/3d/physics_engine = "<value>"`

For native runs the name is derived from the **live** project setting, not the
requested argument, so a missing override would show the truth (and log a
warning). Verified engaged headless:

```
[compare] ENGINE PROOF: Box3D        -> Box3D GDExtension ...
[compare] ENGINE PROOF: Godot Physics -> native PhysicsServer3D  ·  physics/3d/physics_engine = "GodotPhysics"
[compare] ENGINE PROOF: Jolt Physics  -> native PhysicsServer3D  ·  physics/3d/physics_engine = "Jolt Physics"
```

## The overlay

Top-left panel, sized for a screen recording:

- **Engine name** (big) + the proof line, tinted per engine (Box3D cyan, Godot
  blue, Jolt orange).
- Scenario, body count, tick rate, substeps.
- **`physics  N.NN ms / tick`** — the headline metric (green). This is the
  honest cross-engine number: every scenario runs the same fixed 60 Hz step
  with the same bodies, so the differentiator is how many milliseconds each
  engine spends per physics tick (its headroom) — not the rendered frame rate,
  which a shared vsync cap and the identical draw-call load would flatten.
- FPS (self-measured, averaged) and process ms / draw calls for context.

## What is matched, and what has no equivalent

Matched exactly across all three engines:

| quantity | value | how |
|----------|-------|-----|
| geometry / spawn positions | seeded, identical | one builder, `SEED=1337` |
| box size | 1×1×1 (full extents) | `box_size` == `BoxShape3D.size` |
| mass | `density × volume` | Box3D uses density 1.0; native `RigidBody3D.mass` is set to the same resulting mass |
| friction | 0.6 | Box3D `friction`; native via a `PhysicsMaterial` |
| restitution | 0.0 | Box3D `restitution`; native `PhysicsMaterial.bounce` |
| gravity | 9.8 m/s² down | Box3D world gravity; native project `default_gravity` |
| timestep | fixed 60 Hz | both step in `_physics_process` at `physics_ticks_per_second` |
| camera | fixed per scenario | same eye/target for every engine |

**Not matchable** — these are genuinely different solver designs, and the
differences are the point of the comparison:

- **Substeps vs iterations.** Box3D uses a soft-step solver with a substep
  count (set to 4 here). Godot Physics exposes solver *iterations*
  (`physics/3d/solver/solver_iterations`); Jolt uses velocity/position steps
  (`physics/jolt_physics_3d/simulation/*`). There is no one-to-one mapping, so
  each native engine runs at its own defaults and Box3D at 4 substeps. Tune
  these in `project.godot` / the constants if you want a different operating
  point, but document whatever you pick.
- **Threading.** Box3D's solver is multithreaded (`worker_count = 4` here).
  Godot Physics is single-threaded; Jolt multithreads internally by default.
  This is a real, shipping property of each engine, left as-is.
- **Friction / restitution combine rules.** Box3D combines with a geometric
  mean; Godot multiplies; Jolt uses a geometric mean by default. With both
  contacting surfaces set to the same 0.6 the spread is small, but it is not
  zero.
- **Contact softness, sleeping thresholds, CCD internals** differ per engine
  and are left at each engine's defaults (the wrecking ball opts into CCD on
  all three: Box3D `continuous`, native `continuous_cd`).

## Recording flow

1. Pick a scenario. Launch each engine full-screen at a fixed window size, one
   at a time:
   ```sh
   godot/tools/compare.sh box3d pyramid
   godot/tools/compare.sh godot pyramid
   godot/tools/compare.sh jolt  pyramid
   ```
   The camera and overlay are identical, so the three clips register when laid
   side-by-side (or in a 3-up grid) in your editor.
2. For the `pyramid` collapse, the ball fires at tick 90 (~1.5 s in) on every
   engine — a natural sync point. `pile` settles within a few seconds; `stir`
   and `chain` run indefinitely, so cut whatever window you like.
3. Read the green `physics ms / tick` number off each clip for the on-screen
   verdict; the body count and FPS are there for context.
4. `stir` is the best single clip for a "which solver stays cheap under
   sustained contact" story; `pile` for settle time; `pyramid` for a dramatic
   collapse; `chain` for joint behavior (expect the most visible divergence
   here — joint solvers differ the most).

Tip: add `--fixed-fps 60` to decouple the sim from your display's refresh if you
want identical wall-clock pacing between captures.
