## Written by Claude (claude-opus-5-5), 2026-11-09: headless self-test for pawn spec step 9: Dash, MeleeAttack, Knockback, the
## interrupt rules (pawn spec 8.6), hits on the server only, rollback, the lag compensation input, and the AI's Attack behaviour.
## Exits 0 on success, 1 on failure. Run from the project folder:
##   "C:\Git\Test 2\Godot_v4.7.2-stable_win64_console.exe" --headless --path . "res://assets/scripts/abilities/tests/combat_selftest.tscn"
extends Node

const PAWN_SCENE := "res://assets/scenes/pawn/pawn.tscn"

var _failures := 0


## A timed action a test can give any threshold, locking out walking, sprinting and jumping, like an emote or a reload.
class Busy extends AbilityBase:
	func _init() -> void:
		super()
		kind = Kind.ACTION
		trigger_action = &"secondary"
		category = &"utility.interact"
		duration = 2.0
		locks_out = [&"movement.walk", &"movement.sprint", &"movement.jump"]


func _ready() -> void:
	print("--- Combat self-test ---")
	var floor_body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(200, 1, 200)
	shape.shape = box
	shape.position.y = -0.5
	floor_body.add_child(shape)
	add_child(floor_body)
	await _test_dash()
	await _test_interrupts()
	await _test_melee_hits()
	await _test_melee_multi_hit() # Claude 2026-11-09
	await _test_server_only_and_replays()
	_test_view_ticks_behind()
	await _test_ai_attacks()
	print("--- ALL PASSED ---" if _failures == 0 else "--- %d FAILED ---" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)


func _test_dash() -> void:
	var pawn := _make_pawn(Vector3(0, 0.1, 0))
	var ai := _ai(pawn)
	var dash: DashAbility = pawn.ability_manager.get_node("Dash")
	await _ticks(15)
	var start := pawn.global_position
	ai.move_in_direction(Vector3(1, 0, 0))
	ai.press(&"dash")
	await _ticks(2)
	_check(dash.is_running_timed() and pawn.velocity.x > 17.0, "dash: a burst at DashSpeed, the way it's moving (%.1f m/s)" % pawn.velocity.x)
	ai.press(&"jump")
	await _ticks(1)
	_check(pawn.velocity.y <= 0.01, "jump is locked out while dashing")
	await _ticks(10)
	ai.stop()
	await _ticks(30)
	var travelled := pawn.global_position.x - start.x
	_check(not dash.is_running_timed() and travelled > 2.5 and travelled < 4.0, "it lasts 9 ticks, about 2.7 m, then Walk slows it (%.2f m)" % travelled)
	ai.press(&"dash")
	await _ticks(2)
	_check(not dash.is_running_timed() or dash.cooldown_ticks_left == 0, "after its 1 s cooldown is over it can go again")
	await _ticks(60)
	var facing_before := pawn.yaw
	ai.press(&"dash")
	await _ticks(2)
	var along := Vector3(-sin(facing_before), 0, -cos(facing_before))
	_check(Vector3(pawn.velocity.x, 0, pawn.velocity.z).normalized().dot(along) > 0.99, "standing still, it dashes the way it faces")
	await _ticks(70)
	ai.press(&"jump")
	await _ticks(3)
	ai.press(&"dash")
	await _ticks(2)
	_check(not dash.is_running_timed(), "no air dash")
	await _ticks(60)
	ai.press(&"dash")
	await _ticks(2)
	ai.press(&"dash")
	await _ticks(12)
	_check(not dash.is_running_timed() and dash.cooldown_ticks_left > 0, "its cooldown stops a second dash straight after")
	pawn.free()


