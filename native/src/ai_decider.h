// Written by Claude (claude-opus-5-5), 2026-11-17. History: native/CHANGELOG.md.
// AIDecider: AI behaviour decisions in C++ (scaling spec 6.2, pawn spec 16.5), the main path. Each AIBehaviourManager owns one,
// through AIDeciderBridge, holding its pawn's one row; a batch runner can hold many rows in one. It makes the same decision
// AIBehaviourManager.decide() makes (pawn spec 10.8), from plain data, so it can later run on the worker threads;
// ai/tests/ai_decider_selftest checks it against decisions GDScript made (AIDecisionRecorder's records).
// REFACTOR: kept twice, here and in AIBehaviourManager.decide() (reusable, extensible); see the row in native/CHANGELOG.md.
//
// The data, as the owner sketched it: a small number of parallel arrays in, one row per decision, and arrays out.
// - A brain (add_brain) is what every pawn using the same behaviour set shares: each behaviour's settings, in the manager's fixed
//   order (by name), with its tag requirements as masks over the owned tags' category words. Brains live in one store shared by
//   every decider (static), compiled once per key: pawns built the same way share one however many deciders there are.
// - A row is one pawn's decision: its brain, tick, owned tags (as words), reasons, running behaviour, and bitmasks for the hard rules
//   (cooling down, whose action can start, blocked by a behaviour modifier) and for the availability GDScript gave. Per-behaviour
//   numbers (modifier bonuses, given scores) are in flattened arrays, `stride` values a row (get_stride()).
// - decide() returns which behaviour each row chose, whether the interrupt rule kept the running one, and which behaviours' is_available
//   it asked for, so a comparison can check the early stop asked exactly what GDScript asked.
//
// Two ways to use it:
// - decide(columns): many decisions in one call, everything about each passed in as columns. Stateless: decision_replay.gd replays
//   recorded decisions through it.
// - Pawns: each pawn's decision state lives in its row (add_pawn): its running behaviour and since when, and each behaviour's last
//   end (cooldowns). decide_pawn() decides one pawn from that state and its facts (owned tags, target, inputs, the numbers its
//   behaviour modifiers leave: score bonus, jitter, interrupt threshold, cooldown, minimum run), and applies the switch to the state
//   itself, as AIBehaviourManager._start does to the behaviour nodes. A behaviour stopping on its own is stop_running. This is how
//   C++ makes the game's decisions; GDScript's decider is the backup (the owner's call).
//
// Bitmasks are one 64-bit word, so a brain holds up to 64 behaviours (add_brain refuses more). That's per brain, not per game: a
// second word per mask is the way past it, if a brain ever needs it.
//
// Behaviours' own checks go through a scorer registry: each behaviour names a scorer, and the decider calls it for is_available and
// score. Two scorers (scaling spec 6.2, step 5b):
// - "conditions": the behaviour's conditions and score curves, plain data in the brain (AICondition, AIScoreCurve in GDScript),
//   checked against the row's AI inputs (the "inputs" column, AIInputs in GDScript). Every built-in behaviour is judged this way.
//   No behaviour is written in C++: only the kinds of check are (compare, chance, any), so a designer's new behaviour needs no C++.
// - "given": GDScript's answer, passed in the row (available_known, available, score; set_given for a pawn's row), for a behaviour
//   with code of its own or a condition C++ doesn't read. Only that behaviour is GDScript's; C++ judges the rest of the brain.
#pragma once

#include <godot_cpp/classes/ref.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string_name.hpp>

#include <godot_cpp/variant/vector3.hpp>

#include <cstdint>
#include <unordered_map>
#include <vector>

namespace godot {

class AIDecider : public RefCounted {
	GDCLASS(AIDecider, RefCounted)

public:
	// The most behaviours a brain can hold: one bit each in a 64-bit mask.
	static constexpr int MAX_BEHAVIOURS = 64;

