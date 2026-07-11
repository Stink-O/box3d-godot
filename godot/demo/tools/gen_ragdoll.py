import os
import math

# Emits samples/ragdoll.tscn: a wooden-mannequin humanoid in the style of
# box3d's own human prefab (shared/human.c) -- every bone is a capsule, all in
# one wood tone. The torso is a stack of four horizontal capsules (pelvis,
# belly, mid-spine, chest) that reads as a ribbed mannequin trunk, the head is
# a vertical capsule (an egg), and the limbs are vertical capsules that
# overlap their neighbours at every joint so the figure reads as ONE connected
# body, not floating pieces (jointed pairs don't collide, so overlap is free).
#
# It spawns standing. The joint tuning is upstream's ragdoll-sample setup
# (sample_ragdoll.cpp / shared/human.c): every joint has a soft angular spring
# toward the spawn pose (hertz 1, damping 0.7) plus a small dry-friction
# torque, and the cone/twist/hinge ranges below are human.c's own numbers --
# so the figure stands like a posed mannequin instead of collapsing on load,
# and crumples the way box3d's own samples do when you grab/shoot/bomb it.
#
# The figure faces +Z: hips/knees/elbows get asymmetric human ranges (knees
# bend backward, elbows forward), which is what the limit signs below encode.

DROP = 0.01  # lowest point starts this far above the floor

DENSITY = 3.0
# Upstream tunes jointFrictionTorque = 5 N*m against box3d's default density
# of 1000 kg/m^3; the demo's bodies use density 3, so scale the torque by the
# same 3/1000 to get the identical feel. (Spring hertz/damping are
# frequency-based and mass-independent -- they carry over unscaled.)
FRICTION_BASE = 5.0 * DENSITY / 1000.0
SPRING_HERTZ = 1.0
SPRING_DAMPING = 0.7

# --- skeleton, standing, feet near y=0, facing +Z ---
# Vertical capsules: (name, x, top_y, bottom_y, radius)
V_CAPSULES = [
    ("thigh_l",     -0.11, 0.89, 0.53, 0.09),
    ("thigh_r",      0.11, 0.89, 0.53, 0.09),
    ("shin_l",      -0.11, 0.50, 0.085, 0.075),
    ("shin_r",       0.11, 0.50, 0.085, 0.075),
    ("upper_arm_l", -0.30, 1.44, 1.19, 0.075),
    ("upper_arm_r",  0.30, 1.44, 1.19, 0.075),
    ("lower_arm_l", -0.30, 1.21, 0.94, 0.055),
    ("lower_arm_r",  0.30, 1.21, 0.94, 0.055),
    ("neck",         0.0,  1.60, 1.50, 0.07),
    ("head",         0.0,  1.76, 1.68, 0.10),
]
# Horizontal torso capsules, axis along X: (name, center_y, half_seg, radius)
H_CAPSULES = [
    ("pelvis",   0.98, 0.07,  0.13),
    ("belly",    1.12, 0.06,  0.115),
    ("spine",    1.25, 0.075, 0.10),
    ("chest",    1.41, 0.09,  0.145),
]

