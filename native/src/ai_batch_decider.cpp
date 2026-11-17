// Written by Claude (claude-opus-5-5), 2026-11-17. History: native/CHANGELOG.md.
// AIBatchDecider: AI behaviour decisions for many pawns in one call. Described in ai_batch_decider.h. Every step follows
// AIBehaviourManager.decide() (assets/scripts/ai/AIBehaviourManager.gd) exactly, in the same order with the same arithmetic, so the
// two agree to the bit: a change to one goes in both, and ai_batch_decider_selftest compares them.
#include "ai_batch_decider.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <cmath>
#include <limits>

using namespace godot;

namespace {
constexpr double NEG_INF = -std::numeric_limits<double>::infinity();

// A column from decide()'s Dictionary, checked for its type and length. Null, with an error, if it's missing or wrong.
template <typename T>
const T *column(const Dictionary &columns, const char *name, Variant::Type type, int64_t length, T &holder, bool required = true) {
	const Variant value = columns.get(name, Variant());
	if (value.get_type() == Variant::NIL && !required) {
		return nullptr;
	}
	if (value.get_type() != type) {
		UtilityFunctions::push_error(String("AIBatchDecider.decide: the column \"") + name + "\" is missing or the wrong type.");
		return nullptr;
	}
	holder = value;
	if (holder.size() != length) {
		UtilityFunctions::push_error(String("AIBatchDecider.decide: the column \"") + name + "\" has the wrong length.");
		return nullptr;
	}
	return &holder;
}

// The scorer for a name in a brain description. Unknown names are refused (add_brain fails), so a typo can't pass silently.
bool scorer_by_name(const String &name, uint8_t &scorer) {
	if (name.is_empty() || name == "given") {
		scorer = 0; // Scorer::GIVEN
		return true;
	}
	return false;
}
} // namespace

double AIBatchDecider::random_unit_at(int64_t seed, int64_t pawn_number, int64_t tick, int64_t salt) {
	// GDScript's ints are 64-bit and wrap on overflow; unsigned arithmetic wraps the same way in C++ (signed overflow is undefined).
	uint64_t h = (uint64_t(seed) * 83492791ULL) ^ (uint64_t(pawn_number) * 19349663ULL) ^ (uint64_t(tick) * 73856093ULL) ^ uint64_t(salt);
	h &= 0xFFFFFFFFULL;
	h = ((h ^ (h >> 16)) * 0x45D9F3BULL) & 0xFFFFFFFFULL;
	h = ((h ^ (h >> 16)) * 0x45D9F3BULL) & 0xFFFFFFFFULL;
	h = h ^ (h >> 16);
	return double(h & 0xFFFFFFULL) / 16777216.0;
}

double AIBatchDecider::random_unit(int64_t seed, int64_t pawn_number, int64_t tick, int64_t salt) const {
	return random_unit_at(seed, pawn_number, tick, salt);
}

