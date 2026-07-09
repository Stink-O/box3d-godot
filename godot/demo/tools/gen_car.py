import os

# Emits samples/car.tscn: a boxy chassis on four free-rolling cylinder wheels.
# car.gd drives it ARCADE-style -- it sets the chassis's forward speed and yaw
# directly, and the chassis has its pitch/roll locked so it always stays upright
# and controllable. The wheels aren't motorized; they just spin from ground
# contact and keep the chassis at ride height (box3d can't do a proper driven
# wheel/suspension, so we don't rely on wheel-motor traction). The bumpy noise
# terrain and all input live in car.gd.

CHASSIS = (1.8, 0.5, 4.0)
WHEEL_R = 0.42
WHEEL_Y = 0.48
WHEEL_X = 0.95
WHEEL_Z = 1.5

# name, x-sign, z-sign
WHEELS = [
    ("FrontLeftWheel", -WHEEL_X, -WHEEL_Z),
    ("FrontRightWheel", WHEEL_X, -WHEEL_Z),
    ("RearLeftWheel", -WHEEL_X, WHEEL_Z),
    ("RearRightWheel", WHEEL_X, WHEEL_Z),
]

subres = []
nodes = []
S = subres.append
B = nodes.append

S('[sub_resource type="BoxMesh" id="ChassisMesh"]\nsize = Vector3(%g, %g, %g)' % CHASSIS)
S('[sub_resource type="StandardMaterial3D" id="ChassisMat"]\n'
  'albedo_color = Color(0.78, 0.18, 0.16, 1)\nroughness = 0.35\nmetallic = 0.25')
WHEEL_W = 0.32  # cylinder width (along the axle)
S('[sub_resource type="CylinderMesh" id="WheelMesh"]\ntop_radius = %g\nbottom_radius = %g\nheight = %g'
  % (WHEEL_R, WHEEL_R, WHEEL_W))
S('[sub_resource type="StandardMaterial3D" id="WheelMat"]\n'
  'albedo_color = Color(0.08, 0.08, 0.09, 1)\nroughness = 0.9')

B('[node name="Car" type="Node3D"]')
B('script = ExtResource("1_car")')
B('')
B('[node name="Box3DWorld" type="Box3DWorld" parent="."]')
B('gravity = Vector3(0, -9.8, 0)')
B('substep_count = 8')
B('')

# Chassis. Pitch/roll are locked so the car always stays upright and drivable
# (car.gd steers it by applying force + yaw torque directly -- an arcade drive
# that's far more controllable than trying to steer via wheel-motor traction).
# Damping keeps it from sliding/spinning forever when you let go.
B('[node name="Chassis" type="Box3DBody" parent="Box3DWorld"]')
B('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0.83, 0)')
B('box_size = Vector3(%g, %g, %g)' % CHASSIS)
B('density = 6.0')
B('friction = 0.4')
B('linear_damping = 0.4')
B('angular_damping = 4.0')
B('lock_angular_x = true')
B('lock_angular_z = true')
B('')
B('[node name="MeshInstance3D" type="MeshInstance3D" parent="Box3DWorld/Chassis"]')
B('mesh = SubResource("ChassisMesh")')
B('material_override = SubResource("ChassisMat")')
B('')

# Cylinder wheels: basis rotated so the cylinder's local-Y axis points along the
# axle (world X), matching the CylinderMesh; the hinge frame (not the wheel)
# still defines the spin axis.
for name, sx, sz in WHEELS:
    B('[node name="%s" type="Box3DBody" parent="Box3DWorld"]' % name)
    B('transform = Transform3D(0, 1, 0, -1, 0, 0, 0, 0, 1, %g, %g, %g)' % (sx, WHEEL_Y, sz))
    B('shape_type = 3')
    B('capsule_radius = %g' % WHEEL_R)
    B('capsule_height = %g' % WHEEL_W)
    B('cylinder_sides = 32')
    B('density = 1.5')
    B('friction = 0.2')  # low so the wheels glide (don't brake the chassis drive)
    B('')
    B('[node name="MeshInstance3D" type="MeshInstance3D" parent="Box3DWorld/%s"]' % name)
    B('mesh = SubResource("WheelMesh")')
    B('material_override = SubResource("WheelMat")')
    B('')

# Hinge joints: frame Z is the axle (world X). Transform basis cols
# x=(0,0,1) y=(0,1,0) z=(-1,0,0) -> z-axis = world -X (the axle). The wheels are
# FREE-ROLLING (no motor) -- they just spin from ground contact as the chassis
# is driven, so they read as real wheels while car.gd drives the chassis.
for name, sx, sz in WHEELS:
    jname = name.replace("Wheel", "Joint")
    B('[node name="%s" type="Box3DHingeJoint" parent="Box3DWorld"]' % jname)
    B('transform = Transform3D(0, 0, 1, 0, 1, 0, -1, 0, 0, %g, %g, %g)' % (sx, WHEEL_Y, sz))
    B('body_a = NodePath("../%s")' % name)
    B('body_b = NodePath("../Chassis")')
    B('')

header = '[gd_scene load_steps=%d format=3]' % (len(subres) + 2)
ext = '[ext_resource type="Script" path="res://samples/car.gd" id="1_car"]'
out = header + '\n\n' + ext + '\n\n' + '\n\n'.join(subres) + '\n\n' + '\n'.join(nodes) + '\n'

_out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "samples", "car.tscn")
with open(_out, "w", encoding="utf-8") as f:
    f.write(out)
print("wrote samples/car.tscn: chassis + 4 free-rolling cylinder wheels + 4 hinge joints")
