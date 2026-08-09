// SPDX-FileCopyrightText: 2026 box3d-godot contributors
// SPDX-License-Identifier: MIT

#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/aabb.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/transform3d.hpp>

#include <box3d/box3d.h>

namespace godot {

class Box3DWorld;

// Upstream's recording and replay system (box3d.h:255-468), which writes every
// world mutation and every step to a byte stream and can stand that stream back
// up in a fresh world.
//
// WHAT THIS IS FOR. A recording is not a savegame and not an animation: it is a
// determinism instrument. Recording embeds a state hash of the world after
// every step (src/physics_world.c:1173-1180, plus an anchor hash at session
// start, src/recording.c:1062-1066), and replay recomputes that hash and
// compares. Because the player can stand the recording up at a DIFFERENT worker
// count than it was recorded at, and a different worker count re-partitions the
// constraint graph, a replay that reports no divergence is a live cross-thread
// determinism check on the very property this repo's red lines protect
// (box3d.h:322-327).
//
// WHAT IS HASHED, exactly, so nobody over-reads a passing replay:
// b3HashWorldState (src/recording.c:1223-1266) is an FNV-1a over every live
// body's transform (position + quaternion) and, when the body has a solver
// state, its linear and angular velocity. Contacts, joints, impulses and sleep
// flags are NOT hashed. A matching replay proves the bodies ended up in the
// same places at the same speeds; it does not prove the contact set was
// identical along the way.
//
// PATHS. Upstream's b3SaveRecordingToFile / b3LoadRecordingFromFile are plain
// fopen on an OS path (src/recording.c:1113-1177), so they cannot see res://
// (which is inside the .pck of an exported game and is not a file at all) and
// they cannot see user:// on the platforms where it is not a plain directory.
// Neither is bound. Everything here moves bytes through PackedByteArray and
// Godot's own FileAccess instead, which works identically in the editor, in an
// exported desktop game, on Android and in the browser. That is also why the
// player opens from bytes: b3RecPlayer_Create takes a raw buffer
// (box3d.h:319-324), so no b3Recording ever has to be reconstructed to replay
// one.
//
// The conventional extension is .b3rec (the repo's .gitignore carries it).

// A recording buffer: the write side of the system. Hand one to
// Box3DWorld.start_recording() and it fills as the world steps.
//
// LIFETIME AND THE ONE CONTRACT THAT BITES. The bytes are only a complete,
// loadable recording after the session is stopped: stopping is what appends the
// geometry registry and backpatches the header's registry offset
// (src/recording.c:1069-1108). Reading the bytes mid-session would therefore
// hand out a file that b3RecPlayer_Create rejects, so get_data() and
// save_to_file() REFUSE while a session is live and say so. Stop first.
//
// A world being destroyed stops its recording for you (b3DestroyWorld ->
// b3StopRecordingInternal, src/physics_world.c:414-415), so a scene that quits
// mid-recording still leaves a complete buffer; Box3DWorld does it explicitly
// so this object's own is_recording() cannot go stale.
class Box3DRecording : public RefCounted {
	GDCLASS(Box3DRecording, RefCounted)

private:
	b3Recording *rec = nullptr;
	// Non-owning. Set for exactly as long as a world is recording into this
	// buffer; the world holds a Ref to this object over the same interval, so
	// this pointer cannot dangle. Used to refuse reads mid-session and to
	// reach that world's async-step join before touching the buffer.
	Box3DWorld *recording_world = nullptr;

protected:
	static void _bind_methods();

public:
	Box3DRecording();
	~Box3DRecording();

	// b3CreateRecording's byteCapacity (box3d.h:262-264). The default buffer is
	// 64 KiB and grows on demand, so this is a reallocation optimisation, not a
	// cap: a long recording of a heavy scene is tens of megabytes either way.
	static Ref<Box3DRecording> create(int p_byte_capacity);

	// b3Recording_GetSize. Live during a session, so this is the one honest
	// progress readout while recording.
	int get_size() const;

