## Written by Claude (claude-opus-5-5), 2026-11-09: headless self-test for presses as requests: when several abilities answer one
## action, the highest priority that can start wins (it was the lowest), priority_jitter varies the choice from tick to tick but never
## within one tick, and the faction arena's attacks: the attack request gives the normal swing, then a follow-up while that cools
## down, and the special request gives the heavy attack. Claude 2026-11-10: the follow-up is now a combo made of boosts (_test_combo).
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


## Claude 2026-11-10 (pawn spec 8.11): replaces the follow-up test. The faction arena's combo, made of boosts: pressing again quickly
## gives swing, second, finisher; pressing slowly gives swing, swing.
func _test_combo() -> void:
	var pawn: Pawn = load(PLAYER_SCENE).instantiate()
	pawn.skip_default_parts = NO_AI
	add_child(pawn)
	var manager := pawn.ability_manager
	var swing: MeleeAttackAbility = manager.get_node("MeleeAttack")
	var second: MeleeAttackAbility = manager.get_node("SecondSwing")
	var finisher: MeleeAttackAbility = manager.get_node("FinisherSwing")
	await _ticks(5)
	_check(swing.trigger_action == second.trigger_action and second.trigger_action == finisher.trigger_action and swing.priority == 10 and second.priority == 0 and finisher.priority == -10, "three swings answer the attack request, at priorities 10, 0 and -10")
	_ai(pawn).press(&"primary")
	await _ticks(2)
	_check(swing.is_running_timed() and manager.press_priority_now(second) == 20, "the request starts the swing, which boosts the second swing to 20 for a moment (%d)" % manager.press_priority_now(second))
	await _until(func() -> bool: return not swing.is_running_timed(), 60)
	_ai(pawn).press(&"primary")
	await _ticks(2)
	_check(second.is_running_timed() and manager.press_priority_now(finisher) == 30, "pressed again quickly: the second swing, which boosts the finisher to 30 (%d)" % manager.press_priority_now(finisher))
	await _until(func() -> bool: return not second.is_running_timed(), 60)
	_ai(pawn).press(&"primary")
	await _ticks(2)
	_check(finisher.is_running_timed(), "and again: the finisher")
	await _until(func() -> bool: return not finisher.is_running_timed(), 60)
	await _ticks(40) # past every boost
	_check(manager.press_priority_now(second) == 0 and manager.press_priority_now(finisher) == -10 and pawn.effect_manager.get_active_effects().is_empty(), "the boosts end at their deadline: back to 0 and -10, nothing left on the pawn")
	_ai(pawn).press(&"primary")
	await _ticks(2)
	_check(swing.is_running_timed(), "a press after that: the swing again")
	await _until(func() -> bool: return not swing.is_running_timed(), 60)
	await _ticks(40)
	_ai(pawn).press(&"primary")
	await _ticks(2)
	_check(swing.is_running_timed(), "pressing slowly: swing, swing")
	# Mashing: a press near the end of the swing can't cancel it (10 against 15), so it waits in the buffer and the second starts
	# as soon as the swing ends.
	await _until(func() -> bool: return swing.ticks_left <= 4, 60)
	_ai(pawn).press(&"primary")
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
	await _ticks(5)
	_ai(pawn).press(&"secondary")
	await _ticks(2)
	_check(heavy.is_running_timed() and heavy.duration_ticks() == 41, "the special request starts the heavy attack (41 ticks: 18, 5 and 18)")
	await _until(func() -> bool: return not heavy.is_running_timed(), 80)
	_check(heavy.cooldown_ticks_left > 300, "then a long cooldown (6 s)")
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
