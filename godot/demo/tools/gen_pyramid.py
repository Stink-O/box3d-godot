import os

# Emits samples/pyramid.tscn: a stepped square pyramid of unit cubes — a
# classic stacking-stability stress test. World-only (the sample browser shell
# owns the camera / lights / UI). Reuses cube.tscn for each box.

BASE = 7          # cubes per side on the bottom layer
SPACING = 1.02    # >1 so cubes start with a hair of clearance

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
A('[node name="Pyramid" type="Node3D"]')
A('')
A('[node name="Box3DWorld" type="Box3DWorld" parent="."]')
A('gravity = Vector3(0, -9.8, 0)')
A('')
A('[node name="Floor" type="Box3DBody" parent="Box3DWorld"]')
A('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, -0.5, 0)')
A('body_type = 0')
A('box_size = Vector3(40, 1, 40)')
A('')
A('[node name="MeshInstance3D" type="MeshInstance3D" parent="Box3DWorld/Floor"]')
A('mesh = SubResource("FloorMesh_1")')
A('material_override = SubResource("FloorMat_1")')
A('')
A('[node name="Blocks" type="Node3D" parent="Box3DWorld"]')
A('')

n = 0
for j in range(BASE):            # layers, bottom to top
    side = BASE - j              # cubes per side this layer
    for i in range(side):
        for k in range(side):
            x = (i - (side - 1) / 2.0) * SPACING
            z = (k - (side - 1) / 2.0) * SPACING
            y = 0.55 + j * SPACING
            A('[node name="Cube_%d" parent="Box3DWorld/Blocks" instance=ExtResource("1_cube")]' % n)
            A('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, %.4g, %.4g, %.4g)' % (x, y, z))
            A('')
            n += 1

out = "\n".join(lines) + "\n"
_out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "samples", "pyramid.tscn")
os.makedirs(os.path.dirname(_out), exist_ok=True)
with open(_out, "w", encoding="utf-8") as f:
    f.write(out)
print("wrote samples/pyramid.tscn with %d cubes" % n)
