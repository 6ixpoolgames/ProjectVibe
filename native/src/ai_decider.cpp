// Written by Claude (claude-opus-5-5), 2026-11-17. History: native/CHANGELOG.md.
// AIDecider: AI behaviour decisions in C++. Described in ai_decider.h. Every step follows
// AIBehaviourManager.decide() (assets/scripts/ai/AIBehaviourManager.gd) exactly, in the same order with the same arithmetic, so the
// two agree to the bit: a change to one goes in both, and ai_decider_selftest compares them.
#include "ai_decider.h"
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
constexpr double POS_INF = std::numeric_limits<double>::infinity();

// A column from decide()'s Dictionary, checked for its type and length. Null, with an error, if it's missing or wrong.
template <typename T>
const T *column(const Dictionary &columns, const char *name, Variant::Type type, int64_t length, T &holder, bool required = true) {
	const Variant value = columns.get(name, Variant());
	if (value.get_type() == Variant::NIL && !required) {
		return nullptr;
	}
	if (value.get_type() != type) {
		UtilityFunctions::push_error(String("AIDecider.decide: the column \"") + name + "\" is missing or the wrong type.");
		return nullptr;
	}
	holder = value;
	if (holder.size() != length) {
		UtilityFunctions::push_error(String("AIDecider.decide: the column \"") + name + "\" has the wrong length.");
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

// AIBehaviourModifier.strength_in: the baked curve's strength at x, a straight line between its points, the end values beyond.
double strength_in(const std::vector<double> &table, double low, double high, double x) {
	const int64_t last = int64_t(table.size()) - 1;
	if (last < 0) {
		return 1.0;
	}
	if (x <= low || high <= low) {
		return table[0];
	}
	if (x >= high) {
		return table[last];
	}
	const double place = (x - low) / (high - low) * double(last);
	const int64_t i = std::min<int64_t>(int64_t(place), last - 1);
	const double part = place - double(i);
	return table[i] + (table[i + 1] - table[i]) * part;
}

// AIBehaviourModifier.multiply_at: a multiply with strength s, never below 0 while reversed.
inline double multiply_at(double m, double s) {
	const double factor = 1.0 + (m - 1.0) * s;
	return (s < 0.0 && factor < 0.0) ? 0.0 : factor;
}

// GDScript's roundi(): half away from zero.
inline int64_t round_to_int(double value) {
	return int64_t(std::llround(value));
}
} // namespace

double AIDecider::random_unit_at(int64_t seed, int64_t pawn_number, int64_t tick, int64_t salt) {
	return deterministic_random::unit(seed, pawn_number, tick, salt);
}

double AIDecider::random_unit(int64_t seed, int64_t pawn_number, int64_t tick, int64_t salt) const {
	return random_unit_at(seed, pawn_number, tick, salt);
}

AIDecider::Shared *AIDecider::s_shared = nullptr;

AIDecider::Shared &AIDecider::shared() {
	if (s_shared == nullptr) {
		s_shared = new Shared();
	}
	return *s_shared;
}

void AIDecider::free_shared() {
	delete s_shared;
	s_shared = nullptr;
}

int64_t AIDecider::ticks_at_rate(int64_t reference_ticks, int64_t rate) {
	if (reference_ticks <= 0 || rate == 60) {
		return reference_ticks;
	}
	return std::max<int64_t>(1, round_to_int(double(reference_ticks) * double(rate) / 60.0));
}

int AIDecider::add_brain(const Dictionary &description, const String &key) {
	Shared &store = shared();
	if (!key.is_empty() && store.by_key.has(key)) {
		return int(store.by_key[key]);
	}
	const Array list = description.get("behaviours", Array());
	if (list.size() > MAX_BEHAVIOURS) {
		UtilityFunctions::push_error(vformat("AIDecider.add_brain: %d behaviours; a brain holds up to %d.", list.size(), MAX_BEHAVIOURS));
		return -1;
	}
	Brain brain;
	brain.tie_margin = double(description.get("tie_margin", 0.0001));
	brain.randomize_ties = bool(description.get("randomize_ties", false));
	brain.tie_salt = int64_t(description.get("tie_salt", 0x7135));
	brain.tick_rate = int64_t(description.get("tick_rate", 60));
	brain.jitter_once = bool(description.get("jitter_once", false));
	brain.jitter_once_salt = int64_t(description.get("jitter_once_salt", 0x6A17));
	brain.jitter_once_tick = int64_t(description.get("jitter_once_tick", 0));
	for (int64_t i = 0; i < list.size(); ++i) {
		const Dictionary entry = list[i];
		Behaviour behaviour;
		behaviour.name = StringName(String(entry.get("name", "")));
		behaviour.name_hash = int64_t(entry.get("name_hash", 0));
		behaviour.scripted_score = bool(entry.get("scripted_score", false));
		behaviour.needs_target = bool(entry.get("needs_target", false));
		behaviour.presses_action = !String(entry.get("presses_action", "")).is_empty();
		behaviour.interrupt_threshold = int64_t(entry.get("interrupt_threshold", 0));
		behaviour.cannot_be_interrupted = bool(entry.get("cannot_be_interrupted", false));
		behaviour.jitter = double(entry.get("effective_jitter", 0.0));
		const int64_t cooldown = int64_t(entry.get("cooldown_ticks", 0));
		const int64_t min_run = int64_t(entry.get("min_run_ticks", 0));
		behaviour.cooldown_ticks = ticks_at_rate(cooldown, brain.tick_rate);
		behaviour.min_run_ticks = ticks_at_rate(min_run, brain.tick_rate);
		behaviour.base[SCORE] = double(entry.get("base_score", 50.0));
		behaviour.base[SCORE_JITTER] = behaviour.jitter;
		behaviour.base[INTERRUPT_THRESHOLD] = double(behaviour.interrupt_threshold);
		behaviour.base[COOLDOWN_TICKS] = double(cooldown);
		behaviour.base[MIN_RUN_TICKS] = double(min_run);
		uint8_t scorer = 0;
		if (!scorer_by_name(String(entry.get("scorer", "")), scorer)) {
			UtilityFunctions::push_error("AIDecider.add_brain: no scorer called \"" + String(entry.get("scorer", "")) + "\".");
			return -1;
		}
		behaviour.scorer = Scorer(scorer);
		// Conditions only for the scorer that reads them: a "given" behaviour may have a condition of a kind C++ doesn't know, which is
		// why GDScript answers for it.
		const bool judged_here = behaviour.scorer == Scorer::CONDITIONS;
		if (judged_here && !add_conditions(entry.get("conditions", Array()), brain, behaviour.first_condition, behaviour.condition_count)) {
			return -1;
		}
		const Variant gate = entry.get("tag_requirements", Variant());
		if (gate.get_type() == Variant::DICTIONARY) {
			const Dictionary g = gate;
			const PackedInt64Array all = g.get("all", PackedInt64Array());
			const PackedInt64Array any = g.get("any", PackedInt64Array());
			const PackedInt64Array none = g.get("none", PackedInt64Array());
			behaviour.has_gate = true;
			behaviour.gate_impossible = bool(g.get("impossible", false));
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
		if (brain.behaviours[slot].scripted_score) {
			brain.scripted_score_mask |= bit;
		}
	}
	store.brains.push_back(brain);
	store.stride = std::max(store.stride, int(brain.behaviours.size()));
	const int number = int(store.brains.size()) - 1;
	if (!key.is_empty()) {
		store.by_key[key] = number;
	}
	return number;
}

bool AIDecider::add_conditions(const Array &list, Brain &brain, int &first, int &count) {
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
			UtilityFunctions::push_error("AIDecider.add_brain: no condition kind called \"" + kind + "\".");
			return false;
		}
		these.push_back(condition);
	}
	first = int(brain.conditions.size());
	count = int(these.size());
	brain.conditions.insert(brain.conditions.end(), these.begin(), these.end());
	return true;
}

