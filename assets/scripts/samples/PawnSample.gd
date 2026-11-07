## Written by Claude (claude-opus-5-5), 2026-11-07: runs pawn_sample.tscn, a small game for feeling the tier -1 pawn, cameras and streaming.
## Press Offline to play alone. To play together, open it twice, press Host in one and Join in the other.
##
## Keys: WASD to move, Shift to sprint, Space to jump, the mouse to look, and the wheel to zoom. Esc frees the mouse, and a click
## takes it back. Tab swaps to the next pawn. On the host or offline, F raises the ground ahead of you, and G digs it.
##
## A scripted start also works, after "--" on the command line:
##   --offline              starts offline
##   --host                 hosts and plays
##   --join=127.0.0.1       joins
##   --ping=100             fake ping, in milliseconds
##   --walk                 your pawn walks itself, for recording
extends Node3D

const PORT := 24895
const PAWN_SCENE := preload("res://assets/scenes/pawn/pawn.tscn")
const AI_PAWNS := 3

@onready var _terrain: Terrain = $World/Terrain
@onready var _streamer: ChunkStreamer = $World/ChunkStreamer
@onready var _edit_log: TerrainEditLog = $World/Terrain/TerrainEditLog
@onready var _status: Label = $Display/Status
@onready var _menu: Control = $Display/Menu
@onready var _address: LineEdit = $Display/Menu/Box/Address

var _next_spawn := 0
var _walk_by_itself := false


func _ready() -> void:
	NetworkSession.world_root = $Entities
	NetworkSession.register_type("pawn", PAWN_SCENE)
	NetworkSession.player_connected.connect(_on_player_connected)
	NetworkSession.entity_spawned.connect(_on_entity_spawned)
	NetworkSession.refused.connect(func(reason: String) -> void: _status.text = "Refused: %s" % reason)
	NetworkSession.disconnected.connect(func() -> void: _menu.show())
	PawnWalkerBrain.terrain = _terrain
	$Display/Menu/Box/Offline.pressed.connect(_start_offline)
	$Display/Menu/Box/Host.pressed.connect(_host)
	$Display/Menu/Box/Join.pressed.connect(func() -> void: _join(_address.text))
	_read_command_line()


func _process(_delta: float) -> void:
	_status.text = _status_text()


func _unhandled_key_input(event: InputEvent) -> void:
	if not event.is_pressed() or event.is_echo():
		return
	match (event as InputEventKey).physical_keycode:
		KEY_TAB:
			_swap_to_next_pawn()
		KEY_F:
			_edit_ground_ahead(3.0)
		KEY_G:
			_edit_ground_ahead(-3.0)


# --- Starting ---


func _start_offline() -> void:
	_menu.hide()
	var pawn := _spawn_pawn(0)
	GameMode.possession.possess(pawn)
	_spawn_ai_pawns()


func _host() -> void:
	var error := NetworkSession.host(PORT)
	if error != OK:
		_status.text = "Couldn't host: error %d" % error
		return
	_menu.hide()
	_on_player_connected(NetworkSession.get_local_peer())
	_spawn_ai_pawns()


func _join(address: String) -> void:
	_menu.hide()
	NetworkSession.join(address if address != "" else "127.0.0.1", PORT)


## Server: a player has arrived, so they get a pawn.
func _on_player_connected(peer: int) -> void:
	GameMode.possession.possess_for(peer, _spawn_pawn(peer))


func _spawn_ai_pawns() -> void:
	for i in AI_PAWNS:
		_spawn_pawn(0)


func _spawn_pawn(owner_peer: int) -> Pawn:
	var angle := _next_spawn * 2.4
	var radius := 4.0 + _next_spawn * 2.0
	_next_spawn += 1
	var spot := Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)
	# The server has no ground there yet, so it builds that one chunk first to find the height.
	_terrain.load_chunk(_terrain.chunk_of(spot))
	spot.y = _terrain.height_at(spot.x, spot.z) + 0.3
	return NetworkSession.spawn("pawn", owner_peer, spot)


## AI pawns wander on the server. With --walk, so does your own.
func _on_entity_spawned(entity: NetworkEntity) -> void:
	if entity.owner_peer == 0 or _walk_by_itself:
		var brain := PawnWalkerBrain.new()
		brain.mode = "walk"
		entity.get_parent().add_child(brain)


# --- Keys ---


func _swap_to_next_pawn() -> void:
	var pawns: Array[Pawn] = []
	for entity: NetworkEntity in NetworkSession.get_entities():
		var pawn := entity.get_parent() as Pawn
		if pawn and GameMode.possession.get_peer_of(pawn) == 0:
			pawns.append(pawn)
	if not pawns.is_empty():
		GameMode.possession.possess(pawns[randi() % pawns.size()])


func _edit_ground_ahead(amount: float) -> void:
	var pawn := GameMode.possession.get_pawn_of()
	if pawn == null or NetworkSession.is_client():
		return
	var ahead := Basis(Vector3.UP, GameMode.possession.controller.look_yaw) * Vector3(0.0, 0.0, -6.0)
	_terrain.edit(pawn.global_position + ahead, 6.0, amount)


# --- Display ---


func _status_text() -> String:
	var stats := _streamer.get_stats()
	var mode := "offline"
	if NetworkSession.is_server():
		mode = "hosting"
	elif NetworkSession.is_client():
		mode = "client, ping %d ms" % int(NetworkSession.get_rtt_ms())
	var pawn := GameMode.possession.get_pawn_of() if GameMode.possession else null
	var lines := PackedStringArray()
	lines.append("%s    %d fps" % [mode, Engine.get_frames_per_second()])
	lines.append("chunks %d    waiting %d    built at once %d    worst step %.2f ms" % [_terrain.get_loaded_chunks().size(), stats.queued, stats.urgent_builds, stats.worst_step_ms])
	lines.append("AI switched off %d of %d    edits %d" % [GameMode.ai_activity.get_inactive_count(), GameMode.ai_activity.get_watched_count(), _edit_log.get_edit_count()])
	if pawn:
		lines.append("speed %.1f m/s    %s" % [Vector2(pawn.velocity.x, pawn.velocity.z).length(), "on the ground" if pawn.grounded else "in the air"])
	lines.append("WASD, Shift, Space, mouse, wheel    Esc: free the mouse    Tab: next pawn    F / G: raise or dig")
	return "\n".join(lines)


func _read_command_line() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument == "--walk":
			_walk_by_itself = true
		elif argument.begins_with("--ping="):
			var bench := NetTestBench.new()
			add_child(bench)
			bench.set_ping(float(argument.trim_prefix("--ping=")))
	for argument in OS.get_cmdline_user_args():
		if argument == "--offline":
			_start_offline()
		elif argument == "--host":
			_host()
		elif argument.begins_with("--join="):
			_join(argument.trim_prefix("--join="))
