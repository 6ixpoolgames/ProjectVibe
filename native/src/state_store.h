// Written by Claude (claude-opus-5-5), 2026-11-19. History: native/CHANGELOG.md.
// StateStore: the central record of every gameplay entity's state, tick by tick (docs/state_store/STATE_STORE_SPEC.md). The tick
// driver commits it once at the end of every tick: one pass reads every bound entity's gathered columns from its nodes, rounds each
// to its encoding (writing back what rounding changed), and copies it into that tick's frame. Pushed columns take the value their
// holder last pushed. Rollback, snapshots and corrections read and write the frames; a rollback loads a row back into the nodes.
//
// Layouts: entities with the same columns (names, encodings, gathered or pushed) share a table (an archetype). A slot never moves; a
// freed slot is reused only once no frame in the history can still hold its old occupant, with a new generation, so a stale handle
// never matches. A handle is (generation << 32) | (layout << 20) | slot.
// Frames: a rotating buffer of `depth` frames (tick T is frame T mod depth), allocated as slots are added, never freed while the store
// lives. Each row remembers the tick and generation it holds, so a row is only valid for the tick and entity that wrote it.
//
// Twin: assets/scripts/state_store/StateStoreGD.gd does exactly the same in GDScript; a change goes in both, and
// state_store/tests/state_store_selftest compares them. Rounding is StateEncoding.quantize's, value for value.
// REFACTOR: kept twice, here and in StateStoreGD.gd (reusable, extensible); see the row in native/CHANGELOG.md.
#pragma once

#include "state_encoding.h"

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/node_path.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/string_name.hpp>
#include <godot_cpp/variant/variant.hpp>

#include <cstdint>
#include <deque>
#include <vector>

namespace godot {

class StateStore : public RefCounted {
	GDCLASS(StateStore, RefCounted)

public:
	StateStore();

	// Forgets every layout and entity. The depth stays.
	void clear();
	// Frames kept. Only while the store holds no entity; false otherwise.
	bool set_depth(int64_t depth);
	int64_t get_depth() const;

	// A layout from its columns: names, encoding names and, optionally, a 1 for each pushed column. The same columns give the same
	// layout number. An "auto" column takes each entity's encoding from its binding. -1, with an error, for an unknown encoding or a
	// size mismatch.
	int64_t define_layout(const PackedStringArray &names, const Array &encodings, const PackedByteArray &pushed);
	int64_t get_layout_count() const;
	PackedStringArray get_layout_columns(int64_t layout) const;

	// A new entity in a layout, owned by owner (asked to gather when the store can't; may be null). Returns its handle, or -1.
	int64_t add_entity(int64_t layout, Object *owner);
	// Frees an entity: it stops committing at once, its rows stay readable until overwritten.
	void remove_entity(int64_t handle);
	bool is_alive(int64_t handle) const;
	// An inactive entity isn't committed (a client's entity drawn from the server, a paused pawn). Rows already written stay.
	void set_active(int64_t handle, bool active);
	bool is_active(int64_t handle) const;
	// How many ticks back this entity's rows count, at most the store's depth.
	void set_entity_depth(int64_t handle, int64_t depth);
	Object *get_owner(int64_t handle) const;

	// The compiled accessors for an entity's columns: one node, one property path and one encoding per column, in column order. An
	// encoding must be settled (never "auto") and match the layout's unless the layout's is "auto". A pushed column may have a node
	// too (or null): its value is read from it now, written back to it by load_row, and checked by verify_nodes, but never read by a
	// commit. round_values: round to each encoding and write back what changed. False, binding nothing, otherwise.
	bool bind(int64_t handle, const Array &nodes, const Array &properties, const Array &encodings, bool round_values);
	void unbind(int64_t handle);
	bool is_bound(int64_t handle) const;

	// Sets a pushed column's value; every commit from now on records it, until the next push.
	void push(int64_t handle, int64_t column, const Variant &value);
	// On: a commit copies this entity's previous row forward, reading no node, unless it was marked changed since the last commit
	// (an entity that only changes when it runs, such as a pawn on a load step). Pushed columns take their pushed values either way.
	void set_carry_forward(int64_t handle, bool on);
	// Something changed this entity since the last commit, so the next one reads its nodes, all of them: values written through
	// for it before this call are dropped.
	void mark_changed(int64_t handle);
	// Writes one column, by name, for many entities now: into each one's node (rounded first, as the commit rounds) and into the row
	// the commit for that tick records, which then skips reading that node. For a batch that moves many entities at once (the crowd
	// mover). Whatever writes the same property after this, in the same tick, must write through as well or call mark_changed, or the
	// row misses it.
	// Returns how many it wrote; an entity that isn't bound, or whose layout lacks the column, is skipped.
	int64_t write_through(const PackedInt64Array &handles, const StringName &column, const Array &values, int64_t tick);

	// The end of a tick: every active entity's row for this tick. Returns the handles the store couldn't gather (unbound, or a node
	// gone, which unbinds it); their owners write them with write_row.
	PackedInt64Array commit(int64_t tick);
	// The same for some entities only (a rollback's re-run rewriting past frames).
	PackedInt64Array commit_entities(int64_t tick, const PackedInt64Array &handles);
	// An owner's own gather: the whole row for that tick. False for a dead handle or a size mismatch.
	bool write_row(int64_t handle, int64_t tick, const Array &values);

