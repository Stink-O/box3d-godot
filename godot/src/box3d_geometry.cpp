// SPDX-FileCopyrightText: 2026 box3d-godot contributors
// SPDX-License-Identifier: MIT

#include "box3d_geometry.h"

#include "box3d_conversions.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <vector>

using namespace godot;

namespace {

// A hull is a half-edge structure: each face names one of its edges, and
// walking `next` around that edge closes the polygon (types.h:1946-1968). Faces
// are convex, so fanning from the first vertex triangulates them exactly.
Dictionary hull_to_dict(const b3HullData *p_hull) {
	Dictionary out;
	PackedVector3Array vertices;
	PackedInt32Array indices;
	if (p_hull == nullptr) {
		out["vertices"] = vertices;
		out["indices"] = indices;
		return out;
	}
	const b3Vec3 *points = b3GetHullPoints(p_hull);
	const b3HullHalfEdge *edges = b3GetHullEdges(p_hull);
	const b3HullFace *faces = b3GetHullFaces(p_hull);
	if (points != nullptr) {
		vertices.resize(p_hull->vertexCount);
		for (int i = 0; i < p_hull->vertexCount; ++i) {
			vertices[i] = to_gd(points[i]);
		}
	}
	if (edges != nullptr && faces != nullptr) {
		for (int f = 0; f < p_hull->faceCount; ++f) {
			const int first = faces[f].edge;
			int e = edges[first].next;
			const int root = edges[first].origin;
			int previous = edges[e].origin;
			e = edges[e].next;
			// Bounded by the half-edge count so a malformed hull cannot spin
			// here; a well-formed face closes long before that.
			for (int guard = 0; guard < p_hull->edgeCount && e != first; ++guard) {
				const int current = edges[e].origin;
				indices.push_back(root);
				indices.push_back(previous);
				indices.push_back(current);
				previous = current;
				e = edges[e].next;
			}
		}
	}
	out["vertices"] = vertices;
	out["indices"] = indices;
	return out;
}

// Owned for the length of one call: every b3Create* hull is heap data that has
// to go back through b3DestroyHull (collision.h:232-234).
Dictionary consume_hull(b3HullData *p_hull) {
	Dictionary out = hull_to_dict(p_hull);
	if (p_hull != nullptr) {
		b3DestroyHull(p_hull);
	}
	return out;
}

// The b3Make*BoxHull family returns a b3BoxHull BY VALUE whose `base` is a
// b3HullData with the arrays hanging off the same struct. It must NOT be
// destroyed (collision.h:236-243) — reading it and letting it fall off the
// stack is the whole lifetime.
Dictionary box_hull_to_dict(const b3BoxHull &p_box) {
	return hull_to_dict(&p_box.base);
}

Dictionary mesh_to_dict(b3MeshData *p_mesh) {
	Dictionary out;
	PackedVector3Array vertices;
	PackedInt32Array indices;
	PackedByteArray materials;
	if (p_mesh == nullptr) {
		out["vertices"] = vertices;
		out["indices"] = indices;
		out["materials"] = materials;
		out["bvh_height"] = 0;
		return out;
	}
	const b3Vec3 *points = b3GetMeshVertices(p_mesh);
	const b3MeshTriangle *triangles = b3GetMeshTriangles(p_mesh);
	const uint8_t *material_indices = b3GetMeshMaterialIndices(p_mesh);
	if (points != nullptr) {
		vertices.resize(p_mesh->vertexCount);
		for (int i = 0; i < p_mesh->vertexCount; ++i) {
			vertices[i] = to_gd(points[i]);
		}
	}
	if (triangles != nullptr) {
		indices.resize(p_mesh->triangleCount * 3);
		for (int i = 0; i < p_mesh->triangleCount; ++i) {
			indices[i * 3 + 0] = triangles[i].index1;
			indices[i * 3 + 1] = triangles[i].index2;
			indices[i * 3 + 2] = triangles[i].index3;
		}
	}
	// One material index per triangle (collision.h:311-313), which is exactly
	// what Box3DBody.mesh_materials indexes surface_materials with.
	if (material_indices != nullptr) {
		materials.resize(p_mesh->triangleCount);
		for (int i = 0; i < p_mesh->triangleCount; ++i) {
			materials[i] = material_indices[i];
		}
	}
	out["vertices"] = vertices;
	out["indices"] = indices;
	out["materials"] = materials;
	// b3GetHeight (collision.h:359): the height of the mesh's BVH, i.e. how
	// deep a query into this mesh has to walk.
	out["bvh_height"] = b3GetHeight(p_mesh);
	b3DestroyMesh(p_mesh);
	return out;
}

} // namespace

