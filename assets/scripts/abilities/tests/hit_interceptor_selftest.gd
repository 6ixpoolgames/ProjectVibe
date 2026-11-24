## Written by Claude (claude-opus-5-5), 2026-11-17 (pawn spec 8.23): HitInterceptor's rules, on plain pawns:
##   - an interceptor is on only while its ability (or step) runs, and only for active_seconds when that's set
##   - the first active TURN_AWAY interceptor that stops a hit ends it: none of its effects land, hit_intercepted goes out, and the
##     interceptor's ON_INTERCEPT effects go back to the attacker in a hit of their own, which can't be turned away in its turn
##   - interceptors are asked from the highest priority down
##   - a MISS interceptor means the hit never arrives: no hit_arrived, so the AI doesn't notice
##   - a new kind is a subclass with intercept() and nothing else; a Dash and a Parry with no interceptor of their own make theirs
## Exits 0 on success, 1 on failure. Run from the project folder:
##   bash tools/run_tests.sh hit_interceptor
extends SelfTest

const PAWN_SCENE := "res://assets/scenes/pawn/pawn.tscn"


## A test-only ability that runs for 1 s when started by code, holding whatever interceptors a test gives it.
class Stance extends AbilityBase:
	func _init() -> void:
		super()
		kind = Kind.ACTION
		self.category = &"ability.utility.interact"
		self.duration_ticks = 60


## A new kind of interceptor, made only by overriding intercept(): it stops hits that carry more than 15 damage.
class StopsBigHits extends HitInterceptor:
	var asked := 0

	func intercept(hit: HitInfo) -> Result:
		asked += 1
		return Result.STOP if hit.planned_damage() > 15.0 else Result.PASS


func _ready() -> void:
	print("--- Hit interceptor self-test ---")
	TickDriver.tick_rate = TickDriver.REFERENCE_RATE # these checks count ticks at 60
	var floor_body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(200, 1, 200)
	shape.shape = box
	shape.position.y = -0.5
	floor_body.add_child(shape)
	add_child(floor_body)
	await _test_turn_away_and_response()
	await _test_order_and_window()
	await _test_miss()
	await _test_defaults()
	_finish()


func _test_turn_away_and_response() -> void:
	var stance := Stance.new()
	stance.name = "Stance"
	var big := StopsBigHits.new()
	big.name = "StopsBigHits"
	stance.add_child(big)
	var reply := EffectApplier.new()
	reply.trigger = EffectApplier.Trigger.ON_INTERCEPT
	reply.effects = [Effect.make_damage(5)]
	big.add_child(reply)
	var guard := _make_pawn(Vector3(0, 0.1, 0), [stance])
	var attacker := _make_pawn(Vector3(0, 0.1, -2), [])
	await _ticks(10)
	_check(big.ability == stance and big.pawn == guard and big.on_intercept_effects.size() == 1, "(the manager hands an interceptor its ability, pawn and ON_INTERCEPT effects)")
	var stopped: Array = []
	guard.ability_manager.hit_intercepted.connect(func(hit: HitInfo, by: HitInterceptor) -> void: stopped.append(by))
	guard.ability_manager.receive_hit(_hit(attacker, guard, 20))
	_check_near(guard.stat_manager.get_health(), 80.0, 0.01, "with its ability not running, an interceptor stops nothing")
	_check_equal(big.asked, 0, "and isn't even asked")
	guard.ability_manager.start_ability(stance)
	await _ticks(1)
	guard.ability_manager.receive_hit(_hit(attacker, guard, 10))
	_check_near(guard.stat_manager.get_health(), 70.0, 0.01, "running, it lets through the hits intercept() passes (10 damage)")
	guard.ability_manager.receive_hit(_hit(attacker, guard, 20))
	_check_near(guard.stat_manager.get_health(), 70.0, 0.01, "and stops the ones it doesn't (20 damage): none of its effects land")
	_check(stopped == [big], "hit_intercepted goes out once, naming the interceptor (%d)" % stopped.size())
	_check_near(attacker.stat_manager.get_health(), 95.0, 0.01, "its ON_INTERCEPT effect goes back to the attacker in a hit of its own")
	# A reply can't be turned away in its turn: give the attacker the same stance and send it a reply-hit.
	var back := _hit(guard, attacker, 20)
	back.from_interception = true
	_check_equal(guard.ability_manager.intercept_hit(back), null, "a hit sent in reply to an interception can't be turned away")
	guard.free()
	attacker.free()


