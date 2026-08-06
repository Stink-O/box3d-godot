extends Node3D

## Bounce House -- a port of upstream's "Continuous / Bounce House" sample
## (samples/sample_continuous.cpp). One frictionless, perfectly elastic ball
## is fired across a 20 x 20 m walled pen at 170 m/s with gravity switched
## off, so it never settles: it just keeps bouncing. At that speed the ball
## crosses more than two metres per physics step -- roughly four times its
## own diameter -- so every wall hit is caught by CONTINUOUS collision. The
## walls are static, and box3d sweeps fast dynamic bodies against static
## geometry without needing the bullet flag (upstream leaves `isBullet`
## false here, so this port leaves `continuous` off too).
##
## The thing to watch is that the ball stays inside. Without the sweep it
## would leave the pen on the first wall it met.

const BALL_RADIUS := 0.5
const BALL_START := Vector3(-8.0, 4.0, 0.0)
const BALL_VELOCITY := Vector3(120.0, 0.0, 120.0)

var camera_home := Vector3(25.0, 35.4, 25.0)
var camera_look_at := Vector3(0.0, 0.0, 0.0)

var _ball: Box3DBody


func _ready() -> void:
	_ball = $Box3DWorld/Ball
	_ball.set_linear_velocity(BALL_VELOCITY)


## The shell's reusable Activate button: put the ball back on its opening shot.
func activate() -> void:
	_ball.teleport(Transform3D(Basis(), BALL_START))
	_ball.set_linear_velocity(BALL_VELOCITY)
	_ball.set_awake(true)