Dictionary Box3DGeometry::create_rock(double p_radius) {
	return consume_hull(b3CreateRock((float)p_radius));
}

Dictionary Box3DGeometry::create_cylinder(double p_height, double p_radius, double p_y_offset, int p_sides) {
	return consume_hull(b3CreateCylinder((float)p_height, (float)p_radius, (float)p_y_offset, p_sides));
}

Dictionary Box3DGeometry::create_cone(double p_height, double p_radius1, double p_radius2, int p_slices) {
	return consume_hull(b3CreateCone((float)p_height, (float)p_radius1, (float)p_radius2, p_slices));
}

Dictionary Box3DGeometry::create_hull(const PackedVector3Array &p_points, int p_max_vertex_count) {
	const int count = p_points.size();
	if (count < 4) {
		UtilityFunctions::push_warning("Box3DGeometry.create_hull needs at least 4 points.");
		return hull_to_dict(nullptr);
	}
	std::vector<b3Vec3> points((size_t)count);
	for (int i = 0; i < count; ++i) {
		points[(size_t)i] = to_b3(p_points[i]);
	}
	int max_verts = p_max_vertex_count > 0 ? p_max_vertex_count : B3_MAX_HULL_VERTICES;
	if (max_verts > B3_MAX_HULL_VERTICES) {
		max_verts = B3_MAX_HULL_VERTICES;
	}
	return consume_hull(b3CreateHull(points.data(), count, max_verts));
}

Dictionary Box3DGeometry::transform_hull(const PackedVector3Array &p_points, const Transform3D &p_transform,
		const Vector3 &p_scale) {
	const int count = p_points.size();
	if (count < 4) {
		UtilityFunctions::push_warning("Box3DGeometry.transform_hull needs at least 4 points.");
		return hull_to_dict(nullptr);
	}
	std::vector<b3Vec3> points((size_t)count);
	for (int i = 0; i < count; ++i) {
		points[(size_t)i] = to_b3(p_points[i]);
	}
	b3HullData *source = b3CreateHull(points.data(), count, B3_MAX_HULL_VERTICES);
	if (source == nullptr) {
		return hull_to_dict(nullptr);
	}
	// Two heap hulls live at once here, which is why both are freed explicitly
	// rather than through consume_hull alone.
	b3HullData *transformed = b3CloneAndTransformHull(source, to_b3_transform(p_transform), to_b3(p_scale));
	b3DestroyHull(source);
	return consume_hull(transformed);
}

Dictionary Box3DGeometry::make_cube_hull(double p_half_width) {
	const b3BoxHull box = b3MakeCubeHull((float)p_half_width);
	return box_hull_to_dict(box);
}

Dictionary Box3DGeometry::make_box_hull(const Vector3 &p_half_extents) {
	const b3BoxHull box = b3MakeBoxHull((float)p_half_extents.x, (float)p_half_extents.y, (float)p_half_extents.z);
	return box_hull_to_dict(box);
}

Dictionary Box3DGeometry::make_offset_box_hull(const Vector3 &p_half_extents, const Vector3 &p_offset) {
	const b3BoxHull box = b3MakeOffsetBoxHull((float)p_half_extents.x, (float)p_half_extents.y,
			(float)p_half_extents.z, to_b3(p_offset));
	return box_hull_to_dict(box);
}

Dictionary Box3DGeometry::make_transformed_box_hull(const Vector3 &p_half_extents, const Transform3D &p_transform) {
	const b3BoxHull box = b3MakeTransformedBoxHull((float)p_half_extents.x, (float)p_half_extents.y,
			(float)p_half_extents.z, to_b3_transform(p_transform));
	return box_hull_to_dict(box);
}

Dictionary Box3DGeometry::make_scaled_box_hull(const Vector3 &p_half_extents, const Transform3D &p_transform,
		const Vector3 &p_post_scale) {
	const b3BoxHull box = b3MakeScaledBoxHull(to_b3(p_half_extents), to_b3_transform(p_transform), to_b3(p_post_scale));
	return box_hull_to_dict(box);
}

