## Written by Claude (claude-opus-5-5), 2026-11-09: headless self-test for AIBehaviourManager, AIBehaviourBase, AIWanderBehaviour,
## AIManager and the pawn's AI step. Checks the decision steps of pawn spec 10.8 one by one (hard rules, ranges, early stop,
## jitter, ties, the fixed order), persistence (Claude 2026-11-25: own modifiers now), interrupts, finishing, Wander, what runs while a player has the pawn, that a client
## never runs the AI, that a rollback doesn't run it again, and the odd cases at the top of AIBehaviourManager.gd.
## Claude 2026-11-17 (scaling spec 6.2): and wake-ups: wake_at, a walk ending and an ability on the action ending wake a sleeping
## behaviour, used up when they fire, cleared when it starts again.
## Exits 0 on success, 1 on failure. Run from the project folder:
##   godot --headless --path . "res://assets/scripts/ai/tests/ai_behaviour_manager_selftest.tscn"
extends SelfTest # Claude 2026-11-16 (wider audit): _check and _failures come from tests/SelfTest.gd now

const PAWN_SCENE := "res://assets/scenes/pawn/pawn.tscn"
const NEVER := 100000000 # a decision interval so long the pawn never decides on its own, so the test decides by hand


## A behaviour a test controls: its score, whether it's available, and how its tick ends. It counts what the manager does to it.
class TestBehaviour extends AIBehaviourBase:
	var value := 0.5
	var available := true
	var finish_with := Status.RUNNING
	var scored := 0
	var entered := 0
	var exited := 0
	var ticks := 0
	var last_exit_reason := ""

	func is_available(_context: AIManager) -> bool:
		return available

	func score(_context: AIManager) -> float:
		scored += 1
		return value

	func enter(_context: AIManager) -> void:
		entered += 1

	func tick(_context: AIManager) -> Status:
		ticks += 1
		return finish_with

	func exit(_context: AIManager, reason: String) -> void:
		exited += 1
		last_exit_reason = reason


## Walks to a point when it starts, through the AI controller.
class GoToBehaviour extends AIBehaviourBase:
	var target := Vector3.ZERO
	var walk_accepted := false

	func enter(context: AIManager) -> void:
		walk_accepted = context.controller.move_to(target)


## A state a test can switch on.
class SwitchState extends AIStateBase:
	var fits := false

	func prerequisites_met(_context: AIManager) -> bool:
		return fits


func _ready() -> void:
	# Claude 2026-11-09 (scaling spec step 6): these checks count exact ticks at the reference rate, 60 a second, so they pin it, even
	# in a run at another rate (-- --tick-rate=30). tick_rate_selftest checks that converted settings last the same time at 30.
	TickDriver.tick_rate = TickDriver.REFERENCE_RATE
	print("--- AI behaviour manager self-test ---")
	await _test_empty_manager()
	_test_best_score_and_fixed_order()
	_test_hard_rules()
	_test_ranges_and_early_stop()
	_test_random_numbers_and_jitter()
	_test_ties()
	_test_own_modifiers() # Claude 2026-11-25 (pawn spec 16.10 step 6a): was _test_persistence; persistence is gone
	_test_interrupts()
	_test_tag_gates()
	_test_score_modifiers()
	await _test_finishing()
	_test_tick_interval()
	_test_wake_ups()
	_test_odd_cases()
	await _test_wander()
	await _test_while_possessed()
	await _test_client_and_rollback()
	print("--- ALL PASSED ---" if _failures == 0 else "--- %d FAILED ---" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)


func _test_empty_manager() -> void:
	var floor_body := _make_floor(60.0)
	var pawn: Pawn = load(PAWN_SCENE).instantiate() # the default parts: an empty behaviour manager
	pawn.position = Vector3(0, 0.1, 0)
	add_child(pawn)
	pawn.ai.decision_interval_ticks = 1
	await _ticks(10)
	_check(pawn.ai.state_manager.get_current_state().name == &"Idle", "default parts: the state manager picks Idle")
	pawn.controller_manager.ai_controller.move_in_direction(Vector3(1, 0, 0))
	await _ticks(20)
	_check(pawn.velocity.x > 4.0, "an empty behaviour manager leaves a script driving the AI controller alone (%.2f m/s)" % pawn.velocity.x)
	pawn.free()
	floor_body.free()


func _test_best_score_and_fixed_order() -> void:
	var pawn := _make_pawn([_b("Alpha", 0.3), _b("Bravo", 0.7), _b("Charlie", 0.5)])
	_decide(pawn, 1)
	_check(_running_name(pawn) == &"Bravo", "the highest score runs")
	pawn.free()
	var first := _make_pawn([_b("Zulu", 0.5), _b("Yankee", 0.5)])
	var second := _make_pawn([_b("Yankee", 0.5), _b("Zulu", 0.5)])
	_decide(first, 1)
	_decide(second, 1)
	_check(_running_name(first) == &"Yankee" and _running_name(second) == &"Yankee", "a tie goes by name, whatever order they were added in")
	first.free()
	second.free()


