// Written by Claude (claude-opus-5-5), 2026-11-09: see pawn_table.h.
#include "pawn_table.h"

#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/object.hpp>

#include <algorithm>

using namespace godot;

PawnTable::PawnTable() :
		_velocity_name("velocity"),
		_yaw_name("yaw"),
		_team_name("team"),
		_grounded_name("grounded"),
		_detectability_name("detectability") {
}

bool PawnTable::add(Object *pawn, int64_t key) {
	if (pawn == nullptr || _slot_of.count(pawn->get_instance_id()) > 0) {
		return false;
	}
	// The first slot with a larger key: equal keys keep the order they were added in.
	const size_t slot = size_t(std::upper_bound(_keys.begin(), _keys.end(), key) - _keys.begin());
	_keys.insert(_keys.begin() + slot, key);
	_ids.insert(_ids.begin() + slot, pawn->get_instance_id());
	_nodes.insert(_nodes.begin() + slot, nullptr);
	_positions.insert(_positions.begin() + slot, Vector3());
	_velocities.insert(_velocities.begin() + slot, Vector3());
	_yaws.insert(_yaws.begin() + slot, 0.0f);
	_teams.insert(_teams.begin() + slot, 0);
	_grounded.insert(_grounded.begin() + slot, 0);
	_detectability.insert(_detectability.begin() + slot, 1.0f);
	rebuild_slot_map();
	_stale = true;
	return true;
}

void PawnTable::remove(Object *pawn) {
	if (pawn == nullptr) {
		return;
	}
	auto found = _slot_of.find(pawn->get_instance_id());
	if (found == _slot_of.end()) {
		return;
	}
	erase_slot(found->second);
	rebuild_slot_map();
}

int64_t PawnTable::get_count() const {
	return int64_t(_keys.size());
}

bool PawnTable::refresh(int64_t tick) {
	if (!_stale && tick == _refreshed_tick) {
		return false;
	}
	bool dropped = false;
	for (size_t slot = 0; slot < _ids.size();) {
		Object *object = ObjectDB::get_instance(_ids[slot]);
		Node3D *node = Object::cast_to<Node3D>(object);
		if (node == nullptr) {
			erase_slot(slot); // freed without leaving the tree first
			dropped = true;
			continue;
		}
		_nodes[slot] = node;
		_positions[slot] = node->get_global_position();
		_velocities[slot] = node->get(_velocity_name);
		_yaws[slot] = float(double(node->get(_yaw_name)));
		_teams[slot] = int64_t(node->get(_team_name));
		_grounded[slot] = bool(node->get(_grounded_name)) ? 1 : 0;
		_detectability[slot] = float(double(node->get(_detectability_name)));
		++slot;
	}
	if (dropped) {
		rebuild_slot_map();
	} else {
		++_version;
	}
	_refreshed_tick = tick;
	_stale = false;
	return true;
}

int64_t PawnTable::get_refreshed_tick() const {
	return _refreshed_tick;
}

void PawnTable::mark_stale() {
	_stale = true;
}

PackedInt64Array PawnTable::get_keys() const {
	PackedInt64Array out;
	out.resize(int64_t(_keys.size()));
	for (size_t i = 0; i < _keys.size(); ++i) {
		out[int64_t(i)] = _keys[i];
	}
	return out;
}

int64_t PawnTable::get_slot(Object *pawn) const {
	if (pawn == nullptr) {
		return -1;
	}
	auto found = _slot_of.find(pawn->get_instance_id());
	return found == _slot_of.end() ? -1 : int64_t(found->second);
}

Dictionary PawnTable::get_row(int64_t slot) const {
	Dictionary row;
	if (slot < 0 || slot >= int64_t(_keys.size())) {
		return row;
	}
	const size_t i = size_t(slot);
	row["key"] = _keys[i];
	row["team"] = _teams[i];
	row["position"] = _positions[i];
	row["velocity"] = _velocities[i];
	row["yaw"] = _yaws[i];
	row["grounded"] = _grounded[i] != 0;
	row["detectability"] = _detectability[i];
	return row;
}

void PawnTable::rebuild_slot_map() {
	++_version;
	_slot_of.clear();
	for (size_t i = 0; i < _ids.size(); ++i) {
		_slot_of[_ids[i]] = uint32_t(i);
	}
}

// Removes one slot from every array, keeping the rest in key order.
void PawnTable::erase_slot(size_t slot) {
	_keys.erase(_keys.begin() + slot);
	_ids.erase(_ids.begin() + slot);
	_nodes.erase(_nodes.begin() + slot);
	_positions.erase(_positions.begin() + slot);
	_velocities.erase(_velocities.begin() + slot);
	_yaws.erase(_yaws.begin() + slot);
	_teams.erase(_teams.begin() + slot);
	_grounded.erase(_grounded.begin() + slot);
	_detectability.erase(_detectability.begin() + slot);
}

void PawnTable::_bind_methods() {
	ClassDB::bind_method(D_METHOD("add", "pawn", "key"), &PawnTable::add);
	ClassDB::bind_method(D_METHOD("remove", "pawn"), &PawnTable::remove);
	ClassDB::bind_method(D_METHOD("get_count"), &PawnTable::get_count);
	ClassDB::bind_method(D_METHOD("refresh", "tick"), &PawnTable::refresh);
	ClassDB::bind_method(D_METHOD("get_refreshed_tick"), &PawnTable::get_refreshed_tick);
	ClassDB::bind_method(D_METHOD("mark_stale"), &PawnTable::mark_stale);
	ClassDB::bind_method(D_METHOD("get_keys"), &PawnTable::get_keys);
	ClassDB::bind_method(D_METHOD("get_slot", "pawn"), &PawnTable::get_slot);
	ClassDB::bind_method(D_METHOD("get_row", "slot"), &PawnTable::get_row);
}
