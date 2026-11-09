## Written by Claude (claude-opus-5-5), 2026-11-07: headless self-test for AbilityManager, AbilityBase, Walk, Sprint and Jump. Checks the
## odd cases at the top of AbilityManager.gd, Sprint's duration and cooldown, Jump's buffer and coyote time, lockouts, and that ability
## state rolls back.
## Exits 0 on success, 1 on failure. Run from the project folder:
##   "C:\Git\Test 2\Godot_v4.7.2-stable_win64_console.exe" --headless --path . "res://assets/scripts/abilities/tests/ability_selftest.tscn"
extends Node

const PAWN_SCENE := "res://assets/scenes/pawn/pawn.tscn"

var _failures := 0


## A timed action that roots the pawn: while it runs, nothing in "movement" can start or steer.
class RootingAttack extends AbilityBase:
	var starts := 0
	var stops := 0

	func _init() -> void:
		super()
		kind = Kind.ACTION
		trigger_action = &"primary"
		category = &"combat.melee"
		duration = 0.5
		cooldown = 0.5
		locks_out = [&"movement"]

	func start() -> void:
		starts += 1

	func stop() -> void:
		stops += 1


## An action that can be told not to start, to check what happens to a second ability on the same action.
class SometimesAction extends AbilityBase:
	var allowed := true
	var starts := 0

	func _init() -> void:
		super()
		kind = Kind.ACTION
		trigger_action = &"secondary"
		buffer_window = 0.2

	func can_start() -> bool:
		return allowed

	func start() -> void:
		starts += 1


## Claude 2026-11-09: overrides every_tick(), to check the manager finds overrides in scripts like this one and calls only those.
class EveryTickCounter extends AbilityBase:
	var calls := 0

	func every_tick(_dt: float) -> void:
		calls += 1

	# It always has something to do, so the pawn never rests while it's there (pawn spec 15.3).
	func can_rest() -> bool:
		return false


func _ready() -> void:
	print("--- Ability self-test ---")
	await _test_rollback_registration()
	await _test_sprint()
	await _test_jump_buffer()
	await _test_coyote_time()
	await _test_lockouts()
	await _test_one_press_one_ability()
	await _test_no_stats()
	await _test_rollback_restores_ability_state()
	await _test_gates() # Claude 2026-11-09
	_test_odd_setups()
	print("--- ALL PASSED ---" if _failures == 0 else "--- %d FAILED ---" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)


func _test_rollback_registration() -> void:
	var pawn := _make_pawn()
	await _ticks(3) # so at least one tick has been recorded
	var listed: Array[String] = (pawn.get_node("TickState") as TickStateComponent).state_properties
	_check(listed.has("AbilityManager/Sprint:ticks_left") and listed.has("AbilityManager/Sprint:cooldown_ticks_left"), "Sprint's time left and cooldown roll back")
	_check(listed.has("AbilityManager/Jump:buffer_ticks_left") and listed.has("AbilityManager/Jump:ticks_off_ground"), "and Jump's waiting press and time off the ground")
	var walk_entries := listed.filter(func(entry: String) -> bool: return entry.begins_with("AbilityManager/Walk"))
	_check(walk_entries.is_empty(), "Walk keeps nothing between ticks, so it adds nothing")
	print("  (a warning about adding state entries too late is expected next)")
	_check(not (pawn.get_node("TickState") as TickStateComponent).add_state_properties(["late:entry"]), "entries can't be added once ticks are recorded")
	pawn.free()


func _test_sprint() -> void:
	var floor_body := _make_floor(400.0)
	var pawn := _make_pawn(Vector3(0, 0.1, 0))
	var sprint: SprintAbility = pawn.ability_manager.get_node("Sprint")
	sprint.duration = 0.5 # 30 ticks, to keep the test short
	sprint.cooldown = 0.5
	var ai := _ai(pawn)
	await _ticks(20)
	ai.move_in_direction(Vector3(1, 0, 0))
	ai.hold(&"sprint")
	await _ticks(20)
	_check(sprint.is_running_timed() and pawn.velocity.x > 5.5, "holding sprint runs Sprint instead of Walk (%.2f m/s)" % pawn.velocity.x)
	await _ticks(15)
	_check(not sprint.is_running_timed() and sprint.cooldown_ticks_left > 0, "its time runs out, and its cooldown starts, though the key is still held")
	_check(not pawn.ability_manager.can_start(&"sprint"), "so it can't start again yet")
	await _ticks(20) # tick 55: its cooldown ends at tick 60
	_check(absf(pawn.velocity.x - 5.0) < 0.05, "and Walk takes over (%.2f m/s)" % pawn.velocity.x)
	await _ticks(10)
	_check(sprint.is_running_timed(), "once the cooldown is over, the held key starts it again")
	ai.hold(&"sprint", false)
	await _ticks(1)
	_check(not sprint.is_running_timed() and sprint.cooldown_ticks_left > 0, "letting go stops it early, and starts the cooldown")
	pawn.free()
	floor_body.free()