func _test_hard_rules() -> void:
	var quick := _b("Quick", 0.9)
	quick.cooldown_ticks = 10
	quick.finish_with = AIBehaviourBase.Status.SUCCEEDED
	var target_needed := _b("Hunt", 1.0)
	target_needed.needs_target = true
	var cant_press := _b("Press", 1.0)
	cant_press.presses_action = &"no_such_action"
	var elsewhere := _b("Elsewhere", 1.0)
	elsewhere.tag_requirements = TagQuery.make([Tags.AI.STATE_COMBAT])
	var fallback := _b("Fallback", 0.1)
	var pawn := _make_pawn([quick, target_needed, cant_press, elsewhere, fallback])
	_decide(pawn, 100)
	_check(_running_name(pawn) == &"Quick", "a behaviour needing a target, one whose action can't start, and one for another state are all skipped")
	_check(target_needed.scored == 0 and cant_press.scored == 0 and elsewhere.scored == 0, "...without running their score()")
	pawn.ai.behaviour_manager.tick_running(101) # Quick finishes, and the manager decides at once
	_check(quick.last_exit_reason == "succeeded" and _running_name(pawn) == &"Fallback", "Quick finished: on cooldown, so Fallback runs at once")
	_decide(pawn, 110)
	_check(_running_name(pawn) == &"Fallback", "still cooling down 9 ticks later")
	_decide(pawn, 111)
	_check(_running_name(pawn) == &"Quick", "its cooldown over at 10 ticks, it wins again")
	pawn.free()


func _test_ranges_and_early_stop() -> void:
	var sure := _b("Sure", 0.85, 0.9)
	sure.min_score = 0.8
	var weak := _b("Weak", 0.5)
	var pawn := _make_pawn([sure, weak])
	_decide(pawn, 1)
	_check(_running_name(pawn) == &"Sure" and weak.scored == 0, "a ceiling below another's floor: dropped without its score() running")
	pawn.free()
	var high := _b("High", 0.9)
	var low := _b("Low", 0.4)
	pawn = _make_pawn([high, low])
	_decide(pawn, 1)
	_check(_running_name(pawn) == &"High" and low.scored == 0, "early stop: once High scores 0.9, Low (max 0.4) isn't asked")
	pawn.free()
	var overrated := _b("Overrated", 0.2, 0.9) # can reach 0.9, but scores 0.2 now; no min_score
	var steady := _b("Steady", 0.5)
	pawn = _make_pawn([overrated, steady])
	_decide(pawn, 1)
	_check(_running_name(pawn) == &"Steady", "a behaviour scoring below its max never shuts out one that would win")
	_check(overrated.scored == 1 and steady.scored == 1, "...because both had to be scored")
	pawn.free()


func _test_random_numbers_and_jitter() -> void:
	var b := _b("B", 0.5) # Claude 2026-11-25: kept, since set_score_jitter is gone (step 6a): settings are set on the behaviour
	var pawn := _make_pawn([_b("A", 0.5), b])
	var context := pawn.ai
	var same := context.random_unit_at(500, 77) == context.random_unit_at(500, 77)
	var differs := context.random_unit_at(500, 77) != context.random_unit_at(501, 77) and context.random_unit_at(500, 77) != context.random_unit_at(500, 78)
	_check(same and differs, "random numbers: the same tick and salt give the same number; another tick or salt, another number")
	var in_range := true
	var total := 0.0
	for t in 2000:
		var value := context.random_unit_at(t, 5)
		in_range = in_range and value >= 0.0 and value < 1.0
		total += value
	_check(in_range and absf(total / 2000.0 - 0.5) < 0.05, "random numbers: from 0 up to 1, averaging about a half (%.3f)" % (total / 2000.0))
	context.random_seed = 99
	var reseeded := context.random_unit_at(500, 77) != same_seed_value(context)
	context.random_seed = 0
	_check(reseeded, "random numbers: another seed, another number")
	# No jitter: equal scores always go to the first by name.
	var winners := {}
	for t in 40:
		_decide(pawn, 1000 + t)
		winners[_running_name(pawn)] = true
	_check(winners.size() == 1 and winners.has(&"A"), "jitter 0 (the default): the same choice every time")
	# Jitter on B only: B sometimes beats A, and the choices replay the same.
	b.score_jitter = 0.2
	var b_wins := 0
	var first_run: Array[StringName] = []
	for t in 60:
		_decide(pawn, 2000 + t)
		first_run.append(_running_name(pawn))
		b_wins += 1 if _running_name(pawn) == &"B" else 0
	var second_run: Array[StringName] = []
	for t in 60:
		_decide(pawn, 2000 + t)
		second_run.append(_running_name(pawn))
	_check(b_wins > 10 and b_wins < 50, "jitter per behaviour: B, with jitter, wins about half the time (%d of 60)" % b_wins)
	_check(first_run == second_run, "the same ticks give the same choices")
	b.score_jitter = -1.0
	pawn.ai.behaviour_manager.default_score_jitter = 0.2
	var a_seen := false
	var b_seen := false
	for t in 60:
		_decide(pawn, 3000 + t)
		a_seen = a_seen or _running_name(pawn) == &"A"
		b_seen = b_seen or _running_name(pawn) == &"B"
	_check(a_seen and b_seen, "-1 uses the manager's default_score_jitter")
	pawn.free()


