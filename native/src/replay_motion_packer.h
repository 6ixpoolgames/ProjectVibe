// Written by Claude (claude-opus-5-5), 2026-11-17 (C++ bundle stage 3, replay spec 3): the replay's motion channel's packing in C++.
// ReplayMotionChannel.gd gathers each pawn's position, yaw, velocity and flags once a tick; this compares them with what was last
// written for that pawn and writes the tick's bytes, in exactly the layout the GDScript version writes (ReplayMotionChannel.gd, version
// 2): count (u16); ids (u32 each); position x, y, z changes (i32 each, whole millimetres); yaws (half); velocities x, y, z (half);
// flags (u8, bit 7 meaning "the position is whole, not a change"). replay_selftest compares the two byte for byte.
//
// It keeps each pawn's last record itself, as the GDScript version keeps _last, so forget() a pawn that leaves and clear() at the end.
#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>

#include <cstdint>
#include <unordered_map>
#include <vector>

namespace godot {

class ReplayMotionPacker : public RefCounted {
	GDCLASS(ReplayMotionPacker, RefCounted)

public:
	// One tick: a pawn whose position, yaw, velocity and flags are all exactly as last written is left out, unless keyframe is on,
	// which writes every pawn with its whole position. yaws are the pawns' own (wrapped to -pi..pi here), as doubles, so a change too
	// small for a 32-bit float still counts, as in GDScript. Returns the tick's bytes; empty with an error if the lists differ in length.
	PackedByteArray pack(const PackedInt64Array &ids, const PackedVector3Array &positions, const PackedFloat64Array &yaws,
			const PackedVector3Array &velocities, const PackedByteArray &flags, bool keyframe);
	void forget(int64_t id);
	void clear();

protected:
	static void _bind_methods();

private:
	struct Last {
		Vector3 position;
		double yaw = 0.0;
		Vector3 velocity;
		uint8_t flags = 0;
		int64_t mm[3] = { 0, 0, 0 };
	};
	std::unordered_map<int64_t, Last> _last;
	std::vector<uint8_t> _bytes; // reused each tick
};

} // namespace godot
