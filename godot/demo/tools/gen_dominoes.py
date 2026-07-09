import os
import sys

# Emits samples/dominoes.tscn: a straight line of thin slabs, standing upright,
# running along +X. World-only aside from dominoes.gd on the root (kick+replay).

N = 18            # number of dominoes
SPACING = float(sys.argv[1]) if len(sys.argv) > 1 else 1.0  # centre-to-centre (m)
THIN = 0.2        # slab thickness (local X, the fall direction)
TALL = 2.0        # slab height (local Y)
WIDE = 1.0        # slab width (local Z)

x0 = -(N - 1) * SPACING / 2.0

lines = []
A = lines.append

A('[gd_scene load_steps=6 format=3]')
A('')
A('[ext_resource type="Script" path="res://samples/dominoes.gd" id="1_dom"]')
A('')
A('[sub_resource type="BoxMesh" id="FloorMesh"]')
A('size = Vector3(40, 1, 40)')
A('')
A('[sub_resource type="StandardMaterial3D" id="FloorMat"]')
A('albedo_color = Color(0.2, 0.22, 0.26, 1)')
A('roughness = 0.55')
A('metallic = 0.1')
A('')
A('[sub_resource type="BoxMesh" id="DomMesh"]')
A('size = Vector3(%g, %g, %g)' % (THIN, TALL, WIDE))
A('')
A('[sub_resource type="StandardMaterial3D" id="DomA"]')
A('albedo_color = Color(0.86, 0.3, 0.28, 1)')
A('roughness = 0.4')
A('')
A('[sub_resource type="StandardMaterial3D" id="DomB"]')
A('albedo_color = Color(0.28, 0.55, 0.86, 1)')
A('roughness = 0.4')
A('')
A('[node name="Dominoes" type="Node3D"]')
A('script = ExtResource("1_dom")')
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
A('mesh = SubResource("FloorMesh")')
A('material_override = SubResource("FloorMat")')
A('')
A('[node name="Dominoes" type="Node3D" parent="Box3DWorld"]')
A('')

for i in range(N):
    x = x0 + i * SPACING
    mat = "DomA" if i % 2 == 0 else "DomB"
    A('[node name="Dom_%d" type="Box3DBody" parent="Box3DWorld/Dominoes"]' % i)
    A('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, %.4g, %g, 0)' % (x, TALL / 2.0))
    A('box_size = Vector3(%g, %g, %g)' % (THIN, TALL, WIDE))
    A('friction = 0.5')
    A('')
    A('[node name="MeshInstance3D" type="MeshInstance3D" parent="Box3DWorld/Dominoes/Dom_%d"]' % i)
    A('mesh = SubResource("DomMesh")')
    A('material_override = SubResource("%s")' % mat)
    A('')

out = "\n".join(lines) + "\n"
_out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "samples", "dominoes.tscn")
os.makedirs(os.path.dirname(_out), exist_ok=True)
with open(_out, "w", encoding="utf-8") as f:
    f.write(out)
print("wrote samples/dominoes.tscn with %d dominoes at spacing %g" % (N, SPACING))
