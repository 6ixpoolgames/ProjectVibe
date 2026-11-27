## Written by Claude (claude-opus-5-5), 2026-11-17: headless self-test for the C++ AIDecider (scaling spec 6.2, the shadow
## decider), against GDScript's AIBehaviourManager. GDScript decides as usual while an AIDecisionRecorder records, and every recorded
## decision is replayed through the C++ decider (decision_replay.gd), which must choose the same behaviour, keep the running one when
## GDScript did, and ask is_available() of exactly the same behaviours.
## Covers: the random numbers bit for bit; brains (the fixed order, states, the 64-behaviour limit); made-up brains that use every rule
## the real ones don't (jitter, persistence that fades, floors, cooldowns, targets, actions, states, min_run_ticks, interrupt
## thresholds, cannot_be_interrupted, random ties, a behaviour ending); that a planted mismatch is caught; and a real fight in the
## faction arena; and live shadow mode (AIDecisionChecks.set_check_against_gdscript; Claude 2026-11-26: was the AIDecisionModule's), which must agree on every decision and change none
## of GDScript's. Claude 2026-11-18 (step 5c): the made-up brains' test behaviours have code of their own, so they're special minds
## that stay in GDScript (Claude 2026-11-26, step 6d: now they decide in C++ from GDScript's answers, checked in shadow mode); shadow mode checks the real fight, whose built-in behaviours C++ reads, from C++'s own copy of each pawn's
## state.
## Claude 2026-11-17 (step 5b): and in the real fight, that the AI's kept answer to "could this action start?" (AIInputs.action_ready,
## asked again only when AbilityManager.readiness_version moves on) matches asking AbilityManager.can_start at every decision.
## Claude 2026-11-27 (AI scoring proposal): floors and ceilings are gone (one open score); a score's modifiers replay as its multiply
## and add.
## Exits 0 on success, 1 on failure. Run from the project folder:
##   godot --headless --path . "res://assets/scripts/ai/tests/ai_decider_selftest.tscn"
extends SelfTest

const DecisionReplay := preload("res://assets/scripts/ai/tests/decision_replay.gd")
const PAWN_SCENE := "res://assets/scenes/pawn/pawn.tscn"
const ARENA := "res://assets/scenes/samples/faction_arena_sample.tscn"
const NEVER := 100000000
const FIGHT_SECONDS := 12


## A behaviour a test controls: its score, whether it's available, and how its tick ends.
class TestBehaviour extends AIBehaviourBase:
	var value := 0.5
	var available := true
	var finish_with := Status.RUNNING

	func is_available(_context: AIManager) -> bool:
		return available

	func score(_context: AIManager) -> float:
		return value

	func tick(_context: AIManager) -> Status:
		return finish_with


## A state a test can switch on.
class SwitchState extends AIStateBase:
	var fits := false

	func prerequisites_met(_context: AIManager) -> bool:
		return fits


## A recorder that also checks, at each decision, every action the decision's hard rule looked at: the kept answer it used (the
## record's rule) against AbilityManager.can_start asked now. Claude 2026-11-17.
class ReadinessCheckingRecorder extends AIDecisionRecorder:
	var checked := 0
	var mismatches: Array[String] = []

	func _on_decision(record: AIDecisionRecord, manager: AIBehaviourManager) -> void:
		super(record, manager)
		var abilities := manager.pawn.ability_manager if manager.pawn else null
		if abilities == null or record.kept_by_interrupt:
			return
		for behaviour in manager.get_behaviours():
			if behaviour.presses_action == &"" or behaviour.name == record.running_before:
				continue
			var entry := record.entry_for(behaviour.name)
			var rule: StringName = entry.get("rule", &"tags")
			if rule != AIDecisionRecord.RULE_ACTION and rule != AIDecisionRecord.RULE_NONE:
				continue # ruled out before the action was looked at
			checked += 1
			var kept_answer := rule == AIDecisionRecord.RULE_NONE
			if kept_answer != abilities.can_start(behaviour.presses_action) and mismatches.size() < 5:
				mismatches.append("tick %d, %s, %s: kept %s" % [record.tick, record.pawn_name, behaviour.presses_action, kept_answer])


var _recorder: AIDecisionRecorder = null