func _test_interrupts() -> void:
	var pawn := _make_pawn(Vector3(10, 0.1, 0))
	var ai := _ai(pawn)
	var manager := pawn.ability_manager
	var melee: MeleeAttackAbility = manager.get_node("MeleeAttack")
	var dash: DashAbility = manager.get_node("Dash")
	var sprint: SprintAbility = manager.get_node("Sprint")
	var cancels := []
	manager.ability_cancelled.connect(func(what, by): cancels.append([what.name, by.name]))
	await _ticks(15)
	ai.press(&"primary")
	await _ticks(2)
	_check(melee.is_running_timed() and melee.ticks_left > 15, "the swing starts and lasts 24 ticks")
	ai.move_in_direction(Vector3(1, 0, 0))
	ai.hold(&"sprint")
	await _ticks(3)
	_check(melee.is_running_timed() and not sprint.is_running_timed(), "sprinting (10) doesn't cancel a swing (threshold 15)")
	_check(Vector2(pawn.velocity.x, pawn.velocity.z).length() < 0.5, "and the pawn holds still while swinging")
	ai.press(&"dash")
	await _ticks(2)
	_check(not melee.is_running_timed() and dash.is_running_timed(), "dash (20) cancels the swing: the animation cancel")
	_check(cancels.has([&"MeleeAttack", &"Dash"]) and melee.cooldown_ticks_left >= 0, "ability_cancelled says so")
	ai.hold(&"sprint", false)
	ai.stop()
	await _ticks(30)
	# A knockback cancels a dash.
	ai.move_in_direction(Vector3(0, 0, 1))
	ai.press(&"dash")
	await _ticks(2)
	var knockback: KnockbackAbility = manager.get_node("Knockback")
	knockback.push(Vector3(-8, 0, 0), 10)
	_check(not dash.is_running_timed() and knockback.is_running_timed(), "knockback (30) cancels a dash (threshold 25)")
	await _ticks(1)
	_check(pawn.velocity.x < -6.0, "and pushes the pawn (%.1f m/s)" % pawn.velocity.x)
	ai.stop()
	await _ticks(30)
	_check(Vector2(pawn.velocity.x, pawn.velocity.z).length() < 0.5, "the push fades out")
	pawn.free()

	# Thresholds 0 and 10, on an action that locks out movement: walking cancels the first, only sprinting the second.
	var emote := Busy.new()
	emote.name = "Emote"
	emote.interrupt_threshold = 0
	pawn = _make_pawn(Vector3(20, 0.1, 0), [emote])
	ai = _ai(pawn)
	await _ticks(15)
	ai.press(&"secondary")
	await _ticks(3)
	_check(emote.is_running_timed(), "an emote (threshold 0) starts")
	ai.move_in_direction(Vector3(1, 0, 0))
	await _ticks(3)
	_check(not emote.is_running_timed() and pawn.velocity.x > 1.0, "just moving cancels it")
	pawn.free()
	var reload := Busy.new()
	reload.name = "Reload"
	reload.interrupt_threshold = 10
	pawn = _make_pawn(Vector3(30, 0.1, 0), [reload])
	ai = _ai(pawn)
	await _ticks(15)
	ai.press(&"secondary")
	await _ticks(2)
	ai.move_in_direction(Vector3(1, 0, 0))
	await _ticks(5)
	_check(reload.is_running_timed(), "a reload (threshold 10) isn't cancelled by walking")
	ai.hold(&"sprint")
	await _ticks(3)
	_check(not reload.is_running_timed(), "but sprinting cancels it, like a CoD sprint cancel")
	pawn.free()


## Claude 2026-11-09: one swing hits every enemy inside its sphere, and each takes its own damage and its own knockback (the owner
## asked whether melee is multi-hit). Placed off to the side, at x = 30, away from the other tests' pawns.
func _test_melee_multi_hit() -> void:
	var attacker := _make_pawn(Vector3(30, 0.1, 40))
	attacker.team = 1
	# Both 1.4 m in front and 0.5 m to either side: inside the sphere (centre 1 m ahead, radius 0.8) and not touching each other.
	var left := _make_pawn(Vector3(29.5, 0.1, 38.6))
	var right := _make_pawn(Vector3(30.5, 0.1, 38.6))
	await _ticks(15)
	var melee: MeleeAttackAbility = attacker.ability_manager.get_node("MeleeAttack")
	var landed := []
	melee.hit_landed.connect(func(hit): landed.append(hit))
	var ai := _ai(attacker)
	ai.look_at_point(Vector3(30, 1, 30))
	await _ticks(2)
	ai.press(&"primary")
	await _ticks(16) # the 8-tick wind-up, the 4 hit ticks and the knockback's first ticks
	var hit_both := landed.any(func(hit): return hit.target == left) and landed.any(func(hit): return hit.target == right)
	_check(landed.size() == 2 and hit_both, "multi-hit: one swing hits both enemies inside its sphere, each once (%d hits)" % landed.size())
	_check(left.get_health() == 100.0 - melee.damage and right.get_health() == 100.0 - melee.damage, "and each takes the damage (%d and %d HP)" % [int(left.get_health()), int(right.get_health())])
	_check(left.global_position.x < 29.45 and right.global_position.x > 30.55, "and each is knocked back away from the attacker, to its own side (%.2f and %.2f m sideways)" % [left.global_position.x - 29.5, right.global_position.x - 30.5])
	attacker.free()
	left.free()
	right.free()


