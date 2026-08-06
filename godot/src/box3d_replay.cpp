// SPDX-FileCopyrightText: 2026 box3d-godot contributors
// SPDX-License-Identifier: MIT

#include "box3d_replay.h"

#include "box3d_conversions.h"
#include "box3d_world.h"

#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

using namespace godot;

// --- Box3DRecording ---------------------------------------------------------

Box3DRecording::Box3DRecording() {
	// 0 asks for upstream's 64 KiB default, which grows on demand
	// (box3d.h:262-264).
	rec = b3CreateRecording(0);
}

Box3DRecording::~Box3DRecording() {
	// The world holds a Ref for the whole session, so a live session cannot
	// reach here. Belt and braces anyway: destroying the buffer out from under
	// a recording world would leave that world writing into freed memory.
	if (recording_world != nullptr) {
		recording_world->stop_recording();
	}
	b3DestroyRecording(rec); // NULL-safe upstream
	rec = nullptr;
}

Ref<Box3DRecording> Box3DRecording::create(int p_byte_capacity) {
	Ref<Box3DRecording> out;
	out.instantiate();
	if (p_byte_capacity > 0 && out->rec != nullptr) {
		b3DestroyRecording(out->rec);
		out->rec = b3CreateRecording(p_byte_capacity);
	}
	return out;
}

int Box3DRecording::get_size() const {
	return rec != nullptr ? b3Recording_GetSize(rec) : 0;
}

PackedByteArray Box3DRecording::get_data() const {
	PackedByteArray out;
	if (rec == nullptr) {
		return out;
	}
	if (recording_world != nullptr) {
		ERR_PRINT("Box3DRecording: the bytes are incomplete until the session is stopped "
				  "(stop_recording() writes the geometry registry and backpatches the header). "
				  "Call Box3DWorld.stop_recording() first.");
		return out;
	}
	const int size = b3Recording_GetSize(rec);
	const uint8_t *data = b3Recording_GetData(rec);
	if (size <= 0 || data == nullptr) {
		return out;
	}
	// Copied here and never held: upstream's pointer is only valid until the
	// next byte is written (box3d.h:266-270).
	out.resize(size);
	memcpy(out.ptrw(), data, (size_t)size);
	return out;
}

bool Box3DRecording::save_to_file(const String &p_path) const {
	const PackedByteArray bytes = get_data();
	if (bytes.is_empty()) {
		return false;
	}
	Ref<FileAccess> f = FileAccess::open(p_path, FileAccess::WRITE);
	if (f.is_null()) {
		ERR_PRINT(vformat("Box3DRecording: cannot open \"%s\" for writing (error %d).",
				p_path, (int)FileAccess::get_open_error()));
		return false;
	}
	f->store_buffer(bytes);
	f->close();
	return true;
}

bool Box3DRecording::is_recording() const {
	return recording_world != nullptr;
}

void Box3DRecording::attach_world(Box3DWorld *p_world) {
	recording_world = p_world;
}

void Box3DRecording::detach_world() {
	recording_world = nullptr;
}

void Box3DRecording::_bind_methods() {
	ClassDB::bind_static_method("Box3DRecording", D_METHOD("create", "byte_capacity"),
			&Box3DRecording::create, DEFVAL(0));
	ClassDB::bind_method(D_METHOD("get_size"), &Box3DRecording::get_size);
	ClassDB::bind_method(D_METHOD("get_data"), &Box3DRecording::get_data);
	ClassDB::bind_method(D_METHOD("save_to_file", "path"), &Box3DRecording::save_to_file);
	ClassDB::bind_method(D_METHOD("is_recording"), &Box3DRecording::is_recording);
}

// --- Box3DReplayPlayer ------------------------------------------------------

Box3DReplayPlayer::Box3DReplayPlayer() {}

Box3DReplayPlayer::~Box3DReplayPlayer() {
	close();
}

bool Box3DReplayPlayer::open(const PackedByteArray &p_data, int p_worker_count) {
	close();
	if (p_data.is_empty()) {
		ERR_PRINT("Box3DReplayPlayer: no recording bytes.");
		return false;
	}
	int count = p_worker_count < 1 ? 1 : p_worker_count;
#ifdef BOX3D_NO_THREADS
	// Same clamp as Box3DWorld::set_worker_count: a single-threaded wasm build
	// has no pthreads, and b3RecPlayer_Create goes to b3CreateScheduler ->
	// pthread_create for any count above 1 — with exceptions disabled that
	// refusal aborts the process, so clamp rather than trust the caller.
	count = 1;
#endif
	// Upstream installs the recording's length scale before it finishes
	// validating the header, and every failure path returns without restoring
	// it (src/recording_replay.c:2809-2813 vs :2833-2869). Snapshot it here so
	// a rejected recording cannot silently rescale every other world in the
	// process.
	const float previous_scale = b3GetLengthUnitsPerMeter();
	b3RecPlayer *p = b3RecPlayer_Create(p_data.ptr(), p_data.size(), count);
	if (p == nullptr) {
		if (b3GetLengthUnitsPerMeter() != previous_scale) {
			b3SetLengthUnitsPerMeter(previous_scale);
		}
		ERR_PRINT("Box3DReplayPlayer: the recording could not be opened "
				  "(bad magic, version, pointer width or a corrupt stream).");
		return false;
	}
	player = p;
	worker_count = count;
	return true;
}

