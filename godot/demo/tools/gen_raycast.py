import os
import math

# Emits samples/raycast.tscn: a central emitter with a beam that sweeps around,
# plus a ring of dynamic target pillars the raycast lights up. raycast.gd drives
# the sweep. Beam + hit marker are plain MeshInstance3D visuals on the root.

N = 12
RING_R = 7.0

subres = []
nodes = []
S = subres.append
B = nodes.append

S('[sub_resource type="StandardMaterial3D" id="FloorMat"]\n'
  'albedo_color = Color(0.2, 0.22, 0.26, 1)\nroughness = 0.55\nmetallic = 0.1')
S('[sub_resource type="BoxMesh" id="FloorPlate"]\nsize = Vector3(30, 1, 30)')
S('[sub_resource type="BoxMesh" id="TargetMesh"]\nsize = Vector3(1, 2, 1)')
S('[sub_resource type="StandardMaterial3D" id="TargetMat"]\n'
  'albedo_color = Color(0.55, 0.6, 0.7, 1)\nroughness = 0.5')
S('[sub_resource type="CylinderMesh" id="PostMesh"]\n'
  'top_radius = 0.25\nbottom_radius = 0.25\nheight = 1.6')
S('[sub_resource type="StandardMaterial3D" id="PostMat"]\n'
  'albedo_color = Color(0.3, 0.32, 0.38, 1)\nroughness = 0.6\nmetallic = 0.3')
S('[sub_resource type="CylinderMesh" id="BeamMesh"]\n'
  'top_radius = 0.045\nbottom_radius = 0.045\nheight = 1.0')
S('[sub_resource type="StandardMaterial3D" id="BeamMat"]\n'
  'albedo_color = Color(1, 0.25, 0.15, 1)\nemission_enabled = true\n'
  'emission = Color(1, 0.25, 0.15, 1)\nemission_energy_multiplier = 3.0\nshading_mode = 0')
S('[sub_resource type="SphereMesh" id="MarkerMesh"]\nradius = 0.2\nheight = 0.4')
S('[sub_resource type="StandardMaterial3D" id="MarkerMat"]\n'
  'albedo_color = Color(1, 0.9, 0.3, 1)\nemission_enabled = true\n'
  'emission = Color(1, 0.9, 0.3, 1)\nemission_energy_multiplier = 4.0\nshading_mode = 0')

B('[node name="RayCast" type="Node3D"]')
B('script = ExtResource("1_ray")')
B('')
B('[node name="Box3DWorld" type="Box3DWorld" parent="."]')
B('gravity = Vector3(0, -9.8, 0)')
B('')
B('[node name="Floor" type="Box3DBody" parent="Box3DWorld"]')
B('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, -0.5, 0)')
B('body_type = 0')
B('shape_type = 7')
B('')
B('[node name="MeshInstance3D" type="MeshInstance3D" parent="Box3DWorld/Floor"]')
B('mesh = SubResource("FloorPlate")')
B('material_override = SubResource("FloorMat")')
B('')

# Central emitter post (static, decorative — the ray starts just above it).
B('[node name="Emitter" type="Box3DBody" parent="Box3DWorld"]')
B('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0.8, 0)')
B('body_type = 0')
B('shape_type = 3')
B('capsule_radius = 0.25')
B('capsule_height = 1.6')
B('')
B('[node name="MeshInstance3D" type="MeshInstance3D" parent="Box3DWorld/Emitter"]')
B('mesh = SubResource("PostMesh")')
B('material_override = SubResource("PostMat")')
B('')

# Ring of dynamic target pillars.
B('[node name="Targets" type="Node3D" parent="Box3DWorld"]')
B('')
for i in range(N):
    a = (i / float(N)) * math.tau
    x = math.cos(a) * RING_R
    z = math.sin(a) * RING_R
    B('[node name="Target_%d" type="Box3DBody" parent="Box3DWorld/Targets"]' % i)
    B('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, %.4g, 1, %.4g)' % (x, z))
    B('box_size = Vector3(1, 2, 1)')
    B('density = 3.0')
    B('')
    B('[node name="MeshInstance3D" type="MeshInstance3D" parent="Box3DWorld/Targets/Target_%d"]' % i)
    B('mesh = SubResource("TargetMesh")')
    B('material_override = SubResource("TargetMat")')
    B('')

# Beam + hit marker (visuals on the root; the script positions them).
B('[node name="Beam" type="MeshInstance3D" parent="."]')
B('mesh = SubResource("BeamMesh")')
B('material_override = SubResource("BeamMat")')
B('')
B('[node name="HitMarker" type="MeshInstance3D" parent="."]')
B('mesh = SubResource("MarkerMesh")')
B('material_override = SubResource("MarkerMat")')
B('')

header = '[gd_scene load_steps=%d format=3]' % (len(subres) + 2)
ext = '[ext_resource type="Script" path="res://samples/raycast.gd" id="1_ray"]'
out = header + '\n\n' + ext + '\n\n' + '\n\n'.join(subres) + '\n\n' + '\n'.join(nodes) + '\n'

_out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "samples", "raycast.tscn")
with open(_out, "w", encoding="utf-8") as f:
    f.write(out)
print("wrote samples/raycast.tscn with %d targets" % N)