	// A copy of the buffer (b3Recording_GetData, box3d.h:266-270). Copied at
	// the moment of the call and never held, because upstream's pointer is only
	// valid until the next byte is written. Empty, with an error, while a
	// session is still running.
	PackedByteArray get_data() const;

	// Writes get_data() through Godot's FileAccess, so user:// and any
	// globalizable path work in an exported game on every platform. Refuses
	// while a session is running, for the same reason get_data() does.
	bool save_to_file(const String &p_path) const;

	// True between Box3DWorld.start_recording() and stop_recording().
	bool is_recording() const;

	// THE ONE IDENTITY THAT CROSSES A RECORDING (F-042). Returns a live
	// Box3DBody's identity as "<index1>:<generation>", or "" if it is not a
	// Box3DBody or has no live body.
	//
	// A recording holds physics and no art, so anything a host wants to carry
	// alongside one — colours, names, materials — has to be keyed on something
	// that means the same thing in the live world and in the replayed world.
	// This is that key, and it is upstream's guarantee rather than a
	// convention: b3RecMakeBodyId retargets a recorded body id onto the replay
	// world by replacing world0 ONLY, keeping index1 and generation
	// (src/recording_replay.c:656-663), and every replayed b3CreateBody asserts
	// the id it got back has the recorded index1 and generation
	// (b3RecCheckBodyId, :695-698, via b3RecCheckId :685-693). Bodies that
	// already existed when recording started arrive through the snapshot seed
	// (src/recording.c:1050-1058), which serializes the id pools themselves
	// (src/world_snapshot.c:999-1004 / :1146-1151), so their ids are preserved
	// too. Node paths, names and instance indices survive none of that.
	//
	// The generation is part of the key on purpose: index1 is a slot and a slot
	// is reused, so a body destroyed mid-recording and one created after it can
	// share an index1 and must not share a colour.
	//
	// Static because it describes a body, not a buffer, and the caller usually
	// wants it for bodies it is about to record rather than for a recording it
	// already holds.
	static String get_body_key(Object *p_body);

	// Internal, for Box3DWorld only.
	b3Recording *get_handle() const { return rec; }
	void attach_world(Box3DWorld *p_world);
	void detach_world();
};

// The read side: an incremental player over recorded bytes, driving its OWN
// private world.
//
// THE PLAYER NEVER TOUCHES YOUR WORLD. b3RecPlayer_Create stands up a fresh
// b3CreateWorld of its own (src/recording_replay.c:2715-2725, called at :2820)
// and every dispatched op is retargeted onto it — the recorded world id is
// informational and the id-remapping helpers overwrite the world field of every
// body, shape and joint id (src/recording_replay.c:656-681). So replaying
// cannot mutate a Box3DWorld, a Box3DBody or a Box3DJoint that a scene owns,
// however many joint setters the stream contains. That is deliberate here as
// well as upstream: b3RecPlayer_GetWorldId is NOT bound, because handing script
// a raw world id would be the one way to break that guarantee.
//
// ONE PROCESS-WIDE SIDE EFFECT, so budget for it. A recording carries the
// length scale it was made at (src/recording.c:1043) and opening one INSTALLS
// that scale globally (b3SetLengthUnitsPerMeter, src/recording_replay.c:2809-
// 2813), restoring the previous value when the player is closed
// (src/recording_replay.c:2958-2960). While a player is open, every other Box3D
// world in the process is running under the recording's scale. Keep players
// short-lived, and do not open one from a scene that has authored a non-default
// physics/box3d/length_units_per_meter unless the recording was made at the
// same scale. (Upstream leaks the scale when Create fails partway; this binding
// restores it itself on every failure path.)
//
// THREADING. Nothing in the b3RecPlayer_* family is documented thread-safe and
// every call mutates replay state, so drive a player from the main thread only.
// It is unrelated to Box3DWorld's async step: the replay world is a different
// world and is never stepped by the binding's step thread.
//
// NOT BOUND TO SCRIPT, on purpose: b3RecPlayer_GetWorldId,
// b3RecPlayer_DrawFrameQueries and the recorded-query inspection surface
// (GetFrameQuery / GetFrameQueryHit). Handing script a raw world id is the one
// way to break the "the player never touches your world" guarantee above, and
// the query surface is a debug VIEWER's need rather than a determinism
// harness's. b3ValidateReplay is not bound either: it is the one-shot
// assert-based form of the same check, while this player reports divergence as
// data.
//
// b3RecPlayer_SetDebugShapeCallbacks IS wired, but only in C++, and only
// through install_debug_shape_callbacks() below — Box3DReplayRenderer is its
// one caller. Upstream requires it be called immediately after
// b3RecPlayer_Create, because it destroys and rebuilds the replay world under
// the new callbacks and rewinds to frame 0 (box3d.h:406-413,
// src/recording_replay.c:3635-3671). This class therefore REMEMBERS the
// callback triple and re-applies it inside open(), right after Create, so a
// renderer that was attached before a recording was opened gets the ordering
// upstream asks for without the caller having to sequence it.
class Box3DReplayPlayer : public RefCounted {
	GDCLASS(Box3DReplayPlayer, RefCounted)

private:
	b3RecPlayer *player = nullptr;
	int worker_count = 1;
	// Remembered so open() can re-apply them right after b3RecPlayer_Create,
	// which is the ordering upstream requires (see the class comment).
	b3CreateDebugShapeCallback *cb_create = nullptr;
	b3DestroyDebugShapeCallback *cb_destroy = nullptr;
	void *cb_context = nullptr;
	// Bumped by every successful open(). A renderer watches this to notice it
	// is now looking at a different recording and drop its cached geometry.
	uint64_t open_generation = 0;

protected:
	static void _bind_methods();

public:
	Box3DReplayPlayer();
	~Box3DReplayPlayer();

