## Written by Claude (claude-opus-5-5), 2026-11-16: headless self-test for pawns that run every 2nd or 4th tick (pawn spec 8.21, scaling
## spec 7.1): a pawn at step 4 runs a quarter as often yet walks as far, its ability lasts as long, an effect over time does the same
## total, its swing still hits, the AI's schedules still fire, and a rollback replays it exactly; the AIActivationManager picks steps by
## distance from the viewers, keeps a player's pawn at every tick, and follows the load ladder; and TickDriver's ladder steps up under
## load, down when there's room, and can be forced.
## Exits 0 on success, 1 on failure. Run from the project folder:
##   godot --headless --path . "res://assets/scripts/pawn/tests/tick_step_selftest.tscn"
extends SelfTest # Claude 2026-11-16 (wider audit): _check and _failures come from tests/SelfTest.gd now

const PAWN_SCENE := "res://assets/scenes/pawn/pawn.tscn"
const NO_AI: Array[StringName] = [&"AISensingManager", &"AIMemory", &"AITargetSelector", &"AIStateManager", &"AIBehaviourManager"]

var _activation: AIActivationManager = null


## A test action on ability_1: runs half a second, then cools down half a second.
class HalfSecond extends AbilityBase:
	func _init() -> void:
		super()
		kind = Kind.ACTION
		self.trigger_action = &"ability_1"
		self.duration_ticks = 30
		self.cooldown_ticks = 30


func _ready() -> void:
	TickDriver.tick_rate = TickDriver.REFERENCE_RATE # these count ticks at 60
	TickDriver.load_step_override = 1 # nothing here should depend on how loaded this machine is
	print("--- Tick step self-test ---")
	var floor_body := _make_floor()
	# The pawn checks set tick_step by hand, so the AIActivationManager, which would set it too, pauses its checks until its own test.
	_activation = GameMode.ai_activation_manager
	# Claude 2026-11-23: its checks run before each tick now, so pausing it means leaving the tick driver's before_tick.
	TickDriver.before_tick.disconnect(_activation._on_before_tick)
	await _test_walking()
	await _test_spread()
	await _test_ability_timing()
	await _test_effect_over_time()
	await _test_swing()
	_test_schedules()
	await _test_rollback()
	TickDriver.before_tick.connect(_activation._on_before_tick)
	await _test_steps_by_distance()
	_test_load_ladder()
	TickDriver.load_step_override = 0
	floor_body.free()
	print("--- ALL PASSED ---" if _failures == 0 else "--- %d FAILED ---" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)


func _test_walking() -> void:
	var every := _pawn(Vector3(0, 0.1, 0), 1)
	var fourth := _pawn(Vector3(0, 0.1, 10), 4)
	await _ticks(20)
	_set_steps([every, fourth], [1, 4])
	await _ticks(4)
	var runs := [0]
	var last_run := [fourth._last_run_tick]
	var start_every := every.global_position
	var start_fourth := fourth.global_position
	_ai(every).move_in_direction(Vector3(1, 0, 0))
	_ai(fourth).move_in_direction(Vector3(1, 0, 0))
	for i in 120:
		await get_tree().physics_frame
		if fourth._last_run_tick != last_run[0]:
			runs[0] += 1
			last_run[0] = fourth._last_run_tick
	var walked_every := every.global_position.distance_to(start_every)
	var walked_fourth := fourth.global_position.distance_to(start_fourth)
	_check(runs[0] >= 29 and runs[0] <= 31, "a pawn at step 4 runs every 4th tick (%d runs in 120 ticks)" % runs[0])
	_check(walked_every > 5.0 and absf(walked_fourth - walked_every) < walked_every * 0.06,
			"and walks as far as one running every tick (%.2f m against %.2f m)" % [walked_fourth, walked_every])
	_check(fourth.ticks_elapsed == 4 and every.ticks_elapsed == 1, "each run covers its step's ticks (ticks_elapsed %d and %d)" % [fourth.ticks_elapsed, every.ticks_elapsed])
	every.free()
	fourth.free()


func _test_spread() -> void:
	var pawns: Array[Pawn] = []
	for i in 8:
		pawns.append(_pawn(Vector3(20 + i * 2, 0.1, 0), 4))
	await _ticks(10)
	for pawn in pawns:
		pawn.tick_step = 4
	await _ticks(4)
	var runs_by_tick := {}
	for i in 8:
		await get_tree().physics_frame
		var now := TickDriver.tick
		for pawn in pawns:
			if pawn._last_run_tick == now:
				runs_by_tick[now] = runs_by_tick.get(now, 0) + 1
	var busiest := 0
	for tick: int in runs_by_tick:
		busiest = maxi(busiest, runs_by_tick[tick])
	_check(runs_by_tick.size() >= 2 and busiest < 8, "a crowd at step 4 doesn't all run on the same tick (the most on one tick: %d of 8)" % busiest)
	for pawn in pawns:
		pawn.free()