func same_seed_value(context: AIManager) -> float:
	var seed_now := context.random_seed
	context.random_seed = 0
	var value := context.random_unit_at(500, 77)
	context.random_seed = seed_now
	return value


func _test_ties() -> void:
	var pawn := _make_pawn([_b("Kilo", 0.5), _b("Lima", 0.5), _b("Mike", 0.5)])
	pawn.ai.behaviour_manager.randomize_ties = true
	var seen := {}
	var first: Array[StringName] = []
	for t in 60:
		_decide(pawn, 4000 + t)
		seen[_running_name(pawn)] = true
		first.append(_running_name(pawn))
	var again: Array[StringName] = []
	for t in 60:
		_decide(pawn, 4000 + t)
		again.append(_running_name(pawn))
	_check(seen.size() == 3, "randomize_ties: every tied behaviour gets picked sometimes")
	_check(first == again, "randomize_ties: the same ticks give the same picks")
	pawn.free()


# Claude 2026-11-25 (pawn spec 16.10 step 6a): persistence is gone. A behaviour gives itself a modifier as it starts or ends; with no
# applies_to it changes only itself.
func _test_own_modifiers() -> void:
	var keeper := _b("Keeper", 0.5)
	var hold := AIBehaviourModifier.new()
	hold.add = 0.1 # no duration: while it runs
	keeper.modifier_on_start = hold
	var rival := _b("Rival", 0.4, 1.0) # max 1.0, because the test raises its score
	var pawn := _make_pawn([keeper, rival])
	_decide(pawn, 100)
	_check(_running_name(pawn) == &"Keeper", "Keeper wins first")
	_check(is_equal_approx(keeper.score_bonus(), 0.1) and rival.score_bonus() == 0.0, "as it starts it gives itself +0.1, and only itself")
	rival.value = 0.55
	_decide(pawn, 105)
	_check(_running_name(pawn) == &"Keeper", "+0.1 keeps it ahead of a rival at 0.55")
	rival.value = 0.7
	_decide(pawn, 106)
	_check(_running_name(pawn) == &"Rival" and keeper.score_bonus() == 0.0, "a rival at 0.7 wins, and with no duration the +0.1 went as Keeper ended")
	pawn.free()
	# On end, with a duration: it steps aside for a while, as Look Toward does.
	var restless := _b("Restless", 0.5)
	var aside := AIBehaviourModifier.new()
	aside.add = -0.2
	aside.duration_ticks = 30
	restless.modifier_on_end = aside
	var other := _b("Other", 0.4, 1.0)
	pawn = _make_pawn([restless, other])
	_decide(pawn, 1)
	_check(_running_name(pawn) == &"Restless", "Restless wins first")
	other.value = 0.6
	_decide(pawn, 2)
	_check(_running_name(pawn) == &"Other" and is_equal_approx(restless.score_bonus(), -0.2), "Other wins; Restless gives itself -0.2 as it ends")
	other.value = 0.4
	_decide(pawn, 31)
	_check(_running_name(pawn) == &"Other", "for 30 ticks, -0.2 keeps it behind Other at 0.4")
	_decide(pawn, 32)
	_check(_running_name(pawn) == &"Restless" and restless.score_bonus() == 0.0, "at its deadline it's gone, and Restless wins again")
	pawn.free()


