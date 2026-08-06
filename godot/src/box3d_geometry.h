// SPDX-FileCopyrightText: 2026 box3d-godot contributors
// SPDX-License-Identifier: MIT

#pragma once

#include <godot_cpp/classes/array_mesh.hpp>
#include <godot_cpp/classes/object.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <box3d/box3d.h>

namespace godot {

// Upstream's geometry factories (collision.h:216-361), the ones its own samples
// author their scenes with: the hull makers and the procedural meshes.
//
// Every call is STATIC and needs no world — none of these functions touches a
// b3WorldId, they build geometry in isolation (which is why they are safe to
// call while a world is stepping).
//
// **Ownership never escapes.** b3Create* geometry is heap data that must be
// handed back with b3DestroyHull / b3DestroyMesh (collision.h:232-234, :356),
// while the b3Make*BoxHull family returns a b3BoxHull BY VALUE that must NOT be
// destroyed (collision.h:236-243). Rather than hand a script a pointer it could
// leak or double-free, each call here reads the result into plain Godot arrays
// and frees the Box3D copy before returning. What comes back is data, and Godot
// owns it.
//
// Every function returns a Dictionary in one shape, so they are all
// interchangeable:
//
//   vertices      PackedVector3Array, the points
//   indices       PackedInt32Array, 3 per triangle, upstream's CCW winding
//   materials     PackedByteArray, one per triangle (mesh factories only)
//   bvh_height    int, b3GetHeight of the generated mesh (mesh factories only)
//
// which is exactly what Box3DBody.mesh_vertices / mesh_indices /
// mesh_materials take for a MESH shape. For a HULL shape, or for a visual,
// pass the Dictionary through make_array_mesh().
class Box3DGeometry : public Object {
	GDCLASS(Box3DGeometry, Object)

protected:
	static void _bind_methods();

public:
	// --- hulls -------------------------------------------------------------
	// A hull comes back as its points plus a triangulated surface: the points
	// are what a HULL collider is built from, and the triangles are what draws
	// it. Hull faces are convex polygons of any size (types.h:1962-1968), so
	// each one is fanned into triangles here.

	// b3CreateRock (collision.h:222): the 10-point Fibonacci-lattice hull
	// upstream's debris uses.
	static Dictionary create_rock(double p_radius);
	// b3CreateCylinder (collision.h:216) and b3CreateCone (collision.h:219):
	// tessellated hulls, the same ones Box3DBody's CYLINDER and CONE shapes are
	// built from, so a visual made from these matches the collider exactly.
	static Dictionary create_cylinder(double p_height, double p_radius, double p_y_offset, int p_sides);
	static Dictionary create_cone(double p_height, double p_radius1, double p_radius2, int p_slices);
	// b3CreateHull (collision.h:225): the convex hull of an arbitrary point
	// cloud. max_vertex_count caps the result at B3_MAX_HULL_VERTICES (128,
	// constants.h:115); 0 means "as many as allowed".
	static Dictionary create_hull(const PackedVector3Array &p_points, int p_max_vertex_count = 0);
	// b3CloneAndTransformHull (collision.h:231): re-hulls p_points, then
	// transforms the hull with support for non-uniform and mirroring scale.
	// (b3CloneHull has no separate meaning here — a plain clone of data Godot
	// already owns is a copy of the array.)
	static Dictionary transform_hull(const PackedVector3Array &p_points, const Transform3D &p_transform,
			const Vector3 &p_scale);

	// The b3Make*BoxHull family (collision.h:236-259). All four return a
	// b3BoxHull by value that must not be destroyed, which is handled here.
	// Half extents throughout, matching upstream; Box3DBody.box_size is a FULL
	// size, so halve it when crossing between the two.
	static Dictionary make_cube_hull(double p_half_width);
	static Dictionary make_box_hull(const Vector3 &p_half_extents);
	static Dictionary make_offset_box_hull(const Vector3 &p_half_extents, const Vector3 &p_offset);
	static Dictionary make_transformed_box_hull(const Vector3 &p_half_extents, const Transform3D &p_transform);
	// b3MakeScaledBoxHull (collision.h:252-259): a transformed box with a post
	// scale that may be negative or non-uniform. Approximate under shear.
	static Dictionary make_scaled_box_hull(const Vector3 &p_half_extents, const Transform3D &p_transform,
			const Vector3 &p_post_scale);
	// b3ScaleBox (collision.h:261-268): resolves a post scale into new half
	// extents and a new transform, which is what a level editor needs to turn a
	// scaled box back into a plain one. Returns
	// { half_extents: Vector3, transform: Transform3D }.
	static Dictionary scale_box(const Vector3 &p_half_extents, const Transform3D &p_transform,
			const Vector3 &p_post_scale, double p_min_half_width);

	// --- meshes ------------------------------------------------------------
	// Triangle soups for static MESH colliders. Upstream's samples build their
	// terrain and their rooms with exactly these.

	// b3CreateGridMesh (collision.h:331-337): a flat grid in the XZ plane.
	// material_count > 1 stripes the triangles across that many materials,
	// which Box3DBody.surface_materials then indexes. identify_edges computes
	// adjacency, which is what stops a box catching on an internal edge.
	static Dictionary create_grid_mesh(int p_x_count, int p_z_count, double p_cell_width,
			int p_material_count = 1, bool p_identify_edges = true);
	// b3CreateWaveMesh (collision.h:340): the same grid, displaced by the
	// product of two sine waves. row_frequency runs along Z, column_frequency
	// along X, and BOTH are multiplied by cell_width before the sine
	// (src/mesh.c:1321-1322) — they are cycles per CELL, not per metre. A whole
	// number of cycles per cell samples the sine only at its zeros, so
	// frequency 1 with cell_width 1 produces a perfectly FLAT mesh. Quarter
	// values (0.25) give the peaks upstream's own wave terrain has.
	static Dictionary create_wave_mesh(int p_x_count, int p_z_count, double p_cell_width,
			double p_amplitude, double p_row_frequency, double p_column_frequency);
	// b3CreateTorusMesh (collision.h:344).
	static Dictionary create_torus_mesh(int p_radial_resolution, int p_tubular_resolution,
			double p_radius, double p_thickness);
	// b3CreateBoxMesh (collision.h:347): a closed box as triangles, extents are
	// half extents from the center.
	static Dictionary create_box_mesh(const Vector3 &p_center, const Vector3 &p_extent, bool p_identify_edges = true);
	// b3CreateHollowBoxMesh (collision.h:350): the same box wound INWARD, i.e. a
	// room. A mesh is single-sided, so winding is what makes it a container.
	static Dictionary create_hollow_box_mesh(const Vector3 &p_center, const Vector3 &p_extent);
	// b3CreatePlatformMesh (collision.h:353): a truncated pyramid.
	static Dictionary create_platform_mesh(const Vector3 &p_center, double p_height,
			double p_top_width, double p_bottom_width);

	// --- bridge ------------------------------------------------------------
	// Turns any of the Dictionaries above into a drawable ArrayMesh: assign it
	// to a MeshInstance3D, or to Box3DBody.collision_mesh for a HULL collider.
	//
	// The winding is FLIPPED on the way through. Box3D triangles are CCW as
	// upstream writes them and Godot's front face is the other order, which is
	// the same flip Box3DBody's Godot-Mesh path already applies. Normals are
	// per-face, and vertices are expanded rather than shared, because a hull
	// and a box both want flat shading.
	static Ref<ArrayMesh> make_array_mesh(const Dictionary &p_geometry);
};

} // namespace godot