# Ball joints: (name, body_a, body_b, anchor, frame, cone_deg,
#               twist_lo_deg, twist_hi_deg, friction_mult)
# Cone/twist ranges and friction multipliers are shared/human.c's values, so
# this ragdoll moves like box3d's own. frame picks the joint's Z axis (the
# twist axis):
#   "up"   -> world +Y: twist = rolling about the spine/limb axis
#   "side" -> world +X: twist = the forward/back swing, so the big human
#             range (hip flexion) rides the twist limit and the cone only
#             allows a little spread -- the same trick upstream's hips use.
BALL = [
    ("waist",      "pelvis", "belly",       (0.0,    1.06), "up",   25.0, -15.0, 15.0, 1.0),
    ("mid_spine",  "belly",  "spine",       (0.0,    1.19), "up",   25.0, -15.0, 15.0, 1.0),
    ("chest_join", "spine",  "chest",       (0.0,    1.30), "up",   15.0, -10.0, 10.0, 1.0),
    ("neck_base",  "chest",  "neck",        (0.0,    1.50), "up",   45.0, -15.0, 15.0, 0.8),
    ("head_join",  "neck",   "head",        (0.0,    1.62), "up",   15.0, -15.0, 15.0, 0.4),
    ("shoulder_l", "chest",  "upper_arm_l", (-0.235, 1.44), "up",   60.0, -5.0, 5.0, 1.0),
    ("shoulder_r", "chest",  "upper_arm_r", (0.235,  1.44), "up",   60.0, -5.0, 5.0, 1.0),
    # Forward hip swing is rotation toward +Z = negative about the +X twist
    # axis: 60 deg of flexion forward, 40 deg of extension back (human.c).
    ("hip_l",      "pelvis", "thigh_l",     (-0.11,  0.92), "side", 10.0, -60.0, 40.0, 1.0),
    ("hip_r",      "pelvis", "thigh_r",     (0.11,   0.92), "side", 10.0, -60.0, 40.0, 1.0),
]
# Hinge joints about world +X: (name, body_a, body_b, anchor,
#                               lower_deg, upper_deg, friction_mult)
# Positive rotation swings the child bone's lower end toward -Z (backward):
# knees fold backward, elbows fold forward. Ranges are human.c's: 45 deg of
# knee flexion and 60 deg of elbow flexion (+5 deg hyperextension each), which
# is what keeps the thrown mannequin stiff-limbed instead of folding double.
HINGE = [
    ("knee_l",  "thigh_l",     "shin_l",      (-0.11, 0.515), -5.0, 45.0, 1.0),
    ("knee_r",  "thigh_r",     "shin_r",      (0.11,  0.515), -5.0, 45.0, 1.0),
    ("elbow_l", "upper_arm_l", "lower_arm_l", (-0.30, 1.20), -60.0, 5.0, 1.0),
    ("elbow_r", "upper_arm_r", "lower_arm_r", (0.30,  1.20), -60.0, 5.0, 1.0),
]

# Basis AXIS/COLUMN vectors (X, Y, Z) for the node transforms. Godot capsules
# run along local Y, hinge bends about local Z, ball twist is about local Z.
# NOTE: xf() below transposes these into rows, because a .tscn Transform3D's
# nine basis numbers are ROW-major (Basis.rows), not the axis vectors --
# writing axes straight into those slots silently inverts every rotation
# (which once turned the knee/elbow hinge axes vertical and froze them).
IDENT = ((1.0, 0.0, 0.0), (0.0, 1.0, 0.0), (0.0, 0.0, 1.0))
X_ALIGNED = ((0.0, -1.0, 0.0), (1.0, 0.0, 0.0), (0.0, 0.0, 1.0))  # local Y -> world X
Z_UP = ((1.0, 0.0, 0.0), (0.0, 0.0, -1.0), (0.0, 1.0, 0.0))       # local Z -> world Y
Z_SIDE = ((0.0, 1.0, 0.0), (0.0, 0.0, 1.0), (1.0, 0.0, 0.0))      # local Z -> world X

# Feet on the floor: offset every y so the lowest collision point sits at DROP.
_lowest = min(bot - r for _n, _x, _top, bot, r in V_CAPSULES)
YOFF = DROP - _lowest


def xf(cols, o):
    xa, ya, za = cols
    # column vectors -> row-major serialization (see note above)
    v = [xa[0], ya[0], za[0], xa[1], ya[1], za[1], xa[2], ya[2], za[2],
         o[0], o[1] + YOFF, o[2]]
    return "Transform3D(" + ", ".join("%.6g" % x for x in v) + ")"


subres = []
nodes = []
S = subres.append
B = nodes.append

S('[sub_resource type="BoxMesh" id="FloorMesh"]\nsize = Vector3(40, 1, 40)')
S('[sub_resource type="StandardMaterial3D" id="FloorMat"]\n'
  'albedo_color = Color(0.2, 0.22, 0.26, 1)\nroughness = 0.55\nmetallic = 0.1')
S('[sub_resource type="StandardMaterial3D" id="WoodMat"]\n'
  'albedo_color = Color(0.87, 0.71, 0.52, 1)\nroughness = 0.6')

