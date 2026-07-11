import os

# Emits samples/large_pyramid.tscn: Erin's CreateLargePyramid benchmark from
# shared/benchmarks.c — a flat brick-wall pyramid of 1 m cubes, BASE wide at
# the bottom and one cube deep (BASE*(BASE+1)/2 bodies). Positions match the
# original exactly (cubes touching, each row offset half a cube). Sleeping is
# disabled on the world, as in the benchmark, so the solver never idles.
# World-only (the sample browser shell owns camera / lights / UI).

BASE = 100        # cubes on the bottom row -> BASE*(BASE+1)/2 total (5050)
H = 0.5           # half extent of a cube; shift in the original == H

lines = []
A = lines.append

A('[gd_scene load_steps=4 format=3]')
A('')
A('[ext_resource type="PackedScene" path="res://common/cube.tscn" id="1_cube"]')
A('')
A('[sub_resource type="BoxMesh" id="FloorMesh_1"]')
A('size = Vector3(240, 1, 240)')
A('')
A('[sub_resource type="StandardMaterial3D" id="FloorMat_1"]')
A('albedo_color = Color(0.2, 0.22, 0.26, 1)')
A('roughness = 0.55')
A('metallic = 0.1')
A('')
A('[node name="LargePyramid" type="Node3D"]')
A('')
# Hand-editable spawn view: the shell spawns the fly camera here, facing the
# node's -Z. A Camera3D (never current at runtime — the shell's camera owns
# the viewport) so the editor offers Preview and Align Transform with View.
# Identity basis at +Z already faces the pyramid.
A('[node name="CameraStart" type="Camera3D" parent="."]')
A('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 55, 115)')
A('')
A('[node name="Box3DWorld" type="Box3DWorld" parent="."]')
A('gravity = Vector3(0, -9.8, 0)')
A('worker_count = 4')
A('enable_sleep = false')
A('')
A('[node name="Floor" type="Box3DBody" parent="Box3DWorld"]')
A('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, -0.5, 0)')
A('body_type = 0')
A('box_size = Vector3(240, 1, 240)')
A('')
A('[node name="MeshInstance3D" type="MeshInstance3D" parent="Box3DWorld/Floor"]')
A('mesh = SubResource("FloorMesh_1")')
A('material_override = SubResource("FloorMat_1")')
A('')
A('[node name="Blocks" type="Node3D" parent="Box3DWorld"]')
A('')

n = 0
for i in range(BASE):                      # rows, bottom to top
    y = (2.0 * i + 1.0) * H
    for j in range(i, BASE):
        x = (i + 1.0) * H + 2.0 * (j - i) * H - H * BASE
        A('[node name="Cube_%d" parent="Box3DWorld/Blocks" instance=ExtResource("1_cube")]' % n)
        A('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, %g, %g, 0)' % (x, y))
        A('')
        n += 1

out = "\n".join(lines)
_out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "samples", "large_pyramid.tscn")
with open(_out, "w", newline="\n", encoding="utf-8") as f:
    f.write(out)
print("wrote samples/large_pyramid.tscn with %d cubes (%d wide)" % (n, BASE))
