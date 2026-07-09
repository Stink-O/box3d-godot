import os

# Emits samples/fountain.tscn: a central spout in a walled basin. fountain.gd
# sprays balls up; they arc over and rain back into the basin. World structure
# is just floor + walls + a decorative spout.

HALF = 7.0
WALL_H = 2.0

subres = []
nodes = []
S = subres.append
B = nodes.append

S('[sub_resource type="StandardMaterial3D" id="FloorMat"]\n'
  'albedo_color = Color(0.18, 0.24, 0.3, 1)\nroughness = 0.4\nmetallic = 0.2')
S('[sub_resource type="BoxMesh" id="FloorMesh"]\nsize = Vector3(%g, 1, %g)' % (2 * HALF, 2 * HALF))
S('[sub_resource type="StandardMaterial3D" id="WallMat"]\n'
  'albedo_color = Color(0.3, 0.34, 0.4, 1)\nroughness = 0.5')
S('[sub_resource type="CylinderMesh" id="SpoutMesh"]\n'
  'top_radius = 0.5\nbottom_radius = 0.8\nheight = 3.0')
S('[sub_resource type="StandardMaterial3D" id="SpoutMat"]\n'
  'albedo_color = Color(0.4, 0.44, 0.5, 1)\nroughness = 0.5\nmetallic = 0.4')


def fit_box(name, size, pos, mat):
    mid = "M_" + name
    S('[sub_resource type="BoxMesh" id="%s"]\nsize = Vector3(%g, %g, %g)' % (mid, size[0], size[1], size[2]))
    B('[node name="%s" type="Box3DBody" parent="Box3DWorld"]' % name)
    B('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, %g, %g, %g)' % pos)
    B('body_type = 0')
    B('shape_type = 7')
    B('friction = 0.3')
    B('')
    B('[node name="MeshInstance3D" type="MeshInstance3D" parent="Box3DWorld/%s"]' % name)
    B('mesh = SubResource("%s")' % mid)
    B('material_override = SubResource("%s")' % mat)
    B('')


B('[node name="Fountain" type="Node3D"]')
B('script = ExtResource("1_fount")')
B('')
B('[node name="Box3DWorld" type="Box3DWorld" parent="."]')
B('gravity = Vector3(0, -9.8, 0)')
B('')
fit_box("Floor", (2 * HALF, 1, 2 * HALF), (0, -0.5, 0), "FloorMat")
fit_box("WallN", (2 * HALF + 0.8, WALL_H, 0.5), (0, WALL_H / 2, -HALF), "WallMat")
fit_box("WallS", (2 * HALF + 0.8, WALL_H, 0.5), (0, WALL_H / 2, HALF), "WallMat")
fit_box("WallE", (0.5, WALL_H, 2 * HALF), (HALF, WALL_H / 2, 0), "WallMat")
fit_box("WallW", (0.5, WALL_H, 2 * HALF), (-HALF, WALL_H / 2, 0), "WallMat")

# Decorative spout at the centre (visual only).
B('[node name="Spout" type="MeshInstance3D" parent="Box3DWorld"]')
B('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 1.5, 0)')
B('mesh = SubResource("SpoutMesh")')
B('material_override = SubResource("SpoutMat")')
B('')

header = '[gd_scene load_steps=%d format=3]' % (len(subres) + 2)
ext = '[ext_resource type="Script" path="res://samples/fountain.gd" id="1_fount"]'
out = header + '\n\n' + ext + '\n\n' + '\n\n'.join(subres) + '\n\n' + '\n'.join(nodes) + '\n'

_out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "samples", "fountain.tscn")
with open(_out, "w", encoding="utf-8") as f:
    f.write(out)
print("wrote samples/fountain.tscn")
