# Changelog

What changed in each release of Box3D for Godot, newest first. Every release, its
assets and its full notes are on the
[releases page](https://github.com/Stink-O/box3d-godot/releases);
releases before 0.4.2 are listed only there.

## 0.6.0 (2026-10-23)

- **Old recordings no longer load.** Upstream added a world setting to the
  snapshot and recording formats, so `.b3rec` files made with 0.5.0 or
  earlier are refused. Record them again. This is why the version jumps to
  0.6.0.
- **Upstream synced** through Erin's solver and joint rework, contact
  manifold fixes, and gyroscopic torque that is now skipped on near-spherical
  bodies. The new `Box3DWorld.isotropic_inertia_tolerance` (default 0.2)
  sets how close to a sphere a body must be for that.
- **New bindings:**
  - `Box3DBody`: `safety_factor`, `start_asleep`, `get_min_extent()` /
    `get_max_extent()`, `cast_shape()` / `overlaps_shape()` with any proxy
    plus `max_fraction` and `can_encroach`, `collide_mover()` and
    `time_of_impact_mover()`.
  - `Box3DWorld`: `collide_mover()` and `get_move_events()`.
  - `Box3DCollision`: `solve_planes()` and `clip_vector()`, the character
    plane solver on its own.
  - `Box3DJoint.is_awake()` and `Box3DCollisionShape.get_contacts()`.
- **`step(0)` now runs collision and events without solving**, as upstream
  defines a zero time step. Negative, NaN and infinite steps are refused
  instead of corrupting body positions.
- **14 new samples:** Safety Factor, Spinning Capsule, Body Cast, Capsule
  Plane, Mover Overlap, Breakable Joints, Card House, Arch, Ragdoll Pile,
  Lock Mixing, Fixed Rotation, Rolling Resistance, Body Move Events and Rope
  Bridge. Character Controller gains upstream's falling plate and tree.
- **A refreshed demo:** a grid floor that runs to the horizon, a new UI
  theme, Settings split into Sample, Physics, View and Tools tabs, and Rec /
  Replay on the top bar (F2 and F3).
- Fixes: the length scale project setting now shows without Advanced
  Settings ([#6](https://github.com/Stink-O/box3d-godot/issues/6), thanks
  Chailotl), and switching Compare Engines to Jolt or Godot Physics no longer
  logs a script error on most samples.

## 0.5.0 (2026-10-09)

- **Old recordings no longer load.** Upstream changed the hull and compound
  data versions, and every recording carries them, so `.b3rec` files made
  with 0.4.4 or earlier are refused. Record them again. Hull and compound
  data saved with upstream's own serialisation is affected the same way.
  This is why the version jumps to 0.5.0.
- **AVX2 solver kernels.** On x86 CPUs that have AVX2, upstream Box3D now
  picks 8-wide solver kernels at runtime. The results stay bit-identical to
  the SSE2 path; a new selftest steps the same 386-body pile both ways and
  compares every transform. `Box3DWorld.is_avx2_available()` reports which
  path is in use, and `Box3DWorld.sse2_fallback` forces SSE2 for testing.
- **`Box3DGeometry.create_complex_hull(radius)`**: upstream's 32-point
  convex pile hull, a rounder alternative to `create_rock`.
- Upstream synced through eight commits, including a fix for a crash when
  recording compound shapes, recording and compound serialisation fixes,
  collision tree performance work, and a mesh contact triangle limit raised
  from 256 to 512.
- Docs: the Linux packages upstream's CMake samples need, including GTK3
  ([#4](https://github.com/Stink-O/box3d-godot/issues/4)), and the stale
  `demo/bin` references from before 0.4.3
  ([#5](https://github.com/Stink-O/box3d-godot/issues/5)). Thanks to
  clankill3r for both. The addon's own README now says the macOS quarantine
  command is required.

## 0.4.4 (2026-09-27)

- **Godot 4.6 support.** The same binaries now load in Godot 4.6 and 4.7:
  the extension is built against the 4.6 API, and newer Godot versions
  accept it. Thanks to cdgonz115 for the request
  ([#3](https://github.com/Stink-O/box3d-godot/pull/3)).
- **macOS support.** The addon zip now includes a universal (Apple Silicon
  and Intel) macOS library, built and tested on a Mac by GitHub Actions on
  every release, for Godot 4.6 and 4.7. Thanks to cdgonz115 for the first Mac
  report and the manifest change
  ([#2](https://github.com/Stink-O/box3d-godot/pull/2)). It is not signed by
  Apple, so macOS blocks it after a download until you run one Terminal
  command; see the macOS note under Getting started.
- **Bounce solver settings** on `Box3DWorld`: `restitution_iterations`
  (passes of the bounce solve, 0 turns bouncing off) and
  `enable_restitution_propagation` (a hit carries through everything
  touching, as in a Newton's cradle). New in upstream Box3D; both are also
  in the demo sidebar.
- **Barrel Spire and Barrel Skyscraper samples**: 3000 oil drums stacked into
  a hollow cone and a hollow square tower. The Skyscraper has sidebar boxes
  for wall width, floors and barrel count.
- **Faster replay indexing**: the replay player now uses several solver
  workers, so a 40,000-ball recording indexes in about 45 s instead of 105 s.
- Upstream synced through five commits (solver and SAT optimizations, the
  compound mesh material limit removed). `Box3DWorld.get_profile()` follows
  upstream's field names, so its `applyRestitution` key is now `restitution`.

## 0.4.3 (2026-09-18)

- **One-zip install.** The release is now a single `addons/box3d/` zip with
  every platform's library inside, the way godot-jolt and Terrain3D ship.
  Unzip next to `project.godot`, restart Godot, done. The loose per-platform
  files are gone; Godot exports only the library that matches your target, so
  the extra platforms in the zip cost your game nothing.
- **Wind Drop sample**: a thin plate gliding down through still air, the
  upstream "Wind Drop" sample. There is no drag setting in Box3D; the
  float-down is `apply_wind` computing projected-area drag and lift against
  the plate's own velocity. Toggle the air off and it drops like a stone.
- **`max_spring_torque`** on `Box3DBallJoint` and `Box3DHingeJoint`: a torque
  ceiling on the pose spring, so a joint can be stiff without winning at any
  cost. Implemented entirely in the extension, no upstream patch.
- **`Box3DBody.set_target_transform`**: upstream's velocity-based kinematic
  drive, for moving a kinematic body to a pose in one step without teleporting.
- **Web demo no longer freezes on Wave Pile.** The 8-worker replay joined
  threads the browser had not started yet; the export's thread pool is larger
  and the sample yields before it closes a replay.
- Upstream synced through Box3D's broad-phase rewrite (three upstream
  commits: clockwise mesh winding, `b3Joint_IsAwake`, fixes, faster
  broad-phase).

## 0.4.2 (2026-08-09)

- **Record and replay any sample, with a timeline.** Two buttons in the demo
  sidebar capture a whole session, including everything you do to it (fired
  balls, bombs, grab-drags). A draggable timeline scrubs the result in both
  directions, plays it backwards, and single-steps either way. The timeline is
  very early and still needs iteration: expect rough edges in its UI and
  behaviour, and expect it to change between releases. Reverse
  playback reads cached transforms instead of re-simulating, so scrubbing a
  16,000-body pyramid collapse costs milliseconds a frame; recordings larger
  than the memory budget spill to a temp file and stay scrubbable end to end.
- **Replays look like the scene you recorded.** A small sidecar file captures
  each body's colour and material response at record time (the `.b3rec`
  recording itself stays byte-identical to upstream's format); replaying a
  recording made at one worker count on another is a live cross-thread
  determinism check, verified on desktop at 1, 2, 4 and 8 workers.
- **In-editor gizmos** for every collider type and all nine joints, drawn in
  upstream's own debug palette so the editor and the runtime overlay agree.
- **Debug shells for every collider** in the demo's debug view: convex hulls,
  height fields and fitted meshes included, not just primitives.
- **Bombs work everywhere**: the demo's blast now auto-calibrates to scenes
  authored at upstream's density, and a crash on exploding near dynamic
  triangle-mesh bodies is guarded (the underlying upstream bug is written
  up, with the fix located, ready to file).
- Smaller: the sample picker groups by category and highlights where you are;
  saving a recording is instant and threaded with a visible progress state;
  spacebar drives the replay transport.

<p align="center">
  <img width="620" height="336" alt="pyramid_boom" src="https://github.com/user-attachments/assets/5f9e5d4d-092c-4286-b80b-9d4fb3b6ae62" />
</p>

https://github.com/user-attachments/assets/b3b04613-ed57-417e-822d-665f057b7d5c

https://github.com/user-attachments/assets/33752918-c3a2-4899-821c-bf13d9adce11
