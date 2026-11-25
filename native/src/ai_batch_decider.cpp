// Written by Claude (claude-opus-5-5), 2026-11-17. History: native/CHANGELOG.md.
// AIBatchDecider: AI behaviour decisions for many pawns in one call. Described in ai_batch_decider.h. Every step follows
// AIBehaviourManager.decide() (assets/scripts/ai/AIBehaviourManager.gd) exactly, in the same order with the same arithmetic, so the
// two agree to the bit: a change to one goes in both, and ai_batch_decider_selftest compares them.
#include "ai_batch_decider.h"
#include "deterministic_random.h"
#include "ai_memory_store.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/classes/node3d.hpp>
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
	return deterministic_random::unit(seed, pawn_number, tick, salt);
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
		// Switched off (enabled false): a gate nothing passes.
		if (!bool(entry.get("enabled", true))) {
			behaviour.has_gate = true;
			behaviour.gate_impossible = true;
		}
		const Variant gate = entry.get("tag_requirements", Variant());
		if (gate.get_type() == Variant::DICTIONARY) {
			const Dictionary g = gate;
			const PackedInt64Array all = g.get("all", PackedInt64Array());
			const PackedInt64Array any = g.get("any", PackedInt64Array());
			const PackedInt64Array none = g.get("none", PackedInt64Array());
			behaviour.has_gate = true;
			behaviour.gate_impossible = behaviour.gate_impossible || bool(g.get("impossible", false)); // switched off stays off
			for (int64_t w = 0; w < all.size(); ++w) {
				behaviour.gate_all.push_back(uint64_t(all[w]));
				behaviour.gate_any.push_back(w < any.size() ? uint64_t(any[w]) : 0);
				behaviour.gate_none.push_back(w < none.size() ? uint64_t(none[w]) : 0);
				behaviour.gate_needs_any = behaviour.gate_needs_any || (w < any.size() && any[w] != 0);
			}
		}
		brain.behaviours.push_back(behaviour);
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
	for (int i : order) {
		sorted.push_back(brain.behaviours[i]);
	}
	brain.behaviours = sorted;
	for (size_t slot = 0; slot < brain.behaviours.size(); ++slot) {
		const uint64_t bit = uint64_t(1) << slot;
		if (brain.behaviours[slot].needs_target) {
			brain.needs_target_mask |= bit;
		}
		if (brain.behaviours[slot].presses_action) {
			brain.presses_action_mask |= bit;
		}
		if (brain.behaviours[slot].has_gate) {
			brain.gated_mask |= bit;
		}
	}
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