func _ready() -> void:
	TagRegistry.declare([&"ai.state.alarm"]) # the test's own Alarm state's tag (AIStateBase.get_tag)
	TickDriver.tick_rate = TickDriver.REFERENCE_RATE
	print("--- AI decider self-test ---")
	if not ClassDB.class_exists(&"AIDecider"):
		_check(false, "the navcore library has AIDecider (rebuild native/ with the editor closed)")
		_finish()
		return
	_recorder = ReadinessCheckingRecorder.new()
	add_child(_recorder)
	_test_random_numbers()
	_test_brains()
	_test_made_up_brains()
	_test_gates_and_modifiers()
	await _test_real_fight()
	_recorder.stop()
	AIDecisionChecks.set_check_against_gdscript(false)
	_finish()


func _test_random_numbers() -> void:
	var pawn := _make_pawn([_b("Alpha", 0.5)])
	var context := pawn.ai
	var decider: Object = ClassDB.instantiate(&"AIDecider")
	var all_same := true
	for seed: int in [0, 12345, -7]:
		context.random_seed = seed
		for tick: int in [0, 1, 999, 123456789]:
			for salt: int in [0, 0x7135, 2817701341, 4229566536]:
				all_same = all_same and decider.random_unit(seed, pawn.entity_number(), tick, salt) == context.random_unit_at(tick, salt)
				# Claude 2026-11-24 (pawn spec 16.9): the shared service is the same hash, with any key.
				for key: int in [0, 7, 2147483647, -1]:
					all_same = all_same and decider.random_unit(seed, key, tick, salt) == DeterministicRandom.unit_seeded(seed, key, tick, salt)
	_check(all_same, "C++ random numbers equal GDScript's (the AI's and DeterministicRandom's), bit for bit (negative seeds and salts over 2^31 included)")
	pawn.free()


func _test_brains() -> void:
	var decider: Object = ClassDB.instantiate(&"AIDecider")
	var words := TagRegistry.get_categories().size()
	var brain: int = decider.add_brain({"tag_words": words, "behaviours": [
		{"name": "Zulu", "scorer": "conditions", "tag_requirements": TagQuery.make([Tags.AI.STATE_COMBAT]).describe_words()},
		{"name": "Alpha", "scorer": "conditions", "base_score": 0.1},
		{"name": "Mike", "scorer": "conditions", "tag_requirements": TagQuery.make([], [Tags.AI.STATE_ALERT, Tags.AI.STATE_COMBAT]).describe_words()},
	]})
	_check_equal(brain, 0, "a brain is added")
	_check(decider.get_behaviour_name(brain, 0) == &"Alpha" and decider.get_behaviour_name(brain, 2) == &"Zulu", "its behaviours are in the fixed order, by name")
	_check_equal(decider.find_behaviour(brain, &"Mike"), 1, "find_behaviour gives the slot")
	_check_equal(decider.get_stride(), 3, "the stride is the largest brain's behaviour count")
	# Tag requirements against each row's owned tags: idle (neither passes), alert (Mike), combat (both: a tie, Mike first by order),
	# and combat with Mike blocked by a modifier, and with Zulu raised by one.
	var owned_rows := [[Tags.AI.STATE_IDLE], [Tags.AI.STATE_ALERT], [Tags.AI.STATE_COMBAT], [Tags.AI.STATE_COMBAT], [Tags.AI.STATE_COMBAT]]
	var rows := owned_rows.size()
	var owned := PackedInt64Array()
	for tags: Array in owned_rows:
		owned.append_array(TagQuery.words_of(tags))
	var zeros := PackedFloat64Array()
	zeros.resize(rows * 3)
	zeros.fill(0.0)
	var modifier := zeros.duplicate()
	modifier[4 * 3 + 2] = 0.2 # row 4, Zulu
	var columns := {"brain": PackedInt32Array([0, 0, 0, 0, 0]), "pawn_number": PackedInt64Array([1, 1, 1, 1, 1]),
		"random_seed": PackedInt64Array([0, 0, 0, 0, 0]), "tick": PackedInt64Array([1, 1, 1, 1, 1]), "owned": owned, "tag_words": words,
		"has_target": PackedByteArray([0, 0, 0, 0, 0]), "event_normal": PackedByteArray([1, 1, 1, 1, 1]),
		"event_priority": PackedInt32Array([0, 0, 0, 0, 0]), "running": PackedInt32Array([-1, -1, -1, -1, -1]),
		"running_started": PackedInt64Array([-1, -1, -1, -1, -1]), "cooling": PackedInt64Array([0, 0, 0, 0, 0]),
		"can_press": PackedInt64Array([-1, -1, -1, -1, -1]), "available_known": PackedInt64Array([0, 0, 0, 0, 0]),
		"available": PackedInt64Array([0, 0, 0, 0, 0]), "score_add": modifier, # Claude 2026-11-27: was the score bonus column
		"blocked": PackedInt64Array([0, 0, 0, 1 << 1, 0])}
	var answer: Dictionary = decider.decide(columns)
	_check_equal(answer.get("chosen", PackedInt32Array()), PackedInt32Array([0, 1, 1, 2, 2]),
		"tag requirements: idle Alpha, alert Mike, combat Mike (a tie, by order), Mike blocked Zulu, Zulu raised Zulu")
	var too_many: Array = []
	for i in 65:
		too_many.append({"name": "B%02d" % i})
	_check_equal(decider.add_brain({"behaviours": too_many}), -1, "65 behaviours in one brain are refused (one 64-bit mask a brain)")
	_check_equal(decider.add_brain({"behaviours": [{"name": "X", "scorer": "no_such_scorer"}]}), -1, "an unknown scorer is refused")