int AIBatchDecider::add_brain(const Dictionary &description) {
	const Array list = description.get("behaviours", Array());
	if (list.size() > MAX_BEHAVIOURS) {
		UtilityFunctions::push_error(vformat("AIBatchDecider.add_brain: %d behaviours; a brain holds up to %d.", list.size(), MAX_BEHAVIOURS));
		return -1;
	}
	Brain brain;
	brain.tie_margin = double(description.get("tie_margin", 0.0001));
	brain.randomize_ties = bool(description.get("randomize_ties", false));
	brain.tie_salt = int64_t(description.get("tie_salt", 0x7135));
	// Each behaviour's allowed states, kept until the fixed order is known.
	std::vector<Array> allowed;
	for (int64_t i = 0; i < list.size(); ++i) {
		const Dictionary entry = list[i];
		Behaviour behaviour;
		behaviour.name = StringName(String(entry.get("name", "")));
		behaviour.name_hash = int64_t(entry.get("name_hash", 0));
		behaviour.max_score = double(entry.get("max_score", 0.5));
		const Variant min_score = entry.get("min_score", Variant());
		behaviour.has_min_score = min_score.get_type() != Variant::NIL && double(min_score) > NEG_INF;
		behaviour.min_score = behaviour.has_min_score ? double(min_score) : NEG_INF;
		behaviour.needs_target = bool(entry.get("needs_target", false));
		behaviour.presses_action = !String(entry.get("presses_action", "")).is_empty();
		behaviour.min_run_ticks = int64_t(entry.get("min_run_ticks_at_rate", entry.get("min_run_ticks", 0)));
		behaviour.interrupt_threshold = int64_t(entry.get("interrupt_threshold", 0));
		behaviour.cannot_be_interrupted = bool(entry.get("cannot_be_interrupted", false));
		behaviour.jitter = double(entry.get("effective_jitter", 0.0));
		uint8_t scorer = 0;
		if (!scorer_by_name(String(entry.get("scorer", "")), scorer)) {
			UtilityFunctions::push_error("AIBatchDecider.add_brain: no scorer called \"" + String(entry.get("scorer", "")) + "\".");
			return -1;
		}
		behaviour.scorer = Scorer(scorer);
		brain.behaviours.push_back(behaviour);
		allowed.push_back(entry.get("allowed_states", Array()));
	}
	// The fixed order: by name, as AIBehaviourManager._collect_behaviours sorts (String comparison, so the same order).
	std::vector<int> order(brain.behaviours.size());
	for (size_t i = 0; i < order.size(); ++i) {
		order[i] = int(i);
	}
	std::sort(order.begin(), order.end(), [&](int a, int b) {
		return String(brain.behaviours[a].name) < String(brain.behaviours[b].name);
	});
	std::vector<Behaviour> sorted;
	std::vector<Array> sorted_allowed;
	for (int i : order) {
		sorted.push_back(brain.behaviours[i]);
		sorted_allowed.push_back(allowed[i]);
	}
	brain.behaviours = sorted;
	// The state masks: [0] for any state no behaviour names, then one per named state.
	brain.state_masks.push_back(0);
	for (size_t slot = 0; slot < brain.behaviours.size(); ++slot) {
		const uint64_t bit = uint64_t(1) << slot;
		if (brain.behaviours[slot].needs_target) {
			brain.needs_target_mask |= bit;
		}
		if (brain.behaviours[slot].presses_action) {
			brain.presses_action_mask |= bit;
		}
		const Array &states = sorted_allowed[slot];
		if (states.is_empty()) {
			for (int64_t &mask : brain.state_masks) {
				mask = int64_t(uint64_t(mask) | bit); // allowed everywhere, so in every mask, including ones added later (below)
			}
			continue;
		}
		for (int64_t i = 0; i < states.size(); ++i) {
			const StringName state = StringName(String(states[i]));
			size_t index = 0;
			while (index < brain.state_names.size() && brain.state_names[index] != state) {
				++index;
			}
			if (index == brain.state_names.size()) {
				brain.state_names.push_back(state);
				brain.state_masks.push_back(brain.state_masks[0]); // starts with the ones allowed everywhere so far
			}
			brain.state_masks[index + 1] = int64_t(uint64_t(brain.state_masks[index + 1]) | bit);
		}
	}
	// A behaviour allowed everywhere that came before a state was first named is already in that state's mask (copied from [0]);
	// one that comes after is added to every mask above. Either way, every mask holds every behaviour with no allowed_states.
	_brains.push_back(brain);
	_stride = std::max(_stride, int(brain.behaviours.size()));
	return int(_brains.size()) - 1;
}

int AIBatchDecider::get_brain_count() const {
	return int(_brains.size());
}

int AIBatchDecider::get_behaviour_count(int brain) const {
	ERR_FAIL_INDEX_V(brain, int(_brains.size()), 0);
	return int(_brains[brain].behaviours.size());
}

int AIBatchDecider::find_behaviour(int brain, const StringName &name) const {
	ERR_FAIL_INDEX_V(brain, int(_brains.size()), -1);
	const std::vector<Behaviour> &list = _brains[brain].behaviours;
	for (size_t i = 0; i < list.size(); ++i) {
		if (list[i].name == name) {
			return int(i);
		}
	}
	return -1;
}

