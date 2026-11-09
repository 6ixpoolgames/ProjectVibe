## Written by Claude (claude-opus-5-5), 2026-11-09: headless self-test for AIStateManager and AIStateBase. Checks picking by priority,
## the fixed order, forced states with priorities, running out and releasing, the signal, and the odd cases at the top of
## AIStateManager.gd. Claude 2026-11-09 (scaling spec step 3): and forces asked for during a tick, which wait for the next AI step.
## Exits 0 on success, 1 on failure. Run from the project folder:
##   "C:\Git\Test 2\Godot_v4.7.2-stable_win64_console.exe" --headless --path . "res://assets/scripts/ai/tests/ai_state_manager_selftest.tscn"
extends Node

const PAWN_SCENE := "res://assets/scenes/pawn/pawn.tscn"

var _failures := 0


## A state a test can switch on and off, with a tunable threshold the way real states should have.
class SwitchState extends AIStateBase:
	@export var needed := 1
	var level := 0
	var entered := 0
	var exited := 0

	func prerequisites_met(_context: AIContextComponent) -> bool:
		return level >= needed

	func enter(_context: AIContextComponent) -> void:
		entered += 1

	func exit(_context: AIContextComponent) -> void:
		exited += 1


func _ready() -> void:
	# Claude 2026-11-09 (scaling spec step 6): these checks count exact ticks at the reference rate, 60 a second, so they pin it, even
	# in a run at another rate (-- --tick-rate=30). tick_rate_selftest checks that converted settings last the same time at 30.
	TickDriver.tick_rate = TickDriver.REFERENCE_RATE
	print("--- AI state manager self-test ---")
	await _test_priority_order()
	_test_fixed_order()
	await _test_forcing()
	await _test_forcing_during_a_tick()
	_test_odd_cases()
	print("--- ALL PASSED ---" if _failures == 0 else "--- %d FAILED ---" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)


func _test_priority_order() -> void:
	var combat := _state("Combat", 20)
	var alert := _state("Alert", 10)
	var pawn := _make_pawn([alert, combat]) # added lowest first on purpose
	var states := pawn.ai_state_manager
	var changes := []
	states.state_changed.connect(func(old, new, reason): changes.append([old, new, reason]))
	await _ticks(3) # decisions every tick in this test
	_check(states.get_current_state().name == &"Idle", "nothing fits but Idle: Idle")
	_check(changes.size() == 1 and changes[0][0] == null and changes[0][1].name == &"Idle", "state_changed for the first pick, with no old state")
	alert.level = 1
	await _ticks(2)
	_check(states.get_current_state() == alert and alert.entered == 1, "Alert fits: Alert, and its enter() ran")
	combat.level = 1
	await _ticks(2)
	_check(states.get_current_state() == combat and alert.exited == 1, "Combat fits too: the higher priority wins, and Alert's exit() ran")
	combat.level = 0
	await _ticks(2)
	_check(states.get_current_state() == alert, "Combat stops fitting: back to Alert at once, with no stay rule")
	alert.needed = 2 # a threshold changed in the inspector
	await _ticks(2)
	_check(states.get_current_state().name == &"Idle", "a tunable threshold: raising it drops the pawn to Idle")
	_check(changes.size() == 5, "one signal per change (%d)" % changes.size())
	pawn.free()


func _test_fixed_order() -> void:
	# Two states with the same priority: the name decides, whichever was added first.
	var first := _make_pawn([_state("Bravo", 5, 0), _state("Alpha", 5, 0)])
	var second := _make_pawn([_state("Alpha", 5, 0), _state("Bravo", 5, 0)])
	var a: Array[StringName] = []
	var b: Array[StringName] = []
	for state in first.ai_state_manager.get_states():
		a.append(state.name)
	for state in second.ai_state_manager.get_states():
		b.append(state.name)
	_check(a == b and a[0] == &"Alpha", "the same order whatever order they were added in: %s" % str(a))
	first.ai_state_manager.update_state(0)
	second.ai_state_manager.update_state(0)
	_check(first.ai_state_manager.get_current_state().name == &"Alpha" and second.ai_state_manager.get_current_state().name == &"Alpha", "so both pick the same state")
	first.free()
	second.free()


func _test_forcing() -> void:
	var combat := _state("Combat", 20)
	var flee := _state("Flee", 30)
	var pawn := _make_pawn([combat, flee])
	var states := pawn.ai_state_manager
	await _ticks(2)
	_check(states.force_state(&"Combat", 10, 50, "test"), "a force is accepted")
	_check(states.get_current_state() == combat, "and takes effect at once, though Combat's prerequisites don't hold")
	_check(pawn.ai_context.has_decision_waiting() and pawn.ai_context.waiting_event_priority() == 50, "and asks for a decision with the force's priority")
	await _ticks(5)
	_check(states.get_current_state() == combat, "it holds while the normal check would say Idle")
	print("  (a refused force is logged next)")
	_check(not states.force_state(&"Flee", 10, 40, "weaker"), "a weaker force is refused")
	_check(states.get_current_state() == combat, "and changes nothing")
	_check(states.force_state(&"Flee", -1, 50, "as strong"), "an equal one replaces it")
	await _ticks(20)
	_check(states.get_current_state() == flee and states.is_state_forced(), "hold_ticks -1: it holds until released, past the old force's time")
	states.release_forced_state()
	await _ticks(2)
	_check(states.get_current_state().name == &"Idle" and not states.is_state_forced(), "released: the normal check picks Idle again")
	states.force_state(&"Combat", 4, 1, "short")
	await _ticks(7)
	_check(states.get_current_state().name == &"Idle", "a force runs out after hold_ticks, and the normal check takes over on time")
	print("  (a warning about a missing state is expected next)")
	_check(not states.force_state(&"Nowhere", 10, 99, "missing"), "a state it doesn't have: false")
	# On a client, the AI doesn't run, so forcing does nothing.
	var real_entity: NetworkEntity = pawn._entity
	var client_entity := NetworkEntity.new()
	client_entity.role = NetworkEntity.Role.REMOTE_FOLLOWING
	pawn._entity = client_entity
	print("  (a warning about forcing on a client is expected next)")
	_check(not states.force_state(&"Combat", 10, 99, "client"), "on a client: refused, with a warning")
	pawn._entity = real_entity
	client_entity.free()
	pawn.free()


