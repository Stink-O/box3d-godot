// SPDX-FileCopyrightText: 2026 box3d-godot contributors
// SPDX-License-Identifier: MIT

#include "box3d_replay_renderer.h"

#include "box3d_conversions.h"

#include <godot_cpp/classes/array_mesh.hpp>
#include <godot_cpp/classes/capsule_mesh.hpp>
#include <godot_cpp/classes/dir_access.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/classes/shader.hpp>
#include <godot_cpp/classes/sphere_mesh.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <box3d/collision.h>

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstring>

using namespace godot;

namespace {

// --- content hashing --------------------------------------------------------
//
// Geometry is deduplicated by CONTENT, never by pointer: the player destroys
// and recreates its replay world on Restart and on every backward seek
// (src/recording_replay.c:3116-3147), so the same recorded box comes back at a
// different address with the same bytes.

const uint64_t FNV_OFFSET = 1469598103934665603ull;
const uint64_t FNV_PRIME = 1099511628211ull;

inline uint64_t hash_bytes(uint64_t p_seed, const void *p_data, size_t p_size) {
	const uint8_t *b = (const uint8_t *)p_data;
	uint64_t h = p_seed;
	for (size_t i = 0; i < p_size; ++i) {
		h ^= (uint64_t)b[i];
		h *= FNV_PRIME;
	}
	return h;
}

inline uint64_t hash_u64(uint64_t p_seed, uint64_t p_value) {
	return hash_bytes(p_seed, &p_value, sizeof(p_value));
}

inline uint64_t hash_float(uint64_t p_seed, float p_value) {
	// Bit pattern, not the value: two geometries are the same mesh only if
	// their numbers are literally identical.
	uint32_t bits;
	memcpy(&bits, &p_value, sizeof(bits));
	return hash_u64(p_seed, (uint64_t)bits);
}

inline uint64_t hash_vec(uint64_t p_seed, const b3Vec3 &p_v) {
	return hash_float(hash_float(hash_float(p_seed, p_v.x), p_v.y), p_v.z);
}

inline uint64_t hash_transform(uint64_t p_seed, const b3Transform &p_t) {
	uint64_t h = hash_vec(p_seed, p_t.p);
	h = hash_vec(h, p_t.q.v);
	return hash_float(h, p_t.q.s);
}

// --- triangle sink ----------------------------------------------------------

struct TriSink {
	PackedVector3Array verts;
	PackedVector3Array normals;
	int triangles = 0;

	void add(const Vector3 &p_a, const Vector3 &p_b, const Vector3 &p_c) {
		// Flat shading from the face itself. The material shades with
		// abs(dot(N, L)) and disables culling, so a geometry whose winding
		// runs the other way is lit identically rather than turning black.
		Vector3 n = (p_b - p_a).cross(p_c - p_a);
		const real_t len = n.length();
		n = len > (real_t)1e-12 ? n / len : Vector3(0, 1, 0);
		verts.push_back(p_a);
		verts.push_back(p_b);
		verts.push_back(p_c);
		normals.push_back(n);
		normals.push_back(n);
		normals.push_back(n);
		++triangles;
	}

	Ref<ArrayMesh> build() const {
		Ref<ArrayMesh> mesh;
		if (triangles == 0) {
			return mesh;
		}
		mesh.instantiate();
		Array arrays;
		arrays.resize(Mesh::ARRAY_MAX);
		arrays[Mesh::ARRAY_VERTEX] = verts;
		arrays[Mesh::ARRAY_NORMAL] = normals;
		mesh->add_surface_from_arrays(Mesh::PRIMITIVE_TRIANGLES, arrays);
		return mesh;
	}
};

// A replay is a debugging view, not a render budget: a single recorded mesh or
// height field past this is drawn as its own local AABB instead of a million
// triangles nobody asked for. Reported as `approximate` in get_geometry_info().
const int TRIANGLE_LIMIT = 200000;

inline Vector3 to_gd_v(const b3Vec3 &v) {
	return Vector3((real_t)v.x, (real_t)v.y, (real_t)v.z);
}

inline Transform3D to_gd_transform(const b3Transform &t) {
	return Transform3D(Basis(to_gd(t.q)), to_gd_v(t.p));
}

// b3HexColor is 0x00RRGGBB with a b3DebugMaterial preset packed into the high
// byte (types.h:2939-2942). The preset drives PBR roughness in upstream's
// renderer; this one is unshaded, so it is masked off.
inline Color hex_color(b3HexColor p_color) {
	return Color::hex((uint32_t)((((uint32_t)p_color & 0x00FFFFFFu) << 8) | 0xFFu));
}

// --- per-type mesh building -------------------------------------------------

// A convex hull is a half-edge structure: every face names one of its
// half-edges, and `next` walks the face loop counter-clockwise
// (types.h:1946-1972). Fan-triangulate each loop from its first vertex.
void add_hull(TriSink &r_sink, const b3HullData *p_hull, const Transform3D &p_xf) {
	const b3Vec3 *points = b3GetHullPoints(p_hull);
	const b3HullHalfEdge *edges = b3GetHullEdges(p_hull);
	const b3HullFace *faces = b3GetHullFaces(p_hull);
	if (points == nullptr || edges == nullptr || faces == nullptr) {
		return;
	}
	for (int f = 0; f < p_hull->faceCount; ++f) {
		const uint8_t start = faces[f].edge;
		// Half-edge indices are uint8_t, so a loop can never legitimately be
		// longer than the edge count; the counter is the guard against a
		// corrupt blob spinning forever.
		Vector3 first = p_xf.xform(to_gd_v(points[edges[start].origin]));
		uint8_t e = edges[start].next;
		Vector3 prev = p_xf.xform(to_gd_v(points[edges[e].origin]));
		int guard = 0;
		for (e = edges[e].next; e != start && guard <= p_hull->edgeCount; e = edges[e].next, ++guard) {
			const Vector3 cur = p_xf.xform(to_gd_v(points[edges[e].origin]));
			r_sink.add(first, prev, cur);
			prev = cur;
		}
	}
}

void add_mesh(TriSink &r_sink, const b3MeshData *p_mesh, const Vector3 &p_scale, const Transform3D &p_xf) {
	const b3Vec3 *verts = b3GetMeshVertices(p_mesh);
	const b3MeshTriangle *tris = b3GetMeshTriangles(p_mesh);
	if (verts == nullptr || tris == nullptr) {
		return;
	}
	for (int t = 0; t < p_mesh->triangleCount; ++t) {
		const b3MeshTriangle &tri = tris[t];
		r_sink.add(
				p_xf.xform(to_gd_v(verts[tri.index1]) * p_scale),
				p_xf.xform(to_gd_v(verts[tri.index2]) * p_scale),
				p_xf.xform(to_gd_v(verts[tri.index3]) * p_scale));
	}
}

// Height fields store quantised heights (uint16) over a regular grid; the
// decode is minHeight + heightScale * compressed, then the whole grid point is
// multiplied by the field's scale (src/height_field.c:484-513). Cells whose
// material index is B3_HEIGHT_FIELD_HOLE are not surfaces and are skipped.
void add_height_field(TriSink &r_sink, const b3HeightFieldData *p_hf, const Transform3D &p_xf) {
	const uint16_t *heights = b3GetHeightFieldCompressedHeights(p_hf);
	if (heights == nullptr) {
		return;
	}
	const uint8_t *materials = b3GetHeightFieldMaterialIndices(p_hf);
	const int columns = p_hf->columnCount;
	const int rows = p_hf->rowCount;
	const b3Vec3 scale = p_hf->scale;
	auto point = [&](int p_column, int p_row) {
		const float h = p_hf->minHeight + p_hf->heightScale * (float)heights[p_row * columns + p_column];
		return p_xf.xform(Vector3(
				(real_t)((float)p_column * scale.x),
				(real_t)(h * scale.y),
				(real_t)((float)p_row * scale.z)));
	};
	for (int row = 0; row + 1 < rows; ++row) {
		for (int column = 0; column + 1 < columns; ++column) {
			if (materials != nullptr && materials[row * (columns - 1) + column] == B3_HEIGHT_FIELD_HOLE) {
				continue;
			}
			const Vector3 c00 = point(column, row);
			const Vector3 c10 = point(column + 1, row);
			const Vector3 c01 = point(column, row + 1);
			const Vector3 c11 = point(column + 1, row + 1);
			r_sink.add(c00, c01, c11);
			r_sink.add(c00, c11, c10);
		}
	}
}

void add_box(TriSink &r_sink, const AABB &p_box) {
	const Vector3 lo = p_box.position;
	const Vector3 hi = p_box.position + p_box.size;
	const Vector3 v[8] = {
		Vector3(lo.x, lo.y, lo.z), Vector3(hi.x, lo.y, lo.z),
		Vector3(hi.x, hi.y, lo.z), Vector3(lo.x, hi.y, lo.z),
		Vector3(lo.x, lo.y, hi.z), Vector3(hi.x, lo.y, hi.z),
		Vector3(hi.x, hi.y, hi.z), Vector3(lo.x, hi.y, hi.z)
	};
	static const int faces[6][4] = {
		{ 0, 3, 2, 1 }, { 4, 5, 6, 7 }, { 0, 1, 5, 4 },
		{ 3, 7, 6, 2 }, { 0, 4, 7, 3 }, { 1, 2, 6, 5 }
	};
	for (int f = 0; f < 6; ++f) {
		r_sink.add(v[faces[f][0]], v[faces[f][1]], v[faces[f][2]]);
		r_sink.add(v[faces[f][0]], v[faces[f][2]], v[faces[f][3]]);
	}
}

inline AABB to_gd_aabb(const b3AABB &p_aabb) {
	const Vector3 lower = to_gd_pos(p_aabb.lowerBound);
	const Vector3 upper = to_gd_pos(p_aabb.upperBound);
	return AABB(lower, upper - lower);
}

} // namespace

// --- Box3DReplayRenderer ----------------------------------------------------

Box3DReplayRenderer::Box3DReplayRenderer() {
	// The measurement hatch for the full-frame interval, read once. 32 is what
	// the sweep in perf_replay.gd picked; this is how that sweep was taken and
	// how it can be retaken on other content without a rebuild.
	const char *env = std::getenv("B3_REPLAY_CACHE_CHUNK");
	if (env != nullptr) {
		const int n = atoi(env);
		if (n >= 1 && n <= 4096) {
			chunk_frames = n;
		}
	}
}

Box3DReplayRenderer::~Box3DReplayRenderer() {
	// Godot frees the child nodes itself; what it cannot know about is the
	// callbacks Box3D still holds and the handles they returned.
	uninstall();
	detach_all_handles();
	// And the temp file, which nothing else knows about. A replay session must
	// not leave hundreds of megabytes behind under user://.
	close_spill();
}

void *Box3DReplayRenderer::cb_create_debug_shape(const b3DebugShape *p_shape, void *p_context) {
	return ((Box3DReplayRenderer *)p_context)->create_shape_handle(p_shape);
}

void Box3DReplayRenderer::cb_destroy_debug_shape(void *p_user_shape, void *p_context) {
	((Box3DReplayRenderer *)p_context)->destroy_shape_handle(p_user_shape);
}

void Box3DReplayRenderer::cb_draw_shape(void *p_user_shape, b3WorldTransform p_transform,
		b3HexColor p_color, void *p_context) {
	Box3DReplayRenderer *self = (Box3DReplayRenderer *)p_context;
	ShapeHandle *handle = (ShapeHandle *)p_user_shape;
	if (handle == nullptr) {
		return;
	}
	const Transform3D body(Basis(to_gd(p_transform.q)), to_gd_pos(p_transform.p));
	self->push_instance(handle, body, hex_color(p_color));
}

int Box3DReplayRenderer::intern_geometry(uint64_t p_key, b3ShapeType p_type, const Ref<Mesh> &p_mesh,
		int p_triangle_count, bool p_approximate) {
	auto it = geometry_by_key.find(p_key);
	if (it != geometry_by_key.end()) {
		return it->second;
	}
	Geometry g;
	g.key = p_key;
	g.type = p_type;
	g.mesh = p_mesh;
	g.triangle_count = p_triangle_count;
	g.approximate = p_approximate;
	geometries.push_back(g);
	const int index = (int)geometries.size() - 1;
	geometry_by_key[p_key] = index;
	return index;
}

