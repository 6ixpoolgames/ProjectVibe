## Written by Claude (claude-opus-5-5), 2026-11-09: headless self-test for presses as requests: when several abilities answer one
## action, the highest priority that can start wins (it was the lowest), priority_jitter varies the choice from tick to tick but never
## within one tick, and the faction arena's attacks: the attack request gives the normal swing, then a follow-up while that cools
## down, and the special request gives the heavy attack.
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
	await _test_follow_up()
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


## Attack, then attack again quickly: the follow-up. Then nothing until the normal swing's cooldown is over.
func _test_follow_up() -> void:
	var pawn: Pawn = load(PLAYER_SCENE).instantiate()
	pawn.skip_default_parts = NO_AI
	add_child(pawn)
	var normal: MeleeAttackAbility = pawn.ability_manager.get_node("MeleeAttack")
	var follow: FollowUpAttackAbility = pawn.ability_manager.get_node("FollowUpAttack")
	normal.cooldown = 0.8 # as in the arena: 48 ticks (Claude 2026-11-10: was 1.5, the arena's old value)
	await _ticks(5)
	_check(follow.priority < normal.priority and follow.trigger_action == normal.trigger_action and normal.priority_jitter == 0.0 and follow.priority_jitter == 0.0, "the follow-up answers the same request with a lower priority, and neither has jitter")
	_ai(pawn).press(&"primary")
	await _ticks(2)
	_check(normal.is_running_timed() and not follow.is_running_timed(), "the attack request starts the normal swing")
	await _until(func() -> bool: return not normal.is_running_timed(), 60)
	_ai(pawn).press(&"primary")
	await _ticks(2)
	_check(follow.is_running_timed(), "pressed again while it cools down, within the window: the follow-up")
	await _until(func() -> bool: return not follow.is_running_timed(), 60)
	_ai(pawn).press(&"primary")
	await _ticks(2)
	_check(not normal.is_running_timed() and not follow.is_running_timed(), "and again: nothing, one follow-up per swing, and the normal one still cooling down")
	await _until(func() -> bool: return normal.cooldown_ticks_left == 0, 120)
	_ai(pawn).press(&"primary")
	await _ticks(2)
	_check(normal.is_running_timed(), "once its cooldown is over, the normal swing again")
	await _until(func() -> bool: return not normal.is_running_timed(), 60)
	await _ticks(int(follow.follow_window * 60) + 5)
	_ai(pawn).press(&"primary")
	await _ticks(2)
	_check(not follow.is_running_timed(), "a press after the window has closed: no follow-up")
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