func _test_made_up_brains() -> void:
	_recorder.clear()
	_recorder.start()
	# Claude 2026-11-26 (step 6d): recorded with GDScript deciding, since a C++ decision's record leaves GDScript's numbers out; their
	# behaviours have code of their own, so they'd decide in C++ from GDScript's answers otherwise (checked in shadow mode below).
	AIDecisionChecks.set_all_in_gdscript(true)
	var choices := _play_made_up(false)
	AIDecisionChecks.set_all_in_gdscript(false)
	_recorder.stop()
	# What the run covered, so a quiet run can't pass by accident.
	var kept := 0
	var ended := 0
	var jitter := 0
	var boosted := 0 # Claude 2026-11-25 (pawn spec 16.10 step 6a): was persisting; persistence is gone, Alpha boosts itself
	var tie_picks := {}
	for record in _recorder.get_records():
		kept += 1 if record.kept_by_interrupt else 0
		ended += 1 if record.cause == AIDecisionRecord.CAUSE_BEHAVIOUR_ENDED else 0
		if record.pawn_name == &"Two":
			tie_picks[record.chosen] = true
		for entry in record.behaviours:
			jitter += 1 if entry.get("jitter", 0.0) != 0.0 else 0
			boosted += 1 if entry.get("score_add", 0.0) != 0.0 else 0
	_check(kept > 20 and ended > 20 and jitter > 100 and boosted > 20 and tie_picks.size() == 3,
			"the made-up brains used every rule (kept %d, ended %d, jittered %d, boosted %d, tie picks %d)" % [kept, ended, jitter, boosted, tie_picks.size()])
	var data := DecisionReplay.from_recorder(_recorder)
	var result := DecisionReplay.compare(data)
	print("  made-up brains: " + DecisionReplay.describe(result))
	for example: String in result["examples"]:
		print("    " + example)
	_check(result["decisions"] > 1000 and result["agreed"] == result["decisions"], "C++ makes every one of GDScript's decisions the same way")
	_check_equal(result["brains"], 3, "three different brains")
	# A planted mismatch must be caught: the check isn't vacuous.
	var planted: Dictionary = data["decisions"][0]
	planted["chosen"] = "Golf" if planted["chosen"] != "Golf" else "Alpha"
	_check_equal(DecisionReplay.compare(data)["agreed"], result["decisions"] - 1, "a decision changed after recording is caught")
	var decisions_made: int = result["decisions"]
	_recorder.clear()
	# Live shadow mode (on from here through the real fight): the made-up brains' behaviours have code of their own, so they're
	# special minds that stay in GDScript, and nothing changes. Claude 2026-11-26 (step 6d): now they decide in C++ with GDScript's answers
	# for every behaviour, and shadow mode must agree at every decision.
	AIDecisionChecks.set_check_against_gdscript(true)
	AIDecisionChecks.reset_counts()
	var shadow_choices := _play_made_up(true)
	var counts := AIDecisionChecks.get_counts()
	print("  live shadow, made-up brains: %s (decisions %d)" % [str(counts), decisions_made])
	_check(counts["checked"] > 300 and counts["agreed"] == counts["checked"] and counts["gdscript_answers"] > 0,
			"the made-up brains (code of their own) decide in C++ from GDScript's answers, and agree with GDScript at every decision (%d of %d)" % [counts["agreed"], counts["checked"]])
	_check(shadow_choices == choices and not choices.is_empty(), "shadow mode changes nothing: GDScript makes the same %d changes of behaviour with it on" % choices.size())
	AIDecisionChecks.reset_counts()


