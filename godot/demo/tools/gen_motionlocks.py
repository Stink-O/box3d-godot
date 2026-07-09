import os

# Emits samples/motion_locks.tscn: an air-hockey table of plane-locked pucks and
# an abacus rail of line-locked beads. motion_locks.gd gives them a starting
# kick. Shows the Axis Lock properties (lock_linear_* / lock_angular_*).

TW, TD = 24.0, 14.0     # table width x depth
WALL_H = 1.2

subres = []
nodes = []
S = subres.append
B = nodes.append

S('[sub_resource type="StandardMaterial3D" id="FloorMat"]\n'
  'albedo_color = Color(0.16, 0.28, 0.34, 1)\nroughness = 0.35\nmetallic = 0.1')
S('[sub_resource type="StandardMaterial3D" id="WallMat"]\n'
  'albedo_color = Color(0.85, 0.9, 0.95, 1)\nroughness = 0.4')
S('[sub_resource type="CylinderMesh" id="PuckMesh"]\n'
  'top_radius = 0.6\nbottom_radius = 0.6\nheight = 0.3')
S('[sub_resource type="StandardMaterial3D" id="PuckMat"]\n'
  'albedo_color = Color(0.9, 0.3, 0.2, 1)\nroughness = 0.3\nmetallic = 0.2')
S('[sub_resource type="SphereMesh" id="BeadMesh"]\nradius = 0.45\nheight = 0.9')
S('[sub_resource type="StandardMaterial3D" id="BeadMat"]\n'
  'albedo_color = Color(0.35, 0.75, 0.5, 1)\nroughness = 0.35\nmetallic = 0.2')
S('[sub_resource type="BoxMesh" id="RailMesh"]\nsize = Vector3(20, 0.12, 0.12)')
S('[sub_resource type="StandardMaterial3D" id="RailMat"]\n'
  'albedo_color = Color(0.5, 0.52, 0.58, 1)\nroughness = 0.5\nmetallic = 0.5')
S('[sub_resource type="BoxMesh" id="StopMesh"]\nsize = Vector3(0.4, 1.0, 1.0)')


def fit_box(name, size, pos, mat, mesh_id=None):
    mid = mesh_id or ("M_" + name)
    if mesh_id is None:
        S('[sub_resource type="BoxMesh" id="%s"]\nsize = Vector3(%g, %g, %g)' % (mid, size[0], size[1], size[2]))
    B('[node name="%s" type="Box3DBody" parent="Box3DWorld"]' % name)
    B('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, %g, %g, %g)' % pos)
    B('body_type = 0')
    B('shape_type = 7')
    B('restitution = 0.9')
    B('friction = 0.05')
    B('')
    B('[node name="MeshInstance3D" type="MeshInstance3D" parent="Box3DWorld/%s"]' % name)
    B('mesh = SubResource("%s")' % mid)
    B('material_override = SubResource("%s")' % mat)
    B('')


def label(name, text, pos, color):
    B('[node name="%s" type="Label3D" parent="."]' % name)
    B('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, %g, %g, %g)' % pos)
    B('billboard = 1')
    B('text = "%s"' % text)
    B('font_size = 56')
    B('outline_size = 16')
    B('modulate = Color%s' % color)
    B('')


B('[node name="MotionLocks" type="Node3D"]')
B('script = ExtResource("1_ml")')
B('')
B('[node name="Box3DWorld" type="Box3DWorld" parent="."]')
B('gravity = Vector3(0, -9.8, 0)')
B('')

fit_box("Floor", (TW, 1, TD), (0, -0.5, 0), "FloorMat")
# Perimeter walls (bouncy).
fit_box("WallN", (TW + 0.6, WALL_H, 0.6), (0, WALL_H / 2, -TD / 2), "WallMat")
fit_box("WallS", (TW + 0.6, WALL_H, 0.6), (0, WALL_H / 2, TD / 2), "WallMat")
fit_box("WallE", (0.6, WALL_H, TD), (TW / 2, WALL_H / 2, 0), "WallMat")
fit_box("WallW", (0.6, WALL_H, TD), (-TW / 2, WALL_H / 2, 0), "WallMat")

