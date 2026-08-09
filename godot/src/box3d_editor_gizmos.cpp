// SPDX-FileCopyrightText: 2026 box3d-godot contributors
// SPDX-License-Identifier: MIT

#include "box3d_editor_gizmos.h"

#include "box3d_body.h"
#include "box3d_collision_shape.h"
#include "box3d_conversions.h"
#include "box3d_joint.h"
#include "box3d_world.h"

#include <godot_cpp/classes/mesh.hpp>
#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/classes/standard_material3d.hpp>
#include <godot_cpp/variant/aabb.hpp>
#include <godot_cpp/variant/basis.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>

#include <box3d/box3d.h>
#include <box3d/collision.h>
#include <box3d/constants.h>

#include <cmath>
#include <vector>

using namespace godot;

namespace {

// One material for every line: the colour rides in per-vertex colours, which
// is what EditorNode3DGizmo::add_lines' `modulate` argument writes, so the
// material has to be created with use_vertex_color on or every line comes back
// white.
const char *LINE_MATERIAL = "box3d_lines";

constexpr int CIRCLE_SEGMENTS = 24;
// upstream's kSliceCount for every limit wedge and cone
// (src/revolute_joint.c:626, src/spherical_joint.c:680, src/wheel_joint.c:1073)
constexpr int ARC_SEGMENTS = 16;
constexpr double TAU_D = 6.283185307179586;
constexpr double PI_D = 3.141592653589793;

// b3HexColor is 0x00RRGGBB (types.h:2773-2941). Same unpack as the runtime
// overlay's ov_color (box3d_world.cpp), minus its sRGB step: a Color handed to
// the renderer as a vertex colour is already in the space Godot expects.
Color b3col(b3HexColor p_c) {
	return Color::hex((((uint32_t)p_c & 0x00FFFFFFu) << 8) | 0xFFu);
}

void seg(PackedVector3Array &p_lines, const Vector3 &p_a, const Vector3 &p_b) {
	p_lines.push_back(p_a);
	p_lines.push_back(p_b);
}

// A point marker, where upstream calls DrawPointFcn: three short crossed
// segments, sized in world units rather than the pixels upstream uses (a gizmo
// has no screen-space primitive).
void wire_point(PackedVector3Array &p_lines, const Vector3 &p_p, double p_r) {
	seg(p_lines, p_p - Vector3(p_r, 0, 0), p_p + Vector3(p_r, 0, 0));
	seg(p_lines, p_p - Vector3(0, p_r, 0), p_p + Vector3(0, p_r, 0));
	seg(p_lines, p_p - Vector3(0, 0, p_r), p_p + Vector3(0, 0, p_r));
}

void wire_box(PackedVector3Array &p_lines, const Vector3 &p_center, const Vector3 &p_half) {
	Vector3 v[8];
	for (int i = 0; i < 8; ++i) {
		v[i] = p_center + Vector3((i & 1) ? p_half.x : -p_half.x,
							  (i & 2) ? p_half.y : -p_half.y,
							  (i & 4) ? p_half.z : -p_half.z);
	}
	static const int edges[12][2] = {
		{ 0, 1 }, { 2, 3 }, { 4, 5 }, { 6, 7 },
		{ 0, 2 }, { 1, 3 }, { 4, 6 }, { 5, 7 },
		{ 0, 4 }, { 1, 5 }, { 2, 6 }, { 3, 7 }
	};
	for (int i = 0; i < 12; ++i) {
		seg(p_lines, v[edges[i][0]], v[edges[i][1]]);
	}
}

// Arc of radius p_r about p_center, in the plane spanned by p_u (angle 0) and
// p_v (angle pi/2), swept from p_a0 to p_a1 radians.
void wire_arc(PackedVector3Array &p_lines, const Vector3 &p_center, const Vector3 &p_u,
		const Vector3 &p_v, double p_r, double p_a0, double p_a1, int p_segments) {
	if (p_segments < 1 || p_r <= 0.0) {
		return;
	}
	Vector3 prev = p_center + p_u * (real_t)(p_r * std::cos(p_a0)) + p_v * (real_t)(p_r * std::sin(p_a0));
	for (int i = 1; i <= p_segments; ++i) {
		const double t = p_a0 + (p_a1 - p_a0) * (double)i / (double)p_segments;
		const Vector3 cur = p_center + p_u * (real_t)(p_r * std::cos(t)) + p_v * (real_t)(p_r * std::sin(t));
		seg(p_lines, prev, cur);
		prev = cur;
	}
}

void wire_circle(PackedVector3Array &p_lines, const Vector3 &p_center, const Vector3 &p_u,
		const Vector3 &p_v, double p_r) {
	wire_arc(p_lines, p_center, p_u, p_v, p_r, 0.0, TAU_D, CIRCLE_SEGMENTS);
}

void wire_sphere(PackedVector3Array &p_lines, const Vector3 &p_center, double p_r) {
	wire_circle(p_lines, p_center, Vector3(1, 0, 0), Vector3(0, 1, 0), p_r);
	wire_circle(p_lines, p_center, Vector3(1, 0, 0), Vector3(0, 0, 1), p_r);
	wire_circle(p_lines, p_center, Vector3(0, 1, 0), Vector3(0, 0, 1), p_r);
}

// Capsule along local Y, exactly as Box3DBody / Box3DCollisionShape build it:
// centers at (0, +-half, 0) with half = capsule_height / 2 - radius, clamped at
// zero (box3d_body.cpp:391-397).
void wire_capsule(PackedVector3Array &p_lines, double p_radius, double p_total_height) {
	const double r = p_radius;
	double half = p_total_height * 0.5 - r;
	if (half < 0.0) {
		half = 0.0;
	}
	const Vector3 top(0, (real_t)half, 0);
	const Vector3 bottom(0, (real_t)-half, 0);
	wire_circle(p_lines, top, Vector3(1, 0, 0), Vector3(0, 0, 1), r);
	wire_circle(p_lines, bottom, Vector3(1, 0, 0), Vector3(0, 0, 1), r);
	seg(p_lines, top + Vector3((real_t)r, 0, 0), bottom + Vector3((real_t)r, 0, 0));
	seg(p_lines, top - Vector3((real_t)r, 0, 0), bottom - Vector3((real_t)r, 0, 0));
	seg(p_lines, top + Vector3(0, 0, (real_t)r), bottom + Vector3(0, 0, (real_t)r));
	seg(p_lines, top - Vector3(0, 0, (real_t)r), bottom - Vector3(0, 0, (real_t)r));
	wire_arc(p_lines, top, Vector3(1, 0, 0), Vector3(0, 1, 0), r, 0.0, PI_D, CIRCLE_SEGMENTS / 2);
	wire_arc(p_lines, top, Vector3(0, 0, 1), Vector3(0, 1, 0), r, 0.0, PI_D, CIRCLE_SEGMENTS / 2);
	wire_arc(p_lines, bottom, Vector3(1, 0, 0), Vector3(0, 1, 0), r, PI_D, TAU_D, CIRCLE_SEGMENTS / 2);
	wire_arc(p_lines, bottom, Vector3(0, 0, 1), Vector3(0, 1, 0), r, PI_D, TAU_D, CIRCLE_SEGMENTS / 2);
}

// Every drawable edge of a hull, once. edgeCount is the HALF-edge count
// (types.h:2013), so each pair is emitted by the half whose index is below its
// twin's — the same walk the runtime hull shell does
// (box3d_world.cpp::push_hull_shell), minus its centroid lift, which exists to
// keep a wireframe off a resting floor and has no editor counterpart.
void wire_hull(PackedVector3Array &p_lines, const b3HullData *p_hull, const Vector3 &p_offset) {
	if (p_hull == nullptr || p_hull->edgeCount <= 0 || p_hull->vertexCount <= 0) {
		return;
	}
	const b3Vec3 *points = b3GetHullPoints(p_hull);
	const b3HullHalfEdge *edges = b3GetHullEdges(p_hull);
	if (points == nullptr || edges == nullptr) {
		return;
	}
	for (int e = 0; e < p_hull->edgeCount; ++e) {
		const int twin = (int)edges[e].twin;
		if (twin <= e || twin >= p_hull->edgeCount) {
			continue;
		}
		seg(p_lines, to_gd(points[edges[e].origin]) + p_offset, to_gd(points[edges[twin].origin]) + p_offset);
	}
}

// The five primitives Box3DBody and Box3DCollisionShape both author, in the
// node's own local space. The node scale is NOT applied here: a gizmo is drawn
// under the node's global transform, which already carries it, and the runtime
// bakes exactly that scale into the geometry (P-024).
void primitive_outline(PackedVector3Array &p_lines, int p_shape_type, const Vector3 &p_box_size,
		double p_sphere_radius, double p_capsule_radius, double p_capsule_height, int p_sides) {
	switch (p_shape_type) {
		case Box3DCollisionShape::BOX:
			wire_box(p_lines, Vector3(), p_box_size * 0.5f);
			break;
		case Box3DCollisionShape::SPHERE:
			wire_sphere(p_lines, Vector3(), p_sphere_radius);
			break;
		case Box3DCollisionShape::CAPSULE:
			wire_capsule(p_lines, p_capsule_radius, p_capsule_height);
			break;
		case Box3DCollisionShape::CYLINDER: {
			// Same call and same centring offset as the runtime
			// (box3d_body.cpp:428): b3CreateCylinder builds base-up from
			// yOffset, so -height/2 centres it on the origin.
			b3HullData *hull = b3CreateCylinder((float)p_capsule_height, (float)p_capsule_radius,
					(float)(-p_capsule_height * 0.5), p_sides);
			if (hull != nullptr) {
				wire_hull(p_lines, hull, Vector3());
				b3DestroyHull(hull);
			}
		} break;
		case Box3DCollisionShape::CONE: {
			// b3CreateCone has no offset argument, so the runtime bakes the
			// -height/2 shift into the shape transform (box3d_body.cpp:447-455).
			b3HullData *hull = b3CreateCone((float)p_capsule_height, (float)p_capsule_radius, 0.0f, p_sides);
			if (hull != nullptr) {
				wire_hull(p_lines, hull, Vector3(0, (real_t)(-p_capsule_height * 0.5), 0));
				b3DestroyHull(hull);
			}
		} break;
		default:
			break;
	}
}

// Upstream's body-state palette (src/physics_world.c:1240-1305), restricted to
// the states an unsimulated node can actually be in. The runtime overlay picks
// from the same list (box3d_world.cpp:2415-2436), so a collider keeps its
// colour when you press play.
Color body_color(const Box3DBody *p_body) {
	if (!p_body->get_enabled()) {
		return b3col(b3_colorSlateGray);
	}
	if (p_body->get_is_sensor()) {
		return b3col(b3_colorWheat);
	}
	switch (p_body->get_body_type()) {
		case Box3DBody::STATIC:
			return b3col(b3_colorDarkGray);
		case Box3DBody::KINEMATIC:
			return b3col(b3_colorSteelBlue);
		default:
			// A scene starts with its dynamic bodies awake, so the awake tan is
			// the honest one of upstream's tan / light-slate-gray pair.
			return b3col(b3_colorTan);
	}
}

bool has_child_shapes(const Node3D *p_body) {
	for (int i = 0; i < p_body->get_child_count(); ++i) {
		if (Object::cast_to<Box3DCollisionShape>(p_body->get_child(i)) != nullptr) {
			return true;
		}
	}
	return false;
}

// --- joints ---------------------------------------------------------------

// One entry per colour upstream uses, because add_lines takes a single
// modulate per call: the gizmo accumulates a line list per colour and flushes
// them together.
struct ColoredLines {
	Color color;
	PackedVector3Array lines;
};

// No joint type below reaches this many distinct colours (the wheel, at six, is
// the worst), and the callers hold the returned reference across further
// bucket() calls, so the vector must never reallocate.
constexpr size_t MAX_COLOR_BUCKETS = 16;

PackedVector3Array &bucket(std::vector<ColoredLines> &p_buckets, b3HexColor p_color) {
	const Color c = b3col(p_color);
	for (ColoredLines &b : p_buckets) {
		if (b.color == c) {
			return b.lines;
		}
	}
	if (p_buckets.size() >= MAX_COLOR_BUCKETS) {
		return p_buckets.back().lines; // unreachable today; never reallocate
	}
	p_buckets.push_back(ColoredLines{ c, PackedVector3Array() });
	return p_buckets.back().lines;
}

// The three frame axes upstream draws for a revolute or spherical joint at
// 0.1 * scale (src/revolute_joint.c:619-624, src/spherical_joint.c:665-671):
// X red, Y green, Z blue. Frame A is the joint node's own transform for every
// type but the wheel, so in gizmo space it is the identity.
void frame_axes(std::vector<ColoredLines> &p_b, const Basis &p_basis, double p_length) {
	seg(bucket(p_b, b3_colorRed), Vector3(), p_basis.get_column(0) * (real_t)p_length);
	seg(bucket(p_b, b3_colorGreen), Vector3(), p_basis.get_column(1) * (real_t)p_length);
	seg(bucket(p_b, b3_colorBlue), Vector3(), p_basis.get_column(2) * (real_t)p_length);
}

// upstream's limit wedge: a fan of ARC_SEGMENTS chords in the frame's XY plane
// closed back to the frame origin at both ends
// (src/revolute_joint.c:626-670).
void limit_wedge(PackedVector3Array &p_lines, const Vector3 &p_u, const Vector3 &p_v,
		double p_radius, double p_lower, double p_upper) {
	wire_arc(p_lines, Vector3(), p_u, p_v, p_radius, p_lower, p_upper, ARC_SEGMENTS);
	seg(p_lines, Vector3(), p_u * (real_t)(p_radius * std::cos(p_lower)) + p_v * (real_t)(p_radius * std::sin(p_lower)));
	seg(p_lines, Vector3(), p_u * (real_t)(p_radius * std::cos(p_upper)) + p_v * (real_t)(p_radius * std::sin(p_upper)));
}

// The joint's debug size, upstream's max(0.0001, jointScale * drawScale)
// (src/joint.c:1670). The world-level half comes from the nearest Box3DWorld
// ancestor, the same node the joint would find at runtime.
double joint_scale(const Box3DJoint *p_joint) {
	double world_scale = 1.0;
	for (Node *n = p_joint->get_parent(); n != nullptr; n = n->get_parent()) {
		const Box3DWorld *w = Object::cast_to<Box3DWorld>(n);
		if (w != nullptr) {
			world_scale = w->get_debug_joint_scale();
			break;
		}
	}
	const double s = world_scale * p_joint->get_draw_scale();
	return s > 0.0001 ? s : 0.0001;
}

// Where the joint's two anchors sit in the joint node's local space. Every
// joint but the distance one anchors both frames on the node itself
// (box3d_joint.cpp local_frame(), called with p_joint for both), so both
// anchors are the origin; Box3DDistanceJoint deliberately uses identity local
// frames instead, i.e. each BODY's origin (box3d_joint.cpp:836-838).
bool distance_anchors(const Box3DJoint *p_joint, Vector3 &r_a, Vector3 &r_b) {
	const Node3D *a = Object::cast_to<Node3D>(p_joint->get_node_or_null(p_joint->get_body_a()));
	const Node3D *b = Object::cast_to<Node3D>(p_joint->get_node_or_null(p_joint->get_body_b()));
	if (a == nullptr) {
		return false;
	}
	const Transform3D inv = p_joint->get_global_transform().affine_inverse();
	r_a = inv.xform(a->get_global_transform().origin);
	// An empty body_b anchors to the world at this node's position, which is
	// what create_joint's static anchor body does.
	r_b = b != nullptr ? inv.xform(b->get_global_transform().origin) : Vector3();
	return true;
}

void draw_joint(const Box3DJoint *p_joint, std::vector<ColoredLines> &p_b) {
	const double scale = joint_scale(p_joint);
	const Basis id; // frame A and frame B in the node's own space

	if (const Box3DHingeJoint *hinge = Object::cast_to<Box3DHingeJoint>(p_joint)) {
		// b3DrawRevoluteJoint (src/revolute_joint.c:618-673).
		frame_axes(p_b, id, 0.1 * scale);
		if (hinge->get_limit_enabled()) {
			limit_wedge(bucket(p_b, b3_colorCyan), Vector3(1, 0, 0), Vector3(0, 1, 0),
					0.2 * scale, hinge->get_lower_limit(), hinge->get_upper_limit());
		}
		return;
	}
	if (const Box3DSliderJoint *slider = Object::cast_to<Box3DSliderJoint>(p_joint)) {
		// b3DrawPrismaticJoint (src/prismatic_joint.c:694-725): the two
		// perpendiculars, then the track. The slide axis is frame A local X.
		const Vector3 axis = id.get_column(0);
		const double s = 0.2 * scale;
		seg(bucket(p_b, b3_colorGreen), Vector3(), id.get_column(1) * (real_t)s);
		seg(bucket(p_b, b3_colorBlue), Vector3(), id.get_column(2) * (real_t)s);
		if (slider->get_limit_enabled()) {
			const Vector3 p1 = axis * (real_t)slider->get_lower_limit();
			const Vector3 p2 = axis * (real_t)slider->get_upper_limit();
			seg(bucket(p_b, b3_colorOrange), p1, p2);
			wire_point(bucket(p_b, b3_colorGreen), p1, 0.05 * scale);
			wire_point(bucket(p_b, b3_colorRed), p2, 0.05 * scale);
		} else {
			seg(bucket(p_b, b3_colorOrange), axis * (real_t)(-0.5 * scale), axis * (real_t)(0.5 * scale));
		}
		wire_point(bucket(p_b, b3_colorViolet), Vector3(), 0.04 * scale);
		return;
	}
	if (const Box3DWheelJoint *wheel = Object::cast_to<Box3DWheelJoint>(p_joint)) {
		// b3DrawWheelJoint (src/wheel_joint.c:1020-1105). Frame A is the node
		// basis rotated so box3d's X lands on the node's suspension axis; the
		// binding builds it at box3d_joint.cpp:1432 and this repeats it
		// verbatim, so the gizmo cannot drift from the constraint.
		const Basis frame_a = Basis(Vector3(0, 1, 0), Vector3(-1, 0, 0), Vector3(0, 0, 1));
		const Vector3 cx = frame_a.get_column(0); // suspension / steering axis
		const Vector3 cy = frame_a.get_column(1);
		if (wheel->get_suspension_limit_enabled()) {
			const Vector3 lower = cx * (real_t)wheel->get_lower_suspension_limit();
			const Vector3 upper = cx * (real_t)wheel->get_upper_suspension_limit();
			seg(bucket(p_b, b3_colorGray), lower, upper);
			const Vector3 tick = cy * (real_t)(0.1 * scale);
			seg(bucket(p_b, b3_colorGreen), lower - tick, lower + tick);
			seg(bucket(p_b, b3_colorRed), upper - tick, upper + tick);
		} else {
			seg(bucket(p_b, b3_colorGray), cx * (real_t)(-1.0 * scale), cx * (real_t)(1.0 * scale));
		}
		if (wheel->get_steering_enabled() && wheel->get_steering_limit_enabled()) {
			// The steering wedge is swept in frame A's YZ plane, as
			// (0, -r sin, r cos) (src/wheel_joint.c:1078-1088).
			limit_wedge(bucket(p_b, b3_colorCyan), id.get_column(2), -id.get_column(1),
					0.5 * scale, wheel->get_lower_steering_limit(), wheel->get_upper_steering_limit());
		}
		// The axle: frame B local Z, which for this node IS the node's Z.
		const Vector3 axle = id.get_column(2) * (real_t)(0.5 * scale);
		seg(bucket(p_b, b3_colorMagenta), -axle, axle);
		wire_point(bucket(p_b, b3_colorGray), Vector3(), 0.03 * scale);
		return;
	}
	if (const Box3DDistanceJoint *dist = Object::cast_to<Box3DDistanceJoint>(p_joint)) {
		// b3DrawDistanceJoint (src/distance_joint.c:538-580).
		Vector3 pa, pb;
		if (!distance_anchors(p_joint, pa, pb)) {
			return;
		}
		const Vector3 axis = (pb - pa).normalized();
		if (dist->get_limit_enabled() && dist->get_min_length() < dist->get_max_length()) {
			const Vector3 p_min = pa + axis * (real_t)dist->get_min_length();
			const Vector3 p_max = pa + axis * (real_t)dist->get_max_length();
			// upstream skips a min at the linear slop and a max at B3_HUGE;
			// the same two guards, expressed on the authored values.
			const bool has_min = dist->get_min_length() > (double)B3_LINEAR_SLOP;
			const bool has_max = dist->get_max_length() < (double)B3_HUGE;
			if (has_min) {
				wire_point(bucket(p_b, b3_colorLightGreen), p_min, 0.05 * scale);
			}
			if (has_max) {
				wire_point(bucket(p_b, b3_colorRed), p_max, 0.05 * scale);
			}
			if (has_min && has_max) {
				seg(bucket(p_b, b3_colorGray), p_min, p_max);
			}
		}
		PackedVector3Array &white = bucket(p_b, b3_colorWhite);
		seg(white, pa, pb);
		wire_point(white, pa, 0.04 * scale);
		wire_point(white, pb, 0.04 * scale);
		if (dist->get_spring_enabled() && dist->get_spring_hertz() > 0.0) {
			// length < 0 means "the current distance", which is what the two
			// anchors already are.
			const double len = dist->get_length() < 0.0 ? (double)pa.distance_to(pb) : dist->get_length();
			wire_point(bucket(p_b, b3_colorBlue), pa + axis * (real_t)len, 0.04 * scale);
		}
		return;
	}
	if (const Box3DBallJoint *ball = Object::cast_to<Box3DBallJoint>(p_joint)) {
		// b3DrawSphericalJoint (src/spherical_joint.c:661-744).
		frame_axes(p_b, id, 0.1 * scale);
		seg(bucket(p_b, b3_colorOrange), Vector3(), id.get_column(2) * (real_t)(0.2 * scale));
		if (ball->get_twist_limit_enabled()) {
			limit_wedge(bucket(p_b, b3_colorCyan), id.get_column(0), id.get_column(1),
					0.1 * scale, ball->get_twist_lower(), ball->get_twist_upper());
		}
		if (ball->get_cone_limit_enabled()) {
			const double radius = 0.1 * scale;
			const double cone_r = radius * std::sin(ball->get_cone_angle());
			const double cone_h = radius * std::cos(ball->get_cone_angle());
			const Vector3 center = id.get_column(2) * (real_t)cone_h;
			PackedVector3Array &cyan = bucket(p_b, b3_colorCyan);
			wire_circle(cyan, center, id.get_column(0), id.get_column(1), cone_r);
			for (int i = 0; i < ARC_SEGMENTS; ++i) {
				const double phi = TAU_D * (double)i / (double)ARC_SEGMENTS;
				seg(cyan, Vector3(),
						center + id.get_column(0) * (real_t)(cone_r * std::cos(phi)) +
								id.get_column(1) * (real_t)(cone_r * std::sin(phi)));
			}
		}
		return;
	}
	if (Object::cast_to<Box3DFixedJoint>(p_joint) != nullptr) {
		// b3DrawWeldJoint (src/weld_joint.c:306-314): a small box per frame.
		// Both frames are this node, so the two boxes coincide; the dark-orange
		// one (frame A) is drawn slightly larger so both stay readable.
		const Vector3 extents((real_t)(0.1 * scale), (real_t)(0.05 * scale), (real_t)(0.025 * scale));
		wire_box(bucket(p_b, b3_colorDarkOrange), Vector3(), extents);
		wire_box(bucket(p_b, b3_colorDarkCyan), Vector3(), extents * 0.6f);
		return;
	}
	if (Object::cast_to<Box3DParallelJoint>(p_joint) != nullptr) {
		// b3DrawParallelJoint (src/parallel_joint.c:242-251): frame A's Z green,
		// frame B's Z blue. Same node, so the blue one is drawn shorter.
		const double length = 0.1 * scale;
		seg(bucket(p_b, b3_colorGreen), Vector3(), id.get_column(2) * (real_t)length);
		seg(bucket(p_b, b3_colorBlue), Vector3(), id.get_column(2) * (real_t)(-length));
		return;
	}
	// Motor (b3_colorPlum / b3_colorYellowGreen) and filter (b3_colorGold) have
	// no draw function of their own: src/joint.c:1683-1690 draws them as the
	// segment between the two anchors. Both anchor on this node, so the segment
	// upstream would draw is the body-to-body span, which is what is worth
	// seeing in the editor.
	Vector3 pa, pb;
	if (!distance_anchors(p_joint, pa, pb)) {
		wire_point(bucket(p_b, b3_colorDarkSeaGreen), Vector3(), 0.1 * scale);
		return;
	}
	if (Object::cast_to<Box3DFilterJoint>(p_joint) != nullptr) {
		seg(bucket(p_b, b3_colorGold), pa, pb);
		return;
	}
	if (Object::cast_to<Box3DMotorJoint>(p_joint) != nullptr) {
		seg(bucket(p_b, b3_colorPlum), pa, pb);
		wire_point(bucket(p_b, b3_colorYellowGreen), pa, 0.05 * scale);
		wire_point(bucket(p_b, b3_colorPlum), pb, 0.05 * scale);
		return;
	}
	// src/joint.c:1714-1717's fallback, for a joint type added upstream that
	// this file has not learned yet.
	PackedVector3Array &fallback = bucket(p_b, b3_colorDarkSeaGreen);
	seg(fallback, pa, Vector3());
	seg(fallback, Vector3(), pb);
}

} // namespace

