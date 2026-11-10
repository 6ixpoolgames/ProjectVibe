## Written by Claude (claude-opus-5-5), 2026-11-10: headless self-test for the attack game feel pass (the owner's request): the swing's
## hit sphere sweeps across an arc, right to left (or left to right), so it hits to the side where a sphere held still doesn't; the
## swing turns toward where the pawn looks during its windup; a hit lifts the target in a small hop, but not one already in the air;
## and invulnerability: a pawn whose running ability has invulnerable_while_running isn't hit by a swing, and a dashing pawn takes no
## hit at all.
## Exits 0 on success, 1 on failure. Run from the project folder:
##   "C:\Git\Test 2\Godot_v4.7.2-stable_win64_console.exe" --headless --path . "res://assets/scripts/abilities/tests/attack_feel_selftest.tscn"
extends Node

const PAWN_SCENE := "res://assets/scenes/pawn/pawn.tscn"
const NO_AI: Array[StringName] = [&"AISensingManager", &"AIMemory", &"AITargetSelector", &"AIStateManager", &"AIBehaviourManager"]

var _failures := 0


## A test-only shield: runs for 2 s on the secondary action, and the pawn is invulnerable while it does. Locks nothing out.
class Shield extends AbilityBase:
	func _init() -> void:
		super()
		kind = Kind.ACTION
		trigger_action = &"secondary"
		category = &"utility.interact"
		duration = 2.0
		invulnerable_while_running = true


func _ready() -> void:
	print("--- Attack feel self-test ---")
	TickDriver.tick_rate = TickDriver.REFERENCE_RATE # these checks count ticks at 60
	var floor_body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(300, 1, 300)
	shape.shape = box
	shape.position.y = -0.5
	floor_body.add_child(shape)
	add_child(floor_body)
	await _test_sweep()
	await _test_windup_turn()
	await _test_hop()
	await _test_invulnerable()
	print("--- ALL PASSED ---" if _failures == 0 else "--- %d FAILED ---" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)


## Targets 75 degrees to either side, 1.3 m away: outside a sphere held straight ahead, inside the 100-degree sweep.
func _test_sweep() -> void:
	for from_left in [false, true]:
		var origin := Vector3(0, 0.1, 0) if not from_left else Vector3(20, 0.1, 0)
		var attacker := _pawn(origin, 1)
		var right := _pawn(origin + _flat_at(-75.0, 1.3), 0) # a smaller yaw is to the right
		var left := _pawn(origin + _flat_at(75.0, 1.3), 0)
		var behind := _pawn(origin + Vector3(0, 0, 1.5), 0)
		var melee: MeleeAttackAbility = attacker.ability_manager.get_node("MeleeAttack")
		melee.sweep_from_left = from_left
		var hit_at := {}
		melee.hit_landed.connect(func(hit: HitInfo) -> void: hit_at[hit.target] = TickDriver.tick)
		var moved := []
		melee.hit_area_moved.connect(func(_from: Vector3, _to: Vector3, _radius: float) -> void: moved.append(true))
		await _swing(attacker, origin + Vector3(0, 1, -10))
		var order_ok: bool = hit_at.has(right) and hit_at.has(left) and (hit_at[right] < hit_at[left] if not from_left else hit_at[left] < hit_at[right])
		_check(order_ok, "%s: the sweep hits both sides, %s first (ticks %s)" % ["left to right" if from_left else "right to left", "left" if from_left else "right", str(hit_at.values())])
		_check(not hit_at.has(behind), "and not the pawn behind")
		_check(moved.size() == melee.hit_ticks, "hit_area_moved goes out on each of the %d hit ticks (%d)" % [melee.hit_ticks, moved.size()])
		for pawn in [attacker, right, left, behind]:
			pawn.free()
	# The same, with no sweep: the old sphere straight ahead misses both.
	var still_origin := Vector3(40, 0.1, 0)
	var still := _pawn(still_origin, 1)
	var side := _pawn(still_origin + _flat_at(-75.0, 1.3), 0)
	var front := _pawn(still_origin + Vector3(0, 0, -1.4), 0)
	var still_melee: MeleeAttackAbility = still.ability_manager.get_node("MeleeAttack")
	still_melee.sweep_degrees = 0.0
	var hits := []
	still_melee.hit_landed.connect(func(hit: HitInfo) -> void: hits.append(hit.target))
	await _swing(still, still_origin + Vector3(0, 1, -10))
	_check(hits.has(front) and not hits.has(side), "with sweep_degrees 0, the sphere holds still straight ahead: it hits in front, not to the side")
	for pawn in [still, side, front]:
		pawn.free()


func _test_windup_turn() -> void:
	for turn in [720.0, 0.0]:
		var origin := Vector3(0, 0.1, 30) if turn > 0.0 else Vector3(20, 0.1, 30)
		var pawn := _pawn(origin, 0)
		var melee: MeleeAttackAbility = pawn.ability_manager.get_node("MeleeAttack")
		melee.windup_turn_degrees_per_second = turn
		var ai := _ai(pawn)
		ai.look_at_point(origin + Vector3(0, 1, -10)) # yaw 0
		await _ticks(5)
		ai.press(&"primary")
		await _ticks(2)
		ai.look_at_point(origin + Vector3(10, 1, 0)) # to the right: yaw -90 degrees
		await _until(func() -> bool: return melee.duration_ticks() - melee.ticks_left >= melee.windup_ticks, 30)
		var degrees := rad_to_deg(pawn.yaw)
		if turn > 0.0:
			# The look changes a tick after the swing starts, so 7 of the 8 windup ticks turn: 84 of the 90 degrees at 720 a second.
			_check(degrees < -75.0 and degrees > -91.0, "during the windup, the swing turns toward where the pawn looks (%.0f of -90 degrees)" % degrees)
		else:
			_check(absf(degrees) < 0.5, "with windup turning at 0, it holds where it started (%.0f degrees)" % degrees)
		pawn.free()


