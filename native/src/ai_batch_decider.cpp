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
	if (name == "conditions") {
		scorer = 1; // Scorer::CONDITIONS
		return true;
	}
	return false;
}

// An input's value in a row, or 0 past the row's end, as AIInputs.value() reads 0 for a slot never written.
inline double input_at(const double *inputs, int64_t count, int slot) {
	return (inputs && slot >= 0 && slot < count) ? inputs[slot] : 0.0;
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
		behaviour.cooldown_ticks = int64_t(entry.get("cooldown_ticks_at_rate", entry.get("cooldown_ticks", 0)));
		behaviour.persistence = double(entry.get("persistence", 0.0));
		const Variant fade = entry.get("persistence_fade", Variant());
		if (fade.get_type() == Variant::DICTIONARY) {
			// Already at the match's rate (AIBehaviourManager.describe()).
			const Dictionary f = fade;
			fade_math::read_values(behaviour.persistence_fade, int(f.get("mode", 0)), int64_t(f.get("hold", 0)), int64_t(f.get("fade", 60)),
					int64_t(f.get("half_life", 30)), f.get("curve", Variant()));
			behaviour.has_persistence_fade = true;
		}
		if (!add_conditions(entry.get("conditions", Array()), brain, behaviour.first_condition, behaviour.condition_count)) {
			return -1;
		}
		const Array curves = entry.get("score_curves", Array());
		behaviour.first_curve = int(brain.curves.size());
		behaviour.curve_count = int(curves.size());
		for (int64_t c = 0; c < curves.size(); ++c) {
			const Dictionary described = curves[c];
			Curve curve;
			curve.input_slot = int(described.get("input_slot", -1));
			curve.from = double(described.get("from", 0.0));
			curve.to = double(described.get("to", 1.0));
			brain.curves.push_back(curve);
		}
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

bool AIBatchDecider::add_conditions(const Array &list, Brain &brain, int &first, int &count) {
	// Children first (an "any" condition's own list goes in before it), then this list's conditions next to each other.
	std::vector<Condition> these;
	for (int64_t i = 0; i < list.size(); ++i) {
		const Dictionary described = list[i];
		const String kind = described.get("kind", "always");
		Condition condition;
		if (kind == "always") {
			condition.kind = ConditionKind::ALWAYS;
		} else if (kind == "compare") {
			condition.kind = ConditionKind::COMPARE;
			condition.input_slot = int(described.get("input_slot", -1));
			condition.comparison = int(described.get("comparison", 0));
			condition.value = double(described.get("value", 0.0));
			condition.other_slot = int(described.get("other_slot", -1));
		} else if (kind == "chance") {
			condition.kind = ConditionKind::CHANCE;
			condition.chance = double(described.get("chance", 0.0));
			condition.salt = int64_t(described.get("salt", 0));
			condition.key_slot = int(described.get("key_slot", -1));
			condition.salt_slot = int(described.get("salt_slot", -1));
		} else if (kind == "any") {
			condition.kind = ConditionKind::ANY;
			if (!add_conditions(described.get("conditions", Array()), brain, condition.first_child, condition.child_count)) {
				return false;
			}
		} else {
			UtilityFunctions::push_error("AIBatchDecider.add_brain: no condition kind called \"" + kind + "\".");
			return false;
		}
		these.push_back(condition);
	}
	first = int(brain.conditions.size());
	count = int(these.size());
	brain.conditions.insert(brain.conditions.end(), these.begin(), these.end());
	return true;
}

bool AIBatchDecider::passes(const Brain &brain, const Condition &condition, const RowView &row, int64_t behaviour_salt) const {
	switch (condition.kind) {
		case ConditionKind::ALWAYS:
			return true;
		case ConditionKind::COMPARE: {
			// AICompareCondition.passes, the same arithmetic.
			const double left = input_at(row.inputs, row.input_count, condition.input_slot);
			double right = condition.value;
			if (condition.other_slot >= 0) {
				right += input_at(row.inputs, row.input_count, condition.other_slot);
			}
			switch (condition.comparison) {
				case 0:
					return left <= right;
				case 1:
					return left < right;
				case 2:
					return left >= right;
				case 3:
					return left > right;
				case 4:
					return left == right;
				default:
					return left != right;
			}
		}
		case ConditionKind::CHANCE: {
			// AIChanceCondition: roll_tick and roll_salt, then the context's random_unit_at. A double to int64 truncates toward 0,
			// as GDScript's int() does.
			const int64_t roll_tick = condition.key_slot >= 0 ? int64_t(input_at(row.inputs, row.input_count, condition.key_slot)) : row.tick;
			int64_t salt = condition.salt ^ behaviour_salt;
			if (condition.salt_slot >= 0) {
				salt ^= int64_t(input_at(row.inputs, row.input_count, condition.salt_slot)) & 0xFFFF;
			}
			return random_unit_at(row.random_seed, row.pawn_number, roll_tick, salt) < condition.chance;
		}
		case ConditionKind::ANY:
			for (int i = 0; i < condition.child_count; ++i) {
				if (passes(brain, brain.conditions[condition.first_child + i], row, behaviour_salt)) {
					return true;
				}
			}
			return false;
	}
	return true;
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
		case Scorer::CONDITIONS: {
			// AIBehaviourBase.is_available(): every condition passes, checked in order, stopping at the first that doesn't.
			const Behaviour &behaviour = brain.behaviours[slot];
			available = true;
			for (int i = 0; i < behaviour.condition_count; ++i) {
				if (!passes(brain, brain.conditions[behaviour.first_condition + i], row, behaviour.name_hash)) {
					available = false;
					break;
				}
			}
			break;
		}
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
		case Scorer::CONDITIONS: {
			// AIBehaviourBase.score(): max_score, scaled by the curves, in the same order with the same arithmetic.
			const Behaviour &behaviour = brain.behaviours[slot];
			if (behaviour.curve_count == 0) {
				break;
			}
			double amount = 1.0;
			for (int i = 0; i < behaviour.curve_count; ++i) {
				const Curve &curve = brain.curves[behaviour.first_curve + i];
				const double value = input_at(row.inputs, row.input_count, curve.input_slot);
				double part;
				if (curve.to == curve.from) {
					part = value >= curve.to ? 1.0 : 0.0;
				} else {
					part = std::clamp((value - curve.from) / (curve.to - curve.from), 0.0, 1.0);
				}
				amount *= part;
			}
			const double low = behaviour.has_min_score ? behaviour.min_score : 0.0;
			return low + (behaviour.max_score - low) * amount;
		}
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
	// The AI inputs, optional: rows * input_stride values.
	const int64_t input_stride = int64_t(columns.get("input_stride", 0));
	PackedFloat64Array inputs_h;
	const auto *inputs = input_stride > 0 ? column(columns, "inputs", Variant::PACKED_FLOAT64_ARRAY, rows * input_stride, inputs_h) : nullptr;
	if (input_stride > 0 && !inputs) {
		return result; // column() said why
	}
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
	const double *inputs_of = inputs ? inputs->ptr() : nullptr;

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
		RowInput in;
		in.running = (*running)[r];
		in.running_started = (*started)[r];
		in.now = (*tick)[r];
		in.event_priority = (*priority)[r];
		in.event_normal = (*normal)[r] != 0;
		in.state = (*state)[r];
		in.has_target = (*has_target)[r] != 0;
		in.cooling = uint64_t((*cooling)[r]);
		in.can_press = uint64_t((*can_press)[r]);
		in.persistence = persistence_of + r * _stride;
		in.view = RowView{ (*known)[r], (*available)[r], score_of ? score_of + r * _stride : nullptr,
			inputs_of ? inputs_of + r * input_stride : nullptr, input_stride, (*seed)[r], (*pawn)[r], in.now };
		const RowResult out = decide_row(_brains[b], in);
		chosen_out.set(r, out.chosen);
		kept_out.set(r, out.kept ? 1 : 0);
		asked_out.set(r, int64_t(out.asked));
		unknown_out.set(r, int64_t(out.unknown));
	}
	result["chosen"] = chosen_out;
	result["kept"] = kept_out;
	result["asked"] = asked_out;
	result["unknown"] = unknown_out;
	return result;
}

