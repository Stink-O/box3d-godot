import os

# Emits samples/car.tscn: a port of box3d's own "Driving" sample (upstream
# samples/sample_joint.cpp). The vehicle is PURE Box3D — a box chassis with
# four sphere wheels hanging on Box3DWheelJoints (suspension spring + travel
# limits; the front pair steers, the rear pair drives via the joint's spin
# motor) and a soft Box3DParallelJoint holding the chassis upright, over the
# rolling wave terrain in car_terrain.res (tools/gen_car_terrain.gd — the
# triangle-mesh stand-in for upstream's b3CreateWave height field). All the
# numbers below are upstream's. car.gd only feeds key input into the joints.

CHASSIS = (4.0, 1.0, 2.0)   # full extents; upstream half-extents (2, 0.5, 1)
CHASSIS_Y = 2.5
WHEEL_R = 0.4
WHEEL_X = 1.5               # +X pair steers (the nose), -X pair drives
WHEEL_Y = 2.0
WHEEL_Z = 0.8

SUSPENSION_HERTZ = 4.0
SUSPENSION_TRAVEL = 0.2
STEERING_HERTZ = 10.0
STEER_TORQUE = 5.0
STEER_LIMIT = 0.785398      # 45 degrees
SPIN_TORQUE = 5.0

# name, x, z, steers
WHEELS = [
    ("FrontLeftWheel", WHEEL_X, WHEEL_Z, True),
    ("FrontRightWheel", WHEEL_X, -WHEEL_Z, True),
    ("RearLeftWheel", -WHEEL_X, WHEEL_Z, False),
    ("RearRightWheel", -WHEEL_X, -WHEEL_Z, False),
]

subres = []
nodes = []
S = subres.append
B = nodes.append

S('[sub_resource type="BoxMesh" id="ChassisMesh"]\nsize = Vector3(%g, %g, %g)' % CHASSIS)
S('[sub_resource type="StandardMaterial3D" id="ChassisMat"]\n'
  'albedo_color = Color(0.78, 0.18, 0.16, 1)\nroughness = 0.35\nmetallic = 0.25')
S('[sub_resource type="SphereMesh" id="WheelMesh"]\nradius = %g\nheight = %g' % (WHEEL_R, WHEEL_R * 2))
S('[sub_resource type="StandardMaterial3D" id="WheelMat"]\n'
  'albedo_color = Color(0.09, 0.09, 0.1, 1)\nroughness = 0.85')
S('[sub_resource type="StandardMaterial3D" id="TerrainMat"]\n'
  'albedo_color = Color(0.28, 0.4, 0.24, 1)\nroughness = 0.95')

B('[node name="Car" type="Node3D"]')
B('script = ExtResource("1_car")')
B('')
B('[node name="Box3DWorld" type="Box3DWorld" parent="."]')
B('')

# Rolling wave ground: one continuous static triangle-mesh collider, sourced
# from the child MeshInstance3D (shape_type 6 = Mesh).
B('[node name="Terrain" type="Box3DBody" parent="Box3DWorld"]')
B('body_type = 0')
B('shape_type = 6')
B('')
B('[node name="MeshInstance3D" type="MeshInstance3D" parent="Box3DWorld/Terrain"]')
B('mesh = ExtResource("2_terrain")')
B('material_override = SubResource("TerrainMat")')
B('')

B('[node name="Chassis" type="Box3DBody" parent="Box3DWorld"]')
B('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, %g, 0)' % CHASSIS_Y)
B('box_size = Vector3(%g, %g, %g)' % CHASSIS)
B('density = 0.5')
B('')
B('[node name="MeshInstance3D" type="MeshInstance3D" parent="Box3DWorld/Chassis"]')
B('mesh = SubResource("ChassisMesh")')
B('material_override = SubResource("ChassisMat")')
B('')

for name, x, z, _steers in WHEELS:
    B('[node name="%s" type="Box3DBody" parent="Box3DWorld"]' % name)
    B('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, %g, %g, %g)' % (x, WHEEL_Y, z))
    B('shape_type = 1')
    B('sphere_radius = %g' % WHEEL_R)
    B('density = 2.0')
    B('friction = 3.0')
    B('allow_fast_rotation = true')
    B('')
    B('[node name="MeshInstance3D" type="MeshInstance3D" parent="Box3DWorld/%s"]' % name)
    B('mesh = SubResource("WheelMesh")')
    B('material_override = SubResource("WheelMat")')
    B('')

# Wheel joints: unrotated, so the node's local Y (suspension + steering axis)
# is up and its local Z (the spin axle) runs across the car.
for name, x, z, steers in WHEELS:
    jname = name.replace("Wheel", "Joint")
    B('[node name="%s" type="Box3DWheelJoint" parent="Box3DWorld"]' % jname)
    B('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, %g, %g, %g)' % (x, WHEEL_Y, z))
    B('body_a = NodePath("../Chassis")')
    B('body_b = NodePath("../%s")' % name)
    B('suspension_hertz = %g' % SUSPENSION_HERTZ)
    B('suspension_limit_enabled = true')
    B('lower_suspension_limit = %g' % -SUSPENSION_TRAVEL)
    B('upper_suspension_limit = %g' % SUSPENSION_TRAVEL)
    if steers:
        B('steering_enabled = true')
        B('steering_hertz = %g' % STEERING_HERTZ)
        B('max_steering_torque = %g' % STEER_TORQUE)
        B('steering_limit_enabled = true')
        B('lower_steering_limit = %g' % -STEER_LIMIT)
        B('upper_steering_limit = %g' % STEER_LIMIT)
    else:
        B('spin_motor_enabled = true')
        B('max_spin_torque = %g' % SPIN_TORQUE)
    B('')

# Soft upright spring, as in upstream ("Keep vehicle upright"): local Z (the
# axis held parallel) points up; body_b empty = anchored to the world.
B('[node name="UprightSpring" type="Box3DParallelJoint" parent="Box3DWorld"]')
B('transform = Transform3D(1, 0, 0, 0, 0, 1, 0, -1, 0, 0, %g, 0)' % CHASSIS_Y)
B('body_a = NodePath("../Chassis")')
B('spring_hertz = 0.5')
B('spring_damping = 1.0')
B('')

# Floating speed readout (car.gd keeps it over the car), like upstream's
# on-screen speed text.
B('[node name="Speedo" type="Label3D" parent="."]')
B('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 4.4, 0)')
B('billboard = 1')
B('font_size = 64')
B('outline_size = 16')
B('modulate = Color(1, 0.92, 0.6, 1)')
B('text = "0.0 m/s"')
B('')

header = '[gd_scene load_steps=%d format=3]' % (len(subres) + 3)
ext = ('[ext_resource type="Script" path="res://samples/car.gd" id="1_car"]\n\n'
       '[ext_resource type="ArrayMesh" path="res://samples/car_terrain.res" id="2_terrain"]')
out = header + '\n\n' + ext + '\n\n' + '\n\n'.join(subres) + '\n\n' + '\n'.join(nodes)

_out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "samples", "car.tscn")
with open(_out, "w", encoding="utf-8", newline="\n") as f:
    f.write(out)
print("wrote samples/car.tscn: Driving-sample port (4 wheel joints + upright spring on wave terrain)")
