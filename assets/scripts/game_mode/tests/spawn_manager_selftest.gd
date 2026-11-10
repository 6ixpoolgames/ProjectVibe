## Written by Claude (claude-opus-5-5), 2026-11-10: headless self-test for spawning: SpawnPoint, SpawnManager (a GameMode module) and
## PawnSpawner. Offline, on a flat floor with no terrain, so pawns appear at the points' own height. It checks:
##   - points by team and group, facing the point's way; a crowded point spreads pawns inside its scatter; no point, no pawn
##   - after_seconds counts ticks, so pausing the tick driver pauses it
##   - a player's pawn is possessed, and after dying comes back at a point for its team, alive, still possessed
##   - a PawnSpawner fills up, removes a body, replaces it after its delay with a fresh pawn, stops at total_limit, treats a pawn
##     removed some other way as a death, and refill_now skips the wait
## Exits 0 on success, 1 on failure. Run from the project folder:
##   "C:\Git\Test 2\Godot_v4.7.2-stable_win64_console.exe" --headless --path . "res://assets/scripts/game_mode/tests/spawn_manager_selftest.tscn"
extends Node

const PAWN_SCENE := preload("res://assets/scenes/pawn/pawn.tscn")
const GOBLIN_SCENE := preload("res://assets/scenes/samples/arena_goblin.tscn") # team 1

var _failures := 0
var _manager: SpawnManager = null


func _ready() -> void:
	print("--- Spawn manager self-test ---")
	TickDriver.tick_rate = TickDriver.REFERENCE_RATE
	var floor_body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(400, 1, 400)
	shape.shape = box
	shape.position.y = -0.5
	floor_body.add_child(shape)
	add_child(floor_body)
	NetworkSession.world_root = self
	NetworkSession.register_type("spawn_test_player", PAWN_SCENE)
	NetworkSession.register_type("spawn_test_goblin", GOBLIN_SCENE)
	_manager = GameMode.spawn_manager
	_check(_manager != null and GameMode.get_module(SpawnManager) == _manager, "SpawnManager is one of GameMode's default modules")
	await _test_points()
	await _test_after_seconds()
	await _test_player_respawn()
	await _test_pawn_spawner()
	print("--- ALL PASSED ---" if _failures == 0 else "--- %d FAILED ---" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)


func _test_points() -> void:
	var start := _point("PlayerStart", Vector3(0, 0, 0), 0, &"", 0.0, 0.0)
	var east := _point("East", Vector3(40, 0, 0), 1, &"east", 0.0, 90.0)
	var west := _point("West", Vector3(-40, 0, 0), -1, &"west", 0.0, 0.0)
	await _ticks(1)
	var goblin := _manager.spawn("spawn_test_goblin", &"east")
	_check(goblin != null and goblin.global_position.distance_to(Vector3(40, 0, 0)) < 0.01, "a pawn asked for in a group appears at that group's point")
	_check(goblin != null and is_equal_approx(goblin.yaw, deg_to_rad(90.0)), "facing the point's way (%.0f degrees)" % (rad_to_deg(goblin.yaw) if goblin else 0.0))
	var anywhere := _manager.spawn("spawn_test_goblin")
	_check(anywhere != null and (anywhere.global_position.x > 39.0 or anywhere.global_position.x < -39.0), "with no group, it uses any point its team may use: East (team 1) or West (anyone), never PlayerStart (team 0)")
	west.enabled = false
	var team_zero := _manager.find_place(0)
	_check(not team_zero.is_empty() and team_zero["position"].distance_to(Vector3.ZERO) < 0.01, "a team 0 pawn goes to PlayerStart, with West switched off")
	_check(_manager.find_place(1, &"nowhere").is_empty(), "a group with no points: nowhere")
	_check(_manager.spawn("spawn_test_goblin", &"nowhere") == null, "and nothing spawns (a warning says why)")
	# Crowding: a point with a scatter spreads pawns so they don't stand on each other.
	start.scatter_radius = 4.0
	var first := _manager.spawn("spawn_test_player")
	await _ticks(2) # into the physics world, so the next check sees its body
	var second := _manager.spawn("spawn_test_player")
	_check(first and second and first.global_position.distance_to(second.global_position) > _manager.clearance_radius, "a second pawn at a crowded point appears beside the first, not on it (%.2f m apart)" % first.global_position.distance_to(second.global_position))
	for pawn in [goblin, anywhere, first, second]:
		if is_instance_valid(pawn):
			NetworkSession.despawn(pawn.get_network_entity().entity_id)
	start.scatter_radius = 0.0
	west.enabled = true
	east.queue_free()
	west.queue_free()
	await _ticks(2)


func _test_after_seconds() -> void:
	var ran := {"count": 0}
	_manager.after_seconds(0.25, func() -> void: ran["count"] += 1)
	TickDriver.active = false
	await _ticks(40)
	_check(ran["count"] == 0, "after_seconds counts ticks: paused, it doesn't run however long it waits")
	TickDriver.active = true
	await _ticks(20)
	_check(ran["count"] == 1, "and after the ticks it runs, once")


