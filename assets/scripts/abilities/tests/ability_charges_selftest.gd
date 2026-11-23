## Written by Claude (claude-opus-5-5), 2026-11-23: headless self-test for limited uses (charges) and start requirements (pawn spec
## 10.13): a start spends a charge, none left means not ready, charges come back on a tick deadline (some, or a full magazine), revive
## refills, the most can be changed for good or for a while, the has-charges tag follows, charges roll back; and start requirements
## over the pawn's owned tags, with the AI's readiness answer moving on when they change.
## Exits 0 on success, 1 on failure. Run from the project folder:
##   godot --headless --path . "res://assets/scripts/abilities/tests/ability_charges_selftest.tscn"
extends SelfTest

const PAWN_SCENE := "res://assets/scenes/pawn/pawn.tscn"
const AMMO := &"status.has_ammo.ranged"


## An instant action on "primary" with limited uses.
class Shot extends AbilityBase:
	var starts := 0

	func _init() -> void:
		super()
		kind = Kind.ACTION
		trigger_action = &"primary"
		category = &"ability.combat.ranged"
		max_charges = 3
		recharges = true
		charge_restore_ticks = 60
		restore_all_charges = true
		has_charges_tag = &"status.has_ammo.ranged"

	func start() -> void:
		starts += 1


## An instant action on "secondary", gated by tags.
class Gated extends AbilityBase:
	func _init() -> void:
		super()
		kind = Kind.ACTION
		trigger_action = &"secondary"


func _ready() -> void:
	TickDriver.tick_rate = TickDriver.REFERENCE_RATE # the checks count exact ticks at 60 a second
	print("--- Ability charges self-test ---")
	await _test_charges()
	await _test_restore_some()
	await _test_no_recharge()
	await _test_max_changes()
	await _test_rollback()
	await _test_start_requirements()
	_finish()


func _test_charges() -> void:
	var made := _make_pawn()
	var pawn: Pawn = made[0]
	var shot: Shot = made[1]
	var manager := pawn.ability_manager
	await _ticks(2)
	_check(manager.can_start(&"primary") and shot.charges_left() == 3, "full: 3 charges, it can start")
	_check(pawn.owned_tags.has(AMMO), "the has-charges tag is owned while charges are left")
	for i in 3:
		_ai(pawn).press(&"primary")
		await _ticks(2)
	_check_equal(shot.starts, 3, "three presses, three starts")
	_check(shot.charges_left() == 0 and not manager.can_start(&"primary"), "out of charges: not ready")
	_check(not pawn.owned_tags.has(AMMO), "...and the tag is gone")
	var version := manager.readiness_version
	_ai(pawn).press(&"primary")
	await _ticks(2)
	_check_equal(shot.starts, 3, "a press with none left starts nothing")
	var restore_at := shot.next_restore_tick
	_check(restore_at > TickDriver.tick, "a restore is due at a tick deadline (%d)" % restore_at)
	while TickDriver.tick < restore_at:
		await _ticks(1)
	await _ticks(1)
	_check(shot.charges_left() == 3 and shot.next_restore_tick == -1, "restore_all_charges: the deadline gives back the full magazine")
	_check(pawn.owned_tags.has(AMMO) and manager.readiness_version != version, "the tag is back, and the AI's readiness answer moved on")
	# Revive refills.
	_ai(pawn).press(&"primary")
	await _ticks(2)
	_check_equal(shot.charges_left(), 2, "one spent")
	manager.revive()
	_check(shot.charges_left() == 3 and shot.next_restore_tick == -1, "revive refills every charge")
	pawn.free()


func _test_restore_some() -> void:
	var made := _make_pawn()
	var pawn: Pawn = made[0]
	var shot: Shot = made[1]
	shot.restore_all_charges = false
	shot.charges_restored = 1
	shot.charge_restore_ticks = 30
	pawn.ability_manager.settings_changed()
	await _ticks(2)
	for i in 3:
		_ai(pawn).press(&"primary")
		await _ticks(2)
	_check_equal(shot.charges_left(), 0, "all three spent")
	var first := shot.next_restore_tick
	while TickDriver.tick <= first:
		await _ticks(1)
	_check(shot.charges_left() == 1 and shot.next_restore_tick == first + 30, "one comes back, and the next is due 30 ticks after the last deadline")
	await _ticks(60)
	_check(shot.charges_left() == 3 and shot.next_restore_tick == -1, "one at a time until full, then no deadline")
	pawn.free()


