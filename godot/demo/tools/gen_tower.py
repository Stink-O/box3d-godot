import os

# Emits samples/tower.tscn: a Jenga-style tumbling tower — layers of three
# blocks, each layer rotated 90 degrees from the one below. It stands stable;
# shoot it (F) or drag a block to topple it, Reset to re-stack. World-only.

LAYERS = 14
BLK_L = 1.5      # block long axis
BLK_H = 0.5
BLK_W = 0.5
LAYER_DY = 0.52  # a hair over BLK_H so blocks start with clearance
GAP = 0.51       # block centre spacing within a layer

lines = []
A = lines.append

A('[gd_scene load_steps=6 format=3]')
A('')
A('[sub_resource type="BoxMesh" id="FloorMesh"]')
A('size = Vector3(20, 1, 20)')
A('')
A('[sub_resource type="StandardMaterial3D" id="FloorMat"]')
A('albedo_color = Color(0.2, 0.22, 0.26, 1)')
A('roughness = 0.55')
A('metallic = 0.1')
A('')
A('[sub_resource type="BoxMesh" id="BlockMesh"]')
A('size = Vector3(%g, %g, %g)' % (BLK_L, BLK_H, BLK_W))
A('')
A('[sub_resource type="StandardMaterial3D" id="BlockMat"]')
A('albedo_color = Color(0.82, 0.62, 0.34, 1)')
A('roughness = 0.6')
A('')
A('[node name="Tower" type="Node3D"]')
A('')
A('[node name="Box3DWorld" type="Box3DWorld" parent="."]')
A('gravity = Vector3(0, -9.8, 0)')
A('substep_count = 8')
A('')
A('[node name="Floor" type="Box3DBody" parent="Box3DWorld"]')
A('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, -0.5, 0)')
A('body_type = 0')
A('shape_type = 7')
A('friction = 0.8')
A('')
A('[node name="MeshInstance3D" type="MeshInstance3D" parent="Box3DWorld/Floor"]')
A('mesh = SubResource("FloorMesh")')
A('material_override = SubResource("FloorMat")')
A('')
A('[node name="Blocks" type="Node3D" parent="Box3DWorld"]')
A('')

# 90-degree rotation about Y (swap long axis X<->Z).
ROT90 = "0, 0, -1, 0, 1, 0, 1, 0, 0"

n = 0
for layer in range(LAYERS):
    y = 0.25 + layer * LAYER_DY
    for k in (-1, 0, 1):
        if layer % 2 == 0:
            # long axis along X; three blocks spread in Z
            xf = "1, 0, 0, 0, 1, 0, 0, 0, 1, 0, %g, %g" % (y, k * GAP)
        else:
            # rotated: long axis along Z; three blocks spread in X
            xf = "%s, %g, %g, 0" % (ROT90, k * GAP, y)
        A('[node name="Blk_%d" type="Box3DBody" parent="Box3DWorld/Blocks"]' % n)
        A('transform = Transform3D(%s)' % xf)
        A('box_size = Vector3(%g, %g, %g)' % (BLK_L, BLK_H, BLK_W))
        A('friction = 0.7')
        A('')
        A('[node name="MeshInstance3D" type="MeshInstance3D" parent="Box3DWorld/Blocks/Blk_%d"]' % n)
        A('mesh = SubResource("BlockMesh")')
        A('material_override = SubResource("BlockMat")')
        A('')
        n += 1

out = "\n".join(lines) + "\n"
_out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "samples", "tower.tscn")
with open(_out, "w", encoding="utf-8") as f:
    f.write(out)
print("wrote samples/tower.tscn with %d blocks (%d layers)" % (n, LAYERS))