func _test_interrupts() -> void:
	var heavy := _b("Heavy", 0.6)
	heavy.interrupt_threshold = 15
	var better := _b("Better", 0.4, 1.0)
	var pawn := _make_pawn([heavy, better])
	_decide(pawn, 1)
	better.value = 0.9
	_decide(pawn, 2)
	_check(_running_name(pawn) == &"Heavy", "threshold 15: an ordinary decision (priority 0) can't replace it")
	_decide(pawn, 3, 10, false)
	_check(_running_name(pawn) == &"Heavy", "nor an event of priority 10")
	_decide(pawn, 4, 20, false)
	_check(_running_name(pawn) == &"Better" and heavy.last_exit_reason == "interrupted", "an event of priority 20 can, and Heavy's exit says interrupted")
	pawn.free()

	var stubborn := _b("Stubborn", 0.6)
	stubborn.cannot_be_interrupted = true
	var keen := _b("Keen", 0.4, 1.0)
	pawn = _make_pawn([stubborn, keen])
	_decide(pawn, 1)
	keen.value = 0.9
	_decide(pawn, 2, 999, false)
	_check(_running_name(pawn) == &"Stubborn", "cannot_be_interrupted: not even priority 999")
	stubborn.finish_with = AIBehaviourBase.Status.SUCCEEDED
	pawn.ai.behaviour_manager.tick_running(3)
	_check(_running_name(pawn) == &"Keen", "until it finishes itself")
	pawn.free()

	var settled := _b("Settled", 0.6)
	settled.min_run_ticks = 30
	var eager := _b("Eager", 0.4, 1.0)
	pawn = _make_pawn([settled, eager])
	_decide(pawn, 100)
	eager.value = 0.9
	_decide(pawn, 110)
	_check(_running_name(pawn) == &"Settled", "min_run_ticks 30: an ordinary decision 10 ticks in can't replace it")
	_decide(pawn, 111, 0, false)
	_check(_running_name(pawn) == &"Eager", "but a state change can, even at priority 0")
	pawn.free()

	settled = _b("Settled", 0.6)
	settled.min_run_ticks = 30
	eager = _b("Eager", 0.4, 1.0)
	pawn = _make_pawn([settled, eager])
	_decide(pawn, 100)
	eager.value = 0.9
	_decide(pawn, 130)
	_check(_running_name(pawn) == &"Eager", "and an ordinary decision can once 30 ticks have passed")
	pawn.free()

	# A running behaviour whose state no longer allows it, held by its threshold.
	var combat := SwitchState.new()
	combat.name = "Combat"
	combat.priority = 20
	var guard := _b("Guard", 0.6)
	guard.tag_requirements = TagQuery.make([Tags.AI.STATE_IDLE])
	guard.interrupt_threshold = 50
	var fight := _b("Fight", 0.5)
	fight.tag_requirements = TagQuery.make([Tags.AI.STATE_COMBAT])
	pawn = _make_pawn([guard, fight], [combat])
	_decide(pawn, 1)
	combat.fits = true
	_decide(pawn, 2) # the state check moves to Combat, a state-change event of priority 20
	_check(pawn.ai.state_manager.get_current_state() == combat and _running_name(pawn) == &"Guard", "a threshold above the new state's priority keeps a behaviour running in a state that doesn't allow it")
	# Claude 2026-11-25 (pawn spec 16.10 step 6a): set_interrupt_threshold is gone; a modifier lowers it.
	var lowered := AIBehaviourModifier.new()
	lowered.number = AIBehaviourModifier.Number.INTERRUPT_THRESHOLD
	lowered.overrides = true
	pawn.ai.behaviour_manager.add_modifier(lowered, self)
	_decide(pawn, 3)
	_check(_running_name(pawn) == &"Fight", "a modifier lowering its threshold while it runs: the next decision replaces it")
	pawn.free()


# Claude 2026-11-23 (pawn spec 10.13): tag requirements over the pawn's owned tags, the running check, and the switch.
func _test_tag_gates() -> void:
	var shoot := _b("Shoot", 0.9)
	shoot.tag_requirements = TagQuery.make([Tags.STATUS.HAS_AMMO_RANGED])
	shoot.min_run_ticks = 600
	var fight := _b("Fight", 0.5)
	var pawn := _make_pawn([shoot, fight])
	var manager := pawn.ai.behaviour_manager
	_decide(pawn, 1)
	_check(_running_name(pawn) == &"Fight", "a behaviour whose tag requirements fail isn't chosen")
	_check(shoot.scored == 0, "...and its score() isn't run")
	pawn.owned_tags.add(Tags.STATUS.HAS_AMMO_RANGED)
	_decide(pawn, 2)
	_check(_running_name(pawn) == &"Shoot", "the tag owned: it's chosen")
	pawn.owned_tags.remove(Tags.STATUS.HAS_AMMO_RANGED)
	pawn.ai.clear_decision()
	manager.check_running(3)
	_check(pawn.ai.has_decision_waiting() and not pawn.ai.waiting_event_is_normal(),
			"check_running: its requirements stopped passing, so it asks for a decision min_run_ticks don't hold off")
	manager.decide(3)
	_check(_running_name(pawn) == &"Fight", "...which replaces it, though its min_run_ticks (600) haven't passed")
	pawn.ai.clear_decision()
	manager.check_running(4)
	_check(not pawn.ai.has_decision_waiting(), "check_running asks nothing when nothing changed")
	# A threshold still holds it, as it does through a state change.
	pawn.owned_tags.add(Tags.STATUS.HAS_AMMO_RANGED)
	_decide(pawn, 5)
	shoot.interrupt_threshold = 50
	pawn.owned_tags.remove(Tags.STATUS.HAS_AMMO_RANGED)
	_decide(pawn, 6, 0, false)
	_check(_running_name(pawn) == &"Shoot", "an interrupt_threshold above the reason's priority still keeps it")
	_decide(pawn, 7, 60, false)
	_check(_running_name(pawn) == &"Fight", "...and a strong enough reason replaces it")
	# Switched off.
	fight.enabled = false
	_decide(pawn, 8)
	_check(_running_name(pawn) == &"", "enabled off: a running behaviour is replaced, and nothing else passes, so nothing runs")
	fight.enabled = true
	_decide(pawn, 9)
	_check(_running_name(pawn) == &"Fight", "enabled on again: chosen again")
	pawn.free()


