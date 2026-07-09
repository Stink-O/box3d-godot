import os
import math

# Emits samples/motor.tscn: a motorized turntable (hinge motor about Y) loaded
# with boxes that fling off as it spins up, plus a motorized windmill bar (hinge
# motor about Z) that swats boxes. motor.gd drives the motor speeds.

subres = []
nodes = []
S = subres.append
B = nodes.append

S('[sub_resource type="BoxMesh" id="FloorMesh"]\nsize = Vector3(40, 1, 40)')
S('[sub_resource type="StandardMaterial3D" id="FloorMat"]\n'
  'albedo_color = Color(0.2, 0.22, 0.26, 1)\nroughness = 0.55\nmetallic = 0.1')
S('[sub_resource type="CylinderMesh" id="DiscMesh"]\n'
  'top_radius = 3.5\nbottom_radius = 3.5\nheight = 0.3')
S('[sub_resource type="StandardMaterial3D" id="DiscMat"]\n'
  'albedo_color = Color(0.35, 0.5, 0.7, 1)\nroughness = 0.5\nmetallic = 0.2')
S('[sub_resource type="CylinderMesh" id="PostMesh"]\n'
  'top_radius = 0.3\nbottom_radius = 0.3\nheight = 1.1')
S('[sub_resource type="StandardMaterial3D" id="PostMat"]\n'
  'albedo_color = Color(0.3, 0.32, 0.38, 1)\nroughness = 0.7')
S('[sub_resource type="BoxMesh" id="RiderMesh"]\nsize = Vector3(0.8, 0.8, 0.8)')
S('[sub_resource type="StandardMaterial3D" id="RiderMat"]\n'
  'albedo_color = Color(0.87, 0.46, 0.2, 1)\nroughness = 0.4')
S('[sub_resource type="BoxMesh" id="BladeMesh"]\nsize = Vector3(4, 0.4, 0.4)')
S('[sub_resource type="StandardMaterial3D" id="BladeMat"]\n'
  'albedo_color = Color(0.7, 0.35, 0.35, 1)\nroughness = 0.5')

B('[node name="Motor" type="Node3D"]')
B('script = ExtResource("1_motor")')
B('')
B('[node name="Box3DWorld" type="Box3DWorld" parent="."]')
B('gravity = Vector3(0, -9.8, 0)')
B('')
B('[node name="Floor" type="Box3DBody" parent="Box3DWorld"]')
B('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, -0.5, 0)')
B('body_type = 0')
B('shape_type = 7')
B('')
B('[node name="MeshInstance3D" type="MeshInstance3D" parent="Box3DWorld/Floor"]')
B('mesh = SubResource("FloorMesh")')
B('material_override = SubResource("FloorMat")')
B('')

# --- Turntable ---
# Decorative static post under the disc.
B('[node name="TurnPost" type="Box3DBody" parent="Box3DWorld"]')
B('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0.55, 0)')
B('body_type = 0')
B('shape_type = 3')
B('capsule_radius = 0.3')
B('capsule_height = 1.1')
B('')
B('[node name="MeshInstance3D" type="MeshInstance3D" parent="Box3DWorld/TurnPost"]')
B('mesh = SubResource("PostMesh")')
B('material_override = SubResource("PostMat")')
B('')
# Dynamic disc.
B('[node name="Turntable" type="Box3DBody" parent="Box3DWorld"]')
B('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 1.25, 0)')
B('shape_type = 3')
B('capsule_radius = 3.5')
B('capsule_height = 0.3')
B('density = 0.6')
B('friction = 0.9')
B('')
B('[node name="MeshInstance3D" type="MeshInstance3D" parent="Box3DWorld/Turntable"]')
B('mesh = SubResource("DiscMesh")')
B('material_override = SubResource("DiscMat")')
B('')
# Hinge motor about Y: orient joint so its local Z points up (basis rotates Z->Y).
B('[node name="TurntableJoint" type="Box3DHingeJoint" parent="Box3DWorld"]')
B('transform = Transform3D(1, 0, 0, 0, 0, -1, 0, 1, 0, 0, 1.25, 0)')
B('body_a = NodePath("../Turntable")')
B('motor_enabled = true')
B('motor_speed = 0.0')
B('max_motor_torque = 4000.0')
B('')

# Riders that fling off.
B('[node name="Riders" type="Node3D" parent="Box3DWorld"]')
B('')
for i in range(8):
    a = (i / 8.0) * math.tau
    x = math.cos(a) * 1.8
    z = math.sin(a) * 1.8
    B('[node name="Rider_%d" type="Box3DBody" parent="Box3DWorld/Riders"]' % i)
    B('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, %.4g, 1.85, %.4g)' % (x, z))
    B('box_size = Vector3(0.8, 0.8, 0.8)')
    B('')
    B('[node name="MeshInstance3D" type="MeshInstance3D" parent="Box3DWorld/Riders/Rider_%d"]' % i)
    B('mesh = SubResource("RiderMesh")')
    B('material_override = SubResource("RiderMat")')
    B('')

# --- Windmill (free-spinning blade, high enough to clear the ground; shoot
# balls at it with F to get them batted). ---
WX = 9.0
WY = 3.6
B('[node name="WindPost" type="Box3DBody" parent="Box3DWorld"]')
B('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, %g, %g, 0)' % (WX, WY / 2.0))
B('body_type = 0')
B('box_size = Vector3(0.4, %g, 0.4)' % WY)
B('')
B('[node name="MeshInstance3D" type="MeshInstance3D" parent="Box3DWorld/WindPost"]')
B('mesh = SubResource("PostMesh")')
B('material_override = SubResource("PostMat")')
B('')
B('[node name="Windmill" type="Box3DBody" parent="Box3DWorld"]')
B('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, %g, %g, 1.2)' % (WX, WY))
B('box_size = Vector3(4, 0.4, 0.4)')
B('density = 0.8')
B('')
B('[node name="MeshInstance3D" type="MeshInstance3D" parent="Box3DWorld/Windmill"]')
B('mesh = SubResource("BladeMesh")')
B('material_override = SubResource("BladeMat")')
B('')
# Hinge motor about Z (default hinge axis, no rotation needed).
B('[node name="WindmillJoint" type="Box3DHingeJoint" parent="Box3DWorld"]')
B('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, %g, %g, 1.2)' % (WX, WY))
B('body_a = NodePath("../Windmill")')
B('motor_enabled = true')
B('motor_speed = 0.0')
B('max_motor_torque = 800.0')
B('')

header = '[gd_scene load_steps=%d format=3]' % (len(subres) + 2)
ext = '[ext_resource type="Script" path="res://samples/motor.gd" id="1_motor"]'
out = header + '\n\n' + ext + '\n\n' + '\n\n'.join(subres) + '\n\n' + '\n'.join(nodes) + '\n'

_out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "samples", "motor.tscn")
with open(_out, "w", encoding="utf-8") as f:
    f.write(out)
print("wrote samples/motor.tscn")
