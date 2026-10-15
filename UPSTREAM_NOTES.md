# Upstream notes

Changes made for the Clean Room Ragdoll project, kept here so they can be offered upstream. Two local
branches, one on top of the other; nothing is pushed anywhere (the fork owner decides).

| branch | commits | touches |
|---|---|---|
| `crr/body-safety-factor` | 18448d4 | the Godot binding only (`godot/`) |
| `crr/armature-elliptical-cone` | 900e0f5 (C core + tests), 1a850f3 (binding), 779d5a6 (notes); then e0f1211 (asymmetric cone, C core + tests), 2fa57f4 (its binding) and these notes | `src/`, `include/`, `test/`, `godot/` |

---

# Part 3. Asymmetric elliptical cone (branch `crr/armature-elliptical-cone`, e0f1211 + 2fa57f4)

A mode of Part 2's elliptical cone with a separate limit in each direction of each swing axis, written in the
same style (def fields with zero defaults, `B3_API` getters and setters, solver code in prepare / solve,
recording ops, unit tests, `.clang-format` on the changed lines). Off by default; with it off, or with its
limits in symmetric pairs, Box3D is bit-identical to before (proof below).

## Why

Range-of-motion data are quoted per direction (hip: flexion 115°, extension 15°, abduction 40°, adduction 25°).
Part 2's symmetric ellipse is centred on the joint frame's z-axis, so a lopsided range needs the frame turned to
the middle of the range and an ellipse that encloses all of it: for a hip that admits 42 % non-human swing (by
solid angle), for a shoulder 37 %. Turning the frame also moves the swing–twist decomposition, and a limit that
follows another joint (hip flexion following the knee) had to move the frame live. Four half-angles carry such a
range directly, with the frame left on the rest pose.

## Shape

Four half-angles on Part 2's swing tilt `p = theta * e` (frame A coordinates): `angleX` towards +x,
`angleNegativeX` towards −x, `angleY` towards +y, `angleNegativeY` towards −y, each in `[0, 0.9 pi]`. Each quadrant
of the tilt plane is bounded by the quarter-ellipse through its two axis limits:

```
g(p) = sqrt((p.x / ax)^2 + (p.y / ay)^2),   ax = p.x >= 0 ? angleX : angleNegativeX
                                            ay = p.y >= 0 ? angleY : angleNegativeY
inside: g <= 1
```

That is how range-of-motion tables with four one-sided values are read (the project's ROM.md, and its soft
limits).