# Claude 2026-11-23 (pawn spec 10.13): score modifiers, keyed by source, with deadlines, requirements, blocks and granted tags.
# Claude 2026-11-25 (pawn spec 16.10 step 6a): AIScoreModifier is AIBehaviourModifier (amount is add), the calls are add_modifier and
# remove_modifiers, and the sum is score_bonus(); its other numbers are checked at the end.
func _test_score_modifiers() -> void:
	var melee := _b("Melee", 0.8)
	melee.tags = [Tags.AI.STANCE_MELEE]
	var ranged := _b("Ranged", 0.85)
	ranged.tags = [Tags.AI.STANCE_RANGED]
	var pawn := _make_pawn([melee, ranged])
	var manager := pawn.ai.behaviour_manager
	_decide(pawn, 1)
	_check(_running_name(pawn) == &"Ranged", "no modifiers: Ranged (0.85) over Melee (0.8)")
	var charge := AIBehaviourModifier.new()
	charge.applies_to = TagQuery.make([], [Tags.AI.STANCE_MELEE])
	charge.add = 0.1
	charge.granted_tags = [Tags.AI.STANCE_MELEE]
	var shout_a := Node.new()
	var shout_b := Node.new()
	manager.add_modifier(charge, shout_a)
	_check(is_equal_approx(melee.score_bonus(), 0.1) and ranged.score_bonus() == 0.0, "a modifier adds to the behaviours it applies to (by their tags) only")
	_check(pawn.owned_tags.has(Tags.AI.STANCE_MELEE), "its granted tags are owned while it's added")
	_decide(pawn, 2)
	_check(_running_name(pawn) == &"Melee", "Melee 0.8 + 0.1 beats Ranged 0.85")
	manager.add_modifier(charge, shout_b)
	_check(is_equal_approx(melee.score_bonus(), 0.2), "two sources stack")
	manager.remove_modifiers(shout_a)
	_check(is_equal_approx(melee.score_bonus(), 0.1) and pawn.owned_tags.has(Tags.AI.STANCE_MELEE), "removing one source leaves the other's")
	manager.remove_modifiers(shout_b)
	_check(melee.score_bonus() == 0.0 and not pawn.owned_tags.has(Tags.AI.STANCE_MELEE), "removing the last: no sum, no granted tag")
	# A deadline.
	var brief := AIBehaviourModifier.new()
	brief.applies_to = charge.applies_to
	brief.add = 0.1
	brief.duration_ticks = 10
	TickDriver.tick = 100
	manager.add_modifier(brief, shout_a)
	manager.refresh_modifiers(109)
	_check(is_equal_approx(melee.score_bonus(), 0.1), "a 10-tick modifier counts at tick 109")
	manager.refresh_modifiers(110)
	_check(melee.score_bonus() == 0.0 and manager.get_modifiers().is_empty(), "...and is gone at its deadline, tick 110")
	# Ongoing requirements.
	var with_ammo := AIBehaviourModifier.new()
	with_ammo.applies_to = TagQuery.make([], [Tags.AI.STANCE_RANGED])
	with_ammo.add = -0.2
	with_ammo.ongoing_requirements = TagQuery.make([], [], [Tags.STATUS.HAS_AMMO])
	manager.add_modifier(with_ammo, shout_a)
	_check(is_equal_approx(ranged.score_bonus(), -0.2), "ongoing requirements pass (no ammo tag): it counts")
	pawn.owned_tags.add(Tags.STATUS.HAS_AMMO_RANGED)
	manager.refresh_modifiers(111)
	_check(ranged.score_bonus() == 0.0, "the pawn now owns a tag under status.has_ammo: it stops counting")
	pawn.owned_tags.remove(Tags.STATUS.HAS_AMMO_RANGED)
	manager.remove_modifiers(shout_a)
	# A block, on the running behaviour.
	_decide(pawn, 120)
	_check(_running_name(pawn) == &"Ranged", "back to Ranged")
	var no_ranged := AIBehaviourModifier.new()
	no_ranged.applies_to = TagQuery.make([], [Tags.AI.STANCE_RANGED])
	no_ranged.blocks = true
	no_ranged.wakes_decision = true
	pawn.ai.clear_decision()
	manager.add_modifier(no_ranged, shout_b)
	_check(ranged.decision_blocked and pawn.ai.has_decision_waiting(), "a blocking modifier blocks, and wakes_decision asks for a decision")
	manager.decide(121)
	_check(_running_name(pawn) == &"Melee", "a blocked running behaviour is replaced")
	manager.remove_modifiers(shout_b)
	_check(not ranged.decision_blocked, "removed: unblocked")
	# The other numbers: multiply, then add; an override wins whatever the order; ticks are written for 60 a second.
	melee.score_jitter = 0.2
	melee.cooldown_ticks = 30
	var calm := AIBehaviourModifier.new()
	calm.number = AIBehaviourModifier.Number.SCORE_JITTER
	calm.multiply = 0.0
	calm.add = 0.05
	manager.add_modifier(calm, shout_a) # no applies_to: every behaviour
	_check(is_equal_approx(melee.current_jitter(), 0.05), "jitter: 0.2 x 0 + 0.05")
	var stubborn := AIBehaviourModifier.new()
	stubborn.number = AIBehaviourModifier.Number.INTERRUPT_THRESHOLD
	stubborn.overrides = true
	stubborn.override_value = 40.0
	var softer := AIBehaviourModifier.new()
	softer.number = AIBehaviourModifier.Number.INTERRUPT_THRESHOLD
	softer.add = -5.0
	manager.add_modifier(stubborn, shout_a)
	manager.add_modifier(softer, shout_a)
	_check(melee.current_interrupt_threshold() == 40, "an override wins over an add made after it")
	var slow := AIBehaviourModifier.new()
	slow.number = AIBehaviourModifier.Number.COOLDOWN_TICKS
	slow.multiply = 2.0
	var settle := AIBehaviourModifier.new()
	settle.number = AIBehaviourModifier.Number.MIN_RUN_TICKS
	settle.add = 20.0
	manager.add_modifier(slow, shout_a)
	manager.add_modifier(settle, shout_a)
	_check(melee.current_cooldown_ticks() == TickDriver.ticks_at_rate(60) and melee.current_min_run_ticks() == TickDriver.ticks_at_rate(20),
			"cooldown 30 x 2 and minimum run 0 + 20, at the match's rate")
	manager.remove_modifiers(shout_a)
	_check(is_equal_approx(melee.current_jitter(), 0.2) and melee.current_interrupt_threshold() == 0 and melee.current_cooldown_ticks() == TickDriver.ticks_at_rate(30)
			and melee.current_min_run_ticks() == 0, "removed: its own numbers again")
	shout_a.free()
	shout_b.free()
	pawn.free()


