## Written by Claude (claude-opus-5-5), 2026-11-09: headless self-test for AIBehaviourManager, AIBehaviourBase, AIWanderBehaviour,
## AIContextComponent and the pawn's AI step. Checks the decision steps of pawn spec 10.8 one by one (hard rules, ranges, early stop,
## jitter, ties, the fixed order), persistence, interrupts, finishing, Wander, what runs while a player has the pawn, that a client
## never runs the AI, that a rollback doesn't run it again, and the odd cases at the top of AIBehaviourManager.gd.
## Exits 0 on success, 1 on failure. Run from the project folder:
##   "C:\Git\Test 2\Godot_v4.7.2-stable_win64_console.exe" --headless --path . "res://assets/scripts/ai/tests/ai_behaviour_manager_selftest.tscn"
extends Node

const PAWN_SCENE := "res://assets/scenes/pawn/pawn.tscn"
const NEVER := 100000000 # a decision interval so long the pawn never decides on its own, so the test decides by hand

var _failures := 0


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

	func is_available(_context: AIContextComponent) -> bool:
		return available

	func score(_context: AIContextComponent) -> float:
		scored += 1
		return value

	func enter(_context: AIContextComponent) -> void:
		entered += 1

	func tick(_context: AIContextComponent) -> Status:
		ticks += 1
		return finish_with

	func exit(_context: AIContextComponent, reason: String) -> void:
		exited += 1
		last_exit_reason = reason


## Walks to a point when it starts, through the AI controller.
class GoToBehaviour extends AIBehaviourBase:
	var target := Vector3.ZERO
	var walk_accepted := false

	func enter(context: AIContextComponent) -> void:
		walk_accepted = context.controller.move_to(target)


## A state a test can switch on.
class SwitchState extends AIStateBase:
	var fits := false

	func prerequisites_met(_context: AIContextComponent) -> bool:
		return fits


func _ready() -> void:
	print("--- AI behaviour manager self-test ---")
	await _test_empty_manager()
	_test_best_score_and_fixed_order()
	_test_hard_rules()
	_test_ranges_and_early_stop()
	_test_random_numbers_and_jitter()
	_test_ties()
	_test_persistence()
	_test_interrupts()
	await _test_finishing()
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
	pawn.ai_context.decision_interval_ticks = 1
	await _ticks(10)
	_check(pawn.ai_state_manager.get_current_state().name == &"Idle", "default parts: the state manager picks Idle")
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
	elsewhere.allowed_states = [&"Combat"]
	var fallback := _b("Fallback", 0.1)
	var pawn := _make_pawn([quick, target_needed, cant_press, elsewhere, fallback])
	_decide(pawn, 100)
	_check(_running_name(pawn) == &"Quick", "a behaviour needing a target, one whose action can't start, and one for another state are all skipped")
	_check(target_needed.scored == 0 and cant_press.scored == 0 and elsewhere.scored == 0, "...without running their score()")
	pawn.ai_behaviour_manager.tick_running(101) # Quick finishes, and the manager decides at once
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
	var pawn := _make_pawn([_b("A", 0.5), _b("B", 0.5)])
	var context := pawn.ai_context
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
	pawn.ai_behaviour_manager.set_score_jitter(&"B", 0.2)
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
	pawn.ai_behaviour_manager.set_score_jitter(&"B", -1.0)
	pawn.ai_behaviour_manager.default_score_jitter = 0.2
	var a_seen := false
	var b_seen := false
	for t in 60:
		_decide(pawn, 3000 + t)
		a_seen = a_seen or _running_name(pawn) == &"A"
		b_seen = b_seen or _running_name(pawn) == &"B"
	_check(a_seen and b_seen, "-1 uses the manager's default_score_jitter")
	pawn.free()


func same_seed_value(context: AIContextComponent) -> float:
	var seed_now := context.random_seed
	context.random_seed = 0
	var value := context.random_unit_at(500, 77)
	context.random_seed = seed_now
	return value


func _test_ties() -> void:
	var pawn := _make_pawn([_b("Kilo", 0.5), _b("Lima", 0.5), _b("Mike", 0.5)])
	pawn.ai_behaviour_manager.randomize_ties = true
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


