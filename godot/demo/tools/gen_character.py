import os
import math

# Emits samples/character.tscn: a Box3D PLAYGROUND for a Box3DCharacterBody.
# The Godot mover slides but doesn't step up, so elevation is a *flush* ramp
# (its low edge sits exactly at floor level, the body sunk into the floor) up to
# a raised platform. Walls give something to slide along. Scattered around the
# course are ordinary dynamic Box3DBody props (crates / barrels / balls) that
# character.gd shoves as it walks into them, so the capsule clearly reads as
# one more Box3D body sharing the world with the rest of the demo.

# Flush ramp geometry: tilt T about X, low top-edge at y=0 so there's no lip.
THETA = 0.28
T = 0.4          # ramp thickness
L = 8.0          # ramp length (along Z)
c = math.cos(THETA)
s = math.sin(THETA)
ramp_cy = (L / 2) * s - (T / 2) * c          # low top-edge lands at y=0
ramp_top_high = ramp_cy + (T / 2) * c + (L / 2) * s   # y of the high top-edge
ramp_high_z = 0.1 + (T / 2) * s - (L / 2) * c         # z of the high top-edge (Cz=0.1)

subres = []
nodes = []
S = subres.append
B = nodes.append

S('[sub_resource type="StandardMaterial3D" id="FloorMat"]\n'
  'albedo_color = Color(0.2, 0.22, 0.26, 1)\nroughness = 0.55\nmetallic = 0.1')
S('[sub_resource type="StandardMaterial3D" id="BlockMat"]\n'
  'albedo_color = Color(0.4, 0.44, 0.5, 1)\nroughness = 0.7')
S('[sub_resource type="StandardMaterial3D" id="RampMat"]\n'
  'albedo_color = Color(0.5, 0.42, 0.32, 1)\nroughness = 0.7')
S('[sub_resource type="StandardMaterial3D" id="CharMat"]\n'
  'albedo_color = Color(0.9, 0.5, 0.2, 1)\nroughness = 0.4\nmetallic = 0.1')
S('[sub_resource type="StandardMaterial3D" id="CrateMat"]\n'
  'albedo_color = Color(0.72, 0.5, 0.24, 1)\nroughness = 0.85')
S('[sub_resource type="StandardMaterial3D" id="BarrelMat"]\n'
  'albedo_color = Color(0.75, 0.16, 0.12, 1)\nroughness = 0.45\nmetallic = 0.25')
S('[sub_resource type="StandardMaterial3D" id="BallMat"]\n'
  'albedo_color = Color(0.25, 0.65, 0.85, 1)\nroughness = 0.3\nmetallic = 0.2')


def fit_box(name, size, pos, mat):
    # Static geometry (course itself): FIT_MESH box collider sized from its
    # child mesh. body_type defaults to DYNAMIC, so these all say STATIC.
    mid = "M_" + name
    S('[sub_resource type="BoxMesh" id="%s"]\nsize = Vector3(%g, %g, %g)' % (mid, size[0], size[1], size[2]))
    B('[node name="%s" type="Box3DBody" parent="Box3DWorld"]' % name)
    B('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, %g, %g, %g)' % pos)
    B('body_type = 0')
    B('shape_type = 7')  # Fit Mesh: collider sized from the child mesh
    B('')
    B('[node name="MeshInstance3D" type="MeshInstance3D" parent="Box3DWorld/%s"]' % name)
    B('mesh = SubResource("%s")' % mid)
    B('material_override = SubResource("%s")' % mat)
    B('')


