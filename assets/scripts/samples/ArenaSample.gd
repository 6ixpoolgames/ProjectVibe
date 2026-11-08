## Written by Claude (claude-opus-5-5), 2026-11-09: runs arena_sample.tscn, the t0 test level: you against goblins, to feel and tune
## the pawn, abilities, AI and fights by hand (pawn spec build order step 12, pulled forward at the owner's request).
## Press Offline to play alone. To play together, open it twice, press Host in one and Join in the other.
##
## Keys: WASD to move, Shift to sprint, Space to jump, Left Alt to dash, the left mouse button to swing, the mouse to look, the wheel
## to zoom. Esc frees the mouse, and a click takes it back. R sends a new wave of goblins. Tab possesses a goblin (then it fights for
## you, on its team; Tab again goes back). F3 shows or hides the readout over each goblin.
##
## What's in it:
##   - The same world as the pawn sample: terrain, streaming and nav.
##   - Goblins (arena_goblin.tscn): red pawns on team 1 with all six t0 behaviours (Wander, Look Toward, Investigate, Search, Chase,
##     Attack). They wander until they notice you, then chase and swing. Hit them back.
##   - A readout over each goblin, on the server or offline, where the AI runs: its state, its running behaviour, its Health, and
##     how aware of your pawn it is. This is sample code: the base has no debug readout yet (pawn spec open question 10).
##   - Death: a dead goblin is removed after 3 s. A dead player is revived where they fell after 3 s. Both are this sample's rules,
##     not the base's (pawn spec 8.7).
##
## A scripted start also works, after "--" on the command line: --offline, --host, --join=127.0.0.1, --ping=100.
extends Node3D

const PORT := 24896
const PAWN_SCENE := preload("res://assets/scenes/pawn/pawn.tscn")
const GOBLIN_SCENE := preload("res://assets/scenes/samples/arena_goblin.tscn")
const GOBLINS_PER_WAVE := 6
const BODY_REMOVAL_SECONDS := 3.0
const PLAYER_REVIVE_SECONDS := 3.0

@onready var _terrain: TerrainGenerator = $World/Terrain
@onready var _status: Label = $Display/Status
@onready var _menu: Control = $Display/Menu
@onready var _address: LineEdit = $Display/Menu/Box/Address

var _show_readouts := true
var _kills := 0
var _deaths := 0
var _readouts := {} # Pawn -> Label3D
var _player_pawn: Pawn = null # the pawn this machine's player started with, to go back to after Tab


func _ready() -> void:
	NetworkSession.world_root = $Entities
	NetworkSession.register_type("pawn", PAWN_SCENE)
	NetworkSession.register_type("goblin", GOBLIN_SCENE)
	NetworkSession.player_connected.connect(_on_player_connected)
	NetworkSession.entity_spawned.connect(_on_entity_spawned)
	NetworkSession.refused.connect(func(reason: String) -> void: _status.text = "Refused: %s" % reason)
	NetworkSession.disconnected.connect(func() -> void: _menu.show())
	$Display/Menu/Box/Offline.pressed.connect(_start_offline)
	$Display/Menu/Box/Host.pressed.connect(_host)
	$Display/Menu/Box/Join.pressed.connect(func() -> void: _join(_address.text))
	_read_command_line()


func _process(_delta: float) -> void:
	_status.text = _status_text()
	_update_readouts()


func _unhandled_key_input(event: InputEvent) -> void:
	if not event.is_pressed() or event.is_echo():
		return
	match (event as InputEventKey).physical_keycode:
		KEY_R:
			_spawn_wave()
		KEY_TAB:
			_swap_pawn()
		KEY_F3:
			_show_readouts = not _show_readouts


# --- Starting ---


func _start_offline() -> void:
	_menu.hide()
	_player_pawn = _spawn("pawn", 0, Vector3.ZERO)
	GameMode.possession_coordinator.possess(_player_pawn)
	_spawn_wave()


func _host() -> void:
	var error := NetworkSession.host(PORT)
	if error != OK:
		_status.text = "Couldn't host: error %d" % error
		return
	_menu.hide()
	_on_player_connected(NetworkSession.get_local_peer())
	_spawn_wave()


func _join(address: String) -> void:
	_menu.hide()
	NetworkSession.join(address if address != "" else "127.0.0.1", PORT)


## Server: a player has arrived, so they get a pawn near the middle.
func _on_player_connected(peer: int) -> void:
	var pawn := _spawn("pawn", peer, Vector3(randf_range(-3.0, 3.0), 0.0, randf_range(-3.0, 3.0)))
	if peer == NetworkSession.get_local_peer() or not NetworkSession.is_server():
		_player_pawn = pawn
	GameMode.possession_coordinator.possess_for(peer, pawn)


## Server: a ring of goblins 18 to 26 m out, so they have to notice you first.
func _spawn_wave() -> void:
	if NetworkSession.is_client():
		return
	for i in GOBLINS_PER_WAVE:
		var angle := TAU * i / GOBLINS_PER_WAVE + randf_range(-0.3, 0.3)
		var distance := randf_range(18.0, 26.0)
		_spawn("goblin", 0, Vector3(cos(angle) * distance, 0.0, sin(angle) * distance))