	// Adds a brain to the store every decider shares, from its description (AIBehaviourManager.describe()'s shape): tie_margin, randomize_ties, tie_salt, and
	// "behaviours", each with name, name_hash, tag_requirements (TagQuery.describe_words(): all, any and none as one word per tag
	// category, and impossible; null for none), enabled (false: never chosen), max_score, min_score (null: none), needs_target, presses_action,
	// min_run_ticks_at_rate (else min_run_ticks), interrupt_threshold, cannot_be_interrupted, effective_jitter, and optionally
	// scorer ("given", the default, or "conditions"), conditions and score_curves (AICondition.describe() and
	// AIScoreCurve.describe()). Behaviours are put in the fixed order, by name. Returns the brain's number, or -1 with an error.
	// key: what the brain is compiled from (the description as text); a brain already added under it is returned, not compiled again.
	// Empty: always a new brain.
	int add_brain(const Dictionary &description, const String &key = String());
	int get_brain_count() const;
	// The behaviours in a brain, their slots (place in the fixed order) and names.
	int get_behaviour_count(int brain) const;
	int find_behaviour(int brain, const StringName &name) const; // -1 if it has none by that name
	StringName get_behaviour_name(int brain, int slot) const;
	// How many values a row takes in the flattened per-behaviour arrays: the most behaviours any brain has.
	int get_stride() const;

	// One decision per row. columns holds these arrays, all the same length (the row count), except the flattened ones:
	//   brain (PackedInt32Array), pawn_number, random_seed, tick (PackedInt64Array), owned (PackedInt64Array, rows * tag_words: the
	//   owned tags' words; optional, nothing owned without it) with tag_words (int), has_target, event_normal (PackedByteArray, 0 or 1), event_priority (PackedInt32Array), running (PackedInt32Array, slot,
	//   -1 for none), running_started (PackedInt64Array), cooling, can_press (PackedInt64Array masks: behaviours cooling down;
	//   behaviours whose action could start), available_known, available (PackedInt64Array masks, for the "given" scorer),
	//   and optionally score (PackedFloat64Array, rows * stride; NaN or missing means the default score(), max_score), modifier
	//   (PackedFloat64Array, rows * stride, the behaviour modifiers' score bonus), jitter (PackedFloat64Array, rows * stride),
	//   interrupt_threshold and min_run (PackedInt64Array, rows * stride, min_run at the match's rate): the numbers modifiers leave,
	//   the brain's without them; blocked (PackedInt64Array mask, behaviours a modifier blocks), and inputs (PackedFloat64Array, rows * input_stride, each row's AI inputs by slot)
	//   with input_stride (int). A condition reading a slot past input_stride reads 0, as AIInputs.value() does.
	// Returns a Dictionary: chosen (PackedInt32Array, slot or -1), kept (PackedByteArray, 1 when the interrupt rule kept the
	// running one), asked (PackedInt64Array, behaviours whose is_available it asked for), unknown (PackedInt64Array, asked but not
	// in available_known: the "given" scorer had no answer and counted it as not available). Empty, with an error, if a column is
	// missing or the wrong length.
	Dictionary decide(const Dictionary &columns);

	// AIManager.random_unit_at, bit for bit: a number from 0 up to 1 from (seed, pawn, tick, salt), nothing stored.
	static double random_unit_at(int64_t seed, int64_t pawn_number, int64_t tick, int64_t salt);
	// The same, as GDScript calls it, for tests.
	double random_unit(int64_t seed, int64_t pawn_number, int64_t tick, int64_t salt) const;

