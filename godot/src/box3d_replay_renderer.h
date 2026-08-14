// SPDX-FileCopyrightText: 2026 box3d-godot contributors
// SPDX-License-Identifier: MIT

#pragma once

#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/classes/mesh.hpp>
#include <godot_cpp/classes/multi_mesh.hpp>
#include <godot_cpp/classes/multi_mesh_instance3d.hpp>
#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/classes/shader_material.hpp>
#include <godot_cpp/variant/aabb.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/vector2i.hpp>

#include <box3d/box3d.h>

#include <map>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include "box3d_replay.h"

namespace godot {

// Draws the world a Box3DReplayPlayer is replaying.
//
// WHY THIS EXISTS. A player exposes body transforms and nothing else, so a
// script can move markers around but cannot know what any body LOOKS like: the
// recording's geometry lives in the byte stream's registry, not in the scene.
// Upstream's answer is b3RecPlayer_SetDebugShapeCallbacks (box3d.h:406-417):
// the host hands Box3D a pair of callbacks, Box3D calls the first one the first
// time each replayed shape is drawn (src/physics_world.c:1309-1348) and hands
// back a b3DebugShape carrying the real geometry, and thereafter every
// b3World_Draw reports that shape's world transform and state colour through
// b3DebugDraw::DrawShapeFcn (src/physics_world.c:1353).
//
// THE CHOICE, stated for the record. The alternative was to expose per-body
// shape enumeration to GDScript and rebuild meshes there. This is the C++ route
// instead, for three reasons. (1) The geometry the callback hands over is raw
// upstream data with pointer offsets baked into the blob — b3HullData's
// vertices, edges, faces and planes are all offsets from the struct address
// (collision.h:135-186) — and marshalling that into Variants per shape means
// copying every hull to script only to copy it back into an ArrayMesh. (2) The
// per-frame path has to be a bulk buffer upload: this repo has MEASURED that
// MultiMesh is what makes thousands of bodies affordable (it doubled the
// demo's mobile FPS, and it is what Box3DWorld's own debug shells and
// Box3DMultiMeshRenderer already use), and a GDScript per-shape loop is the
// thing that measurement rejected. (3) The callbacks must be installed
// immediately after b3CreatePlayer and the pointers they return are owned
// by whoever installed them; keeping that ownership inside one C++ node is far
// safer than handing script a lifetime it can only get wrong.
//
// HOW IT DRAWS. One Godot Mesh per DISTINCT recorded geometry, and one
// MultiMesh instance per shape using it — so a Cube Pile of ten thousand
// identical boxes is ONE mesh and ONE draw call. Dedup is by content, not by
// pointer: hulls, meshes and height fields all carry a content hash upstream
// computes over their own blob (types.h:1983, :2179, :2292), and spheres and
// capsules are keyed on their dimensions with their local offset lifted OUT of
// the mesh and into the per-shape transform. That last part matters twice: it
// is why a hundred spheres of the same radius at a hundred different local
// offsets still share one mesh, and it is REQUIRED anyway, because
// DrawShapeFcn reports the BODY transform, not the shape's
// (src/physics_world.c:1353).
//
// PLACEMENT. The MultiMesh instances are ordinary children, so this node's own
// Transform3D places the whole replay in the scene. That is deliberately unlike
// Box3DWorld's debug shells, which are top-level: a live world shares the
// scene's coordinates, while a replay is a separate world you are looking at.
//
// LIFETIME. The node holds a Ref to its player, so the player cannot die first.
// Detaching, changing player, or leaving the tree uninstalls the callbacks and
// frees every shape handle this node created — necessary, because destroying
// the replay world does NOT run the destroy callback for shapes that are still
// alive (upstream only calls it from b3DestroyShape, src/shape.c:1025, and from
// snapshot restore, src/world_snapshot.c:771-773).
//
// THREADING. b3World_Draw walks live solver state and the b3RecPlayer_* family
// is not thread-safe, so everything here is main thread only. The replay world
// is never touched by Box3DWorld's async step; it is a different world.
//
// THE FRAME CACHE (F-R4), and why a renderer owns it. A DISPLAYED frame is
// nothing but a list of shape transforms and colours — the solver is not needed
// to look at one, only to PRODUCE one. Backward playback in upstream's viewer
// (and in this port before this cache) re-produced every frame it displayed:
// b3RecPlayer_SeekFrame restores the nearest keyframe and re-steps the gap
// (src/recording_replay.c:3148-3194), so every backward frame costs a snapshot
// deserialize plus up to a whole keyframe interval of full solver steps.
//
// MEASURED on Cube Pile (4097 replayed shapes, 400 recorded frames, Linux
// template_debug): forward play 8.4 ms/frame, of which the draw — the part this
// node does — is 0.36 ms. Backward play 78-148 ms/frame, 99.7% of it inside the
// player. So a cached frame costs the 0.36 ms and nothing else.
//
// It also measured WHY the keyframe ring alone cannot fix this: one Cube Pile
// keyframe is ~28 MiB, so F-R3's 96 MiB budget holds three of them and the ring
// silently doubles its spacing from the requested 8 up to 128. Sweeping the
// requested interval from 1 to 32 changed the effective interval not at all
// (all 128) and backward play not at all (78 ms). Tuning the policy is not a
// lever at this scale; caching the display is.
//
// The cache stored 32 bytes per drawn instance — origin as three floats, the
// rotation as a quaternion, and the instance colour as RGBA8 — rather than the
// 64-byte MultiMesh row (F-R5, below, packs that row further still). The rotation round-trips through Basis::get_quaternion
// because every instance transform here is rigid by construction (the body
// transform DrawShapeFcn reports, times a shape-local offset that is only ever
// a translation and a rotation), and the colours come from an 8-bit hex palette
// so RGBA8 is exact. Halving the row is what makes a 400-frame Cube Pile fit in
// budget whole (131 KiB/frame, 52 MiB) instead of spilling.
//
// F-R5, WHICH IS WHAT MAKES A BIG SCENE FIT AT ALL. 32 bytes an instance a
// frame is still linear in the scene: Huge Pyramid is 16,290 shapes, so a
// stored frame was 521 KB and the 96 MB budget held 188 of them. A user's
// recording of the pyramid collapsing ran out of budget partway through
// indexing, and every frame past that point fell back to the ~150 ms
// keyframe-and-re-step path — the exact cost F-R4 existed to remove.
//
// Two encodings, and WHICH ONE A FRAME GETS IS MEASURED PER FRAME.
//
// (1) DELTA. A stack that is not moving costs nothing to re-state: a body Box3D
// has put to sleep reports the same transform every frame, bit for bit. So a
// frame can store only the instances that moved, against a full frame every
// `chunk_frames` frames (a CHUNK).
//
// (2) FULL. The premise above is CONTENT DEPENDENT, and the case that prompted
// all this is the one where it fails. Measured on a 300-frame recording of the
// pyramid collapsing: 16,290 of 16,290 instances move by more than 1e-4 EVERY
// FRAME, before the blast as much as after it — a 180-row stack creeps under
// its own load and is one contact island, so it never sleeps and one moving box
// keeps all of them awake. On that content a delta is pure overhead. So the
// encoder counts what moved and takes the delta only while fewer than five
// instances in six have; otherwise it opens a new chunk with a full frame. That
// test is the difference between this being a 12% REGRESSION on the reported
// case and being a win on it.
//
// The row itself went from 32 bytes to 20: position as three 21-bit axes over
// the frame's own AABB, rotation as a smallest-three quaternion at 20 bits a
// component, colour still exact RGBA8. Error bounds are stated at the packing
// helpers in the .cpp and are content-relative by construction — one part in
// 2^21 of whatever the frame spans.
//
// MEASURED, Linux template_debug, against the same recordings:
//
//     Huge Pyramid, 16,290 shapes, 301 frames   521 KB -> 328 KB a frame
//         149.6 MB (188 of 301 frames, TRUNCATED)  ->  94.1 MB, WHOLE
//     Cube Pile, 4,097 shapes, 401 frames        131 KB ->  81 KB a frame
//         50.2 MB -> 31.1 MB
//     backward play and scrub, both, stay a MultiMesh upload:
//         Cube Pile 0.08 ms a frame, Huge Pyramid 0.32 ms
//
// The 1.6x on both is the packing; the delta is what makes settle-heavy content
// nearly free on top of it, and neither of those two recordings is settle-heavy.
//
// Determinism is untouched by any of this. The cache is display only; the
// solver never reads it.
//
// The price, stated plainly. (1) A delta means nothing without the frames it
// inherits from, so eviction lets go of a CHUNK at a time rather than a frame
// at a time; chunks are capped, so the window is still a window and it is still
// contiguous. (2) A frame's rows can no longer be laid out in the order Box3D
// happened to visit shapes, because that order changes as the broad-phase tree
// rebalances — it is a slot per shape now, assigned once at handle creation,
// and the buffer is filled by walking each geometry's slot list. That is
// strictly more stable than what it replaced, and it is what lets a delta name
// an instance at all. (3) A recording still big enough to overrun the budget
// degrades to a sliding window around the playhead: the index pass stands down
// when its own newest frames start being evicted, play and scrub inside the
// window keep the upload path, and a seek outside it costs the player's normal
// keyframe restore.
//
// F-050, WHICH IS WHAT MAKES (3) STOP MATTERING. A window is still a window:
// the user's 1200-frame recording of the pyramid indexed 306 frames into 96 MB
// and stood down, and past that band a seek cost 0.5 s forty frames out, 2.0 s
// at two hundred and 6.1 SECONDS at six hundred — the keyframe-and-re-step path
// again, now with the ring's spacing doubled to 256 frames because one keyframe
// of that scene is 30 MB.
//
// The asymmetry that fixes it: a cached frame is 328 KB of quantised
// transforms, and re-simulating one is 11 to 148 ms of solver. So an evicted
// chunk is WRITTEN OUT (`spill_path` and `spilled`, below) instead of dropped,
// and how much of a recording is reachable stops being a question about RAM.
//
// MEASURED, same recording, same machine, Linux template_debug:
//
//     frames indexed                 306 of 1200  ->  1200 of 1200
//     memory held                      95.7 MB    ->    95.7 MB (unchanged)
//     temp file                            none   ->   325.5 MB
//     seek, 300 frames past the band   2006 ms    ->     0.55 ms
//     seek, 600 frames past it         6139 ms    ->     0.55 ms
//     backward play past the band     818 ms mean ->     0.69 ms mean,
//                                     12,355 max         1.50 max
//     backward play inside it        0.33 ms mean ->     0.35 ms mean
//     process RSS                     425.6 MB    ->   443.9 MB
//
// A chunk read is one seek and one sequential read of its own bytes. Chunks are
// IMMUTABLE once written, which is what keeps the offset table a plain map: a
// chunk read back in keeps its disk image, so dropping it again is free, and
// nothing is ever rewritten in place. The one thing eviction must not take is
// the chunk the encoder is still appending to — closing it early would cost a
// disk record and a lost delta per frame — so the victim is the furthest chunk
// that is not that one.
//
// What this does NOT buy, stated so nobody looks for it: a frame that has never
// been simulated. Coverage grows at the speed of the solver (11-148 ms a frame
// on that scene, 25.9 s for the whole 1200), and no cache makes the first pass
// cheaper. What it does is make the first pass the ONLY one, and turn the
// coverage into a prefix a transport can wait on instead of a window it falls
// off the edge of — see get_indexed_through().
class Box3DReplayRenderer : public Node3D {
	GDCLASS(Box3DReplayRenderer, Node3D)

public:
	// One distinct recorded geometry and the MultiMesh that draws every shape
	// using it.
	struct Geometry {
		uint64_t key = 0;
		b3ShapeType type = b3_sphereShape;
		int triangle_count = 0;
		// True when the mesh is a stand-in rather than the recorded surface —
		// currently only for a geometry blob this build cannot decode, which
		// falls back to its own local AABB so the body is at least visible.
		bool approximate = false;
		Ref<Mesh> mesh;
		MultiMeshInstance3D *mmi = nullptr;
		Ref<MultiMesh> mm;
		// Instance rows, 16 floats each (12 transform + 4 colour). Grown
		// geometrically, never shrunk.
		PackedFloat32Array buffer;
		int count = 0; // rows written by the current update
		int allocated = 0; // MultiMesh instance count currently reserved
		// The slots of every shape handle that has ever used this geometry, in
		// assignment order (so ascending). This is what makes a frame's rows
		// reproducible: the buffer is filled by walking THIS list and taking
		// the slots the frame has, never by the order Box3D happened to visit
		// shapes in. Handles are never removed from it — a destroyed shape's
		// slot simply stops being present in later frames, and the frames that
		// already have it still rebuild exactly.
		std::vector<int> slots;
	};

