## Written by Claude (claude-opus-5-5), 2026-11-09: headless self-test for presses as requests: when several abilities answer one
## action, the highest priority that can start wins (it was the lowest), priority_jitter varies the choice from tick to tick but never
## within one tick, and the faction arena's attacks: the attack request gives the normal swing, then a follow-up while that cools
## down, and the special request gives the heavy attack. Claude 2026-11-10: the follow-up is now a combo made of boosts (_test_combo).
## Claude 2026-11-16 (pawn spec 8.20): and now a combo counted by position, light and heavy mixed (_test_combo).
## Exits 0 on success, 1 on failure. Run from the project folder:
##   "C:\Git\Test 2\Godot_v4.7.2-stable_win64_console.exe" --headless --path . "res://assets/scripts/abilities/tests/attack_request_selftest.tscn"
extends Node

const PAWN_SCENE := "res://assets/scenes/pawn/pawn.tscn"
const PLAYER_SCENE := "res://assets/scenes/samples/faction_player.tscn"
const ABILITY_PART := "res://assets/scenes/pawn/parts/AbilityManager.tscn"
const NO_AI: Array[StringName] = [&"AISensingManager", &"AIMemory", &"AITargetSelector", &"AIStateManager", &"AIBehaviourManager"]

var _failures := 0


## A test-only action: runs for a tenth of a second on ability_1, and counts its starts.
class Marker extends AbilityBase:
	var starts := 0
	func _init() -> void:
		super()
		kind = Kind.ACTION
		trigger_action = &"ability_1"
		duration = 0.1
	func start() -> void:
		starts += 1


func _ready() -> void:
	print("--- Attack request self-test ---")
	TickDriver.tick_rate = TickDriver.REFERENCE_RATE # these checks count ticks at 60
	var floor_body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(200, 1, 200)
	shape.shape = box
	shape.position.y = -0.5
	floor_body.add_child(shape)
	add_child(floor_body)
	await _test_higher_priority_wins()
	await _test_jitter()
	await _test_combo() # Claude 2026-11-10: was _test_follow_up
	await _test_special()
	print("--- ALL PASSED ---" if _failures == 0 else "--- %d FAILED ---" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)


func _test_higher_priority_wins() -> void:
	var pawn := _pawn_with_markers([1, 5, 3], [0.0, 0.0, 0.0])
	var markers := _markers(pawn)
	await _ticks(5)
	_ai(pawn).press(&"ability_1")
	await _ticks(2)
	_check(markers[1].starts == 1 and markers[0].starts == 0 and markers[2].starts == 0, "three abilities on one action: the press starts the one with the highest priority (5)")
	await _ticks(10)
	markers[1].cooldown = 10.0 # the winner can't start for a while
	markers[1].cooldown_ticks_left = 600
	_ai(pawn).press(&"ability_1")
	await _ticks(2)
	_check(markers[2].starts == 1 and markers[0].starts == 0, "while it can't start, the next highest (3) does")
	pawn.free()


func _test_jitter() -> void:
	# Priorities 0 and 0.4 apart, with jitter of 1 each: either can win on a given press.
	var pawn := _pawn_with_markers([0, 0], [1.0, 1.0])
	var markers := _markers(pawn)
	markers[1].priority = 0
	await _ticks(5)
	for i in 40:
		_ai(pawn).press(&"ability_1")
		await _ticks(9) # each run lasts 6 ticks
	_check(markers[0].starts > 5 and markers[1].starts > 5 and markers[0].starts + markers[1].starts == 40, "with jitter, either can win a press (%d and %d of 40)" % [markers[0].starts, markers[1].starts])
	var first: float = pawn.ability_manager._priority_now(markers[0])
	var again: float = pawn.ability_manager._priority_now(markers[0])
	_check(first == again and first != 0.0, "within one tick, an ability's jittered priority is always the same, so a rollback replay picks the same one (%.3f)" % first)
	var plain := _pawn_with_markers([2], [0.0])
	await _ticks(1)
	_check(plain.ability_manager._priority_now(_markers(plain)[0]) == 2.0, "with no jitter (the default), it's exactly its priority")
	pawn.free()
	plain.free()


