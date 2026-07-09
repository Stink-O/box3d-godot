import os

# Emits samples/cube_pile.tscn: a world-only sample (no camera / lights / UI —
# the sample browser shell owns those). Root Node3D with a Box3DWorld child.

lines = []
A = lines.append

A('[gd_scene load_steps=4 format=3]')
A('')
A('[ext_resource type="PackedScene" path="res://common/cube.tscn" id="1_cube"]')
A('')
A('[sub_resource type="BoxMesh" id="FloorMesh_1"]')
A('size = Vector3(40, 1, 40)')
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
A('')
# shape_type 7 = Fit Mesh: the box collider is auto-sized from the child
# MeshInstance3D's FloorMesh, so resizing the floor mesh is all it takes.
A('[node name="Floor" type="Box3DBody" parent="Box3DWorld"]')
A('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, -0.5, 0)')
A('body_type = 0')
A('shape_type = 7')
A('')
A('[node name="MeshInstance3D" type="MeshInstance3D" parent="Box3DWorld/Floor"]')
A('mesh = SubResource("FloorMesh_1")')
A('material_override = SubResource("FloorMat_1")')
A('')
A('[node name="CubeStack" type="Node3D" parent="Box3DWorld"]')
A('')

N = 6
spacing = 1.02
n = 0
for j in range(N):          # layers (y)
    for i in range(N):      # x
        for k in range(N):  # z
            x = (i - (N - 1) / 2.0) * spacing
            z = (k - (N - 1) / 2.0) * spacing
            y = 0.55 + j * spacing
            A('[node name="Cube_%d" parent="Box3DWorld/CubeStack" instance=ExtResource("1_cube")]' % n)
            A('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, %.4g, %.4g, %.4g)' % (x, y, z))
            A('')
            n += 1

out = "\n".join(lines) + "\n"
_out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "samples", "cube_pile.tscn")
os.makedirs(os.path.dirname(_out), exist_ok=True)
with open(_out, "w", encoding="utf-8") as f:
    f.write(out)
print("wrote samples/cube_pile.tscn with %d cubes" % n)