	// What b3World_Draw hands back to us as the opaque userShape. One per
	// replayed shape; owned by this node.
	struct ShapeHandle {
		int geometry = -1;
		// This shape's row in every slot-indexed array — the live frame, the
		// encoder's reference and the decoder's state. Handed out by a single
		// monotonic counter and NEVER reused, so a slot means the same shape
		// for the whole life of the node and a cached frame stored before this
		// shape existed simply does not have the bit set.
		int slot = -1;
		// Shape-local offset lifted out of the shared mesh, so the mesh can be
		// shared by every shape with the same dimensions. Instance transform is
		// body_transform * local.
		Transform3D local;
		// The shape's owning body, as (index1 << 16) | generation — the
		// identity a recording preserves; see the colour-override note below.
		// Resolved once, when the shape handle is created.
		uint64_t body_key = 0;
		// Colour this shape's body was given by the host, if any. Resolved at
		// handle creation and again whenever the override table changes, so the
		// per-frame path stays a table-free write.
		bool has_override = false;
		Color override_color;
		// Shading response this shape's body was given by the host, if any
		// (F-045): roughness, metallic, specular. Resolved alongside the
		// colour, and NOT stored per frame — a body's material does not change
		// while a recording plays, so it lives per slot and costs the frame
		// cache nothing.
		bool has_material = false;
		float material_roughness = 0.0f;
		float material_metallic = 0.0f;
		float material_specular = 0.0f;
	};

