// Written by Claude (claude-opus-5-5), 2026-11-09: see pawn_table.h.
#include "pawn_table.h"

#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/object.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>

using namespace godot;

PawnTable::PawnTable() :
		_team_name("team") {
	// Claude 2026-11-09 (step 2): the built-in optional columns, off until something switches them on. Their defaults are what a
	// pawn without the property would mean: standing still, facing -Z, in the air, fully visible.
	auto built_in = [this](const char *name, Variant::Type type, const Variant &default_value) {
		Column column;
		column.name = StringName(name);
		column.property = column.name;
		column.type = type;
		column.default_value = default_value;
		_columns.push_back(column);
	};
	built_in("velocity", Variant::VECTOR3, Vector3());
	built_in("yaw", Variant::FLOAT, 0.0);
	built_in("grounded", Variant::BOOL, false);
	built_in("detectability", Variant::FLOAT, 1.0);
}

bool PawnTable::add(Object *pawn, int64_t key) {
	if (pawn == nullptr || _slot_of.count(pawn->get_instance_id()) > 0) {
		return false;
	}
	before_change(); // Claude 2026-11-09 (step 2): no job may be reading while the arrays move
	// The first slot with a larger key: equal keys keep the order they were added in.
	const size_t slot = size_t(std::upper_bound(_keys.begin(), _keys.end(), key) - _keys.begin());
	_keys.insert(_keys.begin() + slot, key);
	_ids.insert(_ids.begin() + slot, pawn->get_instance_id());
	_nodes.insert(_nodes.begin() + slot, nullptr);
	_positions.insert(_positions.begin() + slot, Vector3());
	_teams.insert(_teams.begin() + slot, 0);
	// Claude 2026-11-09 (step 2): every column that's on gets a place too, with its default until the next refresh reads the pawn.
	for (Column &column : _columns) {
		if (!column.on()) {
			continue;
		}
		if (column.type == Variant::FLOAT) {
			column.numbers.insert(column.numbers.begin() + slot, double(column.default_value));
		} else if (column.type == Variant::VECTOR3) {
			column.vectors.insert(column.vectors.begin() + slot, Vector3(column.default_value));
		} else {
			column.whole_numbers.insert(column.whole_numbers.begin() + slot, column.type == Variant::BOOL ? (bool(column.default_value) ? 1 : 0) : int64_t(column.default_value));
		}
	}
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
	before_change();
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
	before_change();
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
		_teams[slot] = int64_t(node->get(_team_name));
		for (Column &column : _columns) {
			if (column.on()) {
				read_column(column, slot, node);
			}
		}
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

// --- Columns (Claude 2026-11-09, step 2) ---

bool PawnTable::require_column(const StringName &name) {
	Column *column = find_column(name, "require_column");
	if (column == nullptr) {
		return false;
	}
	const bool was_on = column->on();
	column->required = true;
	switched(*column, was_on);
	return true;
}

bool PawnTable::enable_column(const StringName &name) {
	Column *column = find_column(name, "enable_column");
	if (column == nullptr) {
		return false;
	}
	const bool was_on = column->on();
	column->enabled = true;
	switched(*column, was_on);
	return true;
}

bool PawnTable::disable_column(const StringName &name) {
	Column *column = find_column(name, "disable_column");
	if (column == nullptr) {
		return false;
	}
	const bool was_on = column->on();
	column->enabled = false;
	if (column->required) {
		UtilityFunctions::push_warning("PawnTable: the column \"", name, "\" stays on, because a system that reads it requires it.");
	}
	switched(*column, was_on);
	return true;
}

bool PawnTable::add_column(const StringName &name, int64_t type, const StringName &property, const Variant &default_value) {
	if (name == StringName("key") || name == StringName("position") || name == StringName("team") || column_index(name) >= 0) {
		UtilityFunctions::push_error("PawnTable.add_column: there's already a column called \"", name, "\".");
		return false;
	}
	const Variant::Type kind = Variant::Type(type);
	if (kind != Variant::FLOAT && kind != Variant::INT && kind != Variant::BOOL && kind != Variant::VECTOR3) {
		UtilityFunctions::push_error("PawnTable.add_column: \"", name, "\" must be TYPE_FLOAT, TYPE_INT, TYPE_BOOL or TYPE_VECTOR3.");
		return false;
	}
	Column column;
	column.name = name;
	column.property = property;
	column.type = kind;
	column.default_value = default_value;
	_columns.push_back(column);
	return enable_column(name); // a game adds a column to use it
}

bool PawnTable::is_column_on(const StringName &name) const {
	if (name == StringName("key") || name == StringName("position") || name == StringName("team")) {
		return true;
	}
	const int i = column_index(name);
	return i >= 0 && _columns[size_t(i)].on();
}

bool PawnTable::has_column(const StringName &name) const {
	return name == StringName("key") || name == StringName("position") || name == StringName("team") || column_index(name) >= 0;
}

PackedStringArray PawnTable::get_column_names() const {
	PackedStringArray names;
	names.push_back("key");
	names.push_back("position");
	names.push_back("team");
	for (const Column &column : _columns) {
		names.push_back(String(column.name));
	}
	return names;
}

Variant PawnTable::get_column(const StringName &name) const {
	if (name == StringName("key")) {
		return get_keys();
	}
	if (name == StringName("position")) {
		PackedVector3Array out;
		for (const Vector3 &v : _positions) {
			out.push_back(v);
		}
		return out;
	}
	if (name == StringName("team")) {
		PackedInt64Array out;
		for (int64_t v : _teams) {
			out.push_back(v);
		}
		return out;
	}
	const int i = column_index(name);
	if (i < 0) {
		return Variant();
	}
	const Column &column = _columns[size_t(i)];
	if (column.type == Variant::FLOAT) {
		PackedFloat64Array out;
		for (double v : column.numbers) {
			out.push_back(v);
		}
		return out;
	}
	if (column.type == Variant::VECTOR3) {
		PackedVector3Array out;
		for (const Vector3 &v : column.vectors) {
			out.push_back(v);
		}
		return out;
	}
	PackedInt64Array out;
	for (int64_t v : column.whole_numbers) {
		out.push_back(v);
	}
	return out;
}

int PawnTable::column_index(const StringName &name) const {
	for (size_t i = 0; i < _columns.size(); ++i) {
		if (_columns[i].name == name) {
			return int(i);
		}
	}
	return -1;
}

PawnTable::Column *PawnTable::find_column(const StringName &name, const char *asked_by) {
	const int i = column_index(name);
	if (i < 0) {
		UtilityFunctions::push_error("PawnTable.", asked_by, ": no column called \"", name, "\". Built-in ones: velocity, yaw, grounded, detectability; add others with add_column.");
		return nullptr;
	}
	return &_columns[size_t(i)];
}

// A column switched on gets a value for every pawn (its default until the next refresh reads them); one switched off lets its memory go.
void PawnTable::switched(Column &column, bool was_on) {
	if (column.on() == was_on) {
		return;
	}
	before_change();
	if (column.on()) {
		resize_column(column);
		_stale = true; // the next refresh reads its real values
	} else {
		column.numbers = std::vector<double>();
		column.whole_numbers = std::vector<int64_t>();
		column.vectors = std::vector<Vector3>();
	}
	++_version;
}

void PawnTable::resize_column(Column &column) {
	const size_t count = _keys.size();
	if (column.type == Variant::FLOAT) {
		column.numbers.assign(count, double(column.default_value));
	} else if (column.type == Variant::VECTOR3) {
		column.vectors.assign(count, Vector3(column.default_value));
	} else {
		column.whole_numbers.assign(count, column.type == Variant::BOOL ? (bool(column.default_value) ? 1 : 0) : int64_t(column.default_value));
	}
}

void PawnTable::read_column(Column &column, size_t slot, Object *node) {
	Variant value = node->get(column.property);
	if (value.get_type() == Variant::NIL) {
		value = column.default_value; // the pawn doesn't have this property
	}
	if (column.type == Variant::FLOAT) {
		column.numbers[slot] = double(value);
	} else if (column.type == Variant::VECTOR3) {
		column.vectors[slot] = Vector3(value);
	} else if (column.type == Variant::BOOL) {
		column.whole_numbers[slot] = bool(value) ? 1 : 0;
	} else {
		column.whole_numbers[slot] = int64_t(value);
	}
}

void PawnTable::before_change() {
	if (_change_guard) {
		_change_guard();
	}
}

// --- For GDScript ---

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
	// Claude 2026-11-09 (step 2): and every column that's on.
	for (const Column &column : _columns) {
		if (!column.on()) {
			continue;
		}
		if (column.type == Variant::FLOAT) {
			row[String(column.name)] = column.numbers[i];
		} else if (column.type == Variant::VECTOR3) {
			row[String(column.name)] = column.vectors[i];
		} else if (column.type == Variant::BOOL) {
			row[String(column.name)] = column.whole_numbers[i] != 0;
		} else {
			row[String(column.name)] = column.whole_numbers[i];
		}
	}
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
	_teams.erase(_teams.begin() + slot);
	for (Column &column : _columns) {
		if (!column.on()) {
			continue;
		}
		if (column.type == Variant::FLOAT) {
			column.numbers.erase(column.numbers.begin() + slot);
		} else if (column.type == Variant::VECTOR3) {
			column.vectors.erase(column.vectors.begin() + slot);
		} else {
			column.whole_numbers.erase(column.whole_numbers.begin() + slot);
		}
	}
}