bool Box3DReplayPlayer::open_file(const String &p_path, int p_worker_count) {
	// FileAccess rather than b3LoadRecordingFromFile: see the class comment.
	// This reads res:// out of an exported .pck, which fopen cannot.
	Ref<FileAccess> f = FileAccess::open(p_path, FileAccess::READ);
	if (f.is_null()) {
		ERR_PRINT(vformat("Box3DReplayPlayer: cannot open \"%s\" for reading (error %d).",
				p_path, (int)FileAccess::get_open_error()));
		return false;
	}
	const PackedByteArray bytes = f->get_buffer((int64_t)f->get_length());
	f->close();
	return open(bytes, p_worker_count);
}

void Box3DReplayPlayer::close() {
	if (player != nullptr) {
		// Restores the length scale that was in force before open().
		b3RecPlayer_Destroy(player);
		player = nullptr;
	}
}

bool Box3DReplayPlayer::is_open() const {
	return player != nullptr;
}

bool Box3DReplayPlayer::step_frame() {
	if (player == nullptr) {
		return false;
	}
	return b3RecPlayer_StepFrame(player);
}

void Box3DReplayPlayer::sub_step_frame() {
	if (player == nullptr) {
		return;
	}
	b3RecPlayer_SubStepFrame(player);
}

void Box3DReplayPlayer::restart() {
	if (player == nullptr) {
		return;
	}
	b3RecPlayer_Restart(player);
}

void Box3DReplayPlayer::seek_frame(int p_frame) {
	if (player == nullptr) {
		return;
	}
	b3RecPlayer_SeekFrame(player, p_frame);
}

bool Box3DReplayPlayer::replay_all() {
	if (player == nullptr) {
		return false;
	}
	// StepFrame returns false once the op stream is exhausted and keeps
	// returning false, so this terminates; the frame count is the belt and
	// braces against a stream that never reports the end.
	const int limit = b3RecPlayer_GetFrameCount(player) + 1;
	for (int i = 0; i < limit; ++i) {
		if (!b3RecPlayer_StepFrame(player)) {
			break;
		}
	}
	return !b3RecPlayer_HasDiverged(player);
}

int Box3DReplayPlayer::get_frame() const {
	return player != nullptr ? b3RecPlayer_GetFrame(player) : 0;
}

int Box3DReplayPlayer::get_frame_count() const {
	return player != nullptr ? b3RecPlayer_GetFrameCount(player) : 0;
}

bool Box3DReplayPlayer::is_at_end() const {
	return player != nullptr ? b3RecPlayer_IsAtEnd(player) : false;
}

bool Box3DReplayPlayer::is_at_pre_step() const {
	return player != nullptr ? b3RecPlayer_IsAtPreStep(player) : false;
}

bool Box3DReplayPlayer::has_diverged() const {
	return player != nullptr ? b3RecPlayer_HasDiverged(player) : false;
}

int Box3DReplayPlayer::get_diverge_frame() const {
	return player != nullptr ? b3RecPlayer_GetDivergeFrame(player) : -1;
}

Dictionary Box3DReplayPlayer::get_info() const {
	Dictionary d;
	if (player == nullptr) {
		return d;
	}
	const b3RecPlayerInfo info = b3RecPlayer_GetInfo(player);
	d["frameCount"] = info.frameCount;
	d["workerCount"] = info.workerCount;
	d["timeStep"] = (double)info.timeStep;
	d["subStepCount"] = info.subStepCount;
	d["lengthScale"] = (double)info.lengthScale;
	const Vector3 lower = to_gd_pos(info.bounds.lowerBound);
	const Vector3 upper = to_gd_pos(info.bounds.upperBound);
	d["bounds"] = AABB(lower, upper - lower);
	return d;
}

void Box3DReplayPlayer::set_worker_count(int p_count) {
	worker_count = p_count < 1 ? 1 : p_count;
	if (player == nullptr) {
		return;
	}
	b3RecPlayer_SetWorkerCount(player, worker_count);
}

int Box3DReplayPlayer::get_worker_count() const {
	return worker_count;
}

void Box3DReplayPlayer::set_keyframe_policy(int64_t p_budget_bytes, int p_min_interval_frames) {
	if (player == nullptr) {
		return;
	}
	b3RecPlayer_SetKeyframePolicy(player,
			p_budget_bytes > 0 ? (size_t)p_budget_bytes : (size_t)0,
			p_min_interval_frames);
	// Upstream requires a Restart after a policy change, because setting one
	// clears the existing ring (box3d.h:385-387).
	b3RecPlayer_Restart(player);
}

