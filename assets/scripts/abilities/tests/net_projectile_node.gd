## Written by Claude (claude-opus-5-5), 2026-11-18: one machine of the projectile network test (net_projectile_selftest), started by NetRun
## as its own Godot process. The server spawns each client a faction pawn (team 0) and a row of shooters (team 1, no AI) that fire the
## RangedAttack at the nearest client pawn in turn; each client strafes its own predicted pawn (walk a second, stand a second), so some
## bolts hit and some miss. Every machine writes what it saw: bolts spawned and despawned, hits, Health, its pawns' positions each tick
## and its rollbacks.
##
## Settings (after --): --role=server|client, --port, --name, --out, --seconds=12, --shooters=3, --fire-every=90 (ticks between one
## shooter's shots), --fire-until (seconds), --latency, --jitter, --loss (the fake network, each way), --conditions-seed.
extends Node

const PAWN_SCENE := preload("res://assets/scenes/samples/faction_player.tscn")
const HEALTH := 1000.0 # high, so no pawn dies during a run: a hit is 15

var settings: Dictionary = {}
var result: Dictionary = {"joined": false, "refused": "", "disconnected": false, "bolts_spawned": [], "bolts_despawned": [],
	"hits": {}, "hit_ticks": [], "health": {}, "positions": {}, "max_in_flight": 0, "shots_tried": 0, "shots_started": 0, "rollbacks": 0}
var _session: NetworkSessionSingleton
var _debug: NetDebugModule
var _shooters: Array[Pawn] = []
var _players: Array[Pawn] = []
var _bolts := {} # entity id -> true while in flight here
var _command := InputCommand.new()
var _started_msec := 0
var _finished := false
var _shooters_spawned := false


func _ready() -> void:
	for argument in OS.get_cmdline_user_args():
		var parts := argument.trim_prefix("--").split("=", true, 1)
		settings[parts[0]] = parts[1] if parts.size() > 1 else "true"
	_session = NetworkSession
	_debug = NetDebugModule.on(_session)
	_build_floor()
	_session.world_root = self
	# The same types, in the same order, on every machine, before hosting or joining: the list is in the join check.
	_session.register_type("pawn", PAWN_SCENE)
	Projectile.register() # Claude 2026-11-22: the built-in projectile, was the bolt scene
	_debug.fake.latency_ms = float(settings.get("latency", 0))
	_debug.fake.jitter_ms = float(settings.get("jitter", 0))
	_debug.fake.loss = float(settings.get("loss", 0))
	var conditions_seed := int(settings.get("conditions-seed", hash(settings.get("name", "server"))))
	_debug.fake.set_seed(conditions_seed)
	_debug.fake_in.set_seed(conditions_seed + 1)
	TickDriver.after_rollback.connect(func(_from: int, _to: int) -> void: result["rollbacks"] += 1)
	TickDriver.register(self, 1) # input after the pawns' own (order 0), as PawnWalkerBrain does
	TickDriver.before_tick.connect(_on_before_tick)
	TickDriver.after_tick.connect(_on_after_tick)
	_session.joined.connect(func() -> void:
		result["joined"] = true
		result["peer"] = _session.get_local_peer()
		result["measure_from_tick"] = TickDriver.tick + 60)
	_session.refused.connect(func(reason: String) -> void: result["refused"] = reason)
	_session.disconnected.connect(func() -> void: result["disconnected"] = true)
	_session.entity_spawned.connect(_on_entity_spawned)
	_session.entity_despawned.connect(_on_entity_despawned)
	_session.player_connected.connect(_on_player_connected)
	_started_msec = Time.get_ticks_msec()
	if settings.get("role", "server") == "server":
		result["peer"] = 1
		result["measure_from_tick"] = 0
		var error := _session.host(int(settings.get("port", 24500)))
		if error != OK:
			result["refused"] = "host failed: %d" % error
			_finish()
	else:
		_session.join("127.0.0.1", int(settings.get("port", 24500)))


func _exit_tree() -> void:
	TickDriver.unregister(self)


func _process(_delta: float) -> void:
	if not _finished and Time.get_ticks_msec() - _started_msec >= int(float(settings.get("seconds", 12)) * 1000.0):
		_finish()


# Server: a pawn for the new player, and the shooters once.
func _on_player_connected(peer: int) -> void:
	_session.spawn("pawn", peer, Vector3(_players.size() * 8.0, 0.1, 0.0))
	if _shooters_spawned:
		return
	_shooters_spawned = true
	var count := int(settings.get("shooters", 3))
	for i in count:
		_session.spawn("pawn", 0, Vector3((i - (count - 1) * 0.5) * 4.0 + 4.0, 0.1, -12.0))