void *Box3DReplayRenderer::create_shape_handle(const b3DebugShape *p_shape) {
	if (p_shape == nullptr) {
		return nullptr;
	}

	int geometry = -1;
	Transform3D local;

	switch (p_shape->type) {
		case b3_sphereShape: {
			const b3Sphere *s = p_shape->sphere;
			if (s == nullptr) {
				return nullptr;
			}
			// The centre goes into the per-shape transform, not the mesh, so
			// every sphere of this radius shares one mesh.
			local.origin = to_gd_v(s->center);
			const uint64_t key = hash_float(hash_u64(FNV_OFFSET, (uint64_t)b3_sphereShape), s->radius);
			auto it = geometry_by_key.find(key);
			if (it != geometry_by_key.end()) {
				geometry = it->second;
			} else {
				Ref<SphereMesh> mesh;
				mesh.instantiate();
				mesh->set_radius(s->radius);
				mesh->set_height(s->radius * 2.0f);
				mesh->set_radial_segments(24);
				mesh->set_rings(12);
				geometry = intern_geometry(key, b3_sphereShape, mesh, 24 * 12 * 2, false);
			}
		} break;

		case b3_capsuleShape: {
			const b3Capsule *c = p_shape->capsule;
			if (c == nullptr) {
				return nullptr;
			}
			const Vector3 c1 = to_gd_v(c->center1);
			const Vector3 c2 = to_gd_v(c->center2);
			const Vector3 axis = c2 - c1;
			const real_t length = axis.length();
			// Godot's CapsuleMesh runs along +Y and its height is the TOTAL
			// height including both hemispheres.
			local.origin = (c1 + c2) * 0.5f;
			if (length > (real_t)1e-9) {
				local.basis = Basis(Quaternion(Vector3(0, 1, 0), axis / length));
			}
			uint64_t key = hash_u64(FNV_OFFSET, (uint64_t)b3_capsuleShape);
			key = hash_float(hash_float(key, c->radius), (float)length);
			auto it = geometry_by_key.find(key);
			if (it != geometry_by_key.end()) {
				geometry = it->second;
			} else {
				Ref<CapsuleMesh> mesh;
				mesh.instantiate();
				mesh->set_radius(c->radius);
				mesh->set_height((real_t)length + c->radius * 2.0f);
				mesh->set_radial_segments(24);
				mesh->set_rings(8);
				geometry = intern_geometry(key, b3_capsuleShape, mesh, 24 * 10 * 2, false);
			}
		} break;

		case b3_hullShape: {
			const b3HullData *h = p_shape->hull;
			if (h == nullptr) {
				return nullptr;
			}
			// Upstream computes a content hash over the whole blob with the
			// hash field zeroed (types.h:1983), which is exactly the identity
			// this wants — two boxes of the same size hash the same however
			// many times the replay world is rebuilt.
			const uint64_t key = hash_u64(hash_u64(FNV_OFFSET, (uint64_t)b3_hullShape), (uint64_t)h->hash);
			auto it = geometry_by_key.find(key);
			if (it != geometry_by_key.end()) {
				geometry = it->second;
			} else {
				TriSink sink;
				add_hull(sink, h, Transform3D());
				Ref<Mesh> mesh = sink.build();
				if (mesh.is_null()) {
					return nullptr;
				}
				geometry = intern_geometry(key, b3_hullShape, mesh, sink.triangles, false);
			}
		} break;

		case b3_meshShape: {
			const b3Mesh *m = p_shape->mesh;
			if (m == nullptr || m->data == nullptr) {
				return nullptr;
			}
			uint64_t key = hash_u64(hash_u64(FNV_OFFSET, (uint64_t)b3_meshShape), (uint64_t)m->data->hash);
			key = hash_vec(key, m->scale);
			auto it = geometry_by_key.find(key);
			if (it != geometry_by_key.end()) {
				geometry = it->second;
			} else {
				if (m->data->triangleCount > TRIANGLE_LIMIT) {
					TriSink sink;
					add_box(sink, to_gd_aabb(m->data->bounds));
					geometry = intern_geometry(key, b3_meshShape, sink.build(), sink.triangles, true);
				} else {
					TriSink sink;
					add_mesh(sink, m->data, to_gd_v(m->scale), Transform3D());
					Ref<Mesh> mesh = sink.build();
					if (mesh.is_null()) {
						return nullptr;
					}
					geometry = intern_geometry(key, b3_meshShape, mesh, sink.triangles, false);
				}
			}
		} break;

		case b3_heightShape: {
			const b3HeightFieldData *hf = p_shape->heightField;
			if (hf == nullptr) {
				return nullptr;
			}
			const uint64_t key = hash_u64(hash_u64(FNV_OFFSET, (uint64_t)b3_heightShape), (uint64_t)hf->hash);
			auto it = geometry_by_key.find(key);
			if (it != geometry_by_key.end()) {
				geometry = it->second;
			} else {
				const int64_t tris = 2ll * (int64_t)(hf->columnCount - 1) * (int64_t)(hf->rowCount - 1);
				TriSink sink;
				bool approximate = false;
				if (tris > TRIANGLE_LIMIT || tris <= 0) {
					add_box(sink, to_gd_aabb(hf->aabb));
					approximate = true;
				} else {
					add_height_field(sink, hf, Transform3D());
				}
				Ref<Mesh> mesh = sink.build();
				if (mesh.is_null()) {
					return nullptr;
				}
				geometry = intern_geometry(key, b3_heightShape, mesh, sink.triangles, approximate);
			}
		} break;

		case b3_compoundShape: {
			const b3CompoundData *c = p_shape->compound;
			if (c == nullptr) {
				return nullptr;
			}
			// A compound has no content hash of its own, and byte-hashing the
			// blob would be unstable (it holds pointers into other blobs and a
			// dynamic tree). Hash the CHILD DESCRIPTORS instead: their own
			// hashes and their local transforms are the whole visual identity.
			uint64_t key = hash_u64(FNV_OFFSET, (uint64_t)b3_compoundShape);
			for (int i = 0; i < c->sphereCount; ++i) {
				const b3CompoundSphere s = b3GetCompoundSphere(c, i);
				key = hash_float(hash_vec(key, s.sphere.center), s.sphere.radius);
			}
			for (int i = 0; i < c->capsuleCount; ++i) {
				const b3CompoundCapsule cap = b3GetCompoundCapsule(c, i);
				key = hash_vec(hash_vec(key, cap.capsule.center1), cap.capsule.center2);
				key = hash_float(key, cap.capsule.radius);
			}
			for (int i = 0; i < c->hullCount; ++i) {
				const b3CompoundHull h = b3GetCompoundHull(c, i);
				key = hash_u64(key, h.hull != nullptr ? (uint64_t)h.hull->hash : 0);
				key = hash_transform(key, h.transform);
			}
			for (int i = 0; i < c->meshCount; ++i) {
				const b3CompoundMesh m = b3GetCompoundMesh(c, i);
				key = hash_u64(key, m.meshData != nullptr ? (uint64_t)m.meshData->hash : 0);
				key = hash_vec(hash_transform(key, m.transform), m.scale);
			}
			auto it = geometry_by_key.find(key);
			if (it != geometry_by_key.end()) {
				geometry = it->second;
			} else {
				// Baked flat into ONE mesh: a debug-shape callback returns one
				// handle per shape, and a compound is one shape.
				TriSink sink;
				for (int i = 0; i < c->sphereCount; ++i) {
					const b3CompoundSphere s = b3GetCompoundSphere(c, i);
					// A UV sphere is overkill inside a compound; an octahedral
					// subdivision would be nicer but this stays a debug view.
					AABB box;
					box.position = to_gd_v(s.sphere.center) - Vector3(1, 1, 1) * s.sphere.radius;
					box.size = Vector3(1, 1, 1) * (s.sphere.radius * 2.0f);
					add_box(sink, box);
				}
				for (int i = 0; i < c->capsuleCount; ++i) {
					const b3CompoundCapsule cap = b3GetCompoundCapsule(c, i);
					AABB box;
					const Vector3 a = to_gd_v(cap.capsule.center1);
					const Vector3 b = to_gd_v(cap.capsule.center2);
					const Vector3 r = Vector3(1, 1, 1) * cap.capsule.radius;
					const Vector3 lo(MIN(a.x, b.x), MIN(a.y, b.y), MIN(a.z, b.z));
					const Vector3 hi(MAX(a.x, b.x), MAX(a.y, b.y), MAX(a.z, b.z));
					box.position = lo - r;
					box.size = (hi + r) - box.position;
					add_box(sink, box);
				}
				for (int i = 0; i < c->hullCount; ++i) {
					const b3CompoundHull h = b3GetCompoundHull(c, i);
					if (h.hull != nullptr) {
						add_hull(sink, h.hull, to_gd_transform(h.transform));
					}
				}
				for (int i = 0; i < c->meshCount; ++i) {
					const b3CompoundMesh m = b3GetCompoundMesh(c, i);
					if (m.meshData != nullptr && m.meshData->triangleCount <= TRIANGLE_LIMIT) {
						add_mesh(sink, m.meshData, to_gd_v(m.scale), to_gd_transform(m.transform));
					}
				}
				Ref<Mesh> mesh = sink.build();
				if (mesh.is_null()) {
					return nullptr;
				}
				// Spheres and capsules inside a compound are drawn as their
				// bounding boxes, so the whole thing is flagged approximate
				// whenever it has any.
				const bool approximate = c->sphereCount > 0 || c->capsuleCount > 0;
				geometry = intern_geometry(key, b3_compoundShape, mesh, sink.triangles, approximate);
			}
		} break;

		default:
			// A shape type this build does not know. Returning null leaves
			// shape->userShape null upstream, which simply retries next draw
			// (src/physics_world.c:1309) — no leak, nothing drawn.
			return nullptr;
	}

	if (geometry < 0) {
		return nullptr;
	}
	ShapeHandle *handle = new ShapeHandle();
	handle->geometry = geometry;
	handle->local = local;
	// The slot, assigned once and never reused. Appending it to the geometry's
	// list here — inside the create callback, which upstream fires before the
	// first draw of this shape (src/physics_world.c:1309-1348) — is what keeps
	// the list ascending and the row order reproducible.
	handle->slot = slot_count++;
	ensure_slot(handle->slot);
	geometries[geometry].slots.push_back(handle->slot);
	// The owning body's identity, resolved once. b3Shape_GetBody is valid here:
	// upstream fills debugShape.shapeId before calling us
	// (src/physics_world.c:1312-1316), and a shape's body never changes.
	const b3BodyId body = b3Shape_GetBody(p_shape->shapeId);
	handle->body_key = ((uint64_t)(uint32_t)body.index1 << 16) | (uint64_t)body.generation;
	resolve_override(handle);
	resolve_material(handle);
	write_slot_material(handle);
	handles.insert(handle);
	return handle;
}

void Box3DReplayRenderer::resolve_override(ShapeHandle *p_handle) {
	p_handle->has_override = false;
	if (body_colors.empty()) {
		return;
	}
	auto it = body_colors.find(p_handle->body_key);
	if (it == body_colors.end()) {
		return;
	}
	p_handle->has_override = true;
	p_handle->override_color = it->second;
}

void Box3DReplayRenderer::resolve_overrides() {
	for (ShapeHandle *handle : handles) {
		resolve_override(handle);
	}
}

void Box3DReplayRenderer::set_body_color_overrides(const Dictionary &p_colors) {
	body_colors_source = p_colors;
	body_colors.clear();
	const Array keys = p_colors.keys();
	for (int i = 0; i < keys.size(); ++i) {
		const String key = keys[i];
		const int sep = key.find(":");
		if (sep <= 0) {
			continue; // not "<index1>:<generation>"; ignored, never fatal
		}
		const int64_t index1 = key.substr(0, sep).to_int();
		const int64_t generation = key.substr(sep + 1).to_int();
		if (index1 <= 0 || generation < 0 || generation > 0xFFFF) {
			continue;
		}
		body_colors[((uint64_t)(uint32_t)index1 << 16) | (uint64_t)generation] =
				(Color)p_colors[keys[i]];
	}
	resolve_overrides();
	// The cached rows carry the colour they were filled with, so a table change
	// makes every one of them stale.
	clear_frame_cache();
}