## Claude 2026-11-09 (scaling spec step 3): a force or release asked for during a tick (here from after_simulate, as another pawn's
## hit or ability would) waits for the pawn's next AI step, and queued ones apply in the order they were asked for. Forced targets
## (taunts) work the same way.
func _test_forcing_during_a_tick() -> void:
	var combat := _state("Combat", 20)
	var flee := _state("Flee", 30)
	var pawn := _make_pawn([combat, flee])
	var taunter: Pawn = load(PAWN_SCENE).instantiate()
	taunter.team = 5
	taunter.position = Vector3(30, 0, 0)
	add_child(taunter)
	var states := pawn.ai_state_manager
	var selector := pawn.ai_target_selector
	await _ticks(2)
	var seen := {}
	TickDriver.after_simulate.connect(func(_dt: float, _tick: int) -> void:
		seen["state accepted"] = states.force_state(&"Combat", 60, 50, "during a tick")
		seen["weaker accepted"] = states.force_state(&"Flee", 60, 40, "weaker, during a tick")
		seen["target accepted"] = selector.force_target(taunter, 60, 10, "taunt during a tick")
		seen["state right after"] = states.get_current_state().name
		seen["target right after"] = selector.get_current_target(), CONNECT_ONE_SHOT)
	await _ticks(1)
	_check(seen.get("state accepted", false) and seen.get("weaker accepted", false) and seen.get("target accepted", false), "during a tick, forces are queued and return true")
	_check(seen.get("state right after") == &"Idle" and seen.get("target right after") == null, "and change nothing yet")
	await _ticks(2)
	_check(states.get_current_state() == combat and states.is_state_forced(), "the pawn's next AI step applies them: Combat, forced")
	_check(selector.get_current_target() == taunter and selector.is_target_forced(), "and the taunt: the target is forced")
	TickDriver.after_simulate.connect(func(_dt: float, _tick: int) -> void:
		states.release_forced_state()
		selector.release_forced_target()
		seen["still forced"] = states.is_state_forced() and selector.is_target_forced(), CONNECT_ONE_SHOT)
	await _ticks(3)
	_check(seen.get("still forced", false) and not states.is_state_forced() and not selector.is_target_forced() and states.get_current_state().name == &"Idle", "releases during a tick wait too, then hand back")
	TickDriver.after_simulate.connect(func(_dt: float, _tick: int) -> void:
		states.force_state(&"Combat", 60, 50, "first")
		states.force_state(&"Flee", 60, 50, "second, as strong"), CONNECT_ONE_SHOT)
	await _ticks(3)
	_check(states.get_current_state() == flee, "queued forces apply in the order they were asked for: the second, as strong, replaces the first")
	states.release_forced_state()
	taunter.free()
	pawn.free()


func _test_odd_cases() -> void:
	var lonely := AIStateManager.new()
	print("  (a warning about a parent that isn't a Pawn is expected next)")
	add_child(lonely)
	lonely.update_state(0)
	_check(lonely.get_current_state() == null, "its parent isn't a Pawn: it never picks a state")
	lonely.free()
	# No state fits, and no Idle: it stays where it was.
	var only := _state("Only", 1)
	var pawn := _make_pawn([only], false)
	only.level = 1
	pawn.ai_state_manager.update_state(0)
	only.level = 0
	print("  (a warning about no state fitting is expected next)")
	pawn.ai_state_manager.update_state(1)
	_check(pawn.ai_state_manager.get_current_state() == only, "no state fits: it keeps the current one")
	pawn.free()
	var automatic := SwitchState.new() # no name set
	var holder := AIStateManager.new()
	holder.name = "AIStateManager"
	holder.add_child(automatic) # GDScript note: a node added with no name gets an automatic one, like "@Node@123"
	var other: Pawn = load(PAWN_SCENE).instantiate()
	other.add_child(holder)
	print("  (a warning about an automatic name is expected next)")
	add_child(other)
	_check(holder.get_states().size() == 1, "a state with an automatic name still works, with a warning")
	other.free()


# --- Helpers ---


func _state(state_name: String, priority: int, needed := 1) -> SwitchState:
	var state := SwitchState.new()
	state.name = state_name
	state.priority = priority
	state.needed = needed
	return state


## A pawn whose state manager holds these states, plus Idle unless with_idle is false. Decides every tick.
func _make_pawn(states: Array, with_idle := true) -> Pawn:
	var pawn: Pawn = load(PAWN_SCENE).instantiate()
	var manager := AIStateManager.new()
	manager.name = "AIStateManager"
	for state in states:
		manager.add_child(state)
	if with_idle:
		var idle := AIIdleState.new()
		idle.name = "Idle"
		manager.add_child(idle)
	pawn.add_child(manager)
	add_child(pawn)
	pawn.ai_context.decision_interval_ticks = 1
	return pawn


func _ticks(count: int) -> void:
	for i in count:
		await get_tree().physics_frame


func _check(passed: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if passed else "FAIL", what])
	if not passed:
		_failures += 1