StringName AIBatchDecider::get_behaviour_name(int brain, int slot) const {
	ERR_FAIL_INDEX_V(brain, int(_brains.size()), StringName());
	ERR_FAIL_INDEX_V(slot, int(_brains[brain].behaviours.size()), StringName());
	return _brains[brain].behaviours[slot].name;
}

int AIBatchDecider::find_state(int brain, const StringName &state) const {
	ERR_FAIL_INDEX_V(brain, int(_brains.size()), 0);
	const std::vector<StringName> &names = _brains[brain].state_names;
	for (size_t i = 0; i < names.size(); ++i) {
		if (names[i] == state) {
			return int(i) + 1;
		}
	}
	return 0;
}

int AIBatchDecider::get_stride() const {
	return _stride;
}

bool AIBatchDecider::is_available(const Brain &brain, int slot, const RowView &row, uint64_t &asked, uint64_t &answers, uint64_t &unknown) const {
	const uint64_t bit = uint64_t(1) << slot;
	if (asked & bit) {
		return (answers & bit) != 0;
	}
	asked |= bit;
	bool available = false;
	switch (brain.behaviours[slot].scorer) {
		case Scorer::GIVEN:
			if (uint64_t(row.available_known) & bit) {
				available = (uint64_t(row.available) & bit) != 0;
			} else {
				unknown |= bit; // GDScript never answered for this one: counted as not available, and reported
			}
			break;
	}
	if (available) {
		answers |= bit;
	}
	return available;
}

double AIBatchDecider::score(const Brain &brain, int slot, const RowView &row) const {
	switch (brain.behaviours[slot].scorer) {
		case Scorer::GIVEN:
			if (row.scores && !std::isnan(row.scores[slot])) {
				return row.scores[slot];
			}
			break;
	}
	return brain.behaviours[slot].max_score; // AIBehaviourBase.score()'s default
}