	// One drawn instance as the ENCODER and DECODER handle it: plain floats,
	// 32 bytes. This is scratch, never storage.
	struct RawInstance {
		float px, py, pz;
		float qx, qy, qz, qw;
		uint32_t rgba;
	};

	// One drawn instance AS STORED. 20 bytes.
	//
	// `pos` is three 21-bit fixed-point axes against the frame's own AABB, so
	// the step is the scene's span over 2^21 - 9.5 um across a 20 m Cube Pile,
	// 0.19 mm across Huge Pyramid's 400 m of rubble. `rot` is the quaternion
	// smallest-three: a 2-bit index for the component that was dropped and
	// three 20-bit signed components for the rest, which reconstructs to within
	// ~6e-6 of the basis it came from. `rgba` stays exact, because upstream's
	// palette is 8-bit hex and the override colours are host art that has to
	// come back the colour it went in as.
	struct CachedInstance {
		uint32_t pos0, pos1;
		uint32_t rot0, rot1;
		uint32_t rgba;
	};

	// One displayed frame, DELTA CODED (F-R5). See the delta note above the
	// class for why.
	//
	// `present` is the frame's own occupancy, one bit per slot, always
	// complete — so "was this shape drawn on this frame" is a bit test and
	// never a walk back through the chunk.
	//
	// The first frame of a chunk is a BASE: `values` holds one entry per set
	// bit of `present`, in ascending slot order, and `slots` is empty because
	// the bitset already says which slots they are. Every later frame is a
	// DELTA: `slots` and `values` are exactly the instances that MOVED away
	// from what the decoder already holds, and everything else is inherited.
	struct CachedFrame {
		std::vector<uint32_t> slots;
		std::vector<CachedInstance> values;
		std::vector<uint64_t> present;
		// The frame's own position grid: the lower corner and the step of the
		// 21-bit fixed point. Per frame, so precision follows the content
		// instead of a fixed world size.
		float grid_min[3] = { 0.0f, 0.0f, 0.0f };
		float grid_step[3] = { 0.0f, 0.0f, 0.0f };
		int64_t bytes = 0;
		// How many instances on this frame were coloured from the override
		// table. Per FRAME, not per instance: four bytes so
		// get_override_instance_count() answers for a cached frame as well as
		// for a live walk.
		int override_count = 0;
	};

