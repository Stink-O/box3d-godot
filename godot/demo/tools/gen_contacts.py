import os

# Emits samples/contacts.tscn: a walled pit with a staggered grid of standing
# pegs (each contact_monitor = true) and a few balls dropped in. contacts.gd
# flashes a peg on body_entered, so ricochets light up the field. Shoot more
# balls with F.

ROWS = 8
COLS = 8
SPACING = 1.25   # gap (~0.75) is barely over a ball's diameter, so balls clatter
PEG_R = 0.25
PEG_H = 1.6

subres = []
nodes = []
S = subres.append
B = nodes.append

S('[sub_resource type="StandardMaterial3D" id="FloorMat"]\n'
  'albedo_color = Color(0.2, 0.22, 0.26, 1)\nroughness = 0.55\nmetallic = 0.1')
S('[sub_resource type="StandardMaterial3D" id="WallMat"]\n'
  'albedo_color = Color(0.32, 0.34, 0.4, 1)\nroughness = 0.7')
S('[sub_resource type="CylinderMesh" id="PegMesh"]\n'
  'top_radius = %g\nbottom_radius = %g\nheight = %g' % (PEG_R, PEG_R, PEG_H))
S('[sub_resource type="StandardMaterial3D" id="PegMat"]\n'
  'albedo_color = Color(0.55, 0.6, 0.7, 1)\nroughness = 0.4\nmetallic = 0.2')
S('[sub_resource type="SphereMesh" id="BallMesh"]\nradius = 0.35\nheight = 0.7')
S('[sub_resource type="StandardMaterial3D" id="BallMat"]\n'
  'albedo_color = Color(0.87, 0.35, 0.2, 1)\nroughness = 0.35')


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


B('[node name="Contacts" type="Node3D"]')
B('script = ExtResource("1_con")')
B('')
B('[node name="Box3DWorld" type="Box3DWorld" parent="."]')
B('gravity = Vector3(0, -9.8, 0)')
B('')

fit_box("Floor", (20, 1, 20), (0, -0.5, 0), "FloorMat")

# Perimeter walls to keep balls in the pit.
half = 7.0
fit_box("WallN", (2 * half + 0.5, 2, 0.5), (0, 1, -half), "WallMat")
fit_box("WallS", (2 * half + 0.5, 2, 0.5), (0, 1, half), "WallMat")
fit_box("WallE", (0.5, 2, 2 * half), (half, 1, 0), "WallMat")
fit_box("WallW", (0.5, 2, 2 * half), (-half, 1, 0), "WallMat")

# Staggered peg grid, each a contact-monitored cylinder.
B('[node name="Pegs" type="Node3D" parent="Box3DWorld"]')
B('')
n = 0
for r in range(ROWS):
    z = (r - (ROWS - 1) / 2.0) * SPACING
    offset = (SPACING / 2.0) if (r % 2) else 0.0
    for cc in range(COLS):
        x = (cc - (COLS - 1) / 2.0) * SPACING + offset
        if abs(x) > half - 1.0:
            continue
        B('[node name="Peg_%d" type="Box3DBody" parent="Box3DWorld/Pegs"]' % n)
        B('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, %.4g, %g, %.4g)' % (x, PEG_H / 2.0, z))
        B('body_type = 0')
        B('shape_type = 3')  # cylinder
        B('capsule_radius = %g' % PEG_R)
        B('capsule_height = %g' % PEG_H)
        B('restitution = 0.55')
        B('contact_monitor = true')
        B('')
        B('[node name="MeshInstance3D" type="MeshInstance3D" parent="Box3DWorld/Pegs/Peg_%d"]' % n)
        B('mesh = SubResource("PegMesh")')
        B('material_override = SubResource("PegMat")')
        B('')
        n += 1

# A handful of balls dropped in at scattered spots.
B('[node name="Balls" type="Node3D" parent="Box3DWorld"]')
B('')
drops = [
	(-2.5, 9, -2.0), (2.0, 10, 1.5), (-1.0, 11, 3.0), (3.0, 12, -3.0),
	(0.5, 9.5, -0.5), (-2.0, 13, 2.0), (1.2, 14, -1.2), (-3.0, 10.5, 0.8),
	(2.6, 13.5, 2.6), (-0.6, 12.5, -2.8),
]
for i, (x, y, z) in enumerate(drops):
    B('[node name="Ball_%d" type="Box3DBody" parent="Box3DWorld/Balls"]' % i)
    B('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, %g, %g, %g)' % (x, y, z))
    B('shape_type = 1')
    B('sphere_radius = 0.35')
    B('restitution = 0.65')
    B('density = 2.0')
    B('')
    B('[node name="MeshInstance3D" type="MeshInstance3D" parent="Box3DWorld/Balls/Ball_%d"]' % i)
    B('mesh = SubResource("BallMesh")')
    B('material_override = SubResource("BallMat")')
    B('')

header = '[gd_scene load_steps=%d format=3]' % (len(subres) + 2)
ext = '[ext_resource type="Script" path="res://samples/contacts.gd" id="1_con"]'
out = header + '\n\n' + ext + '\n\n' + '\n\n'.join(subres) + '\n\n' + '\n'.join(nodes) + '\n'

_out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "samples", "contacts.tscn")
with open(_out, "w", encoding="utf-8") as f:
    f.write(out)
print("wrote samples/contacts.tscn with %d pegs + %d balls" % (n, len(drops)))
