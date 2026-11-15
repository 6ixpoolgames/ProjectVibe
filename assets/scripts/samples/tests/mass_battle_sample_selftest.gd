## Written by Claude (claude-opus-5-5), 2026-11-15: headless self-test for mass_battle_sample.tscn, with small teams (4) so it's quick:
## the spawners far apart, each loading its own ground; the teams filling up with a hero each, heroes as chunk sources; everyone
## marching to the middle; H switching the heroes' sources; C freezing and unfreezing an AI pawn in the middle; and a pawn sprinting and
## dashing out into unloaded land at a player's speeds never running off the ground its own source builds.
## Exits 0 on success, 1 on failure. Run from the project folder:
##   "C:\Git\Test 2\Godot_v4.7.2-stable_win64_console.exe" --headless --path . "res://assets/scripts/samples/tests/mass_battle_sample_selftest.tscn"
extends Node

const ARENA := "res://assets/scenes/samples/mass_battle_sample.tscn"
const ALLY_SCENE := "res://assets/scenes/samples/faction_ally.tscn"

var _failures := 0
var _arena: Node = null


func _ready() -> void:
	print("--- Mass battle sample self-test ---")
	_arena = load(ARENA).instantiate()
	_arena.team_size = 4
	add_child(_arena)
	await get_tree().physics_frame
	_arena._start_offline()
	_test_layout()
	await _test_filling()
	await _test_march()
	await _test_hero_switch()
	await _test_centre_switch()
	await _test_outrunning()
	print("--- ALL PASSED ---" if _failures == 0 else "--- %d FAILED ---" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)


func _test_layout() -> void:
	var spawners := ["RedSpawner", "BlueSpawner", "AllySpawner"].map(func(n: String) -> Node3D: return _arena.get_node("Spawning/" + n))
	var far := spawners.all(func(s: Node3D) -> bool: return Vector2(s.global_position.x, s.global_position.z).length() > 290.0)
	var sources := spawners.all(func(s: Node3D) -> bool: return s.has_node("StreamingSource") and is_equal_approx((s.get_node("StreamingSource") as StreamingSource).load_distance, 160.0))
	_check(far and sources, "three faction spawners 300 m from the middle, each loading 160 m of ground around itself")
	var red: Node3D = spawners[0]
	var to_middle := -red.global_position.normalized()
	var facing := -red.global_basis.z
	_check(facing.dot(to_middle) > 0.99, "facing the middle")
	_check(_arena.is_centre_source_on() and get_tree().get_nodes_in_group(&"rally_point").size() == 1, "a rally point in the middle, with its own source, on to begin with")


func _test_filling() -> void:
	# 4 of each colour plus a hero each; the players' team: 3 soldiers (4 less the one player) and a hero.
	for i in 600:
		await get_tree().physics_frame
		if _alive(1) == 5 and _alive(2) == 5 and _alive(0) == 4:
			break
	_check(_alive(1) == 5 and _alive(2) == 5 and _alive(0) == 4, "the teams fill up: red %d, blue %d, soldiers %d (each with a hero)" % [_alive(1), _alive(2), _alive(0)])
	var heroes: Array[Pawn] = _arena.get_heroes()
	_check(heroes.size() == 3 and heroes.all(func(h: Pawn) -> bool: return h.has_node("StreamingSource") and h.get_health() == 1000.0), "three heroes, each a chunk source, with 1000 Health")
	var player: Pawn = GameMode.possession_coordinator.get_pawn_of()
	var source := player.get_node_or_null("StreamingSource") as StreamingSource
	_check(source != null and is_equal_approx(source.load_distance, 160.0) and player.global_position.x > 270.0, "the player starts at the players' spawner, loading 160 m like the rest")


func _test_march() -> void:
	var before := _average_distance()
	await _ticks(600)
	var after := _average_distance()
	_check(after < before - 30.0, "everyone marches toward the middle (%.0f m on average, then %.0f m)" % [before, after])


func _test_hero_switch() -> void:
	_arena.set_hero_sources(false)
	await _ticks(2)
	var heroes: Array[Pawn] = _arena.get_heroes()
	_check(heroes.all(func(h: Pawn) -> bool: return not h.has_node("StreamingSource")), "H: the heroes stop being chunk sources")
	_arena.set_hero_sources(true)
	await _ticks(2)
	_check(heroes.all(func(h: Pawn) -> bool: return h.has_node("StreamingSource")), "and H again brings them back")


