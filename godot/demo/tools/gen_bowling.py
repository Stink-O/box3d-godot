import os

# Emits samples/bowling.tscn: a lane with side bumpers, ten pins racked in a
# triangle, and a ball. bowling.gd rolls the ball in on load. Pins are dynamic
# cylinders; the ball is a heavy sphere. Reset re-racks; F shoots more balls.

PIN_R = 0.18
PIN_H = 1.3
PIN_DX = 0.95
APEX_Z = -9.0

subres = []
nodes = []
S = subres.append
B = nodes.append

S('[sub_resource type="StandardMaterial3D" id="LaneMat"]\n'
  'albedo_color = Color(0.5, 0.38, 0.22, 1)\nroughness = 0.35\nmetallic = 0.1')
S('[sub_resource type="BoxMesh" id="LaneMesh"]\nsize = Vector3(5.4, 1, 36)')
S('[sub_resource type="StandardMaterial3D" id="BumperMat"]\n'
  'albedo_color = Color(0.25, 0.27, 0.32, 1)\nroughness = 0.6')
S('[sub_resource type="CylinderMesh" id="PinMesh"]\n'
  'top_radius = %g\nbottom_radius = %g\nheight = %g' % (PIN_R, PIN_R, PIN_H))
S('[sub_resource type="StandardMaterial3D" id="PinMat"]\n'
  'albedo_color = Color(0.95, 0.95, 0.97, 1)\nroughness = 0.4')
S('[sub_resource type="SphereMesh" id="BallMesh"]\nradius = 0.5\nheight = 1.0')
S('[sub_resource type="StandardMaterial3D" id="BallMat"]\n'
  'albedo_color = Color(0.2, 0.25, 0.7, 1)\nroughness = 0.2\nmetallic = 0.3')


def fit_box(name, size, pos, mat):
    mid = "M_" + name
    S('[sub_resource type="BoxMesh" id="%s"]\nsize = Vector3(%g, %g, %g)' % (mid, size[0], size[1], size[2]))
    B('[node name="%s" type="Box3DBody" parent="Box3DWorld"]' % name)
    B('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, %g, %g, %g)' % pos)
    B('body_type = 0')
    B('shape_type = 7')
    B('')
    B('[node name="MeshInstance3D" type="MeshInstance3D" parent="Box3DWorld/%s"]' % name)
    B('mesh = SubResource("%s")' % mid)
    B('material_override = SubResource("%s")' % mat)
    B('')


B('[node name="Bowling" type="Node3D"]')
B('script = ExtResource("1_bowl")')
B('')
B('[node name="Box3DWorld" type="Box3DWorld" parent="."]')
B('gravity = Vector3(0, -9.8, 0)')
B('')

# Lane (Fit-Mesh floor) + side bumpers.
B('[node name="Lane" type="Box3DBody" parent="Box3DWorld"]')
B('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, -0.5, -2)')
B('body_type = 0')
B('shape_type = 7')
B('friction = 0.15')
B('')
B('[node name="MeshInstance3D" type="MeshInstance3D" parent="Box3DWorld/Lane"]')
B('mesh = SubResource("LaneMesh")')
B('material_override = SubResource("LaneMat")')
B('')
fit_box("BumperL", (0.4, 1.0, 34), (-2.7, 0.5, -2), "BumperMat")
fit_box("BumperR", (0.4, 1.0, 34), (2.7, 0.5, -2), "BumperMat")

# Ten pins in a triangle, apex toward the bowler (+Z).
B('[node name="Pins" type="Node3D" parent="Box3DWorld"]')
B('')
n = 0
for r in range(4):
    z = APEX_Z - r * 0.95
    for i in range(r + 1):
        x = (i - r / 2.0) * PIN_DX
        B('[node name="Pin_%d" type="Box3DBody" parent="Box3DWorld/Pins"]' % n)
        B('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, %.4g, %g, %.4g)' % (x, PIN_H / 2.0, z))
        B('shape_type = 3')
        B('capsule_radius = %g' % PIN_R)
        B('capsule_height = %g' % PIN_H)
        B('density = 0.6')
        B('friction = 0.3')
        B('')
        B('[node name="MeshInstance3D" type="MeshInstance3D" parent="Box3DWorld/Pins/Pin_%d"]' % n)
        B('mesh = SubResource("PinMesh")')
        B('material_override = SubResource("PinMat")')
        B('')
        n += 1

# The ball (heavy sphere) at the near end; bowling.gd rolls it on load.
B('[node name="Ball" type="Box3DBody" parent="Box3DWorld"]')
B('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0.5, 8)')
B('shape_type = 1')
B('sphere_radius = 0.5')
B('density = 6.0')
B('friction = 0.2')
B('continuous = true')
B('')
B('[node name="MeshInstance3D" type="MeshInstance3D" parent="Box3DWorld/Ball"]')
B('mesh = SubResource("BallMesh")')
B('material_override = SubResource("BallMat")')
B('')

header = '[gd_scene load_steps=%d format=3]' % (len(subres) + 2)
ext = '[ext_resource type="Script" path="res://samples/bowling.gd" id="1_bowl"]'
out = header + '\n\n' + ext + '\n\n' + '\n\n'.join(subres) + '\n\n' + '\n'.join(nodes) + '\n'

_out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "samples", "bowling.tscn")
with open(_out, "w", encoding="utf-8") as f:
    f.write(out)
print("wrote samples/bowling.tscn with %d pins" % n)