func _test_ability_timing() -> void:
	var lengths := {}
	var cooldowns := {}
	for step in [1, 4]:
		var pawn := _pawn(Vector3(40, 0.1, step * 5), step, [HalfSecond.new()])
		var ability: AbilityBase = pawn.ability_manager.get_node("HalfSecond")
		await _ticks(10)
		pawn.tick_step = step
		await _ticks(4)
		_ai(pawn).press(&"ability_1")
		await _until(func() -> bool: return ability.is_running_timed(), 10)
		var started := TickDriver.tick
		await _until(func() -> bool: return not ability.is_running_timed(), 60)
		lengths[step] = TickDriver.tick - started
		var ended := TickDriver.tick
		await _until(func() -> bool: return ability.cooldown_ticks_left() <= 0, 60)
		cooldowns[step] = TickDriver.tick - ended
		pawn.free()
	_check(absi(lengths[4] - lengths[1]) <= 4 and absi(lengths[1] - 30) <= 1, "a half-second ability lasts as long at step 4 (%d ticks, %d at step 1)" % [lengths[4], lengths[1]])
	_check(absi(cooldowns[4] - cooldowns[1]) <= 4, "and so does its cooldown (%d ticks, %d at step 1)" % [cooldowns[4], cooldowns[1]])


func _test_effect_over_time() -> void:
	var poison := Effect.new()
	poison.effect_name = &"test poison"
	poison.duration_ticks = 60
	poison.period_ticks = 15
	var part := StatChangePart.new()
	part.stat = &"Health"
	part.amount = -5.0
	poison.parts = [part]
	var lost := {}
	for step in [1, 4]:
		var pawn := _pawn(Vector3(60, 0.1, step * 5), step)
		await _ticks(5)
		pawn.tick_step = step
		await _ticks(4)
		var before := pawn.stat_manager.get_health()
		pawn.effect_manager.apply_effect(poison)
		await _ticks(90)
		lost[step] = before - pawn.stat_manager.get_health()
		pawn.free()
	_check(lost[1] > 0.0 and is_equal_approx(lost[4], lost[1]), "an effect over time does the same total at step 4 (%.0f Health, %.0f at step 1)" % [lost[4], lost[1]])


func _test_swing() -> void:
	var attacker := _pawn(Vector3(80, 0.1, 0), 2)
	var target := _pawn(Vector3(80, 0.1, -1.6), 1)
	target.team = 1
	await _ticks(10)
	attacker.tick_step = 2
	await _ticks(2)
	var ai := _ai(attacker)
	ai.look_at_point(target.global_position + Vector3(0, 1, 0))
	await _ticks(4)
	var before := target.stat_manager.get_health()
	ai.hold(&"primary", true)
	var melee: MeleeAttackAbility = attacker.ability_manager.get_node("MeleeAttack")
	await _until(func() -> bool: return melee.is_running_timed(), 10)
	await _until(func() -> bool: return not melee.is_running_timed(), 80)
	ai.hold(&"primary", false)
	_check(target.stat_manager.get_health() < before, "a swing from a pawn at step 2 still sweeps through its target and hits (%.0f to %.0f)" % [before, target.stat_manager.get_health()])
	attacker.free()
	target.free()


func _test_schedules() -> void:
	var pawn: Pawn = load(PAWN_SCENE).instantiate()
	pawn.ticks_elapsed = 4
	var fired := 0
	for tick in range(4, 124, 4): # a pawn running every 4th tick, for 120 ticks
		if pawn.fired_since_last_run(tick, 7, 15):
			fired += 1
	pawn.ticks_elapsed = 1
	var every := 0
	for tick in range(1, 121):
		if pawn.fired_since_last_run(tick, 7, 15):
			every += 1
	_check(fired == 8 and every == 8, "an every-15-ticks rule fires as often for a pawn at step 4 as at step 1 (%d and %d times in 120 ticks)" % [fired, every])
	pawn.free()


func _test_rollback() -> void:
	var pawn := _pawn(Vector3(100, 0.1, 0), 4)
	await _ticks(20)
	pawn.tick_step = 4
	_ai(pawn).move_in_direction(Vector3(0, 0, 1))
	await _ticks(30)
	await get_tree().physics_frame
	var listed: Array[String] = (pawn.get_node("TickState") as TickStateComponent).state_properties
	_check(listed.has("tick_step pushed") and listed.has("_last_run_tick"), "how often a pawn runs, and when it last did, roll back")
	var real := [pawn.global_position, pawn._last_run_tick, pawn.tick_step]
	var went_back: bool = TickDriver.rollback(TickDriver.tick - 9)
	var after := [pawn.global_position, pawn._last_run_tick, pawn.tick_step]
	_check(went_back and after[0].distance_to(real[0]) < 0.002 and after[1] == real[1] and after[2] == real[2],
			"a replay runs it on the same ticks and ends in the same place (%s, was %s)" % [str(after), str(real)])
	pawn.free()