# The made-up brains, decided 400 ticks by hand. Returns every change of behaviour, as "pawn:behaviour", in order.
func _play_made_up(_shadow: bool) -> Array[String]:
	var choices: Array[String] = []
	var note := func(_old: AIBehaviourBase, new: AIBehaviourBase, _reason: String, who: String) -> void:
		choices.append("%s:%s" % [who, String(new.name) if new else ""])
	# Pawn one: jitter on everything, a boost it gives itself as it starts (Claude 2026-11-25: was persistence that fades), floors, a
	# cooldown, a target, an action, a state, a behaviour ending.
	var alarm := SwitchState.new()
	alarm.name = "Alarm"
	alarm.priority = 10
	var alpha := _b("Alpha", 0.5)
	var boost := AIBehaviourModifier.new()
	boost.add = 0.3
	boost.duration_ticks = 15
	alpha.modifier_on_start = boost
	var bravo := _b("Bravo", 0.45)
	var charlie := _b("Charlie", 0.6)
	var delta := _b("Delta", 0.55)
	delta.cooldown_ticks = 10
	delta.finish_with = AIBehaviourBase.Status.SUCCEEDED
	var echo := _b("Echo", 0.95)
	echo.needs_target = true
	var foxtrot := _b("Foxtrot", 0.97)
	foxtrot.presses_action = &"no_such_action"
	var golf := _b("Golf", 0.65)
	golf.tag_requirements = TagQuery.make([&"ai.state.alarm"])
	var one := _make_pawn([alpha, bravo, charlie, delta, echo, foxtrot, golf], [alarm])
	one.name = "One"
	one.ai.behaviour_manager.default_score_jitter = 0.2
	one.ai.random_seed = 4242
	# Pawn two: equal scores and random ties.
	var two := _make_pawn([_b("Kilo", 0.5), _b("Lima", 0.5), _b("November", 0.5)])
	two.name = "Two"
	two.ai.behaviour_manager.randomize_ties = true
	# Pawn three: the interrupt rules. Hotel needs 8 ticks before an ordinary decision replaces it, and a reason of 5 or more;
	# Juliet, when it gets in, can't be interrupted at all, and ends after a while.
	var hotel := _b("Hotel", 0.6)
	hotel.min_run_ticks = 8
	hotel.interrupt_threshold = 5
	var india := _b("India", 0.5)
	var juliet := _b("Juliet", 0.7)
	juliet.cannot_be_interrupted = true
	var three := _make_pawn([hotel, india, juliet])
	three.name = "Three"
	for pawn: Pawn in [one, two, three]:
		pawn.ai.behaviour_manager.behaviour_changed.connect(note.bind(String(pawn.name)))
	for t in 400:
		var tick := 5000 + t
		alpha.available = t % 11 != 0
		charlie.available = t % 7 < 3
		bravo.available = t % 5 != 1
		alarm.fits = t % 50 >= 30
		var priority := 10 if t % 13 == 0 else 0
		_decide(one, tick, priority, priority == 0)
		one.ai.behaviour_manager.tick_running(tick) # Delta ends at once when it runs
		_decide(two, tick)
		hotel.available = t % 9 < 6
		juliet.available = t % 40 < 3
		juliet.finish_with = AIBehaviourBase.Status.SUCCEEDED if t % 40 == 20 else AIBehaviourBase.Status.RUNNING
		_decide(three, tick, [0, 3, 5, 9][t % 4], t % 3 != 0)
		three.ai.behaviour_manager.tick_running(tick)
	for pawn: Pawn in [one, two, three]:
		pawn.free()
	return choices