Dictionary Box3DGeometry::scale_box(const Vector3 &p_half_extents, const Transform3D &p_transform,
		const Vector3 &p_post_scale, double p_min_half_width) {
	b3Vec3 half_extents = to_b3(p_half_extents);
	b3Transform xf = to_b3_transform(p_transform);
	// In/out parameters, both rewritten in place (collision.h:261-268).
	b3ScaleBox(&half_extents, &xf, to_b3(p_post_scale), (float)p_min_half_width);
	Dictionary out;
	out["half_extents"] = to_gd(half_extents);
	Transform3D result;
	result.basis = Basis(to_gd(xf.q));
	result.origin = to_gd(xf.p);
	out["transform"] = result;
	return out;
}

Dictionary Box3DGeometry::create_grid_mesh(int p_x_count, int p_z_count, double p_cell_width,
		int p_material_count, bool p_identify_edges) {
	return mesh_to_dict(b3CreateGridMesh(p_x_count, p_z_count, (float)p_cell_width,
			p_material_count, p_identify_edges));
}

Dictionary Box3DGeometry::create_wave_mesh(int p_x_count, int p_z_count, double p_cell_width,
		double p_amplitude, double p_row_frequency, double p_column_frequency) {
	return mesh_to_dict(b3CreateWaveMesh(p_x_count, p_z_count, (float)p_cell_width, (float)p_amplitude,
			(float)p_row_frequency, (float)p_column_frequency));
}

Dictionary Box3DGeometry::create_torus_mesh(int p_radial_resolution, int p_tubular_resolution,
		double p_radius, double p_thickness) {
	return mesh_to_dict(b3CreateTorusMesh(p_radial_resolution, p_tubular_resolution,
			(float)p_radius, (float)p_thickness));
}

Dictionary Box3DGeometry::create_box_mesh(const Vector3 &p_center, const Vector3 &p_extent, bool p_identify_edges) {
	return mesh_to_dict(b3CreateBoxMesh(to_b3(p_center), to_b3(p_extent), p_identify_edges));
}

Dictionary Box3DGeometry::create_hollow_box_mesh(const Vector3 &p_center, const Vector3 &p_extent) {
	return mesh_to_dict(b3CreateHollowBoxMesh(to_b3(p_center), to_b3(p_extent)));
}

Dictionary Box3DGeometry::create_platform_mesh(const Vector3 &p_center, double p_height,
		double p_top_width, double p_bottom_width) {
	return mesh_to_dict(b3CreatePlatformMesh(to_b3(p_center), (float)p_height,
			(float)p_top_width, (float)p_bottom_width));
}

Ref<ArrayMesh> Box3DGeometry::make_array_mesh(const Dictionary &p_geometry, const Vector3 &p_scale) {
	Ref<ArrayMesh> mesh;
	mesh.instantiate();
	const PackedVector3Array points = p_geometry.get("vertices", PackedVector3Array());
	const PackedInt32Array indices = p_geometry.get("indices", PackedInt32Array());
	const int triangle_count = indices.size() / 3;
	if (triangle_count == 0 || points.is_empty()) {
		return mesh;
	}
	// A mirroring scale (negative determinant) turns every triangle inside out,
	// so the flip below has to be undone for it — exactly what b3Shape_SetMesh's
	// negative scale does to the collider.
	const bool mirrored = p_scale.x * p_scale.y * p_scale.z < 0.0;
	PackedVector3Array vertices;
	PackedVector3Array normals;
	vertices.resize(triangle_count * 3);
	normals.resize(triangle_count * 3);
	const int point_count = points.size();
	for (int t = 0; t < triangle_count; ++t) {
		const int i0 = indices[t * 3 + 0];
		const int i1 = indices[t * 3 + 1];
		const int i2 = indices[t * 3 + 2];
		if (i0 < 0 || i1 < 0 || i2 < 0 || i0 >= point_count || i1 >= point_count || i2 >= point_count) {
			UtilityFunctions::push_warning("Box3DGeometry.make_array_mesh: index out of range, mesh truncated.");
			vertices.resize(t * 3);
			normals.resize(t * 3);
			break;
		}
		const Vector3 a = points[i0] * p_scale;
		const Vector3 b = points[i1] * p_scale;
		const Vector3 c = points[i2] * p_scale;
		// Box3D winds CCW by the right-hand rule and Godot's front face is the
		// other order, so the triangle is emitted reversed — unless the scale
		// mirrored it, which reverses it once already.
		const Vector3 v0 = a;
		const Vector3 v1 = mirrored ? b : c;
		const Vector3 v2 = mirrored ? c : b;
		// The normal Godot's own convention gives this triangle, i.e.
		// Plane(v0, v1, v2).normal: it points at the side the face is visible
		// from, which for a Box3D mesh is the collidable side. Supplying its
		// negative (the older code did) lights every face from behind.
		const Vector3 normal = (v0 - v2).cross(v0 - v1).normalized();
		vertices[t * 3 + 0] = v0;
		vertices[t * 3 + 1] = v1;
		vertices[t * 3 + 2] = v2;
		normals[t * 3 + 0] = normal;
		normals[t * 3 + 1] = normal;
		normals[t * 3 + 2] = normal;
	}
	if (vertices.is_empty()) {
		return mesh;
	}
	Array arrays;
	arrays.resize(Mesh::ARRAY_MAX);
	arrays[Mesh::ARRAY_VERTEX] = vertices;
	arrays[Mesh::ARRAY_NORMAL] = normals;
	mesh->add_surface_from_arrays(Mesh::PRIMITIVE_TRIANGLES, arrays);
	return mesh;
}

