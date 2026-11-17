// Written by Claude (claude-opus-5-5), 2026-11-09. History: native/CHANGELOG.md.
// TickStateRecorder: the fast path of rollback recording. Described in tick_state_recorder.h.
#include "tick_state_recorder.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/math.hpp>
#include <godot_cpp/core/object.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector3.hpp>

using namespace godot;

// MM, CM, U16_STEP, BYTE_STEP, PI_VALUE and the encoding numbers come from state_encoding.h, shared with NetCodec.
using namespace state_encoding;

namespace {

// StateEncoding._as_float32: a 64-bit float through 32 bits and back, as Vector2(value, 0.0).x does.
double as_float32(double value) {
	return (double)(float)value;
}
} // namespace

TickStateRecorder::TickStateRecorder() :
		m_step_mm3(Vector3(MM, MM, MM)),
		m_step_mm2(Vector2(MM, MM)),
		m_step_cm3(Vector3(CM, CM, CM)) {
}

void TickStateRecorder::clear() {
	m_entries.clear();
	m_nodes.clear();
}

bool TickStateRecorder::add(Object *node, const NodePath &property, const StringName &encoding) {
	const int id = encoding_id(encoding);
	if (node == nullptr || id == ENC_UNKNOWN) {
		return false;
	}
	Entry entry;
	entry.node_id = node->get_instance_id();
	entry.path = property;
	entry.encoding = id;
	// A plain name ("velocity") is one name with no parts; ":rotation:y" has parts and goes through get_indexed.
	entry.indexed = property.get_name_count() != 1 || property.get_subname_count() != 0;
	if (property.get_name_count() == 0 && property.get_subname_count() > 0) {
		entry.indexed = true;
	}
	if (!entry.indexed) {
		entry.name = property.get_name(0);
	}
	m_entries.push_back(entry);
	m_nodes.push_back(nullptr);
	return true;
}

int64_t TickStateRecorder::get_count() const {
	return (int64_t)m_entries.size();
}

bool TickStateRecorder::capture(Array values, bool round_values, bool store) {
	const size_t count = m_entries.size();
	// First every node, so a freed one stops the tick before anything is read or written.
	for (size_t i = 0; i < count; i++) {
		Object *node = ObjectDB::get_instance(m_entries[i].node_id);
		if (node == nullptr) {
			return false;
		}
		m_nodes[i] = node;
	}
	if (store) {
		values.resize((int64_t)count);
	}
	for (size_t i = 0; i < count; i++) {
		const Entry &entry = m_entries[i];
		Object *node = m_nodes[i];
		Variant value = entry.indexed ? node->get_indexed(entry.path) : node->get(entry.name);
		if (round_values) {
			Variant rounded = quantize_by_id(value, entry.encoding);
			// Only values that changed are written back, so setters don't run needlessly (as in TickStateComponent).
			if (rounded != value) {
				if (entry.indexed) {
					node->set_indexed(entry.path, rounded);
				} else {
					node->set(entry.name, rounded);
				}
				value = rounded;
			}
		}
		if (store) {
			// StateEncoding.copy_value: containers are copied, so every history slot keeps its own contents.
			const Variant::Type type = value.get_type();
			if (type == Variant::ARRAY || type == Variant::DICTIONARY || type >= Variant::PACKED_BYTE_ARRAY) {
				values[(int64_t)i] = value.duplicate(true);
			} else {
				values[(int64_t)i] = value;
			}
		}
	}
	return true;
}

Variant TickStateRecorder::quantize(const Variant &value, const StringName &encoding) const {
	const int id = encoding_id(encoding);
	return id == ENC_UNKNOWN ? value : quantize_by_id(value, id);
}

// StateEncoding.quantize, case by case. A value whose type doesn't fit its encoding comes back unchanged.
Variant TickStateRecorder::quantize_by_id(const Variant &value, int encoding) const {
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

// Through the shared names in state_encoding.h. "auto" counts as unknown here: an entry's encoding is settled before it gets here.
int TickStateRecorder::encoding_id(const StringName &name) const {
	const Encoding id = m_encoding_names.id_of(name);
	return id == ENC_AUTO ? int(ENC_UNKNOWN) : int(id);
}

void TickStateRecorder::_bind_methods() {
	ClassDB::bind_method(D_METHOD("clear"), &TickStateRecorder::clear);
	ClassDB::bind_method(D_METHOD("add", "node", "property", "encoding"), &TickStateRecorder::add);
	ClassDB::bind_method(D_METHOD("get_count"), &TickStateRecorder::get_count);
	ClassDB::bind_method(D_METHOD("capture", "values", "round_values", "store"), &TickStateRecorder::capture);
	ClassDB::bind_method(D_METHOD("quantize", "value", "encoding"), &TickStateRecorder::quantize);
}
