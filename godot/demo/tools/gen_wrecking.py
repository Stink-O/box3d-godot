import os
import math

from rope_builder import rope_link_assets, build_rope

# Emits samples/wrecking.tscn: a heavy wrecking ball on a real jointed chain
# (a handful of small dynamic links pinned end-to-end with Box3DBallJoint,
# plane-locked) that starts pulled back and swings into a block wall on load.
# World physics is all joints + gravity; wrecking.gd has nothing to draw.

ANCHOR = (0.0, 9.0, 0.0)
ROPE = 6.0
ROPE_LINKS = 8
ROPE_RADIUS = 0.07
# The ball is very dense (density 12, r=1 -> mass ~50) so the rope links need
# enough mass of their own or the ball/last-link joint (an ~extreme mass-ratio
# pin) stretches badly under the swing -- a well-known failure mode for
# iterative solvers chaining a heavy tip off light links. Density 40 keeps the
# whole rope at ~6% of the ball's mass (still "light") while holding taut.
ROPE_DENSITY = 40.0
BALL_R = 1.0
THETA = math.radians(78.0)   # pulled back toward -x
BALL_X = ANCHOR[0] - ROPE * math.sin(THETA)
BALL_Y = ANCHOR[1] - ROPE * math.cos(THETA)

# Wall grid.
WX0, WX1 = 2.9, 3.7          # two courses deep
BLK = 0.8
COLS_Z = [-0.85, 0.0, 0.85]
ROWS = 7

subres = []
nodes = []
S = subres.append
B = nodes.append

S('[sub_resource type="BoxMesh" id="FloorMesh"]\nsize = Vector3(30, 1, 16)')
S('[sub_resource type="StandardMaterial3D" id="FloorMat"]\n'
  'albedo_color = Color(0.2, 0.22, 0.26, 1)\nroughness = 0.55\nmetallic = 0.1')
S('[sub_resource type="BoxMesh" id="PostMesh"]\nsize = Vector3(0.4, 9.6, 0.4)')
S('[sub_resource type="BoxMesh" id="ArmMesh"]\nsize = Vector3(2, 0.4, 0.4)')
S('[sub_resource type="StandardMaterial3D" id="SteelMat"]\n'
  'albedo_color = Color(0.35, 0.37, 0.42, 1)\nroughness = 0.5\nmetallic = 0.5')
S('[sub_resource type="SphereMesh" id="BallMesh"]\nradius = %g\nheight = %g' % (BALL_R, 2 * BALL_R))
S('[sub_resource type="StandardMaterial3D" id="BallMat"]\n'
  'albedo_color = Color(0.25, 0.27, 0.3, 1)\nroughness = 0.4\nmetallic = 0.7')
S('[sub_resource type="BoxMesh" id="BlockMesh"]\nsize = Vector3(%g, %g, %g)' % (BLK, BLK, BLK))
S('[sub_resource type="StandardMaterial3D" id="BlockMat"]\n'
  'albedo_color = Color(0.75, 0.4, 0.3, 1)\nroughness = 0.7')
rope_link_assets(S, "RopeLinkMesh", "RopeLinkMat", ROPE_RADIUS, (0.2, 0.2, 0.22, 1))

B('[node name="Wrecking" type="Node3D"]')
B('script = ExtResource("1_wreck")')
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
# Decorative crane post + arm — visuals only (no collision) and set behind the
# swing plane (z>0), so they never block the ball, which is locked to z=0.
B('[node name="Post" type="MeshInstance3D" parent="."]')
B('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, -1.2, 4.8, 1.6)')
B('mesh = SubResource("PostMesh")')
B('material_override = SubResource("SteelMat")')
B('')
B('[node name="Arm" type="MeshInstance3D" parent="."]')
B('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, -0.4, %g, 1.6)' % (ANCHOR[1] + 0.1))
B('mesh = SubResource("ArmMesh")')
B('material_override = SubResource("SteelMat")')
B('')

# The wrecking ball (heavy, plane-locked), hung from the anchor by a real
# jointed rope (chain of small dynamic links, see below) instead of a bare
# distance joint.
B('[node name="Ball" type="Box3DBody" parent="Box3DWorld"]')
B('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, %.4g, %.4g, 0)' % (BALL_X, BALL_Y))
B('shape_type = 1')
B('sphere_radius = %g' % BALL_R)
B('density = 12.0')
B('friction = 0.5')
B('continuous = true')
B('lock_linear_z = true')
B('')
B('[node name="MeshInstance3D" type="MeshInstance3D" parent="Box3DWorld/Ball"]')
B('mesh = SubResource("BallMesh")')
B('material_override = SubResource("BallMat")')
B('')

# Real rope: a chain of small dynamic capsule links pinned end-to-end with
# Box3DBallJoint, from the fixed world anchor down to the ball's center.
build_rope(B, "Box3DWorld", "Rope", ANCHOR, (BALL_X, BALL_Y, 0.0), "../Ball",
           ROPE_LINKS, "RopeLinkMesh", "RopeLinkMat", radius=ROPE_RADIUS, density=ROPE_DENSITY)

# Block wall.
B('[node name="Wall" type="Node3D" parent="Box3DWorld"]')
B('')
n = 0
for x in (WX0, WX1):
    for row in range(ROWS):
        y = BLK / 2.0 + row * (BLK + 0.01)
        for z in COLS_Z:
            B('[node name="Blk_%d" type="Box3DBody" parent="Box3DWorld/Wall"]' % n)
            B('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, %g, %.4g, %g)' % (x, y, z))
            B('box_size = Vector3(%g, %g, %g)' % (BLK, BLK, BLK))
            B('friction = 0.6')
            B('')
            B('[node name="MeshInstance3D" type="MeshInstance3D" parent="Box3DWorld/Wall/Blk_%d"]' % n)
            B('mesh = SubResource("BlockMesh")')
            B('material_override = SubResource("BlockMat")')
            B('')
            n += 1

header = '[gd_scene load_steps=%d format=3]' % (len(subres) + 2)
ext = '[ext_resource type="Script" path="res://samples/wrecking.gd" id="1_wreck"]'
out = header + '\n\n' + ext + '\n\n' + '\n\n'.join(subres) + '\n\n' + '\n'.join(nodes) + '\n'

_out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "samples", "wrecking.tscn")
with open(_out, "w", encoding="utf-8") as f:
    f.write(out)
print("wrote samples/wrecking.tscn (%d wall blocks, ball at %.1f,%.1f)" % (n, BALL_X, BALL_Y))
