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

# Decorative crane: a mast standing on the floor and a jib whose tip is
# directly over ANCHOR, so the rope visibly hangs off the end of the jib.
#
# The mast and the jib are MeshInstance3D, not bodies -- they have no collider
# and cannot block anything, which is why they can stand where the ball swings
# without being "in the way". They used to sit at z = 1.6 for exactly that
# (mistaken) reason, and the cost was the whole scene reading as broken: the
# ball hung from a rope whose top end was 1.4 m clear of the nearest piece of
# crane, i.e. from nothing at all.
#
# The one direction the ball genuinely never occupies is z: it is
# lock_linear_z, so it stays in the z = 0 plane and its sphere spans z = -1..1
# forever. So the mast stands off in z and the jib runs back along z to the
# anchor. NEGATIVE z, because the shell's default camera sits at (0, 8, 18)
# looking down -z (main.tscn:28-29) and this sample authors no view of its own:
# a mast at +z would stand between that camera and the entire swing.
#
# Running the jib along z rather than along x also keeps it out of the rope's
# way. The rope pivots about ANCHOR in the x-y plane and reaches 78 deg from
# vertical, so a jib laid along x would have the top link sweeping along its
# underside; along z the link leaves the jib's 0.4 m x-band as soon as it
# tilts. The 0.12 m the underside sits above ANCHOR covers the one remaining
# case: a near-vertical rope, whose top link's cap reaches y = 9.058 (measured
# over 600 steps) -- less than a link radius of daylight, so the rope still
# reads as running into the jib rather than hanging below it.
MAST_Z = -2.0
MAST = (0.4, 9.6, 0.4)                          # x, y, z extents
JIB_H = 0.4                                     # square section
JIB_BOTTOM = ANCHOR[1] + 0.12
JIB_Z0, JIB_Z1 = MAST_Z - MAST[2] / 2.0, 0.4    # overhangs the anchor

# Wall grid. The vertical pitch is exactly BLK: a wall authored with a gap per
# course starts in free fall and sinks by (ROWS - 1) x gap the moment the scene
# loads -- at the 0.01 this used that was 6.2 cm of visible settle on the top
# course. Boxes that exactly touch are at rest, and Box3D's speculative
# contacts resolve the zero-distance pairs on the first step.
WX0, WX1 = 2.9, 3.7          # two courses deep, flush
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
S('[sub_resource type="BoxMesh" id="PostMesh"]\nsize = Vector3(%g, %g, %g)' % MAST)
S('[sub_resource type="BoxMesh" id="ArmMesh"]\nsize = Vector3(%g, %g, %g)'
  % (JIB_H, JIB_H, JIB_Z1 - JIB_Z0))
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
# Decorative crane, visuals only (no collision). The mast stands on the floor
# at z = MAST_Z, clear of the ball's z = -1..1 band and behind the default
# view; the jib runs forward over the anchor so the rope leaves the crane
# where a rope should.
B('[node name="Post" type="MeshInstance3D" parent="."]')
B('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, %g, %g, %g)'
  % (ANCHOR[0], MAST[1] / 2.0, MAST_Z))
B('mesh = SubResource("PostMesh")')
B('material_override = SubResource("SteelMat")')
B('')
B('[node name="Arm" type="MeshInstance3D" parent="."]')
B('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, %g, %g, %g)'
  % (ANCHOR[0], JIB_BOTTOM + JIB_H / 2.0, (JIB_Z0 + JIB_Z1) / 2.0))
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
        y = BLK / 2.0 + row * BLK
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