Dictionary Box3DReplayRenderer::get_body_color_overrides() const {
	return body_colors_source;
}

void Box3DReplayRenderer::resolve_material(ShapeHandle *p_handle) {
	p_handle->has_material = false;
	if (body_materials.empty()) {
		return;
	}
	auto it = body_materials.find(p_handle->body_key);
	if (it == body_materials.end()) {
		return;
	}
	p_handle->has_material = true;
	p_handle->material_roughness = (float)it->second.x;
	p_handle->material_metallic = (float)it->second.y;
	p_handle->material_specular = (float)it->second.z;
}

void Box3DReplayRenderer::write_slot_material(const ShapeHandle *p_handle) {
	if (p_handle->slot < 0) {
		return;
	}
	ensure_slot(p_handle->slot);
	float *m = slot_material.data() + (size_t)p_handle->slot * 4;
	if (!p_handle->has_material) {
		// The modal default. Written rather than left alone, because a table
		// can be replaced with one that no longer names this body.
		m[0] = 0.85f;
		m[1] = 0.0f;
		m[2] = 0.35f;
		m[3] = 0.0f;
		return;
	}
	m[0] = p_handle->material_roughness;
	m[1] = p_handle->material_metallic;
	m[2] = p_handle->material_specular;
	m[3] = 1.0f;
}

// Widen the instance row to carry custom data. One-off, and only when a
// material table is actually set: without one every replay would pay 25% more
// upload for four floats that are always the same.
void Box3DReplayRenderer::enable_custom_data() {
	if (use_custom_data) {
		return;
	}
	use_custom_data = true;
	row_stride = 20;
	// MultiMesh cannot change its format under an allocated buffer, so the
	// resources are rebuilt. The geometries, the slots and the FRAME CACHE all
	// survive: none of them describe the row layout.
	for (Geometry &g : geometries) {
		if (g.mmi != nullptr) {
			remove_child(g.mmi);
			memdelete(g.mmi);
			g.mmi = nullptr;
		}
		g.mm.unref();
		g.allocated = 0;
		g.buffer.resize(0);
	}
	ensure_nodes();
}

void Box3DReplayRenderer::set_body_material_overrides(const Dictionary &p_materials) {
	body_materials_source = p_materials;
	body_materials.clear();
	const Array keys = p_materials.keys();
	for (int i = 0; i < keys.size(); ++i) {
		const String key = keys[i];
		const int sep = key.find(":");
		if (sep <= 0) {
			continue; // not "<index1>:<generation>"; ignored, never fatal
		}
		const int64_t index1 = key.substr(0, sep).to_int();
		const int64_t generation = key.substr(sep + 1).to_int();
		if (index1 <= 0 || generation < 0 || generation > 0xFFFF) {
			continue;
		}
		const Variant value = p_materials[keys[i]];
		if (value.get_type() != Variant::DICTIONARY) {
			continue;
		}
		const Dictionary d = value;
		// Anything the entry leaves out keeps the renderer's own response, so a
		// host can send one property without having to state the other two.
		auto pick = [&](const char *p_name, float p_fallback) {
			if (!d.has(p_name)) {
				return p_fallback;
			}
			const float v = (float)(double)d[p_name];
			return v < 0.0f ? 0.0f : (v > 1.0f ? 1.0f : v);
		};
		body_materials[((uint64_t)(uint32_t)index1 << 16) | (uint64_t)generation] =
				Vector3((real_t)pick("roughness", 0.85f), (real_t)pick("metallic", 0.0f),
						(real_t)pick("specular", 0.35f));
	}
	for (ShapeHandle *handle : handles) {
		resolve_material(handle);
		write_slot_material(handle);
	}
	if (!body_materials.empty()) {
		enable_custom_data();
	}
	// NO clear_frame_cache(). A cached frame stores transforms and colour; the
	// shading response is per slot and is written at compaction, so every frame
	// already in the cache comes back with the new table applied.
}

Dictionary Box3DReplayRenderer::get_body_material_overrides() const {
	return body_materials_source;
}

int Box3DReplayRenderer::get_override_instance_count() const {
	return last_override_count;
}

void Box3DReplayRenderer::destroy_shape_handle(void *p_user_shape) {
	ShapeHandle *handle = (ShapeHandle *)p_user_shape;
	if (handle == nullptr) {
		return;
	}
	if (handles.erase(handle) > 0) {
		delete handle;
	}
}

void Box3DReplayRenderer::detach_all_handles() {
	for (ShapeHandle *handle : handles) {
		delete handle;
	}
	handles.clear();
}

void Box3DReplayRenderer::push_instance(ShapeHandle *p_handle, const Transform3D &p_body, const Color &p_color) {
	if (p_handle->geometry < 0 || p_handle->geometry >= (int)geometries.size()) {
		return;
	}
	if (p_handle->slot < 0) {
		return;
	}
	// DrawShapeFcn reports the BODY transform (src/physics_world.c:1353), so
	// the shape's own offset is applied here.
	const Transform3D t = p_body * p_handle->local;

	// F-042. The host's colour for this body wins over the recording's state
	// palette, except under debug_style, where the state palette IS the answer
	// the view was asked for.
	Color color = p_color;
	if (p_handle->has_override && !debug_style) {
		color = p_handle->override_color;
		++last_override_count;
	}

	// The row goes to this shape's SLOT, not to the end of a growing list: the
	// order Box3D visits shapes in is broad-phase tree order and it changes as
	// bodies move, and a delta has to be able to name an instance. compact_live()
	// turns these into the dense buffer once the walk knows what is present.
	ensure_slot(p_handle->slot);
	live_present[(size_t)p_handle->slot >> 6] |= (uint64_t)1 << (p_handle->slot & 63);
	float *inst = live_rows.data() + (int64_t)p_handle->slot * 16;
	// MultiMesh 3D rows are three float4s: the basis rows with the origin in
	// the w slot, then the instance colour.
	inst[0] = (float)t.basis.rows[0][0];
	inst[1] = (float)t.basis.rows[0][1];
	inst[2] = (float)t.basis.rows[0][2];
	inst[3] = (float)t.origin.x;
	inst[4] = (float)t.basis.rows[1][0];
	inst[5] = (float)t.basis.rows[1][1];
	inst[6] = (float)t.basis.rows[1][2];
	inst[7] = (float)t.origin.y;
	inst[8] = (float)t.basis.rows[2][0];
	inst[9] = (float)t.basis.rows[2][1];
	inst[10] = (float)t.basis.rows[2][2];
	inst[11] = (float)t.origin.z;
	inst[12] = color.r;
	inst[13] = color.g;
	inst[14] = color.b;
	inst[15] = color.a;
}

void Box3DReplayRenderer::ensure_slot(int p_slot) {
	if (p_slot < 0) {
		return;
	}
	if (p_slot >= slot_count) {
		slot_count = p_slot + 1;
	}
	const size_t rows = (size_t)slot_count;
	if (live_rows.size() < rows * 16) {
		live_rows.resize(rows * 16, 0.0f);
	}
	if (enc_ref.size() < rows) {
		enc_ref.resize(rows);
	}
	if (dec_state.size() < rows) {
		dec_state.resize(rows);
	}
	if (slot_material.size() < rows * 4) {
		const size_t was = slot_material.size();
		slot_material.resize(rows * 4);
		// The modal default, so a slot with no entry needs nothing written.
		for (size_t i = was; i < slot_material.size(); i += 4) {
			slot_material[i] = 0.85f;
			slot_material[i + 1] = 0.0f;
			slot_material[i + 2] = 0.35f;
			slot_material[i + 3] = 0.0f;
		}
	}
	const size_t words = (rows + 63) / 64;
	// New words are zero, so a slot that did not exist yet is simply absent
	// from the frame being built and from both reference states.
	if (live_present.size() < words) {
		live_present.resize(words, 0);
	}
	if (enc_present.size() < words) {
		enc_present.resize(words, 0);
	}
	if (dec_present.size() < words) {
		dec_present.resize(words, 0);
	}
}

