extends Node3D

## Conveyor Belt -- a port of upstream's "Shapes / Conveyor Belt" sample
## (samples/sample_shapes.cpp). The ramp is a plain STATIC body that never
## moves: what carries the crates up it is `tangent_velocity`, a surface
## property that tells the solver the contact patch is sliding at 2 m/s along
## the shape's local X even though the body is still. Friction (0.8 here) is
## what couples that to whatever is resting on it, so the crates get dragged
## along instead of sliding off the tilt.
##
## The belt is yawed 0.2 rad, and the drive is expressed in the SHAPE's local
## space, so the crates travel along the belt rather than along world X.

var camera_home := Vector3(0.0, 17.9, 36.3)
var camera_look_at := Vector3(0.0, 1.0, 0.0)
