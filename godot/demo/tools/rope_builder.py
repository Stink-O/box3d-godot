import math

# Shared "real rope" builder used by gen_wrecking.py and gen_cradle.py.
#
# Both samples used to fake their rope/chain as a single stretched-cylinder
# MeshInstance3D repositioned every frame by script (wrecking.gd / cradle.gd),
# with all the actual physics done by one Box3DDistanceJoint straight from the
# world anchor to the hanging ball. That looked broken (a rigid cylinder that
# doesn't bend) and wasn't really a rope at all.
#
# build_rope() instead emits a real jointed rope: a handful of small dynamic
# capsule Box3DBody "links" laid out in a straight line between two world
# points, pinned end-to-end with Box3DBallJoint, running from a fixed world
# anchor (top) down to a caller-supplied body (the wrecking ball / a cradle
# ball). The links are plane-locked (lock_linear_z + lock_angular_x/y) the
# same way the samples already lock their balls, so bending stays confined to
# the z=0 swing plane. They don't collide with anything (collision_mask = 0):
# the old fake rope had no collision presence either (it was a bare
# MeshInstance3D), so this preserves that behaviour while adding real mass +
# joints instead of a per-frame-repositioned mesh.


def _normalize(v):
    n = math.sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2])
    return v[0] / n, v[1] / n, v[2] / n


def _cross(a, b):
    return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])


def _basis_from_ydir(d):
    # Orthonormal basis (columns x, y, z) with the y column aligned to unit
    # vector d, so a capsule's long axis (local Y) points along the rope.
    ref = (0.0, 0.0, 1.0) if abs(d[2]) < 0.9 else (1.0, 0.0, 0.0)
    x_axis = _normalize(_cross(ref, d))
    z_axis = _cross(x_axis, d)
    return x_axis, d, z_axis


def rope_link_assets(S, mesh_id, mat_id, radius, color):
    """Emit the shared capsule mesh + material sub_resources for one rope's
    links. Call once per distinct rope "look" (ids must be unique in the
    scene); build_rope() can be called multiple times reusing the same ids
    (e.g. the cradle's five strings all share one mesh/material)."""
    S('[sub_resource type="CapsuleMesh" id="%s"]\nradius = %.4g\nheight = %.4g' % (mesh_id, radius, 4 * radius))
    S('[sub_resource type="StandardMaterial3D" id="%s"]\n'
      'albedo_color = Color(%g, %g, %g, %g)\nroughness = 0.6\nmetallic = 0.35' % ((mat_id,) + tuple(color)))


def build_rope(B, parent, name, anchor, end, end_body_path, num_links,
               mesh_id, mat_id, radius=0.05, density=0.4, friction=0.3):
    """
    Emit a chain of `num_links` small capsule Box3DBody links + Box3DBallJoints
    running in a straight line from world point `anchor` to world point `end`:

        world anchor -> Link_0 -> Link_1 -> ... -> Link_{N-1} -> end_body_path

    parent:         NodePath the rope's container node is created under (e.g.
                    "Box3DWorld").
    name:           unique node name for this rope's container; links/joints
                    become "<parent>/<name>/Link_i" and ".../Joint_i".
    anchor, end:    world-space (x, y, z) tuples — the fixed top anchor and the
                    body's attachment point (e.g. the ball's initial center).
    end_body_path:  NodePath, relative to "<parent>/<name>", of the body the
                    last link pins to (e.g. "../Ball" or "../Balls/Ball_3").
    num_links:      number of dynamic link bodies between anchor and end.
    mesh_id/mat_id: sub_resource ids from a prior rope_link_assets() call.
    density:        tune this relative to the end body's mass -- a very heavy
                    tip (e.g. a dense wrecking ball) on very light links makes
                    an extreme mass-ratio joint at the last pin, which the
                    iterative solver can't hold taut (it stretches badly,
                    independent of substep_count). Keeping the whole rope's
                    mass at roughly 5-10% of the end body's mass keeps it taut.
    """
    ax, ay, az = anchor
    ex, ey, ez = end
    dx, dy, dz = ex - ax, ey - ay, ez - az
    length = math.sqrt(dx * dx + dy * dy + dz * dz)
    dirv = (dx / length, dy / length, dz / length)
    seg_len = length / num_links
    xa, ya, za = _basis_from_ydir(dirv)
    rot = '%.5g, %.5g, %.5g, %.5g, %.5g, %.5g, %.5g, %.5g, %.5g' % (
        xa[0], xa[1], xa[2], ya[0], ya[1], ya[2], za[0], za[1], za[2])

    def point(t):
        return ax + dirv[0] * t, ay + dirv[1] * t, az + dirv[2] * t

    container = "%s/%s" % (parent, name)
    B('[node name="%s" type="Node3D" parent="%s"]' % (name, parent))
    B('')

    cap_len = seg_len * 0.85  # a bit short of the full segment so caps don't jam at the joints
    for i in range(num_links):
        cx, cy, cz = point(seg_len * (i + 0.5))
        B('[node name="Link_%d" type="Box3DBody" parent="%s"]' % (i, container))
        B('transform = Transform3D(%s, %.5g, %.5g, %.5g)' % (rot, cx, cy, cz))
        B('shape_type = 2')
        B('capsule_radius = %.4g' % radius)
        B('capsule_height = %.4g' % cap_len)
        B('density = %.4g' % density)
        B('friction = %.4g' % friction)
        B('collision_layer = 4')
        B('collision_mask = 0')
        B('lock_linear_z = true')
        B('lock_angular_x = true')
        B('lock_angular_y = true')
        B('')
        B('[node name="MeshInstance3D" type="MeshInstance3D" parent="%s/Link_%d"]' % (container, i))
        B('mesh = SubResource("%s")' % mesh_id)
        B('material_override = SubResource("%s")' % mat_id)
        B('')

    # Joints: world anchor -> Link_0 -> ... -> Link_{N-1} -> end_body_path.
    # NodePaths resolve relative to the joint node itself (Box3DJoint calls
    # get_node_or_null() on `this`), and the joint is a *sibling* of the links
    # (both are direct children of the container) -- so reaching a sibling
    # link needs "../Link_i", and end_body_path (already relative to the
    # container, e.g. "../Ball") needs one more "../" on top of that.
    for i in range(num_links + 1):
        px, py, pz = point(seg_len * i)
        B('[node name="Joint_%d" type="Box3DBallJoint" parent="%s"]' % (i, container))
        B('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, %.5g, %.5g, %.5g)' % (px, py, pz))
        if i == 0:
            B('body_a = NodePath("../Link_0")')
        elif i == num_links:
            B('body_a = NodePath("../%s")' % end_body_path)
            B('body_b = NodePath("../Link_%d")' % (i - 1))
        else:
            B('body_a = NodePath("../Link_%d")' % i)
            B('body_b = NodePath("../Link_%d")' % (i - 1))
        B('')