func _on_entity_spawned(entity: NetworkEntity) -> void:
	var node := entity.get_parent()
	if node is Projectile:
		_bolts[entity.entity_id] = true
		result["bolts_spawned"].append(entity.entity_id)
		result["max_in_flight"] = maxi(result["max_in_flight"], _bolts.size())
		return
	var pawn := node as Pawn
	if pawn == null:
		return
	pawn.team = 1 if entity.owner_peer == 0 else 0
	var health := pawn.status_manager.get_stat(&"Health") if pawn.status_manager else null
	if health:
		health.base_value = HEALTH
		health.current = HEALTH
	if entity.owner_peer == 0:
		_shooters.append(pawn)
	else:
		_players.append(pawn)
		if entity.is_local:
			result["own"] = str(entity.entity_id)
			result["own_role"] = NetworkEntity.Role.keys()[entity.role]
		result["hits"][str(entity.entity_id)] = 0
		pawn.ability_manager.hit_received.connect(func(hit: HitInfo) -> void:
			if hit.ability is RangedAttackAbility:
				result["hits"][str(entity.entity_id)] += 1
				result["hit_ticks"].append([TickDriver.tick, entity.entity_id]))


func _on_entity_despawned(entity_id: int) -> void:
	if _bolts.erase(entity_id):
		result["bolts_despawned"].append(entity_id)


# The owner's machine: its pawn walks a second, then stands a second, sideways along x.
func _tick_input(_dt: float, tick: int) -> void:
	for pawn in _players:
		if not is_instance_valid(pawn):
			continue
		var entity: NetworkEntity = pawn.get_meta(&"network_entity")
		if not entity.is_local:
			continue
		var phase := (tick / 60) % 4
		_command.move = Vector3([1.0, 0.0, -1.0, 0.0][phase], 0.0, 0.0)
		_command.look_yaw = 0.0
		_command.look_pitch = 0.0
		_command.held_actions = 0
		pawn.controller_manager.apply_input(_command)


# Server: each shooter fires in turn, every fire-every ticks, at the nearest player's pawn.
func _on_before_tick(_dt: float, tick: int) -> void:
	if not _session.is_server() or TickDriver.is_resimulating() or _players.is_empty():
		return
	if Time.get_ticks_msec() - _started_msec > int(float(settings.get("fire-until", 1000)) * 1000.0):
		return # the clients are about to leave: no hit they won't see
	var every := int(settings.get("fire-every", 90))
	for i in _shooters.size():
		var shooter := _shooters[i]
		if not is_instance_valid(shooter) or (tick + i * every / _shooters.size()) % every != 0:
			continue
		var target := _nearest_player(shooter)
		if target == null:
			continue
		var offset := target.global_position - shooter.global_position
		var yaw := atan2(-offset.x, -offset.z)
		shooter.yaw = yaw
		shooter.controller_manager.look_yaw = yaw
		shooter.controller_manager.look_pitch = 0.0
		var ranged := _ranged_of(shooter)
		result["shots_tried"] += 1
		if ranged and shooter.ability_manager.start_ability(ranged):
			result["shots_started"] += 1


func _on_after_tick(_dt: float, tick: int) -> void:
	if TickDriver.is_resimulating():
		return
	for pawn in _players:
		if not is_instance_valid(pawn):
			continue
		var id := str((pawn.get_meta(&"network_entity") as NetworkEntity).entity_id)
		if not result["positions"].has(id):
			result["positions"][id] = {}
		var at := pawn.global_position
		result["positions"][id][str(tick)] = [at.x, at.y, at.z]
		result["health"][id] = pawn.status_manager.get_health() # the latest, kept after the pawn is gone


func _nearest_player(shooter: Pawn) -> Pawn:
	var best: Pawn = null
	var best_distance := INF
	for pawn in _players:
		if is_instance_valid(pawn) and pawn.global_position.distance_to(shooter.global_position) < best_distance:
			best_distance = pawn.global_position.distance_to(shooter.global_position)
			best = pawn
	return best


func _ranged_of(pawn: Pawn) -> RangedAttackAbility:
	for ability in pawn.ability_manager.get_abilities():
		if ability is RangedAttackAbility:
			return ability
	return null


func _build_floor() -> void:
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(120, 1, 120)
	shape.shape = box
	body.add_child(shape)
	body.position = Vector3(0, -0.5, 0)
	add_child(body)


func _finish() -> void:
	_finished = true
	result["bolts_in_flight_at_end"] = _bolts.size()
	result["end_tick"] = TickDriver.tick
	var out_path: String = settings.get("out", "user://net_projectile_output.json")
	DirAccess.make_dir_recursive_absolute(out_path.get_base_dir())
	var file := FileAccess.open(out_path + ".tmp", FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(result))
		file.close()
		DirAccess.rename_absolute(out_path + ".tmp", out_path)
	_session.leave()
	get_tree().quit(0)