Dictionary AIBatchDecider::decide(const Dictionary &columns) {
	Dictionary result;
	PackedInt32Array brains_holder;
	const Variant brain_column = columns.get("brain", Variant());
	if (brain_column.get_type() != Variant::PACKED_INT32_ARRAY) {
		UtilityFunctions::push_error("AIBatchDecider.decide: the column \"brain\" is missing or the wrong type.");
		return result;
	}
	brains_holder = brain_column;
	const int64_t rows = brains_holder.size();
	const int64_t flat = rows * _stride;
	PackedInt64Array pawn_h, seed_h, tick_h, started_h, cooling_h, press_h, known_h, avail_h;
	PackedInt32Array state_h, priority_h, running_h;
	PackedByteArray target_h, normal_h;
	PackedFloat64Array persistence_h, score_h;
	const auto *pawn = column(columns, "pawn_number", Variant::PACKED_INT64_ARRAY, rows, pawn_h);
	const auto *seed = column(columns, "random_seed", Variant::PACKED_INT64_ARRAY, rows, seed_h);
	const auto *tick = column(columns, "tick", Variant::PACKED_INT64_ARRAY, rows, tick_h);
	const auto *state = column(columns, "state", Variant::PACKED_INT32_ARRAY, rows, state_h);
	const auto *has_target = column(columns, "has_target", Variant::PACKED_BYTE_ARRAY, rows, target_h);
	const auto *normal = column(columns, "event_normal", Variant::PACKED_BYTE_ARRAY, rows, normal_h);
	const auto *priority = column(columns, "event_priority", Variant::PACKED_INT32_ARRAY, rows, priority_h);
	const auto *running = column(columns, "running", Variant::PACKED_INT32_ARRAY, rows, running_h);
	const auto *started = column(columns, "running_started", Variant::PACKED_INT64_ARRAY, rows, started_h);
	const auto *cooling = column(columns, "cooling", Variant::PACKED_INT64_ARRAY, rows, cooling_h);
	const auto *can_press = column(columns, "can_press", Variant::PACKED_INT64_ARRAY, rows, press_h);
	const auto *known = column(columns, "available_known", Variant::PACKED_INT64_ARRAY, rows, known_h);
	const auto *available = column(columns, "available", Variant::PACKED_INT64_ARRAY, rows, avail_h);
	const auto *persistence = column(columns, "persistence", Variant::PACKED_FLOAT64_ARRAY, flat, persistence_h);
	const auto *scores = column(columns, "score", Variant::PACKED_FLOAT64_ARRAY, flat, score_h, false);
	if (!pawn || !seed || !tick || !state || !has_target || !normal || !priority || !running || !started || !cooling || !can_press ||
			!known || !available || !persistence) {
		return result;
	}
	if (columns.has("score") && !scores) {
		return result; // there, but wrong: column() said why
	}
	PackedInt32Array chosen_out;
	PackedByteArray kept_out;
	PackedInt64Array asked_out, unknown_out;
	chosen_out.resize(rows);
	kept_out.resize(rows);
	asked_out.resize(rows);
	unknown_out.resize(rows);
	// Raw pointers, read once: the Packed arrays' operator[] goes through a bounds check each time.
	const int32_t *brain_of = brains_holder.ptr();
	const double *persistence_of = persistence->ptr();
	const double *score_of = scores ? scores->ptr() : nullptr;

	for (int64_t r = 0; r < rows; ++r) {
		chosen_out.set(r, -1);
		kept_out.set(r, 0);
		asked_out.set(r, 0);
		unknown_out.set(r, 0);
		const int b = brain_of[r];
		if (b < 0 || b >= int(_brains.size())) {
			UtilityFunctions::push_error(vformat("AIBatchDecider.decide: row %d names brain %d, which doesn't exist.", r, b));
			continue;
		}
		const Brain &brain = _brains[b];
		const int count = int(brain.behaviours.size());
		const int run = (*running)[r];
		const int64_t now = (*tick)[r];
		const int64_t event_priority = (*priority)[r];
		const bool event_is_normal = (*normal)[r] != 0;
		if (count == 0) {
			chosen_out.set(r, run); // the manager does nothing with no behaviours
			continue;
		}
		const uint64_t run_bit = (run >= 0 && run < count) ? (uint64_t(1) << run) : 0;
		// 0. Interrupts (AIBehaviourManager._can_replace_running).
		if (run_bit) {
			const Behaviour &running_one = brain.behaviours[run];
			const bool keep = running_one.cannot_be_interrupted || event_priority < running_one.interrupt_threshold ||
					(event_is_normal && running_one.min_run_ticks > 0 && now - (*started)[r] < running_one.min_run_ticks);
			if (keep) {
				chosen_out.set(r, run);
				kept_out.set(r, 1);
				continue;
			}
		}
		// 1 and 2. Valid behaviours and the hard rules, as masks: allowed in the state; not cooling down (the running one excepted);
		// a target if it needs one; its action can start (the running one excepted, having pressed it already).
		const int state_number = (*state)[r];
		const uint64_t allowed = (state_number >= 0 && state_number < int(brain.state_masks.size())) ? uint64_t(brain.state_masks[state_number])
																									 : uint64_t(brain.state_masks[0]);
		uint64_t candidates = allowed;
		candidates &= ~(uint64_t((*cooling)[r]) & ~run_bit);
		if ((*has_target)[r] == 0) {
			candidates &= ~brain.needs_target_mask;
		}
		candidates &= ~(brain.presses_action_mask & ~uint64_t((*can_press)[r]) & ~run_bit);
		// 3. Each candidate's range, in the fixed order.
		const RowView view{ (*known)[r], (*available)[r], score_of ? score_of + r * _stride : nullptr };
		const int64_t pawn_number = (*pawn)[r];
		const int64_t random_seed = (*seed)[r];
		_candidates.clear();
		for (int slot = 0; slot < count; ++slot) {
			if (!(candidates & (uint64_t(1) << slot))) {
				continue;
			}
			const Behaviour &behaviour = brain.behaviours[slot];
			Candidate c;
			c.slot = slot;
			c.persistence = persistence_of[r * _stride + slot];
			c.jitter = behaviour.jitter > 0.0 ? behaviour.jitter * (random_unit_at(random_seed, pawn_number, now, behaviour.name_hash) * 2.0 - 1.0) : 0.0;
			c.ceiling = behaviour.max_score + c.persistence + behaviour.jitter;
			c.has_floor = behaviour.has_min_score;
			c.floor = c.has_floor ? behaviour.min_score + c.persistence - behaviour.jitter : NEG_INF;
			_candidates.push_back(c);
		}
		uint64_t asked = 0;
		uint64_t answers = 0;
		uint64_t unknown = 0;
		// 3, continued. The highest floor, from the first available behaviour, highest floor first.
		double highest_floor = NEG_INF;
		std::sort(_candidates.begin(), _candidates.end(), [](const Candidate &a, const Candidate &b) {
			return a.floor > b.floor || (a.floor == b.floor && a.slot < b.slot);
		});
		for (const Candidate &c : _candidates) {
			if (c.floor == NEG_INF) {
				break;
			}
			if (is_available(brain, c.slot, view, asked, answers, unknown)) {
				highest_floor = c.floor;
				break;
			}
		}
		// 4. Scoring, highest ceiling first, with the early stop.
		std::sort(_candidates.begin(), _candidates.end(), [](const Candidate &a, const Candidate &b) {
			return a.ceiling > b.ceiling || (a.ceiling == b.ceiling && a.slot < b.slot);
		});
		int best = -1;
		double best_result = NEG_INF;
		_ties.clear();
		for (const Candidate &c : _candidates) {
			if (c.ceiling < highest_floor) {
				continue;
			}
			if (best >= 0 && c.ceiling < best_result - brain.tie_margin) {
				break;
			}
			if (!is_available(brain, c.slot, view, asked, answers, unknown)) {
				continue;
			}
			const double result_now = score(brain, c.slot, view) + c.persistence + c.jitter;
			if (best < 0 || result_now > best_result + brain.tie_margin) {
				best = c.slot;
				best_result = result_now;
				_ties.clear();
				_ties.push_back(c.slot);
			} else if (result_now >= best_result - brain.tie_margin) {
				_ties.push_back(c.slot);
			}
		}
		// 6. Ties: the fixed order, or a replayable random pick.
		if (_ties.size() > 1) {
			std::sort(_ties.begin(), _ties.end());
			if (brain.randomize_ties) {
				const int size = int(_ties.size());
				const int pick = std::min(int(random_unit_at(random_seed, pawn_number, now, brain.tie_salt) * size), size - 1);
				best = _ties[pick];
			} else {
				best = _ties[0];
			}
		}
		chosen_out.set(r, best);
		asked_out.set(r, int64_t(asked));
		unknown_out.set(r, int64_t(unknown));
	}
	result["chosen"] = chosen_out;
	result["kept"] = kept_out;
	result["asked"] = asked_out;
	result["unknown"] = unknown_out;
	return result;
}

void AIBatchDecider::_bind_methods() {
	ClassDB::bind_method(D_METHOD("add_brain", "description"), &AIBatchDecider::add_brain);
	ClassDB::bind_method(D_METHOD("get_brain_count"), &AIBatchDecider::get_brain_count);
	ClassDB::bind_method(D_METHOD("get_behaviour_count", "brain"), &AIBatchDecider::get_behaviour_count);
	ClassDB::bind_method(D_METHOD("find_behaviour", "brain", "name"), &AIBatchDecider::find_behaviour);
	ClassDB::bind_method(D_METHOD("get_behaviour_name", "brain", "slot"), &AIBatchDecider::get_behaviour_name);
	ClassDB::bind_method(D_METHOD("find_state", "brain", "state"), &AIBatchDecider::find_state);
	ClassDB::bind_method(D_METHOD("get_stride"), &AIBatchDecider::get_stride);
	ClassDB::bind_method(D_METHOD("decide", "columns"), &AIBatchDecider::decide);
	ClassDB::bind_method(D_METHOD("random_unit", "seed", "pawn_number", "tick", "salt"), &AIBatchDecider::random_unit);
}