def add_crate(name, size, pos):
    # A dynamic box prop (body_type defaults to DYNAMIC) the character can
    # shove — see character.gd's _push_dynamics().
    mid = "M_" + name
    S('[sub_resource type="BoxMesh" id="%s"]\nsize = Vector3(%g, %g, %g)' % (mid, size, size, size))
    B('[node name="%s" type="Box3DBody" parent="Box3DWorld"]' % name)
    B('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, %g, %g, %g)' % pos)
    B('box_size = Vector3(%g, %g, %g)' % (size, size, size))
    B('friction = 0.7')
    B('')
    B('[node name="MeshInstance3D" type="MeshInstance3D" parent="Box3DWorld/%s"]' % name)
    B('mesh = SubResource("%s")' % mid)
    B('material_override = SubResource("CrateMat")')
    B('')


def add_barrel(name, radius, height, pos):
    # A dynamic upright cylinder (body_type defaults to DYNAMIC).
    mid = "M_" + name
    S('[sub_resource type="CylinderMesh" id="%s"]\ntop_radius = %g\nbottom_radius = %g\nheight = %g'
      % (mid, radius, radius, height))
    B('[node name="%s" type="Box3DBody" parent="Box3DWorld"]' % name)
    B('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, %g, %g, %g)' % pos)
    B('shape_type = 3')  # CYLINDER
    B('capsule_radius = %g' % radius)
    B('capsule_height = %g' % height)
    B('friction = 0.5')
    B('')
    B('[node name="MeshInstance3D" type="MeshInstance3D" parent="Box3DWorld/%s"]' % name)
    B('mesh = SubResource("%s")' % mid)
    B('material_override = SubResource("BarrelMat")')
    B('')


def add_ball(name, radius, pos):
    # A dynamic sphere (body_type defaults to DYNAMIC) — light, rolls easily
    # when the character walks into it or a shot ball (F) clips it.
    mid = "M_" + name
    S('[sub_resource type="SphereMesh" id="%s"]\nradius = %g\nheight = %g' % (mid, radius, radius * 2))
    B('[node name="%s" type="Box3DBody" parent="Box3DWorld"]' % name)
    B('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, %g, %g, %g)' % pos)
    B('shape_type = 1')  # SPHERE
    B('sphere_radius = %g' % radius)
    B('restitution = 0.4')
    B('')
    B('[node name="MeshInstance3D" type="MeshInstance3D" parent="Box3DWorld/%s"]' % name)
    B('mesh = SubResource("%s")' % mid)
    B('material_override = SubResource("BallMat")')
    B('')


def look_at_transform(pos, target, up=(0.0, 1.0, 0.0)):
    # Build a Godot-style Transform3D (column-major basis + origin) whose local
    # -Z axis points from pos toward target, matching Node3D.look_at().
    def sub(a, b):
        return (a[0] - b[0], a[1] - b[1], a[2] - b[2])

    def length(v):
        return math.sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2])

    def norm(v):
        l = length(v)
        return (v[0] / l, v[1] / l, v[2] / l)

    def cross(a, b):
        return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])

    z = norm(sub(pos, target))       # backward (camera looks down -z)
    x = norm(cross(up, z))
    y = cross(z, x)
    return 'Transform3D(%.5g, %.5g, %.5g, %.5g, %.5g, %.5g, %.5g, %.5g, %.5g, %.6g, %.6g, %.6g)' % (
        x[0], x[1], x[2], y[0], y[1], y[2], z[0], z[1], z[2], pos[0], pos[1], pos[2])


B('[node name="Character" type="Node3D"]')
B('script = ExtResource("1_char")')
B('')
B('[node name="Box3DWorld" type="Box3DWorld" parent="."]')
B('gravity = Vector3(0, -9.8, 0)')
B('')

fit_box("Floor", (44, 1, 44), (0, -0.5, 0), "FloorMat")

# Raised platform whose front face meets the ramp's high edge; top is flush
# with the ramp top so the character walks straight on. It rests ON the floor
# (bottom at y=0) — sinking it deep makes the slide-mover churn.
plat_h = ramp_top_high
plat_cz = ramp_high_z - 4.0
fit_box("Platform", (9, plat_h, 8), (0, plat_h / 2.0, plat_cz), "BlockMat")

