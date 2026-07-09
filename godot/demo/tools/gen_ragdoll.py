import os
import math

# Emits samples/ragdoll.tscn: a clean, well-proportioned humanoid ragdoll built
# by hand out of Box3D bodies -- a sphere head, box chest + pelvis, and capsule
# limbs -- linked by ball joints (neck, waist, shoulders, hips) and hinge joints
# (elbows, knees). Unlike the old human.c port, EVERY bone collides with every
# other one (same layer/mask); the joints keep collide_connected = false (the
# default) so directly-jointed bones don't fight at the shared anchor, while
# non-adjacent bones (arm vs torso, thigh vs thigh) can't pass through each
# other. That self-collision is what stops it folding into a tangled clump.
#
# The skeleton is authored standing (all limbs vertical) then the whole thing is
# rotated about X by TILT_DEG so it can't land on its feet and balance -- it
# drops and sprawls into a believable heap. DROP is how far its lowest point
# starts above the floor.

TILT_DEG = 20.0    # a clear forward lean: reads as a figure mid-fall, and topples deterministically
DROP = 0.2         # a small drop; the lean + a shove crumple it on load

# --- skeleton in "feet near y=0", standing space ---
# Parts overlap at the joints so it reads as ONE connected figure, not floating
# pieces (jointed pairs don't collide, so overlap is free).
# Capsule limbs: (name, top_xyz, bottom_xyz, radius, material)
CAPSULES = [
    ("thigh_l",     (-0.10, 0.94, 0.0), (-0.10, 0.50, 0.0), 0.09, "PantMat"),
    ("thigh_r",     ( 0.10, 0.94, 0.0), ( 0.10, 0.50, 0.0), 0.09, "PantMat"),
    ("shin_l",      (-0.10, 0.52, 0.0), (-0.10, 0.10, 0.0), 0.072, "PantMat"),
    ("shin_r",      ( 0.10, 0.52, 0.0), ( 0.10, 0.10, 0.0), 0.072, "PantMat"),
    ("upper_arm_l", (-0.23, 1.58, 0.0), (-0.23, 1.19, 0.0), 0.06, "ShirtMat"),
    ("upper_arm_r", ( 0.23, 1.58, 0.0), ( 0.23, 1.19, 0.0), 0.06, "ShirtMat"),
    ("lower_arm_l", (-0.23, 1.21, 0.0), (-0.23, 0.84, 0.0), 0.052, "SkinMat"),
    ("lower_arm_r", ( 0.23, 1.21, 0.0), ( 0.23, 0.84, 0.0), 0.052, "SkinMat"),
]
# Boxes: (name, center_xyz, size_xyz, material)
BOXES = [
    ("pelvis", (0.0, 1.00, 0.0), (0.30, 0.26, 0.20), "PantMat"),
    ("chest",  (0.0, 1.40, 0.0), (0.34, 0.56, 0.22), "ShirtMat"),
]
# Sphere: (name, center_xyz, radius, material)
SPHERES = [
    ("head", (0.0, 1.79, 0.0), 0.15, "SkinMat"),
]
# Ball joints: (name, body_a, body_b, anchor_xyz, (cone_deg, twist_lo_deg, twist_hi_deg))
BALL = [
    ("waist",      "pelvis", "chest",       (0.0,   1.13, 0.0), (30.0, -40.0, 40.0)),
    ("neck",       "chest",  "head",        (0.0,   1.67, 0.0), (40.0, -45.0, 45.0)),
    ("shoulder_l", "chest",  "upper_arm_l", (-0.23, 1.58, 0.0), (85.0, -60.0, 60.0)),
    ("shoulder_r", "chest",  "upper_arm_r", (0.23,  1.58, 0.0), (85.0, -60.0, 60.0)),
    ("hip_l",      "pelvis", "thigh_l",     (-0.10, 0.93, 0.0), (70.0, -40.0, 40.0)),
    ("hip_r",      "pelvis", "thigh_r",     (0.10,  0.93, 0.0), (70.0, -40.0, 40.0)),
]
# Hinge joints: (name, body_a, body_b, anchor_xyz, (lower_rad, upper_rad))
HINGE = [
    ("elbow_l", "upper_arm_l", "lower_arm_l", (-0.23, 1.20, 0.0), (-2.4, 2.4)),
    ("elbow_r", "upper_arm_r", "lower_arm_r", (0.23,  1.20, 0.0), (-2.4, 2.4)),
    ("knee_l",  "thigh_l",     "shin_l",      (-0.10, 0.51, 0.0), (-2.4, 2.4)),
    ("knee_r",  "thigh_r",     "shin_r",      (0.10,  0.51, 0.0), (-2.4, 2.4)),
]

