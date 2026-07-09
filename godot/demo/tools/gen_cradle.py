import os
import math

# Emits samples/cradle.tscn: a Newton's cradle. Five balls hang from RIGID rods
# (a Box3DDistanceJoint each, spring disabled -> inextensible) and are plane-
# locked, so each ball swings as a true rigid pendulum. The end ball starts
# raised; it swings down and transfers momentum crisply along the touching line.
#
# The rods are rigid (not a chain of little links) because a link chain is
# springy and lossy -- it made the balls bob elastically and damped the
# transfer. cradle.gd draws a thin rod for each string every frame.
#
# The decorative posts are placed OUTSIDE the swing arc so they never block the
# raised ball (they used to).

N = 5
R = 0.5
ROPE = 3.0
ANCHOR_Y = 5.0
REST_Y = ANCHOR_Y - ROPE          # = 2.0
SPACING = 2.0 * R                 # balls just touching for clean transfer
X0 = -(N - 1) * SPACING / 2.0
THETA = math.radians(50.0)        # end-ball pull-back
SWING_X = (X0 + (N - 1) * SPACING) + ROPE * math.sin(THETA)  # how far the raised ball reaches
POST_X = SWING_X + 0.8            # posts clear of the swing
BAR_LEN = 2.0 * POST_X + 0.3

subres = []
nodes = []
S = subres.append
B = nodes.append

S('[sub_resource type="StandardMaterial3D" id="FloorMat"]\n'
  'albedo_color = Color(0.2, 0.22, 0.26, 1)\nroughness = 0.55\nmetallic = 0.1')
S('[sub_resource type="BoxMesh" id="FloorMesh"]\nsize = Vector3(24, 1, 16)')
S('[sub_resource type="SphereMesh" id="BallMesh"]\nradius = %g\nheight = %g' % (R, 2 * R))
S('[sub_resource type="StandardMaterial3D" id="BallMat"]\n'
  'albedo_color = Color(0.75, 0.78, 0.85, 1)\nroughness = 0.25\nmetallic = 0.7')
S('[sub_resource type="BoxMesh" id="PostMesh"]\nsize = Vector3(0.3, 5.2, 0.3)')
S('[sub_resource type="BoxMesh" id="BarMesh"]\nsize = Vector3(%g, 0.3, 0.3)' % BAR_LEN)
S('[sub_resource type="StandardMaterial3D" id="FrameMat"]\n'
  'albedo_color = Color(0.32, 0.24, 0.18, 1)\nroughness = 0.6')

B('[node name="Cradle" type="Node3D"]')
B('script = ExtResource("1_cradle")')
B('')
B('[node name="Box3DWorld" type="Box3DWorld" parent="."]')
B('gravity = Vector3(0, -9.8, 0)')
B('substep_count = 8')
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

# Decorative static frame (two posts well clear of the swing + a top bar).
for nm, px in (("PostL", -POST_X), ("PostR", POST_X)):
    B('[node name="%s" type="Box3DBody" parent="Box3DWorld"]' % nm)
    B('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, %g, 2.6, 0)' % px)
    B('body_type = 0')
    B('box_size = Vector3(0.3, 5.2, 0.3)')
    B('')
    B('[node name="MeshInstance3D" type="MeshInstance3D" parent="Box3DWorld/%s"]' % nm)
    B('mesh = SubResource("PostMesh")')
    B('material_override = SubResource("FrameMat")')
    B('')
B('[node name="TopBar" type="Box3DBody" parent="Box3DWorld"]')
B('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, %g, 0)' % (ANCHOR_Y + 0.15))
B('body_type = 0')
B('box_size = Vector3(%g, 0.3, 0.3)' % BAR_LEN)
B('')
B('[node name="MeshInstance3D" type="MeshInstance3D" parent="Box3DWorld/TopBar"]')
B('mesh = SubResource("BarMesh")')
B('material_override = SubResource("FrameMat")')
B('')

# Balls. The last one starts pulled back so it swings in.
B('[node name="Balls" type="Node3D" parent="Box3DWorld"]')
B('')
ball_pos = []
for i in range(N):
    rest_x = X0 + i * SPACING
    if i == N - 1:
        x = rest_x + ROPE * math.sin(THETA)
        y = ANCHOR_Y - ROPE * math.cos(THETA)
    else:
        x, y = rest_x, REST_Y
    ball_pos.append((x, y))
    B('[node name="Ball_%d" type="Box3DBody" parent="Box3DWorld/Balls"]' % i)
    B('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, %.5g, %.5g, 0)' % (x, y))
    B('shape_type = 1')
    B('sphere_radius = %g' % R)
    B('restitution = 0.99')
    B('friction = 0.15')
    B('linear_damping = 0.0')
    B('lock_linear_z = true')
    B('lock_angular_x = true')
    B('lock_angular_y = true')
    B('lock_angular_z = true')
    B('')
    B('[node name="MeshInstance3D" type="MeshInstance3D" parent="Box3DWorld/Balls/Ball_%d"]' % i)
    B('mesh = SubResource("BallMesh")')
    B('material_override = SubResource("BallMat")')
    B('')

# Rigid rods: one Box3DDistanceJoint per ball, from a fixed world anchor above
# its rest position down to the ball, spring disabled so the length is held
# exactly (an inextensible pendulum rod). cradle.gd draws each rod.
B('[node name="Strings" type="Node3D" parent="Box3DWorld"]')
B('')
for i in range(N):
    rest_x = X0 + i * SPACING
    B('[node name="String_%d" type="Box3DDistanceJoint" parent="Box3DWorld/Strings"]' % i)
    B('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, %.5g, %g, 0)' % (rest_x, ANCHOR_Y))
    B('body_a = NodePath("../../Balls/Ball_%d")' % i)
    B('length = %g' % ROPE)
    B('')

# cradle.gd's REST_X list should match these rest positions.
rest_list = ", ".join("%.5g" % (X0 + i * SPACING) for i in range(N))

header = '[gd_scene load_steps=%d format=3]' % (len(subres) + 2)
ext = '[ext_resource type="Script" path="res://samples/cradle.gd" id="1_cradle"]'
out = header + '\n\n' + ext + '\n\n' + '\n\n'.join(subres) + '\n\n' + '\n'.join(nodes) + '\n'

_out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "samples", "cradle.tscn")
with open(_out, "w", encoding="utf-8") as f:
    f.write(out)
print("wrote samples/cradle.tscn (swing reaches x=%.2f, posts at +/-%.2f; REST_X [%s])"
      % (SWING_X, POST_X, rest_list))
