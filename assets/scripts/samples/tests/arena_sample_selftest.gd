## Written by Claude (claude-opus-5-5), 2026-11-09: headless smoke test for arena_sample.tscn, the t0 test level. It starts offline,
## then checks the player and a wave of goblins appear on the ground, the goblins notice the standing player and fight, the readouts
## show, dead goblins are removed and R sends another wave, with no script errors along the way.
## Claude 2026-11-09: also the debug shapes (a dash trail and a swing sphere, and that both fade), goblins sprinting, dashing and
## swinging while they chase, and the readout's last ability.
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
	# Claude 2026-11-10: the goblins come from the scene's spawners now, which wait for the ground around them to load.
	var wanted := 0
	for spawner: PawnSpawner in arena.get_spawners():
		wanted += spawner.keep_alive
	for i in 300:
		await get_tree().physics_frame
		if i >= 30 and arena._readouts.size() >= wanted:
			break
	var player: Pawn = GameMode.possession_coordinator.get_pawn_of()
	var goblins: Array[Pawn] = []
	for pawn: Pawn in arena._readouts:
		goblins.append(pawn)
	_check(player != null and player.team == 0 and Vector2(player.global_position.x, player.global_position.z).length() <= 3.01, "offline: the player has a pawn on team 0, at the PlayerStart")
	_check(goblins.size() == wanted and wanted == 6, "the spawners fill up: %d goblins on team 1" % goblins.size())
	_check(goblins.all(func(g: Pawn) -> bool: return g.grounded or g.global_position.y > -5.0), "standing on the terrain")
	# Claude 2026-11-09: this level's longer cooldowns, with the swing's timer registered for rollback (it had no cooldown before).
	var swing: AbilityBase = null
	for ability in player.ability_manager.get_abilities():
		if ability is MeleeAttackAbility:
			swing = ability
	var tick_state: TickStateComponent = player.get_node("TickState")
	_check(swing.cooldown == arena.DEBUG_COOLDOWNS["MeleeAttack"] and tick_state.state_properties.has("AbilityManager/MeleeAttack:cooldown_ticks_left"), "longer cooldowns, and the swing's rolls back (%.1f s)" % swing.cooldown)
	# Claude 2026-11-09: a dash leaves a trail of capsules that fades within dash_seconds. Done first, while the goblins are far away.
	var draw: AbilityDebugDraw = arena._debug_draw
	var dash: AbilityBase = null
	for ability in player.ability_manager.get_abilities():
		if ability is DashAbility:
			dash = ability
	player.ability_manager.start_ability(dash)
	await _ticks(4)
	var ghosts := _count_shapes(draw, "DashGhost")
	_check(ghosts >= 3, "a dash leaves a trail of capsules (%d)" % ghosts)
	await get_tree().create_timer(draw.dash_seconds + 0.3).timeout
	_check(_count_shapes(draw, "DashGhost") == 0, "and the trail fades away within %.0f s" % draw.dash_seconds)
	# Bring the goblins close, facing the player, so they notice quickly; then wait for a fight.
	for i in goblins.size():
		var goblin := goblins[i]
		goblin.global_position = player.global_position + Vector3(cos(i) * 6.0, 1.0, sin(i) * 6.0)
	var noticed := false
	var hurt := false
	var used := {} # Claude 2026-11-09: names of abilities goblins started during the fight
	var labelled := false # Claude 2026-11-09: a swing sphere was labelled with the player's name
	for i in 900:
		await get_tree().physics_frame
		noticed = noticed or goblins.any(func(g: Pawn) -> bool: return is_instance_valid(g) and g.ai_context.current_state_name() == &"Combat")
		hurt = player.get_health() < 100.0 or player.is_dead()
		for last: AbilityBase in arena._last_ability.values():
			if is_instance_valid(last):
				used[String(last.name)] = true
		labelled = labelled or _sphere_label_with(draw, String(player.name)) != "" # Claude 2026-11-09
		if noticed and hurt and labelled and used.has("Sprint") and used.has("Dash") and used.has("MeleeAttack"):
			break
	_check(noticed, "the goblins notice the player and go into Combat")
	_check(hurt, "and hit the player (HP %d)" % int(player.get_health()))
	_check(used.has("Sprint") and used.has("Dash") and used.has("MeleeAttack"), "chasing goblins sprint, dash and swing (%s)" % ", ".join(used.keys()))
	var label: Label3D = arena._readouts.values()[0] if not arena._readouts.is_empty() else null
	_check(label != null and label.text.contains("HP") and label.text.contains("last: "), "each goblin shows a readout with its last ability (\"%s\")" % (label.text.replace("\n", " / ") if label else ""))
	# Claude 2026-11-09: each swing leaves its hit sphere, which fades within attack_seconds.
	var sphere: Node = null
	for child in draw.get_children():
		if child.name.begins_with("AttackSphere"):
			sphere = child
	# GDScript note: a freed object compares equal to null, so whether one was found is kept apart from the reference itself.
	var found_sphere := sphere != null
	_check(found_sphere, "a swing leaves its hit sphere")
	_check(labelled, "a swing that hits the player labels its sphere with the player's name and the damage")
	await get_tree().create_timer(draw.attack_seconds + 0.3).timeout
	_check(found_sphere and not is_instance_valid(sphere), "and it fades away within %.0f s" % draw.attack_seconds)
	# Kill one, and check it's removed after a while.
	var victim: Pawn = goblins[0]
	for hit in 5:
		var info := HitInfo.new()
		info.attacker = player
		info.target = victim
		info.effects = [Effect.make_damage(20)] # Claude 2026-11-10: hits carry effects now (pawn spec 8.11)
		victim.receive_hit(info)
	_check(victim.is_dead() and arena._kills == 1, "a goblin killed counts as a kill")
	# Claude 2026-11-10: its spawner removes the body and sends a replacement; R (_spawn_wave) refills at once.
	var body_seconds: float = arena.get_spawners()[0].body_seconds
	await get_tree().create_timer(body_seconds + 0.5).timeout
	_check(not is_instance_valid(victim), "and its spawner removes its body after %.0f s" % body_seconds)
	var living := func() -> int:
		var count := 0
		for spawner: PawnSpawner in arena.get_spawners():
			count += spawner.get_alive().filter(func(p: Pawn) -> bool: return not p.is_dead()).size()
		return count
	var before: int = living.call()
	arena._spawn_wave()
	await _ticks(5)
	_check(before < wanted and living.call() == wanted, "R refills the spawners at once (%d living, was %d)" % [living.call(), before])
	print("--- ALL PASSED ---" if _failures == 0 else "--- %d FAILED ---" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)


# Claude 2026-11-09: the text of the first swing sphere label that names this pawn, or "" if none does.
func _sphere_label_with(draw: AbilityDebugDraw, pawn_name: String) -> String:
	for child in draw.get_children():
		var label := child.get_node_or_null("Hits") as Label3D
		if label and label.text.contains(pawn_name + " -"):
			return label.text
	return ""


# Claude 2026-11-09: how many of the debug draw's shapes have this name (Godot numbers the rest: DashGhost2, DashGhost3).
func _count_shapes(draw: AbilityDebugDraw, shape_name: String) -> int:
	var count := 0
	for child in draw.get_children():
		if child.name.begins_with(shape_name):
			count += 1
	return count


func _ticks(count: int) -> void:
	for i in count:
		await get_tree().physics_frame


func _check(passed: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if passed else "FAIL", what])
	if not passed:
		_failures += 1
