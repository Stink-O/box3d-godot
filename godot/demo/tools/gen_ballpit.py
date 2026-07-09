import os

# Emits samples/ball_pit.tscn: an open-top container filled with a colourful pile
# of balls. They settle on load; shoot into them (F), grab and fling them, or
# Reset. World-only — just a lot of spheres in a box. Robust.

NX, NZ, NY = 9, 9, 3     # ball grid
SPACING = 0.9
R = 0.42
HALF = 4.6               # pit interior half-size
WALL_H = 4.0

subres = []
nodes = []
S = subres.append
B = nodes.append

S('[sub_resource type="StandardMaterial3D" id="FloorMat"]\n'
  'albedo_color = Color(0.2, 0.22, 0.26, 1)\nroughness = 0.55\nmetallic = 0.1')
S('[sub_resource type="StandardMaterial3D" id="WallMat"]\n'
  'albedo_color = Color(0.3, 0.32, 0.38, 1)\nroughness = 0.5\nmetallic = 0.2')
S('[sub_resource type="SphereMesh" id="BallMesh"]\nradius = %g\nheight = %g' % (R, 2 * R))

PALETTE = [
    "Color(0.9, 0.3, 0.25, 1)", "Color(0.95, 0.7, 0.2, 1)", "Color(0.3, 0.75, 0.4, 1)",
    "Color(0.25, 0.55, 0.9, 1)", "Color(0.6, 0.35, 0.8, 1)", "Color(0.95, 0.55, 0.75, 1)",
]
for i, col in enumerate(PALETTE):
    S('[sub_resource type="StandardMaterial3D" id="Ball%d"]\nalbedo_color = %s\nroughness = 0.3\nmetallic = 0.05' % (i, col))


def fit_box(name, size, pos, mat):
    mid = "M_" + name
    S('[sub_resource type="BoxMesh" id="%s"]\nsize = Vector3(%g, %g, %g)' % (mid, size[0], size[1], size[2]))
    B('[node name="%s" type="Box3DBody" parent="Box3DWorld"]' % name)
    B('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, %g, %g, %g)' % pos)
    B('body_type = 0')
    B('shape_type = 7')
    B('friction = 0.4')
    B('')
    B('[node name="MeshInstance3D" type="MeshInstance3D" parent="Box3DWorld/%s"]' % name)
    B('mesh = SubResource("%s")' % mid)
    B('material_override = SubResource("%s")' % mat)
    B('')


B('[node name="BallPit" type="Node3D"]')
B('')
B('[node name="Box3DWorld" type="Box3DWorld" parent="."]')
B('gravity = Vector3(0, -9.8, 0)')
B('')

# Container: floor + four walls.
fit_box("Floor", (2 * HALF + 1.2, 1, 2 * HALF + 1.2), (0, -0.5, 0), "FloorMat")
fit_box("WallN", (2 * HALF + 1.2, WALL_H, 0.5), (0, WALL_H / 2, -HALF - 0.25), "WallMat")
fit_box("WallS", (2 * HALF + 1.2, WALL_H, 0.5), (0, WALL_H / 2, HALF + 0.25), "WallMat")
fit_box("WallE", (0.5, WALL_H, 2 * HALF), (HALF + 0.25, WALL_H / 2, 0), "WallMat")
fit_box("WallW", (0.5, WALL_H, 2 * HALF), (-HALF - 0.25, WALL_H / 2, 0), "WallMat")

# The pile of balls.
B('[node name="Balls" type="Node3D" parent="Box3DWorld"]')
B('')
n = 0
x0 = -(NX - 1) * SPACING / 2.0
z0 = -(NZ - 1) * SPACING / 2.0
for j in range(NY):
    for i in range(NX):
        for k in range(NZ):
            x = x0 + i * SPACING + (0.12 if j % 2 else -0.12)
            z = z0 + k * SPACING
            y = 0.55 + j * SPACING
            B('[node name="Ball_%d" type="Box3DBody" parent="Box3DWorld/Balls"]' % n)
            B('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, %.4g, %.4g, %.4g)' % (x, y, z))
            B('shape_type = 1')
            B('sphere_radius = %g' % R)
            B('restitution = 0.25')
            B('friction = 0.35')
            B('')
            B('[node name="MeshInstance3D" type="MeshInstance3D" parent="Box3DWorld/Balls/Ball_%d"]' % n)
            B('mesh = SubResource("BallMesh")')
            B('material_override = SubResource("Ball%d")' % (n % len(PALETTE)))
            B('')
            n += 1

header = '[gd_scene load_steps=%d format=3]' % (len(subres) + 1)
out = header + '\n\n' + '\n\n'.join(subres) + '\n\n' + '\n'.join(nodes) + '\n'

_out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "samples", "ball_pit.tscn")
with open(_out, "w", encoding="utf-8") as f:
    f.write(out)
print("wrote samples/ball_pit.tscn with %d balls" % n)
