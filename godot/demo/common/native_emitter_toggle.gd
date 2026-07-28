extends Node3D

## Attached by _build_native to the rebuilt stage when a sample carried
## emitters across AND its authored root exposed a sample toggle (Ball
## Flood): the authored set_toggled cannot run on a native engine, but its
## whole job there is pausing the emitters, which this forwarder does. If a
## future sample's toggle means something OTHER than pausing its emitters,
## do not lean on this -- port that toggle for real.

var toggle_label := "Pause Emitters"


func get_toggle_label() -> String:
	return toggle_label


func set_toggled(on: bool) -> void:
	for node in find_children("*", "", true, false):
		if node.has_method(&"set_running"):
			node.set_running(not on)
