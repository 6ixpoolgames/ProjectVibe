## Written by Claude (claude-opus-5-5), 2026-11-04: headless self-test for AIStateManagerComponent and the example states.
## Checks match the corner cases documented at the top of AIStateManager.gd. Exits 0 on success, 1 on failure.
## Run from the project folder (as a scene, so the project's autoloads exist):
##   Godot_v4.4.1-stable_win64.exe --headless --path . "res://assets/scripts/Character Pawn/AI Core Components/tests/ai_state_selftest.tscn"
extends Node

var _failures := 0
var _changes: Array = []


## A state the test controls directly.
class Scripted extends AIStateComponentBase:
	var valid := false
	var exitable := true

	func is_valid(_c: AIContext) -> bool:
		return valid

	func can_exit(_c: AIContext) -> bool:
		return exitable


func _ready() -> void:
	print("--- AI state self-test ---")
	_test_rules()
	_test_behaviour_link()
	_test_example_states()
	print("--- ALL PASSED ---" if _failures == 0 else "--- %d FAILED ---" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)


func _test_rules() -> void:
	var m := _manager()
	m.update(0.25)
	_check(m.get_current_state_name() == &"", "no states and no Idle node: no state")

	var low := _scripted(m, "Low", 20)
	var high := _scripted(m, "High", 10)
	var idle := AIStateComponentBase.new()
	idle.name = "Idle"
	m.add_child(idle)
	m.state_changed.connect(func(o, n): _changes.append([o, n]))

	m.update(0.25)
	_check(m.get_current_state_name() == &"Idle", "nothing valid: default_state (Idle)")
	low.valid = true
	high.valid = true
	m.update(0.25)
	_check(m.get_current_state_name() == &"High", "lowest priority number wins")
	_check(_changes.back() == [&"Idle", &"High"], "state_changed reports old and new names")

	var twin := _scripted(m, "Twin", 10)
	twin.valid = true
	m.update(0.25)
	_check(m.get_current_state_name() == &"High", "equal priority: the one higher in the tree wins")
	twin.free()

	high.valid = false
	m.update(0.25)
	_check(m.get_current_state_name() == &"Low", "current becomes invalid: next valid state")

	low.min_time_in_state = 1.0
	high.valid = true
	m.update(0.25)
	_check(m.get_current_state_name() == &"Low", "min_time_in_state blocks leaving early")
	m.update(0.25)
	m.update(0.25)
	m.update(0.25)
	_check(m.get_current_state_name() == &"High", "after min_time_in_state it can leave")
	low.min_time_in_state = 0.0

	_check(not m.force_state(&"Nope"), "force_state with an unknown name returns false")
	_check(m.get_current_state_name() == &"High", "...and changes nothing")
	_check(m.force_state(&"Low", 0.5) and m.get_current_state_name() == &"Low", "force_state switches immediately, ignoring priority")
	m.update(0.25)
	_check(m.get_current_state_name() == &"Low", "forced state holds while its time lasts")
	m.update(0.25)
	m.update(0.25)
	_check(m.get_current_state_name() == &"High", "forced state expires back to normal evaluation")
	m.force_state(&"Low")
	m.update(0.25)
	m.update(0.25)
	m.update(0.25)
	_check(m.get_current_state_name() == &"Low", "force with no duration lasts until cleared")
	m.clear_forced_state()
	_check(m.get_current_state_name() == &"High", "clear_forced_state returns to normal evaluation")

	high.exitable = false
	high.valid = false
	m.update(0.25)
	_check(m.get_current_state_name() == &"High", "can_exit false: stays even when invalid")
	m.force_state(&"Low", 1.0)
	_check(m.get_current_state_name() == &"High", "can_exit false: forced states can't move it either")
	m.free()


