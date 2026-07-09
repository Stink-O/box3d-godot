import os

# Emits samples/bridge.tscn: a plank walkway made of dynamic slabs linked by
# hinge joints, anchored to the world at both ends (between two static posts).
# A few boxes drop onto it to flex it. bridge.gd resets the load periodically.

N = 12            # number of planks
L = 1.4           # centre-to-centre plank spacing along X
PLANK_LEN = 1.26  # plank length along X (< L so ends don't jam)
THICK = 0.2       # plank thickness (Y)
WIDTH = 3.0       # walkway width (Z)
Y0 = 8.0          # bridge height
SPAN = N * L
HALF = SPAN / 2.0

subres = []
nodes = []


def S(text):
    subres.append(text)


def B(text):
    nodes.append(text)


S('[sub_resource type="BoxMesh" id="FloorMesh"]\nsize = Vector3(40, 1, 40)')
S('[sub_resource type="StandardMaterial3D" id="FloorMat"]\n'
  'albedo_color = Color(0.2, 0.22, 0.26, 1)\nroughness = 0.55\nmetallic = 0.1')
S('[sub_resource type="BoxMesh" id="PlankMesh"]\nsize = Vector3(%g, %g, %g)' % (PLANK_LEN, THICK, WIDTH))
S('[sub_resource type="StandardMaterial3D" id="PlankMat"]\n'
  'albedo_color = Color(0.72, 0.52, 0.3, 1)\nroughness = 0.6')
S('[sub_resource type="BoxMesh" id="PostMesh"]\nsize = Vector3(0.6, %g, 3.4)' % (Y0 + 0.6))
S('[sub_resource type="StandardMaterial3D" id="PostMat"]\n'
  'albedo_color = Color(0.42, 0.44, 0.48, 1)\nroughness = 0.85')
S('[sub_resource type="BoxMesh" id="LoadMesh"]\nsize = Vector3(1, 1, 1)')
S('[sub_resource type="StandardMaterial3D" id="LoadMat"]\n'
  'albedo_color = Color(0.86, 0.35, 0.3, 1)\nroughness = 0.4')

B('[node name="Bridge" type="Node3D"]')
B('')
B('[node name="Box3DWorld" type="Box3DWorld" parent="."]')
B('gravity = Vector3(0, -9.8, 0)')
B('')
B('[node name="Floor" type="Box3DBody" parent="Box3DWorld"]')
B('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, -0.5, 0)')
B('body_type = 0')
B('box_size = Vector3(40, 1, 40)')
B('')
B('[node name="MeshInstance3D" type="MeshInstance3D" parent="Box3DWorld/Floor"]')
B('mesh = SubResource("FloorMesh")')
B('material_override = SubResource("FloorMat")')
B('')

# Two decorative static posts just outside the plank span.
for side, sx in (("L", -(HALF + 0.5)), ("R", HALF + 0.5)):
    B('[node name="Post%s" type="Box3DBody" parent="Box3DWorld"]' % side)
    B('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, %.4g, %g, 0)' % (sx, (Y0 + 0.6) / 2.0 - 0.5))
    B('body_type = 0')
    B('box_size = Vector3(0.6, %g, 3.4)' % (Y0 + 0.6))
    B('')
    B('[node name="MeshInstance3D" type="MeshInstance3D" parent="Box3DWorld/Post%s"]' % side)
    B('mesh = SubResource("PostMesh")')
    B('material_override = SubResource("PostMat")')
    B('')

# Planks.
B('[node name="Planks" type="Node3D" parent="Box3DWorld"]')
B('')
for i in range(N):
    x = -HALF + L * (i + 0.5)
    B('[node name="Plank_%d" type="Box3DBody" parent="Box3DWorld/Planks"]' % i)
    B('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, %.4g, %g, 0)' % (x, Y0))
    B('box_size = Vector3(%g, %g, %g)' % (PLANK_LEN, THICK, WIDTH))
    B('density = 2.0')
    B('')
    B('[node name="MeshInstance3D" type="MeshInstance3D" parent="Box3DWorld/Planks/Plank_%d"]' % i)
    B('mesh = SubResource("PlankMesh")')
    B('material_override = SubResource("PlankMat")')
    B('')

# Hinge joints. Axis = joint frame local Z (unrotated => world Z), so the bridge
# bends vertically. Internal seams link plank i to i+1; the two ends anchor to
# the world (body_b left empty).
B('[node name="Joints" type="Node3D" parent="Box3DWorld"]')
B('')
# Left end anchor.
B('[node name="Anchor_L" type="Box3DHingeJoint" parent="Box3DWorld/Joints"]')
B('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, %.4g, %g, 0)' % (-HALF, Y0))
B('body_a = NodePath("../../Planks/Plank_0")')
B('')
# Internal seams.
for j in range(N - 1):
    x = -HALF + L * (j + 1)
    B('[node name="Seam_%d" type="Box3DHingeJoint" parent="Box3DWorld/Joints"]' % j)
    B('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, %.4g, %g, 0)' % (x, Y0))
    B('body_a = NodePath("../../Planks/Plank_%d")' % (j + 1))
    B('body_b = NodePath("../../Planks/Plank_%d")' % j)
    B('')
# Right end anchor.
B('[node name="Anchor_R" type="Box3DHingeJoint" parent="Box3DWorld/Joints"]')
B('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, %.4g, %g, 0)' % (HALF, Y0))
B('body_a = NodePath("../../Planks/Plank_%d")' % (N - 1))
B('')

# A few boxes that drop onto the middle to flex the span.
B('[node name="Loaders" type="Node3D" parent="Box3DWorld"]')
B('')
for k, lx in enumerate((-2.5, 0.0, 2.5)):
    B('[node name="Load_%d" type="Box3DBody" parent="Box3DWorld/Loaders"]' % k)
    B('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, %g, %g, 0)' % (lx, Y0 + 4.0))
    B('box_size = Vector3(1, 1, 1)')
    B('density = 3.0')
    B('')
    B('[node name="MeshInstance3D" type="MeshInstance3D" parent="Box3DWorld/Loaders/Load_%d"]' % k)
    B('mesh = SubResource("LoadMesh")')
    B('material_override = SubResource("LoadMat")')
    B('')

# sub_resources -> load_steps (no script; the bridge needs no runtime behaviour).
header = '[gd_scene load_steps=%d format=3]' % (len(subres) + 1)
out = header + '\n\n' + '\n\n'.join(subres) + '\n\n' + '\n'.join(nodes) + '\n'

_out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "samples", "bridge.tscn")
os.makedirs(os.path.dirname(_out), exist_ok=True)
with open(_out, "w", encoding="utf-8") as f:
    f.write(out)
print("wrote samples/bridge.tscn with %d planks + %d hinges" % (N, N + 1))
