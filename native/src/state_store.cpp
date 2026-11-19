// Written by Claude (claude-opus-5-5), 2026-11-19. History: native/CHANGELOG.md.
// StateStore: the central record of every gameplay entity's state, tick by tick. Described in state_store.h.
#include "state_store.h"

#include <godot_cpp/classes/time.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/object.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector3.hpp>

using namespace godot;
using namespace state_encoding;

namespace {

constexpr int64_t SLOT_BITS = 20;
constexpr int64_t LAYOUT_BITS = 12;
constexpr int64_t SLOT_MASK = (int64_t(1) << SLOT_BITS) - 1;
constexpr int64_t LAYOUT_MASK = (int64_t(1) << LAYOUT_BITS) - 1;

// StateEncoding._as_float32: a 64-bit float through 32 bits and back, as Vector2(value, 0.0).x does.
double as_float32(double value) {
	return (double)(float)value;
}

int64_t make_handle(uint32_t generation, int64_t layout, int64_t slot) {
	return (int64_t(generation) << 32) | (layout << SLOT_BITS) | slot;
}

} // namespace

StateStore::StateStore() :
		m_missing("__tick_state_missing__"),
		m_step_mm3(Vector3(MM, MM, MM)),
		m_step_mm2(Vector2(MM, MM)),
		m_step_cm3(Vector3(CM, CM, CM)) {
}

void StateStore::clear() {
	m_layouts.clear();
	m_now = -1;
}

bool StateStore::set_depth(int64_t depth) {
	for (const Layout &layout : m_layouts) {
		if (!layout.slots.empty()) {
			return false;
		}
	}
	m_depth = depth < 1 ? 1 : depth;
	return true;
}

int64_t StateStore::get_depth() const {
	return m_depth;
}

int64_t StateStore::define_layout(const PackedStringArray &names, const Array &encodings, const PackedByteArray &pushed) {
	if (names.size() != encodings.size() || (pushed.size() != 0 && pushed.size() != names.size())) {
		UtilityFunctions::push_error("StateStore.define_layout: names, encodings and pushed must be the same size");
		return -1;
	}
	std::vector<int> ids;
	std::vector<uint8_t> kinds;
	String signature;
	for (int64_t i = 0; i < names.size(); i++) {
		const int id = (int)m_encoding_names.id_of(StringName(encodings[i]));
		if (id == ENC_UNKNOWN) {
			UtilityFunctions::push_error(String("StateStore.define_layout: '") + names[i] + String("' has no usable encoding: ") + String(encodings[i]));
			return -1;
		}
		const uint8_t kind = pushed.size() ? (pushed[i] ? 1 : 0) : 0;
		ids.push_back(id);
		kinds.push_back(kind);
		signature += names[i] + String("@") + String(encodings[i]) + String(kind ? "^" : "") + String("|");
	}
	for (size_t l = 0; l < m_layouts.size(); l++) {
		if (m_layouts[l].signature == signature) {
			return (int64_t)l;
		}
	}
	if ((int64_t)m_layouts.size() > LAYOUT_MASK) {
		UtilityFunctions::push_error("StateStore.define_layout: too many layouts");
		return -1;
	}
	Layout layout;
	layout.signature = signature;
	layout.names = names;
	layout.encodings = ids;
	layout.pushed = kinds;
	layout.width = names.size();
	for (uint8_t kind : kinds) {
		layout.gathered += kind ? 0 : 1;
	}
	m_layouts.push_back(layout);
	return (int64_t)m_layouts.size() - 1;
}

int64_t StateStore::get_layout_count() const {
	return (int64_t)m_layouts.size();
}

PackedStringArray StateStore::get_layout_columns(int64_t layout) const {
	if (layout < 0 || layout >= (int64_t)m_layouts.size()) {
		return PackedStringArray();
	}
	return m_layouts[layout].names;
}

