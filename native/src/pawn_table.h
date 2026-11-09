// Written by Claude (claude-opus-5-5), 2026-11-09: the shared table of plain pawn data on a server (scaling spec section 3, tier 1
// step 1). One array per field, one slot per pawn, so slot 7 in every array is the same pawn, and slots in a fixed order: by each
// pawn's key, its entity id, which is the same on every machine.
//
// Pawns join when they enter the tree and leave when they leave it (Pawn.gd). The rows are read from the pawns' nodes once a tick,
// at the first refresh(tick) of that tick, so everything that reads the table during a tick sees the same frozen copy. Tier 1's
// worker jobs will read it instead of nodes; for now AIPawnGrid builds itself from it.
//
// Claude 2026-11-09 (scaling spec step 2, 3.2): columns. Four are always there: the key, the node, the position and the team, which
// the table's order and the grid need. Every other field is a column that's off, holding nothing and costing nothing, until it's
// switched on:
//   - automatically, by a system that reads it: require_column("detectability") from the sensing job, say;
//   - or by hand: enable_column(), from a GameMode module or a game's own code. disable_column() undoes enable_column(), but a column a
//     system requires stays on, with a warning, so a game can't switch off what a system needs by mistake.
// The built-in optional columns are velocity, yaw, grounded and detectability. A game adds its own with add_column(name, type,
// property, default): a number, a whole number or a Vector3, read from a property of the pawn. Columns can be switched on at any time;
// the next refresh fills them.
//
// Claude 2026-11-09 (step 2): the table never changes under a job. Before anything changes it (a pawn joining or leaving, a refresh
// that reads, a column switched), it calls the change guard, which the job scheduler sets to finish every job still reading it.
//
// Plain data only: nothing here changes a pawn.
#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/string_name.hpp>
#include <godot_cpp/variant/variant.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <cstdint>
#include <functional>
#include <unordered_map>
#include <vector>

namespace godot {

class Node3D;

class PawnTable : public RefCounted {
	GDCLASS(PawnTable, RefCounted)

public:
	PawnTable();

	// Adds a pawn with its key (its entity id, or another number that's the same on every machine). Its slot is kept in key order;
	// equal keys keep the order they were added in. False if it's already here or null.
	bool add(Object *pawn, int64_t key);
	// Removes a pawn. Nothing happens if it isn't here.
	void remove(Object *pawn);
	int64_t get_count() const;

	// Reads every pawn's row from its node, once per tick: a second call with the same tick does nothing. Pawns freed without
	// leaving are dropped. Returns true if it read.
	bool refresh(int64_t tick);
	int64_t get_refreshed_tick() const;
	// Makes the next refresh read again, whatever the tick (pawns added or moved by code between ticks are seen anyway).
	void mark_stale();

	// Claude 2026-11-09 (step 2): columns, see the top of this file. Names are the built-ins (velocity, yaw, grounded, detectability)
	// or ones added with add_column. Each returns false, with an error, for a name it doesn't know.
	bool require_column(const StringName &name); // automatic: a system that reads the column
	bool enable_column(const StringName &name); // by hand
	bool disable_column(const StringName &name); // undoes enable_column; a required column stays on, with a warning
	// A game's own column: type is TYPE_FLOAT, TYPE_INT, TYPE_BOOL (kept as 0 or 1) or TYPE_VECTOR3, read from property on each pawn,
	// or default_value where a pawn doesn't have it. Switched on by hand. False if the name is taken or the type isn't one of those.
	bool add_column(const StringName &name, int64_t type, const StringName &property, const Variant &default_value);
	bool is_column_on(const StringName &name) const;
	bool has_column(const StringName &name) const;
	PackedStringArray get_column_names() const; // every column there is, on or off, core ones first
	// One column's values in slot order: a PackedFloat64Array, PackedInt64Array or PackedVector3Array. Empty if it's off.
	Variant get_column(const StringName &name) const;

	// For GDScript: tests and readouts.
	PackedInt64Array get_keys() const;
	int64_t get_slot(Object *pawn) const; // -1 if it isn't here
	Dictionary get_row(int64_t slot) const; // key, position, team, and every column that's on; empty if out of range

	// For C++ readers (AIPawnGrid, the worker jobs). Valid until the next add, remove or refresh.
	int64_t slot_count() const { return int64_t(_keys.size()); }
	// Goes up whenever slots or rows change (an add, a remove, a refresh that read), so a reader knows to rebuild what it made.
	int64_t version() const { return _version; }
	Object *node_at(int64_t slot) const { return _nodes[size_t(slot)]; }
	uint64_t id_at(int64_t slot) const { return _ids[size_t(slot)]; } // the pawn's instance id
	int64_t key_at(int64_t slot) const { return _keys[size_t(slot)]; }
	const Vector3 &position_at(int64_t slot) const { return _positions[size_t(slot)]; }
	int64_t team_at(int64_t slot) const { return _teams[size_t(slot)]; }
	// A column's index, for the accessors below, or -1. Indexes don't change once a column exists.
	int column_index(const StringName &name) const;
	// A number column's values (TYPE_FLOAT), in slot order; empty while it's off.
	const std::vector<double> &numbers(int column) const { return _columns[size_t(column)].numbers; }
	const std::vector<int64_t> &whole_numbers(int column) const { return _columns[size_t(column)].whole_numbers; }
	const std::vector<Vector3> &vectors(int column) const { return _columns[size_t(column)].vectors; }
	// Called before anything changes the table. JobScheduler sets it; empty means nothing to wait for.
	void set_change_guard(std::function<void()> guard) { _change_guard = std::move(guard); }

protected:
	static void _bind_methods();

private:
	struct Column {
		StringName name;
		StringName property;
		Variant::Type type = Variant::FLOAT;
		Variant default_value;
		bool required = false; // switched on by a system that reads it
		bool enabled = false; // switched on by hand
		std::vector<double> numbers; // TYPE_FLOAT
		std::vector<int64_t> whole_numbers; // TYPE_INT and TYPE_BOOL
		std::vector<Vector3> vectors; // TYPE_VECTOR3
		bool on() const { return required || enabled; }
	};

	void rebuild_slot_map();
	void erase_slot(size_t slot);
	void before_change();
	void resize_column(Column &column);
	void read_column(Column &column, size_t slot, Object *node);
	void switched(Column &column, bool was_on);
	Column *find_column(const StringName &name, const char *asked_by);

	// One entry per slot, in key order: the core columns, always there.
	std::vector<int64_t> _keys;
	std::vector<uint64_t> _ids; // instance ids, to find the node safely each refresh
	std::vector<Object *> _nodes; // set by refresh; null until then
	std::vector<Vector3> _positions; // global position
	std::vector<int64_t> _teams;
	// Every other column, built-in or added, on or off. Found by name with a short search: there are only a handful.
	std::vector<Column> _columns;

	std::unordered_map<uint64_t, uint32_t> _slot_of; // instance id -> slot
	int64_t _refreshed_tick = -1;
	bool _stale = true;
	int64_t _version = 0;
	std::function<void()> _change_guard;

	// Godot's interned names, made once here because they can't exist before the engine has started.
	StringName _team_name;
};

} // namespace godot