# Claude 2026-11-23 (pawn spec 10.13): tag requirements, switched-off behaviours, score modifiers and blocks, in both deciders. Plain
# behaviours (no code of their own), so the pawn decides in C++ too: recorded decisions are replayed through decide(), and live shadow
# mode checks decide_pawn() and the facts written into the row (owned tags, modifiers).
func _test_gates_and_modifiers() -> void:
	var melee := _plain("Melee", 0.8)
	melee.tags = [Tags.AI.STANCE_MELEE]
	var ranged := _plain("Ranged", 0.85)
	ranged.tags = [Tags.AI.STANCE_RANGED]
	ranged.tag_requirements = TagQuery.make([Tags.STATUS.HAS_AMMO_RANGED])
	ranged.min_run_ticks = 20
	var hold := _plain("Hold", 0.95)
	var rest := _plain("Rest", 0.1)
	var pawn := _make_pawn([melee, ranged, hold, rest])
	pawn.name = "Four"
	var manager := pawn.ai.behaviour_manager
	var charge := AIBehaviourModifier.new()
	charge.applies_to = TagQuery.make([], [Tags.AI.STANCE_MELEE])
	charge.add = 0.1
	var no_ranged := AIBehaviourModifier.new()
	no_ranged.applies_to = TagQuery.make([], [Tags.AI.STANCE_RANGED])
	no_ranged.blocks = true
	no_ranged.duration_ticks = 15
	# Claude 2026-11-25 (pawn spec 16.10 step 6a): modifiers changing the other numbers, which C++ gets as numbers.
	var wild := AIBehaviourModifier.new()
	wild.number = AIBehaviourModifier.Number.SCORE_JITTER
	wild.add = 0.1
	var steady := AIBehaviourModifier.new()
	steady.number = AIBehaviourModifier.Number.MIN_RUN_TICKS
	steady.add = 12.0
	steady.applies_to = charge.applies_to
	var firm := AIBehaviourModifier.new()
	firm.number = AIBehaviourModifier.Number.INTERRUPT_THRESHOLD
	firm.overrides = true
	firm.override_value = 5.0
	firm.applies_to = no_ranged.applies_to
	var slow := AIBehaviourModifier.new()
	slow.number = AIBehaviourModifier.Number.COOLDOWN_TICKS
	slow.add = 15.0
	AIDecisionChecks.reset_counts()
	_recorder.clear()
	_recorder.start()
	var chosen := {}
	for t in 400:
		var tick := 9000 + t
		TickDriver.tick = tick
		if t % 37 == 0:
			pawn.owned_tags.add(Tags.STATUS.HAS_AMMO_RANGED)
		elif t % 37 == 20:
			pawn.owned_tags.remove(Tags.STATUS.HAS_AMMO_RANGED)
		if t % 60 == 10:
			manager.add_modifier(charge, self)
		elif t % 60 == 40:
			manager.remove_modifiers(self)
		if t % 90 == 50:
			manager.add_modifier(no_ranged, &"block")
		if t % 80 == 5:
			manager.add_modifier(wild, &"wild")
		elif t % 80 == 45:
			manager.remove_modifiers(&"wild")
		if t % 100 == 15:
			for numbers: AIBehaviourModifier in [steady, firm, slow]:
				manager.add_modifier(numbers, &"numbers")
		elif t % 100 == 70:
			manager.remove_modifiers(&"numbers")
		hold.enabled = t % 70 >= 60
		manager.check_running(tick)
		_decide(pawn, tick, 0, t % 5 != 0)
		var running := manager.get_running_behaviour()
		chosen[running.name if running else &""] = true
	_recorder.stop()
	var rules := {}
	var summed := 0
	for record in _recorder.get_records():
		for entry in record.behaviours:
			rules[entry["rule"]] = true
			summed += 1 if entry.get("score_add", 0.0) != 0.0 else 0
	_check(chosen.has(&"Melee") and chosen.has(&"Ranged") and chosen.has(&"Hold") and rules.has(AIDecisionRecord.RULE_TAGS)
			and rules.has(AIDecisionRecord.RULE_OFF) and rules.has(AIDecisionRecord.RULE_BLOCKED) and summed > 20,
			"the run used gates, switching off, blocks and sums (chosen %s, rules %s, summed %d)" % [chosen.keys(), rules.keys(), summed])
	var result := DecisionReplay.compare(DecisionReplay.from_recorder(_recorder))
	print("  gates and modifiers: " + DecisionReplay.describe(result))
	for example: String in result["examples"]:
		print("    " + example)
	_check(result["decisions"] > 300 and result["agreed"] == result["decisions"], "C++ decide() makes every gated and modified decision the same way")
	var counts := AIDecisionChecks.get_counts()
	print("  live shadow, gates and modifiers: %s" % str(counts))
	_check(counts["checked"] > 300 and counts["agreed"] == counts["checked"], "live shadow: decide_pawn() agrees with every one (%d of %d)" % [counts["agreed"], counts["checked"]])
	_check_equal(counts["stale_facts"], 0, "...and the owned tags and modifiers written into its row were never out of date")
	_recorder.clear()
	AIDecisionChecks.reset_counts()
	pawn.free()


