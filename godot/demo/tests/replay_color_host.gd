extends Node3D

## Test double for F-042's colour protocol: a node that draws its own bodies and
## therefore has to be ASKED what colour it gave them. The real implementations
## are `common/cube_grid_multimesh.gd`, `common/ball_cloud.gd`,
## `samples/joint_grid.gd` and `Box3DMultiMeshRenderer`; this one is the same
## shape with the drawing left out, so the selftest exercises the protocol
## itself rather than any one renderer.
##
## No `class_name`: a test fixture has no business in the project's global class
## list, and a new global class needs an --import before every export.

var colors: Array = []


func get_replay_body_colors() -> Dictionary:
	var out := {}
	var i := 0
	for c in get_children():
		if c is Box3DBody:
			if i < colors.size():
				out[c] = colors[i]
			i += 1
	return out