namespace {

inline bool bit_set(const std::vector<uint64_t> &p_bits, int p_slot) {
	const size_t word = (size_t)p_slot >> 6;
	return word < p_bits.size() && (p_bits[word] & ((uint64_t)1 << (p_slot & 63))) != 0;
}

// Pack one MultiMesh row into the cached form. The basis is orthonormal by
// construction (a recorded body transform times a translate-and-rotate shape
// offset), so the quaternion round trip loses float rounding, not information.
inline void pack_row(const float *p_row, Box3DReplayRenderer::RawInstance &r_out) {
	Basis b;
	b.rows[0] = Vector3((real_t)p_row[0], (real_t)p_row[1], (real_t)p_row[2]);
	b.rows[1] = Vector3((real_t)p_row[4], (real_t)p_row[5], (real_t)p_row[6]);
	b.rows[2] = Vector3((real_t)p_row[8], (real_t)p_row[9], (real_t)p_row[10]);
	const Quaternion q = b.get_quaternion();
	r_out.px = p_row[3];
	r_out.py = p_row[7];
	r_out.pz = p_row[11];
	r_out.qx = (float)q.x;
	r_out.qy = (float)q.y;
	r_out.qz = (float)q.z;
	r_out.qw = (float)q.w;
	// The palette is upstream's 8-bit hex (types.h:2939-2942), so this is a
	// lossless round trip, not a quantisation.
	uint32_t rgba = 0;
	for (int c = 0; c < 4; ++c) {
		const float v = p_row[12 + c] < 0.0f ? 0.0f : (p_row[12 + c] > 1.0f ? 1.0f : p_row[12 + c]);
		rgba |= (uint32_t)(v * 255.0f + 0.5f) << (c * 8);
	}
	r_out.rgba = rgba;
}

inline void unpack_row(const Box3DReplayRenderer::RawInstance &p_ci, float *r_row) {
	const Basis b(Quaternion((real_t)p_ci.qx, (real_t)p_ci.qy, (real_t)p_ci.qz, (real_t)p_ci.qw));
	r_row[0] = (float)b.rows[0][0];
	r_row[1] = (float)b.rows[0][1];
	r_row[2] = (float)b.rows[0][2];
	r_row[3] = p_ci.px;
	r_row[4] = (float)b.rows[1][0];
	r_row[5] = (float)b.rows[1][1];
	r_row[6] = (float)b.rows[1][2];
	r_row[7] = p_ci.py;
	r_row[8] = (float)b.rows[2][0];
	r_row[9] = (float)b.rows[2][1];
	r_row[10] = (float)b.rows[2][2];
	r_row[11] = p_ci.pz;
	r_row[12] = (float)((p_ci.rgba >> 0) & 0xFF) / 255.0f;
	r_row[13] = (float)((p_ci.rgba >> 8) & 0xFF) / 255.0f;
	r_row[14] = (float)((p_ci.rgba >> 16) & 0xFF) / 255.0f;
	r_row[15] = (float)((p_ci.rgba >> 24) & 0xFF) / 255.0f;
}

// The custom-data half of an instance row: the body's shading response, or the
// renderer's own when it has none. Four floats, the last one the shader's
// "these are real" flag — a MultiMesh with custom data off hands the shader
// zeroes, and a zero flag is exactly what makes it fall back to the default.
inline void write_custom(float *r_row, const float *p_material) {
	if (p_material == nullptr || p_material[3] < 0.5f) {
		r_row[0] = 0.85f;
		r_row[1] = 0.0f;
		r_row[2] = 0.35f;
		r_row[3] = 0.0f;
		return;
	}
	r_row[0] = p_material[0];
	r_row[1] = p_material[1];
	r_row[2] = p_material[2];
	r_row[3] = 1.0f;
}

// THE PACKING, and the whole of the fidelity argument for it.
//
// 21 bits per position axis against the FRAME'S OWN AABB, and the quaternion
// smallest-three at 20 bits a component. Both bounds are stated rather than
// hoped for:
//
//   position   step = span / (2^21 - 1), error <= one step. Over Cube Pile's
//              ~20 m that is 9.5 um per axis (1.6e-5 on the vector); over Huge
//              Pyramid's ~400 m of rubble it is 0.19 mm. The fidelity assertion
//              in test_features.gd allows 1e-4 and measures on Cube Pile, so
//              this clears it by six times.
//   rotation   a unit quaternion's largest component is never below 1/2, so
//              reconstructing it from the other three amplifies their 6.7e-7
//              by at most ~4x; the basis it builds lands within ~6e-6 of the
//              one it came from, against the 5e-7 the plain quaternion round
//              trip had and the 1e-4 the assertion allows.
//   colour     exact. Upstream's palette is 8-bit hex (types.h:2939-2942) and
//              the override colours are the host's own art, which has to come
//              back the colour it went in as.
//
// This is deliberately NOT a fixed world grid. A fixed step fine enough for
// Cube Pile (0.1 mm) only reaches +/-128 m in 21 bits, which Huge Pyramid's
// own coordinates already leave; per frame, precision follows the content.
constexpr int POS_BITS_MAX = 2097151; // 2^21 - 1
constexpr float ROT_SCALE = 1048575.0f; // 2^20 - 1
constexpr float ROT_RANGE = 0.70710678f;

// THE EPSILON a delta is taken against. It is per axis, and it is at least half
// the frame's own quantisation step: below that, an instance that has not moved
// at all still reads as moved the moment the frame's AABB shifts under it, and
// delta coding would carry the whole scene every frame for nothing. Away from
// the grid it is 5e-7, at or below the quaternion round trip the cache had
// before any of this.
//
// It is compared against WHAT THE DECODER WILL HOLD -- the dequantised value,
// not the one we were handed -- so a shape creeping by less than the epsilon
// each frame is re-sent as soon as its total drift crosses it. The error is
// bounded by one step, never accumulated along the chain.
constexpr float CACHE_EPSILON = 5e-7f;

inline bool instance_moved(const Box3DReplayRenderer::RawInstance &a,
		const Box3DReplayRenderer::RawInstance &b, const float *p_pos_eps) {
	if (a.rgba != b.rgba) {
		return true;
	}
	return fabsf(a.px - b.px) > p_pos_eps[0] || fabsf(a.py - b.py) > p_pos_eps[1] ||
			fabsf(a.pz - b.pz) > p_pos_eps[2] || fabsf(a.qx - b.qx) > CACHE_EPSILON ||
			fabsf(a.qy - b.qy) > CACHE_EPSILON || fabsf(a.qz - b.qz) > CACHE_EPSILON ||
			fabsf(a.qw - b.qw) > CACHE_EPSILON;
}

inline uint32_t quantize_axis(float p_v, float p_min, float p_step) {
	if (p_step <= 0.0f) {
		return 0;
	}
	const float t = (p_v - p_min) / p_step;
	const int64_t q = (int64_t)(t + 0.5f);
	return (uint32_t)(q < 0 ? 0 : (q > POS_BITS_MAX ? POS_BITS_MAX : q));
}

inline void quantize(const Box3DReplayRenderer::RawInstance &p_in, const float *p_min,
		const float *p_step, Box3DReplayRenderer::CachedInstance &r_out) {
	const uint32_t x = quantize_axis(p_in.px, p_min[0], p_step[0]);
	const uint32_t y = quantize_axis(p_in.py, p_min[1], p_step[1]);
	const uint32_t z = quantize_axis(p_in.pz, p_min[2], p_step[2]);
	r_out.pos0 = x | ((y & 0x7FF) << 21);
	r_out.pos1 = (y >> 11) | (z << 10);

	// Smallest three: drop the largest component and rebuild it from the unit
	// constraint, with the sign chosen so the dropped one is positive.
	const float q[4] = { p_in.qx, p_in.qy, p_in.qz, p_in.qw };
	int idx = 0;
	float best = fabsf(q[0]);
	for (int i = 1; i < 4; ++i) {
		const float m = fabsf(q[i]);
		if (m > best) {
			best = m;
			idx = i;
		}
	}
	const float sign = q[idx] < 0.0f ? -1.0f : 1.0f;
	uint32_t u[3];
	int w = 0;
	for (int i = 0; i < 4; ++i) {
		if (i == idx) {
			continue;
		}
		float v = q[i] * sign;
		v = v < -ROT_RANGE ? -ROT_RANGE : (v > ROT_RANGE ? ROT_RANGE : v);
		u[w++] = (uint32_t)(((v + ROT_RANGE) / (2.0f * ROT_RANGE)) * ROT_SCALE + 0.5f);
	}
	r_out.rot0 = (uint32_t)idx | (u[0] << 2) | ((u[1] & 0x3FF) << 22);
	r_out.rot1 = (u[1] >> 10) | (u[2] << 10);
	r_out.rgba = p_in.rgba;
}

inline void dequantize(const Box3DReplayRenderer::CachedInstance &p_in, const float *p_min,
		const float *p_step, Box3DReplayRenderer::RawInstance &r_out) {
	const uint32_t x = p_in.pos0 & 0x1FFFFF;
	const uint32_t y = ((p_in.pos0 >> 21) & 0x7FF) | ((p_in.pos1 & 0x3FF) << 11);
	const uint32_t z = (p_in.pos1 >> 10) & 0x1FFFFF;
	r_out.px = p_min[0] + (float)x * p_step[0];
	r_out.py = p_min[1] + (float)y * p_step[1];
	r_out.pz = p_min[2] + (float)z * p_step[2];

	const int idx = (int)(p_in.rot0 & 3);
	const uint32_t u[3] = {
		(p_in.rot0 >> 2) & 0xFFFFF,
		((p_in.rot0 >> 22) & 0x3FF) | ((p_in.rot1 & 0x3FF) << 10),
		(p_in.rot1 >> 10) & 0xFFFFF,
	};
	float v[3];
	float sum = 0.0f;
	for (int i = 0; i < 3; ++i) {
		v[i] = ((float)u[i] / ROT_SCALE) * (2.0f * ROT_RANGE) - ROT_RANGE;
		sum += v[i] * v[i];
	}
	const float rest = sum >= 1.0f ? 0.0f : sqrtf(1.0f - sum);
	float q[4];
	int w = 0;
	for (int i = 0; i < 4; ++i) {
		q[i] = i == idx ? rest : v[w++];
	}
	r_out.qx = q[0];
	r_out.qy = q[1];
	r_out.qz = q[2];
	r_out.qw = q[3];
	r_out.rgba = p_in.rgba;
}

} // namespace

// The dense buffers, from the live walk's full-precision rows. One pass to
// learn how many slots this geometry has this frame, one to copy them: the row
// ORDER is the geometry's slot list, which is stable whatever order Box3D
// visited the shapes in.
void Box3DReplayRenderer::compact_live() {
	for (Geometry &g : geometries) {
		int n = 0;
		for (int slot : g.slots) {
			n += bit_set(live_present, slot) ? 1 : 0;
		}
		g.count = n;
		if (n == 0) {
			continue;
		}
		const int64_t need = (int64_t)n * row_stride;
		if (g.buffer.size() < need) {
			const int64_t grow = g.buffer.size() * 2;
			g.buffer.resize(grow < need ? need : grow);
		}
		float *dst = g.buffer.ptrw();
		const bool mats = use_custom_data && !debug_style;
		int w = 0;
		for (int slot : g.slots) {
			if (!bit_set(live_present, slot)) {
				continue;
			}
			float *row = dst + (int64_t)w * row_stride;
			memcpy(row, live_rows.data() + (int64_t)slot * 16, 16 * sizeof(float));
			if (row_stride > 16) {
				write_custom(row + 16, mats ? slot_material.data() + (size_t)slot * 4 : nullptr);
			}
			++w;
		}
	}
}

// The same, from the decoder's packed state.
void Box3DReplayRenderer::compact_decoded() {
	for (Geometry &g : geometries) {
		int n = 0;
		for (int slot : g.slots) {
			n += bit_set(dec_present, slot) ? 1 : 0;
		}
		g.count = n;
		if (n == 0) {
			continue;
		}
		const int64_t need = (int64_t)n * row_stride;
		if (g.buffer.size() < need) {
			const int64_t grow = g.buffer.size() * 2;
			g.buffer.resize(grow < need ? need : grow);
		}
		float *dst = g.buffer.ptrw();
		const bool mats = use_custom_data && !debug_style;
		int w = 0;
		for (int slot : g.slots) {
			if (!bit_set(dec_present, slot)) {
				continue;
			}
			float *row = dst + (int64_t)w * row_stride;
			unpack_row(dec_state[(size_t)slot], row);
			if (row_stride > 16) {
				write_custom(row + 16, mats ? slot_material.data() + (size_t)slot * 4 : nullptr);
			}
			++w;
		}
	}
}

void Box3DReplayRenderer::ensure_material() {
	if (material_lit.is_null()) {
		Ref<Shader> shader;
		shader.instantiate();
		// THE DEFAULT LOOK (F-038). An ordinary lit surface: the host scene's
		// lights and environment shade it, so a replay opened with the shell's
		// Debug switch off looks like objects rather than like a debug overlay.
		// The colour is still the one the recording carries — a recording holds
		// the solver's geometry and the solver's state colours and no art at
		// all — but it is albedo under real light, not a flat fill.
		//
		// The winding fix earns its place: recorded hulls can come back wound
		// the other way (which is why culling is off here as it is in the debug
		// shader), and an un-flipped normal would light those faces from the
		// wrong side instead of merely drawing them dark.
		shader->set_code(R"(shader_type spatial;
render_mode cull_disabled;

// The host's shading response for this body, or zeroes. INSTANCE_CUSTOM is a
// vertex-stage input, so it has to be carried across; w is the flag, and it is
// zero both for a body with no entry and for a MultiMesh with custom data
// turned off, which is why the fallback is written once here.
varying vec4 v_material;

void vertex() {
	v_material = INSTANCE_CUSTOM;
}

void fragment() {
	// Upstream's palette is sRGB hex; linearize so the rendered colour matches.
	ALBEDO = pow(COLOR.rgb, vec3(2.2));
	bool has = v_material.w > 0.5;
	ROUGHNESS = has ? v_material.x : 0.85;
	METALLIC = has ? v_material.y : 0.0;
	SPECULAR = has ? v_material.z : 0.35;
	NORMAL = FRONT_FACING ? NORMAL : -NORMAL;
}
)");
		material_lit.instantiate();
		material_lit->set_shader(shader);
	}
	if (material_debug.is_null()) {
		Ref<Shader> shader;
		shader.instantiate();
		// Same treatment as Box3DWorld's debug shells (box3d_world.cpp:2279-
		// 2289): a fixed-direction half-lambert so the replay's state colours
		// read identically whatever the host scene's lighting is doing, and the
		// sRGB hex palette linearised so the rendered colour matches upstream's.
		// abs() on the lambert term with culling off means a hull whose winding
		// runs the other way is lit, not black.
		shader->set_code(R"(shader_type spatial;
render_mode unshaded, cull_disabled;

void fragment() {
	vec3 light_vs = normalize((VIEW_MATRIX * vec4(0.35, 0.8, 0.45, 0.0)).xyz);
	float shade = abs(dot(normalize(NORMAL), light_vs)) * 0.55 + 0.45;
	ALBEDO = pow(COLOR.rgb, vec3(2.2)) * shade;
}
)");
		material_debug.instantiate();
		material_debug->set_shader(shader);
	}
}

void Box3DReplayRenderer::apply_material() {
	ensure_material();
	const Ref<ShaderMaterial> &m = debug_style ? material_debug : material_lit;
	for (Geometry &g : geometries) {
		if (g.mmi != nullptr) {
			g.mmi->set_material_override(m);
		}
	}
}

void Box3DReplayRenderer::set_debug_style(bool p_enabled) {
	if (debug_style == p_enabled) {
		return;
	}
	debug_style = p_enabled;
	apply_material();
	// F-042: with a colour table set, the two looks do not merely use different
	// materials, they use different per-instance COLOURS — and those are baked
	// into the cached rows. Nothing to invalidate when no table is set, which
	// is the pre-F-042 behaviour and the common case.
	if (!body_colors.empty()) {
		clear_frame_cache();
	}
}

bool Box3DReplayRenderer::is_debug_style() const {
	return debug_style;
}