func _plain(behaviour_name: String, score: float) -> AIBehaviourBase:
	var behaviour := AIBehaviourBase.new()
	behaviour.name = behaviour_name
	behaviour.base_score = score
	return behaviour


func _test_real_fight() -> void:
	var arena: Node = load(ARENA).instantiate()
	add_child(arena)
	await get_tree().physics_frame
	arena._start_offline()
	_recorder.clear()
	_recorder.start()
	for i in FIGHT_SECONDS * TickDriver.get_tick_rate():
		await get_tree().physics_frame
	_recorder.stop()
	var summary := _recorder.summary()
	var chosen: Dictionary = summary["chosen"]
	# Claude 2026-11-18 (Keep Distance): the faction pawns now mostly hang back and shoot, so either kind of attack and of closing in counts.
	_check(summary["decisions"] > 500 and (chosen.has("Attack") or chosen.has("Shoot")) and (chosen.has("Chase") or chosen.has("KeepDistance")),
			"a real fight: %d decisions by %d pawns, with attacks and closing in (%s)" % [summary["decisions"], summary["pawns"], str(chosen)])
	var result := DecisionReplay.compare(DecisionReplay.from_recorder(_recorder))
	print("  faction arena: " + DecisionReplay.describe(result))
	for example: String in result["examples"]:
		print("    " + example)
	_check(result["agreed"] == result["decisions"], "C++ makes every decision of a real fight the same way")
	_check_equal(result["asked_unknown"], 0, "...and never asks for an answer GDScript didn't give")
	var readiness := _recorder as ReadinessCheckingRecorder
	_check(readiness.checked > 200 and readiness.mismatches.is_empty(),
			"the kept 'could this action start' answers match AbilityManager.can_start (%d checked; %s)" % [readiness.checked, str(readiness.mismatches)])
	if AIDecisionChecks.check_against_gdscript:
		var counts := AIDecisionChecks.get_counts()
		print("  live shadow, faction arena: %s" % str(counts))
		_check(counts["checked"] > 500 and counts["agreed"] == counts["checked"],
				"live shadow in a real fight: C++ agrees with every decision, from its own copy of each pawn's state (%d of %d)" % [counts["agreed"], counts["checked"]])
		# Claude 2026-11-18: every fact C++ decides from was written through when it changed (state, target, readiness).
		_check_equal(counts["stale_facts"], 0, "...and no written-through fact was out of date at any decision")
	arena.queue_free()
	await get_tree().physics_frame


# --- Helpers ---


func _b(behaviour_name: String, value: float) -> TestBehaviour:
	var behaviour := TestBehaviour.new()
	behaviour.name = behaviour_name
	behaviour.value = value
	return behaviour


func _linear(hold: int, fade: int) -> FadeProfile:
	var profile := FadeProfile.new()
	profile.mode = FadeProfile.Mode.LINEAR
	profile.hold_ticks = hold
	profile.fade_ticks = fade
	return profile


func _make_pawn(behaviours: Array, states: Array = [], at := Vector3(0, 1000, 0)) -> Pawn:
	var pawn: Pawn = load(PAWN_SCENE).instantiate()
	pawn.position = at
	var manager := AIBehaviourManager.new()
	manager.name = "AIBehaviourManager"
	for behaviour in behaviours:
		manager.add_child(behaviour)
	AITestPawns.ai_of(pawn).add_child(manager)
	if not states.is_empty():
		var state_manager := AIStateManager.new()
		state_manager.name = "AIStateManager"
		for state in states:
			state_manager.add_child(state)
		var idle := AIIdleState.new()
		idle.name = "Idle"
		state_manager.add_child(idle)
		AITestPawns.ai_of(pawn).add_child(state_manager)
	add_child(pawn)
	pawn.ai.decision_interval_ticks = NEVER
	return pawn


func _decide(pawn: Pawn, tick: int, priority := 0, normal := true) -> void:
	var context := pawn.ai
	context.current_tick = tick
	context.request_decision(priority, normal)
	context.state_manager.update_state(tick)
	context.behaviour_manager.decide(tick)
