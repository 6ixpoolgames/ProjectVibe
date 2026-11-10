## Written by Claude (claude-opus-5-5), 2026-11-09: headless smoke test for faction_arena_sample.tscn: two goblin teams and the
## players' team; red and blue goblins fighting each other, using their heavy attacks; the special attack bound to the right mouse
## button; the bigger readouts; and the debug keys: pausing, stepping back through the recording (view only) and forward.
## Exits 0 on success, 1 on failure. Run from the project folder:
##   "C:\Git\Test 2\Godot_v4.7.2-stable_win64_console.exe" --headless --path . "res://assets/scripts/samples/tests/faction_arena_sample_selftest.tscn"
extends Node

const ARENA := "res://assets/scenes/samples/faction_arena_sample.tscn"

var _failures := 0


func _ready() -> void:
	print("--- Faction arena sample self-test ---")
	var arena: Node = load(ARENA).instantiate()
	add_child(arena)
	await get_tree().physics_frame
	arena._start_offline()
	# Claude 2026-11-10: the goblins come from the scene's two spawners now, which wait for the ground around them to load.
	for i in 300:
		await get_tree().physics_frame
		if i >= 30 and arena._readouts.size() >= 8:
			break
	var player: Pawn = GameMode.possession_coordinator.get_pawn_of()
	var red: Array[Pawn] = []
	var blue: Array[Pawn] = []
	for pawn: Pawn in arena._readouts:
		(red if pawn.team == 1 else blue).append(pawn)
	_check(player != null and player.team == 0 and player.ability_manager.has_node("HeavyAttack") and player.ability_manager.has_node("SecondSwing") and player.ability_manager.has_node("FinisherSwing"), "the player is on team 0, with the heavy attack and the combo's swings") # Claude 2026-11-10
	_check(red.size() == 4 and blue.size() == 4, "the spawners fill up: %d red goblins on team 1 and %d blue on team 2" % [red.size(), blue.size()])
	_check(GameMode.possession_coordinator.controller.action_keys.get(&"secondary") == arena.SPECIAL_KEY_ACTION and InputMap.has_action(arena.SPECIAL_KEY_ACTION), "the special attack is bound to the right mouse button")
	var label: Label3D = arena._readouts[red[0]]
	_check(is_equal_approx(label.pixel_size, 0.005), "the readouts are a little bigger (pixel_size 0.005)")
	_check(arena._keys_text().contains("right mouse"), "and the key reminder mentions the special attack")
	# Claude 2026-11-10 (pawn spec 8.11): the player's pawn has a readout too, which lists the effects on it, such as a combo boost.
	var swing: AbilityBase = player.ability_manager.get_node("MeleeAttack")
	player.effect_manager.apply_effects(swing.on_start_effects, player, swing)
	var player_text: String = arena._player_readout_text(player)
	_check(arena._player_readouts.has(player) and player_text.contains("combo second boost") and arena._readout_text(red[0]).contains("HP"), "the player's pawn has a readout, listing its effects (%s)" % player_text.replace("\n", " | "))
	player.effect_manager.remove_all()
	# The player stands far away, so the goblins find each other; bring the two groups close.
	player.global_position = Vector3(60, player.global_position.y + 1.0, 60)
	for i in red.size():
		red[i].global_position = Vector3(i * 1.5, 1.0, 4.0)
		blue[i].global_position = Vector3(i * 1.5, 1.0, -4.0)
	# GDScript note: a lambda copies plain numbers when it's made, so the count lives in a dictionary, which it shares.
	var across := {"hits": 0} # hits between the two AI teams
	var used := {}
	for goblin in red + blue:
		goblin.hit_received.connect(func(hit: HitInfo) -> void:
			if hit.attacker and hit.attacker.team != 0 and hit.attacker.team != goblin.team:
				across["hits"] += 1)
		goblin.ability_manager.ability_started.connect(func(ability: AbilityBase) -> void: used[String(ability.name)] = true)
	for i in 1200:
		await get_tree().physics_frame
		if across["hits"] > 0 and used.has("HeavyAttack"):
			break
	print("        abilities the goblins started: %s" % ", ".join(used.keys()))
	_check(across["hits"] > 0, "red and blue goblins fight each other (%d hits between them)" % across["hits"])
	_check(used.has("HeavyAttack"), "and use their heavy attacks when they're ready")
	# Pause, step back through the recording, then forward to the present and one real tick on.
	arena._toggle_pause()
	var paused_at: int = TickDriver.tick
	await _ticks(10)
	_check(not TickDriver.active and TickDriver.tick == paused_at, "P pauses: no ticks run")
	var timeline: AIDebugTimeline = arena._timeline
	arena._step(-10)
	await get_tree().process_frame
	var ghosts := 0
	for child in timeline.get_children():
		if child is MeshInstance3D and child.visible:
			ghosts += 1
	# Goblins that died and were removed aren't recorded any more, so the ghosts are the goblins recorded on that tick.
	var recorded: int = timeline._frames.get(paused_at - 10, []).size()
	_check(timeline.is_viewing_past() and timeline.get_viewed_tick() == paused_at - 10 and ghosts == recorded and recorded > 0, "← steps back: a ghost for every goblin recorded 10 ticks ago (%d of %d)" % [ghosts, recorded])
	var live_labels_shown := 0
	for pawn in arena._readouts:
		if is_instance_valid(pawn) and arena._readouts[pawn].visible:
			live_labels_shown += 1
	_check(TickDriver.tick == paused_at and live_labels_shown == 0, "and nothing changed: still the same tick, with the live readouts hidden")
	_check(timeline._panel.visible and timeline._panel.text.contains("PAUSED"), "the event list shows (%d lines)" % timeline._panel.text.count("\n"))
	arena._step(11)
	_check(not timeline.is_viewing_past() and TickDriver.tick == paused_at + 1, "→ steps forward to the present, then runs one real tick")
	arena._toggle_pause()
	await _ticks(5)
	_check(TickDriver.active and TickDriver.tick > paused_at + 1, "P again plays on")
	print("--- ALL PASSED ---" if _failures == 0 else "--- %d FAILED ---" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)


func _ticks(count: int) -> void:
	for i in count:
		await get_tree().physics_frame


func _check(passed: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if passed else "FAIL", what])
	if not passed:
		_failures += 1