	// --- Pawns: each pawn's decision state, deciding one pawn at a time (step 5c) ---
	// Adds a pawn by its instance id (Godot never gives a freed object's id to a new one), with its brain, number and random seed.
	// Returns its row, or -1 with an error for an unknown brain. Adding an id that's here starts it afresh. Nothing is running.
	int add_pawn(int64_t id, int brain, int64_t pawn_number, int64_t random_seed);
	void remove_pawn(int64_t id);
	int find_pawn(int64_t id) const; // -1 if it isn't here
	int get_pawn_count() const;
	// Copies a pawn's state from GDScript's behaviour nodes, for a pawn starting to decide here or put right after a disagreement:
	// the running slot (-1 none) and its start tick, and each behaviour's ended tick (-1 never). Lengths must match its brain.
	void set_pawn_state(int row, int running, int64_t running_started, const PackedInt64Array &ended_ticks);
	// The state in the same shape (running, running_started, ended), for tests and a pawn switching to GDScript.
	Dictionary get_pawn_state(int row) const;
	// The running behaviour stopped without a decision (it finished, the pawn died or left): it ends at this tick.
	void stop_running(int row, int64_t tick);
	// The kind of every input slot (AIInputs.Kind, by slot), so the decider can work out the built-in ones itself (step 5d). Shared
	// by every decider, like the brains.
	void set_input_kinds(const PackedInt32Array &kinds);
	int get_input_kind_count() const;
	// Frees the store every decider shares; the library's unload calls it.
	static void free_shared();
	// --- Facts: what a decision is made from, written into the pawn's row when it changes; its owner (AIDeciderBridge) reads version
	// counters before each decision to see which. ---
	// The pawn's body (its instance id: its position is read from it) and its C++ memory store (AIMemoryStore).
	void set_body(int row, int64_t body_id, Object *memory_store);
	// Its owned tags as words (OwnedTags.get_words()), written when they change (OwnedTags.version). The AI's state is one of them.
	void set_owned_tags(int row, const PackedInt64Array &words);
	// What the behaviour modifiers leave, per behaviour slot, written when they change (pawn spec 16.5): the score bonus, jitter,
	// interrupt threshold, cooldown and minimum run (ticks at the match's rate), and the behaviours they block. An empty array: the
	// brain's numbers (bonus 0).
	void set_modifiers(int row, const PackedFloat64Array &bonus, const PackedFloat64Array &jitter, const PackedInt64Array &interrupt_threshold,
			const PackedInt64Array &cooldown, const PackedInt64Array &min_run, int64_t blocked_mask);
	// Its target's instance id (0: none), from AIManager's current_target. A target that's gone counts as none.
	void set_target(int row, int64_t target_id);
	// The behaviours whose action could start (a mask by slot), from the AbilityManager's readiness after it changed.
	void set_can_press(int row, int64_t mask);
	// One input it keeps (a game's own, or action_ready), from AIInputs.set_input.
	void set_input(int row, int slot, double value);
	// GDScript's answers for the behaviours judged by the "given" scorer (code of their own, or a condition C++ doesn't read), for the
	// next decision: which it answered (a mask by slot), which are available, and their scores (one per behaviour; NaN or an empty
	// array: max_score). Written before each decision; a behaviour it didn't answer counts as not available if C++ asks.
	void set_given(int row, int64_t known_mask, int64_t available_mask, const PackedFloat64Array &scores);
	// The nearest node of a group the pawn's conditions read (group_distance and group_found slots, -1 if not read), from AIInputs'
	// lookup, which looks again every 2 seconds. The distance is worked out from the body at each decision.
	void set_group_point(int row, int distance_slot, int found_slot, bool found, const Vector3 &position);
	// The last hit's tick and attacker; the swing coming (attacker 0 when there's none), its attacker's pawn number, start and hit ticks.
	void note_hit(int row, int64_t tick, int64_t attacker_id);
	void note_incoming(int row, int64_t attacker_id, int64_t attacker_number, int64_t start_tick, int64_t hit_tick);
	// The facts as written (owned, target_id, can_press, bonus, jitter, interrupt_threshold, cooldown, min_run, blocked), for shadow
	// mode's check that nothing was missed.
	Dictionary get_facts(int row) const;
	// One decision for one pawn, from its row: its state and facts, and the reason's priority and whether it's an ordinary decision.
	// The memory-based inputs are worked out here from its memory store (as AIInputs does), the group distances from its body, the
	// rest are the inputs it keeps. Returns the chosen slot (-1 nothing) and applies the switch to the pawn's state. was_kept() says
	// whether the interrupt rule kept the running one.
	int decide_pawn(int row, int64_t tick, int64_t event_priority, bool event_normal);
	// The inputs the last decide_pawn used, as it worked them out, for tests.
	PackedFloat64Array get_last_inputs() const;
	bool was_kept() const;

protected:
	static void _bind_methods();

private:
	// What a scorer can read for one row.
	struct RowView {
		int64_t available_known = 0;
		int64_t available = 0;
		const double *scores = nullptr; // stride values, or null
		const double *inputs = nullptr; // input_count values, or null
		int64_t input_count = 0;
		int64_t random_seed = 0; // for chance conditions
		int64_t pawn_number = 0;
		int64_t tick = 0;
	};
	// A behaviour's own checks: is_available() and score(). Registered by name (see scorer_by_name in the .cpp).
	enum class Scorer : uint8_t {
		GIVEN, // GDScript's answer, from the row
		CONDITIONS, // its conditions and score curves, against the row's inputs
	};