func _test_steps_by_distance() -> void:
	var chunk := 64.0 # no terrain here, so the default chunk size
	var player := _pawn(Vector3(0, 0.1, 200), 1)
	var near := _pawn(Vector3(chunk * 1.0, 0.1, 200), 1)
	var middle := _pawn(Vector3(chunk * 3.0, 0.1, 200), 1)
	var far := _pawn(Vector3(chunk * 6.0, 0.1, 200), 1)
	await _ticks(5)
	var coordinator: PossessionCoordinator = GameMode.possession_coordinator
	_settle_steps()
	_check(near.tick_step == 1 and middle.tick_step == 1 and far.tick_step == 1, "with no viewer at all, distance changes nothing: every tick")
	coordinator.possess(player)
	await _ticks(2)
	_settle_steps()
	_check(player.tick_step == 1 and near.tick_step == 1 and middle.tick_step == 2 and far.tick_step == 4,
			"with a player: every tick within 2 chunks, every 2nd up to 4, every 4th beyond (%d, %d, %d)" % [near.tick_step, middle.tick_step, far.tick_step])
	var counts := _activation.get_step_counts()
	_check(counts.get(1, 0) >= 2 and counts.get(2, 0) >= 1 and counts.get(4, 0) >= 1, "get_step_counts says how many run at each step (%s)" % str(counts))
	coordinator.possess(far)
	await _ticks(2)
	_check(far.tick_step == 1, "a pawn a player takes runs every tick at once, however far it was")
	coordinator.possess(player)
	TickDriver.load_step_override = 2
	await get_tree().physics_frame # the driver takes the override on its next tick
	_settle_steps()
	_check(near.tick_step == 2 and middle.tick_step == 2 and far.tick_step == 4 and player.tick_step == 1,
			"under load step 2, every AI pawn runs at most every 2nd tick, and the player's pawn still every tick")
	TickDriver.load_step_override = 1
	await get_tree().physics_frame
	coordinator.release()
	for pawn in [player, near, middle, far]:
		pawn.free()


func _test_load_ladder() -> void:
	var driver := TickDriverSingleton.new()
	driver.active = false
	driver.tick_rate = 60
	add_child(driver)
	var heard: Array[int] = []
	driver.load_step_changed.connect(func(step: int) -> void: heard.append(step))
	var budget := int(1000000.0 / 60.0)
	var dt := 1.0 / 60.0
	# The average takes about 22 ticks to climb over 85 percent from nothing, then 30 more in a row step it up.
	for i in 60:
		driver._note_tick_cost(int(budget * 0.95), dt)
	_check(driver.load_step == 2, "ticks using 95 percent of their budget for a second: the ladder steps up to 2 (%d)" % driver.load_step)
	for i in 35:
		driver._note_tick_cost(int(budget * 0.95), dt)
	_check(driver.load_step == 4, "still overloaded: 4 (%d)" % driver.load_step)
	for i in 100:
		driver._note_tick_cost(int(budget * 0.6), dt)
	_check(driver.load_step == 4, "at 60%, neither over nor well under: it stays")
	for i in 200:
		driver._note_tick_cost(int(budget * 0.2), dt)
	_check(driver.load_step == 2, "at 20% for three seconds: back down to 2")
	for i in 200:
		driver._note_tick_cost(int(budget * 0.2), dt)
	_check(driver.load_step == 1 and heard == [2, 4, 2, 1], "and then to 1, saying each change (%s)" % str(heard))
	driver.load_step_override = 4
	driver._note_tick_cost(0, dt)
	_check(driver.load_step == 4, "load_step_override forces a step, however light the ticks")
	driver.load_step_override = 0
	driver.load_ladder_enabled = false
	driver._note_tick_cost(int(budget * 3.0), dt)
	_check(driver.load_step == 1, "with the ladder off, it stays at 1")
	driver.free()
	# Claude 2026-11-16 (the owner's question: why doesn't it step back down?): the ladder predicts the lower step from what stepping up
	# saved. A step up that saved little (95% to 80%) steps back down at 50%, which the 40% line alone never allowed; one that saved a
	# lot (95% to 45%) stays up at 50%, since stepping down would put it back near 95%.
	for saved_little: bool in [true, false]:
		var ladder := TickDriverSingleton.new()
		ladder.active = false
		ladder.tick_rate = 60
		add_child(ladder)
		for i in 60:
			ladder._note_tick_cost(int(budget * 0.95), dt)
		for i in 40:
			ladder._note_tick_cost(int(budget * (0.8 if saved_little else 0.45)), dt)
		for i in 250:
			ladder._note_tick_cost(int(budget * 0.5), dt)
		if saved_little:
			_check(ladder.load_step == 1, "a step up that saved little (95% to 80%) steps back down at 50%% (%d, saving %.2f)" % [ladder.load_step, float(ladder._saving_at.get(2, -1.0))])
		else:
			_check(ladder.load_step == 2, "one that saved a lot (95% to 45%) stays up at 50%% (%d, saving %.2f)" % [ladder.load_step, float(ladder._saving_at.get(2, -1.0))])
		ladder.free()
	_test_ladder_tries_lower_step(budget, dt)