AIBatchDecider::RowResult AIBatchDecider::decide_row(const Brain &brain, const RowInput &in) {
	RowResult out;
	const int count = int(brain.behaviours.size());
	const int run = in.running;
	const int64_t now = in.now;
	if (count == 0) {
		out.chosen = run; // the manager does nothing with no behaviours
		return out;
	}
	const uint64_t run_bit = (run >= 0 && run < count) ? (uint64_t(1) << run) : 0;
	// 0. Interrupts (AIBehaviourManager._can_replace_running).
	if (run_bit) {
		const Behaviour &running_one = brain.behaviours[run];
		const int64_t threshold = in.interrupt_threshold ? in.interrupt_threshold[run] : running_one.interrupt_threshold;
		const bool keep = running_one.cannot_be_interrupted || in.event_priority < threshold ||
				(in.event_normal && running_one.min_run_ticks > 0 && now - in.running_started < running_one.min_run_ticks);
		if (keep) {
			out.chosen = run;
			out.kept = true;
			return out;
		}
	}
	// 1 and 2. Valid behaviours and the hard rules, as masks: allowed in the state; not cooling down (the running one excepted);
	// a target if it needs one; its action can start (the running one excepted, having pressed it already).
	const uint64_t allowed = (in.state >= 0 && in.state < int(brain.state_masks.size())) ? uint64_t(brain.state_masks[in.state])
																						  : uint64_t(brain.state_masks[0]);
	uint64_t candidates = allowed;
	candidates &= ~(in.cooling & ~run_bit);
	if (!in.has_target) {
		candidates &= ~brain.needs_target_mask;
	}
	candidates &= ~(brain.presses_action_mask & ~in.can_press & ~run_bit);
	// 3. Each candidate's range, in the fixed order.
	const RowView &view = in.view;
	_candidates.clear();
	for (int slot = 0; slot < count; ++slot) {
		if (!(candidates & (uint64_t(1) << slot))) {
			continue;
		}
		const Behaviour &behaviour = brain.behaviours[slot];
		const double jitter = in.jitter ? in.jitter[slot] : behaviour.jitter;
		Candidate c;
		c.slot = slot;
		c.persistence = in.persistence[slot];
		c.jitter = jitter > 0.0 ? jitter * (random_unit_at(view.random_seed, view.pawn_number, now, behaviour.name_hash) * 2.0 - 1.0) : 0.0;
		c.ceiling = behaviour.max_score + c.persistence + jitter;
		c.has_floor = behaviour.has_min_score;
		c.floor = c.has_floor ? behaviour.min_score + c.persistence - jitter : NEG_INF;
		_candidates.push_back(c);
	}
	uint64_t answers = 0;
	// 3, continued. The highest floor, from the first available behaviour, highest floor first.
	double highest_floor = NEG_INF;
	std::sort(_candidates.begin(), _candidates.end(), [](const Candidate &a, const Candidate &b) {
		return a.floor > b.floor || (a.floor == b.floor && a.slot < b.slot);
	});
	for (const Candidate &c : _candidates) {
		if (c.floor == NEG_INF) {
			break;
		}
		if (is_available(brain, c.slot, view, out.asked, answers, out.unknown)) {
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
		if (!is_available(brain, c.slot, view, out.asked, answers, out.unknown)) {
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
			const int pick = std::min(int(random_unit_at(view.random_seed, view.pawn_number, now, brain.tie_salt) * size), size - 1);
			best = _ties[pick];
		} else {
			best = _ties[0];
		}
	}
	out.chosen = best;
	return out;
}

// --- Pawns ---

int AIBatchDecider::add_pawn(int64_t id, int brain, int64_t pawn_number, int64_t random_seed) {
	if (brain < 0 || brain >= int(_brains.size())) {
		UtilityFunctions::push_error(vformat("AIBatchDecider.add_pawn: brain %d doesn't exist.", brain));
		return -1;
	}
	int row = find_pawn(id);
	if (row < 0) {
		if (!_free_rows.empty()) {
			row = _free_rows.back();
			_free_rows.pop_back();
		} else {
			row = int(_pawns.size());
			_pawns.emplace_back();
		}
		_row_of_id[id] = row;
	}
	const Brain &b = _brains[brain];
	const size_t count = b.behaviours.size();
	PawnRow &p = _pawns[row];
	p = PawnRow();
	p.id = id;
	p.brain = brain;
	p.pawn_number = pawn_number;
	p.random_seed = random_seed;
	p.ended.assign(count, -1);
	p.persistence_running.assign(count, 0);
	p.persistence_along.assign(count, 0.0);
	p.persistence_changed.assign(count, 0);
	p.persistence_speed.assign(count, 1.0);
	p.jitter.resize(count);
	p.interrupt_threshold.resize(count);
	for (size_t i = 0; i < count; ++i) {
		p.jitter[i] = b.behaviours[i].jitter;
		p.interrupt_threshold[i] = b.behaviours[i].interrupt_threshold;
	}
	return row;
}

void AIBatchDecider::remove_pawn(int64_t id) {
	const auto found = _row_of_id.find(id);
	if (found == _row_of_id.end()) {
		return;
	}
	_pawns[found->second] = PawnRow(); // brain -1: free
	_free_rows.push_back(found->second);
	_row_of_id.erase(found);
}

int AIBatchDecider::find_pawn(int64_t id) const {
	const auto found = _row_of_id.find(id);
	return found == _row_of_id.end() ? -1 : found->second;
}

int AIBatchDecider::get_pawn_count() const {
	return int(_row_of_id.size());
}

bool AIBatchDecider::row_ok(int row) const {
	return row >= 0 && row < int(_pawns.size()) && _pawns[row].brain >= 0;
}

void AIBatchDecider::set_pawn_state(int row, int running, int64_t running_started, const PackedInt64Array &ended_ticks,
		const PackedFloat64Array &persistence) {
	ERR_FAIL_COND_MSG(!row_ok(row), "AIBatchDecider.set_pawn_state: no pawn in that row.");
	PawnRow &p = _pawns[row];
	const int64_t count = int64_t(p.ended.size());
	ERR_FAIL_COND_MSG(ended_ticks.size() != count || persistence.size() != count * 4, "AIBatchDecider.set_pawn_state: wrong lengths for the brain.");
	p.running = running;
	p.running_started = running_started;
	for (int64_t i = 0; i < count; ++i) {
		p.ended[i] = ended_ticks[i];
		p.persistence_running[i] = persistence[i * 4] != 0.0 ? 1 : 0;
		p.persistence_along[i] = persistence[i * 4 + 1];
		p.persistence_changed[i] = int64_t(persistence[i * 4 + 2]);
		p.persistence_speed[i] = persistence[i * 4 + 3];
	}
}

Dictionary AIBatchDecider::get_pawn_state(int row) const {
	Dictionary state;
	ERR_FAIL_COND_V_MSG(!row_ok(row), state, "AIBatchDecider.get_pawn_state: no pawn in that row.");
	const PawnRow &p = _pawns[row];
	PackedInt64Array ended;
	PackedFloat64Array persistence;
	for (size_t i = 0; i < p.ended.size(); ++i) {
		ended.push_back(p.ended[i]);
		persistence.push_back(p.persistence_running[i] ? 1.0 : 0.0);
		persistence.push_back(p.persistence_along[i]);
		persistence.push_back(double(p.persistence_changed[i]));
		persistence.push_back(p.persistence_speed[i]);
	}
	state["running"] = p.running;
	state["running_started"] = p.running_started;
	state["ended"] = ended;
	state["persistence"] = persistence;
	return state;
}

void AIBatchDecider::stop_running(int row, int64_t tick) {
	ERR_FAIL_COND(!row_ok(row));
	PawnRow &p = _pawns[row];
	if (p.running >= 0) {
		p.ended[p.running] = tick;
		p.running = -1;
	}
}

// AIBehaviourBase._persistence_ticks_along: how far along its fade, from the three numbers.
static double ticks_along(double along, int64_t changed, double speed, int64_t tick) {
	return along + double(tick - changed) * speed;
}

void AIBatchDecider::add_persistence_ticks(int row, int slot, double ticks, int64_t tick) {
	ERR_FAIL_COND(!row_ok(row));
	PawnRow &p = _pawns[row];
	ERR_FAIL_INDEX(slot, int(p.ended.size()));
	if (!p.persistence_running[slot]) {
		return;
	}
	p.persistence_along[slot] = std::max(0.0, ticks_along(p.persistence_along[slot], p.persistence_changed[slot], p.persistence_speed[slot], tick) - ticks);
	p.persistence_changed[slot] = tick;
}

void AIBatchDecider::set_persistence_speed(int row, int slot, double speed, int64_t tick) {
	ERR_FAIL_COND(!row_ok(row));
	PawnRow &p = _pawns[row];
	ERR_FAIL_INDEX(slot, int(p.ended.size()));
	p.persistence_along[slot] = ticks_along(p.persistence_along[slot], p.persistence_changed[slot], p.persistence_speed[slot], tick);
	p.persistence_changed[slot] = tick;
	p.persistence_speed[slot] = std::max(0.0, speed);
}

void AIBatchDecider::set_score_jitter(int row, int slot, double effective_jitter) {
	ERR_FAIL_COND(!row_ok(row));
	ERR_FAIL_INDEX(slot, int(_pawns[row].jitter.size()));
	_pawns[row].jitter[slot] = effective_jitter;
}

void AIBatchDecider::set_interrupt_threshold(int row, int slot, int64_t threshold) {
	ERR_FAIL_COND(!row_ok(row));
	ERR_FAIL_INDEX(slot, int(_pawns[row].interrupt_threshold.size()));
	_pawns[row].interrupt_threshold[slot] = threshold;
}

double AIBatchDecider::persistence_now(int row, int slot, int64_t tick) const {
	ERR_FAIL_COND_V(!row_ok(row), 0.0);
	const PawnRow &p = _pawns[row];
	ERR_FAIL_INDEX_V(slot, int(p.ended.size()), 0.0);
	const Behaviour &behaviour = _brains[p.brain].behaviours[slot];
	// AIBehaviourBase.persistence_now: nothing unless it started, has an amount, and has a fade.
	if (!p.persistence_running[slot] || behaviour.persistence == 0.0 || !behaviour.has_persistence_fade) {
		return 0.0;
	}
	return behaviour.persistence *
			fade_math::value_at(behaviour.persistence_fade, ticks_along(p.persistence_along[slot], p.persistence_changed[slot], p.persistence_speed[slot], tick));
}

int AIBatchDecider::decide_pawn(int row, int64_t tick, int state, bool has_target, int64_t event_priority, bool event_normal,
		int64_t can_press, const PackedFloat64Array &inputs) {
	_last_kept = false;
	ERR_FAIL_COND_V_MSG(!row_ok(row), -1, "AIBatchDecider.decide_pawn: no pawn in that row.");
	PawnRow &p = _pawns[row];
	const Brain &brain = _brains[p.brain];
	const int count = int(brain.behaviours.size());
	// The hard rule's cooldowns (AIBehaviourBase.is_cooling_down) and each behaviour's persistence now.
	uint64_t cooling = 0;
	_persistence_scratch.resize(size_t(count));
	for (int slot = 0; slot < count; ++slot) {
		const int64_t cooldown = brain.behaviours[slot].cooldown_ticks;
		if (cooldown > 0 && p.ended[slot] >= 0 && tick - p.ended[slot] < cooldown) {
			cooling |= uint64_t(1) << slot;
		}
		_persistence_scratch[slot] = persistence_now(row, slot, tick);
	}
	RowInput in;
	in.running = p.running;
	in.running_started = p.running_started;
	in.now = tick;
	in.event_priority = event_priority;
	in.event_normal = event_normal;
	in.state = state;
	in.has_target = has_target;
	in.cooling = cooling;
	in.can_press = uint64_t(can_press);
	in.persistence = _persistence_scratch.data();
	in.jitter = p.jitter.data();
	in.interrupt_threshold = p.interrupt_threshold.data();
	in.view = RowView{ 0, 0, nullptr, inputs.ptr(), inputs.size(), p.random_seed, p.pawn_number, tick };
	const RowResult out = decide_row(brain, in);
	_last_kept = out.kept;
	// The switch, as AIBehaviourManager._start and _stop_running apply it: the old one's end, the new one's start and persistence.
	if (out.chosen != p.running) {
		if (p.running >= 0) {
			p.ended[p.running] = tick;
		}
		p.running = out.chosen;
		if (out.chosen >= 0) {
			p.running_started = tick;
			p.persistence_running[out.chosen] = 1;
			p.persistence_along[out.chosen] = 0.0;
			p.persistence_changed[out.chosen] = tick;
			p.persistence_speed[out.chosen] = 1.0;
		}
	}
	return out.chosen;
}

bool AIBatchDecider::was_kept() const {
	return _last_kept;
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
	ClassDB::bind_method(D_METHOD("add_pawn", "id", "brain", "pawn_number", "random_seed"), &AIBatchDecider::add_pawn);
	ClassDB::bind_method(D_METHOD("remove_pawn", "id"), &AIBatchDecider::remove_pawn);
	ClassDB::bind_method(D_METHOD("find_pawn", "id"), &AIBatchDecider::find_pawn);
	ClassDB::bind_method(D_METHOD("get_pawn_count"), &AIBatchDecider::get_pawn_count);
	ClassDB::bind_method(D_METHOD("set_pawn_state", "row", "running", "running_started", "ended_ticks", "persistence"), &AIBatchDecider::set_pawn_state);
	ClassDB::bind_method(D_METHOD("get_pawn_state", "row"), &AIBatchDecider::get_pawn_state);
	ClassDB::bind_method(D_METHOD("stop_running", "row", "tick"), &AIBatchDecider::stop_running);
	ClassDB::bind_method(D_METHOD("add_persistence_ticks", "row", "slot", "ticks", "tick"), &AIBatchDecider::add_persistence_ticks);
	ClassDB::bind_method(D_METHOD("set_persistence_speed", "row", "slot", "speed", "tick"), &AIBatchDecider::set_persistence_speed);
	ClassDB::bind_method(D_METHOD("set_score_jitter", "row", "slot", "effective_jitter"), &AIBatchDecider::set_score_jitter);
	ClassDB::bind_method(D_METHOD("set_interrupt_threshold", "row", "slot", "threshold"), &AIBatchDecider::set_interrupt_threshold);
	ClassDB::bind_method(D_METHOD("persistence_now", "row", "slot", "tick"), &AIBatchDecider::persistence_now);
	ClassDB::bind_method(D_METHOD("decide_pawn", "row", "tick", "state", "has_target", "event_priority", "event_normal", "can_press", "inputs"),
			&AIBatchDecider::decide_pawn);
	ClassDB::bind_method(D_METHOD("was_kept"), &AIBatchDecider::was_kept);
}