**The boundary is C¹, and C and J are continuous across quadrants.** g is continuous everywhere: on the x-axis
(`p.y = 0`) both y-limits give `g = |p.x| / ax`. Its gradient is `(p.x / (g ax^2), p.y / (g ay^2))`; across the
x-axis only `ay` changes, and the gradient's y-component `p.y / (g ay^2)` is 0 on the axis from either side, while
its x-component does not involve `ay`. The same holds across the y-axis. So `grad g` is continuous on the plane
minus the origin (where the row is never active: there `C` is the smallest angle, > 0), and so are the normal
`n = grad g / |grad g|`, the constraint `C = (1 − g) / |grad g|` and Part 2's Jacobian
`J = (n · e) a + (n · a)(theta z − theta cot(theta) e)`, which depends on p only through n, e, a and theta.
Geometrically, adjacent quarter-ellipses meet on the axis with a common tangent perpendicular to it (each
quarter-ellipse's normal there is the axis direction). Only the curvature jumps (from `ax / ay+^2` to `ax / ay-^2`),
and the solver does not use curvature. On an axis, C is exactly the radial distance to that axis' limit
(`ax − |p.x|`), from either side.

**Symmetric pairs are the elliptical cone, operation for operation.** The constraint picks `ax` and `ay` by sign and
then runs Part 2's arithmetic unchanged; with `angleNegativeX == angleX` and `angleNegativeY == angleY` the picked
values are the same floats, and the origin case's `min` over four values equals Part 2's `min` over two. So the
result is bit-identical, not just equal to round-off (unit test and state hash below).

## API

- `b3SphericalJointDef.enableAsymmetricCone` (default false), `coneAngleNegativeX`, `coneAngleNegativeY` (radians,
  clamped to `[0, 0.9 pi]` at creation). While it is on, `coneAngleX` / `coneAngleY` are the +x / +y limits.
- `b3SphericalJoint_EnableAsymmetricCone`, `b3SphericalJoint_IsAsymmetricConeEnabled`,
  `b3SphericalJoint_SetAsymmetricConeLimits( jointId, angleX, angleNegativeX, angleY, angleNegativeY )` (live,
  clamped like the elliptical cone; like upstream's other limit setters it does not wake the bodies),
  `b3SphericalJoint_GetConeLimitNegativeX`, `b3SphericalJoint_GetConeLimitNegativeY`. Part 2's
  `b3SphericalJoint_SetEllipticalConeLimits` keeps setting the +x / +y limits and leaves the other two.
- Used only while `enableConeLimit` and `enableEllipticalCone` are on. Toggling it clears the swing impulse, as
  toggling the elliptical cone does.
- Part 2's `b3SphericalJoint_GetConeAngles` reads the tilt the limits apply to.

## Solver

`b3GetAsymmetricConeConstraint` (`src/spherical_joint.c`) is Part 2's constraint with the semi-axes picked by the
sign of the tilt components (once the tilt direction is known); `b3GetEllipticalConeConstraint` now calls it with
symmetric pairs. `b3GetSphericalJointConeConstraint` makes the asymmetric or the symmetric call for a joint;
prepare, solve and `b3Joint_GetAngularSeparation` use it, so the row keeps exactly Part 2's form (fields,
speculative bias inside, the joint's softness when violated, Jacobian and effective mass refreshed every solve
call). `b3DrawSphericalJoint` draws one quarter-ellipse per quadrant.

## Recording and replay

The three def fields are written and read after `coneAngleY` (def-size assert 200 → 208 bytes on 64-bit), plus two
ops in the 0x70 range: `SphericalJointEnableAsymmetricCone` (0x74) and `SphericalJointSetAsymmetricConeLimits`
(0x75, four floats), with their dispatchers. `B3_REC_VERSION_MAJOR` 7 → 8 ("widened the spherical joint def with the
asymmetric cone"). `test_recording.c` `AllOps` creates the joint with the new def fields, toggles the mode before the
first step, changes one limit mid-run, and reads all of it back out of the replay world.

## Unit tests (`test/test_joint.c`)

- `TestSphericalJoint`: the new setters and getters, that the symmetric setter keeps the −x / −y limits, clamping.
- `TestAsymmetricConeJacobian`: on the boundary at 16 points (every quadrant) of four cones (a hip-like
  120 / 20 / 45 / 30°, one wider than a hemisphere, one with a 0.2 rad side), three twists: C = 0, and C's rate
  against central finite differences of the relative rotation. Across each axis, at 0.5 / 1.0 / 1.3 × that axis'
  limit, a hair (1e-4 rad) either side: C and J agree within 1e-3 and 1e-2, and C equals the radial distance to the
  axis limit (continuity off the boundary too). Symmetric pairs equal Part 2 bit for bit (24 rotations).
- `TestAsymmetricConeLimit`: a motor drives a lopsided cone (2.0 / 0.35 / 0.8 / 0.5 rad) onto each axis (it rests on
  that axis' own limit within 0.02 rad) and into each quadrant (it stays there, on the boundary within 3 %); a full
  turn of the motor slides the joint along the boundary through all four quadrants at 4 and 8 sub-steps (largest
  departure from the boundary 0.04 % in g, largest per-step move 0.018 rad, no spin-up); a limit the joint rests on
  is lowered and raised live, and changing another limit does not move it; the rest pose (tilt 0) stays put; and a
  motor-driven joint with symmetric pairs steps bit-identically to the elliptical cone for 240 steps.

All 320 Box3D sub-tests pass, Release and Debug (assertions on).

## Files touched

`include/box3d/types.h`, `include/box3d/box3d.h`, `src/joint.h`, `src/joint.c` (creation, angular separation),
`src/spherical_joint.c`, `src/recording.h`, `src/recording.c`, `src/recording_ops.inl`, `src/replay.c`,
`test/test_joint.c`, `test/test_recording.c`; binding: `godot/src/box3d_joint.h`, `godot/src/box3d_joint.cpp`,
`godot/doc_classes/Box3DBallJoint.xml` (which also escapes a `<=` in Part 2's text that Godot's doc loader
rejected: "Invalid tag in doc file").

`.clang-format` (clang-format 19, as in Part 2) was applied to the changed lines only; the new test code keeps
upstream's `(b3Vec3){ ... }` compound-literal spelling, which that version would rewrite as `( b3Vec3 ){ ... }`.

## Binding (box3d-godot)

`Box3DBallJoint.asymmetric_cone_enabled`, `cone_angle_negative_x`, `cone_angle_negative_y` (inspector group Cone
Limit, 0–162°, applied in `create_specific` and live, class XML docs). Defaults match Box3D's.

## Proof that nothing else changed

1. Box3D's unit tests pass, Release and Debug, including the new ones.
2. Per-step state hash (`tools/box3d_statehash/compare.sh` in the Clean Room Ragdoll repo, extended so it detects
   which fork features each tree has and adds the scenes they allow):
   - **stock (18448d4) vs this branch**, the stock scene, at 4 and 8 sub-steps: **identical at every step**, both
     untouched and with every new setter called at its default (armature 0, elliptical cone off, asymmetric cone
     off, all limits 0); the armature 1e-6 control run differs;
   - **779d5a6 vs this branch**: the stock scene is identical; an "elliptical" scene (the spherical chain's five
     cones made symmetric elliptical cones with two different angles, armature on two joints) is **identical at
     every step**, so Part 2 is untouched; and this branch's "asympairs" run (that scene with the asymmetric cone on
     and its limits in symmetric pairs) is **identical at every step to 779d5a6's elliptical run**: symmetric pairs
     are the elliptical cone end to end through the solver. A control with one −y limit 0.1 % smaller differs, so
     the comparison sees that limit act.

   | sub-steps | stock scene vs 18448d4 and 779d5a6 | new setters at defaults | elliptical scene vs 779d5a6 | asymmetric pairs vs 779d5a6 elliptical |
   |---|---|---|---|---|
   | 4 | identical (final SHA-256 70cdaef4…) | identical | identical (595a4942…) | identical (595a4942…) |
   | 8 | identical (6e567496…) | identical | identical (7602dac6…) | identical (7602dac6…) |

## Status

Candidate to upstream with Part 2. Not pushed. The project's use of it is EXPERIMENTS.md E1.9.

---

# Part 2. Joint armature and an elliptical swing cone (branch `crr/armature-elliptical-cone`)

Two features in Box3D's C core, written in upstream's style (file layout, naming, def fields with
zero defaults from `= { 0 }`, `B3_API` getters and setters, solver code in the joints' prepare /
warm-start / solve functions, `B3_REC` recording and replay, unit tests in `test/`, `.clang-format`
applied to the changed lines). With their defaults (armature 0, elliptical cone off) the solver is
bit-identical to stock (proof below).

## 1. Joint armature (revolute and spherical joints)

**Definition.** MuJoCo's XML reference defines joint armature as "additional inertia associated with
movement of the joint that is not due to body mass", usually the reflected inertia of a geared rotor
(rotor inertia times the gear ratio squared). In MuJoCo's reduced coordinates it adds to the diagonal
of the joint-space inertia matrix, i.e. a kinetic energy term `0.5 * a * qdot^2` per degree of freedom,
and the docs note that positive armature "significantly improves simulation stability, even for small
values".

**API.**
- `b3RevoluteJointDef.armature`, `b3RevoluteJoint_SetArmature`, `b3RevoluteJoint_GetArmature`: about
  the hinge axis (the joint's one free axis).
- `b3SphericalJointDef.armature`, `b3SphericalJoint_SetArmature`, `b3SphericalJoint_GetArmature`:
  isotropic, about all three axes (the joint's three degrees of freedom).
- Units kg·m², non-negative, default 0. The setters assert like upstream's (`b3IsValidFloat`, `>= 0`).

**Formulation for a maximal-coordinate soft-step solver.** Box3D has no joint-space mass matrix, so the
armature is modelled as what it physically is: a rotor of inertia `a` carried by the joint's relative
rotation. The rotor has one state, its angular velocity `u_r` (a scalar about the hinge axis for the
revolute joint, a world-space vector for the spherical joint), which persists between sub-steps and
steps. One extra velocity row per joint couples it rigidly to the bodies' relative angular velocity
`u = n · (wB - wA)` (revolute) or `u = wB - wA` (spherical).

With `k = n · (invIA + invIB) n` (revolute) or `K = invIA + invIB` (spherical) the inverse effective
mass of the relative rotation (the same quantity the joint's spring, motor and limit rows use), a rigid
coupling between the bodies and the rotor gives, for one Gauss-Seidel update,

```
impulse      = -(u - u_r) / (k + 1 / a)           revolute
             = -inv(K + I / a) * (u - u_r)        spherical
bodies:      wA -= invIA * impulse,  wB += invIB * impulse      (as the joint's other angular rows)
rotor:       u_r -= impulse / a                                 (equal and opposite)
```

After the update `u = u_r` exactly and the momentum `m u + a u_r` (with `m = 1 / k`) is unchanged: it is
a perfectly inelastic collision between the relative coordinate and the rotor. So:
- **It resists relative angular acceleration about the free axes.** A torque `tau` on the child of a
  joint to a static body spins it up at `tau / (I + a)` exactly (unit test `TestArmatureAcceleration`,
  to 0.1 % at 1, 4 and 8 sub-steps).
- **It cannot add energy**: an inelastic exchange of momentum only removes kinetic energy, counting the
  rotor's `0.5 a u_r^2`.
- **It is stable at any sub-step count**: the update is a projection (its effective mass is at most the
  rigid one, `1 / k`), with no stiffness or time step in it.
- `armatureMass` (`1 / (k + 1 / a)` or `inv(K + I / a)`) is computed in prepare, next to the other
  effective masses; the impulse applied in the current sub-step is kept in `armatureImpulse` (zeroed in
  warm start, not warm started: the rotor velocity carries the momentum) and is included in the joint's
  reported torque (`b3Get*JointTorque`, `b3GetJointReaction`).

**Only in the relax iterations.** Box3D's soft step solves each sub-step twice: with position bias
(soft constraint correction, then positions are integrated) and without it (relax), which removes the
bias velocity. The armature row runs only in the relax pass (`useBias == false`). If it also ran in the
biased pass, the rotor would absorb part of the velocity the position bias adds; the relax pass removes
that velocity from the bodies but not from the rotor, which returns it later. Measured on 2- and 5-link
hinge pendulums under gravity (armature 0.2 and 2.0, 1 / 4 / 16 sub-steps, 600 steps, energy counting
the rotor), the largest rise above the starting energy was:

| armature row solved in | 2 links, a = 2, 4 sub-steps | 5 links, a = 2, 4 sub-steps | any case |
|---|---|---|---|
| both passes | +10.4 J | +166 J | up to +166 J |
| relax pass only (chosen) | 0.000 J | 0.000 J | never above the start |
| re-sync `u_r` to the bodies every sub-step | +420 J | +23 000 J | unstable |

Unit test `TestArmatureEnergy` keeps the chosen form honest (5-link chain, a = 0.2 and 2.0, 1/4/16
sub-steps: energy never above the start by more than 0.5 % of the chain's weight × length, the margin
stock Box3D itself needs without armature).

**Interaction with springs, motors and limits.** The armature row is solved first in the joint's solve
function, before the spring, motor, limits and point constraint, so the hard rows keep the last word
(upstream's order puts the most important rows last). The other rows keep their own effective masses:
- a spring keeps exactly its stiffness and damping (`hertz` and `dampingRatio` are converted to impulses
  with the bodies' effective mass), and the rotor adds inertia, as in MuJoCo where `stiffness` is
  independent of armature;
- a limit stops the bodies at once; the rotor's remaining momentum is passed to the bodies, and thus into
  the limit, by `a k / (1 + a k)` per pass. The limit absorbs it (no bounce: the exchange is inelastic);
- a motor drives the bodies; the rotor follows over a few passes, and the motor's reported torque
  includes spinning it up.

**Initial and changed values.** At creation with `armature > 0`, and whenever the setter changes the
value, the rotor velocity is set to the bodies' current relative angular velocity
(`b3GetJointRelativeAngularVelocity`, `src/joint.c`), since the rotor turns with the joint. Rotor state
lives in the joint sim, so world snapshots and solver-set moves carry it like the warm-start impulses.

**Alternatives considered.**
1. *Add the armature only to the effective mass of the spring / motor / limit rows.* Does nothing when
   no row is active, so it cannot resist free relative acceleration; and it would make every spring
   stiffer by `(m + a) / m` for the same `hertz`. Rejected.
2. *Velocity damping toward the start-of-sub-step relative velocity, re-captured each sub-step.* The
   re-capture gives the rotor momentum the bodies never paid for when a later row (contact, limit,
   another joint) changes the relative velocity; measured unstable (table above). Rejected.
3. *A rotor coupled in both solve passes.* Stores bias velocity (table above). Rejected.
4. *Raising the child body's inertia.* Changes the body's own free rotation too (it is not joint
   inertia), and was tried in the project (E1.6) without effect. Not an engine change.

## 2. Elliptical swing cone (spherical joint)

**References.** PhysX documents its spherical / D6 swing limit as an "elliptical angular cone"
(`PxJointLimitCone`, two limit angles about the constraint frame's Y and Z axes, with a note that very
small or highly elliptical cones may jitter; `PxD6Joint::getSwingYAngle` / `getSwingZAngle` read the two
swings back). Jolt's `SwingTwistConstraint` has separate normal and plane half-cone angles; its
`SwingTwistConstraintPart` header documents the limit as an ellipse in the swing quaternion,
`(q_swing.y / sin(angleY / 2))^2 + (q_swing.z / sin(angleZ / 2))^2 <= 1`, which "roughly corresponds to
an elliptic cone" and "starts to deform for larger swing angles". Only these public docs and headers
were read; no code was taken from either.

**API.**
- `b3SphericalJointDef.enableEllipticalCone` (default false), `coneAngleX`, `coneAngleY` (radians,
  `[0, 0.9 * pi]`, clamped at creation and in the setter).
- `b3SphericalJoint_EnableEllipticalCone`, `b3SphericalJoint_IsEllipticalConeEnabled`,
  `b3SphericalJoint_SetEllipticalConeLimits( jointId, angleX, angleY )`, `b3SphericalJoint_GetConeLimitX`,
  `b3SphericalJoint_GetConeLimitY` (settable live, as upstream's cone and twist limits).
- `b3SphericalJoint_GetConeAngles` returns the current swing as a `b3Vec2` (below).
- The ellipse replaces the circular cone only while both `enableConeLimit` and `enableEllipticalCone`
  are true. The circular cone and its `0.5 * pi` clamp are untouched.

**Parameterization: the swing tilt.** Box3D's spherical joint already decomposes `relQ = swing * twist`
with the twist about the frame-B z-axis (`b3GetSwingAngle`, `b3GetTwistAngle`). The swing is the
minimal rotation taking the frame-A z-axis onto the frame-B z-axis: an angle `theta` about an axis `a` in
the frame-A xy-plane. The frame-B z-axis then tips towards `e = cross(a, z)`. The limit is placed on the
**tilt** `p = theta * e` (the log map of the swing, projected to the plane):

```
(p.x / angleX)^2 + (p.y / angleY)^2 <= 1
```

- For `angleX == angleY` it is exactly the circular cone `theta <= angle`.
- The tilt is well defined for any swing below pi (only `theta = pi`, the frame-B axis pointing exactly
  backwards, has no direction), so the cone may be wider than a hemisphere; the angles are clamped at
  0.9 pi, where the twist Jacobian's `tan(theta / 2)` is still below 6.3.
- Compared with Jolt's half-angle-sine ellipse and PhysX's tan-quarter form, the tilt measures the
  angles in the units the limit is specified in (an ellipse of angles, not of sines), so a range quoted
  as "flexion 120°, abduction 45°" is the ellipse with those semi-axes, at any size. That matches how
  range-of-motion data are given, which is why it was chosen.
- `b3GetSwingTilt` removes the twist from `relQ` without trigonometry: with `sw = |(q.z, q.s)|`, the half
  twist's cosine and sine are `q.s / sw` and `q.z / sw`, the swing quaternion's vector part is
  `(c q.x - s q.y, s q.x + c q.y)`, and `theta = 2 atan2(|(q.x, q.y)|, sw)`. It is polarity independent.

**Constraint and Jacobian** (`b3GetEllipticalConeConstraint`, `src/spherical_joint.c`). With
`g = sqrt((p.x / angleX)^2 + (p.y / angleY)^2)` the constraint is the first-order distance to the ellipse
along its normal `n = grad g / |grad g|`:

```
C = (1 - g) / |grad g|          (radians, positive inside; exact on the ellipse; angle - theta for a circle)
```

The tilt's rate follows from the relative angular velocity `w` in frame-A coordinates (with `phi` the
azimuth of `e`):

```
dtheta/dt = w · a
dphi/dt   = w · (z - cot(theta) e)
dp/dt     = dtheta/dt e + theta dphi/dt a
dC/dt     = -n · dp/dt = -w · J,   J = (n · e) a + (n · a) (theta z - theta cot(theta) e)
```

`J` is rotated to world space with frame A. For a circle `n = e` and `J = a`, upstream's swing axis.
Unit test `TestEllipticalConeJacobian` checks `C` and `J` against central finite differences for four
ellipses (including 137° and 109° semi-axes), three twists and twelve points on each ellipse, and the
circle reduction.

**Solver.** The row reuses the circular cone's fields and form exactly (`swingImpulse`, `swingAxis`,
`swingMass`, speculative `c * inv_h` when inside, the joint's `constraintSoftness` when violated, the
accumulated impulse clamped at 0). Two differences: `C` comes from the ellipse, and since the ellipse
normal turns along the boundary, `J` and its effective mass are recomputed every solve call (and stored
in `swingAxis` for warm starting), where the circle keeps its prepare-time axis. Prepare computes the
first `J` and mass the same way. There is no separate soft or spring mode for the cone upstream, so none
was added: the joint's existing constraint softness applies, and the joint's spring and motor are
unchanged.

**Also updated.** `b3Joint_GetAngularSeparation` reports `max(0, -C)` for the ellipse, using the joint
frames (upstream's circular branch uses the body rotations without the local frames; left as is, but
noted here as a possible upstream issue); `b3GetSphericalJointTorque` and `b3GetJointReaction` use the
stored Jacobian; `b3DrawSphericalJoint` draws the elliptical boundary.

**Measured** (unit test `TestEllipticalConeLimit`): a ball joint driven by a motor into its ellipse comes
to rest on it within 0.02 rad, along either axis and in between, including a 2.0 rad (115°) semi-axis;
an elliptical cone with equal angles rests at the same swing as the circular cone (within 0.01 rad).

## Recording and replay

- Def writers / readers (`b3RecW_REVOLUTEJOINTDEF`, `b3RecW_SPHERICALJOINTDEF`, `src/recording.c`;
  `b3RecR_*`, `src/replay.c`) carry the new fields; the def-size static asserts are updated (160 / 200
  bytes on 64-bit).
- Four new ops (`src/recording_ops.inl`), in the unused 0x70–0x7F range, documented in the range table as
  "joints continued, past the 0xE7 range": `RevoluteJointSetArmature` (0x70), `SphericalJointSetArmature`
  (0x71), `SphericalJointEnableEllipticalCone` (0x72), `SphericalJointSetEllipticalConeLimits` (0x73),
  each with its `b3RecDispatch_*` in `src/replay.c`.
- `B3_REC_VERSION_MAJOR` 6 → 7 ("widened the revolute and spherical joint defs"), as upstream did for the
  body def's safety factor.
- `test_recording.c` `AllOps` sets the new def fields and calls every new setter (before stepping and
  mid-run), validates the replay at two worker counts and through a file, and reads the values back out
  of the replay world.

## Files touched

`include/box3d/types.h` (def fields), `include/box3d/box3d.h` (API), `src/joint.h` (sim fields and
helpers), `src/joint.c` (creation, relative velocity helper, reaction torque, angular separation),
`src/revolute_joint.c`, `src/spherical_joint.c`, `src/recording.h`, `src/recording.c`,
`src/recording_ops.inl`, `src/replay.c`, `test/test_joint.c`, `test/test_recording.c`; binding:
`godot/src/box3d_joint.h`, `godot/src/box3d_joint.cpp`, `godot/doc_classes/Box3DHingeJoint.xml`,
`godot/doc_classes/Box3DBallJoint.xml`.

`.clang-format` was applied to the changed lines only (clang-format 19, which lacks the file's
`ExceptDoubleParentheses` key, a no-op for `false`): upstream's files are not fully formatted by that
version, so formatting whole files would rewrite unrelated code. Compound-literal casts were kept in
upstream's `(b3Vec2){ ... }` spelling.

## Binding (box3d-godot)

`Box3DHingeJoint.armature`, `Box3DBallJoint.armature`, `elliptical_cone_enabled`, `cone_angle_x`,
`cone_angle_y` (properties with setter / getter, applied in `create_specific` and live, `_bind_methods`,
inspector groups, class XML docs) and `Box3DBallJoint.get_current_cone_angles()` (`Vector2`). Defaults
match Box3D's. The scene-dock warning about cone angles above 90° is skipped while the elliptical cone
is on.

## Proof that stock behaviour is unchanged

1. Box3D's unit tests pass, Release and Debug (assertions on), including the new ones.
2. Per-step state hash: `tools/box3d_statehash/` in the Clean Room Ragdoll repo builds a stock scene
   (stack of 8 boxes; a 5-capsule revolute chain with limits, springs, a velocity motor and friction
   motors; a 5-capsule spherical chain with circular cones of 0.6–1.2 rad, twist limits, springs toward
   a rotated target, a velocity motor and friction motors; a 60 m/s sphere and a 45 m/s box fired at a
   3 cm static plank so continuous collision fires — the sphere ends resting on the plank; a box spinning
   about three axes), steps it 600 times at 1/120 s and compares every body's position, rotation and
   velocities after every step by SHA-256, Box3D built from `18448d4` against this branch, at 4 and 8
   sub-steps: **identical at every step**, both untouched and with every new setter called at its default
   (armature 0, elliptical cone off, limits 0). A control run with armature 1e-6 kg·m² on one joint
   differs, so the comparison can see a change that small.
3. The Clean Room Ragdoll default body (25 scenarios at 4 and 8 sub-steps through the binding, 2586
   recorded values) gives identical results with the stock and the patched addon.

## Status

Candidate to upstream. Not pushed. The project's use of it is EXPERIMENTS.md E1.8.

---

# Part 1. Box3DBody.safety_factor (branch `crr/body-safety-factor`)

A small change to the Godot binding only (`godot/`), made for the Clean Room Ragdoll project and
kept here so it can be offered upstream. Box3D's C core (`src/`, `include/`, `extern/`) is
untouched by this part.

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
