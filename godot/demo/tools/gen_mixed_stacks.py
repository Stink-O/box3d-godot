import os
import random

# Emits samples/mixed_stacks.tscn: several columns, each a stack of mixed shape
# types (box / sphere / capsule / cylinder), so you can watch different colliders
# settle against each other. World-only (the shell owns camera / lights / UI).

random.seed(7)

# shape_type: 0 box, 1 sphere, 2 capsule, 3 cylinder
SHAPES = [0, 1, 2, 3]
COLS = 5              # number of columns
PER_COL = 6          # shapes stacked per column
COL_SPACING = 3.0    # distance between columns along X

lines = []
A = lines.append

# Count sub-resources up front for load_steps: floor mesh+mat (2) + per-shape
# mesh+mat pairs. We build node text first, tracking sub-resources.
subres = []


def add_sub(text):
    subres.append(text)


add_sub('[sub_resource type="BoxMesh" id="FloorMesh"]\nsize = Vector3(40, 1, 40)')
add_sub('[sub_resource type="StandardMaterial3D" id="FloorMat"]\n'
        'albedo_color = Color(0.2, 0.22, 0.26, 1)\nroughness = 0.55\nmetallic = 0.1')

# Shared meshes per shape type.
add_sub('[sub_resource type="BoxMesh" id="M0"]\nsize = Vector3(1.1, 1.1, 1.1)')
add_sub('[sub_resource type="SphereMesh" id="M1"]\nradius = 0.6\nheight = 1.2')
add_sub('[sub_resource type="CapsuleMesh" id="M2"]\nradius = 0.45\nheight = 1.5')
add_sub('[sub_resource type="CylinderMesh" id="M3"]\ntop_radius = 0.6\nbottom_radius = 0.6\nheight = 1.1')

# A distinct colour per shape type.
COLORS = {
    0: "Color(0.86, 0.4, 0.3, 1)",
    1: "Color(0.35, 0.6, 0.88, 1)",
    2: "Color(0.55, 0.8, 0.4, 1)",
    3: "Color(0.85, 0.7, 0.3, 1)",
}
for t, c in COLORS.items():
    add_sub('[sub_resource type="StandardMaterial3D" id="C%d"]\nalbedo_color = %s\nroughness = 0.4' % (t, c))

nodes = []
B = nodes.append

B('[node name="MixedStacks" type="Node3D"]')
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
B('[node name="Stacks" type="Node3D" parent="Box3DWorld"]')
B('')

# Per-shape params passed to Box3DBody.
PARAMS = {
    0: 'box_size = Vector3(1.1, 1.1, 1.1)',
    1: 'shape_type = 1\nsphere_radius = 0.6',
    2: 'shape_type = 2\ncapsule_radius = 0.45\ncapsule_height = 1.5',
    3: 'shape_type = 3\ncapsule_radius = 0.6\ncapsule_height = 1.1',
}

n = 0
for col in range(COLS):
    x = (col - (COLS - 1) / 2.0) * COL_SPACING
    y = 1.0
    for row in range(PER_COL):
        t = random.choice(SHAPES)
        # Stack heights: leave a little gap so nothing starts interpenetrating.
        B('[node name="S_%d" type="Box3DBody" parent="Box3DWorld/Stacks"]' % n)
        B('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, %.4g, %.4g, 0)' % (x, y))
        B(PARAMS[t])
        B('friction = 0.6')
        B('')
        B('[node name="MeshInstance3D" type="MeshInstance3D" parent="Box3DWorld/Stacks/S_%d"]' % n)
        B('mesh = SubResource("M%d")' % t)
        B('material_override = SubResource("C%d")' % t)
        B('')
        y += 1.5
        n += 1

# load_steps = number of [sub_resource]/[ext_resource] blocks + 1.
header = '[gd_scene load_steps=%d format=3]' % (len(subres) + 1)
out = header + '\n\n' + '\n\n'.join(subres) + '\n\n' + '\n'.join(nodes) + '\n'

_out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "samples", "mixed_stacks.tscn")
os.makedirs(os.path.dirname(_out), exist_ok=True)
with open(_out, "w", encoding="utf-8") as f:
    f.write(out)
print("wrote samples/mixed_stacks.tscn with %d shapes across %d columns" % (n, COLS))