## Claude 2026-11-16 (pawn spec 8.20, the owner's design): replaces the combo of boosts. Combos are counted by position, shared by light
## and heavy attacks: an attack's hit opens a window, and the follow-up that fits the next position wins its key.
func _test_combo() -> void:
	var pawn: Pawn = load(PLAYER_SCENE).instantiate()
	pawn.skip_default_parts = NO_AI
	add_child(pawn)
	var manager := pawn.ability_manager
	var swing: MeleeAttackAbility = manager.get_node("MeleeAttack")
	var second: MeleeAttackAbility = manager.get_node("SecondSwing")
	var finisher: MeleeAttackAbility = manager.get_node("FinisherSwing")
	var heavy: MeleeAttackAbility = manager.get_node("HeavyAttack")
	var smash: MeleeAttackAbility = manager.get_node("HeavySmash")
	var ai := _ai(pawn)
	await _ticks(5)
	_check(swing.combo_positions == [1] and second.combo_positions == [2] and finisher.combo_positions == [3] and heavy.combo_positions == [1] and smash.combo_positions == [2, 3],
			"the openers fill position 1, SecondSwing 2, FinisherSwing 3, HeavySmash 2 or 3")
	_check(second.priority > swing.priority and finisher.priority > swing.priority and smash.priority > heavy.priority, "and follow-ups outrank the opener on their key")

	# Swing, second, finisher.
	ai.press(&"primary")
	await _ticks(2)
	_check(swing.is_running_timed() and manager.combo_position == 1 and manager.combo_window_ticks_left == 0, "the attack request starts the swing at position 1, with the window shut")
	await _until(func() -> bool: return swing.swing_phase().phase == "recovery", 60)
	_check(manager.combo_window_ticks_left > 0, "its hit opens the window")
	await _until(func() -> bool: return not swing.is_running_timed(), 60)
	ai.press(&"primary")
	await _ticks(2)
	_check(second.is_running_timed() and manager.combo_position == 2, "pressed again in the window: the second swing, position 2")
	await _until(func() -> bool: return not second.is_running_timed(), 60)
	ai.press(&"primary")
	await _ticks(2)
	_check(finisher.is_running_timed() and manager.combo_position == 3, "and again: the finisher, position 3")
	await _until(func() -> bool: return not finisher.is_running_timed(), 60)

	# Light then heavy: swing, smash, finisher.
	await _until(func() -> bool: return manager.combo_window_ticks_left == 0 and swing.cooldown_ticks_left == 0, 120)
	ai.press(&"primary")
	await _ticks(2)
	_check(swing.is_running_timed() and manager.combo_position == 1, "once the window shuts, an attack starts a new combo at 1")
	await _until(func() -> bool: return not swing.is_running_timed(), 60)
	ai.press(&"secondary")
	await _ticks(2)
	_check(smash.is_running_timed() and manager.combo_position == 2, "mixing: the heavy key in the swing's window gives the smash, at position 2")
	await _until(func() -> bool: return not smash.is_running_timed(), 80)
	ai.press(&"primary")
	await _ticks(2)
	_check(finisher.is_running_timed() and manager.combo_position == 3, "and the light key after it gives the finisher, at 3")
	await _until(func() -> bool: return not finisher.is_running_timed(), 60)

	# Heavy opener: heavy, second, smash.
	await _until(func() -> bool: return manager.combo_window_ticks_left == 0 and heavy.cooldown_ticks_left == 0, 150)
	ai.press(&"secondary")
	await _ticks(2)
	_check(heavy.is_running_timed() and manager.combo_position == 1, "a heavy attack opens a combo too")
	await _until(func() -> bool: return not heavy.is_running_timed(), 80)
	ai.press(&"primary")
	await _ticks(2)
	_check(second.is_running_timed() and manager.combo_position == 2, "the light key after it: the second swing")
	await _until(func() -> bool: return not second.is_running_timed(), 60)
	ai.press(&"secondary")
	await _ticks(2)
	_check(smash.is_running_timed() and manager.combo_position == 3, "and the heavy key: the smash, this time at 3")
	await _until(func() -> bool: return not smash.is_running_timed(), 80)

	# Outside a window, a follow-up can't start.
	await _until(func() -> bool: return manager.combo_window_ticks_left == 0, 60)
	swing.cooldown_ticks_left = 600 # the opener can't start either
	ai.press(&"primary")
	await _ticks(2)
	_check(not swing.is_running_timed() and not second.is_running_timed() and not finisher.is_running_timed(), "outside a window, with the opener cooling down, the attack request starts nothing")
	swing.cooldown_ticks_left = 0

	# Cancelled in its windup: no window.
	ai.press(&"primary")
	await _ticks(2)
	manager.cancel(&"primary")
	_check(not swing.is_running_timed() and manager.combo_window_ticks_left == 0, "a swing cancelled in its windup opens no window")
	swing.cooldown_ticks_left = 0

	# Mashing: a press near the end of the swing can't cancel it (10 against 15), so it waits in the buffer, and the second swing starts
	# as soon as the swing ends, in its window.
	ai.press(&"primary")
	await _ticks(2)
	var recovery: AbilityStep = swing.get_node("Recovery")
	await _until(func() -> bool: return recovery.running and recovery.step_ticks >= recovery.length() - 4, 60)
	ai.press(&"primary")
	await _ticks(2)
	_check(swing.is_running_timed() and not second.is_running_timed(), "a press during the swing doesn't cut it short")
	await _until(func() -> bool: return not swing.is_running_timed(), 60)
	await _ticks(1)
	_check(second.is_running_timed(), "it waits, and the second swing starts when the swing ends")
	pawn.free()


