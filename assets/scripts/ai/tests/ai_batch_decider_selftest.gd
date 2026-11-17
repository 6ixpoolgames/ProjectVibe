## Written by Claude (claude-opus-5-5), 2026-11-17: headless self-test for the C++ AIBatchDecider (scaling spec 6.2, the shadow
## decider), against GDScript's AIBehaviourManager. GDScript decides as usual while an AIDecisionRecorder records, and every recorded
## decision is replayed through the C++ decider (decision_replay.gd), which must choose the same behaviour, keep the running one when
## GDScript did, and ask is_available() of exactly the same behaviours.
## Covers: the random numbers bit for bit; brains (the fixed order, states, the 64-behaviour limit); made-up brains that use every rule
## the real ones don't (jitter, persistence that fades, floors, cooldowns, targets, actions, states, min_run_ticks, interrupt
## thresholds, cannot_be_interrupted, random ties, a behaviour ending); that a planted mismatch is caught; and a real fight in the
## faction arena; and live shadow mode (AIDecisionBatcher), which must agree on every decision and change none of GDScript's.
## Exits 0 on success, 1 on failure. Run from the project folder:
##   godot --headless --path . "res://assets/scripts/ai/tests/ai_batch_decider_selftest.tscn"
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

	func is_available(_context: AIContextComponent) -> bool:
		return available

	func score(_context: AIContextComponent) -> float:
		return value

	func tick(_context: AIContextComponent) -> Status:
		return finish_with


## A state a test can switch on.
class SwitchState extends AIStateBase:
	var fits := false

	func prerequisites_met(_context: AIContextComponent) -> bool:
		return fits


var _recorder: AIDecisionRecorder = null
var _batcher: AIDecisionBatcher = null # shadow mode, on from the made-up brains through the real fight


func _ready() -> void:
	TickDriver.tick_rate = TickDriver.REFERENCE_RATE
	print("--- AI batch decider self-test ---")
	if not ClassDB.class_exists(&"AIBatchDecider"):
		_check(false, "the navcore library has AIBatchDecider (rebuild native/ with the editor closed)")
		_finish()
		return
	_recorder = AIDecisionRecorder.new()
	add_child(_recorder)
	_test_random_numbers()
	_test_brains()
	_test_made_up_brains()
	await _test_real_fight()
	_recorder.stop()
	if _batcher:
		GameMode.remove_module(_batcher)
		_check(AIBehaviourManager.decision_batcher == null, "removing the module switches shadow mode off")
	_finish()


func _test_random_numbers() -> void:
	var pawn := _make_pawn([_b("Alpha", 0.5)])
	var context := pawn.ai_context
	var decider: Object = ClassDB.instantiate(&"AIBatchDecider")
	var all_same := true
	for seed: int in [0, 12345, -7]:
		context.random_seed = seed
		for tick: int in [0, 1, 999, 123456789]:
			for salt: int in [0, 0x7135, 2817701341, 4229566536]:
				all_same = all_same and decider.random_unit(seed, context.pawn_number(), tick, salt) == context.random_unit_at(tick, salt)
	_check(all_same, "C++ random numbers equal GDScript's, bit for bit (negative seeds and salts over 2^31 included)")
	pawn.free()


func _test_brains() -> void:
	var decider: Object = ClassDB.instantiate(&"AIBatchDecider")
	var brain: int = decider.add_brain({"behaviours": [
		{"name": "Zulu", "allowed_states": ["Combat"]},
		{"name": "Alpha", "allowed_states": []},
		{"name": "Mike", "allowed_states": ["Alert", "Combat"]},
	]})
	_check_equal(brain, 0, "a brain is added")
	_check(decider.get_behaviour_name(brain, 0) == &"Alpha" and decider.get_behaviour_name(brain, 2) == &"Zulu", "its behaviours are in the fixed order, by name")
	_check_equal(decider.find_behaviour(brain, &"Mike"), 1, "find_behaviour gives the slot")
	_check(decider.find_state(brain, &"Combat") > 0 and decider.find_state(brain, &"Alert") > 0, "named states get numbers")
	_check_equal(decider.find_state(brain, &"Idle"), 0, "a state no behaviour names is 0, the any-state mask")
	_check_equal(decider.get_stride(), 3, "the stride is the largest brain's behaviour count")
	var too_many: Array = []
	for i in 65:
		too_many.append({"name": "B%02d" % i})
	_check_equal(decider.add_brain({"behaviours": too_many}), -1, "65 behaviours in one brain are refused (one 64-bit mask a brain)")
	_check_equal(decider.add_brain({"behaviours": [{"name": "X", "scorer": "no_such_scorer"}]}), -1, "an unknown scorer is refused")