func _test_no_recharge() -> void:
	var made := _make_pawn()
	var pawn: Pawn = made[0]
	var shot: Shot = made[1]
	shot.recharges = false
	pawn.ability_manager.settings_changed()
	await _ticks(2)
	for i in 3:
		_ai(pawn).press(&"primary")
		await _ticks(2)
	_check(shot.charges_left() == 0 and shot.next_restore_tick == -1, "recharges off: spent, and no restore waiting")
	await _ticks(90)
	_check_equal(shot.charges_left(), 0, "...and none come back on their own")
	pawn.ability_manager.revive()
	_check_equal(shot.charges_left(), 3, "only a refill gives them back")
	pawn.free()


func _test_max_changes() -> void:
	var made := _make_pawn()
	var pawn: Pawn = made[0]
	var shot: Shot = made[1]
	await _ticks(2)
	shot.set_max_charges(5)
	_check(shot.max_charges_now() == 5 and shot.charges_left() == 5, "set_max_charges changes the most for good")
	shot.add_max_charges_change(&"quiver", 2, 30)
	_check_equal(shot.max_charges_now(), 7, "a change for a while adds to it")
	var ends: int = shot.max_charges_changes["quiver"][1]
	while TickDriver.tick <= ends:
		await _ticks(1)
	_check(shot.max_charges_now() == 5 and shot.max_charges_changes.is_empty(), "...and is dropped at its deadline")
	shot.add_max_charges_change(&"curse", -5)
	_check(shot.charges_left() == 0 and not pawn.owned_tags.has(AMMO) and not pawn.ability_manager.can_start(&"primary"),
			"a change can take every charge away: no tag, not ready")
	shot.remove_max_charges_change(&"curse")
	_check(shot.charges_left() == 5 and pawn.owned_tags.has(AMMO), "removed: back")
	pawn.free()


func _test_rollback() -> void:
	var made := _make_pawn()
	var pawn: Pawn = made[0]
	var shot: Shot = made[1]
	await _ticks(5)
	var before := TickDriver.tick
	await _ticks(2)
	_ai(pawn).press(&"primary")
	await _ticks(3)
	_ai(pawn).press(&"primary")
	await _ticks(3)
	var spent := shot.charges_spent
	var due := shot.next_restore_tick
	var went_back: bool = TickDriver.rollback(before)
	_check(went_back and shot.charges_spent == spent and shot.next_restore_tick == due,
			"a replay from before both shots ends with the same charges (%d spent, restore at %d)" % [shot.charges_spent, shot.next_restore_tick])
	_check(pawn.owned_tags.has(AMMO), "and the tag as they say")
	pawn.free()


func _test_start_requirements() -> void:
	var pawn: Pawn = load(PAWN_SCENE).instantiate()
	pawn.position = Vector3(0, 1000, 0)
	var manager := AbilityManager.new() # empty: only the test's ability answers its action
	manager.name = "AbilityManager" # the default's name, so PawnInitializer leaves this one alone
	var gated := Gated.new()
	gated.name = "Gated"
	gated.start_requirements = TagQuery.make([], [], [&"status.dead"])
	manager.add_child(gated)
	pawn.add_child(manager)
	add_child(pawn)
	await _ticks(2)
	_check(manager.can_start(&"secondary"), "start requirements pass (not dead): it can start")
	var version := manager.readiness_version
	pawn.owned_tags.add(&"status.dead")
	_check(not manager.can_start(&"secondary"), "a tag in none_of owned: it can't")
	_check(manager.readiness_version != version, "the owned tags changing moves the AI's readiness answer on")
	pawn.owned_tags.remove(&"status.dead")
	_check(manager.can_start(&"secondary"), "gone again: it can")
	print("  (a warning about an AI tag in start requirements is expected next)")
	gated.start_requirements = TagQuery.make([&"ai.state.combat"])
	manager.settings_changed()
	_check(not manager.can_start(&"secondary"), "an ai.* requirement still works where the AI runs, with a warning")
	pawn.free()


# --- Helpers ---


func _make_pawn() -> Array:
	var pawn: Pawn = load(PAWN_SCENE).instantiate()
	pawn.position = Vector3(0, 1000, 0) # in the air, far from anything: only the abilities matter
	var manager := AbilityManager.new() # empty: only the test's ability answers its action
	manager.name = "AbilityManager" # the default's name, so PawnInitializer leaves this one alone
	var shot := Shot.new()
	shot.name = "Shot"
	manager.add_child(shot)
	pawn.add_child(manager)
	add_child(pawn)
	return [pawn, shot]


func _ai(pawn: Pawn) -> AIController:
	return pawn.controller_manager.ai_controller as AIController


func _ticks(count: int) -> void:
	for i in count:
		await get_tree().physics_frame