void Box3DReplayRenderer::ensure_nodes() {
	ensure_material();
	for (size_t i = 0; i < geometries.size(); ++i) {
		Geometry &g = geometries[i];
		if (g.mmi != nullptr) {
			continue;
		}
		Ref<MultiMesh> mm;
		mm.instantiate();
		mm->set_transform_format(MultiMesh::TRANSFORM_3D);
		mm->set_use_colors(true);
		mm->set_use_custom_data(use_custom_data);
		mm->set_mesh(g.mesh);
		// Without a custom AABB every buffer upload makes the renderer
		// recompute bounds over every instance; a replay view does not need
		// accurate culling and the recomputation is half the upload cost at
		// scale (measured on Box3DWorld's shells).
		mm->set_custom_aabb(AABB(Vector3(-100000, -100000, -100000), Vector3(200000, 200000, 200000)));

		MultiMeshInstance3D *mmi = memnew(MultiMeshInstance3D);
		mmi->set_name(String("Box3DReplayGeometry") + String::num_int64((int64_t)i));
		// Bulk multimesh_set_buffer uploads bypass the engine's own multimesh
		// physics interpolation, which would garble them.
		mmi->set_physics_interpolation_mode(Node::PHYSICS_INTERPOLATION_MODE_OFF);
		mmi->set_multimesh(mm);
		mmi->set_material_override(debug_style ? material_debug : material_lit);
		add_child(mmi);

		g.mm = mm;
		g.mmi = mmi;
	}
}

void Box3DReplayRenderer::install() {
	if (player.is_null()) {
		return;
	}
	player->install_debug_shape_callbacks(&Box3DReplayRenderer::cb_create_debug_shape,
			&Box3DReplayRenderer::cb_destroy_debug_shape, this);
	seen_generation = player->get_open_generation();
}

void Box3DReplayRenderer::uninstall() {
	if (player.is_null()) {
		return;
	}
	// Nulls first: this destroys the replay world under the old callbacks, and
	// upstream sets the function pointers to null BEFORE it does
	// (src/recording_replay.c:3643-3654), so nothing calls back into a node
	// that may be halfway through being torn down.
	player->install_debug_shape_callbacks(nullptr, nullptr, nullptr);
}

void Box3DReplayRenderer::set_player(const Ref<Box3DReplayPlayer> &p_player) {
	if (player == p_player) {
		return;
	}
	if (player.is_valid()) {
		uninstall();
	}
	// The old player's world is gone, so every handle it knew about is dead.
	detach_all_handles();
	clear();
	player = p_player;
	install();
}

Ref<Box3DReplayPlayer> Box3DReplayRenderer::get_player() const {
	return player;
}

// The b3World_Draw half of update(). Leaves every geometry's instance rows in
// its own buffer and reports whether they describe a real frame. Split out
// because the cache has to be able to PRODUCE a frame without showing it.
bool Box3DReplayRenderer::draw_walk() {
	for (Geometry &g : geometries) {
		g.count = 0;
	}
	last_instance_count = 0;
	last_override_count = 0;
	// A fresh occupancy for the frame about to be drawn. The rows themselves
	// are left alone: a slot that is not present is never read.
	memset(live_present.data(), 0, live_present.size() * sizeof(uint64_t));

	if (player.is_null() || !player->is_open()) {
		for (Geometry &g : geometries) {
			if (g.mm.is_valid()) {
				g.mm->set_visible_instance_count(0);
			}
		}
		return false;
	}

	// A different recording is loaded: the meshes and handles describe a world
	// that no longer exists.
	if (player->get_open_generation() != seen_generation) {
		detach_all_handles();
		clear();
		seen_generation = player->get_open_generation();
		// open() re-applied the callbacks itself (see Box3DReplayPlayer::open),
		// but this node's context pointer is what they carry, so nothing needs
		// reinstalling here.
	}

	const b3WorldId world_id = player->get_replay_world_id();
	if (!b3World_IsValid(world_id)) {
		return false;
	}

	b3DebugDraw draw = b3DefaultDebugDraw();
	// Shapes only. Every other overlay upstream can draw is a line soup this
	// node has no surface for; F-R3's timeline can add them later through the
	// same struct if they earn their place.
	draw.drawShapes = true;
	draw.drawJoints = false;
	draw.drawJointExtras = false;
	draw.drawBounds = false;
	draw.drawMass = false;
	draw.drawSleep = false;
	draw.drawBodyNames = false;
	draw.drawContacts = false;
	draw.drawGraphColors = false;
	draw.drawContactFeatures = false;
	draw.drawContactNormals = false;
	draw.drawContactForces = false;
	draw.drawIslands = false;

	AABB bounds = drawing_bounds;
	if (bounds.size == Vector3()) {
		// Auto: the recording's own accumulated bounds, inflated so a body at
		// the very edge is not culled on the frame it gets there.
		const Dictionary info = player->get_info();
		if (info.has("bounds")) {
			bounds = (AABB)info["bounds"];
		}
		if (bounds.size == Vector3()) {
			bounds = AABB(Vector3(-1e5, -1e5, -1e5), Vector3(2e5, 2e5, 2e5));
		} else {
			bounds = bounds.grow(bounds.size.length() * 0.25 + 1.0);
		}
	}
	bounds = bounds.abs();
	draw.drawingBounds.lowerBound = to_b3(bounds.position);
	draw.drawingBounds.upperBound = to_b3(bounds.position + bounds.size);

	draw.DrawShapeFcn = &Box3DReplayRenderer::cb_draw_shape;
	draw.context = this;

	// maskBits selects the collision categories the broad phase visits
	// (src/physics_world.c:1406-1409); a replay view never hides one.
	// Every other b3DebugDraw function pointer is left at b3DefaultDebugDraw's
	// no-ops, which matters: b3World_Draw dereferences them unconditionally.
	b3World_Draw(world_id, &draw, UINT64_MAX);

	// Node creation is deliberately OUTSIDE the traversal above: the create
	// callback fires from inside b3World_Draw, and adding scene-tree children
	// from there would mutate the tree mid-walk for no benefit. The callback
	// only interns a Mesh (a resource, safe to build anywhere) and the buffers
	// it fills are plain arrays that exist before any node does.
	ensure_nodes();
	compact_live();
	return true;
}

// The RenderingServer half: push whatever is in the geometry buffers at the
// counts they carry. Shared by the live walk and by a cached-frame replay, so
// there is exactly one upload path.
void Box3DReplayRenderer::upload() {
	last_instance_count = 0;
	RenderingServer *rs = RenderingServer::get_singleton();
	for (Geometry &g : geometries) {
		if (g.mm.is_null()) {
			continue;
		}
		const int alloc = (int)(g.buffer.size() / row_stride);
		if (alloc == 0) {
			g.mm->set_visible_instance_count(0);
			continue; // a zero-size upload errors out
		}
		if (g.allocated != alloc) {
			g.mm->set_instance_count(alloc);
			g.allocated = alloc;
		}
		g.mm->set_visible_instance_count(g.count);
		if (alloc > g.count) {
			// Rows past the visible count are still uploaded, so zero them
			// rather than leave a previous frame's transforms in the tail.
			memset(g.buffer.ptrw() + (int64_t)g.count * row_stride, 0,
					((int64_t)alloc - g.count) * row_stride * sizeof(float));
		}
		rs->multimesh_set_buffer(g.mm->get_rid(), g.buffer);
		last_instance_count += g.count;
	}
}

void Box3DReplayRenderer::update() {
	if (!draw_walk()) {
		return;
	}
	upload();
}

// --- the frame cache (F-R4) --------------------------------------------------

// Work out the position grid for a set of instances: the lower corner and the
// per-axis step of the 21-bit fixed point.
static void measure_grid(const std::vector<Box3DReplayRenderer::RawInstance> &p_raw,
		const std::vector<uint64_t> &p_present, int p_slot_count, float *r_min, float *r_step) {
	float lo[3] = { 0.0f, 0.0f, 0.0f };
	float hi[3] = { 0.0f, 0.0f, 0.0f };
	bool any = false;
	for (int slot = 0; slot < p_slot_count; ++slot) {
		if (!bit_set(p_present, slot)) {
			continue;
		}
		const Box3DReplayRenderer::RawInstance &r = p_raw[(size_t)slot];
		const float p[3] = { r.px, r.py, r.pz };
		if (!any) {
			for (int a = 0; a < 3; ++a) {
				lo[a] = p[a];
				hi[a] = p[a];
			}
			any = true;
			continue;
		}
		for (int a = 0; a < 3; ++a) {
			lo[a] = p[a] < lo[a] ? p[a] : lo[a];
			hi[a] = p[a] > hi[a] ? p[a] : hi[a];
		}
	}
	for (int a = 0; a < 3; ++a) {
		r_min[a] = lo[a];
		const float span = hi[a] - lo[a];
		r_step[a] = span > 0.0f ? span / (float)POS_BITS_MAX : 0.0f;
	}
}

bool Box3DReplayRenderer::store_frame(int p_frame) {
	if (frame_cache_budget <= 0) {
		return false;
	}
	// Already held. Re-storing it would mean splitting a chunk in the middle
	// for a frame whose content is the same either way.
	if (has_cached_frame(p_frame)) {
		return true;
	}

	// Unpack the live rows once, and measure the grid they will be quantised
	// against.
	if (raw_scratch.size() < (size_t)slot_count) {
		raw_scratch.resize((size_t)slot_count);
	}
	int present_count = 0;
	for (int slot = 0; slot < slot_count; ++slot) {
		if (!bit_set(live_present, slot)) {
			continue;
		}
		pack_row(live_rows.data() + (int64_t)slot * 16, raw_scratch[(size_t)slot]);
		++present_count;
	}
	float gmin[3];
	float gstep[3];
	measure_grid(raw_scratch, live_present, slot_count, gmin, gstep);
	// Half a step, so an instance that did not move does not read as moved just
	// because the frame's AABB shifted the grid under it.
	float peps[3];
	for (int a = 0; a < 3; ++a) {
		const float half = gstep[a] * 0.5f;
		peps[a] = half > CACHE_EPSILON ? half : CACHE_EPSILON;
	}

	// Continue the chunk the encoder has open when this frame follows the last
	// one it stored, there is still room in it, AND a delta is actually cheaper
	// than a full frame. Otherwise this frame opens a new chunk and is stored
	// WHOLE. That full frame is what bounds how many deltas a backward walk
	// re-applies, and what lets eviction let go of a chunk without stranding
	// anything.
	//
	// THE ADAPTIVE PART EARNS ITS KEEP ON CONTENT THAT NEVER SETTLES. A delta
	// pays 4 bytes of slot index for every instance it carries and saves 20 on
	// every instance it leaves out, so it is only worth taking while fewer than
	// five instances in six have moved. Huge Pyramid's collapse moves ALL of
	// them, every frame (measured: 16,290 of 16,290 move by more than 1e-4),
	// and on that content this test is what keeps delta coding from costing
	// 12% more than storing frames whole.
	CacheChunk *chunk = nullptr;
	bool base = true;
	if (enc_chunk >= 0 && enc_frame + 1 == p_frame) {
		auto it = chunks.find(enc_chunk);
		if (it != chunks.end() && it->second.end() + 1 == p_frame &&
				(int)it->second.frames.size() < chunk_frames) {
			int changed = 0;
			for (int slot = 0; slot < slot_count; ++slot) {
				if (!bit_set(live_present, slot)) {
					continue;
				}
				if (!bit_set(enc_present, slot) ||
						instance_moved(raw_scratch[(size_t)slot], enc_ref[(size_t)slot], peps)) {
					++changed;
				}
			}
			if ((int64_t)changed * 6 < (int64_t)present_count * 5) {
				chunk = &it->second;
				base = false;
			}
		}
	}
	if (chunk == nullptr) {
		auto res = chunks.emplace(p_frame, CacheChunk());
		if (!res.second) {
			return false;
		}
		chunk = &res.first->second;
		chunk->start = p_frame;
		enc_chunk = p_frame;
		// A base inherits nothing, so the reference starts empty and every
		// present slot is written out below.
		memset(enc_present.data(), 0, enc_present.size() * sizeof(uint64_t));
	}

	CachedFrame cf;
	cf.present = live_present;
	memcpy(cf.grid_min, gmin, sizeof(gmin));
	memcpy(cf.grid_step, gstep, sizeof(gstep));
	for (int slot = 0; slot < slot_count; ++slot) {
		if (!bit_set(live_present, slot)) {
			continue;
		}
		const RawInstance &ri = raw_scratch[(size_t)slot];
		// Three ways an instance earns its bytes: the frame is a base, the
		// shape was not on screen last frame, or it actually moved.
		if (!(base || !bit_set(enc_present, slot) ||
					instance_moved(ri, enc_ref[(size_t)slot], peps))) {
			continue;
		}
		CachedInstance ci;
		quantize(ri, gmin, gstep, ci);
		if (!base) {
			cf.slots.push_back((uint32_t)slot);
		}
		cf.values.push_back(ci);
		// The reference is what the DECODER will hold, which is the value after
		// the round trip and not the one we were handed. That is what bounds
		// the error at one step instead of letting it accumulate.
		dequantize(ci, gmin, gstep, enc_ref[(size_t)slot]);
	}
	enc_present = cf.present;

	cf.override_count = last_override_count;
	cf.bytes = (int64_t)cf.values.size() * (int64_t)sizeof(CachedInstance) +
			(int64_t)cf.slots.size() * 4 + (int64_t)cf.present.size() * 8 + 64;

	const int64_t added = cf.bytes;
	chunk->frames.push_back(std::move(cf));
	chunk->bytes += added;
	frame_cache_bytes += added;
	++cached_frame_total;
	enc_frame = p_frame;

	evict_to_budget();
	return has_cached_frame(p_frame);
}

