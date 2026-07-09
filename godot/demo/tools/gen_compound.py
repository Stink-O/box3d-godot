import os

# Emits samples/compound.tscn: several bodies each built from multiple
# Box3DCollisionShape children (a table, a cross, a dumbbell, a jack) — knock
# them over by shooting (F) or dragging. Shows compound bodies: a body with
# Box3DCollisionShape children uses those instead of its own shape_type.

subres = []
nodes = []
S = subres.append
B = nodes.append
_mesh_seq = [0]

# Local rotations to aim a Y-aligned capsule along X or Z.
ROT_X = "0, -1, 0, 1, 0, 0, 0, 0, 1"   # local Y -> world X
ROT_Z = "1, 0, 0, 0, 0, 1, 0, -1, 0"   # local Y -> world Z
ROT_Y = "1, 0, 0, 0, 1, 0, 0, 0, 1"

S('[sub_resource type="StandardMaterial3D" id="FloorMat"]\n'
  'albedo_color = Color(0.2, 0.22, 0.26, 1)\nroughness = 0.55\nmetallic = 0.1')
S('[sub_resource type="StandardMaterial3D" id="WoodMat"]\n'
  'albedo_color = Color(0.6, 0.42, 0.26, 1)\nroughness = 0.6')
S('[sub_resource type="StandardMaterial3D" id="RedMat"]\n'
  'albedo_color = Color(0.82, 0.3, 0.28, 1)\nroughness = 0.5')
S('[sub_resource type="StandardMaterial3D" id="MetalMat"]\n'
  'albedo_color = Color(0.55, 0.6, 0.7, 1)\nroughness = 0.35\nmetallic = 0.5')


def mesh_box(size):
    mid = "Msh_%d" % _mesh_seq[0]; _mesh_seq[0] += 1
    S('[sub_resource type="BoxMesh" id="%s"]\nsize = Vector3(%g, %g, %g)' % (mid, size[0], size[1], size[2]))
    return mid


def mesh_sphere(r):
    mid = "Msh_%d" % _mesh_seq[0]; _mesh_seq[0] += 1
    S('[sub_resource type="SphereMesh" id="%s"]\nradius = %g\nheight = %g' % (mid, r, 2 * r))
    return mid


def mesh_capsule(r, h):
    mid = "Msh_%d" % _mesh_seq[0]; _mesh_seq[0] += 1
    S('[sub_resource type="CapsuleMesh" id="%s"]\nradius = %g\nheight = %g' % (mid, r, h))
    return mid


def body(name, pos):
    B('[node name="%s" type="Box3DBody" parent="Box3DWorld/Furniture"]' % name)
    B('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, %g, %g, %g)' % pos)
    B('')


def part(body_name, idx, stype, params, xform, mesh_id, mat):
    base = "Box3DWorld/Furniture/%s" % body_name
    B('[node name="S%d" type="Box3DCollisionShape" parent="%s"]' % (idx, base))
    B('transform = Transform3D(%s)' % xform)
    B('shape_type = %d' % stype)
    for k, v in params:
        B('%s = %s' % (k, v))
    B('')
    B('[node name="M%d" type="MeshInstance3D" parent="%s"]' % (idx, base))
    B('transform = Transform3D(%s)' % xform)
    B('mesh = SubResource("%s")' % mesh_id)
    B('material_override = SubResource("%s")' % mat)
    B('')


def xf(rot, p):
    return "%s, %g, %g, %g" % (rot, p[0], p[1], p[2])


B('[node name="Compound" type="Node3D"]')
B('')
B('[node name="Box3DWorld" type="Box3DWorld" parent="."]')
B('gravity = Vector3(0, -9.8, 0)')
B('')
B('[node name="Floor" type="Box3DBody" parent="Box3DWorld"]')
B('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, -0.5, 0)')
B('body_type = 0')
B('shape_type = 7')
B('')
mfloor = mesh_box((30, 1, 30))
B('[node name="MeshInstance3D" type="MeshInstance3D" parent="Box3DWorld/Floor"]')
B('mesh = SubResource("%s")' % mfloor)
B('material_override = SubResource("FloorMat")')
B('')
B('[node name="Furniture" type="Node3D" parent="Box3DWorld"]')
B('')

# --- Table: 4 legs + a top ---
body("Table", (-6, 0, 0))
i = 0
for (lx, lz) in ((-0.85, -0.85), (0.85, -0.85), (-0.85, 0.85), (0.85, 0.85)):
    part("Table", i, 0, [("box_size", "Vector3(0.25, 1.0, 0.25)")], xf(ROT_Y, (lx, 0.5, lz)), mesh_box((0.25, 1.0, 0.25)), "WoodMat")
    i += 1
part("Table", i, 0, [("box_size", "Vector3(2.2, 0.25, 2.2)")], xf(ROT_Y, (0, 1.12, 0)), mesh_box((2.2, 0.25, 2.2)), "WoodMat")

# --- Cross: a horizontal bar + a vertical bar (a plus sign) ---
body("Cross", (-2, 0, 0))
part("Cross", 0, 0, [("box_size", "Vector3(2.2, 0.45, 0.45)")], xf(ROT_Y, (0, 1.1, 0)), mesh_box((2.2, 0.45, 0.45)), "RedMat")
part("Cross", 1, 0, [("box_size", "Vector3(0.45, 2.2, 0.45)")], xf(ROT_Y, (0, 1.1, 0)), mesh_box((0.45, 2.2, 0.45)), "RedMat")

# --- Dumbbell: a capsule bar (along X) with a sphere on each end ---
body("Dumbbell", (2, 0, 0))
part("Dumbbell", 0, 2, [("capsule_radius", "0.16"), ("capsule_height", "2.0")], xf(ROT_X, (0, 0.5, 0)), mesh_capsule(0.16, 2.0), "MetalMat")
part("Dumbbell", 1, 1, [("sphere_radius", "0.45")], xf(ROT_Y, (-1.1, 0.5, 0)), mesh_sphere(0.45), "MetalMat")
part("Dumbbell", 2, 1, [("sphere_radius", "0.45")], xf(ROT_Y, (1.1, 0.5, 0)), mesh_sphere(0.45), "MetalMat")

# --- Jack: three capsules along X, Y, Z through the centre ---
body("Jack", (6, 0, 0))
part("Jack", 0, 2, [("capsule_radius", "0.13"), ("capsule_height", "1.7")], xf(ROT_X, (0, 0.85, 0)), mesh_capsule(0.13, 1.7), "MetalMat")
part("Jack", 1, 2, [("capsule_radius", "0.13"), ("capsule_height", "1.7")], xf(ROT_Y, (0, 0.85, 0)), mesh_capsule(0.13, 1.7), "MetalMat")
part("Jack", 2, 2, [("capsule_radius", "0.13"), ("capsule_height", "1.7")], xf(ROT_Z, (0, 0.85, 0)), mesh_capsule(0.13, 1.7), "RedMat")

header = '[gd_scene load_steps=%d format=3]' % (len(subres) + 1)
out = header + '\n\n' + '\n\n'.join(subres) + '\n\n' + '\n'.join(nodes) + '\n'

_out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "samples", "compound.tscn")
with open(_out, "w", encoding="utf-8") as f:
    f.write(out)
print("wrote samples/compound.tscn")