int64_t StateStore::add_entity(int64_t layout_index, Object *owner) {
	if (layout_index < 0 || layout_index >= (int64_t)m_layouts.size()) {
		return -1;
	}
	Layout &layout = m_layouts[layout_index];
	int64_t slot = -1;
	// The oldest freed slot, once the history has moved past everything its old occupant wrote.
	if (!layout.free_slots.empty()) {
		const int64_t oldest = layout.free_slots.front();
		if (m_now - layout.slots[oldest].freed_tick >= m_depth) {
			slot = oldest;
			layout.free_slots.pop_front();
		}
	}
	if (slot < 0) {
		if ((int64_t)layout.slots.size() > SLOT_MASK) {
			UtilityFunctions::push_error("StateStore.add_entity: the layout is full");
			return -1;
		}
		slot = (int64_t)layout.slots.size();
		layout.slots.push_back(Entity());
		layout.cells.resize(layout.cells.size() + size_t(m_depth * layout.width));
		layout.row_tick.resize(layout.row_tick.size() + size_t(m_depth), -1);
		layout.row_generation.resize(layout.row_generation.size() + size_t(m_depth), 0);
	}
	Entity &entity = layout.slots[slot];
	entity.generation += 1;
	if (entity.generation >= 0x7fffffffu) {
		entity.generation = 1;
	}
	entity.alive = true;
	entity.active = true;
	entity.bound = false;
	entity.round_values = true;
	entity.freed_tick = -1;
	entity.owner_id = owner ? owner->get_instance_id() : 0;
	entity.depth = m_depth;
	entity.newest = -1;
	entity.accessors.clear();
	entity.pushed.assign(size_t(layout.width), Variant());
	// With only pushed columns there's nothing to bind: it commits from the start.
	if (layout.gathered == 0) {
		entity.accessors.resize(size_t(layout.width));
		entity.bound = true;
	}
	return make_handle(entity.generation, layout_index, slot);
}

void StateStore::remove_entity(int64_t handle) {
	int64_t slot = 0;
	Layout *layout = layout_of(handle, slot);
	if (layout == nullptr) {
		return;
	}
	Entity &entity = layout->slots[slot];
	entity.alive = false;
	entity.bound = false;
	entity.accessors.clear();
	entity.freed_tick = m_now;
	layout->free_slots.push_back(slot);
}

bool StateStore::is_alive(int64_t handle) const {
	return entity_of(handle) != nullptr;
}

void StateStore::set_active(int64_t handle, bool active) {
	if (Entity *entity = entity_of(handle)) {
		entity->active = active;
	}
}

bool StateStore::is_active(int64_t handle) const {
	const Entity *entity = entity_of(handle);
	return entity != nullptr && entity->active;
}

void StateStore::set_entity_depth(int64_t handle, int64_t depth) {
	if (Entity *entity = entity_of(handle)) {
		entity->depth = depth < 1 ? 1 : (depth > m_depth ? m_depth : depth);
	}
}

Object *StateStore::get_owner(int64_t handle) const {
	const Entity *entity = entity_of(handle);
	return entity && entity->owner_id ? ObjectDB::get_instance(entity->owner_id) : nullptr;
}

bool StateStore::bind(int64_t handle, const Array &nodes, const Array &properties, const Array &encodings, bool round_values) {
	int64_t slot = 0;
	Layout *layout = layout_of(handle, slot);
	if (layout == nullptr || nodes.size() != layout->width || properties.size() != layout->width || encodings.size() != layout->width) {
		return false;
	}
	std::vector<Accessor> accessors(size_t(layout->width));
	for (int64_t c = 0; c < layout->width; c++) {
		Object *node = nodes[c];
		if (layout->pushed[c] && node == nullptr) {
			continue; // pushed only: nothing to read or write back
		}
		const int encoding = encoding_id(StringName(encodings[c]));
		if (node == nullptr || encoding == ENC_UNKNOWN || (layout->encodings[c] != ENC_AUTO && layout->encodings[c] != encoding)) {
			return false;
		}
		const NodePath property = properties[c];
		Accessor &accessor = accessors[c];
		accessor.encoding = encoding;
		accessor.node_id = node->get_instance_id();
		accessor.path = property;
		// A plain name ("velocity") is one name with no parts; ":rotation:y" has parts and goes through get_indexed.
		accessor.indexed = property.get_name_count() != 1 || property.get_subname_count() != 0;
		if (!accessor.indexed) {
			accessor.name = property.get_name(0);
		}
	}
	Entity &entity = layout->slots[slot];
	entity.accessors = accessors;
	entity.round_values = round_values;
	entity.bound = true;
	entity.changed = true;
	// A pushed column bound to a node starts from the node's value, rounded.
	for (int64_t c = 0; c < layout->width; c++) {
		const Accessor &accessor = accessors[c];
		if (!layout->pushed[c] || accessor.node_id == 0) {
			continue;
		}
		Object *node = ObjectDB::get_instance(accessor.node_id);
		const Variant value = accessor.indexed ? node->get_indexed(accessor.path) : node->get(accessor.name);
		entity.pushed[c] = copy_value(round_values ? quantize_by_id(value, accessor.encoding) : value);
	}
	return true;
}