	// Open a recording from bytes (b3RecPlayer_Create). Closes any previously
	// open recording first. Returns false on a bad header, a version or
	// pointer-width mismatch, or a corrupt stream; upstream prints the reason.
	//
	// WORKER COUNT IS CHOSEN HERE AND ESSENTIALLY ONLY HERE. This is the whole
	// determinism handle and it is easy to get wrong, so read this before
	// using set_worker_count(). The replay world is created with
	// b3WorldDef.workerCount = this argument (src/recording_replay.c:2721),
	// and b3CreateWorld only builds the internal scheduler — the thing that
	// actually spawns threads — when that def asks for more than one worker
	// (src/physics_world.c:367-386). b3World_SetWorkerCount afterwards
	// rebuilds the worker CONTEXTS and never creates a scheduler
	// (src/physics_world.c:2271-2287), and the player never rebuilds its world
	// on Restart or a seek (b3RecPlayer_Restart deserializes in place,
	// src/recording_replay.c:3116-3147). So a player opened at 1 and raised to
	// 8 afterwards re-partitions the graph but still executes serially: it is a
	// weaker test than it looks. Open at the count you want to test.
	bool open(const PackedByteArray &p_data, int p_worker_count = 1);
	// Reads the file through Godot's FileAccess, then open(). Works with
	// user:// and res:// in an exported game, which upstream's own loader
	// cannot (see the header comment above).
	bool open_file(const String &p_path, int p_worker_count = 1);
	void close();
	bool is_open() const;

	// b3RecPlayer_StepFrame: dispatch ops until the next step completes.
	// Returns false at end of recording, and keeps returning false.
	bool step_frame();
	// b3RecPlayer_SubStepFrame: stops between body creation and the step so a
	// viewer can draw the creation pose. The next call runs the step.
	void sub_step_frame();
	// b3RecPlayer_Restart: back to frame 0, in place, world id stable. Clears
	// the divergence flag, so a restart is a fresh verdict.
	void restart();
	// b3RecPlayer_SeekFrame. Backward seeks restore the nearest keyframe and
	// re-step the gap. Out of range is safe in both directions: negatives clamp
	// to 0 and a target past the end stops at the end.
	void seek_frame(int p_frame);

