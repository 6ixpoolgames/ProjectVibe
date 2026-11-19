## Written by Claude (claude-opus-5-5), 2026-11-17: headless self-test for AI conditions as data (scaling spec 6.2, step 5b): the
## pawn's inputs (AIInputs), the condition kinds (AICompareCondition, AIChanceCondition, AIAnyCondition), score curves (AIScoreCurve),
## a behaviour's score with curves, has_own_code(), and the C++ decider (AIBatchDecider's "conditions" scorer) judging the same
## conditions and curves the same way: live shadow mode over made-up brains fed random inputs, which must agree on every decision.
## Claude 2026-11-18 (step 5c): and C++ driving (the main path) plays the same game as GDScript driving, persistence, a per-pawn
## persistence mask, jitter changes and behaviours finishing included; and where pawns decide (setting, override, special minds).
## Claude 2026-11-18 (a review's finding): a group point that moves, or is freed, between the lookup's 2-second looks gives C++ and
## GDScript the same answer.
## Exits 0 on success, 1 on failure. Run from the project folder:
##   godot --headless --path . "res://assets/scripts/ai/tests/ai_conditions_selftest.tscn"
extends SelfTest

const PAWN_SCENE := "res://assets/scenes/pawn/pawn.tscn"
const NEVER := 100000000
const TICKS := 500
const Comparison := AICompareCondition.Comparison


## A behaviour with code of its own, which the C++ decider can't read.
class OwnCodeBehaviour extends AIBehaviourBase:
	func is_available(_context: AIContextComponent) -> bool:
		return true


func _ready() -> void:
	TickDriver.tick_rate = TickDriver.REFERENCE_RATE
	print("--- AI conditions self-test ---")
	_test_inputs()
	_test_compare()
	_test_chance()
	_test_any_and_curves()
	_test_own_code()
	await _test_cpp_agrees()
	_test_moving_group_point()
	_finish()


func _test_inputs() -> void:
	var slot := AIInputs.slot_of(&"test_morale")
	_check_equal(AIInputs.slot_of(&"test_morale"), slot, "a name keeps its slot")
	_check(AIInputs.slot_of(AIInputs.TARGET_DISTANCE) != slot, "different names get different slots")
	_check(AIInputs.is_worked_out(AIInputs.slot_of(AIInputs.TARGET_DISTANCE)) and not AIInputs.is_worked_out(slot),
			"built-in inputs are worked out at decisions; other names are kept")
	_check(AIInputs.is_worked_out(AIInputs.slot_of(&"group_distance/test_group")) and AIInputs.is_worked_out(AIInputs.slot_of(&"action_ready/test")),
			"the group_distance/ and action_ready/ names are worked out too")
	_check(AIInputs.is_ticks(AIInputs.slot_of(AIInputs.TICKS_SINCE_UNKNOWN_HIT)) and not AIInputs.is_ticks(slot),
			"names starting ticks_ are times in ticks")
	var inputs := AIInputs.new()
	_check_equal(inputs.value_of(&"test_never_written"), 0.0, "an input never written reads 0")
	inputs.set_input(&"test_morale", 0.4)
	_check_equal(inputs.value_of(&"test_morale"), 0.4, "set_input writes a kept input")


func _test_compare() -> void:
	var inputs := AIInputs.new()
	inputs.set_input(&"test_a", 2.0)
	inputs.set_input(&"test_b", 0.5)
	var expected := {Comparison.AT_MOST: true, Comparison.LESS_THAN: false, Comparison.AT_LEAST: true, Comparison.MORE_THAN: false,
		Comparison.EQUAL: true, Comparison.NOT_EQUAL: false}
	var all_right := true
	for how: int in expected:
		if AICompareCondition.make(&"test_a", how, 2.0).passes(inputs, null, 0) != expected[how]:
			all_right = false
	_check(all_right, "each comparison: 2 against 2")
	_check(AICompareCondition.make(&"test_a", Comparison.AT_MOST, 1.5, &"test_b").passes(inputs, null, 0)
			and not AICompareCondition.make(&"test_a", Comparison.AT_MOST, 1.4, &"test_b").passes(inputs, null, 0),
			"against another input plus a number: 2 <= 0.5 + 1.5, but not 0.5 + 1.4")
	# A time in ticks: 120 written for 60 ticks a second is 60 at 30.
	inputs.set_input(&"ticks_test_wait", 100.0)
	var wait := AICompareCondition.make(&"ticks_test_wait", Comparison.AT_MOST, 120.0)
	var at_60 := wait.passes(inputs, null, 0)
	TickDriver.tick_rate = 30
	var at_30 := wait.passes(inputs, null, 0)
	var described_at_30: float = wait.describe()["value"]
	TickDriver.tick_rate = TickDriver.REFERENCE_RATE
	_check(at_60 and not at_30 and described_at_30 == 60.0, "a ticks_ input's value is converted to the match's rate (100 <= 120 at 60, not <= 60 at 30)")