void StateStore::unbind(int64_t handle) {
	if (Entity *entity = entity_of(handle)) {
		entity->bound = false;
		entity->accessors.clear();
	}
}

bool StateStore::is_bound(int64_t handle) const {
	const Entity *entity = entity_of(handle);
	return entity != nullptr && entity->bound;
}

void StateStore::push(int64_t handle, int64_t column, const Variant &value) {
	int64_t slot = 0;
	Layout *layout = layout_of(handle, slot);
	if (layout == nullptr || column < 0 || column >= layout->width) {
		return;
	}
	layout->slots[slot].pushed[column] = copy_value(value);
}

void StateStore::set_carry_forward(int64_t handle, bool on) {
	if (Entity *entity = entity_of(handle)) {
		entity->carry_forward = on;
		entity->changed = true;
	}
}

void StateStore::mark_changed(int64_t handle) {
	if (Entity *entity = entity_of(handle)) {
		entity->changed = true;
	}
}

PackedInt64Array StateStore::commit(int64_t tick) {
	const uint64_t started = Time::get_singleton()->get_ticks_usec();
	m_now = tick;
	m_rows_read = 0;
	m_rows_carried = 0;
	PackedInt64Array unfinished;
	for (size_t l = 0; l < m_layouts.size(); l++) {
		Layout &layout = m_layouts[l];
		for (int64_t slot = 0; slot < (int64_t)layout.slots.size(); slot++) {
			const Entity &entity = layout.slots[slot];
			if (!entity.alive || !entity.active) {
				continue;
			}
			if (!commit_one(layout, slot, tick, true)) {
				unfinished.push_back(make_handle(entity.generation, (int64_t)l, slot));
			}
		}
	}
	m_commit_usec = int64_t(Time::get_singleton()->get_ticks_usec() - started);
	return unfinished;
}

PackedInt64Array StateStore::commit_entities(int64_t tick, const PackedInt64Array &handles) {
	PackedInt64Array unfinished;
	for (int64_t i = 0; i < handles.size(); i++) {
		int64_t slot = 0;
		Layout *layout = layout_of(handles[i], slot);
		if (layout == nullptr || !layout->slots[slot].active) {
			continue;
		}
		if (!commit_one(*layout, slot, tick, false)) {
			unfinished.push_back(handles[i]);
		}
	}
	return unfinished;
}

// One entity's row for a tick: copied forward from the tick before when it may be and nothing changed it, else gathered from its nodes.
// False (writing nothing) if it isn't bound or a node is gone, which unbinds it.
bool StateStore::commit_one(Layout &layout, int64_t slot, int64_t tick, bool may_carry) {
	Entity &entity = layout.slots[slot];
	if (!entity.bound) {
		return false;
	}
	const int64_t width = layout.width;
	const int64_t frame = frame_of(tick);
	const int64_t row = slot * m_depth + frame;
	if (may_carry && entity.carry_forward && !entity.changed && row_held(layout, slot, entity.generation, entity.depth, tick - 1)) {
		const Variant *before = layout.cells.data() + size_t((slot * m_depth + frame_of(tick - 1)) * width);
		Variant *cells = layout.cells.data() + size_t(row * width);
		for (int64_t c = 0; c < width; c++) {
			cells[c] = layout.pushed[c] ? copy_value(entity.pushed[c]) : copy_value(before[c]);
		}
		layout.row_tick[row] = tick;
		layout.row_generation[row] = entity.generation;
		entity.newest = tick > entity.newest ? tick : entity.newest;
		m_rows_carried++;
		return true;
	}
	// First every node, so a freed one stops it before anything is read or written.
	m_nodes.resize(size_t(width));
	for (int64_t c = 0; c < width; c++) {
		m_nodes[c] = nullptr;
		if (layout.pushed[c]) {
			continue;
		}
		Object *node = ObjectDB::get_instance(entity.accessors[c].node_id);
		if (node == nullptr) {
			entity.bound = false;
			entity.accessors.clear();
			return false;
		}
		m_nodes[c] = node;
	}
	Variant *cells = layout.cells.data() + size_t(row * width);
	for (int64_t c = 0; c < width; c++) {
		if (layout.pushed[c]) {
			cells[c] = copy_value(entity.pushed[c]);
			continue;
		}
		const Accessor &accessor = entity.accessors[c];
		Object *node = m_nodes[c];
		Variant value = accessor.indexed ? node->get_indexed(accessor.path) : node->get(accessor.name);
		if (entity.round_values) {
			Variant rounded = quantize_by_id(value, accessor.encoding);
			// Only values rounding changed are written back, so setters don't run needlessly.
			if (rounded != value) {
				if (accessor.indexed) {
					node->set_indexed(accessor.path, rounded);
				} else {
					node->set(accessor.name, rounded);
				}
				value = rounded;
			}
		}
		cells[c] = copy_value(value);
	}
	layout.row_tick[row] = tick;
	layout.row_generation[row] = entity.generation;
	if (tick > entity.newest) {
		entity.newest = tick;
	}
	entity.changed = false;
	m_rows_read++;
	return true;
}