func _test_order_and_window() -> void:
	var stance := Stance.new()
	stance.name = "Stance"
	var low := StopsBigHits.new()
	low.name = "Low"
	low.priority = 1
	stance.add_child(low)
	var high := HitInterceptor.new() # the base: stops every hit that reaches it
	high.name = "High"
	high.priority = 5
	high.active_seconds = 0.25
	stance.add_child(high)
	var guard := _make_pawn(Vector3(10, 0.1, 0), [stance])
	var attacker := _make_pawn(Vector3(10, 0.1, -2), [])
	await _ticks(10)
	var stopped: Array = []
	guard.ability_manager.hit_intercepted.connect(func(_hit: HitInfo, by: HitInterceptor) -> void: stopped.append(by))
	guard.ability_manager.start_ability(stance)
	await _ticks(1)
	guard.ability_manager.receive_hit(_hit(attacker, guard, 20))
	_check(stopped == [high] and low.asked == 0, "the highest priority is asked first, and the first to stop a hit ends it (lower not asked: %d)" % low.asked)
	await _ticks(20) # past high's 0.25 s (15 ticks)
	_check(not high.is_active() and low.is_active(), "active_seconds: on only for that long from the start of the run")
	guard.ability_manager.receive_hit(_hit(attacker, guard, 20))
	_check(stopped.size() == 2 and stopped[1] == low, "then the next one down decides")
	guard.free()
	attacker.free()


func _test_miss() -> void:
	var stance := Stance.new()
	stance.name = "Stance"
	var dodge := InvulnerabilityInterceptor.new()
	dodge.name = "Invulnerable"
	stance.add_child(dodge)
	var guard := _make_pawn(Vector3(20, 0.1, 0), [stance])
	var attacker := _make_pawn(Vector3(20, 0.1, -2), [])
	await _ticks(10)
	var arrived: Array = []
	guard.ability_manager.hit_arrived.connect(func(hit: HitInfo) -> void: arrived.append(hit))
	guard.ability_manager.start_ability(stance)
	await _ticks(1)
	_check(guard.ability_manager.is_invulnerable(), "a MISS interceptor that's on makes the pawn invulnerable")
	guard.ability_manager.receive_hit(_hit(attacker, guard, 20))
	_check(guard.stat_manager.get_health() == 100.0 and arrived.is_empty(), "the hit never arrives: no damage, and no hit_arrived, so the AI doesn't notice")
	_check(not guard.effect_manager.apply_effect(Effect.make_damage(10), attacker), "and harmful effects are refused too")
	guard.free()
	attacker.free()


func _test_defaults() -> void:
	var dash := DashAbility.new()
	dash.name = "Dash"
	var parry := ParryAbility.new()
	parry.name = "Parry"
	var pawn := _make_pawn(Vector3(30, 0.1, 0), [dash, parry])
	await _ticks(2)
	_check(dash.interceptors.size() == 1 and dash.interceptors[0] is InvulnerabilityInterceptor and is_equal_approx(dash.interceptors[0].active_seconds, 0.18),
		"a Dash with none of its own is invulnerable for its first 0.18 s")
	_check(parry.guard() != null and is_equal_approx(parry.guard().front_degrees, 120.0), "a Parry with none of its own turns away hits from a 120 degree front")
	pawn.free()


func _hit(attacker: Pawn, target: Pawn, damage: int) -> HitInfo:
	var hit := HitInfo.new()
	hit.attacker = attacker
	hit.target = target
	hit.tick = TickDriver.tick
	hit.effects = [Effect.make_damage(damage)]
	var away := target.global_position - attacker.global_position
	away.y = 0.0
	hit.direction = away.normalized()
	return hit


func _make_pawn(at: Vector3, abilities: Array) -> Pawn:
	var pawn: Pawn = load(PAWN_SCENE).instantiate()
	pawn.position = at
	if not abilities.is_empty():
		var manager := AbilityManager.new()
		manager.name = "AbilityManager" # the same name as the default, so PawnInitializer leaves this one alone
		var walk := WalkAbility.new()
		walk.name = "Walk"
		manager.add_child(walk)
		for ability: AbilityBase in abilities:
			manager.add_child(ability)
		pawn.add_child(manager)
	add_child(pawn)
	return pawn


func _ticks(count: int) -> void:
	for i in count:
		await get_tree().physics_frame