func _test_chance() -> void:
	var context := AIContextComponent.new()
	context.random_seed = 99
	var inputs := context.inputs
	var always := AIChanceCondition.make(1.0, 1)
	var never := AIChanceCondition.make(0.0, 1)
	var half := AIChanceCondition.make(0.5, 1)
	var passed := 0
	var always_right := true
	for t in 1000:
		context.current_tick = t
		always_right = always_right and always.passes(inputs, context, 0) and not never.passes(inputs, context, 0)
		passed += 1 if half.passes(inputs, context, 0) else 0
	_check(always_right, "chance 1 always passes, chance 0 never does")
	_check(passed > 420 and passed < 580, "chance 0.5 passes about half the time (%d of 1000)" % passed)
	# Once per input: the roll stays the same while the input does.
	var per_swing := AIChanceCondition.make(0.5, 7, &"test_swing_tick")
	inputs.set_input(&"test_swing_tick", 77.0)
	var first := per_swing.passes(inputs, context, 5)
	var same := true
	for t in 50:
		context.current_tick = 2000 + t
		same = same and per_swing.passes(inputs, context, 5) == first
	_check(same, "with once_per_input, the roll is the same at every decision while the input stays the same")
	_check_equal(per_swing.passes(inputs, context, 5), context.random_unit_at(77, 7 ^ 5) < 0.5,
			"the roll is random_unit_at(the input, salt ^ the behaviour's number)")
	var mixed := AIChanceCondition.make(0.5, 7, &"test_swing_tick", &"test_attacker")
	var differs := false
	for attacker in 40:
		inputs.set_input(&"test_attacker", float(attacker))
		differs = differs or mixed.passes(inputs, context, 5) != first
	_check(differs, "salt_input changes the roll")
	context.free()


func _test_any_and_curves() -> void:
	var inputs := AIInputs.new()
	inputs.set_input(&"test_c", 5.0)
	var yes := AICompareCondition.make(&"test_c", Comparison.EQUAL, 5.0)
	var no := AICompareCondition.make(&"test_c", Comparison.EQUAL, 6.0)
	var none: Array[AICondition] = []
	var no_yes: Array[AICondition] = [no, yes]
	var no_no: Array[AICondition] = [no, no]
	_check(not AIAnyCondition.make(none).passes(inputs, null, 0), "any of nothing never passes")
	_check(AIAnyCondition.make(no_yes).passes(inputs, null, 0) and not AIAnyCondition.make(no_no).passes(inputs, null, 0),
			"any passes when one of its conditions does")
	var rising := AIScoreCurve.make(&"test_c", 0.0, 10.0)
	var falling := AIScoreCurve.make(&"test_c", 10.0, 0.0)
	var step := AIScoreCurve.make(&"test_c", 5.0, 5.0)
	_check_near(rising.amount(inputs), 0.5, 0.000001, "a curve from 0 to 10 gives 0.5 at 5")
	inputs.set_input(&"test_c", 2.0)
	_check_near(falling.amount(inputs), 0.8, 0.000001, "turned round (10 to 0), it gives 0.8 at 2")
	_check_equal(step.amount(inputs), 0.0, "from and to equal: 0 below")
	inputs.set_input(&"test_c", 20.0)
	_check(rising.amount(inputs) == 1.0 and step.amount(inputs) == 1.0, "1 above the top, and at or above a step")
	inputs.set_input(&"test_c", -3.0)
	_check_equal(rising.amount(inputs), 0.0, "0 below the bottom")
	# A behaviour's score with a curve: between min_score (or 0) and max_score.
	var context := AIContextComponent.new()
	context.inputs.set_input(&"test_c", 5.0)
	var behaviour := AIBehaviourBase.new()
	behaviour.max_score = 0.8
	behaviour.score_curves = [AIScoreCurve.make(&"test_c", 0.0, 10.0)]
	_check_near(behaviour.score(context), 0.4, 0.000001, "with no min_score, a curve scales from 0 to max_score")
	behaviour.min_score = 0.2
	_check_near(behaviour.score(context), 0.5, 0.000001, "with a min_score, from min_score to max_score")
	behaviour.score_curves = []
	_check_equal(behaviour.score(context), 0.8, "with no curves, the score is max_score")
	behaviour.free()
	context.free()