int64_t Box3DReplayPlayer::get_keyframe_budget() const {
	return player != nullptr ? (int64_t)b3RecPlayer_GetKeyframeBudget(player) : 0;
}

int Box3DReplayPlayer::get_keyframe_min_interval() const {
	return player != nullptr ? b3RecPlayer_GetKeyframeMinInterval(player) : 0;
}

int Box3DReplayPlayer::get_keyframe_interval() const {
	return player != nullptr ? b3RecPlayer_GetKeyframeInterval(player) : 0;
}

int64_t Box3DReplayPlayer::get_keyframe_bytes() const {
	return player != nullptr ? (int64_t)b3RecPlayer_GetKeyframeBytes(player) : 0;
}

int Box3DReplayPlayer::get_body_count() const {
	return player != nullptr ? b3RecPlayer_GetBodyCount(player) : 0;
}

bool Box3DReplayPlayer::is_body_valid(int p_index) const {
	if (player == nullptr) {
		return false;
	}
	// A null id comes back both for an out-of-range ordinal and for a hole left
	// by a destroyed body (box3d.h:400-402); b3Body_IsValid tells them apart
	// from a live body without asserting on either.
	return b3Body_IsValid(b3RecPlayer_GetBodyId(player, p_index));
}

Transform3D Box3DReplayPlayer::get_body_transform(int p_index) const {
	if (player == nullptr) {
		return Transform3D();
	}
	const b3BodyId id = b3RecPlayer_GetBodyId(player, p_index);
	if (!b3Body_IsValid(id)) {
		return Transform3D();
	}
	const b3WorldTransform t = b3Body_GetTransform(id);
	return Transform3D(Basis(to_gd(t.q)), to_gd_pos(t.p));
}

void Box3DReplayPlayer::_bind_methods() {
	ClassDB::bind_method(D_METHOD("open", "data", "worker_count"), &Box3DReplayPlayer::open, DEFVAL(1));
	ClassDB::bind_method(D_METHOD("open_file", "path", "worker_count"), &Box3DReplayPlayer::open_file, DEFVAL(1));
	ClassDB::bind_method(D_METHOD("close"), &Box3DReplayPlayer::close);
	ClassDB::bind_method(D_METHOD("is_open"), &Box3DReplayPlayer::is_open);

	ClassDB::bind_method(D_METHOD("step_frame"), &Box3DReplayPlayer::step_frame);
	ClassDB::bind_method(D_METHOD("sub_step_frame"), &Box3DReplayPlayer::sub_step_frame);
	ClassDB::bind_method(D_METHOD("restart"), &Box3DReplayPlayer::restart);
	ClassDB::bind_method(D_METHOD("seek_frame", "frame"), &Box3DReplayPlayer::seek_frame);
	ClassDB::bind_method(D_METHOD("replay_all"), &Box3DReplayPlayer::replay_all);

	ClassDB::bind_method(D_METHOD("get_frame"), &Box3DReplayPlayer::get_frame);
	ClassDB::bind_method(D_METHOD("get_frame_count"), &Box3DReplayPlayer::get_frame_count);
	ClassDB::bind_method(D_METHOD("is_at_end"), &Box3DReplayPlayer::is_at_end);
	ClassDB::bind_method(D_METHOD("is_at_pre_step"), &Box3DReplayPlayer::is_at_pre_step);
	ClassDB::bind_method(D_METHOD("has_diverged"), &Box3DReplayPlayer::has_diverged);
	ClassDB::bind_method(D_METHOD("get_diverge_frame"), &Box3DReplayPlayer::get_diverge_frame);
	ClassDB::bind_method(D_METHOD("get_info"), &Box3DReplayPlayer::get_info);

	ClassDB::bind_method(D_METHOD("set_worker_count", "count"), &Box3DReplayPlayer::set_worker_count);
	ClassDB::bind_method(D_METHOD("get_worker_count"), &Box3DReplayPlayer::get_worker_count);

	ClassDB::bind_method(D_METHOD("set_keyframe_policy", "budget_bytes", "min_interval_frames"),
			&Box3DReplayPlayer::set_keyframe_policy);
	ClassDB::bind_method(D_METHOD("get_keyframe_budget"), &Box3DReplayPlayer::get_keyframe_budget);
	ClassDB::bind_method(D_METHOD("get_keyframe_min_interval"), &Box3DReplayPlayer::get_keyframe_min_interval);
	ClassDB::bind_method(D_METHOD("get_keyframe_interval"), &Box3DReplayPlayer::get_keyframe_interval);
	ClassDB::bind_method(D_METHOD("get_keyframe_bytes"), &Box3DReplayPlayer::get_keyframe_bytes);

	ClassDB::bind_method(D_METHOD("get_body_count"), &Box3DReplayPlayer::get_body_count);
	ClassDB::bind_method(D_METHOD("is_body_valid", "index"), &Box3DReplayPlayer::is_body_valid);
	ClassDB::bind_method(D_METHOD("get_body_transform", "index"), &Box3DReplayPlayer::get_body_transform);
}