func _test_behaviour_link() -> void:
	var m := _manager()
	var calm := _scripted(m, "Calm", 20)
	var panic := _scripted(m, "Panic", 10)
	calm.valid = true

	var bm := AIBehaviourManagerComponent.new()
	bm.active = false
	bm.decision_interval = 0.25
	bm.context = m.context # one shared context, as the AI core does
	add_child(bm)
	m.state_changed.connect(bm._on_state_changed)
	var relax := AIBehaviourComponentBase.new()
	relax.name = "Relax"
	relax.stateName = &"Calm"
	bm.add_child(relax)
	var flee := AIBehaviourComponentBase.new()
	flee.name = "Flee"
	flee.stateName = &"Panic"
	bm.add_child(flee)

	m.update(0.25)
	bm.update(0.25)
	_check(bm.current == relax, "behaviour gated to the current state runs")
	panic.valid = true
	m.update(0.25)
	bm.update(0.01) # mid-interval, but the state change wakes it
	_check(bm.current == flee, "state change re-decides behaviours immediately (gating follows the state)")
	bm.free()
	m.free()


func _test_example_states() -> void:
	var m := _manager()
	for script in [DeadState, IncapacitatedState, RoutedState, AggressiveState, AlertedState]:
		var s: AIStateComponentBase = script.new()
		s.name = script.get_global_name().trim_suffix("State")
		m.add_child(s)
	var idle := IdleAIStateBase.new()
	idle.name = "Idle"
	m.add_child(idle)

	# No stats, no memory: every example state treats a missing part as "not valid".
	m.update(0.25)
	_check(m.get_current_state_name() == &"Idle", "missing memory and stats: falls back to Idle")

	var stats := CharacterStatManager.new()
	add_child(stats)
	var health := StatComponentBase.new(StatBlockRes.new("Health", 10, 10))
	stats.add_child(health)
	var mem := AIMemoryComponent.new()
	add_child(mem)
	m.context.statManager = stats
	m.context.memory = mem
	var enemy := Node3D.new()

	mem.record(&"pawn_seen", enemy, Vector3.ZERO)
	m.update(0.25)
	_check(m.get_current_state_name() == &"Aggressive", "fresh sighting: Aggressive")
	mem.decay_by(5.0) # confidence 1.0 -> 0.5
	m.update(0.25)
	_check(m.get_current_state_name() == &"Alerted", "fading memory: Alerted")
	mem.decay_by(10.0) # 0.5 -> 0.125
	m.update(0.25)
	_check(m.get_current_state_name() == &"Idle", "faded memory: back to Idle")

	mem.record(&"pawn_seen", enemy, Vector3.ZERO)
	health.currValue = 1.0
	m.update(0.25)
	_check(m.get_current_state_name() == &"Routed", "low health with a threat: Routed")
	health.currValue = 3.0
	m.update(0.25)
	_check(m.get_current_state_name() == &"Routed", "still Routed below recover_above (no flicker)")
	health.currValue = 5.0
	m.update(0.25)
	_check(m.get_current_state_name() == &"Aggressive", "recovered: leaves Routed (the old version never did)")

	_check(m.force_state(&"Incapacitated", 0.5) and m.get_current_state_name() == &"Incapacitated", "force_state Incapacitated (a stun)")
	m.update(0.25)
	m.update(0.25)
	m.update(0.25)
	_check(m.get_current_state_name() == &"Aggressive", "stun wears off")

	health.currValue = 0.0
	m.update(0.25)
	_check(m.get_current_state_name() == &"Dead", "health 0: Dead")
	health.currValue = 10.0
	m.force_state(&"Incapacitated", 1.0)
	m.update(0.25)
	_check(m.get_current_state_name() == &"Dead", "Dead is permanent, even when healed or forced")

	enemy.free()
	m.free()


func _manager() -> AIStateManagerComponent:
	var m := AIStateManagerComponent.new()
	m.active = false # the test drives update() itself
	m.evaluation_interval = 0.25
	add_child(m)
	return m


func _scripted(m: AIStateManagerComponent, id: String, priority: int) -> Scripted:
	var s := Scripted.new()
	s.name = id
	s.state_priority = priority
	m.add_child(s)
	return s


func _check(ok: bool, what: String) -> void:
	print(("  PASS  " if ok else "  FAIL  ") + what)
	if not ok:
		_failures += 1
