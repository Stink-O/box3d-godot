import os

lines = []
A = lines.append

def node(name, ntype, parent=None, instance=None):
    if parent is None:
        A('[node name="%s" type="%s"]' % (name, ntype))
    elif instance:
        A('[node name="%s" parent="%s" instance=%s]' % (name, parent, instance))
    else:
        A('[node name="%s" type="%s" parent="%s"]' % (name, ntype, parent))

def tf(x, y, z):
    A('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, %.4g, %.4g, %.4g)' % (x, y, z))

def mesh_child(parent, mesh_id, mat_id):
    A('[node name="MeshInstance3D" type="MeshInstance3D" parent="%s"]' % parent)
    A('mesh = SubResource("%s")' % mesh_id)
    A('material_override = SubResource("%s")' % mat_id)
    A('')

def marker(name, x, y, z):
    # A purely-visual pivot marker (no physics body, so nothing to collide with).
    node(name, "MeshInstance3D", "Box3DWorld")
    tf(x, y, z)
    A('mesh = SubResource("Pivot")')
    A('material_override = SubResource("StaticMat")')
    A('')

def body(name, x, y, z, body_type, mesh_id, mat_id, props=None):
    node(name, "Box3DBody", "Box3DWorld")
    tf(x, y, z)
    A('body_type = %d' % body_type)
    for p in (props or []):
        A(p)
    A('')
    mesh_child("Box3DWorld/%s" % name, mesh_id, mat_id)

def joint(name, jtype, x, y, z, a, b=None, props=None):
    node(name, jtype, "Box3DWorld")
    tf(x, y, z)
    A('body_a = NodePath("../%s")' % a)
    if b:
        A('body_b = NodePath("../%s")' % b)
    for p in (props or []):
        A(p)
    A('')

A('[gd_scene load_steps=11 format=3]')
A('')
A('[ext_resource type="Script" path="res://samples/joint_sample.gd" id="1_root"]')
A('')
A('[sub_resource type="BoxMesh" id="FloorMesh"]')
A('size = Vector3(40, 1, 40)')
A('')
A('[sub_resource type="BoxMesh" id="Cube04"]')
A('size = Vector3(0.4, 0.4, 0.4)')
A('')
A('[sub_resource type="BoxMesh" id="Cube1"]')
A('size = Vector3(1, 1, 1)')
A('')
A('[sub_resource type="BoxMesh" id="Bar"]')
A('size = Vector3(3, 0.3, 0.3)')
A('')
A('[sub_resource type="BoxMesh" id="Cube05"]')
A('size = Vector3(0.5, 0.5, 0.5)')
A('')
A('[sub_resource type="SphereMesh" id="Bob"]')
A('radius = 0.6')
A('height = 1.2')
A('')
A('[sub_resource type="SphereMesh" id="Pivot"]')
A('radius = 0.15')
A('height = 0.3')
A('')
A('[sub_resource type="StandardMaterial3D" id="FloorMat"]')
A('albedo_color = Color(0.2, 0.22, 0.26, 1)')
A('roughness = 0.55')
A('metallic = 0.1')
A('')
A('[sub_resource type="StandardMaterial3D" id="DynMat"]')
A('albedo_color = Color(0.87, 0.46, 0.19, 1)')
A('roughness = 0.4')
A('')
A('[sub_resource type="StandardMaterial3D" id="StaticMat"]')
A('albedo_color = Color(0.42, 0.44, 0.48, 1)')
A('roughness = 0.85')
A('')

# Root (world-only sample; the shell owns camera + lighting)
node("JointSampler", "Node3D")
A('script = ExtResource("1_root")')
A('')

node("Box3DWorld", "Box3DWorld", ".")
A('gravity = Vector3(0, -9.8, 0)')
A('')

# Floor
body("Floor", 0, -0.5, 0, 0, "FloorMesh", "FloorMat", ['box_size = Vector3(40, 1, 40)'])

# Hinge: an arm pinned at its left end to the world, swings down about Z.
body("HingeArm", -6.5, 7, 0, 2, "Bar", "DynMat", ['box_size = Vector3(3, 0.3, 0.3)'])
joint("HingeJoint", "Box3DHingeJoint", -8, 7, 0, "HingeArm")
marker("HingePivot", -8, 7, 0)

# Ball-joint pendulum: bob hangs from a world anchor, released horizontally.
body("PendulumBob", -1, 9, 0, 2, "Bob", "DynMat", ['shape_type = 1', 'sphere_radius = 0.6'])
joint("PendulumJoint", "Box3DBallJoint", -3, 9, 0, "PendulumBob")
marker("PendulumPivot", -3, 9, 0)

# Ball-joint chain hanging from a world anchor.
for i in range(5):
    body("ChainLink%d" % i, 2, 8.0 - i * 0.8, 0, 2, "Cube04", "DynMat", ['box_size = Vector3(0.4, 0.4, 0.4)'])
joint("ChainJoint0", "Box3DBallJoint", 2, 8.4, 0, "ChainLink0")
for i in range(1, 5):
    joint("ChainJoint%d" % i, "Box3DBallJoint", 2, 8.4 - i * 0.8, 0, "ChainLink%d" % i, "ChainLink%d" % (i - 1))
marker("ChainTop", 2, 8.4, 0)

# Motorized slider: box slides along X relative to a world anchor (driven by joints.gd).
body("SliderBox", 7, 4, 0, 2, "Cube1", "DynMat", ['box_size = Vector3(1, 1, 1)'])
joint("SliderJoint", "Box3DSliderJoint", 7, 4, 0, "SliderBox", None,
      ['limit_enabled = true', 'lower_limit = -3.0', 'upper_limit = 3.0',
       'motor_enabled = true', 'motor_speed = 3.0', 'max_motor_force = 300.0'])
marker("SliderAnchor", 7, 4, 0)

# Contact-event dropper: falls on the floor and fires body_entered.
body("Dropper", 0, 5, 4, 2, "Cube1", "DynMat", ['box_size = Vector3(1, 1, 1)', 'contact_monitor = true'])

_out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "samples", "joint_sampler.tscn")
os.makedirs(os.path.dirname(_out), exist_ok=True)
with open(_out, "w", encoding="utf-8") as f:
    f.write("\n".join(lines) + "\n")
print("wrote samples/joint_sampler.tscn")