	// One condition (AICondition in GDScript), as plain numbers. An "any" condition's own conditions are children[first, first+count)
	// in the brain's conditions list.
	enum class ConditionKind : uint8_t {
		ALWAYS,
		COMPARE, // AICompareCondition
		CHANCE, // AIChanceCondition
		ANY, // AIAnyCondition
	};
	struct Condition {
		ConditionKind kind = ConditionKind::ALWAYS;
		int input_slot = -1;
		int comparison = 0; // AICompareCondition.Comparison: AT_MOST, LESS_THAN, AT_LEAST, MORE_THAN, EQUAL, NOT_EQUAL
		double value = 0.0; // already at the match's tick rate
		int other_slot = -1;
		double chance = 0.0;
		int64_t salt = 0;
		int key_slot = -1;
		int salt_slot = -1;
		int first_child = 0;
		int child_count = 0;
	};
	// One score curve (AIScoreCurve): from gives 0, to gives 1, a straight line between.
	struct Curve {
		int input_slot = -1;
		double from = 0.0;
		double to = 1.0;
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
		int first_condition = 0; // its top-level conditions: the brain's conditions[first, first+count)
		int condition_count = 0;
		int first_curve = 0; // its curves: the brain's curves[first, first+count)
		int curve_count = 0;
		int64_t cooldown_ticks = 0; // at the match's rate
		// Its tag requirements (a TagQuery): one word per category for all of, any of and none of.
		bool has_gate = false;
		bool gate_impossible = false; // all of names a tag nothing can own
		bool gate_needs_any = false;
		std::vector<uint64_t> gate_all;
		std::vector<uint64_t> gate_any;
		std::vector<uint64_t> gate_none;
	};

	struct Brain {
		std::vector<Behaviour> behaviours; // the fixed order, by name
		std::vector<Condition> conditions; // every behaviour's, children before the "any" holding them
		std::vector<Curve> curves;
		uint64_t gated_mask = 0; // behaviours with tag requirements
		uint64_t needs_target_mask = 0;
		uint64_t presses_action_mask = 0;
		double tie_margin = 0.0001;
		bool randomize_ties = false;
		int64_t tie_salt = 0x7135;
	};

	// One behaviour's scratch values in one decision, like AIBehaviourBase's decision_ fields.
	struct Candidate {
		int slot = 0;
		double bonus = 0.0; // the modifiers' score bonus
		double jitter = 0.0;
		double ceiling = 0.0;
		double floor = 0.0;
		bool has_floor = false;
	};