Box3DReplayRenderer::CacheChunk *Box3DReplayRenderer::find_chunk(int p_frame) {
	auto it = chunks.upper_bound(p_frame);
	if (it == chunks.begin()) {
		return nullptr;
	}
	--it;
	return p_frame <= it->second.end() ? &it->second : nullptr;
}

const Box3DReplayRenderer::CacheChunk *Box3DReplayRenderer::find_chunk(int p_frame) const {
	return const_cast<Box3DReplayRenderer *>(this)->find_chunk(p_frame);
}

// A chunk lost frames: anything the encoder or the decoder was standing on
// inside that range is no longer a place to continue from.
void Box3DReplayRenderer::forget_frames(int p_lo, int p_hi) {
	if (enc_frame >= p_lo && enc_frame <= p_hi) {
		enc_chunk = -1;
		enc_frame = -1;
	}
	if (dec_frame >= p_lo && dec_frame <= p_hi) {
		dec_chunk = -1;
		dec_frame = -1;
	}
}

// Bring the decoder to p_frame. Stepping forward from where it already stands
// is what makes forward play through a chunk nearly free; anything else starts
// at the chunk's base, which is why the base interval is capped.
bool Box3DReplayRenderer::decode_to(int p_frame) {
	CacheChunk *c = find_chunk(p_frame);
	if (c == nullptr) {
		return false;
	}
	int from;
	if (dec_chunk == c->start && dec_frame >= c->start && dec_frame <= p_frame) {
		from = dec_frame + 1;
	} else {
		const CachedFrame &b = c->frames[0];
		dec_present = b.present;
		size_t i = 0;
		for (int slot = 0; slot < slot_count && i < b.values.size(); ++slot) {
			if (bit_set(b.present, slot)) {
				dequantize(b.values[i++], b.grid_min, b.grid_step, dec_state[(size_t)slot]);
			}
		}
		from = c->start + 1;
	}
	for (int f = from; f <= p_frame; ++f) {
		const CachedFrame &d = c->frames[(size_t)(f - c->start)];
		dec_present = d.present;
		for (size_t i = 0; i < d.slots.size(); ++i) {
			dequantize(d.values[i], d.grid_min, d.grid_step, dec_state[(size_t)d.slots[i]]);
		}
	}
	dec_frame = p_frame;
	dec_chunk = c->start;
	return true;
}

// Drop a chunk's FIRST frame. The frames behind it inherit from it, so the
// second frame is decoded and rewritten as the new base; the chunk keeps every
// frame but one and the window's front edge moves.
void Box3DReplayRenderer::rebase_front(int p_start) {
	auto it = chunks.find(p_start);
	if (it == chunks.end() || it->second.frames.size() < 2) {
		return;
	}
	const int next = p_start + 1;
	if (!decode_to(next)) {
		return;
	}
	CachedFrame nb;
	nb.present = dec_present;
	measure_grid(dec_state, dec_present, slot_count, nb.grid_min, nb.grid_step);
	for (int slot = 0; slot < slot_count; ++slot) {
		if (bit_set(dec_present, slot)) {
			CachedInstance ci;
			quantize(dec_state[(size_t)slot], nb.grid_min, nb.grid_step, ci);
			nb.values.push_back(ci);
		}
	}
	nb.override_count = it->second.frames[1].override_count;
	nb.bytes = (int64_t)nb.values.size() * (int64_t)sizeof(CachedInstance) +
			(int64_t)nb.present.size() * 8 + 64;

	CacheChunk moved;
	moved.start = next;
	moved.frames.reserve(it->second.frames.size() - 1);
	moved.bytes = nb.bytes;
	moved.frames.push_back(std::move(nb));
	for (size_t i = 2; i < it->second.frames.size(); ++i) {
		moved.bytes += it->second.frames[i].bytes;
		moved.frames.push_back(std::move(it->second.frames[i]));
	}

	frame_cache_bytes += moved.bytes - it->second.bytes;
	--cached_frame_total;
	chunks.erase(it);
	chunks.emplace(next, std::move(moved));
	if (enc_chunk == p_start) {
		enc_chunk = next;
	}
	if (dec_chunk == p_start) {
		dec_chunk = next;
	}
	// The decoder is standing on the new base, which is exactly the state it
	// already holds, so it stays valid.
}

// Eviction is by distance from the PLAYHEAD, not by age: the window that
// matters is the one around what the viewer is looking at, and a prefetch pass
// running far ahead must lose its own newest frames rather than the frames the
// user is about to scrub through.
//
// The unit is a CHUNK, because a delta cannot outlive the frames it inherits
// from. Chunks are capped at `chunk_frames`, so the window still tracks the
// playhead at that granularity, and it stays CONTIGUOUS: the victim is always
// one of the two ends. When one chunk is all that is left, it is trimmed a
// frame at a time instead — free at the tail, a rebase at the front.
//
// F-050 changed what "evict" MEANS without changing which chunk goes: with a
// spill path set the victim is written out instead of thrown away, so the
// memory budget became a working-set size and coverage became a property of the
// disk budget instead.
void Box3DReplayRenderer::evict_to_budget() {
	while (frame_cache_bytes > frame_cache_budget && !chunks.empty()) {
		if (chunks.size() > 1) {
			auto lo = chunks.begin();
			auto hi = std::prev(chunks.end());
			const int64_t d_lo = (int64_t)cache_playhead - lo->second.end();
			const int64_t d_hi = (int64_t)hi->second.start - cache_playhead;
			if (!spill_enabled()) {
				// No spill: the window has to stay CONTIGUOUS, because a chunk
				// dropped out of the middle is a hole nothing can fill. So the
				// victim is one of the two ends, exactly as F-R5 left it.
				release_chunk(d_lo >= d_hi ? lo : hi);
				continue;
			}
			// With a spill, a chunk out of the middle is not a hole in COVERAGE
			// — it is on disk — so the victim can be the furthest chunk full
			// stop. Two things it must never be. (1) The chunk the encoder is
			// still appending to: writing it out closes it, and an index pass
			// running far from the playhead would then have every frame closed
			// into a chunk of its own, which is a disk write and a lost delta
			// per frame. (2) Nothing else; the playhead's own chunk is by
			// construction the nearest, and if it does go it comes back from
			// disk on the next draw.
			auto victim = chunks.end();
			int64_t best = -1;
			for (auto it = chunks.begin(); it != chunks.end(); ++it) {
				if (it->first == enc_chunk) {
					continue;
				}
				const int64_t d = cache_playhead < it->second.start
						? (int64_t)it->second.start - cache_playhead
						: (cache_playhead > it->second.end()
										? (int64_t)cache_playhead - it->second.end()
										: 0);
				if (d > best) {
					best = d;
					victim = it;
				}
			}
			if (victim == chunks.end()) {
				break; // only the open chunk is left; it is not evictable yet
			}
			release_chunk(victim);
			continue;
		}
		// One chunk left, and it is the one the playhead is standing in. With a
		// spill file this is the end of the road rather than a reason to start
		// trimming: rebase_front rewrites a chunk in place, which would leave
		// its disk image describing frames memory no longer agrees with, and a
		// single chunk is `chunk_frames` frames — 10 MB of the worst scene this
		// demo has against a 96 MB budget, so the case does not arise.
		if (spill_enabled()) {
			break;
		}
		CacheChunk &c = chunks.begin()->second;
		if (c.frames.size() <= 1) {
			// One frame bigger than the whole budget is kept anyway: a cache
			// that refuses to hold a single frame is worse than one that
			// overshoots by one.
			break;
		}
		const int start = c.start;
		const int last = c.end();
		if ((int64_t)cache_playhead - start >= (int64_t)last - cache_playhead) {
			rebase_front(start);
		} else {
			frame_cache_bytes -= c.frames.back().bytes;
			c.bytes -= c.frames.back().bytes;
			c.frames.pop_back();
			--cached_frame_total;
			forget_frames(last, last);
		}
	}
}

// --- the spill file (F-050) --------------------------------------------------
//
// THE MEASUREMENT THIS EXISTS FOR. Huge Pyramid, 16,290 shapes, a 1200-frame
// recording, Linux template_debug: the index pass filled 96 MB with 306 frames
// and stood down, and past that band a seek cost the player a keyframe restore
// and a re-step of the gap — 0.5 s at 40 frames out, 2.0 s at 200, 6.1 s at
// 600. A cached frame of that scene is 328 KB. Writing it out and reading it
// back is milliseconds; re-simulating 256 frames of 16,290 bodies is seconds.
// So the overflow goes to a temp file, and the number of frames the transport
// can reach stops depending on how much memory the cache is allowed.
//
// The file is APPEND-ONLY and its records are IMMUTABLE. A chunk is written
// once, when the budget first pushes it out; a chunk read back in keeps its
// disk image, so dropping it again later is free. Nothing is ever rewritten in
// place, which is what makes the offset table a plain map and the reads a
// single seek.

bool Box3DReplayRenderer::open_spill() {
	if (spill_file.is_valid()) {
		return true;
	}
	if (spill_path.is_empty() || spill_failed) {
		return false;
	}
	const String dir = spill_path.get_base_dir();
	if (!dir.is_empty()) {
		DirAccess::make_dir_recursive_absolute(dir);
	}
	// WRITE_READ creates and TRUNCATES, which is what a fresh cache wants: a
	// file left by an earlier recording in this same node describes slots that
	// no longer mean anything.
	spill_file = FileAccess::open(spill_path, FileAccess::WRITE_READ);
	if (spill_file.is_null()) {
		spill_failed = true;
		return false;
	}
	spill_cursor = 0;
	spill_bytes = 0;
	return true;
}

void Box3DReplayRenderer::close_spill() {
	if (spill_file.is_valid()) {
		spill_file->close();
		spill_file.unref();
	}
	if (!spill_path.is_empty() && FileAccess::file_exists(spill_path)) {
		DirAccess::remove_absolute(spill_path);
	}
	spilled.clear();
	spill_cursor = 0;
	spill_bytes = 0;
	spill_scratch.resize(0);
}

int64_t Box3DReplayRenderer::chunk_serialized_size(const CacheChunk &p_chunk) const {
	int64_t n = 16; // magic, version, start, frame count
	for (const CachedFrame &f : p_chunk.frames) {
		n += 40; // four counts and the six grid floats
		n += (int64_t)f.slots.size() * 4;
		n += (int64_t)f.values.size() * (int64_t)sizeof(CachedInstance);
		n += (int64_t)f.present.size() * 8;
	}
	return n;
}