TH = math.radians(TILT_DEG)
COS, SIN = math.cos(TH), math.sin(TH)
PIVOT = (0.0, 1.0, 0.0)  # tilt around roughly the body's centre

# Body/ball basis = rotation about X by TH; hinge basis = that * (Z-col = world X).
BODY_COLS = ((1.0, 0.0, 0.0), (0.0, COS, SIN), (0.0, -SIN, COS))
HINGE_COLS = ((0.0, SIN, -COS), (0.0, COS, SIN), (1.0, 0.0, 0.0))


def _rot(p):
    y = p[1] - PIVOT[1]
    z = p[2] - PIVOT[2]
    return (p[0], COS * y - SIN * z + PIVOT[1], SIN * y + COS * z + PIVOT[2])


# Find the lowest rotated point among all defining points, then offset so it
# starts DROP above the floor.
_pts = []
for _n, t, b, _r, _m in CAPSULES:
    _pts += [_rot(t), _rot(b)]
for _n, c, s, _m in BOXES:
    _pts.append(_rot(c))
for _n, c, _r, _m in SPHERES:
    _pts.append(_rot(c))
YOFF = DROP - min(p[1] for p in _pts)


def place(p):
    r = _rot(p)
    return (r[0], r[1] + YOFF, r[2])


def xf(cols, o):
    xa, ya, za = cols
    v = [xa[0], xa[1], xa[2], ya[0], ya[1], ya[2], za[0], za[1], za[2], o[0], o[1], o[2]]
    return "Transform3D(" + ", ".join("%.6g" % x for x in v) + ")"


subres = []
nodes = []
S = subres.append
B = nodes.append

S('[sub_resource type="BoxMesh" id="FloorMesh"]\nsize = Vector3(40, 1, 40)')
S('[sub_resource type="StandardMaterial3D" id="FloorMat"]\n'
  'albedo_color = Color(0.2, 0.22, 0.26, 1)\nroughness = 0.55\nmetallic = 0.1')
S('[sub_resource type="StandardMaterial3D" id="SkinMat"]\n'
  'albedo_color = Color(0.9, 0.76, 0.62, 1)\nroughness = 0.5')
S('[sub_resource type="StandardMaterial3D" id="ShirtMat"]\n'
  'albedo_color = Color(0.28, 0.72, 0.68, 1)\nroughness = 0.5')
S('[sub_resource type="StandardMaterial3D" id="PantMat"]\n'
  'albedo_color = Color(0.25, 0.5, 0.85, 1)\nroughness = 0.5')

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


def emit_common():
    # every bone: dynamic, collides with the floor AND all other bones
    B('density = 3.0')
    B('friction = 0.5')
    B('collision_layer = 1')
    B('collision_mask = 1')


for name, top, bottom, r, mat in CAPSULES:
    mid = ((top[0] + bottom[0]) * 0.5, (top[1] + bottom[1]) * 0.5, (top[2] + bottom[2]) * 0.5)
    seg = math.dist(top, bottom)
    height = seg + 2 * r  # capsule height is total (segment + 2 caps)
    B('[node name="%s" type="Box3DBody" parent="Box3DWorld/Body"]' % name)
    B('transform = ' + xf(BODY_COLS, place(mid)))
    B('shape_type = 2')
    B('capsule_radius = %.5g' % r)
    B('capsule_height = %.5g' % height)
    emit_common()
    B('')
    S('[sub_resource type="CapsuleMesh" id="Mesh_%s"]\nradius = %.5g\nheight = %.5g' % (name, r, height))
    B('[node name="MeshInstance3D" type="MeshInstance3D" parent="Box3DWorld/Body/%s"]' % name)
    B('mesh = SubResource("Mesh_%s")' % name)
    B('material_override = SubResource("%s")' % mat)
    B('')