	// One pawn's decision state (see the Pawns functions above). Per behaviour: ended tick, and the numbers modifiers leave.
	struct PawnRow {
		int64_t id = 0;
		int brain = -1;
		int64_t pawn_number = 0;
		int64_t random_seed = 0;
		int running = -1;
		int64_t running_started = -1;
		std::vector<int64_t> ended;
		std::vector<double> jitter;
		std::vector<int64_t> interrupt_threshold;
		std::vector<int64_t> cooldown; // at the match's rate
		std::vector<int64_t> min_run; // at the match's rate
		// Facts (write-through), written when they change.
		uint64_t body_id = 0;
		Ref<RefCounted> memory_store; // an AIMemoryStore
		std::vector<uint64_t> owned; // its owned tags' words
		std::vector<double> bonus; // the modifiers' score bonus per slot (empty: none)
		uint64_t blocked = 0;
		uint64_t target_id = 0;
		uint64_t can_press = 0;
		std::vector<double> kept_inputs; // by slot: the inputs it keeps
		struct GroupPoint {
			int distance_slot = -1;
			int found_slot = -1;
			bool found = false;
			Vector3 position;
		};
		std::vector<GroupPoint> groups;
		int64_t last_hit_tick = -1;
		uint64_t last_attacker_id = 0;
		uint64_t incoming_attacker_id = 0;
		int64_t incoming_attacker_number = -1;
		int64_t incoming_start_tick = -1;
		int64_t incoming_hit_tick = -1;
		// GDScript's answers for "given" behaviours, for the next decision (set_given).
		uint64_t given_known = 0;
		uint64_t given_available = 0;
		std::vector<double> given_scores; // by slot, NaN: max_score; empty: none
	};
	// The numbers the modifiers leave, back to the brain's own (add_pawn, and set_modifiers before writing).
	static void reset_numbers(PawnRow &p, const Brain &b);
	// The inputs worked out here into scratch, for one decision.
	const double *work_out_inputs(const PawnRow &p, const Vector3 &position, int64_t tick, int64_t &count);

	// Everything one decision is made from, whichever way it came in.
	struct RowInput {
		int running = -1;
		int64_t running_started = -1;
		int64_t now = 0;
		int64_t event_priority = 0;
		bool event_normal = true;
		const uint64_t *owned = nullptr; // the owned tags' words, owned_count of them
		int64_t owned_count = 0;
		const double *bonus = nullptr; // one per behaviour, or null: none
		uint64_t blocked = 0;
		bool has_target = false;
		uint64_t cooling = 0;
		uint64_t can_press = 0;
		const double *jitter = nullptr; // one per behaviour, or null: the brain's
		const int64_t *interrupt_threshold = nullptr; // one per behaviour, or null: the brain's
		const int64_t *min_run = nullptr; // one per behaviour, or null: the brain's
		RowView view;
	};
	struct RowResult {
		int chosen = -1;
		bool kept = false;
		uint64_t asked = 0;
		uint64_t unknown = 0;
	};
	// AIBehaviourManager.decide(), step for step, for one decision. Both ways in use it.
	RowResult decide_row(const Brain &brain, const RowInput &in);
	bool row_ok(int row) const;
	// TagQuery.matches_words(): the behaviour's tag requirements against the owned words (true with none).
	static bool passes_gate(const Behaviour &behaviour, const uint64_t *owned, int64_t owned_count);

	// is_available() once per decision, as the manager's _is_available: asked holds which were asked, answers what they said.
	bool is_available(const Brain &brain, int slot, const RowView &row, uint64_t &asked, uint64_t &answers, uint64_t &unknown) const;
	double score(const Brain &brain, int slot, const RowView &row) const;
	// One condition, as AICondition.passes(): behaviour_salt is the behaviour's name hash, for chance rolls.
	bool passes(const Brain &brain, const Condition &condition, const RowView &row, int64_t behaviour_salt) const;
	// Adds a list of described conditions to the brain, contiguously, and says where. False, with an error, for an unknown kind.
	static bool add_conditions(const Array &list, Brain &brain, int &first, int &count);

	// What every decider shares: the brains, by number and by key, and the input slots' kinds. Made on first use; freed by
	// free_shared() as the library unloads, before Godot's own teardown (a static Dictionary or StringName left to the C++ runtime's
	// exit would be destroyed after Godot's memory is gone).
	struct Shared {
		std::vector<Brain> brains;
		Dictionary by_key; // key -> brain number
		int stride = 0; // the most behaviours any brain has
		std::vector<int32_t> input_kinds; // AIInputs.Kind by slot
	};
	static Shared *s_shared;
	static Shared &shared();

	std::vector<Candidate> _candidates; // reused every row
	std::vector<int> _ties;
	std::vector<PawnRow> _pawns; // rows, some free (brain -1)
	std::vector<int> _free_rows;
	std::unordered_map<int64_t, int> _row_of_id;
	std::vector<double> _inputs_scratch; // decide_pawn's worked-out inputs, reused
	bool _last_kept = false;
};

} // namespace godot