func _test_persistence() -> void:
	var keeper := _b("Keeper", 0.5)
	keeper.persistence = 0.1
	keeper.persistence_fade = _linear(10, 10) # full for 10 ticks, gone 10 ticks later
	var rival := _b("Rival", 0.4, 1.0) # max 1.0, because the test raises its score
	var pawn := _make_pawn([keeper, rival])
	_decide(pawn, 100)
	_check(_running_name(pawn) == &"Keeper", "persistence: Keeper wins first, and its persistence starts")
	rival.value = 0.55
	_decide(pawn, 105)
	_check(_running_name(pawn) == &"Keeper", "while held, +0.1 keeps it ahead of a rival at 0.55")
	_decide(pawn, 117)
	_check(_running_name(pawn) == &"Rival", "faded to under 0.05 by tick 17, the rival wins")
	# Modifiers: more ticks, and a slower fade.
	rival.value = 0.4
	_decide(pawn, 200)
	_check(_running_name(pawn) == &"Keeper", "Keeper wins back over a rival at 0.4, and its persistence starts again")
	rival.value = 0.55
	_test_persistence_modifiers(pawn, keeper)
	pawn.free()
	# Negative persistence: prefers something else after it's been chosen.
	var restless := _b("Restless", 0.5)
	restless.persistence = -0.2
	restless.persistence_fade = _linear(30, 0)
	var other := _b("Other", 0.4)
	pawn = _make_pawn([restless, other])
	_decide(pawn, 1)
	_check(_running_name(pawn) == &"Restless", "negative persistence: Restless wins first")
	_decide(pawn, 2)
	_check(_running_name(pawn) == &"Other", "then -0.2 makes the AI prefer Other for a while")
	_decide(pawn, 40)
	_check(_running_name(pawn) == &"Restless", "once it's faded, Restless wins again")
	pawn.free()


# Keeper is running with +0.1, held 10 ticks then gone 10 later; the rival is at 0.55. Modifiers read the current tick from
# TickDriver, so the test sets Keeper's persistence against TickDriver's tick.
func _test_persistence_modifiers(pawn: Pawn, keeper: TestBehaviour) -> void:
	var now: int = TickDriver.tick
	keeper.start_persistence(now - 25) # 25 ticks along: past its 20, so it adds nothing
	pawn.ai_behaviour_manager.add_persistence_ticks(&"Keeper", 20) # back to 5 ticks along: held at full
	_decide(pawn, now)
	_check(_running_name(pawn) == &"Keeper", "add_persistence_ticks: 20 ticks more keep Keeper ahead of the rival")
	keeper.start_persistence(now - 25)
	_decide(pawn, now)
	_check(_running_name(pawn) == &"Rival", "...and without them, the rival wins")
	keeper.start_persistence(now)
	pawn.ai_behaviour_manager.set_persistence_speed(&"Keeper", 0.0)
	_check(is_equal_approx(keeper.persistence_now(now + 500), 0.1), "set_persistence_speed 0: frozen at full 500 ticks later")
	pawn.ai_behaviour_manager.set_persistence_speed(&"Keeper", 2.0)
	_check(is_equal_approx(keeper.persistence_now(now + 5), 0.1) and keeper.persistence_now(now + 10) == 0.0, "speed 2: through its 20 ticks in 10")


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
	pawn.ai_behaviour_manager.tick_running(3)
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
	guard.allowed_states = [&"Idle"]
	guard.interrupt_threshold = 50
	var fight := _b("Fight", 0.5)
	fight.allowed_states = [&"Combat"]
	pawn = _make_pawn([guard, fight], [combat])
	_decide(pawn, 1)
	combat.fits = true
	_decide(pawn, 2) # the state check moves to Combat, a state-change event of priority 20
	_check(pawn.ai_state_manager.get_current_state() == combat and _running_name(pawn) == &"Guard", "a threshold above the new state's priority keeps a behaviour running in a state that doesn't allow it")
	pawn.ai_behaviour_manager.set_interrupt_threshold(&"Guard", 0)
	_decide(pawn, 3)
	_check(_running_name(pawn) == &"Fight", "set_interrupt_threshold: lowered while running, the next decision replaces it")
	pawn.free()


func _test_finishing() -> void:
	var once := _b("Once", 0.9)
	once.finish_with = AIBehaviourBase.Status.FAILED
	once.cooldown_ticks = 1000
	var after := _b("After", 0.2)
	var pawn := _make_pawn([once, after])
	pawn.ai_context.decision_interval_ticks = NEVER
	_decide(pawn, TickDriver.tick)
	_check(_running_name(pawn) == &"Once", "a behaviour that will fail starts")
	await _ticks(2)
	_check(once.last_exit_reason == "failed" and _running_name(pawn) == &"After", "on its first tick it fails, and the manager decides at once")
	_check(after.entered == 1 and after.ticks >= 1, "and the next one starts and ticks")
	pawn.free()