for name, center, size, mat in BOXES:
    B('[node name="%s" type="Box3DBody" parent="Box3DWorld/Body"]' % name)
    B('transform = ' + xf(BODY_COLS, place(center)))
    B('box_size = Vector3(%.5g, %.5g, %.5g)' % size)
    emit_common()
    B('')
    S('[sub_resource type="BoxMesh" id="Mesh_%s"]\nsize = Vector3(%.5g, %.5g, %.5g)' % (name, size[0], size[1], size[2]))
    B('[node name="MeshInstance3D" type="MeshInstance3D" parent="Box3DWorld/Body/%s"]' % name)
    B('mesh = SubResource("Mesh_%s")' % name)
    B('material_override = SubResource("%s")' % mat)
    B('')

for name, center, r, mat in SPHERES:
    B('[node name="%s" type="Box3DBody" parent="Box3DWorld/Body"]' % name)
    B('transform = ' + xf(BODY_COLS, place(center)))
    B('shape_type = 1')
    B('sphere_radius = %.5g' % r)
    emit_common()
    B('')
    S('[sub_resource type="SphereMesh" id="Mesh_%s"]\nradius = %.5g\nheight = %.5g' % (name, r, 2 * r))
    B('[node name="MeshInstance3D" type="MeshInstance3D" parent="Box3DWorld/Body/%s"]' % name)
    B('mesh = SubResource("Mesh_%s")' % name)
    B('material_override = SubResource("%s")' % mat)
    B('')

B('[node name="Joints" type="Node3D" parent="Box3DWorld"]')
B('')

# Ball joints: the cone limits RELATIVE swing from the spawn pose (frameA/frameB
# coincide at build), so any consistent frame works -- use the body tilt.
for name, a, b, anchor, params in BALL:
    cone, tlo, thi = params
    B('[node name="J_%s" type="Box3DBallJoint" parent="Box3DWorld/Joints"]' % name)
    B('transform = ' + xf(BODY_COLS, place(anchor)))
    B('body_a = NodePath("../../Body/%s")' % a)
    B('body_b = NodePath("../../Body/%s")' % b)
    B('cone_limit_enabled = true')
    B('cone_angle = %.5g' % math.radians(cone))
    B('twist_limit_enabled = true')
    B('twist_lower = %.5g' % math.radians(tlo))
    B('twist_upper = %.5g' % math.radians(thi))
    B('')

# Hinge joints: frame local Z is the bend axis (world X here, preserved through
# an X-tilt), so elbows/knees bend cleanly like a hinge.
for name, a, b, anchor, params in HINGE:
    lower, upper = params
    B('[node name="J_%s" type="Box3DHingeJoint" parent="Box3DWorld/Joints"]' % name)
    B('transform = ' + xf(HINGE_COLS, place(anchor)))
    B('body_a = NodePath("../../Body/%s")' % a)
    B('body_b = NodePath("../../Body/%s")' % b)
    B('limit_enabled = true')
    B('lower_limit = %.5g' % lower)
    B('upper_limit = %.5g' % upper)
    B('')

header = '[gd_scene load_steps=%d format=3]' % (len(subres) + 2)
ext = '[ext_resource type="Script" path="res://samples/ragdoll.gd" id="1_rag"]'
out = header + '\n\n' + ext + '\n\n' + '\n\n'.join(subres) + '\n\n' + '\n'.join(nodes) + '\n'

_out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "samples", "ragdoll.tscn")
with open(_out, "w", encoding="utf-8") as f:
    f.write(out)
print("wrote samples/ragdoll.tscn: %d bones, %d joints, tilt=%g deg" %
      (len(CAPSULES) + len(BOXES) + len(SPHERES), len(BALL) + len(HINGE), TILT_DEG))
