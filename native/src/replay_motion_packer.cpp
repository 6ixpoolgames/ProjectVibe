// Written by Claude (claude-opus-5-5), 2026-11-17 (C++ bundle stage 3): see replay_motion_packer.h.
#include "replay_motion_packer.h"

#include "state_encoding.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/math.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <cmath>

using namespace godot;

namespace {
// The flag bit that says a record's position is whole, not a change (ReplayMotionChannel._WHOLE_POSITION).
constexpr uint8_t WHOLE_POSITION = 128;

// Little-endian, as StreamPeerBuffer writes by default.
void put_u16(std::vector<uint8_t> &out, uint16_t value) {
	out.push_back(uint8_t(value));
	out.push_back(uint8_t(value >> 8));
}

void put_u32(std::vector<uint8_t> &out, uint32_t value) {
	for (int shift = 0; shift < 32; shift += 8) {
		out.push_back(uint8_t(value >> shift));
	}
}

// StreamPeerBuffer.put_half: the float made into 16 bits by the engine's own rounding.
void put_half(std::vector<uint8_t> &out, double value) {
	put_u16(out, Math::make_half_float(float(value)));
}

// GDScript's roundi: to the nearest whole number, halves away from zero.
int64_t whole_mm(real_t metres) {
	return int64_t(std::round(double(metres) * 1000.0));
}
} // namespace

PackedByteArray ReplayMotionPacker::pack(const PackedInt64Array &ids, const PackedVector3Array &positions, const PackedFloat64Array &yaws,
		const PackedVector3Array &velocities, const PackedByteArray &flags, bool keyframe) {
	PackedByteArray result;
	const int64_t given = ids.size();
	if (positions.size() != given || yaws.size() != given || velocities.size() != given || flags.size() != given) {
		UtilityFunctions::push_error("ReplayMotionPacker.pack: the lists must all have one entry per pawn.");
		return result;
	}
	// Which pawns are written, and their position changes, before any byte: the count comes first.
	std::vector<int64_t> written;
	// Four numbers per written pawn: its x, y and z changes (or whole position), then -1 if the position is whole, else 0.
	std::vector<int64_t> changes;
	written.reserve(size_t(given));
	changes.reserve(size_t(given) * 3);
	for (int64_t i = 0; i < given; ++i) {
		const int64_t id = ids[i];
		const Vector3 at = positions[i];
		const double yaw = yaws[i];
		const Vector3 velocity = velocities[i];
		const uint8_t pawn_flags = flags[i];
		auto found = _last.find(id);
		if (!keyframe && found != _last.end() && found->second.position == at && found->second.yaw == yaw &&
				found->second.velocity == velocity && found->second.flags == pawn_flags) {
			continue; // nothing changed at all
		}
		const int64_t mm[3] = { whole_mm(at.x), whole_mm(at.y), whole_mm(at.z) };
		const bool whole = keyframe || found == _last.end();
		for (int axis = 0; axis < 3; ++axis) {
			changes.push_back(whole ? mm[axis] : mm[axis] - found->second.mm[axis]);
		}
		Last &last = _last[id];
		last.position = at;
		last.yaw = yaw;
		last.velocity = velocity;
		last.flags = pawn_flags;
		last.mm[0] = mm[0];
		last.mm[1] = mm[1];
		last.mm[2] = mm[2];
		written.push_back(i);
		changes.push_back(whole ? -1 : 0);
	}
	// Then the bytes, a column at a time (see the header).
	const size_t count = written.size();
	_bytes.clear();
	_bytes.reserve(2 + count * 25);
	put_u16(_bytes, uint16_t(count));
	for (int64_t i : written) {
		put_u32(_bytes, uint32_t(ids[i]));
	}
	for (int axis = 0; axis < 3; ++axis) {
		for (size_t w = 0; w < count; ++w) {
			put_u32(_bytes, uint32_t(int32_t(changes[w * 4 + size_t(axis)])));
		}
	}
	for (int64_t i : written) {
		// Wrapped, so a pawn that has turned many times keeps its precision: GDScript's wrapf, through the engine.
		put_half(_bytes, UtilityFunctions::wrapf(yaws[i], -state_encoding::PI_VALUE, state_encoding::PI_VALUE));
	}
	for (int axis = 0; axis < 3; ++axis) {
		for (int64_t i : written) {
			put_half(_bytes, velocities[i][axis]);
		}
	}
	for (size_t w = 0; w < count; ++w) {
		const int64_t i = written[w];
		_bytes.push_back(uint8_t(flags[i] | (changes[w * 4 + 3] < 0 ? WHOLE_POSITION : 0)));
	}
	result.resize(int64_t(_bytes.size()));
	std::copy(_bytes.begin(), _bytes.end(), result.ptrw());
	return result;
}

void ReplayMotionPacker::forget(int64_t id) {
	_last.erase(id);
}

void ReplayMotionPacker::clear() {
	_last.clear();
}

void ReplayMotionPacker::_bind_methods() {
	ClassDB::bind_method(D_METHOD("pack", "ids", "positions", "yaws", "velocities", "flags", "keyframe"), &ReplayMotionPacker::pack);
	ClassDB::bind_method(D_METHOD("forget", "id"), &ReplayMotionPacker::forget);
	ClassDB::bind_method(D_METHOD("clear"), &ReplayMotionPacker::clear);
}