func _spawn(type_name: String, owner_peer: int, spot: Vector3) -> Pawn:
	# The server has no ground there yet, so it builds that one chunk first to find the height.
	_terrain.load_chunk(_terrain.chunk_of(spot))
	spot.y = _terrain.height_at(spot.x, spot.z) + 0.3
	return NetworkSession.spawn(type_name, owner_peer, spot) as Pawn


## Every machine: give each pawn its readout; the server also listens for deaths.
func _on_entity_spawned(entity: NetworkEntity) -> void:
	var pawn := entity.get_parent() as Pawn
	if pawn == null:
		return
	if pawn.team == 1:
		var label := Label3D.new()
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.no_depth_test = true
		label.font_size = 48
		label.outline_size = 12
		label.pixel_size = 0.004
		label.position = Vector3(0.0, 2.4, 0.0)
		pawn.get_visual().add_child(label)
		_readouts[pawn] = label
	if not NetworkSession.is_client():
		pawn.died.connect(_on_pawn_died)


# --- Deaths (this sample's rules) ---


func _on_pawn_died(pawn: Pawn, _hit: HitInfo) -> void:
	if pawn.team == 1:
		_kills += 1
		await get_tree().create_timer(BODY_REMOVAL_SECONDS).timeout
		if is_instance_valid(pawn):
			_readouts.erase(pawn)
			NetworkSession.despawn(pawn.get_network_entity().entity_id)
	else:
		_deaths += 1
		await get_tree().create_timer(PLAYER_REVIVE_SECONDS).timeout
		if is_instance_valid(pawn):
			pawn.revive()


# --- Keys ---


## Tab: possess a living goblin, or go back to your own pawn.
func _swap_pawn() -> void:
	var coordinator := GameMode.possession_coordinator
	var current := coordinator.get_pawn_of()
	if current != null and current.team == 1 and is_instance_valid(_player_pawn):
		coordinator.possess(_player_pawn)
		return
	for pawn: Pawn in _readouts:
		if is_instance_valid(pawn) and not pawn.is_dead() and coordinator.get_peer_of(pawn) == 0:
			coordinator.possess(pawn)
			return


# --- Display ---


func _update_readouts() -> void:
	var player := _player_pawn if is_instance_valid(_player_pawn) else null
	for pawn: Pawn in _readouts.keys():
		var label: Label3D = _readouts[pawn]
		if not is_instance_valid(pawn) or not is_instance_valid(label):
			_readouts.erase(pawn)
			continue
		label.visible = _show_readouts
		if not _show_readouts:
			continue
		var lines := PackedStringArray()
		if pawn.is_dead():
			lines.append("dead")
		elif pawn.runs_ai_here() and pawn.ai_context:
			var running := pawn.ai_behaviour_manager.get_running_behaviour() if pawn.ai_behaviour_manager else null
			lines.append("%s · %s" % [pawn.ai_context.current_state_name(), running.name if running else "—"])
			if player and pawn.ai_memory:
				var index := pawn.ai_memory.find(player)
				if index >= 0:
					var awareness := pawn.ai_memory.awareness_at(index, pawn.ai_context.current_tick)
					lines.append("aware %d%%%s" % [int(awareness * 100.0), " (certain)" if pawn.ai_memory.is_certain_at(index) else ""])
		lines.append("HP %d" % int(pawn.get_health()))
		label.text = "\n".join(lines)
		label.modulate = Color(1.0, 0.45, 0.4) if pawn.ai_context and pawn.ai_context.current_state_name() == &"Combat" else Color(1.0, 0.95, 0.8)


func _status_text() -> String:
	var mode := "offline"
	if NetworkSession.is_server():
		mode = "hosting"
	elif NetworkSession.is_client():
		mode = "client, ping %d ms" % int(NetworkSession.get_rtt_ms())
	var alive := 0
	for pawn: Pawn in _readouts:
		if is_instance_valid(pawn) and not pawn.is_dead():
			alive += 1
	var pawn := GameMode.possession_coordinator.get_pawn_of() if GameMode.possession_coordinator else null
	var lines := PackedStringArray()
	lines.append("%s    %d fps" % [mode, Engine.get_frames_per_second()])
	if pawn:
		lines.append("HP %d%s    speed %.1f m/s" % [int(pawn.get_health()), "  (dead: reviving)" if pawn.is_dead() else "", Vector2(pawn.velocity.x, pawn.velocity.z).length()])
	lines.append("goblins %d    kills %d    deaths %d" % [alive, _kills, _deaths])
	lines.append("WASD, Shift sprint, Space jump, Alt dash, left mouse swing    R: new wave    Tab: possess a goblin    F3: readouts    Esc: free the mouse")
	return "\n".join(lines)


func _read_command_line() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--ping="):
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
