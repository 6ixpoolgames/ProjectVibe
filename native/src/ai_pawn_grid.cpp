// Written by Claude (claude-opus-5-5), 2026-11-09: see ai_pawn_grid.h.
#include "ai_pawn_grid.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/object.hpp>

#include <algorithm>
#include <cmath>

using namespace godot;

void AIPawnGrid::set_table(const Ref<PawnTable> &table) {
	_table = table;
	_built_version = -1;
}

Ref<PawnTable> AIPawnGrid::get_table() const {
	return _table;
}

void AIPawnGrid::set_cell_size(double size) {
	_cell_size = std::max(size, 0.5);
	_built_version = -1;
}

double AIPawnGrid::get_cell_size() const {
	return _cell_size;
}

// Claude 2026-11-09: from the table's rows, in slot order.
void AIPawnGrid::rebuild() {
	for (auto &cell : _cells) {
		cell.second.clear(); // keep the vectors' memory for the next tick
	}
	const int64_t count = _table->slot_count();
	for (int64_t slot = 0; slot < count; ++slot) {
		const Vector3 &position = _table->position_at(slot);
		const int64_t x = int64_t(std::floor(position.x / _cell_size));
		const int64_t z = int64_t(std::floor(position.z / _cell_size));
		_cells[cell_key(x, z)].push_back(uint32_t(slot));
	}
	_built_version = _table->version();
}

Array AIPawnGrid::query(const Vector3 &origin, double radius, int64_t own_team, Object *exclude, int64_t max_results, int64_t tick) {
	Array result;
	if (_table.is_null()) {
		return result;
	}
	_table->refresh(tick); // reads the rows once a tick; does nothing on later queries of the same tick
	if (_built_version != _table->version()) {
		rebuild();
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
			for (uint32_t slot : cell->second) {
				if (_table->team_at(slot) == own_team || _table->node_at(slot) == exclude) {
					continue;
				}
				const double distance_squared = origin.distance_squared_to(_table->position_at(slot));
				if (distance_squared <= radius_squared) {
					_found.push_back({ distance_squared, slot });
				}
			}
		}
	}
	// Nearest first; ties by slot, which is entity-id order, so the order is the same on every machine.
	const size_t keep = std::min(_found.size(), size_t(std::max<int64_t>(max_results, 0)));
	std::partial_sort(_found.begin(), _found.begin() + keep, _found.end());
	result.resize(int64_t(keep));
	for (size_t i = 0; i < keep; ++i) {
		result[int64_t(i)] = _table->node_at(_found[i].second);
	}
	return result;
}

void AIPawnGrid::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_table", "table"), &AIPawnGrid::set_table);
	ClassDB::bind_method(D_METHOD("get_table"), &AIPawnGrid::get_table);
	ClassDB::bind_method(D_METHOD("set_cell_size", "size"), &AIPawnGrid::set_cell_size);
	ClassDB::bind_method(D_METHOD("get_cell_size"), &AIPawnGrid::get_cell_size);
	ClassDB::bind_method(D_METHOD("query", "origin", "radius", "own_team", "exclude", "max_results", "tick"), &AIPawnGrid::query);
}