func _test_odd_cases() -> void:
	var lonely := AIBehaviourManager.new()
	print("  (a warning about a parent that isn't a Pawn is expected next)")
	add_child(lonely)
	lonely.decide(0)
	_check(lonely.get_running_behaviour() == null, "its parent isn't a Pawn: it does nothing")
	lonely.free()
	var only_combat := _b("OnlyCombat", 0.5)
	only_combat.allowed_states = [&"Combat"]
	var pawn := _make_pawn([only_combat])
	print("  (a warning about a state with no behaviour is expected next, once)")
	_decide(pawn, 1)
	_decide(pawn, 2)
	_check(pawn.ai_behaviour_manager.get_running_behaviour() == null, "a state that allows none of its behaviours: nothing runs")
	pawn.free()
	var liar := _b("Liar", 0.9, 0.5) # scores 0.9 but says its max is 0.5
	pawn = _make_pawn([liar])
	print("  (a warning about a score above max_score is expected next, once)")
	_decide(pawn, 1)
	_decide(pawn, 2)
	_check(liar.warned_score_range, "a score above max_score: a warning naming it")
	print("  (a warning about a missing behaviour is expected next)")
	pawn.ai_behaviour_manager.set_score_jitter(&"Nobody", 0.5)
	_check(true, "a behaviour asked for by name that doesn't exist: a warning, nothing else")
	pawn.free()


func _test_wander() -> void:
	var floor_body := _make_floor(100.0)
	var wander := AIWanderBehaviour.new()
	wander.name = "Wander"
	wander.wander_radius = 6.0
	wander.min_pause_ticks = 20
	wander.max_pause_ticks = 40
	var pawn := _make_pawn([wander], [], Vector3(0, 0.1, 0))
	pawn.ai_context.decision_interval_ticks = 15
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
	pawn.ai_context.decision_interval_ticks = 1
	await _ticks(5)
	var context := pawn.ai_context
	context.while_possessed = AIContextComponent.WhilePossessed.MEMORY_ONLY
	pawn.set_has_player(true) # a player on another machine, so nobody here is in charge
	var before := counter.ticks
	await _ticks(10)
	_check(counter.ticks == before, "MEMORY_ONLY (the default): behaviours pause while a player has the pawn")
	pawn.set_has_player(false)
	await _ticks(5)
	_check(counter.ticks > before and _running_name(pawn) == &"Counter", "letting go: the same behaviour carries on, with no special code")
	context.while_possessed = AIContextComponent.WhilePossessed.OFF
	pawn.set_has_player(true)
	before = counter.ticks
	await _ticks(10)
	_check(counter.ticks == before, "OFF: nothing runs while a player has the pawn")
	context.while_possessed = AIContextComponent.WhilePossessed.FULL
	await _ticks(10)
	_check(counter.ticks > before, "FULL: behaviours keep running")
	pawn.set_has_player(false)
	pawn.free()
	# FULL: the hands keep the order without touching the player's path, and carry it out once in charge again.
	var go := GoToBehaviour.new()
	go.name = "GoTo"
	go.target = Vector3(10, 0, 0)
	pawn = _make_pawn([go], [], Vector3(0, 0.1, 0))
	pawn.ai_context.while_possessed = AIContextComponent.WhilePossessed.FULL
	pawn.ai_context.decision_interval_ticks = NEVER
	await _ticks(5)
	pawn.set_has_player(true)
	pawn.navigation_manager.move_to(Vector3(-10, 0, 0)) # the player's path
	_decide(pawn, TickDriver.tick) # GoTo starts while the AI isn't in charge
	var hands: AIController = pawn.controller_manager.ai_controller
	_check(go.walk_accepted and hands.is_following_order(), "FULL, not in charge: move_to is accepted and kept")
	var corners := pawn.navigation_manager.get_path_corners()
	_check(pawn.navigation_manager.is_following_path() and corners[corners.size() - 1].x < -9.0, "and the player's path is left alone")
	hands.stop()
	_check(pawn.navigation_manager.is_following_path(), "stop() while not in charge leaves the player's path alone too")
	hands.move_to(Vector3(10, 0, 0))
	pawn.set_has_player(false)
	await _ticks(3)
	corners = pawn.navigation_manager.get_path_corners()
	_check(pawn.navigation_manager.is_following_path() and corners[corners.size() - 1].x > 9.0, "in charge again: the kept walk starts")
	pawn.free()
	floor_body.free()


func _test_client_and_rollback() -> void:
	var floor_body := _make_floor(100.0)
	var counter := _b("Counter", 0.5)
	var pawn := _make_pawn([counter], [], Vector3(0, 0.1, 0))
	pawn.ai_context.decision_interval_ticks = 1
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


## Makes one decision now, as the pawn's AI step would: the state is checked, then the behaviour manager decides.
func _decide(pawn: Pawn, tick: int, priority := 0, normal := true) -> void:
	var context := pawn.ai_context
	context.current_tick = tick
	context.request_decision(priority, normal)
	pawn.ai_state_manager.update_state(tick)
	pawn.ai_behaviour_manager.decide(tick)


func _running_name(pawn: Pawn) -> StringName:
	var running := pawn.ai_behaviour_manager.get_running_behaviour()
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


func _check(passed: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if passed else "FAIL", what])
	if not passed:
		_failures += 1