# Two low walls on the flat area to slide along.
fit_box("WallL", (0.4, 1.6, 8), (-3.4, 0.8, 5.0), "BlockMat")
fit_box("WallR", (0.4, 1.6, 8), (3.4, 0.8, 5.0), "BlockMat")

# The flush ramp (tilted, so box_size not Fit Mesh).
S('[sub_resource type="BoxMesh" id="RampMesh"]\nsize = Vector3(6, %g, %g)' % (T, L))
B('[node name="Ramp" type="Box3DBody" parent="Box3DWorld"]')
B('transform = Transform3D(1, 0, 0, 0, %.5g, %.5g, 0, %.5g, %.5g, 0, %.5g, 0.1)' % (c, s, -s, c, ramp_cy))
B('body_type = 0')
B('box_size = Vector3(6, %g, %g)' % (T, L))
B('')
B('[node name="MeshInstance3D" type="MeshInstance3D" parent="Box3DWorld/Ramp"]')
B('mesh = SubResource("RampMesh")')
B('material_override = SubResource("RampMat")')
B('')

# --- Box3D playground props: dynamic bodies the character shoves around. ---

# A loose crate blockade squarely in the corridor between the walls — walk
# straight into it to push through, or squeeze around the sides near a wall.
add_crate("Crate1", 0.8, (-1.1, 0.4, 6.3))
add_crate("Crate2", 0.8, (0.0, 0.4, 6.6))
add_crate("Crate3", 0.8, (1.1, 0.4, 6.3))

# A stray barrel on the flat ground before the ramp (the ramp's low edge is
# at z ~= 4.0, so keep this comfortably south of it, still inside the walls).
add_barrel("Barrel1", 0.45, 1.0, (-2.3, 0.5, 7.8))

# A barrel and a ball waiting up on the platform, so the course keeps giving
# the character (and F-shot balls) something dynamic to bump after the climb.
add_barrel("Barrel2", 0.45, 1.0, (2.2, plat_h + 0.5, plat_cz - 1.5))
add_ball("Ball1", 0.35, (-2.0, plat_h + 0.35, plat_cz - 3.0))

# A ball loitering beside the corridor, an easy target for a shot (F) or a
# clipping shoulder-check on the way past.
add_ball("Ball2", 0.35, (2.5, 0.35, 7.5))

# Character capsule.
S('[sub_resource type="CapsuleMesh" id="CharMesh"]\nradius = 0.4\nheight = 1.8')
B('[node name="Character" type="Box3DCharacterBody" parent="Box3DWorld"]')
B('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 1.1, 9)')
B('radius = 0.4')
B('height = 1.8')
B('')
B('[node name="MeshInstance3D" type="MeshInstance3D" parent="Box3DWorld/Character"]')
B('mesh = SubResource("CharMesh")')
B('material_override = SubResource("CharMat")')
B('')

# The establishing view of the playground is set by character.gd's
# camera_home / camera_look_at exports (read by the shell), not a marker node.

# Onscreen control hint.
B('[node name="Hint" type="Label3D" parent="."]')
B('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 4.6, 8.6)')
B('billboard = 1')
B('text = "WASD + Space: walk & jump (release right-mouse to steer)\\n'
  'Walk into the crates to shove them around — F: shoot a ball at the barrels"')
B('font_size = 40')
B('outline_size = 12')
B('modulate = Color(1, 0.92, 0.75, 1)')
B('')

header = '[gd_scene load_steps=%d format=3]' % (len(subres) + 2)
ext = '[ext_resource type="Script" path="res://samples/character.gd" id="1_char"]'
out = header + '\n\n' + ext + '\n\n' + '\n\n'.join(subres) + '\n\n' + '\n'.join(nodes) + '\n'

_out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "samples", "character.tscn")
with open(_out, "w", encoding="utf-8") as f:
    f.write(out)
print("wrote samples/character.tscn (ramp high top y=%.2f z=%.2f)" % (ramp_top_high, ramp_high_z))
