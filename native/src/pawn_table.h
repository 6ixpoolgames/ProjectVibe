// Written by Claude (claude-opus-5-5), 2026-11-09: the shared table of plain pawn data on a server (scaling spec section 3, tier 1
// step 1). One array per field, one slot per pawn, so slot 7 in every array is the same pawn, and slots in a fixed order: by each
// pawn's key, its entity id, which is the same on every machine.
//
// Pawns join when they enter the tree and leave when they leave it (Pawn.gd). The rows are read from the pawns' nodes once a tick,
// at the first refresh(tick) of that tick, so everything that reads the table during a tick sees the same frozen copy. Tier 1's
// worker jobs will read it instead of nodes; for now AIPawnGrid builds itself from it.
//
// Plain data only: nothing here changes a pawn.
#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/string_name.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <cstdint>
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

	// For GDScript: tests and readouts.
	PackedInt64Array get_keys() const;
	int64_t get_slot(Object *pawn) const; // -1 if it isn't here
	Dictionary get_row(int64_t slot) const; // key, team, position, velocity, yaw, grounded, detectability; empty if out of range

	// For C++ readers (AIPawnGrid, later the worker jobs). Valid until the next add, remove or refresh.
	int64_t slot_count() const { return int64_t(_keys.size()); }
	// Goes up whenever slots or rows change (an add, a remove, a refresh that read), so a reader knows to rebuild what it made.
	int64_t version() const { return _version; }
	Object *node_at(int64_t slot) const { return _nodes[size_t(slot)]; }
	const Vector3 &position_at(int64_t slot) const { return _positions[size_t(slot)]; }
	int64_t team_at(int64_t slot) const { return _teams[size_t(slot)]; }

protected:
	static void _bind_methods();

private:
	void rebuild_slot_map();
	void erase_slot(size_t slot);

	// One entry per slot, in key order.
	std::vector<int64_t> _keys;
	std::vector<uint64_t> _ids; // instance ids, to find the node safely each refresh
	std::vector<Object *> _nodes; // set by refresh; null until then
	std::vector<Vector3> _positions; // global position
	std::vector<Vector3> _velocities;
	std::vector<float> _yaws;
	std::vector<int64_t> _teams;
	std::vector<uint8_t> _grounded;
	std::vector<float> _detectability;

	std::unordered_map<uint64_t, uint32_t> _slot_of; // instance id -> slot
	int64_t _refreshed_tick = -1;
	bool _stale = true;
	int64_t _version = 0;

	// Godot's interned names, made once here because they can't exist before the engine has started.
	StringName _velocity_name;
	StringName _yaw_name;
	StringName _team_name;
	StringName _grounded_name;
	StringName _detectability_name;
};

} // namespace godot