	// Where a chunk lives once the budget has pushed it out of memory (F-050).
	// The bytes are the chunk's own serialisation, appended once and never
	// rewritten: a completed chunk is immutable, so its disk image stays true
	// for the life of the recording and a chunk read back in can be dropped
	// again for free.
	struct SpillEntry {
		int start = 0;
		int frames = 0;
		int64_t offset = 0;
		int64_t size = 0;
		int end() const { return start + frames - 1; }
	};

	// A contiguous run of frames beginning with a base. THE UNIT OF EVICTION,
	// which is the price of delta coding: a delta means nothing without the
	// frames it inherits from, so the cache lets go of a whole chunk at a time
	// rather than a frame at a time. Chunks are capped at `chunk_frames`, so
	// that granularity is bounded and a backward walk never re-applies more
	// than a chunk's worth of deltas.
	struct CacheChunk {
		int start = 0;
		std::vector<CachedFrame> frames;
		int64_t bytes = 0;
		int end() const { return start + (int)frames.size() - 1; }
	};

private:
	Ref<Box3DReplayPlayer> player;
	uint64_t seen_generation = 0;
	bool auto_update = true;
	// AABB() (zero size) means "auto": use the recording's own accumulated
	// bounds from b3RecPlayer_GetInfo, inflated, falling back to a very large
	// box when the recording reports no bounds.
	AABB drawing_bounds;

	std::vector<Geometry> geometries;
	std::unordered_map<uint64_t, int> geometry_by_key;
	std::unordered_set<ShapeHandle *> handles; // owned
	int last_instance_count = 0;

	// Ordered by first frame, so eviction can reach both ends of the window.
	std::map<int, CacheChunk> chunks;
	int cached_frame_total = 0;
	int64_t frame_cache_bytes = 0;
	// Frames per chunk, i.e. how often a full frame is stored.
	//
	// SWEPT, and the answer is that it is barely a lever — which is worth
	// knowing before anyone spends time on it. Cube Pile, 401 frames, whole
	// cache: interval 1 (i.e. delta coding OFF, every frame full) 82.5 KB a
	// frame, 32 -> 81.2 KB, 128 -> 81.2 KB. All the compression on that content
	// is the 20-byte row, not the deltas; content that actually sleeps is where
	// the deltas pay. What DOES move with the interval is the tail of a
	// backward step, since it re-applies the chunk's deltas: p95 0.09 ms at 32
	// against 0.21 ms at 128. So: 32, which takes the compression and leaves
	// the tail alone.
	//
	// B3_REPLAY_CACHE_CHUNK is the hatch that took that sweep, left in so it
	// can be retaken on other content without a rebuild. Read once, in the
	// constructor.
	int chunk_frames = 32;

