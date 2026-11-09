// Written by Claude (claude-opus-5-5), 2026-11-09: the fast path of TickStateComponent's recording, the biggest cost per pawn per
// tick in pawn_stress (pawn spec 12.1). Every tick, for each listed property, it reads the value, rounds it to its encoding, writes
// it back if rounding changed it, and copies it into a history slot. TickStateComponent.gd does the same in GDScript, which is used
// where this library isn't available and for everything unusual: matching entries to nodes, picking encodings by type, and warnings.
// This class only runs the steady state, once every entry has a live node and a settled encoding.
//
// Rounding calls the engine's own snapped, snappedf and wrapf, the functions GDScript's StateEncoding.quantize calls, so both give
// exactly the same values, and machines using either can play together. tests/tick_state_selftest compares them.
#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/node_path.hpp>
#include <godot_cpp/variant/string_name.hpp>
#include <godot_cpp/variant/variant.hpp>

#include <cstdint>
#include <vector>

namespace godot {

class TickStateRecorder : public RefCounted {
	GDCLASS(TickStateRecorder, RefCounted)

public:
	TickStateRecorder();

	// Forgets every entry.
	void clear();
	// Adds an entry: the node, the property as a NodePath (":rotation:y" style parts allowed) and a settled encoding name
	// (never "auto"). Returns false, adding nothing, for an unknown encoding or a null node.
	bool add(Object *node, const NodePath &property, const StringName &encoding);
	int64_t get_count() const;

	// One tick: reads every entry, rounds it when round_values is on, writes back the ones rounding changed, and when store is on,
	// puts a copy of each into values (resized to the entry count, reusing it, so a full history allocates nothing). Arrays,
	// Dictionaries and packed arrays are copied deeply, the same as StateEncoding.copy_value. Returns false without reading
	// anything if any entry's node is gone, so the caller can match entries again.
	bool capture(Array values, bool round_values, bool store);

	// The rounding alone, for the comparison test: the value rounded to this encoding, as StateEncoding.quantize does.
	Variant quantize(const Variant &value, const StringName &encoding) const;

protected:
	static void _bind_methods();

private:
	enum Encoding {
		ENC_UNKNOWN = -1,
		ENC_RAW = 0,
		ENC_VECTOR3_MM,
		ENC_VECTOR2_MM,
		ENC_VECTOR3_CM,
		ENC_ANGLE_U16,
		ENC_ANGLE_BYTE,
		ENC_FLOAT,
	};

	struct Entry {
		uint64_t node_id = 0;
		NodePath path; // used when the property has parts (":rotation:y")
		StringName name; // used when it's a plain property name, which is faster to read
		bool indexed = false;
		int encoding = ENC_RAW;
	};

	int encoding_id(const StringName &name) const;
	Variant quantize_by_id(const Variant &value, int encoding) const;

	std::vector<Entry> m_entries;
	std::vector<Object *> m_nodes; // looked up at the start of each capture

	// Godot's interned names, made once here because they can't exist before the engine has started.
	StringName m_raw;
	StringName m_vector3_mm;
	StringName m_vector2_mm;
	StringName m_vector3_cm;
	StringName m_angle_u16;
	StringName m_angle_byte;
	StringName m_float;
	// The snapping steps, built the way StateEncoding builds them: Vector3(MM, MM, MM) stores 32-bit floats.
	Variant m_step_mm3;
	Variant m_step_mm2;
	Variant m_step_cm3;
};

} // namespace godot
