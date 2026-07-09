extends RefCounted

## Shared self-contained despawn: give a spawned body a lifetime, after which
## it frees itself. The Timer is a CHILD OF THE BODY (not a scene-tree timer),
## so the two live and die together: if the whole sample unloads first, the
## timer goes with it instead of leaving a dangling callback pointed at a freed
## body. Connecting straight to `body.queue_free` -- a bound method, not a
## lambda closing over `body` -- likewise avoids the "Lambda capture freed"
## crash a captured-lambda callback hits when it fires (or is torn down) after
## the node it captured has already been freed.
##
##   const Despawn = preload("res://common/despawn.gd")
##   Despawn.attach(body, 20.0)

static func attach(body: Node, lifetime: float) -> void:
	var timer := Timer.new()
	timer.wait_time = maxf(lifetime, 0.01)
	timer.one_shot = true
	timer.autostart = true
	body.add_child(timer)
	timer.timeout.connect(body.queue_free)