func _test_jump_buffer() -> void:
	var floor_body := _make_floor(40.0)
	var pawn := _make_pawn(Vector3(0, 0.1, 0))
	var ai := _ai(pawn)
	await _ticks(20)
	ai.press(&"jump")
	await _ticks(1)
	_check(pawn.velocity.y > 0.0, "a press on the ground jumps")
	await _ticks(54) # about 7 ticks before landing, which is about 62 ticks after the jump
	ai.press(&"jump")
	_check(await _jumps_again_within(pawn, 20), "pressed just before landing, it jumps on landing (the press waited)")
	await _until_grounded(pawn)
	await _ticks(5)
	ai.press(&"jump")
	await _ticks(25) # near the top of the jump
	ai.press(&"jump")
	_check(not await _jumps_again_within(pawn, 60), "pressed too early, the press is gone before landing")
	pawn.free()
	floor_body.free()


func _test_coyote_time() -> void:
	for late_ticks: int in [2, 20]:
		var floor_body := _make_floor(10.0)
		var pawn := _make_pawn(Vector3(3.5, 0.1, 0))
		var ai := _ai(pawn)
		await _ticks(20)
		ai.move_in_direction(Vector3(1, 0, 0))
		var left_ground := false
		for i in 120:
			await _ticks(1)
			if not pawn.grounded:
				left_ground = true
				break
		await _ticks(late_ticks - 1)
		ai.press(&"jump")
		await _ticks(1)
		if late_ticks == 2:
			_check(left_ground and pawn.velocity.y > 0.0, "just after walking off an edge, a press still jumps")
		else:
			_check(left_ground and pawn.velocity.y < 0.0, "long after, it doesn't")
		pawn.free()
		floor_body.free()


func _test_lockouts() -> void:
	var floor_body := _make_floor(400.0)
	var pawn: Pawn = load(PAWN_SCENE).instantiate()
	pawn.position = Vector3(0, 0.1, 0)
	var manager := AbilityManager.new()
	manager.name = "AbilityManager" # the same name as the default, so PawnInitializer leaves this one alone
	var walk := WalkAbility.new()
	walk.name = "Walk"
	manager.add_child(walk)
	var jump := JumpAbility.new()
	jump.name = "Jump"
	manager.add_child(jump)
	var attack := RootingAttack.new()
	attack.name = "Attack"
	manager.add_child(attack)
	pawn.add_child(manager)
	add_child(pawn)
	var ai := _ai(pawn)
	await _ticks(20)
	ai.move_in_direction(Vector3(1, 0, 0))
	await _ticks(30)
	_check(pawn.velocity.x > 4.9, "(walking at full speed)")
	ai.press(&"primary")
	await _ticks(1)
	_check(attack.is_running_timed() and attack.starts == 1 and manager.is_busy(), "a press starts a timed action, and the manager is busy")
	ai.press(&"jump")
	await _ticks(20)
	_check(pawn.velocity.x < 0.5, "it locks out movement: Walk stops steering and the pawn slows to a stop (%.2f m/s)" % pawn.velocity.x)
	_check(pawn.grounded, "and Jump, which is movement too, couldn't start")
	await _ticks(15)
	_check(not attack.is_running_timed() and attack.stops == 1 and not manager.is_busy(), "after its duration it stops")
	await _ticks(20)
	_check(pawn.velocity.x > 2.0, "and walking comes back")
	await _ticks(15) # past its 30-tick cooldown
	ai.press(&"primary")
	await _ticks(1)
	_check(attack.starts == 2 and attack.is_running_timed(), "after its cooldown it can start again")
	manager.cancel(&"primary")
	_check(not attack.is_running_timed() and attack.stops == 2 and attack.cooldown_ticks_left > 0, "cancel() stops it and starts its cooldown")
	_check(manager.has_action(&"primary") and not manager.has_action(&"interact"), "has_action() knows which actions it answers to")
	pawn.free()
	floor_body.free()


func _test_one_press_one_ability() -> void:
	var pawn: Pawn = load(PAWN_SCENE).instantiate()
	var manager := AbilityManager.new()
	manager.name = "AbilityManager"
	var first := SometimesAction.new()
	first.name = "First"
	first.allowed = false
	manager.add_child(first)
	var second := SometimesAction.new()
	second.name = "Second"
	second.priority = 1
	manager.add_child(second)
	pawn.add_child(manager)
	add_child(pawn)
	var ai := _ai(pawn)
	await _ticks(5)
	ai.press(&"secondary")
	await _ticks(1)
	_check(first.starts == 0 and second.starts == 1, "two abilities on one action: the first that can start does")
	first.allowed = true
	await _ticks(3)
	_check(first.starts == 0, "and the other doesn't keep that press waiting")
	_check(manager.can_start(&"secondary"), "can_start() tells whether a press would start something")
	pawn.free()