func _test_finishing() -> void:
	var once := _b("Once", 0.9)
	once.finish_with = AIBehaviourBase.Status.FAILED
	once.cooldown_ticks = 1000
	var after := _b("After", 0.2)
	var pawn := _make_pawn([once, after])
	pawn.ai.decision_interval_ticks = NEVER
	_decide(pawn, TickDriver.tick)
	_check(_running_name(pawn) == &"Once", "a behaviour that will fail starts")
	await _ticks(2)
	_check(once.last_exit_reason == "failed" and _running_name(pawn) == &"After", "on its first tick it fails, and the manager decides at once")
	_check(after.entered == 1 and after.ticks >= 1, "and the next one starts and ticks")
	pawn.free()


# Claude 2026-11-09: tick_interval_ticks.
func _test_tick_interval() -> void:
	var slow := _b("Slow", 0.5)
	slow.tick_interval_ticks = 5
	var pawn := _make_pawn([slow])
	_decide(pawn, 100)
	for t in range(100, 111):
		pawn.ai.behaviour_manager.tick_running(t)
	_check(slow.ticks == 3, "tick_interval_ticks 5: ticked on the tick it started, then every 5 (%d ticks in 11)" % slow.ticks)
	slow.tick_interval_ticks = 1
	for t in range(111, 116):
		pawn.ai.behaviour_manager.tick_running(t)
	_check(slow.ticks == 8, "1: every tick")
	pawn.free()