	// --- slot-indexed working state -----------------------------------------
	// One row per slot in all four, grown together by ensure_slot(). None of it
	// is cache CONTENT; it is the scratch the encoder and decoder work in.
	int slot_count = 0;
	// The live frame as the draw walk filled it: 16 floats per slot, the exact
	// MultiMesh row. Kept in full float precision, so what is DISPLAYED live is
	// bit-for-bit what it always was and the fidelity assertion still measures
	// the cache rather than measuring itself.
	std::vector<float> live_rows;
	std::vector<uint64_t> live_present;
	// What the decoder will hold after the last frame the encoder stored, which
	// is what a delta is taken against. Comparing against THIS rather than
	// against the previous frame is what bounds the error: a shape drifting by
	// less than the epsilon every frame still gets re-sent the moment its total
	// drift crosses it, so the error never accumulates.
	std::vector<RawInstance> enc_ref;
	std::vector<uint64_t> enc_present;
	int enc_chunk = -1; // chunk the encoder is appending to, -1 for none open
	int enc_frame = -1; // last frame it stored there
	// The decoder's state, and the frame it currently holds.
	std::vector<RawInstance> dec_state;
	std::vector<uint64_t> dec_present;
	// The frame being encoded, unpacked but not yet quantised. Scratch.
	std::vector<RawInstance> raw_scratch;
	int dec_frame = -1;
	int dec_chunk = -1;
	// 0 disables caching entirely. The host sets a platform-appropriate figure;
	// this default matches F-R3's desktop keyframe budget.
	int64_t frame_cache_budget = (int64_t)96 << 20;
	// What the viewer is LOOKING at, which is not where the player is once a
	// prefetch pass runs ahead of it. Eviction is centred here, so a background
	// pass can never throw away the frames around the playhead.
	int cache_playhead = 0;

	// --- the spill file (F-050) ---------------------------------------------
	//
	// WHY. The memory budget is a WINDOW, and on a long recording of a big
	// scene that window is a small fraction of the whole: Huge Pyramid at
	// 16,290 shapes stores 328 KB a frame, so 96 MB is 292 frames and a
	// 1200-frame session indexed 306 of them and stood down. Every frame past
	// that cost the player's keyframe restore and a re-step of the gap --
	// MEASURED at up to 6.1 SECONDS a seek, because one keyframe of that scene
	// is 30 MB and the ring's spacing had doubled to 256 frames.
	//
	// A cached frame is 328 KB of quantised transforms. Reading 328 KB back is
	// three orders of magnitude cheaper than re-simulating 256 frames of
	// 16,290 bodies, and it does not compete for RAM. So an evicted chunk is
	// WRITTEN OUT rather than dropped, and the cache's coverage stops being
	// bounded by memory at all -- it is bounded by the disk budget, which at
	// the default 2 GiB is 6,400 frames of the worst scene this demo has.
	//
	// WHAT IT IS NOT. This is not a format and not a document: it is native
	// bytes in a temp file that lives and dies with the node, and nothing ever
	// reads it that did not write it in the same process. The recording's own
	// `.b3rec` is untouched -- byte for byte, this feature adds nothing to it.
	//
	// EMPTY PATH MEANS OFF, and that is the default: a host that has not asked
	// for a temp file does not get one. The web build deliberately never asks,
	// because `user://` there is IndexedDB through Emscripten's filesystem and
	// the bytes would sit in the same wasm heap the budget exists to protect.
	std::map<int, SpillEntry> spilled;
	String spill_path;
	Ref<FileAccess> spill_file;
	int64_t spill_cursor = 0; // append position; the file only grows
	int64_t spill_bytes = 0; // live bytes on disk
	int64_t spill_disk_budget = (int64_t)2 << 30;
	// An I/O failure stands the spill down for the life of the node rather than
	// retrying once a frame. The cache then behaves exactly as it did before
	// this existed: a window, and the host is told by get_indexed_through().
	bool spill_failed = false;
	int64_t spill_writes = 0;
	int64_t spill_reads = 0;
	PackedByteArray spill_scratch;

	// TWO LOOKS, because a replay is not automatically a debug view (F-038).
	// `material_lit` is the default: an ordinary lit surface, shaded by whatever
	// lights the host scene has, so a recording opened with the shell's Debug
	// switch OFF reads as objects. `material_debug` is a byte-for-byte match of
	// Box3DWorld's own debug-shell treatment (box3d_world.cpp:2279-2289) — flat,
	// self-lit, upstream's state palette — so the switch ON shows the replay the
	// same way the live world would show itself.
	Ref<ShaderMaterial> material_lit;
	Ref<ShaderMaterial> material_debug;
	bool debug_style = false;

