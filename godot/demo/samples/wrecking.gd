extends Node3D

## Wrecking Ball toy: a heavy ball hung from a real jointed rope (a chain of
## small dynamic links pinned end-to-end with Box3DBallJoint, see Box3DWorld/
## Rope), plane-locked so it swings straight into a block wall and smashes it
## on load. The rope, swing and impact are all simulated by joints + gravity —
## nothing here needs to draw anything per frame. Grab or shoot the ball to
## take another swing, or Reset to rebuild the wall.