# Claude 2026-11-17: a behaviour sleeping on a long interval, woken by each kind of wake-up.
func _test_wake_ups() -> void:
	var sleeper := _b("Sleeper", 0.5)
	sleeper.tick_interval_ticks = 600
	var pawn := _make_pawn([sleeper])
	var manager := pawn.ai.behaviour_manager
	_decide(pawn, 100)
	manager.tick_running(100) # the tick it starts
	for t in range(101, 110):
		manager.tick_running(t)
	_check_equal(sleeper.ticks, 1, "a 600-tick interval: ticked only when it started")
	sleeper.wake_at(105) # in the past: fires at the next run
	sleeper.wake_at(120)
	manager.tick_running(110)
	_check_equal(sleeper.ticks, 2, "wake_at: the earlier of two wins, and fires at the pawn's first run at or after it")
	manager.tick_running(111)
	_check_equal(sleeper.ticks, 2, "...and is used up when it fires")
	manager._on_path_ended(true)
	manager.tick_running(112)
	_check_equal(sleeper.ticks, 2, "a walk ending doesn't wake a behaviour that didn't ask")
	sleeper.wake_on_path_end()
	manager._on_path_ended(false)
	manager.tick_running(113)
	_check_equal(sleeper.ticks, 3, "wake_on_path_end: a walk ending (here given up) wakes it")
	var swing := AbilityBase.new()
	swing.trigger_action = &"primary"
	var other := AbilityBase.new()
	other.trigger_action = &"secondary"
	sleeper.wake_on_action_end(&"primary")
	manager._on_ability_ended(other)
	manager.tick_running(114)
	_check_equal(sleeper.ticks, 3, "an ability on another action ending doesn't wake it")
	manager._on_ability_ended(swing)
	manager.tick_running(115)
	_check_equal(sleeper.ticks, 4, "wake_on_action_end: an ability on its action ending wakes it")
	sleeper.wake_at(500)
	sleeper.available = false
	_decide(pawn, 116) # nothing left: it stops
	sleeper.available = true
	_decide(pawn, 117) # and starts again
	_check(sleeper.wake_tick == -1 and not sleeper.wakes_on_path_end and sleeper.wakes_on_action == &"",
			"starting again clears every wake-up")
	swing.free()
	other.free()
	pawn.free()


func _test_odd_cases() -> void:
	var lonely := AIBehaviourManager.new()
	print("  (a warning about a parent that isn't a Pawn is expected next)")
	add_child(lonely)
	lonely.decide(0)
	_check(lonely.get_running_behaviour() == null, "its parent isn't a Pawn: it does nothing")
	lonely.free()
	var only_combat := _b("OnlyCombat", 0.5)
	only_combat.tag_requirements = TagQuery.make([Tags.AI.STATE_COMBAT])
	var pawn := _make_pawn([only_combat])
	print("  (a warning about a state with no behaviour is expected next, once)")
	_decide(pawn, 1)
	_decide(pawn, 2)
	_check(pawn.ai.behaviour_manager.get_running_behaviour() == null, "a state that allows none of its behaviours: nothing runs")
	pawn.free()
	var liar := _b("Liar", 0.9, 0.5) # scores 0.9 but says its max is 0.5
	pawn = _make_pawn([liar])
	print("  (a warning about a score above max_score is expected next, once)")
	_decide(pawn, 1)
	_decide(pawn, 2)
	_check(liar.warned_score_range, "a score above max_score: a warning naming it")
	pawn.free()


func _test_wander() -> void:
	var floor_body := _make_floor(100.0)
	var wander := AIWanderBehaviour.new()
	wander.name = "Wander"
	wander.wander_radius = 6.0
	wander.min_pause_ticks = 20
	wander.max_pause_ticks = 40
	var pawn := _make_pawn([wander], [], Vector3(0, 0.1, 0))
	pawn.ai.decision_interval_ticks = 15
	await _ticks(10)
	var start := pawn.global_position
	var furthest := 0.0
	var still_ticks := 0
	var moving_ticks := 0
	for i in 600:
		await get_tree().physics_frame
		var offset := pawn.global_position - start
		offset.y = 0.0
		furthest = maxf(furthest, offset.length())
		if Vector2(pawn.velocity.x, pawn.velocity.z).length() < 0.05:
			still_ticks += 1
		else:
			moving_ticks += 1
	_check(_running_name(pawn) == &"Wander", "Wander runs in Idle")
	_check(furthest > 2.0, "it walks away from where it started (%.1f m at most)" % furthest)
	_check(furthest < wander.wander_radius + 1.5, "and stays near its home (%.1f m, radius %.0f)" % [furthest, wander.wander_radius])
	_check(still_ticks > 40 and moving_ticks > 100, "and pauses between walks (%d ticks still, %d moving)" % [still_ticks, moving_ticks])
	pawn.free()
	floor_body.free()