	// PER-BODY COLOUR OVERRIDES (F-042), and the identity they are keyed on.
	//
	// A recording is physics, not art: the only colour in it is upstream's
	// STATE palette (dynamic tan, static gray, ...), so every dynamic body in a
	// replay comes out the same colour while the live scene had each one its
	// own. The host can hand over the colours the live scene used, keyed by
	// body, and this table replaces the palette colour per instance.
	//
	// THE KEY IS THE BODY ID, and that it works is upstream's guarantee rather
	// than an assumption: b3RecMakeBodyId retargets a recorded id onto the
	// replay world by replacing world0 ONLY, keeping index1 and generation
	// (src/recording_replay.c:656-663), and every replayed create asserts the
	// id it got back equals the id that was recorded (b3RecCheckBodyId,
	// :695-698). Bodies present when recording started come through the
	// snapshot seed, which serializes the id pools themselves
	// (src/world_snapshot.c:999-1004, :1146-1151). So (index1, generation) is
	// the same number in the live world and in the replay world, and it is the
	// only thing that is. The key packs it as (index1 << 16) | generation.
	//
	// Overrides are applied where the instance row is FILLED, so a cached frame
	// carries the overridden colour and the backward/scrub path stays a pure
	// MultiMesh upload. The cost of that choice: changing the table or the
	// debug style invalidates the frame cache, both of which are one-off host
	// actions rather than per-frame ones.
	//
	// debug_style IGNORES the table. A debug view is asked for in order to see
	// the solver's own state colours; painting the host's art over them would
	// answer a different question.
	std::unordered_map<uint64_t, Color> body_colors;
	// PER-BODY SHADING (F-045), keyed exactly as the colours are. The renderer's
	// own fixed response — roughness 0.85, metallic 0, specular 0.35 — is the
	// MODAL DEFAULT and stays the answer for every body that has no entry, so a
	// recording with no table looks exactly as it did before this existed.
	//
	// It rides the MultiMesh custom-data slot rather than the frame cache: a
	// material is a property of the SHAPE, not of the frame, so storing it per
	// instance per frame would have added 12 bytes to a 20-byte cached row for
	// a value that never changes. The rows are filled from `slot_material` at
	// compaction, which the cached path and the live path share. Custom data is
	// only turned on when a table is actually set, so the common case still
	// uploads 16 floats an instance instead of 20.
	std::unordered_map<uint64_t, Vector3> body_materials;
	Dictionary body_materials_source;
	// Four floats per slot: roughness, metallic, specular, and 1.0 when the
	// body has an entry (the shader reads that last one as "use these").
	std::vector<float> slot_material;
	bool use_custom_data = false;
	// Floats per MultiMesh instance row: 16, or 20 once custom data is on.
	int row_stride = 16;
	// The Dictionary exactly as the host handed it over, so the property reads
	// back what was written.
	Dictionary body_colors_source;
	int last_override_count = 0;

	// Callback trampolines handed to Box3D. Context is `this`.
	static void *cb_create_debug_shape(const b3DebugShape *p_shape, void *p_context);
	static void cb_destroy_debug_shape(void *p_user_shape, void *p_context);
	static void cb_draw_shape(void *p_user_shape, b3WorldTransform p_transform,
			b3HexColor p_color, void *p_context);

	void *create_shape_handle(const b3DebugShape *p_shape);
	void destroy_shape_handle(void *p_user_shape);
	void push_instance(ShapeHandle *p_handle, const Transform3D &p_body, const Color &p_color);

	// Find or build the geometry for a content key; returns its index.
	int intern_geometry(uint64_t p_key, b3ShapeType p_type, const Ref<Mesh> &p_mesh,
			int p_triangle_count, bool p_approximate);

	// Re-point every live shape handle at the current override table. Called
	// when the table changes; handle creation resolves its own.
	void resolve_overrides();
	void resolve_override(ShapeHandle *p_handle);
	void resolve_material(ShapeHandle *p_handle);
	void write_slot_material(const ShapeHandle *p_handle);
	// Turn the custom-data slot on and rebuild the MultiMeshes around the wider
	// row. One-off: it happens when a material table is first set.
	void enable_custom_data();

	void ensure_material();
	void apply_material();
	void ensure_nodes();
	void install();
	void uninstall();
	void detach_all_handles();

	// update() split in two, so a frame can be produced without being shown.
	// draw_walk() runs b3World_Draw and leaves the instance rows in the
	// geometries' buffers; upload() is the RenderingServer half.
	bool draw_walk();
	void upload();
	// Pack the frame the walk just filled into the cache under p_frame.
	// Returns false when the entry was evicted immediately, i.e. the caller has
	// run past the end of the affordable window.
	bool store_frame(int p_frame);
	void evict_to_budget();

	// Make room for p_slot in every slot-indexed array.
	void ensure_slot(int p_slot);
	// Fill the geometry buffers by walking each geometry's slot list and taking
	// the slots the frame has. The two sources a frame can come from — a live
	// draw walk (full float rows) and the decoder (packed instances) — go
	// through one of these each, and they produce the same row ORDER, which is
	// what makes a cached frame comparable to the live one row by row.
	void compact_live();
	void compact_decoded();
	// Bring dec_state up to p_frame, stepping deltas forward from where it
	// already is when that is cheaper than starting from the chunk's base.
	// False when p_frame is not cached.
	bool decode_to(int p_frame);
	CacheChunk *find_chunk(int p_frame);
	const CacheChunk *find_chunk(int p_frame) const;