func _test_own_code() -> void:
	var own := OwnCodeBehaviour.new()
	var plain := AIBehaviourBase.new()
	var attack := AIAttackBehaviour.new()
	var parry := AIParryBehaviour.new()
	var wander := AIWanderBehaviour.new()
	var keep_distance := AIKeepDistanceBehaviour.new()
	_check(own.has_own_code() and not plain.has_own_code() and not attack.has_own_code() and not parry.has_own_code()
			and not wander.has_own_code() and not keep_distance.has_own_code(), "has_own_code: true only for a behaviour overriding is_available or score; no built-in one does")
	for behaviour: Node in [own, plain, attack, parry, wander, keep_distance]:
		behaviour.free()


# Made-up brains judged by conditions and curves, fed random kept inputs. First decided by GDScript with shadow mode on: C++ must
# agree on every decision. Then the same game with C++ driving must make the same changes of behaviour.
func _test_cpp_agrees() -> void:
	if not ClassDB.class_exists(&"AIBatchDecider"):
		_check(false, "the navcore library has AIBatchDecider (rebuild native/ with the editor closed)")
		return
	var module := GameMode.get_module(AIDecisionModule) as AIDecisionModule
	var added := module == null
	if added:
		module = AIDecisionModule.new()
		GameMode.add_module(module)
	module.decider = AIDecisionModule.Decider.PAWN_SETTING
	module.check_against_gdscript = true
	module.reset_counts()
	var shadow_game := _play_conditions(module)
	var counts := module.get_counts()
	print("  conditions, live shadow: %s, chosen %s" % [str(counts), str(shadow_game["chosen"].keys())])
	_check(counts["checked"] == TICKS * 3 and counts["agreed"] == counts["checked"],
			"C++ judges conditions and curves the same as GDScript: %d of %d decisions agree" % [counts["agreed"], counts["checked"]])
	_check_equal(counts["stale_facts"], 0, "no written-through fact was out of date at any decision")
	_check(shadow_game["chosen"].size() >= 5, "and the made-up brains chose most of their behaviours (%d of 6)" % shadow_game["chosen"].size())
	# The same game with C++ driving.
	module.check_against_gdscript = false
	module.reset_counts()
	var cpp_game := _play_conditions(module)
	counts = module.get_counts()
	_check(counts["cpp"] == TICKS * 3, "C++ makes every decision when it drives (%d)" % counts["cpp"])
	_check(cpp_game["changes"] == shadow_game["changes"] and not shadow_game["changes"].is_empty(),
			"C++ driving plays the same game as GDScript driving: %d changes of behaviour, the same in order" % shadow_game["changes"].size())
	# Where pawns decide.
	var pawn := _make_pawn(_made_up_behaviours())
	_decide(pawn, 1)
	var manager := pawn.ai_context.behaviour_manager
	_check(manager.cpp_row >= 0, "a pawn decides in C++ by default")
	manager.decides_in = AIBehaviourManager.DecidesIn.GDSCRIPT
	_check(manager.cpp_row == -1, "its own setting moves it to GDScript at once")
	manager.decides_in = AIBehaviourManager.DecidesIn.CPP
	module.decider = AIDecisionModule.Decider.ALL_GDSCRIPT
	_check(manager.cpp_row == -1, "the game mode's override moves every pawn to GDScript")
	module.decider = AIDecisionModule.Decider.PAWN_SETTING
	_check(manager.cpp_row >= 0, "...and back")
	pawn.free()
	var own := OwnCodeBehaviour.new()
	own.name = "OwnCode"
	var special := _make_pawn([own])
	_decide(special, 1)
	_check(special.ai_context.behaviour_manager.cpp_row == -1, "a special mind (a behaviour with code of its own) decides in GDScript")
	special.free()
	if added:
		GameMode.remove_module(module)


