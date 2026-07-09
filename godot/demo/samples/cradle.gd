extends Node3D

## Newton's Cradle: five balls hang from RIGID rods (a Box3DDistanceJoint each,
## spring disabled) and are plane-locked, so each is a true rigid pendulum. The
## raised end ball swings down and transfers momentum crisply along the touching
## line, kicking the far ball out. The rods are inextensible (a springy link
## chain made the balls bob and damped the transfer), so this behaves like a
## real cradle. Grab or shoot the balls to mess with it; Reset to re-raise.
##
## The joints themselves are invisible, so we draw a thin rod for each string
## every frame, from its fixed anchor down to the ball it holds.

const ROD_RADIUS := 0.03

var _rods: Array = []  ## [MeshInstance3D, Vector3 anchor, Box3DBody ball]


func _ready() -> void:
	var strings := $Box3DWorld/Strings
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.15, 0.15, 0.17)
	mat.roughness = 0.5
	mat.metallic = 0.3
	for joint in strings.get_children():
		if not (joint is Box3DDistanceJoint):
			continue
		var ball := joint.get_node_or_null(joint.body_a) as Box3DBody
		if ball == null:
			continue
		var mi := MeshInstance3D.new()
		var mesh := CylinderMesh.new()
		mesh.top_radius = ROD_RADIUS
		mesh.bottom_radius = ROD_RADIUS
		mesh.height = 1.0  # scaled to the live length each frame
		mi.mesh = mesh
		mi.material_override = mat
		add_child(mi)
		_rods.append([mi, (joint as Node3D).global_position, ball])


func _process(_delta: float) -> void:
	for r in _rods:
		_place_rod(r[0], r[1], (r[2] as Box3DBody).global_position)


func _place_rod(mi: MeshInstance3D, a: Vector3, b: Vector3) -> void:
	var d := b - a
	var length := d.length()
	if length < 0.001:
		return
	var y := d / length
	# any axis perpendicular to y
	var x := y.cross(Vector3.FORWARD)
	if x.length() < 0.01:
		x = y.cross(Vector3.RIGHT)
	x = x.normalized()
	var z := x.cross(y)
	# CylinderMesh runs along local Y; scale Y to the rod length.
	var basis := Basis(x, y, z).scaled(Vector3(1.0, length, 1.0))
	mi.global_transform = Transform3D(basis, (a + b) * 0.5)