func _test_melee_hits() -> void:
	var attacker := _make_pawn(Vector3(0, 0.1, 40))
	attacker.team = 1
	var near := _make_pawn(Vector3(0, 0.1, 38.6)) # 1.4 m in front (the attacker faces -Z)
	var far := _make_pawn(Vector3(1.5, 0.1, 37.2)) # about 3.2 m away
	var friend := _make_pawn(Vector3(-0.5, 0.1, 38.8))
	friend.team = 1
	await _ticks(15)
	var melee: MeleeAttackAbility = attacker.ability_manager.get_node("MeleeAttack")
	var landed := []
	melee.hit_landed.connect(func(hit): landed.append(hit))
	var received := []
	near.hit_received.connect(func(hit): received.append(hit))
	var ai := _ai(attacker)
	ai.look_at_point(Vector3(0, 1, 30))
	await _ticks(2)
	ai.press(&"primary")
	await _ticks(6) # the swing starts on the next tick, and winds up for 8
	_check(landed.is_empty(), "nothing is hit during the wind-up")
	for i in 10:
		await get_tree().physics_frame
		if not landed.is_empty():
			break
	await _ticks(2) # the knockback's first ticks
	var pushed := near.velocity.z
	await _ticks(6) # past the 4 hit ticks
	_check(landed.size() == 1 and landed[0].target == near, "during the hit ticks, the pawn in range is hit once, though it's in the sphere for 4 ticks")
	_check(received.size() == 1 and received[0].attacker == attacker, "its receive_hit got the HitInfo, and hit_received went out")
	_check(pushed < -3.0, "it's knocked back, away from the attacker, by its own Knockback (%.1f m/s)" % pushed)
	_check(not landed.any(func(hit): return hit.target == far), "a pawn beyond attack_range isn't hit")
	_check(not landed.any(func(hit): return hit.target == friend), "nor one on its own team")
	var listed: Array[String] = (attacker.get_node("TickState") as TickStateComponent).state_properties
	_check(listed.has("AbilityManager/MeleeAttack:ticks_left") and listed.has("AbilityManager/Knockback:push_velocity") and listed.has("AbilityManager/Dash:dash_direction"), "the swing's timer, the push and the dash direction all roll back")
	attacker.free()
	near.free()
	far.free()
	friend.free()


func _test_server_only_and_replays() -> void:
	var attacker := _make_pawn(Vector3(0, 0.1, 60))
	attacker.team = 1
	var target := _make_pawn(Vector3(0, 0.1, 58.6))
	await _ticks(15)
	var melee: MeleeAttackAbility = attacker.ability_manager.get_node("MeleeAttack")
	var landed := []
	melee.hit_landed.connect(func(hit): landed.append(hit))
	var ai := _ai(attacker)
	ai.look_at_point(Vector3(0, 1, 50))
	await _ticks(2)
	# As a client: the swing plays, but hits are the server's to decide.
	var real_entity: NetworkEntity = attacker._entity
	var client_entity := NetworkEntity.new()
	client_entity.role = NetworkEntity.Role.LOCAL_PREDICTED
	attacker._entity = client_entity
	ai.press(&"primary")
	await _ticks(20)
	_check(landed.is_empty() and not attacker.is_authority(), "on a client the swing hits nothing")
	attacker._entity = real_entity
	client_entity.free()
	await _ticks(30)
	ai.press(&"primary")
	await _ticks(20)
	_check(landed.size() == 1, "as the authority it hits")
	var went_back: bool = TickDriver.rollback(TickDriver.tick - 12)
	_check(went_back and landed.size() == 1, "a rollback replaying the hit ticks doesn't hit again")
	attacker.free()
	target.free()