# Plane-locked pucks (Axis Lock: freeze Y translation + X/Z rotation -> stays
# flat on the table and only slides/spins-about-Y).
B('[node name="Pucks" type="Node3D" parent="Box3DWorld"]')
B('')
spots = [(-7, -3), (-3, 2), (0, -2), (3, 3), (6, -3), (7, 2), (-5, 4), (2, -4)]
for i, (x, z) in enumerate(spots):
    B('[node name="Puck_%d" type="Box3DBody" parent="Box3DWorld/Pucks"]' % i)
    B('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, %g, 0.65, %g)' % (x, z))
    B('shape_type = 3')
    B('capsule_radius = 0.6')
    B('capsule_height = 0.3')
    B('restitution = 0.92')
    B('friction = 0.02')
    B('linear_damping = 0.05')
    B('lock_linear_y = true')
    B('lock_angular_x = true')
    B('lock_angular_z = true')
    B('')
    B('[node name="MeshInstance3D" type="MeshInstance3D" parent="Box3DWorld/Pucks/Puck_%d"]' % i)
    B('mesh = SubResource("PuckMesh")')
    B('material_override = SubResource("PuckMat")')
    B('')

# Abacus rail: a decorative rail + two end stops; beads are line-locked to X.
RAIL_Y = 3.2
B('[node name="Rail" type="Box3DBody" parent="Box3DWorld"]')
B('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, %g, 5.5)' % RAIL_Y)
B('body_type = 0')
B('box_size = Vector3(20, 0.12, 0.12)')
B('collision_layer = 0')  # visual only; beads are constrained by locks
B('collision_mask = 0')
B('')
B('[node name="MeshInstance3D" type="MeshInstance3D" parent="Box3DWorld/Rail"]')
B('mesh = SubResource("RailMesh")')
B('material_override = SubResource("RailMat")')
B('')
for name, sx in (("StopL", -10.2), ("StopR", 10.2)):
    B('[node name="%s" type="Box3DBody" parent="Box3DWorld"]' % name)
    B('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, %g, %g, 5.5)' % (sx, RAIL_Y))
    B('body_type = 0')
    B('box_size = Vector3(0.4, 1.0, 1.0)')
    B('restitution = 0.98')
    B('')
    B('[node name="MeshInstance3D" type="MeshInstance3D" parent="Box3DWorld/%s"]' % name)
    B('mesh = SubResource("StopMesh")')
    B('material_override = SubResource("RailMat")')
    B('')

B('[node name="Beads" type="Node3D" parent="Box3DWorld"]')
B('')
for i, x in enumerate((-6, -3.5, -1, 1.5, 4, 6.5)):
    B('[node name="Bead_%d" type="Box3DBody" parent="Box3DWorld/Beads"]' % i)
    B('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, %g, %g, 5.5)' % (x, RAIL_Y))
    B('shape_type = 1')
    B('sphere_radius = 0.45')
    B('restitution = 0.98')
    B('friction = 0.0')
    B('lock_linear_y = true')
    B('lock_linear_z = true')
    B('lock_angular_x = true')
    B('lock_angular_y = true')
    B('lock_angular_z = true')
    B('')
    B('[node name="MeshInstance3D" type="MeshInstance3D" parent="Box3DWorld/Beads/Bead_%d"]' % i)
    B('mesh = SubResource("BeadMesh")')
    B('material_override = SubResource("BeadMat")')
    B('')

label("LblPucks", "PLANE-LOCKED PUCKS", (0, 2.6, 0), "(1, 0.7, 0.6, 1)")
label("LblBeads", "RAIL: X-ONLY BEADS", (0, 4.4, 5.5), "(0.6, 0.95, 0.75, 1)")

header = '[gd_scene load_steps=%d format=3]' % (len(subres) + 2)
ext = '[ext_resource type="Script" path="res://samples/motion_locks.gd" id="1_ml"]'
out = header + '\n\n' + ext + '\n\n' + '\n\n'.join(subres) + '\n\n' + '\n'.join(nodes) + '\n'

_out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "samples", "motion_locks.tscn")
with open(_out, "w", encoding="utf-8") as f:
    f.write(out)
print("wrote samples/motion_locks.tscn")
