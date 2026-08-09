extends Node3D

## Wrecking Ball toy: a heavy ball hung from a real jointed rope (a chain of
## small dynamic links pinned end-to-end with Box3DBallJoint, see Box3DWorld/
## Rope), plane-locked so it swings straight into a block wall and smashes it
## on load. The rope, swing and impact are all simulated by joints + gravity —
## nothing here needs to draw anything per frame. Grab or shoot the ball to
## take another swing, or Reset to rebuild the wall.
##
## Post and Arm are the crane, and they are scenery: MeshInstance3D, no
## collider, nothing in the world touches them. They stand off in -z, which is
## the one direction the z-locked ball never reaches and also behind the shell's
## default view, with the jib running forward over the rope's anchor. The scene
## and its placement are generated -- edit tools/gen_wrecking.py and re-run it,
## not this .tscn.