// Native bytes, native order. This is a temp file read only by the process that
// wrote it, in the same run — the version word is there so a mismatch fails
// loudly rather than decoding garbage, not because the format travels.
void Box3DReplayRenderer::serialize_chunk(const CacheChunk &p_chunk, uint8_t *p_dst) const {
	uint8_t *w = p_dst;
	const int32_t magic = 0x43463342; // "B3FC"
	const int32_t version = 1;
	const int32_t start = p_chunk.start;
	const int32_t count = (int32_t)p_chunk.frames.size();
	memcpy(w, &magic, 4);
	w += 4;
	memcpy(w, &version, 4);
	w += 4;
	memcpy(w, &start, 4);
	w += 4;
	memcpy(w, &count, 4);
	w += 4;
	for (const CachedFrame &f : p_chunk.frames) {
		const int32_t head[4] = { (int32_t)f.slots.size(), (int32_t)f.values.size(),
			(int32_t)f.present.size(), (int32_t)f.override_count };
		memcpy(w, head, 16);
		w += 16;
		memcpy(w, f.grid_min, 12);
		w += 12;
		memcpy(w, f.grid_step, 12);
		w += 12;
		if (!f.slots.empty()) {
			memcpy(w, f.slots.data(), f.slots.size() * 4);
			w += f.slots.size() * 4;
		}
		if (!f.values.empty()) {
			memcpy(w, f.values.data(), f.values.size() * sizeof(CachedInstance));
			w += f.values.size() * sizeof(CachedInstance);
		}
		if (!f.present.empty()) {
			memcpy(w, f.present.data(), f.present.size() * 8);
			w += f.present.size() * 8;
		}
	}
}

bool Box3DReplayRenderer::deserialize_chunk(const uint8_t *p_src, int64_t p_size,
		CacheChunk &r_chunk) const {
	if (p_src == nullptr || p_size < 16) {
		return false;
	}
	const uint8_t *r = p_src;
	const uint8_t *end = p_src + p_size;
	int32_t magic = 0;
	int32_t version = 0;
	int32_t start = 0;
	int32_t count = 0;
	memcpy(&magic, r, 4);
	r += 4;
	memcpy(&version, r, 4);
	r += 4;
	memcpy(&start, r, 4);
	r += 4;
	memcpy(&count, r, 4);
	r += 4;
	if (magic != 0x43463342 || version != 1 || count <= 0) {
		return false;
	}
	r_chunk.start = start;
	r_chunk.bytes = 0;
	r_chunk.frames.clear();
	r_chunk.frames.resize((size_t)count);
	for (int i = 0; i < count; ++i) {
		if (end - r < 40) {
			return false;
		}
		CachedFrame &f = r_chunk.frames[(size_t)i];
		int32_t head[4];
		memcpy(head, r, 16);
		r += 16;
		memcpy(f.grid_min, r, 12);
		r += 12;
		memcpy(f.grid_step, r, 12);
		r += 12;
		if (head[0] < 0 || head[1] < 0 || head[2] < 0) {
			return false;
		}
		const int64_t need = (int64_t)head[0] * 4 + (int64_t)head[1] * (int64_t)sizeof(CachedInstance) +
				(int64_t)head[2] * 8;
		if (end - r < need) {
			return false;
		}
		f.override_count = head[3];
		f.slots.resize((size_t)head[0]);
		f.values.resize((size_t)head[1]);
		f.present.resize((size_t)head[2]);
		if (head[0] > 0) {
			memcpy(f.slots.data(), r, (size_t)head[0] * 4);
			r += (size_t)head[0] * 4;
		}
		if (head[1] > 0) {
			memcpy(f.values.data(), r, (size_t)head[1] * sizeof(CachedInstance));
			r += (size_t)head[1] * sizeof(CachedInstance);
		}
		if (head[2] > 0) {
			memcpy(f.present.data(), r, (size_t)head[2] * 8);
			r += (size_t)head[2] * 8;
		}
		// Recomputed rather than stored, so a frame read back accounts for
		// exactly what the same frame accounted for when it was encoded.
		f.bytes = (int64_t)f.values.size() * (int64_t)sizeof(CachedInstance) +
				(int64_t)f.slots.size() * 4 + (int64_t)f.present.size() * 8 + 64;
		r_chunk.bytes += f.bytes;
	}
	return true;
}

bool Box3DReplayRenderer::spill_chunk(const CacheChunk &p_chunk) {
	if (!spill_enabled() || p_chunk.frames.empty()) {
		return false;
	}
	if (!open_spill()) {
		return false;
	}
	const int64_t need = chunk_serialized_size(p_chunk);
	if (spill_bytes + need > spill_disk_budget) {
		// Softly, and permanently for this recording: the disk budget is a
		// ceiling the host set, not an error. Coverage stops being a prefix
		// from here and get_indexed_through() reports that.
		return false;
	}
	spill_scratch.resize(need);
	serialize_chunk(p_chunk, spill_scratch.ptrw());
	spill_file->seek((uint64_t)spill_cursor);
	spill_file->store_buffer(spill_scratch);
	if (spill_file->get_error() != OK) {
		spill_failed = true;
		return false;
	}
	SpillEntry e;
	e.start = p_chunk.start;
	e.frames = (int)p_chunk.frames.size();
	e.offset = spill_cursor;
	e.size = need;
	spilled[e.start] = e;
	spill_cursor += need;
	spill_bytes += need;
	++spill_writes;
	return true;
}

void Box3DReplayRenderer::release_chunk(std::map<int, CacheChunk>::iterator p_it) {
	CacheChunk &c = p_it->second;
	if (spill_enabled() && spilled.find(c.start) == spilled.end()) {
		// A failed write is not fatal: the chunk is dropped exactly as it was
		// before this existed, and the cache is a window again.
		spill_chunk(c);
	}
	frame_cache_bytes -= c.bytes;
	cached_frame_total -= (int)c.frames.size();
	forget_frames(c.start, c.end());
	chunks.erase(p_it);
}

const Box3DReplayRenderer::SpillEntry *Box3DReplayRenderer::find_spilled(int p_frame) const {
	auto it = spilled.upper_bound(p_frame);
	if (it == spilled.begin()) {
		return nullptr;
	}
	--it;
	return p_frame <= it->second.end() ? &it->second : nullptr;
}

bool Box3DReplayRenderer::load_spilled(int p_frame) {
	const SpillEntry *found = find_spilled(p_frame);
	if (found == nullptr || spill_file.is_null()) {
		return false;
	}
	const SpillEntry ent = *found;
	if (chunks.find(ent.start) != chunks.end()) {
		return true;
	}
	spill_file->seek((uint64_t)ent.offset);
	const PackedByteArray buf = spill_file->get_buffer(ent.size);
	if (buf.size() != ent.size) {
		return false;
	}
	CacheChunk c;
	if (!deserialize_chunk(buf.ptr(), buf.size(), c)) {
		return false;
	}
	frame_cache_bytes += c.bytes;
	cached_frame_total += (int)c.frames.size();
	chunks.emplace(ent.start, std::move(c));
	++spill_reads;
	// The caller has already moved cache_playhead onto p_frame, so the chunk
	// just read in is the NEAREST one and eviction cannot take it back out.
	evict_to_budget();
	return chunks.find(ent.start) != chunks.end();
}

void Box3DReplayRenderer::collect_runs(std::vector<Vector2i> &r_runs, bool p_resident_only) const {
	r_runs.clear();
	for (const auto &kv : chunks) {
		r_runs.push_back(Vector2i(kv.second.start, kv.second.end()));
	}
	if (!p_resident_only) {
		for (const auto &kv : spilled) {
			if (chunks.find(kv.first) == chunks.end()) {
				r_runs.push_back(Vector2i(kv.second.start, kv.second.end()));
			}
		}
	}
	std::sort(r_runs.begin(), r_runs.end(), [](const Vector2i &a, const Vector2i &b) {
		return a.x < b.x;
	});
	size_t w = 0;
	for (size_t i = 0; i < r_runs.size(); ++i) {
		if (w > 0 && r_runs[i].x <= r_runs[w - 1].y + 1) {
			r_runs[w - 1].y = r_runs[i].y > r_runs[w - 1].y ? r_runs[i].y : r_runs[w - 1].y;
			continue;
		}
		r_runs[w++] = r_runs[i];
	}
	r_runs.resize(w);
}

void Box3DReplayRenderer::capture_frame(int p_frame) {
	if (!draw_walk()) {
		return;
	}
	upload();
	cache_playhead = p_frame;
	store_frame(p_frame);
}

bool Box3DReplayRenderer::prefetch_frame(int p_frame) {
	if (!draw_walk()) {
		return false;
	}
	// Deliberately NO upload: this runs while the viewer is parked somewhere
	// else, and the MultiMesh buffers on the GPU still hold that frame.
	return store_frame(p_frame);
}

bool Box3DReplayRenderer::draw_cached_frame(int p_frame) {
	if (find_chunk(p_frame) == nullptr) {
		// Not in memory. It may still be a frame this cache HAS — the budget
		// only decides where a chunk lives, not whether it exists. Move the
		// playhead first: eviction is centred on it, and a chunk read in for a
		// frame the playhead is not on yet is the furthest one there is.
		const int prev = cache_playhead;
		cache_playhead = p_frame;
		if (!load_spilled(p_frame)) {
			cache_playhead = prev;
			return false;
		}
	}
	if (!decode_to(p_frame)) {
		return false;
	}
	const CacheChunk *c = find_chunk(p_frame);
	compact_decoded();
	ensure_nodes();
	upload();
	last_override_count = c->frames[(size_t)(p_frame - c->start)].override_count;
	cache_playhead = p_frame;
	return true;
}

bool Box3DReplayRenderer::has_cached_frame(int p_frame) const {
	return find_chunk(p_frame) != nullptr || find_spilled(p_frame) != nullptr;
}

void Box3DReplayRenderer::clear_frame_cache() {
	chunks.clear();
	frame_cache_bytes = 0;
	cached_frame_total = 0;
	enc_chunk = -1;
	enc_frame = -1;
	dec_chunk = -1;
	dec_frame = -1;
	// The temp file describes slots and frames that no longer mean anything.
	// Closing the handle is what truncates it: open_spill reopens WRITE_READ.
	spilled.clear();
	spill_cursor = 0;
	spill_bytes = 0;
	if (spill_file.is_valid()) {
		spill_file->close();
		spill_file.unref();
	}
}

// Memory AND disk: both are frames a caller can draw without touching the
// player, which is the only distinction this number has ever been about.
int Box3DReplayRenderer::get_cached_frame_count() const {
	int n = cached_frame_total;
	for (const auto &kv : spilled) {
		if (chunks.find(kv.first) == chunks.end()) {
			n += kv.second.frames;
		}
	}
	return n;
}

int Box3DReplayRenderer::get_resident_frame_count() const {
	return cached_frame_total;
}

int64_t Box3DReplayRenderer::get_frame_cache_bytes() const {
	return frame_cache_bytes;
}

Vector2i Box3DReplayRenderer::get_cached_frame_range() const {
	if (chunks.empty() && spilled.empty()) {
		return Vector2i(-1, -1);
	}
	int lo = 0;
	int hi = 0;
	bool first = true;
	if (!chunks.empty()) {
		lo = chunks.begin()->second.start;
		hi = std::prev(chunks.end())->second.end();
		first = false;
	}
	if (!spilled.empty()) {
		const int slo = spilled.begin()->second.start;
		const int shi = std::prev(spilled.end())->second.end();
		lo = first || slo < lo ? slo : lo;
		hi = first || shi > hi ? shi : hi;
	}
	return Vector2i(lo, hi);
}

void Box3DReplayRenderer::set_frame_cache_spill_path(const String &p_path) {
	if (p_path == spill_path) {
		return;
	}
	// Whatever was written under the old path is unreachable from the new one,
	// so it goes with it rather than being left on disk for nobody.
	close_spill();
	spill_path = p_path;
	spill_failed = false;
}

String Box3DReplayRenderer::get_frame_cache_spill_path() const {
	return spill_path;
}

void Box3DReplayRenderer::set_frame_cache_disk_budget(int64_t p_bytes) {
	spill_disk_budget = p_bytes < 0 ? 0 : p_bytes;
}

int64_t Box3DReplayRenderer::get_frame_cache_disk_budget() const {
	return spill_disk_budget;
}

int64_t Box3DReplayRenderer::get_frame_cache_disk_bytes() const {
	return spill_bytes;
}

int64_t Box3DReplayRenderer::get_spill_write_count() const {
	return spill_writes;
}

int64_t Box3DReplayRenderer::get_spill_read_count() const {
	return spill_reads;
}

int Box3DReplayRenderer::get_indexed_through() const {
	std::vector<Vector2i> runs;
	collect_runs(runs, false);
	if (runs.empty() || runs[0].x > 1) {
		// Frame 0 is before the recording's first dispatch and no transport
		// displays it, so a prefix starts at 1. A first run that starts above
		// that is a window, not a prefix, and the answer is "none".
		return 0;
	}
	return runs[0].y;
}