	// --- the spill file (F-050) ---------------------------------------------
	bool spill_enabled() const { return !spill_path.is_empty() && !spill_failed; }
	// Open the temp file on first use. False (and spill_failed) if it will not.
	bool open_spill();
	// Close the handle and delete the file. Called on clear, on a path change
	// and from the destructor, so a session never leaves bytes behind.
	void close_spill();
	int64_t chunk_serialized_size(const CacheChunk &p_chunk) const;
	void serialize_chunk(const CacheChunk &p_chunk, uint8_t *p_dst) const;
	bool deserialize_chunk(const uint8_t *p_src, int64_t p_size, CacheChunk &r_chunk) const;
	// Write a chunk out and register it. False when the spill is off, full or
	// broken -- in which case the caller drops the chunk, as it always did.
	bool spill_chunk(const CacheChunk &p_chunk);
	// Drop a chunk from memory, writing it out first unless a valid disk image
	// already exists. THE ONLY PLACE a chunk leaves `chunks`.
	void release_chunk(std::map<int, CacheChunk>::iterator p_it);
	// Read the chunk holding p_frame back into memory. False when it is not on
	// disk or the read fails.
	bool load_spilled(int p_frame);
	const SpillEntry *find_spilled(int p_frame) const;
	// Every cached range, memory and disk merged and adjacent runs joined.
	void collect_runs(std::vector<Vector2i> &r_runs, bool p_resident_only) const;
	// Rewrite a chunk's second frame as a base and drop its first, so the front
	// of the window can move without stranding the deltas behind it.
	void rebase_front(int p_start);
	void forget_frames(int p_lo, int p_hi);

protected:
	static void _bind_methods();
	void _notification(int p_what);

public:
	Box3DReplayRenderer();
	~Box3DReplayRenderer();

	// The player to draw. Setting one installs the debug-shape callbacks on it
	// (which rewinds it to frame 0, as upstream's own contract requires:
	// box3d.h:408-410). Set this BEFORE stepping, or the first frames replay
	// without the renderer watching. Passing null detaches.
	void set_player(const Ref<Box3DReplayPlayer> &p_player);
	Ref<Box3DReplayPlayer> get_player() const;

	// Redraw from the player's CURRENT frame. Cheap to call repeatedly; it
	// runs b3World_Draw over the replay world and re-uploads the instance
	// buffers. Called automatically every frame while auto_update is on.
	void update();

	void set_auto_update(bool p_enabled);
	bool is_auto_update() const;

	// Draw the replay the way a debug view draws (flat, self-lit, upstream's
	// state palette — the same treatment Box3DWorld's debug shells get) instead
	// of as ordinary lit surfaces. OFF by default: a host that has not asked for
	// a debug view must not be given one. The shell drives this straight off its
	// Debug switch, so entering a replay inherits whatever was on screen.
	void set_debug_style(bool p_enabled);
	bool is_debug_style() const;

	// Colour the replay's bodies the way the host coloured them, instead of by
	// the solver's state palette (F-042). Keys are body identities as
	// "<index1>:<generation>" — the id the recording preserves, see the note on
	// `body_colors` above — and values are Colors. An empty Dictionary is the
	// fallback and the default: every body keeps the palette colour the
	// recording carries, which is exactly the pre-F-042 look. Keys naming a
	// body the recording does not contain are simply never asked for.
	//
	// Setting this invalidates the frame cache, because the override is baked
	// into the cached rows. So is toggling debug_style while a table is set.
	void set_body_color_overrides(const Dictionary &p_colors);
	Dictionary get_body_color_overrides() const;

	// Shade the replay's bodies the way the host shaded them (F-045). Keys are
	// the same "<index1>:<generation>" body identities `body_color_overrides`
	// uses; values are Dictionaries with any of "roughness", "metallic" and
	// "specular", each a float in 0..1. A body with no entry — and every body,
	// when the table is empty — keeps the renderer's own response, which is
	// roughness 0.85, metallic 0.0, specular 0.35.
	//
	// Unlike the colour table this does NOT invalidate the frame cache: a
	// material belongs to the shape rather than to the frame, so it is resolved
	// per shape and written at upload. `debug_style` ignores it, for the same
	// reason it ignores the colours — a debug view was asked for in order to
	// see the solver's own state, not the host's art.
	void set_body_material_overrides(const Dictionary &p_materials);
	Dictionary get_body_material_overrides() const;

	// How many of the instances on screen were coloured from the table rather
	// than from the recording's palette. Answers for a cached frame too. This
	// is how a test proves the override actually reached the draw instead of
	// trusting that a table was accepted.
	int get_override_instance_count() const;

	// b3DebugDraw::drawingBounds — everything outside is culled before any
	// callback fires. Leave at AABB() for "use the recording's own bounds".
	void set_drawing_bounds(const AABB &p_bounds);
	AABB get_drawing_bounds() const;

	// --- introspection, so a script (and the selftest) can prove the geometry
	// --- really arrived rather than trusting that something got drawn.