func _test_hop() -> void:
	var pawn := _pawn(Vector3(0, 0.1, 60), 0)
	await _ticks(10)
	_check(pawn.grounded, "the target starts on the ground")
	var start_y := pawn.global_position.y
	pawn.receive_hit(_hit(pawn, 2.0))
	await _ticks(2)
	_check(not pawn.grounded and pawn.velocity.y > 0.0, "a hit with a hop lifts it off the ground (%.2f m/s up)" % pawn.velocity.y)
	await _ticks(5)
	var rising := pawn.velocity.y
	pawn.receive_hit(_hit(pawn, 2.0))
	await _ticks(2)
	_check(pawn.velocity.y < rising, "a second hit in the air doesn't lift it again (%.2f m/s, was %.2f)" % [pawn.velocity.y, rising])
	await _until(func() -> bool: return pawn.grounded, 90)
	_check(pawn.grounded and absf(pawn.global_position.y - start_y) < 0.05, "and it lands again")
	var from := pawn.global_position
	pawn.receive_hit(_hit(pawn, 0.0))
	await _ticks(2)
	_check(pawn.grounded, "with no hop, a hit pushes it along the ground")
	await _ticks(20)
	_check(pawn.global_position.z > from.z + 0.2, "away from the attacker (%.2f m)" % (pawn.global_position.z - from.z))
	pawn.free()


func _test_invulnerable() -> void:
	var origin := Vector3(0, 0.1, 90)
	var attacker := _pawn(origin, 1)
	var shield := Shield.new()
	shield.name = "Shield"
	var target := _pawn(origin + Vector3(0, 0, -1.4), 0, [shield])
	var melee: MeleeAttackAbility = attacker.ability_manager.get_node("MeleeAttack")
	var hits := []
	melee.hit_landed.connect(func(hit: HitInfo) -> void: hits.append(hit.target))
	await _ticks(5)
	_ai(target).press(&"secondary")
	await _ticks(2)
	_check(shield.is_running_timed() and target.is_invulnerable(), "an ability with invulnerable_while_running makes its pawn invulnerable while it runs")
	await _swing(attacker, origin + Vector3(0, 1, -10))
	_check(hits.is_empty() and target.get_health() == 100.0, "a swing doesn't hit an invulnerable pawn (HP %d)" % int(target.get_health()))
	attacker.free()
	target.free()
	# Dashing: a hit straight to receive_hit does nothing.
	var dasher := _pawn(Vector3(20, 0.1, 90), 0)
	var received := []
	dasher.hit_received.connect(func(hit: HitInfo) -> void: received.append(hit))
	await _ticks(20) # it lands first (Claude 2026-11-10: Dash works in the air now, but the check is on the ground, as before)
	_ai(dasher).press(&"dash")
	await _ticks(2)
	var dash: DashAbility = dasher.ability_manager.get_node("Dash")
	var hit := _hit(dasher, 2.0)
	hit.damage = 30
	dasher.receive_hit(hit)
	_check(dash.is_running_timed() and received.is_empty() and dasher.get_health() == 100.0, "a dashing pawn takes no hit: no damage and no hit_received (dashing %s, %d received, HP %d, grounded %s)" % [dash.is_running_timed(), received.size(), int(dasher.get_health()), dasher.grounded])
	dasher.free()


# --- Helpers ---


## A hit from 1 m in front of the pawn (-Z), pushing it toward +Z.
func _hit(pawn: Pawn, hop: float) -> HitInfo:
	var hit := HitInfo.new()
	hit.target = pawn
	hit.direction = Vector3(0, 0, 1)
	hit.knockback_speed = 6.0
	hit.knockback_ticks = 10
	hit.knockback_hop = hop
	return hit


## Looks at a point, swings, and waits until the swing is over.
func _swing(attacker: Pawn, look_at: Vector3) -> void:
	var ai := _ai(attacker)
	ai.look_at_point(look_at)
	await _ticks(5)
	ai.press(&"primary")
	await _ticks(2)
	var melee: MeleeAttackAbility = attacker.ability_manager.get_node("MeleeAttack")
	await _until(func() -> bool: return not melee.is_running_timed(), 60)


## Flat offset at this many degrees of yaw from straight ahead (-Z), this far away.
func _flat_at(degrees: float, distance: float) -> Vector3:
	var angle := deg_to_rad(degrees)
	return Vector3(-sin(angle), 0.0, -cos(angle)) * distance


func _pawn(at: Vector3, team: int, extra_abilities: Array = []) -> Pawn:
	var pawn: Pawn = load(PAWN_SCENE).instantiate()
	pawn.skip_default_parts = NO_AI
	pawn.team = team
	pawn.position = at
	if not extra_abilities.is_empty():
		# The default ability part, with the extras added before it starts, as combat_selftest does.
		var manager: AbilityManager = load("res://assets/scenes/pawn/parts/AbilityManager.tscn").instantiate()
		for ability in extra_abilities:
			manager.add_child(ability)
		pawn.add_child(manager)
	add_child(pawn)
	return pawn


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
