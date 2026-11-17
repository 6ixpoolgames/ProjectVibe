// Written by Claude (claude-opus-5-5), 2026-11-17. History: native/CHANGELOG.md.
// AIBatchDecider: AI behaviour decisions for many pawns in one call, in C++ (scaling spec 6.2, the "shadow" decider). It makes the
// same decision AIBehaviourManager.decide() makes (pawn spec 10.8), from plain data, so it can later run on the worker threads.
// For now nothing in the game uses its answers: ai/tests/ai_batch_decider_selftest checks it against decisions GDScript made
// (AIDecisionRecorder's records), and agrees or says where it doesn't.
//
// The data, as the owner sketched it: a small number of parallel arrays in, one row per decision, and arrays out.
// - A brain (add_brain) is what every pawn using the same behaviour set shares: each behaviour's settings, in the manager's fixed
//   order (by name), and for each state a bitmask of the behaviours allowed in it. Brains are added once, not per decision.
// - A row is one pawn's decision: its brain, tick, state, reasons, running behaviour, and bitmasks for the hard rules (cooling down,
//   whose action can start) and for the availability GDScript gave. Per-behaviour numbers (persistence, given scores) are in
//   flattened arrays, `stride` values a row (get_stride()).
// - decide() returns which behaviour each row chose, whether the interrupt rule kept the running one, and which behaviours' is_available
//   it asked for, so a comparison can check the early stop asked exactly what GDScript asked.
//
// Bitmasks are one 64-bit word, so a brain holds up to 64 behaviours (add_brain refuses more). That's per brain, not per game: a
// second word per mask is the way past it, if a brain ever needs it.
//
// Behaviours' own checks go through a scorer registry: each behaviour names a scorer, and the decider calls it for is_available and
// score. One scorer so far, "given": GDScript's answer, passed in the row (available_known, available, score). Native scorers that
// read the pawn table's columns (Wander, Chase, Attack) come next, one at a time, each checked against GDScript the same way.
#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string_name.hpp>

#include <cstdint>
#include <vector>

namespace godot {

class AIBatchDecider : public RefCounted {
	GDCLASS(AIBatchDecider, RefCounted)

public:
	// The most behaviours a brain can hold: one bit each in a 64-bit mask.
	static constexpr int MAX_BEHAVIOURS = 64;

	// Adds a brain from its description (AIDecisionRecorder.describe_brain's shape): tie_margin, randomize_ties, tie_salt, and
	// "behaviours", each with name, name_hash, allowed_states, max_score, min_score (null: none), needs_target, presses_action,
	// min_run_ticks_at_rate (else min_run_ticks), interrupt_threshold, cannot_be_interrupted, effective_jitter, and optionally
	// scorer (default "given"). Behaviours are put in the fixed order, by name. Returns the brain's number, or -1 with an error.
	int add_brain(const Dictionary &description);
	int get_brain_count() const;
	// The behaviours in a brain, their slots (place in the fixed order) and names.
	int get_behaviour_count(int brain) const;
	int find_behaviour(int brain, const StringName &name) const; // -1 if it has none by that name
	StringName get_behaviour_name(int brain, int slot) const;
	// The number decide()'s "state" column uses for a state name. A state no behaviour names allows only the behaviours with no
	// allowed_states, as GDScript's is_allowed_in() does.
	int find_state(int brain, const StringName &state) const;
	// How many values a row takes in the flattened per-behaviour arrays: the most behaviours any brain has.
	int get_stride() const;

	// One decision per row. columns holds these arrays, all the same length (the row count), except the flattened ones:
	//   brain (PackedInt32Array), pawn_number, random_seed, tick (PackedInt64Array), state (PackedInt32Array, from find_state),
	//   has_target, event_normal (PackedByteArray, 0 or 1), event_priority (PackedInt32Array), running (PackedInt32Array, slot,
	//   -1 for none), running_started (PackedInt64Array), cooling, can_press (PackedInt64Array masks: behaviours cooling down;
	//   behaviours whose action could start), available_known, available (PackedInt64Array masks, for the "given" scorer),
	//   persistence (PackedFloat64Array, rows * stride), and optionally score (PackedFloat64Array, rows * stride; NaN or missing
	//   means the default score(), max_score).
	// Returns a Dictionary: chosen (PackedInt32Array, slot or -1), kept (PackedByteArray, 1 when the interrupt rule kept the
	// running one), asked (PackedInt64Array, behaviours whose is_available it asked for), unknown (PackedInt64Array, asked but not
	// in available_known: the "given" scorer had no answer and counted it as not available). Empty, with an error, if a column is
	// missing or the wrong length.
	Dictionary decide(const Dictionary &columns);

	// AIContextComponent.random_unit_at, bit for bit: a number from 0 up to 1 from (seed, pawn, tick, salt), nothing stored.
	static double random_unit_at(int64_t seed, int64_t pawn_number, int64_t tick, int64_t salt);
	// The same, as GDScript calls it, for tests.
	double random_unit(int64_t seed, int64_t pawn_number, int64_t tick, int64_t salt) const;

protected:
	static void _bind_methods();

private:
	// What a scorer can read for one row. Native scorers will get the pawn table and memory here.
	struct RowView {
		int64_t available_known = 0;
		int64_t available = 0;
		const double *scores = nullptr; // stride values, or null
	};
	// A behaviour's own checks: is_available() and score(). Registered by name (see scorer_by_name in the .cpp).
	enum class Scorer : uint8_t {
		GIVEN, // GDScript's answer, from the row
	};

	struct Behaviour {
		StringName name;
		int64_t name_hash = 0;
		double max_score = 0.5;
		double min_score = 0.0;
		bool has_min_score = false;
		bool needs_target = false;
		bool presses_action = false;
		int64_t min_run_ticks = 0; // at the match's tick rate
		int64_t interrupt_threshold = 0;
		bool cannot_be_interrupted = false;
		double jitter = 0.0; // effective_jitter
		Scorer scorer = Scorer::GIVEN;
	};

	struct Brain {
		std::vector<Behaviour> behaviours; // the fixed order, by name
		std::vector<int64_t> state_masks; // [0]: behaviours allowed in any state (no allowed_states); then one per named state
		std::vector<StringName> state_names; // state_names[i] is state_masks[i + 1]'s state; a short list, searched rarely
		uint64_t needs_target_mask = 0;
		uint64_t presses_action_mask = 0;
		double tie_margin = 0.0001;
		bool randomize_ties = false;
		int64_t tie_salt = 0x7135;
	};

	// One behaviour's scratch values in one decision, like AIBehaviourBase's decision_ fields.
	struct Candidate {
		int slot = 0;
		double persistence = 0.0;
		double jitter = 0.0;
		double ceiling = 0.0;
		double floor = 0.0;
		bool has_floor = false;
	};

	// is_available() once per decision, as the manager's _is_available: asked holds which were asked, answers what they said.
	bool is_available(const Brain &brain, int slot, const RowView &row, uint64_t &asked, uint64_t &answers, uint64_t &unknown) const;
	double score(const Brain &brain, int slot, const RowView &row) const;

	std::vector<Brain> _brains;
	int _stride = 0;
	std::vector<Candidate> _candidates; // reused every row
	std::vector<int> _ties;
};

} // namespace godot