Array Box3DReplayRenderer::get_cached_runs() const {
	std::vector<Vector2i> runs;
	collect_runs(runs, false);
	Array out;
	for (const Vector2i &r : runs) {
		out.push_back(r);
	}
	return out;
}

Array Box3DReplayRenderer::get_resident_runs() const {
	std::vector<Vector2i> runs;
	collect_runs(runs, true);
	Array out;
	for (const Vector2i &r : runs) {
		out.push_back(r);
	}
	return out;
}

void Box3DReplayRenderer::set_frame_cache_budget(int64_t p_bytes) {
	frame_cache_budget = p_bytes < 0 ? 0 : p_bytes;
	if (frame_cache_budget == 0) {
		clear_frame_cache();
		return;
	}
	evict_to_budget();
}

int64_t Box3DReplayRenderer::get_frame_cache_budget() const {
	return frame_cache_budget;
}

void Box3DReplayRenderer::clear() {
	for (Geometry &g : geometries) {
		if (g.mmi != nullptr) {
			remove_child(g.mmi);
			memdelete(g.mmi);
			g.mmi = nullptr;
		}
	}
	geometries.clear();
	geometry_by_key.clear();
	last_instance_count = 0;
	// Cached frames name their instances by SLOT, and the counter that hands
	// slots out starts over from here along with the geometries.
	slot_count = 0;
	live_rows.clear();
	live_present.clear();
	enc_ref.clear();
	enc_present.clear();
	dec_state.clear();
	dec_present.clear();
	clear_frame_cache();
}

void Box3DReplayRenderer::set_auto_update(bool p_enabled) {
	auto_update = p_enabled;
	if (is_inside_tree()) {
		set_process(auto_update);
	}
}

bool Box3DReplayRenderer::is_auto_update() const {
	return auto_update;
}

void Box3DReplayRenderer::set_drawing_bounds(const AABB &p_bounds) {
	drawing_bounds = p_bounds;
}

AABB Box3DReplayRenderer::get_drawing_bounds() const {
	return drawing_bounds;
}

int Box3DReplayRenderer::get_geometry_count() const {
	return (int)geometries.size();
}

int Box3DReplayRenderer::get_shape_count() const {
	return (int)handles.size();
}

int Box3DReplayRenderer::get_instance_count() const {
	return last_instance_count;
}

int Box3DReplayRenderer::get_triangle_count() const {
	int total = 0;
	for (const Geometry &g : geometries) {
		total += g.triangle_count;
	}
	return total;
}

Dictionary Box3DReplayRenderer::get_geometry_info(int p_index) const {
	Dictionary d;
	if (p_index < 0 || p_index >= (int)geometries.size()) {
		return d;
	}
	const Geometry &g = geometries[p_index];
	// Upstream's b3ShapeType spelling, minus the b3_ prefix and the Shape
	// suffix, so a script prints "hull" / "sphere" / "mesh".
	const char *name = "unknown";
	switch (g.type) {
		case b3_sphereShape:
			name = "sphere";
			break;
		case b3_capsuleShape:
			name = "capsule";
			break;
		case b3_hullShape:
			name = "hull";
			break;
		case b3_meshShape:
			name = "mesh";
			break;
		case b3_heightShape:
			name = "height_field";
			break;
		case b3_compoundShape:
			name = "compound";
			break;
		default:
			break;
	}
	d["type"] = String(name);
	d["triangles"] = g.triangle_count;
	d["instances"] = g.count;
	d["approximate"] = g.approximate;
	return d;
}

Transform3D Box3DReplayRenderer::get_instance_transform(int p_geometry, int p_index) const {
	if (p_geometry < 0 || p_geometry >= (int)geometries.size()) {
		return Transform3D();
	}
	const Geometry &g = geometries[p_geometry];
	if (p_index < 0 || p_index >= g.count) {
		return Transform3D();
	}
	const float *r = g.buffer.ptr() + (int64_t)p_index * row_stride;
	Basis b;
	b.rows[0] = Vector3((real_t)r[0], (real_t)r[1], (real_t)r[2]);
	b.rows[1] = Vector3((real_t)r[4], (real_t)r[5], (real_t)r[6]);
	b.rows[2] = Vector3((real_t)r[8], (real_t)r[9], (real_t)r[10]);
	return Transform3D(b, Vector3((real_t)r[3], (real_t)r[7], (real_t)r[11]));
}

Color Box3DReplayRenderer::get_instance_color(int p_geometry, int p_index) const {
	if (p_geometry < 0 || p_geometry >= (int)geometries.size()) {
		return Color();
	}
	const Geometry &g = geometries[p_geometry];
	if (p_index < 0 || p_index >= g.count) {
		return Color();
	}
	const float *r = g.buffer.ptr() + (int64_t)p_index * row_stride;
	return Color(r[12], r[13], r[14], r[15]);
}

void Box3DReplayRenderer::_notification(int p_what) {
	switch (p_what) {
		case NOTIFICATION_READY:
			set_process(auto_update);
			break;
		case NOTIFICATION_PROCESS:
			update();
			break;
		case NOTIFICATION_PREDELETE:
			uninstall();
			detach_all_handles();
			break;
		default:
			break;
	}
}

void Box3DReplayRenderer::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_player", "player"), &Box3DReplayRenderer::set_player);
	ClassDB::bind_method(D_METHOD("get_player"), &Box3DReplayRenderer::get_player);
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "player", PROPERTY_HINT_RESOURCE_TYPE, "Box3DReplayPlayer"),
			"set_player", "get_player");

	ClassDB::bind_method(D_METHOD("update"), &Box3DReplayRenderer::update);
	ClassDB::bind_method(D_METHOD("clear"), &Box3DReplayRenderer::clear);

	ClassDB::bind_method(D_METHOD("set_auto_update", "enabled"), &Box3DReplayRenderer::set_auto_update);
	ClassDB::bind_method(D_METHOD("is_auto_update"), &Box3DReplayRenderer::is_auto_update);
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "auto_update"), "set_auto_update", "is_auto_update");

	ClassDB::bind_method(D_METHOD("set_debug_style", "enabled"), &Box3DReplayRenderer::set_debug_style);
	ClassDB::bind_method(D_METHOD("is_debug_style"), &Box3DReplayRenderer::is_debug_style);
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "debug_style"), "set_debug_style", "is_debug_style");

	ClassDB::bind_method(D_METHOD("set_body_color_overrides", "colors"),
			&Box3DReplayRenderer::set_body_color_overrides);
	ClassDB::bind_method(D_METHOD("get_body_color_overrides"),
			&Box3DReplayRenderer::get_body_color_overrides);
	ADD_PROPERTY(PropertyInfo(Variant::DICTIONARY, "body_color_overrides"),
			"set_body_color_overrides", "get_body_color_overrides");
	ClassDB::bind_method(D_METHOD("set_body_material_overrides", "materials"),
			&Box3DReplayRenderer::set_body_material_overrides);
	ClassDB::bind_method(D_METHOD("get_body_material_overrides"),
			&Box3DReplayRenderer::get_body_material_overrides);
	ADD_PROPERTY(PropertyInfo(Variant::DICTIONARY, "body_material_overrides"),
			"set_body_material_overrides", "get_body_material_overrides");
	ClassDB::bind_method(D_METHOD("get_override_instance_count"),
			&Box3DReplayRenderer::get_override_instance_count);

	ClassDB::bind_method(D_METHOD("set_drawing_bounds", "bounds"), &Box3DReplayRenderer::set_drawing_bounds);
	ClassDB::bind_method(D_METHOD("get_drawing_bounds"), &Box3DReplayRenderer::get_drawing_bounds);
	ADD_PROPERTY(PropertyInfo(Variant::AABB, "drawing_bounds"), "set_drawing_bounds", "get_drawing_bounds");

	ClassDB::bind_method(D_METHOD("get_geometry_count"), &Box3DReplayRenderer::get_geometry_count);
	ClassDB::bind_method(D_METHOD("get_shape_count"), &Box3DReplayRenderer::get_shape_count);
	ClassDB::bind_method(D_METHOD("get_instance_count"), &Box3DReplayRenderer::get_instance_count);
	ClassDB::bind_method(D_METHOD("get_triangle_count"), &Box3DReplayRenderer::get_triangle_count);
	ClassDB::bind_method(D_METHOD("get_geometry_info", "index"), &Box3DReplayRenderer::get_geometry_info);

	ClassDB::bind_method(D_METHOD("get_instance_transform", "geometry", "index"),
			&Box3DReplayRenderer::get_instance_transform);
	ClassDB::bind_method(D_METHOD("get_instance_color", "geometry", "index"),
			&Box3DReplayRenderer::get_instance_color);

	ClassDB::bind_method(D_METHOD("capture_frame", "frame"), &Box3DReplayRenderer::capture_frame);
	ClassDB::bind_method(D_METHOD("prefetch_frame", "frame"), &Box3DReplayRenderer::prefetch_frame);
	ClassDB::bind_method(D_METHOD("draw_cached_frame", "frame"), &Box3DReplayRenderer::draw_cached_frame);
	ClassDB::bind_method(D_METHOD("has_cached_frame", "frame"), &Box3DReplayRenderer::has_cached_frame);
	ClassDB::bind_method(D_METHOD("clear_frame_cache"), &Box3DReplayRenderer::clear_frame_cache);
	ClassDB::bind_method(D_METHOD("get_cached_frame_count"), &Box3DReplayRenderer::get_cached_frame_count);
	ClassDB::bind_method(D_METHOD("get_frame_cache_bytes"), &Box3DReplayRenderer::get_frame_cache_bytes);
	ClassDB::bind_method(D_METHOD("get_cached_frame_range"), &Box3DReplayRenderer::get_cached_frame_range);
	ClassDB::bind_method(D_METHOD("set_frame_cache_budget", "bytes"), &Box3DReplayRenderer::set_frame_cache_budget);
	ClassDB::bind_method(D_METHOD("get_frame_cache_budget"), &Box3DReplayRenderer::get_frame_cache_budget);
	ADD_PROPERTY(PropertyInfo(Variant::INT, "frame_cache_budget"),
			"set_frame_cache_budget", "get_frame_cache_budget");

	// F-050: the overflow, and the coverage it buys.
	ClassDB::bind_method(D_METHOD("set_frame_cache_spill_path", "path"),
			&Box3DReplayRenderer::set_frame_cache_spill_path);
	ClassDB::bind_method(D_METHOD("get_frame_cache_spill_path"),
			&Box3DReplayRenderer::get_frame_cache_spill_path);
	ADD_PROPERTY(PropertyInfo(Variant::STRING, "frame_cache_spill_path"),
			"set_frame_cache_spill_path", "get_frame_cache_spill_path");
	ClassDB::bind_method(D_METHOD("set_frame_cache_disk_budget", "bytes"),
			&Box3DReplayRenderer::set_frame_cache_disk_budget);
	ClassDB::bind_method(D_METHOD("get_frame_cache_disk_budget"),
			&Box3DReplayRenderer::get_frame_cache_disk_budget);
	ADD_PROPERTY(PropertyInfo(Variant::INT, "frame_cache_disk_budget"),
			"set_frame_cache_disk_budget", "get_frame_cache_disk_budget");
	ClassDB::bind_method(D_METHOD("get_frame_cache_disk_bytes"),
			&Box3DReplayRenderer::get_frame_cache_disk_bytes);
	ClassDB::bind_method(D_METHOD("get_resident_frame_count"),
			&Box3DReplayRenderer::get_resident_frame_count);
	ClassDB::bind_method(D_METHOD("get_spill_write_count"), &Box3DReplayRenderer::get_spill_write_count);
	ClassDB::bind_method(D_METHOD("get_spill_read_count"), &Box3DReplayRenderer::get_spill_read_count);
	ClassDB::bind_method(D_METHOD("get_indexed_through"), &Box3DReplayRenderer::get_indexed_through);
	ClassDB::bind_method(D_METHOD("get_cached_runs"), &Box3DReplayRenderer::get_cached_runs);
	ClassDB::bind_method(D_METHOD("get_resident_runs"), &Box3DReplayRenderer::get_resident_runs);
}
