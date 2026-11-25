## Written by Claude (claude-opus-5-5), 2026-11-09: headless self-test for AIStateManager and AIStateBase. Checks picking by priority,
## the fixed order, forced states with priorities, running out and releasing, the signal, and the odd cases at the top of
## AIStateManager.gd. Claude 2026-11-09 (scaling spec step 3): and forces asked for during a tick, which wait for the next AI step.
## Claude 2026-11-25 (pawn spec 16.10 step 6b): forcing is gone; the AI manager's request inbox is checked instead.
## Exits 0 on success, 1 on failure. Run from the project folder:
##   godot --headless --path . "res://assets/scripts/ai/tests/ai_state_manager_selftest.tscn"
extends SelfTest # Claude 2026-11-16 (wider audit): _check and _failures come from tests/SelfTest.gd now

const PAWN_SCENE := "res://assets/scenes/pawn/pawn.tscn"


## A state a test can switch on and off, with a tunable threshold the way real states should have.
class SwitchState extends AIStateBase:
	@export var needed := 1
	var level := 0
	var entered := 0
	var exited := 0

	func prerequisites_met(_context: AIManager) -> bool:
		return level >= needed

	func enter(_context: AIManager) -> void:
		entered += 1

	func exit(_context: AIManager) -> void:
		exited += 1


func _ready() -> void:
	# Claude 2026-11-09 (scaling spec step 6): these checks count exact ticks at the reference rate, 60 a second, so they pin it, even
	# in a run at another rate (-- --tick-rate=30). tick_rate_selftest checks that converted settings last the same time at 30.
	TickDriver.tick_rate = TickDriver.REFERENCE_RATE
	print("--- AI state manager self-test ---")
	await _test_priority_order()
	_test_fixed_order()
	await _test_request_inbox() # Claude 2026-11-25 (pawn spec 16.10 step 6b): forcing is gone; outside requests go through the inbox
	_test_odd_cases()
	print("--- ALL PASSED ---" if _failures == 0 else "--- %d FAILED ---" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)


func _test_priority_order() -> void:
	var combat := _state("Combat", 20)
	var alert := _state("Alert", 10)
	var pawn := _make_pawn([alert, combat]) # added lowest first on purpose
	var states := pawn.ai.state_manager
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
	for state in first.ai.state_manager.get_states():
		a.append(state.name)
	for state in second.ai.state_manager.get_states():
		b.append(state.name)
	_check(a == b and a[0] == &"Alpha", "the same order whatever order they were added in: %s" % str(a))
	first.ai.state_manager.update_state(0)
	second.ai.state_manager.update_state(0)
	_check(first.ai.state_manager.get_current_state().name == &"Alpha" and second.ai.state_manager.get_current_state().name == &"Alpha", "so both pick the same state")
	first.free()
	second.free()


## Claude 2026-11-25 (pawn spec 16.10 step 6b): forcing a state or a target is gone. Requests from outside the AI go through the AI
## manager's inbox: asked during a tick (here from after_simulate, as another pawn's hit or ability would), they wait for the pawn's
## next AI step and apply in the order asked; on a client they're ignored, with one warning.
func _test_request_inbox() -> void:
	var pawn := _make_pawn([_state("Combat", 20)])
	await _ticks(2)
	var behaviours := pawn.ai.behaviour_manager
	var charge := AIBehaviourModifier.new()
	charge.granted_tags = [Tags.AI.STANCE_MELEE]
	var seen := {}
	TickDriver.after_simulate.connect(func(_dt: float, _tick: int) -> void:
		pawn.ai.add_modifier(charge, &"shout")
		pawn.ai.set_input(&"test_morale", 0.25)
		seen["waiting"] = pawn.ai.waiting_requests()
		seen["applied right away"] = behaviours.get_modifiers().size(), CONNECT_ONE_SHOT)
	await _ticks(1)
	_check(seen.get("waiting", 0) == 2 and seen.get("applied right away", -1) == 0, "requests asked during a tick wait in the inbox")
	await _ticks(2)
	_check(behaviours.get_modifiers().size() == 1 and pawn.owned_tags.has(Tags.AI.STANCE_MELEE) and pawn.ai.waiting_requests() == 0,
			"the pawn's next AI step applies them: the modifier is added, its tag owned")
	_check(is_equal_approx(pawn.ai.inputs.value(AIInputs.slot_of(&"test_morale")), 0.25), "and the game's input is set")
	# In the order asked: a remove then an add leaves the modifier; an add then a remove leaves none.
	pawn.ai.remove_modifiers(&"shout")
	pawn.ai.add_modifier(charge, &"shout")
	pawn.ai.apply_requests()
	_check(behaviours.get_modifiers().size() == 1, "remove, then add: in the order asked, it's there")
	pawn.ai.add_modifier(charge, &"other")
	pawn.ai.remove_modifiers(&"other")
	pawn.ai.remove_modifiers(&"shout")
	pawn.ai.apply_requests()
	_check(behaviours.get_modifiers().is_empty() and not pawn.owned_tags.has(Tags.AI.STANCE_MELEE), "add, then remove: none left")
	# A source asked by object is kept by its id, so one freed before the request applies still matches.
	var shouter := Node.new()
	pawn.ai.add_modifier(charge, shouter)
	pawn.ai.apply_requests()
	pawn.ai.remove_modifiers(shouter)
	shouter.free()
	pawn.ai.apply_requests()
	_check(behaviours.get_modifiers().is_empty(), "a source freed after asking still removes its own")
	# On a client the AI doesn't run, so requests are ignored.
	var real_entity: NetworkEntity = pawn._entity
	var client_entity := NetworkEntity.new()
	client_entity.role = NetworkEntity.Role.REMOTE_FOLLOWING
	pawn._entity = client_entity
	print("  (a warning about a request on a client is expected next, once)")
	pawn.ai.add_modifier(charge, &"client")
	pawn.ai.add_modifier(charge, &"client again")
	_check(pawn.ai.waiting_requests() == 0, "on a client: ignored, with one warning")
	pawn._entity = real_entity
	client_entity.free()
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
	pawn.ai.state_manager.update_state(0)
	only.level = 0
	print("  (a warning about no state fitting is expected next)")
	pawn.ai.state_manager.update_state(1)
	_check(pawn.ai.state_manager.get_current_state() == only, "no state fits: it keeps the current one")
	pawn.free()
	var automatic := SwitchState.new() # no name set
	var holder := AIStateManager.new()
	holder.name = "AIStateManager"
	holder.add_child(automatic) # GDScript note: a node added with no name gets an automatic one, like "@Node@123"
	var other: Pawn = load(PAWN_SCENE).instantiate()
	AITestPawns.ai_of(other).add_child(holder)
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
	AITestPawns.ai_of(pawn).add_child(manager)
	add_child(pawn)
	pawn.ai.decision_interval_ticks = 1
	return pawn


func _ticks(count: int) -> void:
	for i in count:
		await get_tree().physics_frame
