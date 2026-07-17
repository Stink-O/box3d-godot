import os

# Emits samples/cube_pile.tscn: one big N x N x N cube assembled from unit
# cubes (common/cube.tscn, which tints itself at runtime). It stands as a
# giant block until you shoot it (F) or drag cubes out; Reset re-stacks.
# Bump N for a bigger cube — cube count grows as N^3.

N = 16           # cubes per side -> N^3 total
SPACING = 1.02   # centre spacing, a hair over the 1 m cube for clearance
BASE_Y = 0.55    # bottom layer centre height above the floor

lines = []
A = lines.append

A('[gd_scene load_steps=5 format=3]')
A('')
A('[ext_resource type="PackedScene" path="res://common/cube.tscn" id="1_cube"]')
A('[ext_resource type="Script" path="res://common/cube_grid_multimesh.gd" id="2_mm"]')
A('')
A('[sub_resource type="BoxMesh" id="FloorMesh_1"]')
A('size = Vector3(120, 1, 120)')
A('')
A('[sub_resource type="StandardMaterial3D" id="FloorMat_1"]')
A('albedo_color = Color(0.2, 0.22, 0.26, 1)')
A('roughness = 0.55')
A('metallic = 0.1')
A('')
A('[node name="CubePile" type="Node3D"]')
A('')
A('[node name="Box3DWorld" type="Box3DWorld" parent="."]')
A('gravity = Vector3(0, -9.8, 0)')
A('worker_count = 4')
A('')
A('[node name="Floor" type="Box3DBody" parent="Box3DWorld"]')
A('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, -0.5, 0)')
A('body_type = 0')
A('shape_type = 7')
A('')
A('[node name="MeshInstance3D" type="MeshInstance3D" parent="Box3DWorld/Floor"]')
A('mesh = SubResource("FloorMesh_1")')
A('material_override = SubResource("FloorMat_1")')
A('')
# One MultiMesh draws the whole grid (4096 draw calls -> 1); see the script.
A('[node name="CubeGrid" type="Node3D" parent="Box3DWorld"]')
A('script = ExtResource("2_mm")')
A('')

half = (N - 1) * SPACING / 2.0
i = 0
for y in range(N):
    for x in range(N):
        for z in range(N):
            px = x * SPACING - half
            py = BASE_Y + y * SPACING
            pz = z * SPACING - half
            A('[node name="Cube_%d" parent="Box3DWorld/CubeGrid" instance=ExtResource("1_cube")]' % i)
            A('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, %g, %g, %g)' % (px, py, pz))
            A('')
            i += 1

out = os.path.join(os.path.dirname(__file__), '..', 'samples', 'cube_pile.tscn')
with open(out, 'w', newline='\n') as f:
    f.write('\n'.join(lines))
print('wrote %s: %d cubes (%dx%dx%d)' % (os.path.normpath(out), i, N, N, N))