func _test_made_up_brains() -> void:
	_recorder.clear()
	_recorder.start()
	var choices := _play_made_up(null)
	_recorder.stop()
	# What the run covered, so a quiet run can't pass by accident.
	var kept := 0
	var ended := 0
	var jitter := 0
	var persisting := 0
	var tie_picks := {}
	for record in _recorder.get_records():
		kept += 1 if record.kept_by_interrupt else 0
		ended += 1 if record.cause == AIDecisionRecord.CAUSE_BEHAVIOUR_ENDED else 0
		if record.pawn_name == &"Two":
			tie_picks[record.chosen] = true
		for entry in record.behaviours:
			jitter += 1 if entry.get("jitter", 0.0) != 0.0 else 0
			persisting += 1 if entry.get("persistence", 0.0) != 0.0 else 0
	_check(kept > 20 and ended > 20 and jitter > 100 and persisting > 20 and tie_picks.size() == 3,
			"the made-up brains used every rule (kept %d, ended %d, jittered %d, persisting %d, tie picks %d)" % [kept, ended, jitter, persisting, tie_picks.size()])
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
	# Live shadow mode: the batcher gathers each decision from the live pawns and decides them in C++ at the end of each tick.
	var batcher := AIDecisionBatcher.new()
	GameMode.add_module(batcher)
	batcher.mode = AIDecisionBatcher.Mode.SHADOW
	_check(AIBehaviourManager.decision_batcher == batcher, "shadow mode hooks the batcher into every behaviour manager")
	var shadow_choices := _play_made_up(batcher)
	var counts := batcher.get_counts()
	print("  live shadow, made-up brains: %s" % str(counts))
	_check(counts["decisions"] == decisions_made and counts["agreed"] == counts["decisions"] and counts["unanswered"] == 0,
			"live shadow: C++ agrees with every decision (%d of %d)" % [counts["agreed"], decisions_made])
	_check(shadow_choices == choices and not choices.is_empty(), "shadow mode changes nothing: GDScript makes the same %d changes of behaviour with it on" % choices.size())
	batcher.reset_counts()
	_batcher = batcher # kept on for the real fight