bool StateStore::write_row(int64_t handle, int64_t tick, const Array &values) {
	int64_t slot = 0;
	Layout *layout = layout_of(handle, slot);
	if (layout == nullptr || values.size() != layout->width) {
		return false;
	}
	Entity &entity = layout->slots[slot];
	const int64_t row = slot * m_depth + frame_of(tick);
	Variant *cells = layout->cells.data() + size_t(row * layout->width);
	for (int64_t c = 0; c < layout->width; c++) {
		cells[c] = copy_value(values[c]);
	}
	layout->row_tick[row] = tick;
	layout->row_generation[row] = entity.generation;
	if (tick > entity.newest) {
		entity.newest = tick;
	}
	return true;
}

bool StateStore::has_row(int64_t handle, int64_t tick) const {
	int64_t slot = 0;
	const Layout *layout = layout_of(handle, slot);
	if (layout == nullptr) {
		// A freed entity's rows still count until they're overwritten.
		slot = handle & SLOT_MASK;
		const int64_t l = (handle >> SLOT_BITS) & LAYOUT_MASK;
		if (handle < 0 || l >= (int64_t)m_layouts.size() || slot >= (int64_t)m_layouts[l].slots.size()) {
			return false;
		}
		return row_held(m_layouts[l], slot, uint32_t(handle >> 32), m_depth, tick);
	}
	return row_held(*layout, slot, uint32_t(handle >> 32), layout->slots[slot].depth, tick);
}

bool StateStore::row_held(const Layout &layout, int64_t slot, uint32_t generation, int64_t depth, int64_t tick) const {
	if (tick < 0 || tick <= m_now - depth) {
		return false;
	}
	const int64_t row = slot * m_depth + frame_of(tick);
	return layout.row_tick[row] == tick && layout.row_generation[row] == generation;
}

Array StateStore::get_row(int64_t handle, int64_t tick) const {
	Array out;
	if (!has_row(handle, tick)) {
		return out;
	}
	const int64_t slot = handle & SLOT_MASK;
	const Layout &layout = m_layouts[(handle >> SLOT_BITS) & LAYOUT_MASK];
	const Variant *cells = layout.cells.data() + size_t((slot * m_depth + frame_of(tick)) * layout.width);
	out.resize(layout.width);
	for (int64_t c = 0; c < layout.width; c++) {
		out[c] = copy_value(cells[c]);
	}
	return out;
}

Variant StateStore::get_value(int64_t handle, int64_t column, int64_t tick) const {
	if (!has_row(handle, tick)) {
		return Variant();
	}
	const int64_t slot = handle & SLOT_MASK;
	const Layout &layout = m_layouts[(handle >> SLOT_BITS) & LAYOUT_MASK];
	if (column < 0 || column >= layout.width) {
		return Variant();
	}
	return copy_value(layout.cells[size_t((slot * m_depth + frame_of(tick)) * layout.width + column)]);
}

