# Upstream notes: branch `crr/body-safety-factor`

A small change to the Godot binding only (`godot/`), made for the Clean Room Ragdoll project and
kept here so it can be offered upstream. Box3D's C core (`src/`, `include/`, `extern/`) is
untouched.

## What changed

- `Box3DBody.safety_factor` (float, default `0.5`): a new property mirroring
  `b3BodyDef.safetyFactor` / `b3Body_SetSafetyFactor` / `b3Body_GetSafetyFactor`.
  - Applied at creation (`body_def.safetyFactor` in `Box3DBody::create_in_world`, next to
    `sleepThreshold`) and live (`set_safety_factor` calls `b3Body_SetSafetyFactor` when the body
    exists), bound in `_bind_methods`, listed after `sleep_threshold` in the inspector and
    documented in `godot/doc_classes/Box3DBody.xml`.
  - The value handed to Box3D is clamped to `[0, FLT_MAX]` (`Box3DBody::safety_factor_b3`), the
    range upstream asserts (`src/body.c:187`, `src/body.c:2120`), so `INF` is legal as "never
    sweep this body". The default `0.5` passes through unchanged.
- The world's debug draw used a hard-coded `0.5` in its two "fast body" heuristics (the orange
  "fast" colour and the lime impact flash, `godot/src/box3d_world.cpp`); they now use each
  body's factor, so they agree with the solver. Identical for bodies left at the default.

## Why

Box3D's continuous collision, after the solver, moves a "fast" dynamic body back to its time of
impact against static geometry (`b3SolveContinuous`, `src/solver.c:577-592`). Only that body moves;
bodies jointed to it do not. In an articulated ragdoll this pulls feet and hands away from their
neighbours on impact (measured 41–58 mm of joint separation in a 2 m drop). The world switch
`Box3DWorld.continuous_collision` removes it, but for every body in the world. The per-body
safety factor already in Box3D's API lets an application opt out only the bodies that need it.

## How it maps onto the C API

| Godot | Box3D |
|---|---|
| `safety_factor` at creation | `b3BodyDef.safetyFactor` (`include/box3d/types.h:312-318`, default `0.5` in `b3DefaultBodyDef`, `src/types.c:40`) |
| `set_safety_factor()` on a live body | `b3Body_SetSafetyFactor` (`include/box3d/box3d.h:709`, `src/body.c:2118`) |
| `get_safety_factor()` | returns the stored property (the binding's convention); `b3Body_GetSafetyFactor` reads the same value |

What the factor does in the solver (all in `src/solver.c`):

- Every step, `b3FinalizeBodiesTask` (`:793-795`) flags a dynamic body fast only if world
  continuous collision is on and `maxMotion > safetyFactor * minExtent`, where `maxMotion` is the
  step's largest point motion (linear plus rotation arc to the farthest extent) and `minExtent` the
  body's smallest shape extent. A body that is not fast takes the plain branch
  (`center0 = center`, `:813-816`): no sweep, no time-of-impact pull-back.
- A fast body then tests each shape again with the same factor (`b3IsShapeFast`, `:460-487`,
  called at `:558`) before sweeping it against the static tree.
- So: smaller factor = more continuous collision; a factor so large that `safetyFactor * minExtent`
  exceeds any reachable per-step motion opts the body out. Motion per step is bounded by the
  world's maximum linear speed (default 400 m/s, `src/types.c:26`) and `B3_MAX_ROTATION`
  (`include/box3d/constants.h:70`) per substep, so e.g. `1e6` is beyond reach for any body larger
  than a few micrometres.
- `isBullet` (already bound as `Box3DBody.continuous`) does the opposite (also sweeps against
  kinematic and dynamic bodies and skips the per-shape test), so it is not touched.
- Side effects of not being fast, all upstream's own: the pair is eligible for contact recycling
  (`src/physics_world.c:648-655` skips recycling only for fast bodies), and mesh contact does not
  take its fast-body path (`src/mesh_contact.c:749`).

## Proof that stock behaviour is unchanged

- Box3D's unit tests (`test/`, built with CMake, Release): all pass (core untouched).
- A stock mixed scene (box stack, five-capsule hinge chain, a 60 m/s sphere and a 45 m/s box onto
  a 3 cm static plank so continuous collision fires, a spinning box), 600 steps at 1/120 s, SHA-256
  over every body's transform and velocities at every step: identical before (c68590e) and after
  this change, at 4 and 8 substeps, both with the property left at its default and with
  `safety_factor = 0.5` set explicitly on every body. With `safety_factor = 1e6` on the sphere only,
  it passes through the plank, as intended.

## Status

Candidate to upstream. Not pushed anywhere; the fork owner decides. Origin of the change: written
from Box3D's own source and docs (`include/box3d/types.h`, `src/solver.c`, `docs/simulation.md`
"Continuous Collision"), following this binding's existing property conventions
(`sleep_threshold`, `gravity_scale`).
