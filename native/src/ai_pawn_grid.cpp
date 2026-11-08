// Written by Claude (claude-opus-5-5), 2026-11-09: see ai_pawn_grid.h.
#include "ai_pawn_grid.h"

#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/object.hpp>

#include <algorithm>
#include <cmath>

using namespace godot;

void AIPawnGrid::track(Object *pawn) {
	if (pawn != nullptr) {
		_tracked.insert(pawn->get_instance_id());
		_dirty = true;
	}
}

void AIPawnGrid::untrack(Object *pawn) {
	if (pawn != nullptr) {
		_tracked.erase(pawn->get_instance_id());
		_dirty = true;
	}
}

int64_t AIPawnGrid::tracked_count() const {
	return int64_t(_tracked.size());
}

void AIPawnGrid::set_cell_size(double size) {
	_cell_size = std::max(size, 0.5);
	_dirty = true;
}

double AIPawnGrid::get_cell_size() const {
	return _cell_size;
}

void AIPawnGrid::rebuild(int64_t tick) {
	_entries.clear();
	for (auto &cell : _cells) {
		cell.second.clear(); // keep the vectors' memory for the next tick
	}
	std::vector<uint64_t> gone;
	for (uint64_t id : _tracked) {
		Node3D *node = Object::cast_to<Node3D>(ObjectDB::get_instance(id));
		if (node == nullptr) {
			gone.push_back(id); // freed without leaving the tree first
			continue;
		}
		if (!node->is_inside_tree()) {
			continue;
		}
		const Vector3 position = node->get_global_position();
		const uint32_t index = uint32_t(_entries.size());
		_entries.push_back({ node, position, int64_t(node->get("team")) });
		const int64_t x = int64_t(std::floor(position.x / _cell_size));
		const int64_t z = int64_t(std::floor(position.z / _cell_size));
		_cells[cell_key(x, z)].push_back(index);
	}
	for (uint64_t id : gone) {
		_tracked.erase(id);
	}
	_built_tick = tick;
	_dirty = false;
}

Array AIPawnGrid::query(const Vector3 &origin, double radius, int64_t own_team, Object *exclude, int64_t max_results, int64_t tick) {
	if (_dirty || tick != _built_tick) {
		rebuild(tick);
	}
	_found.clear();
	const double radius_squared = radius * radius;
	const int64_t x0 = int64_t(std::floor((origin.x - radius) / _cell_size));
	const int64_t x1 = int64_t(std::floor((origin.x + radius) / _cell_size));
	const int64_t z0 = int64_t(std::floor((origin.z - radius) / _cell_size));
	const int64_t z1 = int64_t(std::floor((origin.z + radius) / _cell_size));
	for (int64_t x = x0; x <= x1; ++x) {
		for (int64_t z = z0; z <= z1; ++z) {
			auto cell = _cells.find(cell_key(x, z));
			if (cell == _cells.end()) {
				continue;
			}
			for (uint32_t index : cell->second) {
				const Entry &entry = _entries[index];
				if (entry.team == own_team || entry.node == exclude) {
					continue;
				}
				const double distance_squared = origin.distance_squared_to(entry.position);
				if (distance_squared <= radius_squared) {
					_found.push_back({ distance_squared, index });
				}
			}
		}
	}
	// Nearest first; ties by index so the order never depends on hashing.
	const size_t keep = std::min(_found.size(), size_t(std::max<int64_t>(max_results, 0)));
	std::partial_sort(_found.begin(), _found.begin() + keep, _found.end());
	Array result;
	result.resize(int64_t(keep));
	for (size_t i = 0; i < keep; ++i) {
		result[int64_t(i)] = _entries[_found[i].second].node;
	}
	return result;
}

void AIPawnGrid::_bind_methods() {
	ClassDB::bind_method(D_METHOD("track", "pawn"), &AIPawnGrid::track);
	ClassDB::bind_method(D_METHOD("untrack", "pawn"), &AIPawnGrid::untrack);
	ClassDB::bind_method(D_METHOD("tracked_count"), &AIPawnGrid::tracked_count);
	ClassDB::bind_method(D_METHOD("set_cell_size", "size"), &AIPawnGrid::set_cell_size);
	ClassDB::bind_method(D_METHOD("get_cell_size"), &AIPawnGrid::get_cell_size);
	ClassDB::bind_method(D_METHOD("query", "origin", "radius", "own_team", "exclude", "max_results", "tick"), &AIPawnGrid::query);
}