# The made-up brains, decided 400 ticks by hand. Returns every change of behaviour, as "pawn:behaviour", in order. With a batcher,
# its rows are decided at the end of each tick, as the TickDriver's after_tick would.
func _play_made_up(batcher: AIDecisionBatcher) -> Array[String]:
	var choices: Array[String] = []
	var note := func(_old: AIBehaviourBase, new: AIBehaviourBase, _reason: String, who: String) -> void:
		choices.append("%s:%s" % [who, String(new.name) if new else ""])
	# Pawn one: jitter on everything, persistence that fades, floors, a cooldown, a target, an action, a state, a behaviour ending.
	var alarm := SwitchState.new()
	alarm.name = "Alarm"
	alarm.priority = 10
	var alpha := _b("Alpha", 0.5)
	alpha.persistence = 0.3
	alpha.persistence_fade = _linear(5, 20)
	var bravo := _b("Bravo", 0.45)
	bravo.min_score = 0.4
	var charlie := _b("Charlie", 0.6, 0.9) # scores below its max
	var delta := _b("Delta", 0.55)
	delta.cooldown_ticks = 10
	delta.finish_with = AIBehaviourBase.Status.SUCCEEDED
	var echo := _b("Echo", 0.95)
	echo.needs_target = true
	var foxtrot := _b("Foxtrot", 0.97)
	foxtrot.presses_action = &"no_such_action"
	var golf := _b("Golf", 0.65)
	golf.allowed_states = [&"Alarm"]
	golf.min_score = 0.6
	var one := _make_pawn([alpha, bravo, charlie, delta, echo, foxtrot, golf], [alarm])
	one.name = "One"
	one.ai_context.behaviour_manager.default_score_jitter = 0.2
	one.ai_context.random_seed = 4242
	# Pawn two: equal scores and random ties.
	var two := _make_pawn([_b("Kilo", 0.5), _b("Lima", 0.5), _b("November", 0.5)])
	two.name = "Two"
	two.ai_context.behaviour_manager.randomize_ties = true
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
		pawn.ai_context.behaviour_manager.behaviour_changed.connect(note.bind(String(pawn.name)))
	for t in 400:
		var tick := 5000 + t
		alpha.available = t % 11 != 0
		charlie.available = t % 7 < 3
		bravo.available = t % 5 != 1
		alarm.fits = t % 50 >= 30
		var priority := 10 if t % 13 == 0 else 0
		_decide(one, tick, priority, priority == 0)
		one.ai_context.behaviour_manager.tick_running(tick) # Delta ends at once when it runs
		_decide(two, tick)
		hotel.available = t % 9 < 6
		juliet.available = t % 40 < 3
		juliet.finish_with = AIBehaviourBase.Status.SUCCEEDED if t % 40 == 20 else AIBehaviourBase.Status.RUNNING
		_decide(three, tick, [0, 3, 5, 9][t % 4], t % 3 != 0)
		three.ai_context.behaviour_manager.tick_running(tick)
		if batcher:
			batcher.decide_gathered()
	for pawn: Pawn in [one, two, three]:
		pawn.free()
	return choices


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
	_check(summary["decisions"] > 500 and chosen.has("Attack") and chosen.has("Chase"),
			"a real fight: %d decisions by %d pawns, with attacks and chases (%s)" % [summary["decisions"], summary["pawns"], str(chosen)])
	var result := DecisionReplay.compare(DecisionReplay.from_recorder(_recorder))
	print("  faction arena: " + DecisionReplay.describe(result))
	for example: String in result["examples"]:
		print("    " + example)
	_check(result["agreed"] == result["decisions"], "C++ makes every decision of a real fight the same way")
	_check_equal(result["asked_unknown"], 0, "...and never asks for an answer GDScript didn't give")
	if _batcher:
		var counts := _batcher.get_counts()
		print("  live shadow, faction arena: %s" % str(counts))
		_check(counts["decisions"] > 500 and counts["agreed"] == counts["decisions"] and counts["unanswered"] == 0,
				"live shadow in a real fight: C++ agrees with every decision (%d of %d), batched once a tick" % [counts["agreed"], counts["decisions"]])
	arena.queue_free()
	await get_tree().physics_frame


# --- Helpers ---


func _b(behaviour_name: String, value: float, max := -1.0) -> TestBehaviour:
	var behaviour := TestBehaviour.new()
	behaviour.name = behaviour_name
	behaviour.value = value
	behaviour.max_score = value if max < 0.0 else max
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
	pawn.add_child(manager)
	if not states.is_empty():
		var state_manager := AIStateManager.new()
		state_manager.name = "AIStateManager"
		for state in states:
			state_manager.add_child(state)
		var idle := AIIdleState.new()
		idle.name = "Idle"
		state_manager.add_child(idle)
		pawn.add_child(state_manager)
	add_child(pawn)
	pawn.ai_context.decision_interval_ticks = NEVER
	return pawn


func _decide(pawn: Pawn, tick: int, priority := 0, normal := true) -> void:
	var context := pawn.ai_context
	context.current_tick = tick
	context.request_decision(priority, normal)
	context.state_manager.update_state(tick)
	context.behaviour_manager.decide(tick)