// --- Box3DColliderGizmoPlugin ----------------------------------------------

Box3DColliderGizmoPlugin::Box3DColliderGizmoPlugin() {
	create_material(LINE_MATERIAL, Color(1, 1, 1), false, false, true);
}

String Box3DColliderGizmoPlugin::_get_gizmo_name() const {
	return "Box3D Collider";
}

int32_t Box3DColliderGizmoPlugin::_get_priority() const {
	return -1;
}

bool Box3DColliderGizmoPlugin::_has_gizmo(Node3D *p_node) const {
	return Object::cast_to<Box3DBody>(p_node) != nullptr ||
			Object::cast_to<Box3DCollisionShape>(p_node) != nullptr;
}

void Box3DColliderGizmoPlugin::_redraw(const Ref<EditorNode3DGizmo> &p_gizmo) {
	p_gizmo->clear();
	Node3D *node = p_gizmo->get_node_3d();
	if (node == nullptr) {
		return;
	}
	PackedVector3Array lines;
	Color color = b3col(b3_colorTan);

	if (Box3DCollisionShape *shape = Object::cast_to<Box3DCollisionShape>(node)) {
		primitive_outline(lines, shape->get_shape_type(), shape->get_box_size(),
				shape->get_sphere_radius(), shape->get_capsule_radius(),
				shape->get_capsule_height(), shape->get_sides());
		Box3DBody *owner = Object::cast_to<Box3DBody>(shape->get_parent());
		if (owner != nullptr) {
			color = body_color(owner);
		}
	} else if (Box3DBody *body = Object::cast_to<Box3DBody>(node)) {
		color = body_color(body);
		// A body with Box3DCollisionShape children is a compound: the solver
		// ignores its own shape_type entirely, so drawing it would show a
		// collider that is not there. Same rule as the runtime overlay
		// (box3d_world.cpp:2438-2441).
		if (has_child_shapes(body)) {
			return;
		}
		const int shape_type = body->get_shape_type();
		switch (shape_type) {
			case Box3DBody::HULL: {
				// The collider is the convex hull of the source mesh's points,
				// so the gizmo hulls the same cloud rather than outlining the
				// mesh (box3d_body.cpp:460-486). b3Shape_GetHull, the runtime
				// route, needs a live shape and there is none in the editor.
				Ref<Mesh> src_mesh;
				Transform3D src_local;
				if (body->resolve_collision_mesh(src_mesh, src_local)) {
					const PackedVector3Array faces = src_mesh->get_faces();
					const int count = faces.size();
					if (count >= 4) {
						std::vector<b3Vec3> points((size_t)count);
						for (int i = 0; i < count; ++i) {
							points[(size_t)i] = to_b3(src_local.xform(faces[i]));
						}
						const int max_verts = count < 255 ? count : 255;
						b3HullData *hull = b3CreateHull(points.data(), count, max_verts);
						if (hull != nullptr) {
							wire_hull(lines, hull, Vector3());
							b3DestroyHull(hull);
						}
					}
				}
			} break;
			case Box3DBody::FIT_MESH: {
				// The auto-fitted box, recomputed the way create_shapes does
				// (box3d_body.cpp:600-618).
				Ref<Mesh> src_mesh;
				Transform3D src_local;
				if (body->resolve_collision_mesh(src_mesh, src_local)) {
					const AABB aabb = src_mesh->get_aabb();
					AABB local_aabb;
					for (int c = 0; c < 8; ++c) {
						const Vector3 corner = src_local.xform(aabb.get_endpoint(c));
						local_aabb = (c == 0) ? AABB(corner, Vector3()) : local_aabb.expand(corner);
					}
					const Vector3 h = local_aabb.size * 0.5f;
					wire_box(lines, local_aabb.position + h, h);
				}
			} break;
			case Box3DBody::MESH: {
				// A triangle soup has no cheap outline and its shell is drawn
				// in full at runtime; the editor shows its bounds instead, so
				// the collider at least has a visible extent.
				const PackedVector3Array verts = body->get_mesh_vertices();
				if (verts.size() >= 3) {
					AABB bounds(verts[0], Vector3());
					for (int i = 1; i < verts.size(); ++i) {
						bounds = bounds.expand(verts[i]);
					}
					const Vector3 h = bounds.size * 0.5f;
					wire_box(lines, bounds.position + h, h);
				} else {
					Ref<Mesh> src_mesh;
					Transform3D src_local;
					if (body->resolve_collision_mesh(src_mesh, src_local)) {
						const AABB aabb = src_mesh->get_aabb();
						AABB local_aabb;
						for (int c = 0; c < 8; ++c) {
							const Vector3 corner = src_local.xform(aabb.get_endpoint(c));
							local_aabb = (c == 0) ? AABB(corner, Vector3()) : local_aabb.expand(corner);
						}
						const Vector3 h = local_aabb.size * 0.5f;
						wire_box(lines, local_aabb.position + h, h);
					}
				}
			} break;
			case Box3DBody::HEIGHT_FIELD: {
				// get_height_field_extent() is the authored span, corner at the
				// body origin growing +X / +Z, because b3CreateHeightFieldShape
				// takes no local transform (box3d_body.h:574-577). The one shape
				// that ignores the node scale, so the gizmo divides it back out
				// — the editor applies the node transform to everything here.
				const Vector3 extent = body->get_height_field_extent();
				const Vector3 node_scale = body->get_transform().basis.get_scale();
				Vector3 span = extent;
				if (node_scale.x != 0.0f && node_scale.y != 0.0f && node_scale.z != 0.0f) {
					span = Vector3(extent.x / node_scale.x, extent.y / node_scale.y, extent.z / node_scale.z);
				}
				wire_box(lines, span * 0.5f, span * 0.5f);
			} break;
			default:
				primitive_outline(lines, shape_type, body->get_box_size(), body->get_sphere_radius(),
						body->get_capsule_radius(), body->get_capsule_height(), body->get_cylinder_sides());
				break;
		}
	}

	if (lines.size() >= 2) {
		p_gizmo->add_lines(lines, get_material(LINE_MATERIAL, p_gizmo), false, color);
	}
}