# A pawn whose behaviour needs to be more than 5 m from the nearest node in a group, with the node moving near and far every tick and
# then freed: shadow mode must agree at every decision.
func _test_moving_group_point() -> void:
	var module := GameMode.get_module(AIDecisionModule) as AIDecisionModule
	var added := module == null
	if added:
		module = AIDecisionModule.new()
		GameMode.add_module(module)
	module.check_against_gdscript = true
	module.reset_counts()
	var point := Node3D.new()
	add_child(point)
	point.add_to_group(&"test_moving_point")
	var away := _behaviour("Away", 0.6, 0.6)
	away.conditions = [AICompareCondition.make(&"group_found/test_moving_point", Comparison.EQUAL, 1.0),
		AICompareCondition.make(&"group_distance/test_moving_point", Comparison.MORE_THAN, 5.0)]
	var stay := _behaviour("Stay", 0.3, 0.3)
	var pawn := _make_pawn([away, stay])
	var changes := [0] # GDScript note: a lambda captures plain locals by value, so the count lives in an array it can change
	pawn.ai_context.behaviour_manager.behaviour_changed.connect(func(_o: AIBehaviourBase, _n: AIBehaviourBase, _r: String) -> void: changes[0] += 1)
	for t in 60:
		if point:
			point.global_position = pawn.global_position + Vector3(2.0 if t % 2 == 0 else 20.0, 0.0, 0.0)
		if t == 40:
			point.free() # freed between looks
			point = null
		_decide(pawn, 7000 + t)
	var counts := module.get_counts()
	_check(counts["checked"] == 60 and counts["agreed"] == 60 and changes[0] > 20,
			"a group point that moves every tick, then is freed: C++ agrees at every decision (%d of %d, %d changes)" % [counts["agreed"], counts["checked"], changes[0]])
	pawn.free()
	module.check_against_gdscript = false
	if added:
		GameMode.remove_module(module)


# One game of the made-up brains: 3 pawns, TICKS ticks of random inputs, with persistence changes along the way. Returns the
# changes of behaviour in order and which behaviours were chosen.
func _play_conditions(_module: AIDecisionModule) -> Dictionary:
	var pawns: Array[Pawn] = []
	var chosen := {}
	var changes: Array[String] = []
	for n in 3:
		var pawn := _make_pawn(_made_up_behaviours())
		pawn.name = "Conditions%d" % n
		pawn.ai_context.random_seed = 1000 + n
		pawn.ai_context.behaviour_manager.default_score_jitter = 0.05 * n
		pawn.ai_context.behaviour_manager.behaviour_changed.connect(func(_old: AIBehaviourBase, new: AIBehaviourBase, reason: String) -> void:
			changes.append("%d:%s:%s" % [n, String(new.name) if new else "", reason])
			if new:
				chosen[String(new.name)] = true)
		pawns.append(pawn)
	# Pawn 2's Ant carries a persistence mask: a per-pawn shape over its fade (the hook).
	var mask := FadeProfile.new()
	mask.mode = FadeProfile.Mode.HALF_LIFE
	mask.half_life_ticks = 7
	pawns[2].ai_context.behaviour_manager.set_persistence_mask(&"Ant", mask)
	var rng := RandomNumberGenerator.new()
	rng.seed = 31337
	for t in TICKS:
		var tick := 9000 + t
		for pawn in pawns:
			var inputs := pawn.ai_context.inputs
			inputs.set_input(&"test_x", rng.randf())
			inputs.set_input(&"test_y", rng.randf())
			inputs.set_input(&"test_key", float(t / 10))
			inputs.set_input(&"ticks_test_since", float(rng.randi_range(0, 60)))
			_decide(pawn, tick)
			var manager := pawn.ai_context.behaviour_manager
			# Events C++'s copy of the state must follow: persistence changes, jitter, a behaviour finishing on its own.
			if t % 37 == 5:
				manager.add_persistence_ticks(&"Ant", 9.0)
			if t % 53 == 11:
				manager.set_persistence_speed(&"Cat", 0.5 + 0.25 * (t % 3))
			if t % 71 == 3:
				manager.set_score_jitter(&"Bee", 0.02 * (t % 4))
			if t % 29 == 17 and manager.get_running_behaviour():
				manager.stop_running("finished")
	for pawn in pawns:
		pawn.free()
	return {"chosen": chosen, "changes": changes}