func _test_no_stats() -> void:
	var floor_body := _make_floor(400.0)
	var pawn := _make_pawn(Vector3(0, 0.1, 0), [&"StatManager"])
	var ai := _ai(pawn)
	await _ticks(20)
	ai.move_in_direction(Vector3(1, 0, 0))
	await _ticks(40)
	_check(pawn.stat_manager == null and absf(pawn.velocity.x - 5.0) < 0.05, "with no StatManager, Walk uses its fallback speed (%.2f m/s)" % pawn.velocity.x)
	pawn.free()
	floor_body.free()


func _test_rollback_restores_ability_state() -> void:
	var floor_body := _make_floor(400.0)
	var pawn := _make_pawn(Vector3(0, 0.1, 0))
	var sprint: SprintAbility = pawn.ability_manager.get_node("Sprint")
	var ai := _ai(pawn)
	await _ticks(20)
	ai.move_in_direction(Vector3(1, 0, 0))
	ai.hold(&"sprint")
	await _ticks(30)
	await get_tree().physics_frame
	var real_ticks_left := sprint.ticks_left
	var real_position := pawn.position
	var went_back: bool = TickDriver.rollback(TickDriver.tick - 12)
	_check(went_back and sprint.ticks_left == real_ticks_left, "a replay ends with Sprint's time left exactly as it was (%d ticks)" % sprint.ticks_left)
	_check(pawn.position.distance_to(real_position) < 0.0011, "and the pawn in the same place")
	pawn.free()
	floor_body.free()


## Claude 2026-11-09 (pawn spec 15.2): the manager only runs what has a reason to: every_tick() only where a script overrides it, the
## counters of running timers (including one written from outside, as a rollback does), and Walk reads its stats again when one changes.
func _test_gates() -> void:
	var floor_body := _make_floor(400.0)
	var pawn: Pawn = load(PAWN_SCENE).instantiate()
	pawn.position = Vector3(0, 0.1, 0)
	var manager: AbilityManager = load("res://assets/scenes/pawn/parts/AbilityManager.tscn").instantiate()
	var counter := EveryTickCounter.new()
	counter.name = "Counter"
	manager.add_child(counter)
	pawn.add_child(manager)
	add_child(pawn)
	await _ticks(20)
	var calls_before := counter.calls
	await _ticks(10)
	var with_every_tick: Array = manager._every_tick_abilities.map(func(a): return String(a.name))
	_check(counter.calls - calls_before == 10 and with_every_tick.has("Counter") and with_every_tick.has("Jump") and not with_every_tick.has("Walk"), "every_tick() runs only on abilities that override it, every tick (%s)" % str(with_every_tick))
	var sprint: SprintAbility = manager.get_node("Sprint")
	sprint.cooldown_ticks_left = 30 # as a rollback loading saved values would
	await _ticks(10)
	_check(sprint.cooldown_ticks_left == 20, "a timer written from outside starts counting down at once (%d left after 10 ticks)" % sprint.cooldown_ticks_left)
	var ai := _ai(pawn)
	ai.move_in_direction(Vector3(1, 0, 0))
	await _ticks(40)
	var normal_speed := pawn.velocity.x
	(pawn.stat_manager.get_stat(&"MoveSpeed") as Stat).value = 2.0
	await _ticks(40)
	_check(absf(normal_speed - 5.0) < 0.05 and absf(pawn.velocity.x - 2.0) < 0.05, "Walk keeps its stats, and picks up a changed one (%.2f, then %.2f m/s)" % [normal_speed, pawn.velocity.x])
	pawn.free()
	floor_body.free()


func _test_odd_setups() -> void:
	var loose := AbilityManager.new()
	print("  (a warning about an AbilityManager outside a pawn is expected next)")
	add_child(loose)
	loose.tick_abilities(1.0 / 60.0) # does nothing, and nothing breaks
	_check(loose.pawn == null and not loose.is_busy(), "outside a pawn, it does nothing")
	loose.free()


# --- Helpers ---


func _jumps_again_within(pawn: Pawn, ticks: int) -> bool:
	var landed := false
	for i in ticks:
		await _ticks(1)
		if pawn.grounded:
			landed = true
		elif landed and pawn.velocity.y > 0.0:
			return true
	return false


func _until_grounded(pawn: Pawn) -> void:
	for i in 200:
		if pawn.grounded:
			return
		await _ticks(1)


func _ai(pawn: Pawn) -> AIController:
	return pawn.controller_manager.ai_controller as AIController


func _make_pawn(at := Vector3.ZERO, skip: Array[StringName] = []) -> Pawn:
	var pawn: Pawn = load(PAWN_SCENE).instantiate()
	pawn.position = at
	pawn.skip_default_parts = skip
	add_child(pawn)
	return pawn


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