// --- Box3DJointGizmoPlugin --------------------------------------------------

Box3DJointGizmoPlugin::Box3DJointGizmoPlugin() {
	create_material(LINE_MATERIAL, Color(1, 1, 1), false, false, true);
}

String Box3DJointGizmoPlugin::_get_gizmo_name() const {
	return "Box3D Joint";
}

int32_t Box3DJointGizmoPlugin::_get_priority() const {
	return -1;
}

bool Box3DJointGizmoPlugin::_has_gizmo(Node3D *p_node) const {
	return Object::cast_to<Box3DJoint>(p_node) != nullptr;
}

void Box3DJointGizmoPlugin::_redraw(const Ref<EditorNode3DGizmo> &p_gizmo) {
	p_gizmo->clear();
	Box3DJoint *joint = Object::cast_to<Box3DJoint>(p_gizmo->get_node_3d());
	if (joint == nullptr) {
		return;
	}
	std::vector<ColoredLines> buckets;
	buckets.reserve(MAX_COLOR_BUCKETS);
	draw_joint(joint, buckets);
	const Ref<StandardMaterial3D> material = get_material(LINE_MATERIAL, p_gizmo);
	for (const ColoredLines &b : buckets) {
		if (b.lines.size() >= 2) {
			p_gizmo->add_lines(b.lines, material, false, b.color);
		}
	}
}

// --- Box3DEditorPlugin ------------------------------------------------------

void Box3DEditorPlugin::_enter_tree() {
	collider_gizmos.instantiate();
	joint_gizmos.instantiate();
	add_node_3d_gizmo_plugin(collider_gizmos);
	add_node_3d_gizmo_plugin(joint_gizmos);
}

void Box3DEditorPlugin::_exit_tree() {
	if (collider_gizmos.is_valid()) {
		remove_node_3d_gizmo_plugin(collider_gizmos);
		collider_gizmos.unref();
	}
	if (joint_gizmos.is_valid()) {
		remove_node_3d_gizmo_plugin(joint_gizmos);
		joint_gizmos.unref();
	}
}

String Box3DEditorPlugin::_get_plugin_name() const {
	return "Box3D";
}