bool StateStore::set_value(int64_t handle, int64_t column, int64_t tick, const Variant &value) {
	if (!has_row(handle, tick)) {
		return false;
	}
	const int64_t slot = handle & SLOT_MASK;
	Layout &layout = m_layouts[(handle >> SLOT_BITS) & LAYOUT_MASK];
	if (column < 0 || column >= layout.width) {
		return false;
	}
	layout.cells[size_t((slot * m_depth + frame_of(tick)) * layout.width + column)] = copy_value(value);
	return true;
}

bool StateStore::load_row(int64_t handle, int64_t tick) {
	int64_t slot = 0;
	Layout *layout = layout_of(handle, slot);
	if (layout == nullptr || !layout->slots[slot].bound || !has_row(handle, tick)) {
		return false;
	}
	Entity &entity = layout->slots[slot];
	entity.changed = true;
	const Variant *cells = layout->cells.data() + size_t((slot * m_depth + frame_of(tick)) * layout->width);
	for (int64_t c = 0; c < layout->width; c++) {
		if (layout->pushed[c]) {
			entity.pushed[c] = copy_value(cells[c]);
		}
		if (cells[c].get_type() == Variant::STRING_NAME && StringName(cells[c]) == m_missing) {
			continue;
		}
		const Accessor &accessor = entity.accessors[c];
		Object *node = accessor.node_id ? ObjectDB::get_instance(accessor.node_id) : nullptr;
		if (node == nullptr) {
			continue;
		}
		if (accessor.indexed) {
			node->set_indexed(accessor.path, copy_value(cells[c]));
		} else {
			node->set(accessor.name, copy_value(cells[c]));
		}
	}
	return true;
}

int64_t StateStore::newest_tick(int64_t handle) const {
	const Entity *entity = entity_of(handle);
	return entity ? entity->newest : -1;
}

Dictionary StateStore::get_column(int64_t layout_index, int64_t column, int64_t tick) const {
	Dictionary out;
	PackedInt64Array handles;
	Array values;
	if (layout_index >= 0 && layout_index < (int64_t)m_layouts.size() && column >= 0 && column < m_layouts[layout_index].width) {
		const Layout &layout = m_layouts[layout_index];
		const int64_t frame = frame_of(tick);
		for (int64_t slot = 0; slot < (int64_t)layout.slots.size(); slot++) {
			const int64_t row = slot * m_depth + frame;
			if (tick < 0 || tick <= m_now - m_depth || layout.row_tick[row] != tick || layout.row_generation[row] == 0) {
				continue;
			}
			handles.push_back(make_handle(layout.row_generation[row], layout_index, slot));
			values.push_back(copy_value(layout.cells[size_t(row * layout.width + column)]));
		}
	}
	out["handles"] = handles;
	out["values"] = values;
	return out;
}

int64_t StateStore::frame_checksum(int64_t tick) const {
	// The rows as one Array, hashed by the engine: GDScript's hash() of the twin's same Array gives the same number.
	Array all;
	all.push_back(tick);
	if (tick >= 0 && tick > m_now - m_depth) {
		const int64_t frame = frame_of(tick);
		for (size_t l = 0; l < m_layouts.size(); l++) {
			const Layout &layout = m_layouts[l];
			for (int64_t slot = 0; slot < (int64_t)layout.slots.size(); slot++) {
				const int64_t row = slot * m_depth + frame;
				if (layout.row_tick[row] != tick || layout.row_generation[row] == 0) {
					continue;
				}
				all.push_back((int64_t)l);
				all.push_back(slot);
				all.push_back((int64_t)layout.row_generation[row]);
				const Variant *cells = layout.cells.data() + size_t(row * layout.width);
				for (int64_t c = 0; c < layout.width; c++) {
					all.push_back(cells[c]);
				}
			}
		}
	}
	return (int64_t)all.hash();
}

PackedInt64Array StateStore::verify_nodes(int64_t tick) {
	PackedInt64Array differ;
	for (size_t l = 0; l < m_layouts.size(); l++) {
		Layout &layout = m_layouts[l];
		for (int64_t slot = 0; slot < (int64_t)layout.slots.size(); slot++) {
			const Entity &entity = layout.slots[slot];
			if (!entity.alive || !entity.active || !entity.bound || !row_held(layout, slot, entity.generation, entity.depth, tick)) {
				continue;
			}
			const Variant *cells = layout.cells.data() + size_t((slot * m_depth + frame_of(tick)) * layout.width);
			for (int64_t c = 0; c < layout.width; c++) {
				const Accessor &accessor = entity.accessors[c];
				Object *node = accessor.node_id ? ObjectDB::get_instance(accessor.node_id) : nullptr;
				if (node == nullptr) {
					continue;
				}
				Variant value = accessor.indexed ? node->get_indexed(accessor.path) : node->get(accessor.name);
				if (entity.round_values) {
					value = quantize_by_id(value, accessor.encoding);
				}
				if (value != cells[c]) {
					differ.push_back(make_handle(entity.generation, (int64_t)l, slot));
					break;
				}
			}
		}
	}
	return differ;
}

