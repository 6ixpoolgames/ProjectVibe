// Written by Claude (claude-opus-5-5), 2026-11-05: writes and reads the entities in a snapshot, as NetworkSession's fast path.
// NetPackets.gd holds the same format in GDScript, and runs where this library isn't available. The two give exactly the same
// bytes and values, which tests/net_codec_selftest checks, so machines using either can play together.
//
// Why this exists: writing and reading took about 9 and 11 microseconds per pawn in GDScript, and about 0.5 here (netcode spec,
// section 14.1). It's plain data: nothing here touches the scene or the game.
#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/string_name.hpp>
#include <godot_cpp/variant/variant.hpp>

#include <cstdint>
#include <vector>

namespace godot {

class NetCodec : public RefCounted {
	GDCLASS(NetCodec, RefCounted)

public:
	NetCodec();

	// The packet format this was built for. NetworkSession doesn't use a library that disagrees with NetPackets.
	int64_t get_protocol_version() const;

	// Eight items per entity, one after another: id, state values, state encodings, sync values, sync encodings,
	// input values, input encodings, custom values. Encodings are names, as in NetPackets.write_list.
	PackedByteArray write_world(const Array &entries);
	// Starts at byte `start`. An Array of [id, state, sync, input, custom] per entity, or null if the packet is broken.
	Variant read_world(const PackedByteArray &bytes, int64_t start, int64_t count);

	// One list at a time, the same as NetPackets.write_list and read_list.
	void begin_write();
	void write_u32(int64_t value);
	void write_list(const Array &values, const Array &encodings);
	PackedByteArray get_written() const;
	void begin_read(const PackedByteArray &bytes);
	int64_t get_available_bytes() const;
	int64_t read_u32(); // 0 if there aren't 4 bytes left: check get_available_bytes first
	Variant read_list(); // an Array, or null if the packet is broken

protected:
	static void _bind_methods();

private:
	void put_u8(uint8_t value);
	void put_u16(uint16_t value);
	void put_u32(uint32_t value);
	void put_float(float value);
	void put_int24(int64_t value);
	void put_vector3(uint8_t tag, const Vector3 &value, double step);
	void put_angle_u16(double value);
	void put_int(int64_t value);
	void write_value(const Variant &value, int encoding);
	void write_plain(const Variant &value);

	int32_t get_int24();
	bool read_value(Variant &out);
	bool read_list_into(Array &out);

	int encoding_id(const Variant &name) const;

	std::vector<uint8_t> m_written;

	PackedByteArray m_read_bytes; // keeps the bytes alive while m_read points into them
	const uint8_t *m_read = nullptr;
	int64_t m_read_size = 0;
	int64_t m_read_at = 0;

	// Godot's interned names, made once here because they can't exist before the engine has started.
	StringName m_missing;
	StringName m_auto;
	StringName m_vector3_mm;
	StringName m_vector3_cm;
	StringName m_vector2_mm;
	StringName m_angle_u16;
	StringName m_angle_byte;
	StringName m_float;
};

} // namespace godot