void Box3DGeometry::_bind_methods() {
	ClassDB::bind_static_method("Box3DGeometry", D_METHOD("create_rock", "radius"), &Box3DGeometry::create_rock);
	ClassDB::bind_static_method("Box3DGeometry", D_METHOD("create_cylinder", "height", "radius", "y_offset", "sides"), &Box3DGeometry::create_cylinder, DEFVAL(0.0), DEFVAL(16));
	ClassDB::bind_static_method("Box3DGeometry", D_METHOD("create_cone", "height", "radius1", "radius2", "slices"), &Box3DGeometry::create_cone, DEFVAL(16));
	ClassDB::bind_static_method("Box3DGeometry", D_METHOD("create_hull", "points", "max_vertex_count"), &Box3DGeometry::create_hull, DEFVAL(0));
	ClassDB::bind_static_method("Box3DGeometry", D_METHOD("transform_hull", "points", "transform", "scale"), &Box3DGeometry::transform_hull, DEFVAL(Vector3(1, 1, 1)));
	ClassDB::bind_static_method("Box3DGeometry", D_METHOD("make_cube_hull", "half_width"), &Box3DGeometry::make_cube_hull);
	ClassDB::bind_static_method("Box3DGeometry", D_METHOD("make_box_hull", "half_extents"), &Box3DGeometry::make_box_hull);
	ClassDB::bind_static_method("Box3DGeometry", D_METHOD("make_offset_box_hull", "half_extents", "offset"), &Box3DGeometry::make_offset_box_hull);
	ClassDB::bind_static_method("Box3DGeometry", D_METHOD("make_transformed_box_hull", "half_extents", "transform"), &Box3DGeometry::make_transformed_box_hull);
	ClassDB::bind_static_method("Box3DGeometry", D_METHOD("make_scaled_box_hull", "half_extents", "transform", "post_scale"), &Box3DGeometry::make_scaled_box_hull);
	ClassDB::bind_static_method("Box3DGeometry", D_METHOD("scale_box", "half_extents", "transform", "post_scale", "min_half_width"), &Box3DGeometry::scale_box, DEFVAL(0.005));
	ClassDB::bind_static_method("Box3DGeometry", D_METHOD("create_grid_mesh", "x_count", "z_count", "cell_width", "material_count", "identify_edges"), &Box3DGeometry::create_grid_mesh, DEFVAL(1), DEFVAL(true));
	ClassDB::bind_static_method("Box3DGeometry", D_METHOD("create_wave_mesh", "x_count", "z_count", "cell_width", "amplitude", "row_frequency", "column_frequency"), &Box3DGeometry::create_wave_mesh);
	ClassDB::bind_static_method("Box3DGeometry", D_METHOD("create_torus_mesh", "radial_resolution", "tubular_resolution", "radius", "thickness"), &Box3DGeometry::create_torus_mesh);
	ClassDB::bind_static_method("Box3DGeometry", D_METHOD("create_box_mesh", "center", "extent", "identify_edges"), &Box3DGeometry::create_box_mesh, DEFVAL(true));
	ClassDB::bind_static_method("Box3DGeometry", D_METHOD("create_hollow_box_mesh", "center", "extent"), &Box3DGeometry::create_hollow_box_mesh);
	ClassDB::bind_static_method("Box3DGeometry", D_METHOD("create_platform_mesh", "center", "height", "top_width", "bottom_width"), &Box3DGeometry::create_platform_mesh);
	ClassDB::bind_static_method("Box3DGeometry", D_METHOD("make_array_mesh", "geometry", "scale"), &Box3DGeometry::make_array_mesh, DEFVAL(Vector3(1, 1, 1)));
}
