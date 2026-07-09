import os

# Emits samples/body_types.tscn: a static block, a kinematic sliding platform
# carrying a stack of dynamic crates, and a kinematic piston that launches
# crates. body_types.gd animates the two kinematic bodies. Label3Ds mark each
# body type.

subres = []
nodes = []
S = subres.append
B = nodes.append

S('[sub_resource type="BoxMesh" id="FloorMesh"]\nsize = Vector3(34, 1, 34)')
S('[sub_resource type="StandardMaterial3D" id="FloorMat"]\n'
  'albedo_color = Color(0.2, 0.22, 0.26, 1)\nroughness = 0.55\nmetallic = 0.1')
S('[sub_resource type="BoxMesh" id="StaticMesh"]\nsize = Vector3(2, 3, 2)')
S('[sub_resource type="StandardMaterial3D" id="StaticMat"]\n'
  'albedo_color = Color(0.45, 0.47, 0.52, 1)\nroughness = 0.8')
S('[sub_resource type="BoxMesh" id="PlatMesh"]\nsize = Vector3(5, 0.4, 3)')
S('[sub_resource type="StandardMaterial3D" id="PlatMat"]\n'
  'albedo_color = Color(0.3, 0.6, 0.75, 1)\nroughness = 0.4\nmetallic = 0.3')
S('[sub_resource type="BoxMesh" id="PistonMesh"]\nsize = Vector3(1.6, 1, 1.6)')
S('[sub_resource type="StandardMaterial3D" id="PistonMat"]\n'
  'albedo_color = Color(0.75, 0.5, 0.3, 1)\nroughness = 0.5\nmetallic = 0.3')
S('[sub_resource type="BoxMesh" id="CrateMesh"]\nsize = Vector3(0.7, 0.7, 0.7)')
S('[sub_resource type="StandardMaterial3D" id="CrateMat"]\n'
  'albedo_color = Color(0.87, 0.55, 0.25, 1)\nroughness = 0.45')


def label(name, text, pos, color):
    B('[node name="%s" type="Label3D" parent="."]' % name)
    B('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, %g, %g, %g)' % pos)
    B('billboard = 1')
    B('text = "%s"' % text)
    B('font_size = 64')
    B('outline_size = 18')
    B('modulate = Color%s' % color)
    B('')


B('[node name="BodyTypes" type="Node3D"]')
B('script = ExtResource("1_bt")')
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

# Static block.
B('[node name="StaticBlock" type="Box3DBody" parent="Box3DWorld"]')
B('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, -9, 1.5, 0)')
B('body_type = 0')
B('box_size = Vector3(2, 3, 2)')
B('')
B('[node name="MeshInstance3D" type="MeshInstance3D" parent="Box3DWorld/StaticBlock"]')
B('mesh = SubResource("StaticMesh")')
B('material_override = SubResource("StaticMat")')
B('')

# Kinematic sliding platform.
B('[node name="KinematicPlatform" type="Box3DBody" parent="Box3DWorld"]')
B('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 0)')
B('body_type = 1')
B('box_size = Vector3(5, 0.4, 3)')
B('')
B('[node name="MeshInstance3D" type="MeshInstance3D" parent="Box3DWorld/KinematicPlatform"]')
B('mesh = SubResource("PlatMesh")')
B('material_override = SubResource("PlatMat")')
B('')

# Kinematic piston.
B('[node name="Piston" type="Box3DBody" parent="Box3DWorld"]')
B('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 8, 0.5, 0)')
B('body_type = 1')
B('box_size = Vector3(1.6, 1, 1.6)')
B('')
B('[node name="MeshInstance3D" type="MeshInstance3D" parent="Box3DWorld/Piston"]')
B('mesh = SubResource("PistonMesh")')
B('material_override = SubResource("PistonMat")')
B('')

# Dynamic crates: a stack riding the platform + a few over the piston.
B('[node name="Crates" type="Node3D" parent="Box3DWorld"]')
B('')
n = 0
crate_spots = []
for j in range(3):          # a 3x2 stack on the platform
    for i in range(2):
        crate_spots.append((-0.5 + i * 0.9, 1.55 + j * 0.75, -0.4 + (j % 2) * 0.8))
for i in range(3):          # crates over the piston
    crate_spots.append((8.0, 1.4 + i * 0.75, 0.0))
for (x, y, z) in crate_spots:
    B('[node name="Crate_%d" type="Box3DBody" parent="Box3DWorld/Crates"]' % n)
    B('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, %g, %g, %g)' % (x, y, z))
    B('box_size = Vector3(0.7, 0.7, 0.7)')
    B('')
    B('[node name="MeshInstance3D" type="MeshInstance3D" parent="Box3DWorld/Crates/Crate_%d"]' % n)
    B('mesh = SubResource("CrateMesh")')
    B('material_override = SubResource("CrateMat")')
    B('')
    n += 1

label("LblStatic", "STATIC", (-9, 4.2, 0), "(0.7, 0.75, 0.85, 1)")
label("LblKinematic", "KINEMATIC", (0, 3.4, 0), "(0.5, 0.8, 1, 1)")
label("LblDynamic", "DYNAMIC", (8, 4.6, 0), "(1, 0.75, 0.4, 1)")

header = '[gd_scene load_steps=%d format=3]' % (len(subres) + 2)
ext = '[ext_resource type="Script" path="res://samples/body_types.gd" id="1_bt"]'
out = header + '\n\n' + ext + '\n\n' + '\n\n'.join(subres) + '\n\n' + '\n'.join(nodes) + '\n'

_out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "samples", "body_types.tscn")
with open(_out, "w", encoding="utf-8") as f:
    f.write(out)
print("wrote samples/body_types.tscn with %d crates" % n)