void PawnTable::_bind_methods() {
	ClassDB::bind_method(D_METHOD("add", "pawn", "key"), &PawnTable::add);
	ClassDB::bind_method(D_METHOD("remove", "pawn"), &PawnTable::remove);
	ClassDB::bind_method(D_METHOD("get_count"), &PawnTable::get_count);
	ClassDB::bind_method(D_METHOD("refresh", "tick"), &PawnTable::refresh);
	ClassDB::bind_method(D_METHOD("get_refreshed_tick"), &PawnTable::get_refreshed_tick);
	ClassDB::bind_method(D_METHOD("mark_stale"), &PawnTable::mark_stale);
	ClassDB::bind_method(D_METHOD("require_column", "name"), &PawnTable::require_column);
	ClassDB::bind_method(D_METHOD("enable_column", "name"), &PawnTable::enable_column);
	ClassDB::bind_method(D_METHOD("disable_column", "name"), &PawnTable::disable_column);
	ClassDB::bind_method(D_METHOD("add_column", "name", "type", "property", "default_value"), &PawnTable::add_column);
	ClassDB::bind_method(D_METHOD("is_column_on", "name"), &PawnTable::is_column_on);
	ClassDB::bind_method(D_METHOD("has_column", "name"), &PawnTable::has_column);
	ClassDB::bind_method(D_METHOD("get_column_names"), &PawnTable::get_column_names);
	ClassDB::bind_method(D_METHOD("get_column", "name"), &PawnTable::get_column);
	ClassDB::bind_method(D_METHOD("get_keys"), &PawnTable::get_keys);
	ClassDB::bind_method(D_METHOD("get_slot", "pawn"), &PawnTable::get_slot);
	ClassDB::bind_method(D_METHOD("get_row", "slot"), &PawnTable::get_row);
}