	bool has_row(int64_t handle, int64_t tick) const;
	// A copy of the row (containers copied too), or empty if the history doesn't hold it.
	Array get_row(int64_t handle, int64_t tick) const;
	Variant get_value(int64_t handle, int64_t column, int64_t tick) const;
	// Overwrites one value in a held row (a correction from the server). False if the row isn't held.
	bool set_value(int64_t handle, int64_t column, int64_t tick, const Variant &value);
	// Writes a held row back into a bound entity's nodes (MISSING values skipped) and its pushed values. False if not bound or not held.
	bool load_row(int64_t handle, int64_t tick);
	// The newest tick this entity has a row for; -1 for none.
	int64_t newest_tick(int64_t handle) const;

	// One column of a layout at a tick: {"handles": PackedInt64Array, "values": Array}, for every row held for that tick.
	Dictionary get_column(int64_t layout, int64_t column, int64_t tick) const;
	// One Vector3 column, by name, for each of these entities at a tick, in their order: one call for a whole crowd instead of one
	// read a node each. A NaN x where the row isn't held, the entity's layout has no such column, or the value isn't a Vector3.
	PackedVector3Array get_vector3s(const PackedInt64Array &handles, const StringName &column, int64_t tick) const;
	// The move check's first pass (MoveSanityCheck): every entity, in a layout with Vector3 "position" and "velocity" columns, whose
	// move from tick - 1 to tick is longer than max(|velocity then|, |velocity now|) * dt * allowance + slack. Returns
	// {"handles": PackedInt64Array, "moved": PackedFloat32Array, "speeds": PackedFloat32Array, "checked": int}: the long moves, their
	// lengths and the speeds they were held to, and how many moves were compared (entities with both rows).
	Dictionary find_long_moves(int64_t tick, double dt, double allowance, double slack) const;
	// A checksum of every row held for that tick, in layout and slot order. The twin gives the same number.
	int64_t frame_checksum(int64_t tick) const;
	// The determinism tripwire: handles of bound, active entities whose nodes no longer hold (once rounded) what their row for that
	// tick says. Empty when nothing wrote around the store.
	PackedInt64Array verify_nodes(int64_t tick);

	// StateEncoding.quantize, the same rounding the commit does.
	Variant quantize(const Variant &value, const StringName &encoding) const;
	// {layouts, entities, active, bound, cells_per_frame, depth, commit_usec, rows_read, rows_carried} (the last three: the last commit).
	Dictionary get_stats() const;

protected:
	static void _bind_methods();

private:
	struct Accessor {
		uint64_t node_id = 0; // 0: none (a pushed column)
		NodePath path; // used when the property has parts (":rotation:y")
		StringName name; // used when it's a plain name, which is faster to read
		bool indexed = false;
		int encoding = state_encoding::ENC_RAW;
	};
	struct Entity {
		uint32_t generation = 0; // 0: the slot never held anything
		bool alive = false;
		bool active = true;
		bool bound = false;
		bool round_values = true;
		bool carry_forward = false;
		bool changed = true; // a carry-forward entity is read at the next commit
		int64_t freed_tick = -1;
		uint64_t owner_id = 0;
		int64_t depth = 0;
		int64_t newest = -1;
		std::vector<Accessor> accessors;
		std::vector<Variant> pushed;
		// Values written through for the commit of written_tick, one per column, and which columns hold one.
		int64_t written_tick = -1;
		std::vector<Variant> written;
		std::vector<uint8_t> written_mask;
	};
	struct Layout {
		String signature;
		PackedStringArray names;
		std::vector<int> encodings;
		std::vector<uint8_t> pushed;
		int64_t width = 0;
		int64_t gathered = 0; // columns read from nodes; 0: only pushed ones, so nothing to bind
		std::vector<Entity> slots;
		std::deque<int64_t> free_slots; // in the order they were freed
		// REFACTOR: cells are Variants so any value fits; worker jobs want typed lanes they can read without the engine (changelog row).
		std::vector<Variant> cells; // slot-major: ((slot * depth) + frame) * width + column
		std::vector<int64_t> row_tick; // (slot * depth) + frame; -1 empty
		std::vector<uint32_t> row_generation;
	};

	Layout *layout_of(int64_t handle, int64_t &slot) const;
	Entity *entity_of(int64_t handle) const;
	int64_t frame_of(int64_t tick) const;
	bool row_held(const Layout &layout, int64_t slot, uint32_t generation, int64_t depth, int64_t tick) const;
	bool commit_one(Layout &layout, int64_t slot, int64_t tick, bool may_carry);
	int encoding_id(const StringName &name) const;
	Variant quantize_by_id(const Variant &value, int encoding) const;
	static Variant copy_value(const Variant &value);

	int64_t m_depth = 64;
	int64_t m_now = -1; // the newest tick committed: freed slots wait until it has moved past the history
	int64_t m_commit_usec = 0;
	int64_t m_rows_read = 0;
	int64_t m_rows_carried = 0;
	std::vector<Layout> m_layouts;
	std::vector<Object *> m_nodes; // scratch, one per column while gathering

	state_encoding::EncodingNames m_encoding_names;
	StringName m_missing;
	Variant m_step_mm3;
	Variant m_step_mm2;
	Variant m_step_cm3;
};

} // namespace godot
