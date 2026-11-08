## Written by Claude (claude-opus-5-5), 2026-11-09: headless smoke test for arena_sample.tscn, the t0 test level. It starts offline,
## then checks the player and a wave of goblins appear on the ground, the goblins notice the standing player and fight, the readouts
## show, dead goblins are removed and R sends another wave, with no script errors along the way.
## Exits 0 on success, 1 on failure. Run from the project folder:
##   "C:\Git\Test 2\Godot_v4.7.2-stable_win64_console.exe" --headless --path . "res://assets/scripts/samples/tests/arena_sample_selftest.tscn"
extends Node

const ARENA := "res://assets/scenes/samples/arena_sample.tscn"

var _failures := 0


func _ready() -> void:
	print("--- Arena sample self-test ---")
	var arena: Node = load(ARENA).instantiate()
	add_child(arena)
	await get_tree().physics_frame
	arena._start_offline()
	await _ticks(30)
	var player: Pawn = GameMode.possession_coordinator.get_pawn_of()
	var goblins: Array[Pawn] = []
	for pawn: Pawn in arena._readouts:
		goblins.append(pawn)
	_check(player != null and player.team == 0, "offline: the player has a pawn on team 0")
	_check(goblins.size() == arena.GOBLINS_PER_WAVE, "a wave of %d goblins on team 1" % goblins.size())
	_check(goblins.all(func(g: Pawn) -> bool: return g.grounded or g.global_position.y > -5.0), "standing on the terrain")
	# Bring the goblins close, facing the player, so they notice quickly; then wait for a fight.
	for i in goblins.size():
		var goblin := goblins[i]
		goblin.global_position = player.global_position + Vector3(cos(i) * 6.0, 1.0, sin(i) * 6.0)
	var noticed := false
	var hurt := false
	for i in 900:
		await get_tree().physics_frame
		noticed = noticed or goblins.any(func(g: Pawn) -> bool: return is_instance_valid(g) and g.ai_context.current_state_name() == &"Combat")
		hurt = player.get_health() < 100.0 or player.is_dead()
		if noticed and hurt:
			break
	_check(noticed, "the goblins notice the player and go into Combat")
	_check(hurt, "and hit the player (HP %d)" % int(player.get_health()))
	var label: Label3D = arena._readouts.values()[0] if not arena._readouts.is_empty() else null
	_check(label != null and label.text.contains("HP"), "each goblin shows a readout (\"%s\")" % (label.text.replace("\n", " / ") if label else ""))
	# Kill one, and check it's removed after a while.
	var victim: Pawn = goblins[0]
	for hit in 5:
		var info := HitInfo.new()
		info.attacker = player
		info.target = victim
		info.damage = 20
		victim.receive_hit(info)
	_check(victim.is_dead() and arena._kills == 1, "a goblin killed counts as a kill")
	await get_tree().create_timer(arena.BODY_REMOVAL_SECONDS + 0.5).timeout
	_check(not is_instance_valid(victim), "and its body is removed after %.0f s" % arena.BODY_REMOVAL_SECONDS)
	var before: int = arena._readouts.size()
	arena._spawn_wave()
	await _ticks(5)
	_check(arena._readouts.size() == before + arena.GOBLINS_PER_WAVE, "R sends another wave")
	print("--- ALL PASSED ---" if _failures == 0 else "--- %d FAILED ---" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)


func _ticks(count: int) -> void:
	for i in count:
		await get_tree().physics_frame


func _check(passed: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if passed else "FAIL", what])
	if not passed:
		_failures += 1