func _test_special() -> void:
	var pawn: Pawn = load(PLAYER_SCENE).instantiate()
	pawn.skip_default_parts = NO_AI
	add_child(pawn)
	var heavy: MeleeAttackAbility = pawn.ability_manager.get_node("HeavyAttack")
	var smash: MeleeAttackAbility = pawn.ability_manager.get_node("HeavySmash")
	await _ticks(5)
	_ai(pawn).press(&"secondary")
	await _ticks(2)
	# Claude 2026-11-16 (pawn spec 8.20, the owner's numbers): a longer windup and reach than before (22 ticks, 2.7 m; were 18, 2.4).
	var recovery: AbilityStep = heavy.get_node("Recovery")
	_check(heavy.is_running_timed() and heavy.windup_length() == 22 and heavy.hit_length() == 5 and recovery.length() == 18 and is_equal_approx(heavy.attack_range, 2.7),
			"the special request starts the heavy attack: 22, 5 and 18 ticks, 2.7 m reach")
	await _until(func() -> bool: return not heavy.is_running_timed(), 80)
	_check(heavy.cooldown_ticks_left > 100 and heavy.cooldown_ticks_left <= 114, "then its cooldown, 1.9 s (%d ticks left)" % heavy.cooldown_ticks_left)
	var feet := pawn.global_position
	_check(smash.attack_range > heavy.attack_range and smash.hit_centre_at(0.0).y - feet.y > smash.hit_centre_at(1.0).y - feet.y + 1.5,
			"the smash reaches further (%.1f m) and comes down from high to low" % smash.attack_range)
	pawn.free()


func _pawn_with_markers(priorities: Array, jitters: Array) -> Pawn:
	var pawn: Pawn = load(PAWN_SCENE).instantiate()
	pawn.skip_default_parts = NO_AI
	var manager: Node = load(ABILITY_PART).instantiate()
	for i in priorities.size():
		var marker := Marker.new()
		marker.name = "Marker%d" % i
		marker.priority = priorities[i]
		marker.priority_jitter = jitters[i]
		manager.add_child(marker)
	pawn.add_child(manager)
	add_child(pawn)
	return pawn


func _markers(pawn: Pawn) -> Array:
	var out := []
	for child in pawn.ability_manager.get_children():
		if child is Marker:
			out.append(child)
	return out


func _ai(pawn: Pawn) -> AIController:
	return pawn.controller_manager.ai_controller as AIController


func _until(condition: Callable, max_ticks: int) -> void:
	for i in max_ticks:
		if condition.call():
			return
		await get_tree().physics_frame


func _ticks(count: int) -> void:
	for i in count:
		await get_tree().physics_frame


func _check(passed: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if passed else "FAIL", what])
	if not passed:
		_failures += 1
