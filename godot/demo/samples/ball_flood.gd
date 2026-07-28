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


## The shell's reusable sample toggle: ON pauses the flood, and a fresh load
## always starts un-toggled, i.e. flooding. On a native engine the same
## toggle comes from common/native_emitter_toggle.gd (this script does not
## survive the rebuild, the emitters do).
func get_toggle_label() -> String:
	return "Pause Emitters"


func set_toggled(on: bool) -> void:
	for node in find_children("*", "", true, false):
		if node.has_method(&"set_running"):
			node.set_running(not on)