func _test_view_ticks_behind() -> void:
	var pawn: Pawn = load(PAWN_SCENE).instantiate()
	var negative := pawn.sanitize_network_input({"view_ticks_behind": -4.0})
	var nan := pawn.sanitize_network_input({"view_ticks_behind": NAN})
	var wrong := pawn.sanitize_network_input({"view_ticks_behind": "far"})
	var fine := pawn.sanitize_network_input({"view_ticks_behind": 6.5})
	_check(negative["view_ticks_behind"] == 0.0 and nan["view_ticks_behind"] == 0.0 and wrong["view_ticks_behind"] == 0.0, "view_ticks_behind from a client: negative, NaN or the wrong type become 0")
	_check(fine["view_ticks_behind"] == 6.5, "a sensible value passes through (LagCompensation limits how far back it goes)")
	var tick_state: TickStateComponent = pawn.get_node("TickState")
	_check(tick_state.input_properties.has("view_ticks_behind @float"), "it's in the pawn's input list, so a client's swing carries it")
	pawn.free()


func _test_ai_attacks() -> void:
	var goblin: Pawn = load(PAWN_SCENE).instantiate()
	goblin.team = 1
	goblin.position = Vector3(0, 0.1, 80)
	var behaviours := AIBehaviourManager.new()
	behaviours.name = "AIBehaviourManager"
	for pair in [["Chase", AIChaseBehaviour], ["Attack", AIAttackBehaviour]]:
		var behaviour: AIBehaviourBase = pair[1].new()
		behaviour.name = pair[0]
		behaviours.add_child(behaviour)
	goblin.add_child(behaviours)
	add_child(goblin)
	var intruder := _make_pawn(Vector3(0, 0.1, 74))
	await _ticks(5)
	var melee: MeleeAttackAbility = goblin.ability_manager.get_node("MeleeAttack")
	var landed := []
	melee.hit_landed.connect(func(hit): landed.append(hit))
	# GDScript note: a lambda gets a copy of a local number, so it records into an array, which it shares.
	var attack_started := []
	goblin.ai_behaviour_manager.behaviour_changed.connect(func(_old, new, _reason):
		if new and new.name == &"Attack":
			attack_started.append(TickDriver.tick))
	for i in 240:
		await get_tree().physics_frame
		if not landed.is_empty():
			break
	_check(goblin.ai_context.current_state_name() == &"Combat", "the goblin sees the intruder and goes into Combat")
	_check(not attack_started.is_empty(), "it chases, then switches to Attack once close enough")
	var gap := Vector2(goblin.global_position.x - intruder.global_position.x, goblin.global_position.z - intruder.global_position.z).length()
	_check(not landed.is_empty() and landed[0].target == intruder, "the swing lands (from %.2f m, inside attack_range %.1f)" % [gap, melee.attack_range])
	goblin.free()
	intruder.free()


# --- Helpers ---


func _make_pawn(at: Vector3, extra_abilities: Array = []) -> Pawn:
	var pawn: Pawn = load(PAWN_SCENE).instantiate()
	pawn.position = at
	if not extra_abilities.is_empty():
		var manager: AbilityManager = load("res://assets/scenes/pawn/parts/AbilityManager.tscn").instantiate()
		for ability in extra_abilities:
			manager.add_child(ability)
		pawn.add_child(manager)
	add_child(pawn)
	return pawn


func _ai(pawn: Pawn) -> AIController:
	return pawn.controller_manager.ai_controller as AIController


func _ticks(count: int) -> void:
	for i in count:
		await get_tree().physics_frame


func _check(passed: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if passed else "FAIL", what])
	if not passed:
		_failures += 1
