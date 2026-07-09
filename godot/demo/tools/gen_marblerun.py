import os
import math

# Emits samples/marble_run.tscn: a zig-zag of alternately-tilted ramps in a
# z-channel, with a catch tray at the bottom. marble_run.gd drips marbles from
# the top; they roll down ramp to ramp. Robust rolling mechanic (no timing).

N = 5
LEN = 9.0
TILT = 0.26
DY = 2.8
Y0 = 12.0
HALF_Z = 1.4     # channel half-depth
c = math.cos(TILT)
s = math.sin(TILT)

subres = []
nodes = []
S = subres.append
B = nodes.append

S('[sub_resource type="StandardMaterial3D" id="FloorMat"]\n'
  'albedo_color = Color(0.2, 0.22, 0.26, 1)\nroughness = 0.55\nmetallic = 0.1')
S('[sub_resource type="BoxMesh" id="FloorMesh"]\nsize = Vector3(16, 1, 6)')
S('[sub_resource type="BoxMesh" id="RampMesh"]\nsize = Vector3(%g, 0.3, %g)' % (LEN, 2 * HALF_Z))
S('[sub_resource type="StandardMaterial3D" id="RampMat"]\n'
  'albedo_color = Color(0.45, 0.4, 0.5, 1)\nroughness = 0.5\nmetallic = 0.2')
S('[sub_resource type="StandardMaterial3D" id="WallMat"]\n'
  'albedo_color = Color(0.28, 0.3, 0.36, 1)\nroughness = 0.6')


def fit_box(name, size, pos, mat):
    mid = "M_" + name
    S('[sub_resource type="BoxMesh" id="%s"]\nsize = Vector3(%g, %g, %g)' % (mid, size[0], size[1], size[2]))
    B('[node name="%s" type="Box3DBody" parent="Box3DWorld"]' % name)
    B('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, %g, %g, %g)' % pos)
    B('body_type = 0')
    B('shape_type = 7')
    B('friction = 0.25')
    B('')
    B('[node name="MeshInstance3D" type="MeshInstance3D" parent="Box3DWorld/%s"]' % name)
    B('mesh = SubResource("%s")' % mid)
    B('material_override = SubResource("%s")' % mat)
    B('')


B('[node name="MarbleRun" type="Node3D"]')
B('script = ExtResource("1_mr")')
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
B('mesh = SubResource("FloorMesh")')
B('material_override = SubResource("FloorMat")')
B('')

# The zig-zag ramps. Even ramps tilt +x-end-down; odd ramps the other way.
B('[node name="Ramps" type="Node3D" parent="Box3DWorld"]')
B('')
for i in range(N):
    y = Y0 - i * DY
    theta = -TILT if (i % 2 == 0) else TILT
    cc = math.cos(theta)
    ss = math.sin(theta)
    # Z-rotation basis columns: x'=(cc,ss,0) y'=(-ss,cc,0) z'=(0,0,1)
    B('[node name="Ramp_%d" type="Box3DBody" parent="Box3DWorld/Ramps"]' % i)
    B('transform = Transform3D(%.5g, %.5g, 0, %.5g, %.5g, 0, 0, 0, 1, 0, %g, 0)' % (cc, ss, -ss, cc, y))
    B('body_type = 0')
    B('box_size = Vector3(%g, 0.3, %g)' % (LEN, 2 * HALF_Z))
    B('friction = 0.2')
    B('')
    B('[node name="MeshInstance3D" type="MeshInstance3D" parent="Box3DWorld/Ramps/Ramp_%d"]' % i)
    B('mesh = SubResource("RampMesh")')
    B('material_override = SubResource("RampMat")')
    B('')

# Channel side walls (keep marbles from rolling off in z) + end backstops.
top = Y0 + 2.0
height = top + 1.0
fit_box("WallFront", (12, height, 0.4), (0, height / 2 - 1.0, HALF_Z + 0.2), "WallMat")
fit_box("WallBack", (12, height, 0.4), (0, height / 2 - 1.0, -HALF_Z - 0.2), "WallMat")
fit_box("EndL", (0.4, height, 2 * HALF_Z + 0.8), (-5.6, height / 2 - 1.0, 0), "WallMat")
fit_box("EndR", (0.4, height, 2 * HALF_Z + 0.8), (5.6, height / 2 - 1.0, 0), "WallMat")
# Catch tray lip so marbles pool at the bottom instead of rolling away.
fit_box("TrayLipL", (0.4, 1.2, 2 * HALF_Z), (-3.0, 0.1, 0), "WallMat")
fit_box("TrayLipR", (0.4, 1.2, 2 * HALF_Z), (3.0, 0.1, 0), "WallMat")

header = '[gd_scene load_steps=%d format=3]' % (len(subres) + 2)
ext = '[ext_resource type="Script" path="res://samples/marble_run.gd" id="1_mr"]'
out = header + '\n\n' + ext + '\n\n' + '\n\n'.join(subres) + '\n\n' + '\n'.join(nodes) + '\n'

_out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "samples", "marble_run.tscn")
with open(_out, "w", encoding="utf-8") as f:
    f.write(out)
print("wrote samples/marble_run.tscn with %d ramps" % N)