B('[node name="Ragdoll" type="Node3D"]')
B('script = ExtResource("1_rag")')
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
B('[node name="Body" type="Node3D" parent="Box3DWorld"]')
B('')


def emit_bone(name, cols, origin, r, seg_len):
    # every bone: dynamic, collides with the floor AND all non-adjacent bones
    height = seg_len + 2 * r  # capsule height is total (segment + 2 caps)
    B('[node name="%s" type="Box3DBody" parent="Box3DWorld/Body"]' % name)
    B('transform = ' + xf(cols, origin))
    B('shape_type = 2')
    B('capsule_radius = %.5g' % r)
    B('capsule_height = %.5g' % height)
    B('density = %.5g' % DENSITY)
    B('friction = 0.5')
    B('collision_layer = 1')
    B('collision_mask = 1')
    B('')
    S('[sub_resource type="CapsuleMesh" id="Mesh_%s"]\nradius = %.5g\nheight = %.5g'
      % (name, r, height))
    B('[node name="MeshInstance3D" type="MeshInstance3D" parent="Box3DWorld/Body/%s"]' % name)
    B('mesh = SubResource("Mesh_%s")' % name)
    B('material_override = SubResource("WoodMat")')
    B('')


for name, x, top, bot, r in V_CAPSULES:
    emit_bone(name, IDENT, (x, (top + bot) * 0.5, 0.0), r, top - bot)

for name, cy, half, r in H_CAPSULES:
    emit_bone(name, X_ALIGNED, (0.0, cy, 0.0), r, 2 * half)

B('[node name="Joints" type="Node3D" parent="Box3DWorld"]')
B('')


def emit_spring():
    B('spring_enabled = true')
    B('spring_hertz = %.5g' % SPRING_HERTZ)
    B('spring_damping = %.5g' % SPRING_DAMPING)


for name, a, b, anchor, frame, cone, tlo, thi, fric in BALL:
    B('[node name="J_%s" type="Box3DBallJoint" parent="Box3DWorld/Joints"]' % name)
    B('transform = ' + xf(Z_UP if frame == "up" else Z_SIDE, (anchor[0], anchor[1], 0.0)))
    B('body_a = NodePath("../../Body/%s")' % a)
    B('body_b = NodePath("../../Body/%s")' % b)
    B('cone_limit_enabled = true')
    B('cone_angle = %.5g' % math.radians(cone))
    B('twist_limit_enabled = true')
    B('twist_lower = %.5g' % math.radians(tlo))
    B('twist_upper = %.5g' % math.radians(thi))
    emit_spring()
    B('friction_torque = %.5g' % (fric * FRICTION_BASE))
    B('')

for name, a, b, anchor, lo, hi, fric in HINGE:
    B('[node name="J_%s" type="Box3DHingeJoint" parent="Box3DWorld/Joints"]' % name)
    B('transform = ' + xf(Z_SIDE, (anchor[0], anchor[1], 0.0)))
    B('body_a = NodePath("../../Body/%s")' % a)
    B('body_b = NodePath("../../Body/%s")' % b)
    B('limit_enabled = true')
    B('lower_limit = %.5g' % math.radians(lo))
    B('upper_limit = %.5g' % math.radians(hi))
    # zero-speed motor with a torque cap = dry joint friction
    B('motor_enabled = true')
    B('max_motor_torque = %.5g' % (fric * FRICTION_BASE))
    emit_spring()
    B('')

header = '[gd_scene load_steps=%d format=3]' % (len(subres) + 2)
ext = '[ext_resource type="Script" path="res://samples/ragdoll.gd" id="1_rag"]'
out = header + '\n\n' + ext + '\n\n' + '\n\n'.join(subres) + '\n\n' + '\n'.join(nodes) + '\n'

_out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "samples", "ragdoll.tscn")
with open(_out, "w", encoding="utf-8") as f:
    f.write(out)
print("wrote samples/ragdoll.tscn: %d bones, %d joints" %
      (len(V_CAPSULES) + len(H_CAPSULES), len(BALL) + len(HINGE)))
