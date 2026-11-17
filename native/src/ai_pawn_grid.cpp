// Written by Claude (claude-opus-5-5), 2026-11-09: see ai_pawn_grid.h.
#include "ai_pawn_grid.h"

#include <godot_cpp/classes/collision_object3d.hpp> // Claude 2026-11-17: find_touching
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
	_change_guard.before_change(); // Claude 2026-11-17 (C++ bundle stage 2): no job may be reading the cells while they change
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

// Claude 2026-11-09 (step 2): split into prepare() and find_slots(), which the worker jobs use; the answers are the same.
Array AIPawnGrid::query(const Vector3 &origin, double radius, int64_t own_team, Object *exclude, int64_t max_results, int64_t tick) {
	Array result;
	if (_table.is_null()) {
		return result;
	}
	prepare(tick);
	const int64_t exclude_slot = exclude ? _table->get_slot(exclude) : -1;
	const size_t keep = find_slots(origin, radius, own_team, exclude_slot, size_t(std::max<int64_t>(max_results, 0)), _found);
	result.resize(int64_t(keep));
	for (size_t i = 0; i < keep; ++i) {
		result[int64_t(i)] = _table->node_at(_found[i].second);
	}
	return result;
}

void AIPawnGrid::prepare(int64_t tick) {
	if (_table.is_null()) {
		return;
	}
	_table->refresh(tick); // reads the rows once a tick; does nothing on later calls in the same tick
	if (_built_version != _table->version()) {
		rebuild();
	}
}

size_t AIPawnGrid::find_slots(const Vector3 &origin, double radius, int64_t own_team, int64_t exclude_slot, size_t max_results,
		std::vector<std::pair<double, uint32_t>> &found) const {
	found.clear();
	if (_table.is_null()) {
		return 0;
	}
	const PawnTable *table = _table.ptr();
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
				if (table->team_at(slot) == own_team || int64_t(slot) == exclude_slot) {
					continue;
				}
				const double distance_squared = origin.distance_squared_to(table->position_at(slot));
				if (distance_squared <= radius_squared) {
					found.push_back({ distance_squared, slot });
				}
			}
		}
	}
	// Nearest first; ties by slot, which is entity-id order, so the order is the same on every machine.
	const size_t keep = std::min(found.size(), max_results);
	std::partial_sort(found.begin(), found.begin() + keep, found.end());
	return keep;
}

namespace {
// Claude 2026-11-17: the squared distance from point p to segment a-b.
double distance_squared_to_segment(const Vector3 &p, const Vector3 &a, const Vector3 &b) {
	const Vector3 ab = b - a;
	const double length_squared = ab.length_squared();
	const double t = length_squared > 1e-12 ? std::clamp(double((p - a).dot(ab)) / length_squared, 0.0, 1.0) : 0.0;
	return p.distance_squared_to(a + ab * real_t(t));
}

// How far a pawn may have moved since the table was read this tick: the grid finds pawns by where they were then.
constexpr double MOVED_SINCE_READ = 2.0;
} // namespace

// Claude 2026-11-17 (C++ bundle stage 3): see the header. A sphere touches a capsule when the sphere's centre is within the two radii
// of the capsule's middle segment; that's the whole test, the same one physics makes.
Array AIPawnGrid::find_touching(const PackedVector3Array &centres, double radius, Object *exclude, int64_t tick) {
	Array result;
	if (_table.is_null() || centres.is_empty()) {
		return result;
	}
	prepare(tick);
	const PawnTable *table = _table.ptr();
	// Who's near any centre, by the grid: a box around all the centres, grown by how far a body reaches and may have moved.
	const double reach = radius + double(table->max_body_reach()) + MOVED_SINCE_READ;
	Vector3 low = centres[0];
	Vector3 high = centres[0];
	for (int64_t i = 1; i < centres.size(); ++i) {
		low = low.min(centres[i]);
		high = high.max(centres[i]);
	}
	std::vector<uint32_t> near;
	const int64_t x0 = int64_t(std::floor((low.x - reach) / _cell_size));
	const int64_t x1 = int64_t(std::floor((high.x + reach) / _cell_size));
	const int64_t z0 = int64_t(std::floor((low.z - reach) / _cell_size));
	const int64_t z1 = int64_t(std::floor((high.z + reach) / _cell_size));
	for (int64_t x = x0; x <= x1; ++x) {
		for (int64_t z = z0; z <= z1; ++z) {
			auto cell = _cells.find(cell_key(x, z));
			if (cell != _cells.end()) {
				near.insert(near.end(), cell->second.begin(), cell->second.end());
			}
		}
	}
	std::sort(near.begin(), near.end()); // slot order, the same on every machine
	// Each near pawn's capsule now: its middle segment's two ends, and its radius.
	struct Capsule {
		Object *node;
		Vector3 a, b;
		double radius;
	};
	std::vector<Capsule> capsules;
	capsules.reserve(near.size());
	for (uint32_t slot : near) {
		const PawnTable::Body &body = table->body_at(slot);
		Object *object = table->node_at(slot);
		CollisionObject3D *node = Object::cast_to<CollisionObject3D>(object);
		if (body.radius < 0.0f || node == nullptr || object == exclude || !node->is_inside_tree() || node->get_collision_layer() == 0) {
			continue;
		}
		const Transform3D shape = node->get_global_transform() * body.local;
		const Vector3 up = shape.basis.get_column(1); // the capsule stands along the shape's own Y
		capsules.push_back(Capsule{ object, shape.origin - up * body.half_segment, shape.origin + up * body.half_segment,
				double(body.radius) * double(shape.basis.get_column(0).length()) });
	}
	std::vector<bool> taken(capsules.size(), false);
	for (int64_t c = 0; c < centres.size(); ++c) {
		const Vector3 centre = centres[c];
		for (size_t i = 0; i < capsules.size(); ++i) {
			if (taken[i]) {
				continue;
			}
			const double touch = radius + capsules[i].radius;
			if (distance_squared_to_segment(centre, capsules[i].a, capsules[i].b) <= touch * touch) {
				taken[i] = true;
				result.push_back(capsules[i].node);
			}
		}
	}
	return result;
}

void AIPawnGrid::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_table", "table"), &AIPawnGrid::set_table);
	ClassDB::bind_method(D_METHOD("get_table"), &AIPawnGrid::get_table);
	ClassDB::bind_method(D_METHOD("set_cell_size", "size"), &AIPawnGrid::set_cell_size);
	ClassDB::bind_method(D_METHOD("get_cell_size"), &AIPawnGrid::get_cell_size);
	ClassDB::bind_method(D_METHOD("query", "origin", "radius", "own_team", "exclude", "max_results", "tick"), &AIPawnGrid::query);
	// Claude 2026-11-17 (C++ bundle stage 3)
	ClassDB::bind_method(D_METHOD("find_touching", "centres", "radius", "exclude", "tick"), &AIPawnGrid::find_touching);
}