bool AIBatchDecider::passes_gate(const Behaviour &behaviour, const uint64_t *owned, int64_t owned_count) {
	if (!behaviour.has_gate) {
		return true;
	}
	if (behaviour.gate_impossible) {
		return false;
	}
	bool any_hit = !behaviour.gate_needs_any;
	for (size_t i = 0; i < behaviour.gate_all.size(); ++i) {
		const uint64_t word = int64_t(i) < owned_count ? owned[i] : 0;
		if ((word & behaviour.gate_all[i]) != behaviour.gate_all[i] || (word & behaviour.gate_none[i]) != 0) {
			return false;
		}
		if (word & behaviour.gate_any[i]) {
			any_hit = true;
		}
	}
	return any_hit;
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
	PackedInt32Array priority_h, running_h;
	PackedByteArray target_h, normal_h;
	PackedFloat64Array score_h;
	const auto *pawn = column(columns, "pawn_number", Variant::PACKED_INT64_ARRAY, rows, pawn_h);
	const auto *seed = column(columns, "random_seed", Variant::PACKED_INT64_ARRAY, rows, seed_h);
	const auto *tick = column(columns, "tick", Variant::PACKED_INT64_ARRAY, rows, tick_h);
	const auto *has_target = column(columns, "has_target", Variant::PACKED_BYTE_ARRAY, rows, target_h);
	const auto *normal = column(columns, "event_normal", Variant::PACKED_BYTE_ARRAY, rows, normal_h);
	const auto *priority = column(columns, "event_priority", Variant::PACKED_INT32_ARRAY, rows, priority_h);
	const auto *running = column(columns, "running", Variant::PACKED_INT32_ARRAY, rows, running_h);
	const auto *started = column(columns, "running_started", Variant::PACKED_INT64_ARRAY, rows, started_h);
	const auto *cooling = column(columns, "cooling", Variant::PACKED_INT64_ARRAY, rows, cooling_h);
	const auto *can_press = column(columns, "can_press", Variant::PACKED_INT64_ARRAY, rows, press_h);
	const auto *known = column(columns, "available_known", Variant::PACKED_INT64_ARRAY, rows, known_h);
	const auto *available = column(columns, "available", Variant::PACKED_INT64_ARRAY, rows, avail_h);
	const auto *scores = column(columns, "score", Variant::PACKED_FLOAT64_ARRAY, flat, score_h, false);
	// The AI inputs, optional: rows * input_stride values.
	const int64_t input_stride = int64_t(columns.get("input_stride", 0));
	PackedFloat64Array inputs_h;
	const auto *inputs = input_stride > 0 ? column(columns, "inputs", Variant::PACKED_FLOAT64_ARRAY, rows * input_stride, inputs_h) : nullptr;
	if (input_stride > 0 && !inputs) {
		return result; // column() said why
	}
	// The owned tags (rows * tag_words), the numbers the modifiers leave (rows * stride each) and the blocks: all optional.
	const int64_t tag_words = int64_t(columns.get("tag_words", 0));
	PackedInt64Array owned_h, blocked_h, threshold_h, min_run_h;
	PackedFloat64Array modifier_h, jitter_h;
	const auto *owned = tag_words > 0 ? column(columns, "owned", Variant::PACKED_INT64_ARRAY, rows * tag_words, owned_h) : nullptr;
	const auto *modifiers = columns.has("modifier") ? column(columns, "modifier", Variant::PACKED_FLOAT64_ARRAY, flat, modifier_h) : nullptr;
	const auto *jitters = columns.has("jitter") ? column(columns, "jitter", Variant::PACKED_FLOAT64_ARRAY, flat, jitter_h) : nullptr;
	const auto *thresholds = columns.has("interrupt_threshold") ? column(columns, "interrupt_threshold", Variant::PACKED_INT64_ARRAY, flat, threshold_h) : nullptr;
	const auto *min_runs = columns.has("min_run") ? column(columns, "min_run", Variant::PACKED_INT64_ARRAY, flat, min_run_h) : nullptr;
	const auto *blocked = columns.has("blocked") ? column(columns, "blocked", Variant::PACKED_INT64_ARRAY, rows, blocked_h) : nullptr;
	if ((tag_words > 0 && !owned) || (columns.has("modifier") && !modifiers) || (columns.has("jitter") && !jitters) ||
			(columns.has("interrupt_threshold") && !thresholds) || (columns.has("min_run") && !min_runs) || (columns.has("blocked") && !blocked)) {
		return result; // column() said why
	}
	if (!pawn || !seed || !tick || !has_target || !normal || !priority || !running || !started || !cooling || !can_press ||
			!known || !available) {
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
	const double *score_of = scores ? scores->ptr() : nullptr;
	const double *inputs_of = inputs ? inputs->ptr() : nullptr;
	const uint64_t *owned_of = owned ? reinterpret_cast<const uint64_t *>(owned->ptr()) : nullptr;
	const double *modifier_of = modifiers ? modifiers->ptr() : nullptr;
	const double *jitter_of = jitters ? jitters->ptr() : nullptr;
	const int64_t *threshold_of = thresholds ? thresholds->ptr() : nullptr;
	const int64_t *min_run_of = min_runs ? min_runs->ptr() : nullptr;

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
		in.owned = owned_of ? owned_of + r * tag_words : nullptr;
		in.owned_count = owned_of ? tag_words : 0;
		in.bonus = modifier_of ? modifier_of + r * _stride : nullptr;
		in.jitter = jitter_of ? jitter_of + r * _stride : nullptr;
		in.interrupt_threshold = threshold_of ? threshold_of + r * _stride : nullptr;
		in.min_run = min_run_of ? min_run_of + r * _stride : nullptr;
		in.blocked = blocked ? uint64_t((*blocked)[r]) : 0;
		in.has_target = (*has_target)[r] != 0;
		in.cooling = uint64_t((*cooling)[r]);
		in.can_press = uint64_t((*can_press)[r]);
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
	// 0. Interrupts (AIBehaviourManager._can_replace_running). One whose tag requirements fail, or that a modifier blocks (_must_go),
	// isn't held by its min_run_ticks; its threshold and cannot_be_interrupted still hold it.
	if (run_bit) {
		const Behaviour &running_one = brain.behaviours[run];
		const int64_t threshold = in.interrupt_threshold ? in.interrupt_threshold[run] : running_one.interrupt_threshold;
		const int64_t min_run = in.min_run ? in.min_run[run] : running_one.min_run_ticks;
		const bool must_go = (in.blocked & run_bit) != 0 || !passes_gate(running_one, in.owned, in.owned_count);
		const bool normal = in.event_normal && !must_go;
		const bool keep = running_one.cannot_be_interrupted || in.event_priority < threshold ||
				(normal && min_run > 0 && now - in.running_started < min_run);
		if (keep) {
			out.chosen = run;
			out.kept = true;
			return out;
		}
	}
	// 1 and 2. Valid behaviours and the hard rules, as masks: tag requirements pass; not blocked; not cooling down (the running one
	// excepted); a target if it needs one; its action can start (the running one excepted, having pressed it already).
	uint64_t candidates = count >= 64 ? ~uint64_t(0) : (uint64_t(1) << count) - 1;
	for (int slot = 0; slot < count; ++slot) {
		if (((brain.gated_mask >> slot) & 1) && !passes_gate(brain.behaviours[slot], in.owned, in.owned_count)) {
			candidates &= ~(uint64_t(1) << slot);
		}
	}
	candidates &= ~in.blocked;
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
		// The modifiers' score bonus, added as GDScript adds it, so the two agree to the bit.
		c.bonus = in.bonus ? in.bonus[slot] : 0.0;
		c.jitter = jitter > 0.0 ? jitter * (random_unit_at(view.random_seed, view.pawn_number, now, behaviour.name_hash) * 2.0 - 1.0) : 0.0;
		c.ceiling = behaviour.max_score + c.bonus + jitter;
		c.has_floor = behaviour.has_min_score;
		c.floor = c.has_floor ? behaviour.min_score + c.bonus - jitter : NEG_INF;
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
		const double result_now = score(brain, c.slot, view) + c.bonus + c.jitter;
		if (best < 0 || result_now > best_result + brain.tie_margin) {
			best = c.slot;
			best_result = result_now;
			_ties.clear();
			_ties.push_back(c.slot);
		} else if (result_now >= best_result - brain.tie_margin) {
			_ties.push_back(c.slot);
		}
	}
	// 5. Ties: the fixed order, or a replayable random pick.
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
	reset_numbers(p, b);
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

void AIBatchDecider::set_pawn_state(int row, int running, int64_t running_started, const PackedInt64Array &ended_ticks) {
	ERR_FAIL_COND_MSG(!row_ok(row), "AIBatchDecider.set_pawn_state: no pawn in that row.");
	PawnRow &p = _pawns[row];
	const int64_t count = int64_t(p.ended.size());
	ERR_FAIL_COND_MSG(ended_ticks.size() != count, "AIBatchDecider.set_pawn_state: wrong length for the brain.");
	p.running = running;
	p.running_started = running_started;
	for (int64_t i = 0; i < count; ++i) {
		p.ended[i] = ended_ticks[i];
	}
}

Dictionary AIBatchDecider::get_pawn_state(int row) const {
	Dictionary state;
	ERR_FAIL_COND_V_MSG(!row_ok(row), state, "AIBatchDecider.get_pawn_state: no pawn in that row.");
	const PawnRow &p = _pawns[row];
	PackedInt64Array ended;
	for (size_t i = 0; i < p.ended.size(); ++i) {
		ended.push_back(p.ended[i]);
	}
	state["running"] = p.running;
	state["running_started"] = p.running_started;
	state["ended"] = ended;
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

// The numbers the modifiers leave, back to the brain's own: no bonus, its jitter, threshold, cooldown and minimum run.
void AIBatchDecider::reset_numbers(PawnRow &p, const Brain &b) {
	const size_t count = b.behaviours.size();
	p.bonus.clear();
	p.jitter.resize(count);
	p.interrupt_threshold.resize(count);
	p.cooldown.resize(count);
	p.min_run.resize(count);
	for (size_t i = 0; i < count; ++i) {
		p.jitter[i] = b.behaviours[i].jitter;
		p.interrupt_threshold[i] = b.behaviours[i].interrupt_threshold;
		p.cooldown[i] = b.behaviours[i].cooldown_ticks;
		p.min_run[i] = b.behaviours[i].min_run_ticks;
	}
}

void AIBatchDecider::set_input_kinds(const PackedInt32Array &kinds) {
	_input_kinds.assign(kinds.ptr(), kinds.ptr() + kinds.size());
}

void AIBatchDecider::note_hit(int row, int64_t tick, int64_t attacker_id) {
	ERR_FAIL_COND(!row_ok(row));
	_pawns[row].last_hit_tick = tick;
	_pawns[row].last_attacker_id = uint64_t(attacker_id);
}

void AIBatchDecider::note_incoming(int row, int64_t attacker_id, int64_t attacker_number, int64_t start_tick, int64_t hit_tick) {
	ERR_FAIL_COND(!row_ok(row));
	PawnRow &p = _pawns[row];
	p.incoming_attacker_id = uint64_t(attacker_id);
	p.incoming_attacker_number = attacker_number;
	p.incoming_start_tick = start_tick;
	p.incoming_hit_tick = hit_tick;
}

namespace {
// AIInputs.Kind, in its order.
enum InputKind : int32_t {
	KEPT = 0,
	TARGET_DISTANCE,
	MOST_AWARE_CERTAIN,
	MOST_AWARE_UNCERTAIN,
	TICKS_SINCE_UNKNOWN_HIT,
	INCOMING_ATTACK,
	INCOMING_ATTACK_TICK,
	INCOMING_ATTACKER,
	GROUP_DISTANCE,
	GROUP_FOUND,
	ACTION_READY,
};
constexpr double FAR = 1.0e12; // AIInputs.FAR

// AIInputs._flat_distance: the same Vector3 arithmetic, so the same float.
double flat_distance(const Vector3 &point, const Vector3 &from) {
	Vector3 offset = point - from;
	offset.y = 0.0;
	return double(offset.length());
}

// is_instance_valid(): the object with this instance id still exists.
Object *alive(uint64_t id) {
	return id != 0 ? ObjectDB::get_instance(id) : nullptr;
}
} // namespace

const double *AIBatchDecider::work_out_inputs(const PawnRow &p, const Vector3 &position, int64_t tick, int64_t &count) {
	count = std::max<int64_t>(int64_t(p.kept_inputs.size()), int64_t(_input_kinds.size()));
	_inputs_scratch.assign(size_t(count), 0.0);
	std::copy(p.kept_inputs.begin(), p.kept_inputs.end(), _inputs_scratch.begin());
	AIMemoryStore *store = Object::cast_to<AIMemoryStore>(p.memory_store.ptr());
	int64_t most_aware = -2; // not looked for yet
	for (size_t slot = 0; store != nullptr && slot < _input_kinds.size(); ++slot) {
		double &value = _inputs_scratch[slot];
		switch (_input_kinds[slot]) {
			case TARGET_DISTANCE: {
				const int64_t index = alive(p.target_id) != nullptr ? store->find_by_id(p.target_id) : -1;
				value = index >= 0 ? flat_distance(store->last_known_position_at(index), position) : FAR;
				break;
			}
			case MOST_AWARE_CERTAIN:
			case MOST_AWARE_UNCERTAIN: {
				if (most_aware == -2) {
					most_aware = store->most_aware_index(position, tick);
				}
				const bool certain = most_aware >= 0 && store->is_certain_at(most_aware);
				const bool wanted = _input_kinds[slot] == MOST_AWARE_CERTAIN ? certain : (most_aware >= 0 && !certain);
				value = wanted ? 1.0 : 0.0;
				break;
			}
			case TICKS_SINCE_UNKNOWN_HIT: {
				// An attacker it remembers is known; one that's gone, or never noticed, isn't.
				const bool known = alive(p.last_attacker_id) != nullptr && store->find_by_id(p.last_attacker_id) >= 0;
				value = (p.last_hit_tick >= 0 && !known) ? double(tick - p.last_hit_tick) : FAR;
				break;
			}
			case INCOMING_ATTACK: {
				// AIManager.has_incoming_attack: not hit yet, and the attacker still there and alive.
				Object *attacker = alive(p.incoming_attacker_id);
				value = (p.incoming_hit_tick >= tick && attacker != nullptr && !bool(attacker->get("dead"))) ? 1.0 : 0.0;
				break;
			}
			case INCOMING_ATTACK_TICK:
				value = double(p.incoming_start_tick);
				break;
			case INCOMING_ATTACKER:
				value = alive(p.incoming_attacker_id) != nullptr ? double(p.incoming_attacker_number) : -1.0;
				break;
			default:
				break; // kept: a game's own, action_ready
		}
	}
	// The group distances, from where the pawn is now.
	for (const PawnRow::GroupPoint &group : p.groups) {
		if (group.distance_slot >= 0 && group.distance_slot < count) {
			_inputs_scratch[group.distance_slot] = group.found ? flat_distance(group.position, position) : FAR;
		}
		if (group.found_slot >= 0 && group.found_slot < count) {
			_inputs_scratch[group.found_slot] = group.found ? 1.0 : 0.0;
		}
	}
	return _inputs_scratch.data();
}

PackedFloat64Array AIBatchDecider::get_last_inputs() const {
	PackedFloat64Array out;
	for (double value : _inputs_scratch) {
		out.push_back(value);
	}
	return out;
}

void AIBatchDecider::set_body(int row, int64_t body_id, Object *memory_store) {
	ERR_FAIL_COND(!row_ok(row));
	_pawns[row].body_id = uint64_t(body_id);
	_pawns[row].memory_store = Ref<RefCounted>(Object::cast_to<RefCounted>(memory_store));
}

void AIBatchDecider::set_owned_tags(int row, const PackedInt64Array &words) {
	ERR_FAIL_COND(!row_ok(row));
	std::vector<uint64_t> &owned = _pawns[row].owned;
	owned.resize(size_t(words.size()));
	for (int64_t i = 0; i < words.size(); ++i) {
		owned[i] = uint64_t(words[i]);
	}
}

void AIBatchDecider::set_modifiers(int row, const PackedFloat64Array &bonus, const PackedFloat64Array &jitter,
		const PackedInt64Array &interrupt_threshold, const PackedInt64Array &cooldown, const PackedInt64Array &min_run, int64_t blocked_mask) {
	ERR_FAIL_COND(!row_ok(row));
	PawnRow &p = _pawns[row];
	const Brain &b = _brains[p.brain];
	const int64_t count = int64_t(b.behaviours.size());
	for (int64_t size : { bonus.size(), jitter.size(), interrupt_threshold.size(), cooldown.size(), min_run.size() }) {
		ERR_FAIL_COND_MSG(size != 0 && size != count, "AIBatchDecider.set_modifiers: each array is empty or has one number per behaviour.");
	}
	reset_numbers(p, b);
	if (!bonus.is_empty()) {
		p.bonus.assign(bonus.ptr(), bonus.ptr() + count);
	}
	if (!jitter.is_empty()) {
		p.jitter.assign(jitter.ptr(), jitter.ptr() + count);
	}
	if (!interrupt_threshold.is_empty()) {
		p.interrupt_threshold.assign(interrupt_threshold.ptr(), interrupt_threshold.ptr() + count);
	}
	if (!cooldown.is_empty()) {
		p.cooldown.assign(cooldown.ptr(), cooldown.ptr() + count);
	}
	if (!min_run.is_empty()) {
		p.min_run.assign(min_run.ptr(), min_run.ptr() + count);
	}
	p.blocked = uint64_t(blocked_mask);
}

void AIBatchDecider::set_target(int row, int64_t target_id) {
	ERR_FAIL_COND(!row_ok(row));
	_pawns[row].target_id = uint64_t(target_id);
}

void AIBatchDecider::set_can_press(int row, int64_t mask) {
	ERR_FAIL_COND(!row_ok(row));
	_pawns[row].can_press = uint64_t(mask);
}

void AIBatchDecider::set_input(int row, int slot, double value) {
	ERR_FAIL_COND(!row_ok(row));
	ERR_FAIL_COND(slot < 0);
	std::vector<double> &kept = _pawns[row].kept_inputs;
	if (kept.size() <= size_t(slot)) {
		kept.resize(size_t(slot) + 1, 0.0);
	}
	kept[slot] = value;
}

void AIBatchDecider::set_group_point(int row, int distance_slot, int found_slot, bool found, const Vector3 &position) {
	ERR_FAIL_COND(!row_ok(row));
	for (PawnRow::GroupPoint &group : _pawns[row].groups) {
		if (group.distance_slot == distance_slot && group.found_slot == found_slot) {
			group.found = found;
			group.position = position;
			return;
		}
	}
	_pawns[row].groups.push_back(PawnRow::GroupPoint{ distance_slot, found_slot, found, position });
}

Dictionary AIBatchDecider::get_facts(int row) const {
	Dictionary facts;
	ERR_FAIL_COND_V(!row_ok(row), facts);
	const PawnRow &p = _pawns[row];
	PackedInt64Array owned;
	for (uint64_t word : p.owned) {
		owned.append(int64_t(word));
	}
	facts["owned"] = owned;
	PackedFloat64Array bonus, jitter;
	PackedInt64Array threshold, cooldown, min_run;
	for (double value : p.bonus) {
		bonus.append(value);
	}
	for (size_t i = 0; i < p.jitter.size(); ++i) {
		jitter.append(p.jitter[i]);
		threshold.append(p.interrupt_threshold[i]);
		cooldown.append(p.cooldown[i]);
		min_run.append(p.min_run[i]);
	}
	facts["bonus"] = bonus;
	facts["jitter"] = jitter;
	facts["interrupt_threshold"] = threshold;
	facts["cooldown"] = cooldown;
	facts["min_run"] = min_run;
	facts["blocked"] = int64_t(p.blocked);
	facts["target_id"] = int64_t(p.target_id);
	facts["can_press"] = int64_t(p.can_press);
	return facts;
}

int AIBatchDecider::decide_pawn(int row, int64_t tick, int64_t event_priority, bool event_normal) {
	_last_kept = false;
	ERR_FAIL_COND_V_MSG(!row_ok(row), -1, "AIBatchDecider.decide_pawn: no pawn in that row.");
	PawnRow &p = _pawns[row];
	const Brain &brain = _brains[p.brain];
	const int count = int(brain.behaviours.size());
	// The hard rule's cooldowns (AIBehaviourBase.is_cooling_down), with the modifiers' numbers.
	uint64_t cooling = 0;
	for (int slot = 0; slot < count; ++slot) {
		const int64_t cooldown = p.cooldown[slot];
		if (cooldown > 0 && p.ended[slot] >= 0 && tick - p.ended[slot] < cooldown) {
			cooling |= uint64_t(1) << slot;
		}
	}
	// Where the pawn is now, from its body.
	Node3D *body = Object::cast_to<Node3D>(alive(p.body_id));
	const Vector3 position = body ? body->get_global_position() : Vector3();
	RowInput in;
	in.running = p.running;
	in.running_started = p.running_started;
	in.now = tick;
	in.event_priority = event_priority;
	in.event_normal = event_normal;
	in.owned = p.owned.data();
	in.owned_count = int64_t(p.owned.size());
	in.bonus = p.bonus.empty() ? nullptr : p.bonus.data();
	in.blocked = p.blocked;
	in.has_target = alive(p.target_id) != nullptr;
	in.cooling = cooling;
	in.can_press = p.can_press;
	in.jitter = p.jitter.data();
	in.interrupt_threshold = p.interrupt_threshold.data();
	in.min_run = p.min_run.data();
	int64_t input_count = 0;
	const double *input_values = work_out_inputs(p, position, tick, input_count);
	in.view = RowView{ 0, 0, nullptr, input_values, input_count, p.random_seed, p.pawn_number, tick };
	const RowResult out = decide_row(brain, in);
	_last_kept = out.kept;
	// The switch, as AIBehaviourManager._start and _stop_running apply it: the old one's end, the new one's start.
	if (out.chosen != p.running) {
		if (p.running >= 0) {
			p.ended[p.running] = tick;
		}
		p.running = out.chosen;
		if (out.chosen >= 0) {
			p.running_started = tick;
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
	ClassDB::bind_method(D_METHOD("get_stride"), &AIBatchDecider::get_stride);
	ClassDB::bind_method(D_METHOD("decide", "columns"), &AIBatchDecider::decide);
	ClassDB::bind_method(D_METHOD("random_unit", "seed", "pawn_number", "tick", "salt"), &AIBatchDecider::random_unit);
	ClassDB::bind_method(D_METHOD("add_pawn", "id", "brain", "pawn_number", "random_seed"), &AIBatchDecider::add_pawn);
	ClassDB::bind_method(D_METHOD("remove_pawn", "id"), &AIBatchDecider::remove_pawn);
	ClassDB::bind_method(D_METHOD("find_pawn", "id"), &AIBatchDecider::find_pawn);
	ClassDB::bind_method(D_METHOD("get_pawn_count"), &AIBatchDecider::get_pawn_count);
	ClassDB::bind_method(D_METHOD("set_pawn_state", "row", "running", "running_started", "ended_ticks"), &AIBatchDecider::set_pawn_state);
	ClassDB::bind_method(D_METHOD("get_pawn_state", "row"), &AIBatchDecider::get_pawn_state);
	ClassDB::bind_method(D_METHOD("stop_running", "row", "tick"), &AIBatchDecider::stop_running);
	ClassDB::bind_method(D_METHOD("decide_pawn", "row", "tick", "event_priority", "event_normal"), &AIBatchDecider::decide_pawn);
	ClassDB::bind_method(D_METHOD("set_body", "row", "body_id", "memory_store"), &AIBatchDecider::set_body);
	ClassDB::bind_method(D_METHOD("set_owned_tags", "row", "words"), &AIBatchDecider::set_owned_tags);
	ClassDB::bind_method(D_METHOD("set_modifiers", "row", "bonus", "jitter", "interrupt_threshold", "cooldown", "min_run", "blocked_mask"), &AIBatchDecider::set_modifiers);
	ClassDB::bind_method(D_METHOD("set_target", "row", "target_id"), &AIBatchDecider::set_target);
	ClassDB::bind_method(D_METHOD("set_can_press", "row", "mask"), &AIBatchDecider::set_can_press);
	ClassDB::bind_method(D_METHOD("set_input", "row", "slot", "value"), &AIBatchDecider::set_input);
	ClassDB::bind_method(D_METHOD("set_group_point", "row", "distance_slot", "found_slot", "found", "position"), &AIBatchDecider::set_group_point);
	ClassDB::bind_method(D_METHOD("get_facts", "row"), &AIBatchDecider::get_facts);
	ClassDB::bind_method(D_METHOD("set_input_kinds", "kinds"), &AIBatchDecider::set_input_kinds);
	ClassDB::bind_method(D_METHOD("note_hit", "row", "tick", "attacker_id"), &AIBatchDecider::note_hit);
	ClassDB::bind_method(D_METHOD("note_incoming", "row", "attacker_id", "attacker_number", "start_tick", "hit_tick"), &AIBatchDecider::note_incoming);
	ClassDB::bind_method(D_METHOD("get_last_inputs"), &AIBatchDecider::get_last_inputs);
	ClassDB::bind_method(D_METHOD("was_kept"), &AIBatchDecider::was_kept);
}
