import os

# Emits samples/pool.tscn: a pool table with cushion rails, a 15-ball triangle
# rack, and a cue ball. pool.gd shoots the cue into the rack on load. Balls roll
# on the table and bounce off the bouncy cushions.

R = 0.35
HALF_W = 6.5     # table half width (x)
HALF_L = 13.0    # table half length (z)
CUSHION_H = 0.7
APEX_Z = -5.0    # apex of the rack (nearest the cue)

subres = []
nodes = []
S = subres.append
B = nodes.append

S('[sub_resource type="StandardMaterial3D" id="FeltMat"]\n'
  'albedo_color = Color(0.1, 0.4, 0.22, 1)\nroughness = 0.7')
S('[sub_resource type="BoxMesh" id="FeltMesh"]\nsize = Vector3(%g, 1, %g)' % (2 * HALF_W, 2 * HALF_L))
S('[sub_resource type="StandardMaterial3D" id="RailMat"]\n'
  'albedo_color = Color(0.4, 0.26, 0.15, 1)\nroughness = 0.5')
S('[sub_resource type="SphereMesh" id="BallMesh"]\nradius = %g\nheight = %g' % (R, 2 * R))
S('[sub_resource type="StandardMaterial3D" id="CueMat"]\n'
  'albedo_color = Color(0.95, 0.95, 0.95, 1)\nroughness = 0.2')

# A handful of distinct rack-ball colours.
COLORS = [
    "Color(0.9, 0.75, 0.1, 1)", "Color(0.1, 0.2, 0.7, 1)", "Color(0.8, 0.15, 0.1, 1)",
    "Color(0.45, 0.1, 0.5, 1)", "Color(0.9, 0.45, 0.1, 1)", "Color(0.1, 0.45, 0.2, 1)",
    "Color(0.5, 0.1, 0.15, 1)", "Color(0.1, 0.1, 0.12, 1)",
]
for i, col in enumerate(COLORS):
    S('[sub_resource type="StandardMaterial3D" id="Ball%d"]\nalbedo_color = %s\nroughness = 0.25\nmetallic = 0.1' % (i, col))


def fit_box(name, size, pos, mat):
    mid = "M_" + name
    S('[sub_resource type="BoxMesh" id="%s"]\nsize = Vector3(%g, %g, %g)' % (mid, size[0], size[1], size[2]))
    B('[node name="%s" type="Box3DBody" parent="Box3DWorld"]' % name)
    B('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, %g, %g, %g)' % pos)
    B('body_type = 0')
    B('shape_type = 7')
    B('restitution = 0.85')
    B('friction = 0.2')
    B('')
    B('[node name="MeshInstance3D" type="MeshInstance3D" parent="Box3DWorld/%s"]' % name)
    B('mesh = SubResource("%s")' % mid)
    B('material_override = SubResource("%s")' % mat)
    B('')


def ball(name, x, z, mat):
    B('[node name="%s" type="Box3DBody" parent="Box3DWorld"]' % name)
    B('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, %.4g, %g, %.4g)' % (x, R, z))
    B('shape_type = 1')
    B('sphere_radius = %g' % R)
    B('restitution = 0.92')
    B('friction = 0.08')
    B('linear_damping = 0.22')
    B('angular_damping = 0.22')
    B('continuous = true')
    B('')
    B('[node name="MeshInstance3D" type="MeshInstance3D" parent="Box3DWorld/%s"]' % name)
    B('mesh = SubResource("BallMesh")')
    B('material_override = SubResource("%s")' % mat)
    B('')


B('[node name="Pool" type="Node3D"]')
B('script = ExtResource("1_pool")')
B('')
B('[node name="Box3DWorld" type="Box3DWorld" parent="."]')
B('gravity = Vector3(0, -9.8, 0)')
B('')

# Felt bed (Fit-Mesh) + cushion rails.
B('[node name="Table" type="Box3DBody" parent="Box3DWorld"]')
B('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, -0.5, 0)')
B('body_type = 0')
B('shape_type = 7')
B('friction = 0.25')
B('')
B('[node name="MeshInstance3D" type="MeshInstance3D" parent="Box3DWorld/Table"]')
B('mesh = SubResource("FeltMesh")')
B('material_override = SubResource("FeltMat")')
B('')
fit_box("RailN", (2 * HALF_W + 1.0, CUSHION_H, 0.5), (0, CUSHION_H / 2, -HALF_L), "RailMat")
fit_box("RailS", (2 * HALF_W + 1.0, CUSHION_H, 0.5), (0, CUSHION_H / 2, HALF_L), "RailMat")
fit_box("RailE", (0.5, CUSHION_H, 2 * HALF_L), (HALF_W, CUSHION_H / 2, 0), "RailMat")
fit_box("RailW", (0.5, CUSHION_H, 2 * HALF_L), (-HALF_W, CUSHION_H / 2, 0), "RailMat")

# 15-ball triangle rack (apex toward the cue at +Z).
row_dz = 2 * R * 0.87       # tight triangle row spacing
col_dx = 2 * R + 0.01
n = 0
for r in range(5):
    z = APEX_Z - r * row_dz
    for i in range(r + 1):
        x = (i - r / 2.0) * col_dx
        ball("Rack_%d" % n, x, z, "Ball%d" % (n % len(COLORS)))
        n += 1

# Cue ball at the far end; pool.gd shoots it toward the rack on load.
B('[node name="Cue" type="Box3DBody" parent="Box3DWorld"]')
B('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, %g, 8)' % R)
B('shape_type = 1')
B('sphere_radius = %g' % R)
B('restitution = 0.92')
B('friction = 0.08')
B('linear_damping = 0.3')
B('angular_damping = 0.3')
B('continuous = true')
B('')
B('[node name="MeshInstance3D" type="MeshInstance3D" parent="Box3DWorld/Cue"]')
B('mesh = SubResource("BallMesh")')
B('material_override = SubResource("CueMat")')
B('')

header = '[gd_scene load_steps=%d format=3]' % (len(subres) + 2)
ext = '[ext_resource type="Script" path="res://samples/pool.gd" id="1_pool"]'
out = header + '\n\n' + ext + '\n\n' + '\n\n'.join(subres) + '\n\n' + '\n'.join(nodes) + '\n'

_out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "samples", "pool.tscn")
with open(_out, "w", encoding="utf-8") as f:
    f.write(out)
print("wrote samples/pool.tscn with %d racked balls" % n)
