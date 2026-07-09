import os

# Emits samples/explosion.tscn: a stacked block "building" over a bomb marker.
# explosion.gd blows it up on X (Box3DWorld.explode). Reuses common/cube.tscn.

W, H, D = 5, 6, 5      # blocks: width x height x depth
SPACING = 1.02

lines = []
A = lines.append

A('[gd_scene load_steps=6 format=3]')
A('')
A('[ext_resource type="Script" path="res://samples/explosion.gd" id="1_expl"]')
A('[ext_resource type="PackedScene" path="res://common/cube.tscn" id="2_cube"]')
A('')
A('[sub_resource type="BoxMesh" id="FloorMesh"]')
A('size = Vector3(40, 1, 40)')
A('')
A('[sub_resource type="StandardMaterial3D" id="FloorMat"]')
A('albedo_color = Color(0.2, 0.22, 0.26, 1)')
A('roughness = 0.55')
A('metallic = 0.1')
A('')
A('[sub_resource type="SphereMesh" id="BombMesh"]')
A('radius = 0.6')
A('height = 1.2')
A('')
A('[sub_resource type="StandardMaterial3D" id="BombMat"]')
A('albedo_color = Color(0.9, 0.15, 0.1, 1)')
A('emission_enabled = true')
A('emission = Color(0.9, 0.15, 0.1, 1)')
A('emission_energy_multiplier = 2.5')
A('')
A('[node name="Explosion" type="Node3D"]')
A('script = ExtResource("1_expl")')
A('')
A('[node name="Box3DWorld" type="Box3DWorld" parent="."]')
A('gravity = Vector3(0, -9.8, 0)')
A('')
A('[node name="Floor" type="Box3DBody" parent="Box3DWorld"]')
A('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, -0.5, 0)')
A('body_type = 0')
A('shape_type = 7')
A('')
A('[node name="MeshInstance3D" type="MeshInstance3D" parent="Box3DWorld/Floor"]')
A('mesh = SubResource("FloorMesh")')
A('material_override = SubResource("FloorMat")')
A('')
# Bomb marker sits at the blast centre (0, 1, 0) — pulses via the script.
A('[node name="Bomb" type="MeshInstance3D" parent="Box3DWorld"]')
A('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 0)')
A('mesh = SubResource("BombMesh")')
A('material_override = SubResource("BombMat")')
A('')
A('[node name="Blocks" type="Node3D" parent="Box3DWorld"]')
A('')

n = 0
for j in range(H):            # up
    for i in range(W):        # x
        for k in range(D):    # z
            x = (i - (W - 1) / 2.0) * SPACING
            z = (k - (D - 1) / 2.0) * SPACING
            y = 0.55 + j * SPACING
            A('[node name="B_%d" parent="Box3DWorld/Blocks" instance=ExtResource("2_cube")]' % n)
            A('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, %.4g, %.4g, %.4g)' % (x, y, z))
            A('')
            n += 1

out = "\n".join(lines) + "\n"
_out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "samples", "explosion.tscn")
with open(_out, "w", encoding="utf-8") as f:
    f.write(out)
print("wrote samples/explosion.tscn with %d blocks" % n)
