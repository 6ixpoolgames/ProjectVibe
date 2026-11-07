## Written by Claude (claude-opus-5-5), 2026-11-04: a small game you can play to feel the multiplayer code.
## Open net_sample.tscn twice. In one window press Host, in the other press Join. WASD to move, Shift to sprint, Space to jump,
## and click to shoot where the mouse points. In a debug build, a panel of keys changes the fake network and switches features
## on and off while you play: see NetTestBench.gd.
## A dedicated server or a scripted start also work, after "--" on the command line:
##   --server            hosts with no player of its own
##   --host              hosts and plays
##   --join=127.0.0.1    joins
##   --ping=100          sets the test bench's fake ping, in milliseconds
extends Node3D

const PORT := 24890
const PAWN_SCENE := preload("res://assets/scenes/samples/net_sample_pawn.tscn")
const SPAWN_POINTS := [Vector3(-4, 0.1, 0), Vector3(4, 0.1, 0), Vector3(0, 0.1, -4), Vector3(0, 0.1, 4)]

@export var wanderers: int = 2

var _session: NetworkSessionSingleton
var _driver: TickDriverSingleton
var _status: Label
var _menu: Control
var _address: LineEdit
var _bench: NetTestBench
var _next_spawn := 0
var _dedicated := false
var _message := ""


func _ready() -> void:
	_session = get_node("/root/NetworkSession")
	_driver = get_node("/root/TickDriver")
	_session.world_root = $Entities
	_session.register_type("pawn", PAWN_SCENE)
	_session.player_connected.connect(_spawn_player)
	_session.joined.connect(func() -> void: _message = "joined")
	_session.refused.connect(_on_refused)
	_session.disconnected.connect(func() -> void: _show_menu("disconnected"))
	NetDebugModule.on(_session).allow_debug_commands = true # only has any effect in a debug build, which is also the only place the bench exists
	_bench = NetTestBench.new()
	add_child(_bench)
	_build_hud()
	_read_command_line()


func _process(_delta: float) -> void:
	_status.text = _status_text()


func _host(with_player: bool) -> void:
	var error := _session.host(PORT)
	if error != OK:
		_show_menu("couldn't host: error %d" % error)
		return
	_dedicated = not with_player
	_menu.hide()
	if with_player:
		_spawn_player(_session.get_local_peer())
	for i in wanderers:
		_session.spawn("pawn", 0, Vector3(-6 + i * 3, 0.1, 7))


func _join(address: String) -> void:
	var error := _session.join(address, PORT)
	if error != OK:
		_show_menu("couldn't join: error %d" % error)
		return
	_menu.hide()
	_message = "connecting"


func _spawn_player(peer: int) -> void:
	_session.spawn("pawn", peer, SPAWN_POINTS[_next_spawn % SPAWN_POINTS.size()])
	_next_spawn += 1


func _on_refused(reason: String) -> void:
	_show_menu("refused: " + reason)


func _show_menu(message: String) -> void:
	_message = message
	if _menu:
		_menu.show()


func _status_text() -> String:
	var lines := PackedStringArray()
	match _session.get_mode():
		NetworkSessionSingleton.Mode.OFFLINE:
			lines.append("offline. %s" % _message)
		NetworkSessionSingleton.Mode.SERVER:
			lines.append("server, tick %d%s" % [_driver.tick, ", no local player" if _dedicated else ""])
		NetworkSessionSingleton.Mode.CLIENT:
			lines.append("client %s, tick %d" % [_message, _driver.tick])
			lines.append("ping %.0f ms, lead %.1f ticks, others drawn %.1f ticks behind" % [_session.get_rtt_ms(), _session.get_lead_ticks(), _session.get_view_ticks_behind()])
			var stats := _session.stats
			lines.append("corrections %d, largest %.2f m, clock resyncs %d" % [stats["corrections"], stats["correction_worst"], stats["resyncs"]])
	for entity: NetworkEntity in _session.get_entities():
		var body: NetSamplePawn = entity.get_parent()
		lines.append("%s%s: health %d" % [body.name, " (you)" if entity.is_local else "", body.health])
	return "\n".join(lines)


func _read_command_line() -> void:
	var settings: Dictionary = {}
	for argument in OS.get_cmdline_user_args():
		var parts := argument.trim_prefix("--").split("=", true, 1)
		settings[parts[0]] = parts[1] if parts.size() > 1 else "true"
	if settings.has("ping") and OS.is_debug_build():
		_bench.set_ping(float(settings["ping"]))
	if settings.has("server"):
		_host(false)
	elif settings.has("host"):
		_host(true)
	elif settings.has("join"):
		_join(settings["join"])


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	_status = Label.new()
	_status.position = Vector2(12, 10)
	layer.add_child(_status)
	var menu := VBoxContainer.new()
	menu.position = Vector2(12, 150)
	layer.add_child(menu)
	_menu = menu
	var host_button := Button.new()
	host_button.text = "Host"
	host_button.pressed.connect(func() -> void: _host(true))
	menu.add_child(host_button)
	_address = LineEdit.new()
	_address.text = "127.0.0.1"
	menu.add_child(_address)
	var join_button := Button.new()
	join_button.text = "Join"
	join_button.pressed.connect(func() -> void: _join(_address.text))
	menu.add_child(join_button)