# Claude 2026-11-24 (the owner: the mass battle stayed at step 2 after spawning, at 50% load, though step 1 fit at about 66%): a saving
# measured while a spawn burst ended predicts too much. After probe_after_ticks of comfortable load the ladder tries the lower step;
# one that doesn't fit steps up again and the next try waits twice as long.
func _test_ladder_tries_lower_step(budget: int, dt: float) -> void:
	var ladder := TickDriverSingleton.new()
	ladder.active = false
	ladder.tick_rate = 60
	add_child(ladder)
	var run_load := func(share: float, ticks: int) -> void:
		for i in ticks:
			ladder._note_tick_cost(int(budget * share), dt)
	run_load.call(0.95, 60) # a spawn burst steps it up...
	run_load.call(0.45, 40) # ...and ends as the step lands, so the saving looks huge
	run_load.call(0.5, 300)
	_check(ladder.load_step == 2, "at 50%% with a saving that predicts step 1 won't fit, it stays at 2 for now (%d)" % ladder.load_step)
	run_load.call(0.5, 300) # 600 comfortable ticks in all
	_check(ladder.load_step == 1, "after 10 s comfortably loaded it tries step 1 (%d)" % ladder.load_step)
	run_load.call(0.66, 700)
	_check(ladder.load_step == 1, "step 1 fits at 66%%, so it stays there (%d)" % ladder.load_step)
	# A try that doesn't fit: overloaded at step 1, it steps up again, and waits twice as long before the next try.
	run_load.call(0.95, 60)
	run_load.call(0.45, 40)
	run_load.call(0.5, 600)
	_check(ladder.load_step == 1, "the next comfortable 10 s try step 1 again (%d)" % ladder.load_step)
	run_load.call(0.95, 60)
	_check(ladder.load_step == 2, "where it's overloaded, so it steps back up (%d)" % ladder.load_step)
	run_load.call(0.5, 700)
	_check(ladder.load_step == 2, "and doesn't try again after only 10 s (%d)" % ladder.load_step)
	run_load.call(0.5, 600)
	_check(ladder.load_step == 1, "but does after 20 s (%d)" % ladder.load_step)
	ladder.probe_after_ticks = 0
	run_load.call(0.95, 60)
	run_load.call(0.45, 40)
	run_load.call(0.5, 3000)
	_check(ladder.load_step == 2, "probe_after_ticks 0: it never tries (%d)" % ladder.load_step)
	ladder.free()


# --- Helpers ---


func _set_steps(pawns: Array, steps: Array) -> void:
	for i in pawns.size():
		pawns[i].tick_step = steps[i]


# Has the AIActivationManager look at every pawn now, rather than over its next frames.
func _settle_steps() -> void:
	_activation._find_viewers()
	for pawn: Node3D in _activation._pawns:
		if is_instance_valid(pawn):
			_activation._check_pawn(pawn)


func _pawn(at: Vector3, step: int, extra: Array = []) -> Pawn:
	var pawn: Pawn = load(PAWN_SCENE).instantiate()
	pawn.skip_default_parts = NO_AI
	pawn.position = at
	pawn.tick_step = step
	if not extra.is_empty():
		var manager: Node = load("res://assets/scenes/pawn/parts/AbilityManager.tscn").instantiate()
		manager.name = "AbilityManager"
		for ability: AbilityBase in extra:
			ability.name = ability.get_script().get_global_name() if ability.get_script().get_global_name() != "" else "HalfSecond"
			manager.add_child(ability)
		pawn.add_child(manager)
	add_child(pawn)
	return pawn


func _ai(pawn: Pawn) -> AIController:
	return pawn.controller_manager.ai_controller as AIController


func _make_floor() -> StaticBody3D:
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(1000, 1, 1000)
	shape.shape = box
	shape.position.y = -0.5
	body.add_child(shape)
	add_child(body)
	return body


func _until(condition: Callable, max_ticks: int) -> void:
	for i in max_ticks:
		if condition.call():
			return
		await get_tree().physics_frame


func _ticks(count: int) -> void:
	for i in count:
		await get_tree().physics_frame