Variant StateStore::quantize(const Variant &value, const StringName &encoding) const {
	const int id = encoding_id(encoding);
	return id == ENC_UNKNOWN ? value : quantize_by_id(value, id);
}

Dictionary StateStore::get_stats() const {
	int64_t entities = 0;
	int64_t active = 0;
	int64_t bound = 0;
	int64_t cells_per_frame = 0;
	for (const Layout &layout : m_layouts) {
		for (const Entity &entity : layout.slots) {
			if (!entity.alive) {
				continue;
			}
			entities++;
			active += entity.active ? 1 : 0;
			bound += entity.bound ? 1 : 0;
			cells_per_frame += entity.active ? layout.width : 0;
		}
	}
	Dictionary out;
	out["layouts"] = (int64_t)m_layouts.size();
	out["entities"] = entities;
	out["active"] = active;
	out["bound"] = bound;
	out["cells_per_frame"] = cells_per_frame;
	out["depth"] = m_depth;
	out["commit_usec"] = m_commit_usec;
	out["rows_read"] = m_rows_read;
	out["rows_carried"] = m_rows_carried;
	return out;
}

StateStore::Layout *StateStore::layout_of(int64_t handle, int64_t &slot) const {
	if (handle < 0) {
		return nullptr;
	}
	const int64_t l = (handle >> SLOT_BITS) & LAYOUT_MASK;
	slot = handle & SLOT_MASK;
	if (l >= (int64_t)m_layouts.size() || slot >= (int64_t)m_layouts[l].slots.size()) {
		return nullptr;
	}
	const Entity &entity = m_layouts[l].slots[slot];
	if (!entity.alive || entity.generation != uint32_t(handle >> 32)) {
		return nullptr;
	}
	return const_cast<Layout *>(&m_layouts[l]);
}

StateStore::Entity *StateStore::entity_of(int64_t handle) const {
	int64_t slot = 0;
	Layout *layout = layout_of(handle, slot);
	return layout ? &layout->slots[slot] : nullptr;
}

int64_t StateStore::frame_of(int64_t tick) const {
	const int64_t frame = tick % m_depth;
	return frame < 0 ? frame + m_depth : frame;
}

// StateEncoding.copy_value: containers are copied, so every frame keeps its own contents.
Variant StateStore::copy_value(const Variant &value) {
	const Variant::Type type = value.get_type();
	if (type == Variant::ARRAY || type == Variant::DICTIONARY || type >= Variant::PACKED_BYTE_ARRAY) {
		return value.duplicate(true);
	}
	return value;
}

// StateEncoding.quantize, case by case. A value whose type doesn't fit its encoding comes back unchanged.
Variant StateStore::quantize_by_id(const Variant &value, int encoding) const {
	const Variant::Type type = value.get_type();
	switch (encoding) {
		case ENC_VECTOR3_MM:
			if (type == Variant::VECTOR3) {
				return UtilityFunctions::snapped(value, m_step_mm3);
			}
			break;
		case ENC_VECTOR2_MM:
			if (type == Variant::VECTOR2) {
				return UtilityFunctions::snapped(value, m_step_mm2);
			}
			break;
		case ENC_VECTOR3_CM:
			if (type == Variant::VECTOR3) {
				return UtilityFunctions::snapped(value, m_step_cm3);
			}
			break;
		case ENC_ANGLE_U16:
			if (type == Variant::FLOAT) {
				return as_float32(UtilityFunctions::snappedf(UtilityFunctions::wrapf((double)value, -PI_VALUE, PI_VALUE), U16_STEP));
			}
			break;
		case ENC_ANGLE_BYTE:
			if (type == Variant::FLOAT) {
				return as_float32(UtilityFunctions::snappedf(UtilityFunctions::wrapf((double)value, -PI_VALUE, PI_VALUE), BYTE_STEP));
			}
			break;
		case ENC_FLOAT:
			if (type == Variant::FLOAT) {
				return as_float32((double)value);
			}
			break;
		default:
			break;
	}
	return value;
}

