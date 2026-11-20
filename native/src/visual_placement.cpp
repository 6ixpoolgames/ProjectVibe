// Written by Claude (claude-opus-5-5), 2026-11-21. History: native/CHANGELOG.md.
#include "visual_placement.h"

#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/math.hpp>
#include <godot_cpp/core/object.hpp>

#include <cmath>

using namespace godot;

VisualPlacement::Slot *VisualPlacement::slot_at(int64_t slot) {
	if (slot < 0 || slot >= (int64_t)m_slots.size() || !m_slots[size_t(slot)].used) {
		return nullptr;
	}
	return &m_slots[size_t(slot)];
}

int64_t VisualPlacement::add(Object *visual, Object *model, const Vector3 &position, double yaw) {
	int64_t index = 0;
	// The last freed slot first, as the twin does.
	if (!m_free.empty()) {
		index = m_free.back();
		m_free.pop_back();
	} else {
		index = (int64_t)m_slots.size();
		m_slots.emplace_back();
	}
	Slot &slot = m_slots[size_t(index)];
	slot = Slot();
	slot.used = true;
	slot.visual_id = visual ? visual->get_instance_id() : 0;
	slot.model_id = model ? model->get_instance_id() : 0;
	slot.previous_position = position;
	slot.current_position = position;
	slot.previous_yaw = yaw;
	slot.current_yaw = yaw;
	m_count++;
	return index;
}

void VisualPlacement::remove(int64_t slot) {
	if (Slot *s = slot_at(slot)) {
		s->used = false;
		m_free.push_back(slot);
		m_count--;
	}
}

void VisualPlacement::snap(int64_t slot, const Vector3 &position, double yaw) {
	if (Slot *s = slot_at(slot)) {
		s->previous_position = position;
		s->current_position = position;
		s->previous_yaw = yaw;
		s->current_yaw = yaw;
	}
}

void VisualPlacement::note_run(int64_t slot, const Vector3 &position, double yaw, int64_t span, int64_t tick) {
	if (Slot *s = slot_at(slot)) {
		s->previous_position = s->current_position;
		s->previous_yaw = s->current_yaw;
		s->current_position = position;
		s->current_yaw = yaw;
		s->span = span;
		s->run_tick = tick;
	}
}

void VisualPlacement::note_runs(const PackedInt64Array &slots, const PackedVector3Array &positions, const PackedFloat32Array &yaws,
		const PackedInt64Array &spans, int64_t tick) {
	const int64_t count = slots.size();
	if (positions.size() < count || yaws.size() < count || spans.size() < count) {
		return;
	}
	for (int64_t i = 0; i < count; i++) {
		note_run(slots[i], positions[i], yaws[i], spans[i], tick);
	}
}

void VisualPlacement::note_moved(int64_t slot, const Vector3 &position, double yaw) {
	if (Slot *s = slot_at(slot)) {
		note_run(slot, position, yaw, 1, s->run_tick);
	}
}

void VisualPlacement::add_correction(int64_t slot, const Vector3 &jump) {
	if (Slot *s = slot_at(slot)) {
		s->correction += jump;
	}
}

Vector3 VisualPlacement::get_correction(int64_t slot) const {
	if (slot < 0 || slot >= (int64_t)m_slots.size() || !m_slots[size_t(slot)].used) {
		return Vector3();
	}
	return m_slots[size_t(slot)].correction;
}

void VisualPlacement::place(int64_t tick, double fraction, double delta, bool spans_runs) {
	const real_t fade = real_t(1.0 - std::exp(-delta / 0.04));
	for (Slot &s : m_slots) {
		if (!s.used) {
			continue;
		}
		Node3D *visual = Object::cast_to<Node3D>(ObjectDB::get_instance(s.visual_id));
		if (visual == nullptr) {
			continue;
		}
		s.correction = s.correction.lerp(Vector3(), fade);
		double f = fraction;
		// A run longer than a tick is glided across in full, so a pawn on a load step moves steadily (pawn spec 8.21).
		if (s.span > 1 && spans_runs) {
			f = Math::clamp((double(tick - s.run_tick) + fraction) / double(s.span), 0.0, 1.0);
		}
		visual->set_global_position(s.previous_position.lerp(s.current_position, real_t(f)) + s.correction);
		if (Node3D *model = Object::cast_to<Node3D>(ObjectDB::get_instance(s.model_id))) {
			Vector3 rotation = model->get_rotation();
			rotation.y = real_t(Math::lerp_angle(s.previous_yaw, s.current_yaw, f));
			model->set_rotation(rotation);
		}
	}
}

int64_t VisualPlacement::get_count() const {
	return m_count;
}

void VisualPlacement::_bind_methods() {
	ClassDB::bind_method(D_METHOD("add", "visual", "model", "position", "yaw"), &VisualPlacement::add);
	ClassDB::bind_method(D_METHOD("remove", "slot"), &VisualPlacement::remove);
	ClassDB::bind_method(D_METHOD("snap", "slot", "position", "yaw"), &VisualPlacement::snap);
	ClassDB::bind_method(D_METHOD("note_run", "slot", "position", "yaw", "span", "tick"), &VisualPlacement::note_run);
	ClassDB::bind_method(D_METHOD("note_runs", "slots", "positions", "yaws", "spans", "tick"), &VisualPlacement::note_runs);
	ClassDB::bind_method(D_METHOD("note_moved", "slot", "position", "yaw"), &VisualPlacement::note_moved);
	ClassDB::bind_method(D_METHOD("add_correction", "slot", "jump"), &VisualPlacement::add_correction);
	ClassDB::bind_method(D_METHOD("get_correction", "slot"), &VisualPlacement::get_correction);
	ClassDB::bind_method(D_METHOD("place", "tick", "fraction", "delta", "spans_runs"), &VisualPlacement::place);
	ClassDB::bind_method(D_METHOD("get_count"), &VisualPlacement::get_count);
}