func _made_up_behaviours() -> Array:
	var ant := _behaviour("Ant", 0.6, 0.1)
	ant.persistence = 0.2
	ant.persistence_fade = _fade(FadeProfile.Mode.LINEAR, 10, 40)
	ant.conditions = [AICompareCondition.make(&"test_x", Comparison.AT_MOST, 0.5)]
	ant.score_curves = [AIScoreCurve.make(&"test_y", 0.0, 1.0)]
	var bee := _behaviour("Bee", 0.55, 0.55)
	var either: Array[AICondition] = [AICompareCondition.make(&"test_x", Comparison.MORE_THAN, 0.7), AIChanceCondition.make(0.4, 3)]
	bee.conditions = [AIAnyCondition.make(either)]
	var cat := _behaviour("Cat", 0.7, 0.0)
	cat.persistence = -0.15
	cat.persistence_fade = _fade(FadeProfile.Mode.HALF_LIFE, 5, 0, 12)
	cat.cooldown_ticks = 9
	cat.conditions = [AICompareCondition.make(&"test_y", Comparison.AT_LEAST, 0.0, &"test_x")] # y >= x
	cat.score_curves = [AIScoreCurve.make(&"test_x", 1.0, 0.0), AIScoreCurve.make(&"test_y", 0.0, 1.0)]
	var dog := _behaviour("Dog", 0.5, 0.5)
	dog.conditions = [AIChanceCondition.make(0.5, 9, &"test_key", &"test_key")]
	var elk := _behaviour("Elk", 0.3, 0.3) # no conditions: always there
	var fox := _behaviour("Fox", 0.65, 0.65)
	fox.conditions = [AICompareCondition.make(&"ticks_test_since", Comparison.AT_MOST, 20.0), AICompareCondition.make(&"test_x", Comparison.NOT_EQUAL, 0.25)]
	return [ant, bee, cat, dog, elk, fox]


# --- Helpers ---


func _fade(mode: FadeProfile.Mode, hold: int, fade: int, half_life := 30) -> FadeProfile:
	var profile := FadeProfile.new()
	profile.mode = mode
	profile.hold_ticks = hold
	profile.fade_ticks = fade
	profile.half_life_ticks = half_life
	return profile


func _behaviour(behaviour_name: String, max_score: float, min_score: float) -> AIBehaviourBase:
	var behaviour := AIBehaviourBase.new()
	behaviour.name = behaviour_name
	behaviour.max_score = max_score
	behaviour.min_score = min_score
	return behaviour


func _make_pawn(behaviours: Array) -> Pawn:
	var pawn: Pawn = load(PAWN_SCENE).instantiate()
	pawn.position = Vector3(0, 1000, 0)
	var manager := AIBehaviourManager.new()
	manager.name = "AIBehaviourManager"
	for behaviour in behaviours:
		manager.add_child(behaviour)
	pawn.add_child(manager)
	add_child(pawn)
	pawn.ai_context.decision_interval_ticks = NEVER
	return pawn


func _decide(pawn: Pawn, tick: int) -> void:
	var context := pawn.ai_context
	context.current_tick = tick
	context.request_decision()
	context.state_manager.update_state(tick)
	context.behaviour_manager.decide(tick)