# A red goblin put in the middle: frozen once the centre's source is off and the ground there unloads, running again once it's on.
# Claude 2026-11-15: and a hero whose source H switched off, which used to be left unwatched by the AI switch-off and fell through the
# world when the ground went (Pawn.ai_loads_chunks didn't tell it).
func _test_centre_switch() -> void:
	_arena.set_hero_sources(false) # so no hero marching nearby keeps the middle loaded
	var goblin: Pawn = null
	for pawn: Pawn in _arena._readouts:
		if is_instance_valid(pawn) and pawn.team == 1 and not pawn.is_dead() and not _arena._is_hero(pawn):
			goblin = pawn
			break
	var terrain: TerrainGenerator = _arena.get_node("World/Terrain")
	goblin.global_position = Vector3(0, terrain.height_at(0, 0) + 0.5, 0)
	var hero: Pawn = _arena.get_heroes()[0]
	hero.global_position = Vector3(4, terrain.height_at(4, 0) + 0.5, 0)
	await _ticks(30)
	var activation: AIActivationManager = GameMode.ai_activation_manager
	_check(activation.is_active(goblin), "a goblin in the middle runs while the centre's source is on")
	_arena.set_centre_source(false)
	for i in 900:
		await get_tree().physics_frame
		if not activation.is_active(goblin):
			break
	_check(not activation.is_active(goblin), "C: with it off, the ground there unloads and the goblin freezes")
	await _ticks(60)
	_check(not activation.is_active(hero) and hero.global_position.y > -5.0, "and so does a hero whose source is off, rather than falling through (y %.1f)" % hero.global_position.y)
	_arena.set_centre_source(true)
	for i in 900:
		await get_tree().physics_frame
		if activation.is_active(goblin):
			break
	_check(activation.is_active(goblin), "C again: the ground comes back and so does the goblin")
	_arena.set_hero_sources(true)


# A soldier with its own 160 m source and no behaviours, driven like a player running away: sprint held, a dash every second, straight
# out from the middle between the red and blue spawners, where nothing else loads ground.
func _test_outrunning() -> void:
	var runner: Pawn = load(ALLY_SCENE).instantiate()
	runner.ai_loads_chunks = true
	runner.streaming_load_distance = 160.0
	var behaviours := runner.get_node("AIBehaviourManager")
	for child in behaviours.get_children():
		behaviours.remove_child(child)
		child.free()
	var terrain: TerrainGenerator = _arena.get_node("World/Terrain")
	runner.position = Vector3(0, terrain.height_at(0, 0) + 0.5, 0)
	_arena.get_node("Entities").add_child(runner)
	await _ticks(10)
	var hands := runner.controller_manager.ai_controller as AIController
	hands.move_in_direction(Vector3(-1, 0, 0))
	hands.hold(&"sprint")
	var off_ground := 0
	var start := runner.global_position
	for i in 1200:
		if i % 60 == 0:
			hands.press(&"dash")
		await get_tree().physics_frame
		if not terrain.has_ground_around(runner.global_position, 2.0):
			off_ground += 1
	var went := Vector2(runner.global_position.x - start.x, runner.global_position.z - start.z).length()
	# Sprinting is 9 m/s on flat ground; hills and the dashes' wind-down bring the average to about 7.
	_check(went > 100.0 and off_ground == 0, "sprinting and dashing for 20 s into unloaded land (%.0f m, %.1f m/s), it never runs off built ground (%d ticks off)" % [went, went / 20.0, off_ground])
	runner.queue_free()


func _alive(team: int) -> int:
	var count := 0
	for node in get_tree().get_nodes_in_group(TerrainBodyLifter.GROUP):
		var pawn := node as Pawn
		if pawn and pawn.team == team and not pawn.is_dead() and pawn != GameMode.possession_coordinator.get_pawn_of():
			count += 1
	return count


func _average_distance() -> float:
	var total := 0.0
	var count := 0
	for pawn: Pawn in _arena._readouts:
		if is_instance_valid(pawn) and not pawn.is_dead():
			total += Vector2(pawn.global_position.x, pawn.global_position.z).length()
			count += 1
	return total / maxf(count, 1)


func _ticks(count: int) -> void:
	for i in count:
		await get_tree().physics_frame


func _check(passed: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if passed else "FAIL", what])
	if not passed:
		_failures += 1
