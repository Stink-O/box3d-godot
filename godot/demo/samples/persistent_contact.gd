extends Node3D

## Persistent Contact -- a port of upstream's "Events / Persistent Contact"
## sample (samples/sample_events.cpp). A single dense sphere is launched along
## a TRIANGLE MESH floor and its live contact is drawn every frame: a cross at
## each manifold point and a line whose length is that point's accumulated
## normal impulse. The interesting part is that the contact PERSISTS -- the
## same manifold is carried from step to step as the ball rolls over triangle
## after triangle, instead of being rebuilt (and jittering) each time.
##
## Upstream latches the first `beginEvents[i].contactId` and follows that one
## contact id until an end event retires it. The GDExtension does not expose
## contact ids, so this port polls `Box3DBody.get_contacts()` on the ball,
## which reports exactly the touching manifolds box3d is carrying for it --
## the same data (`b3Body_GetContactData`), read from the body instead of from
## the contact.
##
## Upstream's ground is `b3CreateGridMesh(20, 20, 2.0, 2, true)`: a 40x40 m
## grid of 20x20 cells triangulated into 800 triangles. A Godot PlaneMesh of
## the same size with 19 subdivisions per axis is the same tessellation, fed
## to a MESH-typed body.

## Upstream's sphere: radius 0.5, density 20, rolling resistance 0.01, dropped
## at x = -18 with 4 m/s along +x.
const BALL_RADIUS := 0.5
const BALL_START := Vector3(-18.0, 1.0, 0.5)
const BALL_VELOCITY := Vector3(4.0, 0.0, 0.0)
## Metres drawn per newton-second of accumulated normal impulse.
const IMPULSE_SCALE := 1.0
const CROSS_SIZE := 0.15

var camera_home := Vector3(0.0, 25.0, 34.6)
var camera_look_at := Vector3(0.0, 5.0, 0.0)

var _ball: Box3DBody
var _lines: ImmediateMesh
@onready var _label: Label3D = $Status


func _ready() -> void:
	_ball = $Box3DWorld/Ball
	_ball.set_linear_velocity(BALL_VELOCITY)

	_lines = ImmediateMesh.new()
	var marker := MeshInstance3D.new()
	marker.name = "ContactMarkers"
	marker.mesh = _lines
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.86, 0.08, 0.24)  # upstream's crimson
	mat.no_depth_test = true
	marker.material_override = mat
	add_child(marker)


## The shell's reusable Activate button: launch the ball again from the start.
func activate() -> void:
	_ball.teleport(Transform3D(Basis(), BALL_START))
	_ball.set_linear_velocity(BALL_VELOCITY)
	_ball.set_angular_velocity(Vector3.ZERO)
	_ball.set_awake(true)


func _process(_delta: float) -> void:
	_lines.clear_surfaces()
	var contacts: Array = _ball.get_contacts()
	var points := 0
	var impulse := 0.0
	if not contacts.is_empty():
		_lines.surface_begin(Mesh.PRIMITIVE_LINES)
		for c in contacts:
			# `normal` points from the ball towards what it is touching, so the
			# impulse the ball receives is along -normal: upstream draws the
			# same line from the ground's side of the manifold.
			var push: Vector3 = -(c["normal"] as Vector3)
			for p in c["points"]:
				var pos: Vector3 = p["position"]
				var j: float = p["impulse"]
				points += 1
				impulse += j
				_cross(pos)
				_lines.surface_add_vertex(pos)
				_lines.surface_add_vertex(pos + push * j * IMPULSE_SCALE)
		_lines.surface_end()
	_label.text = "manifold points = %d\ntotal normal impulse = %.2f" % [points, impulse]


func _cross(p: Vector3) -> void:
	for axis in [Vector3.RIGHT, Vector3.UP, Vector3.BACK]:
		_lines.surface_add_vertex(p - axis * CROSS_SIZE)
		_lines.surface_add_vertex(p + axis * CROSS_SIZE)
