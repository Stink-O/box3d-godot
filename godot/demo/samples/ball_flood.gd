extends Node3D

## Ball Flood: the body-count stress test. Three emitters hose balls into a
## glass tank as fast as their timers can fire, the balls are immortal
## (lifetime 0) and uncapped (max_alive 0), so the population only ever
## grows -- the limit is the solver, never the scene. The shell's body
## counter switches itself on here (wants_body_counter below) so the number
## at the bottom of the screen tells you where that limit is.

var camera_home := Vector3(0.0, 20.0, 42.0)
var camera_look_at := Vector3(0.0, 6.0, 0.0)
var wants_body_counter := true