// Through the shared names in state_encoding.h. "auto" counts as unknown: an encoding is settled before it gets here.
int StateStore::encoding_id(const StringName &name) const {
	const Encoding id = m_encoding_names.id_of(name);
	return id == ENC_AUTO ? int(ENC_UNKNOWN) : int(id);
}

void StateStore::_bind_methods() {
	ClassDB::bind_method(D_METHOD("clear"), &StateStore::clear);
	ClassDB::bind_method(D_METHOD("set_depth", "depth"), &StateStore::set_depth);
	ClassDB::bind_method(D_METHOD("get_depth"), &StateStore::get_depth);
	ClassDB::bind_method(D_METHOD("define_layout", "names", "encodings", "pushed"), &StateStore::define_layout, DEFVAL(PackedByteArray()));
	ClassDB::bind_method(D_METHOD("get_layout_count"), &StateStore::get_layout_count);
	ClassDB::bind_method(D_METHOD("get_layout_columns", "layout"), &StateStore::get_layout_columns);
	ClassDB::bind_method(D_METHOD("add_entity", "layout", "owner"), &StateStore::add_entity);
	ClassDB::bind_method(D_METHOD("remove_entity", "handle"), &StateStore::remove_entity);
	ClassDB::bind_method(D_METHOD("is_alive", "handle"), &StateStore::is_alive);
	ClassDB::bind_method(D_METHOD("set_active", "handle", "active"), &StateStore::set_active);
	ClassDB::bind_method(D_METHOD("is_active", "handle"), &StateStore::is_active);
	ClassDB::bind_method(D_METHOD("set_entity_depth", "handle", "depth"), &StateStore::set_entity_depth);
	ClassDB::bind_method(D_METHOD("get_owner", "handle"), &StateStore::get_owner);
	ClassDB::bind_method(D_METHOD("bind", "handle", "nodes", "properties", "encodings", "round_values"), &StateStore::bind);
	ClassDB::bind_method(D_METHOD("unbind", "handle"), &StateStore::unbind);
	ClassDB::bind_method(D_METHOD("is_bound", "handle"), &StateStore::is_bound);
	ClassDB::bind_method(D_METHOD("push", "handle", "column", "value"), &StateStore::push);
	ClassDB::bind_method(D_METHOD("set_carry_forward", "handle", "on"), &StateStore::set_carry_forward);
	ClassDB::bind_method(D_METHOD("mark_changed", "handle"), &StateStore::mark_changed);
	ClassDB::bind_method(D_METHOD("commit", "tick"), &StateStore::commit);
	ClassDB::bind_method(D_METHOD("commit_entities", "tick", "handles"), &StateStore::commit_entities);
	ClassDB::bind_method(D_METHOD("write_row", "handle", "tick", "values"), &StateStore::write_row);
	ClassDB::bind_method(D_METHOD("has_row", "handle", "tick"), &StateStore::has_row);
	ClassDB::bind_method(D_METHOD("get_row", "handle", "tick"), &StateStore::get_row);
	ClassDB::bind_method(D_METHOD("get_value", "handle", "column", "tick"), &StateStore::get_value);
	ClassDB::bind_method(D_METHOD("set_value", "handle", "column", "tick", "value"), &StateStore::set_value);
	ClassDB::bind_method(D_METHOD("load_row", "handle", "tick"), &StateStore::load_row);
	ClassDB::bind_method(D_METHOD("newest_tick", "handle"), &StateStore::newest_tick);
	ClassDB::bind_method(D_METHOD("get_column", "layout", "column", "tick"), &StateStore::get_column);
	ClassDB::bind_method(D_METHOD("frame_checksum", "tick"), &StateStore::frame_checksum);
	ClassDB::bind_method(D_METHOD("verify_nodes", "tick"), &StateStore::verify_nodes);
	ClassDB::bind_method(D_METHOD("quantize", "value", "encoding"), &StateStore::quantize);
	ClassDB::bind_method(D_METHOD("get_stats"), &StateStore::get_stats);
}