double AIDecider::RowView::input(int slot) const {
	if (lazy) {
		return lazy->get(slot);
	}
	return input_at(inputs, input_count, slot);
}

bool AIDecider::passes(const Brain &brain, const Condition &condition, const RowView &row, int64_t behaviour_salt) const {
	switch (condition.kind) {
		case ConditionKind::ALWAYS:
			return true;
		case ConditionKind::COMPARE: {
			// AICompareCondition.passes, the same arithmetic.
			const double left = row.input(condition.input_slot);
			double right = condition.value;
			if (condition.other_slot >= 0) {
				right += row.input(condition.other_slot);
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
			const int64_t roll_tick = condition.key_slot >= 0 ? int64_t(row.input(condition.key_slot)) : row.tick;
			int64_t salt = condition.salt ^ behaviour_salt;
			if (condition.salt_slot >= 0) {
				salt ^= int64_t(row.input(condition.salt_slot)) & 0xFFFF;
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

int AIDecider::get_brain_count() const {
	return int(shared().brains.size());
}

int AIDecider::get_behaviour_count(int brain) const {
	ERR_FAIL_INDEX_V(brain, int(shared().brains.size()), 0);
	return int(shared().brains[brain].behaviours.size());
}

int AIDecider::find_behaviour(int brain, const StringName &name) const {
	ERR_FAIL_INDEX_V(brain, int(shared().brains.size()), -1);
	const std::vector<Behaviour> &list = shared().brains[brain].behaviours;
	for (size_t i = 0; i < list.size(); ++i) {
		if (list[i].name == name) {
			return int(i);
		}
	}
	return -1;
}

StringName AIDecider::get_behaviour_name(int brain, int slot) const {
	ERR_FAIL_INDEX_V(brain, int(shared().brains.size()), StringName());
	ERR_FAIL_INDEX_V(slot, int(shared().brains[brain].behaviours.size()), StringName());
	return shared().brains[brain].behaviours[slot].name;
}

bool AIDecider::passes_gate(const Behaviour &behaviour, const uint64_t *owned, int64_t owned_count) {
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

int AIDecider::get_stride() const {
	return shared().stride;
}

bool AIDecider::is_available(const Brain &brain, int slot, const RowView &row, uint64_t &asked, uint64_t &answers, uint64_t &unknown) const {
	const uint64_t bit = uint64_t(1) << slot;
	if (asked & bit) {
		return (answers & bit) != 0;
	}
	asked |= bit;
	bool available = false;
	switch (brain.behaviours[slot].scorer) {
		case Scorer::GIVEN:
			if (row.asker) {
				available = double(row.asker->call(int64_t(ASK_AVAILABLE), int64_t(slot))) > 0.5;
			} else if (uint64_t(row.available_known) & bit) {
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

double AIDecider::asked_score(const Brain &brain, int slot, const RowView &row) const {
	if (row.asker) {
		return double(row.asker->call(int64_t(ASK_SCORE), int64_t(slot)));
	}
	if (row.scores && !std::isnan(row.scores[slot])) {
		return row.scores[slot];
	}
	return brain.behaviours[slot].base[SCORE]; // AIBehaviourBase.score()'s default
}

Dictionary AIDecider::decide(const Dictionary &columns) {
	Dictionary result;
	PackedInt32Array brains_holder;
	const Variant brain_column = columns.get("brain", Variant());
	if (brain_column.get_type() != Variant::PACKED_INT32_ARRAY) {
		UtilityFunctions::push_error("AIDecider.decide: the column \"brain\" is missing or the wrong type.");
		return result;
	}
	brains_holder = brain_column;
	const int64_t rows = brains_holder.size();
	const int stride = shared().stride;
	const int64_t flat = rows * stride;
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
	PackedFloat64Array multiply_h, add_h, jitter_h;
	const auto *owned = tag_words > 0 ? column(columns, "owned", Variant::PACKED_INT64_ARRAY, rows * tag_words, owned_h) : nullptr;
	const auto *multiplies = columns.has("score_multiply") ? column(columns, "score_multiply", Variant::PACKED_FLOAT64_ARRAY, flat, multiply_h) : nullptr;
	const auto *adds = columns.has("score_add") ? column(columns, "score_add", Variant::PACKED_FLOAT64_ARRAY, flat, add_h) : nullptr;
	const auto *jitters = columns.has("jitter") ? column(columns, "jitter", Variant::PACKED_FLOAT64_ARRAY, flat, jitter_h) : nullptr;
	const auto *thresholds = columns.has("interrupt_threshold") ? column(columns, "interrupt_threshold", Variant::PACKED_INT64_ARRAY, flat, threshold_h) : nullptr;
	const auto *min_runs = columns.has("min_run") ? column(columns, "min_run", Variant::PACKED_INT64_ARRAY, flat, min_run_h) : nullptr;
	const auto *blocked = columns.has("blocked") ? column(columns, "blocked", Variant::PACKED_INT64_ARRAY, rows, blocked_h) : nullptr;
	if ((tag_words > 0 && !owned) || (columns.has("score_multiply") && !multiplies) || (columns.has("score_add") && !adds) ||
			(columns.has("jitter") && !jitters) || (columns.has("interrupt_threshold") && !thresholds) ||
			(columns.has("min_run") && !min_runs) || (columns.has("blocked") && !blocked)) {
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
	const double *multiply_of = multiplies ? multiplies->ptr() : nullptr;
	const double *add_of = adds ? adds->ptr() : nullptr;
	const double *jitter_of = jitters ? jitters->ptr() : nullptr;
	const int64_t *threshold_of = thresholds ? thresholds->ptr() : nullptr;
	const int64_t *min_run_of = min_runs ? min_runs->ptr() : nullptr;

	for (int64_t r = 0; r < rows; ++r) {
		chosen_out.set(r, -1);
		kept_out.set(r, 0);
		asked_out.set(r, 0);
		unknown_out.set(r, 0);
		const int b = brain_of[r];
		if (b < 0 || b >= int(shared().brains.size())) {
			UtilityFunctions::push_error(vformat("AIDecider.decide: row %d names brain %d, which doesn't exist.", r, b));
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
		in.score_multiply = multiply_of ? multiply_of + r * stride : nullptr;
		in.score_add = add_of ? add_of + r * stride : nullptr;
		in.jitter = jitter_of ? jitter_of + r * stride : nullptr;
		in.interrupt_threshold = threshold_of ? threshold_of + r * stride : nullptr;
		in.min_run = min_run_of ? min_run_of + r * stride : nullptr;
		in.blocked = blocked ? uint64_t((*blocked)[r]) : 0;
		in.has_target = (*has_target)[r] != 0;
		in.cooling = uint64_t((*cooling)[r]);
		in.can_press = uint64_t((*can_press)[r]);
		in.view.available_known = (*known)[r];
		in.view.available = (*available)[r];
		in.view.scores = score_of ? score_of + r * stride : nullptr;
		in.view.inputs = inputs_of ? inputs_of + r * input_stride : nullptr;
		in.view.input_count = input_stride;
		in.view.random_seed = (*seed)[r];
		in.view.pawn_number = (*pawn)[r];
		in.view.tick = in.now;
		const RowResult out = decide_row(shared().brains[b], in);
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

AIDecider::RowResult AIDecider::decide_row(const Brain &brain, const RowInput &in) {
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
	// 1 and 2. Valid behaviours and the hard rules that cost nothing, as masks: tag requirements pass; not blocked or switched off;
	// not cooling down (the running one excepted); a target if it needs one.
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
	// 3. Each candidate's result, known before any of its code runs: its score with modifiers, plus jitter, in the fixed order. A
	// score of its own code goes first (infinity) and is asked when reached.
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
		if (jitter > 0.0) {
			const double roll = brain.jitter_once
					? random_unit_at(view.random_seed, view.pawn_number, brain.jitter_once_tick, behaviour.name_hash ^ brain.jitter_once_salt)
					: random_unit_at(view.random_seed, view.pawn_number, now, behaviour.name_hash);
			c.jitter = jitter * (roll * 2.0 - 1.0);
		}
		const double multiply = in.score_multiply ? in.score_multiply[slot] : 1.0;
		const double add = in.score_add ? in.score_add[slot] : 0.0;
		c.key = behaviour.scripted_score ? POS_INF : behaviour.base[SCORE] * multiply + add + c.jitter;
		_candidates.push_back(c);
	}
	// 4. The walk, highest result first. Whether its action could start and whether it's available are asked only on the way.
	std::sort(_candidates.begin(), _candidates.end(), [](const Candidate &a, const Candidate &b) {
		return a.key > b.key || (a.key == b.key && a.slot < b.slot);
	});
	uint64_t answers = 0;
	int best = -1;
	double best_result = NEG_INF;
	_ties.clear();
	for (const Candidate &c : _candidates) {
		if (best >= 0 && c.key < best_result - brain.tie_margin) {
			break;
		}
		const uint64_t bit = uint64_t(1) << c.slot;
		// Availability first: usually judged here from data, for nothing, and it usually fails; asking an ability costs a call.
		if (!is_available(brain, c.slot, view, out.asked, answers, out.unknown)) {
			continue;
		}
		// The running one has already pressed its action, so "could it start" doesn't apply to it.
		if ((brain.presses_action_mask & bit) && c.slot != run) {
			const bool could = view.asker ? double(view.asker->call(int64_t(ASK_COULD_PRESS), int64_t(c.slot))) > 0.5
										  : (in.can_press & bit) != 0;
			if (!could) {
				continue;
			}
		}
		double result_now = c.key;
		if (brain.behaviours[c.slot].scripted_score) {
			const double multiply = in.score_multiply ? in.score_multiply[c.slot] : 1.0;
			const double add = in.score_add ? in.score_add[c.slot] : 0.0;
			result_now = asked_score(brain, c.slot, view) * multiply + add + c.jitter;
		}
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

int AIDecider::add_pawn(int64_t id, int brain, int64_t pawn_number, int64_t random_seed) {
	if (brain < 0 || brain >= int(shared().brains.size())) {
		UtilityFunctions::push_error(vformat("AIDecider.add_pawn: brain %d doesn't exist.", brain));
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
	const Brain &b = shared().brains[brain];
	const size_t count = b.behaviours.size();
	PawnRow &p = _pawns[row];
	p = PawnRow();
	p.id = id;
	p.brain = brain;
	p.pawn_number = pawn_number;
	p.random_seed = random_seed;
	p.ended.assign(count, -1);
	work_out_numbers(b, p, 0, nullptr, p.score_multiply, p.score_add, p.jitter, p.interrupt_threshold, p.cooldown, p.min_run);
	return row;
}

void AIDecider::remove_pawn(int64_t id) {
	const auto found = _row_of_id.find(id);
	if (found == _row_of_id.end()) {
		return;
	}
	_pawns[found->second] = PawnRow(); // brain -1: free
	_free_rows.push_back(found->second);
	_row_of_id.erase(found);
}

int AIDecider::find_pawn(int64_t id) const {
	const auto found = _row_of_id.find(id);
	return found == _row_of_id.end() ? -1 : found->second;
}

int AIDecider::get_pawn_count() const {
	return int(_row_of_id.size());
}

bool AIDecider::row_ok(int row) const {
	return row >= 0 && row < int(_pawns.size()) && _pawns[row].brain >= 0;
}

void AIDecider::set_pawn_state(int row, int running, int64_t running_started, const PackedInt64Array &ended_ticks) {
	ERR_FAIL_COND_MSG(!row_ok(row), "AIDecider.set_pawn_state: no pawn in that row.");
	PawnRow &p = _pawns[row];
	const int64_t count = int64_t(p.ended.size());
	ERR_FAIL_COND_MSG(ended_ticks.size() != count, "AIDecider.set_pawn_state: wrong length for the brain.");
	p.running = running;
	p.running_started = running_started;
	for (int64_t i = 0; i < count; ++i) {
		p.ended[i] = ended_ticks[i];
	}
}

Dictionary AIDecider::get_pawn_state(int row) const {
	Dictionary state;
	ERR_FAIL_COND_V_MSG(!row_ok(row), state, "AIDecider.get_pawn_state: no pawn in that row.");
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

void AIDecider::stop_running(int row, int64_t tick) {
	ERR_FAIL_COND(!row_ok(row));
	PawnRow &p = _pawns[row];
	if (p.running >= 0) {
		p.ended[p.running] = tick;
		p.running = -1;
	}
}

// AIBehaviourBase.work_out_change and the current_ numbers, for every behaviour: the fixed part (an override is a multiply of 0 and
// an add of its value, which no curve changes), then each live curve in the order added, then the number's own rounding.
void AIDecider::work_out_numbers(const Brain &b, const PawnRow &p, int64_t tick, const RowView *view, std::vector<double> &score_multiply,
		std::vector<double> &score_add, std::vector<double> &jitter, std::vector<int64_t> &interrupt_threshold, std::vector<int64_t> &cooldown,
		std::vector<int64_t> &min_run) {
	const size_t count = b.behaviours.size();
	score_multiply.resize(count);
	score_add.resize(count);
	jitter.resize(count);
	interrupt_threshold.resize(count);
	cooldown.resize(count);
	min_run.resize(count);
	const bool has_changes = p.changes.size() == count * NUMBERS * 3;
	for (size_t slot = 0; slot < count; ++slot) {
		const Behaviour &behaviour = b.behaviours[slot];
		double multiply[NUMBERS];
		double add[NUMBERS];
		bool overridden[NUMBERS];
		for (int n = 0; n < NUMBERS; ++n) {
			multiply[n] = 1.0;
			add[n] = 0.0;
			overridden[n] = false;
			if (has_changes) {
				const size_t at = (slot * NUMBERS + n) * 3;
				multiply[n] = p.changes[at];
				add[n] = p.changes[at + 1];
				if (!std::isnan(p.changes[at + 2])) {
					multiply[n] = 0.0;
					add[n] = p.changes[at + 2];
					overridden[n] = true;
				}
			}
		}
		const uint64_t bit = uint64_t(1) << slot;
		for (const CurvedModifier &curve : p.curves) {
			if (!(curve.mask & bit) || curve.number < 0 || curve.number >= NUMBERS || overridden[curve.number]) {
				continue;
			}
			// AIBehaviourBase.curve_strength: x is the ticks since added, or its input, times its scale.
			const double raw = curve.slot < 0 ? double(tick - curve.added) : (view ? view->input(curve.slot) : 0.0);
			const double strength = strength_in(curve.table, curve.low, curve.high, raw * curve.scale);
			multiply[curve.number] *= multiply_at(curve.multiply, strength);
			add[curve.number] += curve.add * strength;
		}
		score_multiply[slot] = multiply[SCORE];
		score_add[slot] = add[SCORE];
		jitter[slot] = std::max(0.0, behaviour.base[SCORE_JITTER] * multiply[SCORE_JITTER] + add[SCORE_JITTER]);
		interrupt_threshold[slot] = round_to_int(behaviour.base[INTERRUPT_THRESHOLD] * multiply[INTERRUPT_THRESHOLD] + add[INTERRUPT_THRESHOLD]);
		cooldown[slot] = ticks_at_rate(std::max<int64_t>(0, round_to_int(behaviour.base[COOLDOWN_TICKS] * multiply[COOLDOWN_TICKS] + add[COOLDOWN_TICKS])), b.tick_rate);
		min_run[slot] = ticks_at_rate(std::max<int64_t>(0, round_to_int(behaviour.base[MIN_RUN_TICKS] * multiply[MIN_RUN_TICKS] + add[MIN_RUN_TICKS])), b.tick_rate);
	}
}

void AIDecider::set_input_kinds(const PackedInt32Array &kinds) {
	shared().input_kinds.assign(kinds.ptr(), kinds.ptr() + kinds.size());
}

int AIDecider::get_input_kind_count() const {
	return int(shared().input_kinds.size());
}

void AIDecider::note_hit(int row, int64_t tick, int64_t attacker_id) {
	ERR_FAIL_COND(!row_ok(row));
	_pawns[row].last_hit_tick = tick;
	_pawns[row].last_attacker_id = uint64_t(attacker_id);
}

void AIDecider::note_incoming(int row, int64_t attacker_id, int64_t attacker_number, int64_t start_tick, int64_t hit_tick) {
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
	TICKS_SINCE_TARGET_SEEN,
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

double AIDecider::LazyInputs::get(int slot) {
	if (slot < 0 || slot >= count) {
		return 0.0;
	}
	if (!known[slot]) {
		known[slot] = 1;
		values[slot] = owner->work_out_input(owner->_pawns[row], *this, slot);
	}
	return values[slot];
}

double AIDecider::work_out_input(const PawnRow &p, LazyInputs &lazy, int slot) {
	const std::vector<int32_t> &kinds = shared().input_kinds;
	const double kept = size_t(slot) < p.kept_inputs.size() ? p.kept_inputs[slot] : 0.0;
	const int32_t kind = size_t(slot) < kinds.size() ? kinds[slot] : KEPT;
	switch (kind) {
		case GROUP_DISTANCE:
		case GROUP_FOUND:
		case ACTION_READY:
			// Only GDScript works these out (a group's nearest node, an ability's readiness): asked.
			return p.asker.is_valid() ? double(p.asker.call(int64_t(ASK_INPUT), int64_t(slot))) : 0.0;
		case KEPT:
			return kept;
		default:
			break;
	}
	AIMemoryStore *store = Object::cast_to<AIMemoryStore>(p.memory_store.ptr());
	if (store == nullptr) {
		return kept;
	}
	const Vector3 &position = lazy.position;
	const int64_t tick = lazy.tick;
	switch (kind) {
		case TARGET_DISTANCE: {
			const int64_t index = alive(p.target_id) != nullptr ? store->find_by_id(p.target_id) : -1;
			return index >= 0 ? flat_distance(store->last_known_position_at(index), position) : FAR;
		}
		case MOST_AWARE_CERTAIN:
		case MOST_AWARE_UNCERTAIN: {
			if (lazy.most_aware == -2) {
				lazy.most_aware = store->most_aware_index(position, tick);
			}
			const int64_t most_aware = lazy.most_aware;
			const bool certain = most_aware >= 0 && store->is_certain_at(most_aware);
			const bool wanted = kind == MOST_AWARE_CERTAIN ? certain : (most_aware >= 0 && !certain);
			return wanted ? 1.0 : 0.0;
		}
		case TICKS_SINCE_UNKNOWN_HIT: {
			// An attacker it remembers is known; one that's gone, or never noticed, isn't.
			const bool known = alive(p.last_attacker_id) != nullptr && store->find_by_id(p.last_attacker_id) >= 0;
			return (p.last_hit_tick >= 0 && !known) ? double(tick - p.last_hit_tick) : FAR;
		}
		case INCOMING_ATTACK: {
			// AIManager.has_incoming_attack: not hit yet, and the attacker still there and alive.
			Object *attacker = alive(p.incoming_attacker_id);
			return (p.incoming_hit_tick >= tick && attacker != nullptr && !bool(attacker->get("dead"))) ? 1.0 : 0.0;
		}
		case INCOMING_ATTACK_TICK:
			return double(p.incoming_start_tick);
		case INCOMING_ATTACKER:
			return alive(p.incoming_attacker_id) != nullptr ? double(p.incoming_attacker_number) : -1.0;
		case TICKS_SINCE_TARGET_SEEN: {
			const int64_t index = alive(p.target_id) != nullptr ? store->find_by_id(p.target_id) : -1;
			return index >= 0 ? double(store->ticks_since_seen_at(index, tick)) : FAR;
		}
		default:
			return kept;
	}
}

PackedFloat64Array AIDecider::get_last_inputs() {
	PackedFloat64Array out;
	if (!row_ok(_lazy.row)) {
		return out;
	}
	for (int64_t slot = 0; slot < _lazy.count; ++slot) {
		out.push_back(_lazy.get(int(slot)));
	}
	return out;
}

void AIDecider::set_body(int row, int64_t body_id, Object *memory_store) {
	ERR_FAIL_COND(!row_ok(row));
	_pawns[row].body_id = uint64_t(body_id);
	_pawns[row].memory_store = Ref<RefCounted>(Object::cast_to<RefCounted>(memory_store));
}

void AIDecider::set_asker(int row, const Callable &asker) {
	ERR_FAIL_COND(!row_ok(row));
	_pawns[row].asker = asker;
}

void AIDecider::set_owned_tags(int row, const PackedInt64Array &words) {
	ERR_FAIL_COND(!row_ok(row));
	std::vector<uint64_t> &owned = _pawns[row].owned;
	owned.resize(size_t(words.size()));
	for (int64_t i = 0; i < words.size(); ++i) {
		owned[i] = uint64_t(words[i]);
	}
}

void AIDecider::set_modifiers(int row, const PackedFloat64Array &changes, const Array &curves, int64_t blocked_mask) {
	ERR_FAIL_COND(!row_ok(row));
	PawnRow &p = _pawns[row];
	const Brain &b = shared().brains[p.brain];
	const int64_t count = int64_t(b.behaviours.size());
	ERR_FAIL_COND_MSG(!changes.is_empty() && changes.size() != count * NUMBERS * 3,
			"AIDecider.set_modifiers: changes is empty or has three values for each number of each behaviour.");
	p.changes.assign(changes.ptr(), changes.ptr() + changes.size());
	p.curves.clear();
	for (int64_t i = 0; i < curves.size(); ++i) {
		const Dictionary described = curves[i];
		CurvedModifier curve;
		curve.mask = uint64_t(int64_t(described.get("mask", 0)));
		curve.number = int(described.get("number", 0));
		curve.multiply = double(described.get("multiply", 1.0));
		curve.add = double(described.get("add", 0.0));
		const PackedFloat64Array table = described.get("table", PackedFloat64Array());
		curve.table.assign(table.ptr(), table.ptr() + table.size());
		curve.low = double(described.get("low", 0.0));
		curve.high = double(described.get("high", 1.0));
		curve.slot = int(described.get("slot", -1));
		curve.added = int64_t(described.get("added", 0));
		curve.scale = double(described.get("scale", 1.0));
		p.curves.push_back(curve);
	}
	p.blocked = uint64_t(blocked_mask);
	// What they leave while no curve is live; with one, decide_pawn works them out at each decision.
	work_out_numbers(b, p, 0, nullptr, p.score_multiply, p.score_add, p.jitter, p.interrupt_threshold, p.cooldown, p.min_run);
}

void AIDecider::set_disabled(int row, int64_t mask) {
	ERR_FAIL_COND(!row_ok(row));
	_pawns[row].disabled = uint64_t(mask);
}

void AIDecider::set_target(int row, int64_t target_id) {
	ERR_FAIL_COND(!row_ok(row));
	_pawns[row].target_id = uint64_t(target_id);
}

void AIDecider::set_input(int row, int slot, double value) {
	ERR_FAIL_COND(!row_ok(row));
	ERR_FAIL_COND(slot < 0);
	std::vector<double> &kept = _pawns[row].kept_inputs;
	if (kept.size() <= size_t(slot)) {
		kept.resize(size_t(slot) + 1, 0.0);
	}
	kept[slot] = value;
}

Dictionary AIDecider::get_facts(int row) const {
	Dictionary facts;
	ERR_FAIL_COND_V(!row_ok(row), facts);
	const PawnRow &p = _pawns[row];
	PackedInt64Array owned;
	for (uint64_t word : p.owned) {
		owned.append(int64_t(word));
	}
	facts["owned"] = owned;
	facts["blocked"] = int64_t(p.blocked);
	facts["disabled"] = int64_t(p.disabled);
	facts["target_id"] = int64_t(p.target_id);
	return facts;
}

int AIDecider::decide_pawn(int row, int64_t tick, int64_t event_priority, bool event_normal) {
	_last_kept = false;
	ERR_FAIL_COND_V_MSG(!row_ok(row), -1, "AIDecider.decide_pawn: no pawn in that row.");
	const Brain &brain = shared().brains[_pawns[row].brain];
	const int count = int(brain.behaviours.size());
	// Its inputs, each worked out when first read, from where the pawn is now.
	{
		const PawnRow &p = _pawns[row];
		Node3D *body = Object::cast_to<Node3D>(alive(p.body_id));
		_lazy.owner = this;
		_lazy.row = row;
		_lazy.position = body ? body->get_global_position() : Vector3();
		_lazy.tick = tick;
		_lazy.count = std::max<int64_t>(int64_t(p.kept_inputs.size()), int64_t(shared().input_kinds.size()));
		_lazy.most_aware = -2;
		_lazy.values.assign(size_t(_lazy.count), 0.0);
		_lazy.known.assign(size_t(_lazy.count), 0);
	}
	PawnRow &p = _pawns[row];
	RowInput in;
	in.view.random_seed = p.random_seed;
	in.view.pawn_number = p.pawn_number;
	in.view.tick = tick;
	in.view.lazy = &_lazy;
	in.view.asker = p.asker.is_valid() ? &p.asker : nullptr;
	// The numbers the modifiers leave: worked out as they were written, or now, while a curve is live.
	const bool live = !p.curves.empty();
	if (live) {
		work_out_numbers(brain, p, tick, &in.view, _score_multiply, _score_add, _jitter, _interrupt_threshold, _cooldown, _min_run);
	}
	const std::vector<int64_t> &cooldown = live ? _cooldown : p.cooldown;
	// The hard rule's cooldowns (AIBehaviourBase.is_cooling_down), with the modifiers' numbers.
	uint64_t cooling = 0;
	for (int slot = 0; slot < count; ++slot) {
		if (cooldown[slot] > 0 && p.ended[slot] >= 0 && tick - p.ended[slot] < cooldown[slot]) {
			cooling |= uint64_t(1) << slot;
		}
	}
	in.running = p.running;
	in.running_started = p.running_started;
	in.now = tick;
	in.event_priority = event_priority;
	in.event_normal = event_normal;
	in.owned = p.owned.data();
	in.owned_count = int64_t(p.owned.size());
	in.blocked = p.blocked | p.disabled;
	in.has_target = alive(p.target_id) != nullptr;
	in.cooling = cooling;
	in.score_multiply = live ? _score_multiply.data() : p.score_multiply.data();
	in.score_add = live ? _score_add.data() : p.score_add.data();
	in.jitter = live ? _jitter.data() : p.jitter.data();
	in.interrupt_threshold = live ? _interrupt_threshold.data() : p.interrupt_threshold.data();
	in.min_run = live ? _min_run.data() : p.min_run.data();
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

bool AIDecider::was_kept() const {
	return _last_kept;
}

void AIDecider::_bind_methods() {
	ClassDB::bind_method(D_METHOD("add_brain", "description", "key"), &AIDecider::add_brain, DEFVAL(String()));
	ClassDB::bind_method(D_METHOD("get_brain_count"), &AIDecider::get_brain_count);
	ClassDB::bind_method(D_METHOD("get_behaviour_count", "brain"), &AIDecider::get_behaviour_count);
	ClassDB::bind_method(D_METHOD("find_behaviour", "brain", "name"), &AIDecider::find_behaviour);
	ClassDB::bind_method(D_METHOD("get_behaviour_name", "brain", "slot"), &AIDecider::get_behaviour_name);
	ClassDB::bind_method(D_METHOD("get_stride"), &AIDecider::get_stride);
	ClassDB::bind_method(D_METHOD("decide", "columns"), &AIDecider::decide);
	ClassDB::bind_method(D_METHOD("random_unit", "seed", "pawn_number", "tick", "salt"), &AIDecider::random_unit);
	ClassDB::bind_method(D_METHOD("add_pawn", "id", "brain", "pawn_number", "random_seed"), &AIDecider::add_pawn);
	ClassDB::bind_method(D_METHOD("remove_pawn", "id"), &AIDecider::remove_pawn);
	ClassDB::bind_method(D_METHOD("find_pawn", "id"), &AIDecider::find_pawn);
	ClassDB::bind_method(D_METHOD("get_pawn_count"), &AIDecider::get_pawn_count);
	ClassDB::bind_method(D_METHOD("set_pawn_state", "row", "running", "running_started", "ended_ticks"), &AIDecider::set_pawn_state);
	ClassDB::bind_method(D_METHOD("get_pawn_state", "row"), &AIDecider::get_pawn_state);
	ClassDB::bind_method(D_METHOD("stop_running", "row", "tick"), &AIDecider::stop_running);
	ClassDB::bind_method(D_METHOD("decide_pawn", "row", "tick", "event_priority", "event_normal"), &AIDecider::decide_pawn);
	ClassDB::bind_method(D_METHOD("set_body", "row", "body_id", "memory_store"), &AIDecider::set_body);
	ClassDB::bind_method(D_METHOD("set_asker", "row", "asker"), &AIDecider::set_asker);
	ClassDB::bind_method(D_METHOD("set_owned_tags", "row", "words"), &AIDecider::set_owned_tags);
	ClassDB::bind_method(D_METHOD("set_modifiers", "row", "changes", "curves", "blocked_mask"), &AIDecider::set_modifiers);
	ClassDB::bind_method(D_METHOD("set_disabled", "row", "mask"), &AIDecider::set_disabled);
	ClassDB::bind_method(D_METHOD("set_target", "row", "target_id"), &AIDecider::set_target);
	ClassDB::bind_method(D_METHOD("set_input", "row", "slot", "value"), &AIDecider::set_input);
	ClassDB::bind_method(D_METHOD("get_facts", "row"), &AIDecider::get_facts);
	ClassDB::bind_method(D_METHOD("set_input_kinds", "kinds"), &AIDecider::set_input_kinds);
	ClassDB::bind_method(D_METHOD("get_input_kind_count"), &AIDecider::get_input_kind_count);
	ClassDB::bind_method(D_METHOD("note_hit", "row", "tick", "attacker_id"), &AIDecider::note_hit);
	ClassDB::bind_method(D_METHOD("note_incoming", "row", "attacker_id", "attacker_number", "start_tick", "hit_tick"), &AIDecider::note_incoming);
	ClassDB::bind_method(D_METHOD("get_last_inputs"), &AIDecider::get_last_inputs);
	ClassDB::bind_method(D_METHOD("was_kept"), &AIDecider::was_kept);
}