	// Step to the end of the recording and report whether the embedded hashes
	// all matched — i.e. the whole determinism check in one call. Bound as a
	// method rather than left to a GDScript loop because the loop is per-frame
	// and a heavy recording is thousands of frames.
	bool replay_all();

	int get_frame() const;
	int get_frame_count() const;
	bool is_at_end() const;
	bool is_at_pre_step() const;

	// b3RecPlayer_HasDiverged / GetDivergeFrame: true once any embedded state
	// hash failed to reproduce, and the first frame at which that happened
	// (-1 if never). Divergence is NOT fatal — the player keeps going, which is
	// what makes the frame number useful.
	bool has_diverged() const;
	int get_diverge_frame() const;

	// b3RecPlayer_GetInfo (b3RecPlayerInfo, box3d.h:307-315), keys spelled as
	// upstream's fields: frameCount, workerCount, timeStep, subStepCount,
	// lengthScale, bounds. Note that workerCount is the count REQUESTED for the
	// replay, not one read from the file: the header has no worker-count field
	// (src/recording.h:59-76), so a recording does not remember how many
	// workers made it.
	Dictionary get_info() const;

	// b3RecPlayer_SetWorkerCount, clamped upstream to [1, B3_MAX_WORKERS].
	// Applied to the live replay world at once. Read open()'s note first: this
	// cannot add threads to a player that was opened serially.
	void set_worker_count(int p_count);
	int get_worker_count() const;

	// The keyframe ring that makes backward seeking cheap
	// (b3RecPlayer_SetKeyframePolicy, box3d.h:379-387). A zero budget or a
	// non-positive interval keeps that value. Setting a policy clears the ring,
	// so this restarts the player, as upstream requires.
	void set_keyframe_policy(int64_t p_budget_bytes, int p_min_interval_frames);
	int64_t get_keyframe_budget() const;
	int get_keyframe_min_interval() const;
	// The spacing in force now: it starts at the minimum interval and doubles
	// as the ring evicts to stay under budget.
	int get_keyframe_interval() const;
	int64_t get_keyframe_bytes() const;

	// Bodies in creation order, INCLUDING holes where a body was destroyed
	// (box3d.h:398-402), so the count is not the live body count and an index
	// can legitimately resolve to nothing. is_body_valid() is how you tell.
	// Enough to render a replay from script without any draw plumbing.
	int get_body_count() const;
	bool is_body_valid(int p_index) const;
	Transform3D get_body_transform(int p_index) const;

	// --- C++ only, not bound. Box3DReplayRenderer's private door. ---

	// b3RecPlayer_SetDebugShapeCallbacks (box3d.h:406-417). Applied at once if
	// a recording is open, and remembered so the next open() applies it
	// immediately after b3RecPlayer_Create. Passing three nulls uninstalls.
	//
	// THE CALLER OWNS THE SHAPE HANDLES IT RETURNS AND MUST FREE THEM ITSELF
	// when it uninstalls: destroying the replay world does NOT run the destroy
	// callback for shapes that are still alive (upstream only calls it from
	// b3DestroyShape, src/shape.c:1025, and from snapshot restore,
	// src/world_snapshot.c:771-773), and this call destroys the world
	// (src/recording_replay.c:3650-3654).
	void install_debug_shape_callbacks(b3CreateDebugShapeCallback *p_create,
			b3DestroyDebugShapeCallback *p_destroy, void *p_context);

	// b3RecPlayer_GetWorldId, for b3World_Draw only. Never bound: see above.
	// Re-read on every call rather than cached, because Restart and backward
	// seeks recreate the world under the player.
	b3WorldId get_replay_world_id() const;

	// Changes on every successful open(); a renderer compares it to know its
	// cached meshes belong to a recording that is no longer loaded.
	uint64_t get_open_generation() const { return open_generation; }
};

} // namespace godot