	// Distinct recorded geometries currently interned, i.e. MultiMeshes.
	int get_geometry_count() const;
	// Replayed shapes this node has been handed a geometry for.
	int get_shape_count() const;
	// Instances written by the last update(), i.e. shapes actually drawn.
	int get_instance_count() const;
	// Triangles across the DISTINCT meshes, not multiplied by instance count.
	int get_triangle_count() const;
	// Per-geometry detail: type (upstream's b3ShapeType spelling), triangles,
	// instances drawn last update, approximate.
	Dictionary get_geometry_info(int p_index) const;

	// One instance row as it currently stands in the buffers, whether they were
	// filled by a live draw or by a cached frame. This is how a test proves a
	// cached frame reproduces the frame it was captured from rather than
	// trusting that the instance COUNT matched.
	Transform3D get_instance_transform(int p_geometry, int p_index) const;
	Color get_instance_color(int p_geometry, int p_index) const;

	// --- the frame cache (F-R4) ---------------------------------------------

	// Draw the player's current frame AND remember it as p_frame. This is what
	// the transport calls for every frame it displays through the player, so
	// playing forward once is what makes playing backward free.
	void capture_frame(int p_frame);

	// Remember the player's current frame as p_frame WITHOUT changing what is
	// on screen. A background pass uses this to fill the cache while the viewer
	// stays parked wherever the user left it. Returns false once the pass has
	// run past the affordable window, which is the signal to stop.
	bool prefetch_frame(int p_frame);

	// Re-upload a remembered frame. Returns false if it is not cached, in which
	// case nothing was touched and the caller has to produce it the slow way.
	bool draw_cached_frame(int p_frame);

	bool has_cached_frame(int p_frame) const;
	void clear_frame_cache();
	int get_cached_frame_count() const;
	int64_t get_frame_cache_bytes() const;
	// Lowest and highest cached frame, or (-1, -1) when nothing is cached.
	Vector2i get_cached_frame_range() const;

	// Bytes the cache may hold IN MEMORY. Setting a smaller one evicts at once;
	// 0 turns caching off. The window is centred on the last frame actually
	// displayed. With a spill path set this is a working-set size rather than a
	// coverage limit -- what leaves memory goes to disk instead of being lost.
	void set_frame_cache_budget(int64_t p_bytes);
	int64_t get_frame_cache_budget() const;

	// --- the spill file (F-050) ---------------------------------------------

	// Where evicted chunks go. Empty (the default) means nowhere: the cache is
	// a memory window and behaves exactly as it did before this existed. The
	// path is a TEMP FILE this node owns — it is created on first eviction,
	// truncated on clear, and deleted when the node is freed or the path
	// changes. Point it inside `user://`; the host is responsible for choosing
	// a name no other instance will pick, and for not pointing it at anything
	// it minds losing.
	//
	// Setting it does not move what is already cached; setting it to "" drops
	// everything already spilled, because those frames have nowhere left to be
	// read from.
	void set_frame_cache_spill_path(const String &p_path);
	String get_frame_cache_spill_path() const;

	// Ceiling on the temp file, in bytes. Default 2 GiB. Reaching it stands the
	// spill down softly: further evictions drop their chunks as they used to,
	// coverage stops being a prefix, and get_indexed_through() says so.
	void set_frame_cache_disk_budget(int64_t p_bytes);
	int64_t get_frame_cache_disk_budget() const;

	// Bytes currently live in the temp file.
	int64_t get_frame_cache_disk_bytes() const;
	// Frames held in memory, i.e. what get_frame_cache_bytes() accounts for.
	// get_cached_frame_count() counts these AND the spilled ones, because both
	// are frames a caller can draw without touching the player.
	int get_resident_frame_count() const;
	// Chunk writes and chunk reads the spill has done. Introspection: this is
	// how a test proves the overflow really went to disk and really came back.
	int64_t get_spill_write_count() const;
	int64_t get_spill_read_count() const;

	// The highest F for which EVERY frame in 1..F is cached, or 0 for none.
	//
	// This is the contract a transport needs to stay forward-only: while the
	// coverage is a prefix, a frame at or below this number is an upload and
	// anything above it is ahead of the player, so the player never has to be
	// walked BACKWARD to produce a frame. A host that sees this stop tracking
	// the frames it has stored knows the spill has stood down and it is back to
	// a sliding window.
	int get_indexed_through() const;

	// The cached ranges, as inclusive [first, last] frame pairs with adjacent
	// runs joined. `get_cached_runs` counts memory and disk alike -- both are
	// frames that draw without the player -- and `get_resident_runs` is the
	// memory subset, which is what makes the two-tier buffer band possible.
	Array get_cached_runs() const;
	Array get_resident_runs() const;

	// Drop every mesh, MultiMesh and shape handle, and uninstall the
	// callbacks. The player keeps replaying; it just stops being drawn.
	//
	// The colour-override table SURVIVES this, deliberately: the draw walk
	// calls clear() itself when a different recording is opened, and the host
	// sets the table once, at open, before any of that has happened.
	void clear();
};

} // namespace godot