func _test_player_respawn() -> void:
	_manager.player_respawn_seconds = 0.5
	var pawn := _manager.spawn_player(0, "spawn_test_player")
	_check(pawn != null and GameMode.possession_coordinator.get_pawn_of() == pawn, "spawn_player: a pawn at a point for its team, possessed for the player")
	await _ticks(20)
	pawn.global_position = Vector3(10, 0.1, 10)
	var hit := HitInfo.new()
	hit.target = pawn
	hit.damage = 1000
	pawn.receive_hit(hit)
	_check(pawn.is_dead(), "it dies")
	await _ticks(20)
	_check(pawn.is_dead(), "and stays dead until its respawn time")
	await _until(func() -> bool: return not pawn.is_dead(), 40)
	await _ticks(2)
	_check(not pawn.is_dead() and pawn.get_health() == 100.0, "then comes back, with full Health")
	_check(Vector2(pawn.global_position.x, pawn.global_position.z).length() < 0.5, "at PlayerStart, not where it fell")
	_check(GameMode.possession_coordinator.get_pawn_of() == pawn, "and still possessed by its player")
	GameMode.possession_coordinator.release()
	NetworkSession.despawn(pawn.get_network_entity().entity_id)
	_manager.player_respawn_seconds = 3.0
	await _ticks(2)


func _test_pawn_spawner() -> void:
	var spawner := PawnSpawner.new()
	spawner.name = "TestSpawner"
	spawner.pawn_type = "spawn_test_goblin"
	spawner.keep_alive = 3
	spawner.respawn_seconds = 0.5
	spawner.body_seconds = 0.25
	spawner.scatter_radius = 4.0
	spawner.position = Vector3(0, 0, 80)
	spawner.rotation.y = PI
	var spawn_yaws := [] # at the moment each spawns: the goblins' AI turns them soon after
	spawner.spawned.connect(func(p: Pawn) -> void: spawn_yaws.append(p.yaw))
	add_child(spawner)
	await _ticks(3)
	var alive := spawner.get_alive()
	_check(alive.size() == 3, "a spawner fills up to keep_alive (%d)" % alive.size())
	_check(alive.all(func(p: Pawn) -> bool: return p.global_position.distance_to(spawner.global_position) <= 4.01), "within its scatter_radius")
	_check(spawn_yaws.size() == 3 and spawn_yaws.all(func(yaw: float) -> bool: return is_equal_approx(absf(yaw), PI)), "facing its way when they spawn (%s)" % str(spawn_yaws.map(func(yaw: float) -> float: return snappedf(rad_to_deg(yaw), 0.1))))
	var victim := alive[0]
	_kill(victim)
	await _ticks(2)
	_check(spawner.get_alive().size() == 2, "a death leaves it one short")
	await _ticks(20)
	_check(not is_instance_valid(victim), "the body is removed after body_seconds")
	await _until(func() -> bool: return spawner.get_alive().size() == 3, 40)
	_check(spawner.get_alive().size() == 3 and spawner.get_spawned_total() == 4, "and a fresh pawn replaces it after respawn_seconds (%d spawned in all)" % spawner.get_spawned_total())
	# Removed some other way: the same as a death, with no body.
	var removed := spawner.get_alive()[0]
	NetworkSession.despawn(removed.get_network_entity().entity_id)
	await _ticks(3)
	_check(spawner.get_alive().size() == 2, "a pawn removed by the game leaves it one short too")
	await _until(func() -> bool: return spawner.get_alive().size() == 3, 45)
	_check(spawner.get_alive().size() == 3, "and is replaced after the delay")
	# refill_now skips the wait.
	spawner.respawn_seconds = 60.0
	_kill(spawner.get_alive()[0])
	await _ticks(3)
	spawner.refill_now()
	_check(spawner.get_alive().size() == 3, "refill_now fills up at once, without waiting for the replacement")
	# total_limit.
	spawner.total_limit = spawner.get_spawned_total()
	spawner.respawn_seconds = 0.1
	_kill(spawner.get_alive()[0])
	await _ticks(20)
	_check(spawner.get_alive().size() == 2, "past total_limit, nothing more spawns")
	spawner.active = false
	for pawn in spawner.get_alive():
		NetworkSession.despawn(pawn.get_network_entity().entity_id)
	spawner.queue_free()
	await _ticks(2)


# --- Helpers ---


func _point(point_name: String, at: Vector3, team: int, group: StringName, scatter: float, yaw_degrees: float) -> SpawnPoint:
	var point := SpawnPoint.new()
	point.name = point_name
	point.position = at
	point.rotation.y = deg_to_rad(yaw_degrees)
	point.team = team
	point.group = group
	point.scatter_radius = scatter
	add_child(point)
	return point


func _kill(pawn: Pawn) -> void:
	var hit := HitInfo.new()
	hit.target = pawn
	hit.damage = 1000
	pawn.receive_hit(hit)


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