func _test_while_possessed() -> void:
	var floor_body := _make_floor(100.0)
	var counter := _b("Counter", 0.5)
	var pawn := _make_pawn([counter], [], Vector3(0, 0.1, 0))
	pawn.ai.decision_interval_ticks = 1
	await _ticks(5)
	var context := pawn.ai
	context.while_possessed = AIManager.WhilePossessed.MEMORY_ONLY
	pawn.controller_manager.set_has_player(true) # a player on another machine, so nobody here is in charge
	var before := counter.ticks
	await _ticks(10)
	_check(counter.ticks == before, "MEMORY_ONLY (the default): behaviours pause while a player has the pawn")
	pawn.controller_manager.set_has_player(false)
	await _ticks(5)
	_check(counter.ticks > before and _running_name(pawn) == &"Counter", "letting go: the same behaviour carries on, with no special code")
	context.while_possessed = AIManager.WhilePossessed.OFF
	pawn.controller_manager.set_has_player(true)
	before = counter.ticks
	await _ticks(10)
	_check(counter.ticks == before, "OFF: nothing runs while a player has the pawn")
	context.while_possessed = AIManager.WhilePossessed.FULL
	await _ticks(10)
	_check(counter.ticks > before, "FULL: behaviours keep running")
	pawn.controller_manager.set_has_player(false)
	pawn.free()
	# FULL: the hands keep the order, and carry it out once in charge again. Claude 2026-11-25 (pawn spec 16.10 step 5c): each controller
	# follows its own path now, so the player's path can't be touched; the hands' own follower stays idle while not in charge.
	var go := GoToBehaviour.new()
	go.name = "GoTo"
	go.target = Vector3(10, 0, 0)
	pawn = _make_pawn([go], [], Vector3(0, 0.1, 0))
	pawn.ai.while_possessed = AIManager.WhilePossessed.FULL
	pawn.ai.decision_interval_ticks = NEVER
	await _ticks(5)
	pawn.controller_manager.set_has_player(true)
	_decide(pawn, TickDriver.tick) # GoTo starts while the AI isn't in charge
	var hands: AIController = pawn.controller_manager.ai_controller
	_check(go.walk_accepted and hands.is_following_order(), "FULL, not in charge: move_to is accepted and kept")
	_check(not hands.path_follower.is_under_way() and pawn.controller_manager.get_path_follower() == null, "and no path is followed while it isn't in charge")
	hands.stop()
	_check(not hands.is_following_order(), "stop() while not in charge drops the kept walk")
	hands.move_to(Vector3(10, 0, 0))
	pawn.controller_manager.set_has_player(false)
	await _ticks(3)
	var corners := hands.path_follower.get_path_corners()
	_check(hands.path_follower.is_following_path() and corners[corners.size() - 1].x > 9.0, "in charge again: the kept walk starts")
	pawn.free()
	floor_body.free()


func _test_client_and_rollback() -> void:
	var floor_body := _make_floor(100.0)
	var counter := _b("Counter", 0.5)
	var pawn := _make_pawn([counter], [], Vector3(0, 0.1, 0))
	pawn.ai.decision_interval_ticks = 1
	await _ticks(5)
	var real_entity: NetworkEntity = pawn._entity
	var client_entity := NetworkEntity.new()
	client_entity.role = NetworkEntity.Role.REMOTE_FOLLOWING
	pawn._entity = client_entity
	var before := counter.ticks
	await _ticks(10)
	_check(not pawn.runs_ai_here() and counter.ticks == before, "on a client: the AI never runs")
	pawn._entity = real_entity
	client_entity.free()
	await _ticks(20)
	before = counter.ticks
	var went_back: bool = TickDriver.rollback(TickDriver.tick - 10)
	_check(went_back and counter.ticks == before, "a rollback replays 10 ticks without running the AI again")
	pawn.free()
	floor_body.free()


# --- Helpers ---


## A test behaviour scoring value, with max_score max (value when left out).
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


## A pawn whose behaviour manager holds these behaviours, and whose state manager holds these states plus Idle. It never decides
## on its own unless the test changes decision_interval_ticks.
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


## Makes one decision now, as the pawn's AI step would: the state is checked, then the behaviour manager decides.
func _decide(pawn: Pawn, tick: int, priority := 0, normal := true) -> void:
	var context := pawn.ai
	context.current_tick = tick
	context.request_decision(priority, normal)
	pawn.ai.state_manager.update_state(tick)
	pawn.ai.behaviour_manager.decide(tick)


func _running_name(pawn: Pawn) -> StringName:
	var running := pawn.ai.behaviour_manager.get_running_behaviour()
	return running.name if running else &""


func _make_floor(size: float) -> StaticBody3D:
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(size, 1.0, size)
	shape.shape = box
	shape.position.y = -0.5
	body.add_child(shape)
	add_child(body)
	return body


func _ticks(count: int) -> void:
	for i in count:
		await get_tree().physics_frame
