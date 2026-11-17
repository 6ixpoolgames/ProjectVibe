# Written by Claude (claude-opus-5-5), 2026-11-07. History: game_mode/CHANGELOG.md.
## Who controls which pawn: players possess and let go of pawns through here.
##
## A module of GameMode (GameMode.possession_coordinator). It creates this machine's PlayerController at the start, which lasts the
## whole game with or without a pawn. The possessable flag on the pawn's ControllerManager is the check. In multiplayer the server
## decides and a client's call is only a request; a possessed pawn's owner_peer is its player (0 on letting go, so the server runs
## it). The pawn's ControllerManager hears of it through possession_changed and its AIController takes over. Respawning or removing a
## pawn belongs to the game, which can listen to [signal released].
## [codeblock]
## GameMode.possession_coordinator.possess(pawn)            # offline, or a client asking the server
## GameMode.possession_coordinator.possess_for(peer, pawn)  # server: gives this player this pawn
## GameMode.possession_coordinator.spectate()               # lets go and flies a FreeFlyCamera; possessing stops it
## [/codeblock]
## Spectating is local: only this machine knows its player is spectating, and the spectator is a FreeFlyCamera, not a Pawn.
## Design: pawn spec 6.2.
class_name PossessionCoordinator
extends GameModeModule

## A player has a pawn now. On a client, this fires for every player, not only this one.
signal possessed(peer: int, pawn: Pawn)
## A player has let go of a pawn, or lost it.
signal released(peer: int, pawn: Pawn)
## A request was turned down, on the machine that decided.
signal refused(peer: int, pawn: Pawn, reason: String)
## This machine's player started or stopped spectating.
signal spectating_changed(spectating: bool)

## A project setting: a scene to use as the PlayerController, so a game can have its own.
const CONTROLLER_SCENE_SETTING := "project_base/game_mode/player_controller_scene"
## How offline play refers to its one player, since it has no network peer number.
const OFFLINE_PEER := -1
## The world channel the server tells clients who has which pawn on.
const CHANNEL := "possession"
## The client channel a client asks the server for a pawn on.
const REQUEST_CHANNEL := "possession_request"
# What's in a possession message: one player's pawn, or everyone's (for a late joiner).
const MESSAGE_ONE := 1
const MESSAGE_ALL := 2

## This machine's controller. A dedicated server build has none.
var controller: PlayerController = null

var _by_peer := {} # peer -> Pawn
var _session: Node = null
var _waiting := {} # entity id -> peer, for a client told about a pawn it hasn't been told to spawn yet
var _spectating := false # this machine's player is flying the spectator


func _init() -> void:
	set_process(false)
	set_physics_process(false)


func _on_module_added(game_mode: GameModeSingleton) -> void:
	game_mode.possession_coordinator = self
	_session = get_node_or_null("/root/NetworkSession")
	if _session:
		_session.register_world_channel(CHANNEL, _on_network_message, _catch_up_message)
		_session.entity_spawned.connect(_on_entity_spawned)
		_session.register_client_channel(REQUEST_CHANNEL, _on_request)
		_session.player_leaving.connect(_on_player_leaving)
	if not OS.has_feature("dedicated_server"):
		controller = _make_controller()
		add_child(controller)


func _on_module_removed(game_mode: GameModeSingleton) -> void:
	game_mode.possession_coordinator = null
	if _session:
		_session.unregister_world_channel(CHANNEL)
		_session.entity_spawned.disconnect(_on_entity_spawned)
		_session.unregister_client_channel(REQUEST_CHANNEL)
		_session.player_leaving.disconnect(_on_player_leaving)
	for peer: int in _by_peer.keys():
		_clear(peer)


# --- Things other scripts can call ---


## Takes a pawn for this machine's player. Offline it happens now. On a client it's a request, so it may be turned down.
## On a server with a local player, that player is peer 1. Returns false if it's refused straight away.
func possess(pawn: Pawn) -> bool:
	if _is_client():
		var entity := _entity_of(pawn)
		if entity == null:
			refused.emit(_local_peer(), pawn, "it isn't a networked entity")
			return false
		_ask_server(entity.entity_id)
		return true
	return possess_for(_local_peer(), pawn)


## Lets go of this machine's pawn. On a client it's a request.
func release() -> void:
	if _is_client():
		_ask_server(0)
	else:
		release_for(_local_peer())


## Lets go of this machine's pawn, if it has one (its AI controller takes over), and flies the spectator, starting where the camera
## is. On a client, letting go is a request, but the flying starts at once. False with no PlayerController (a
## dedicated server).
func spectate() -> bool:
	if controller == null:
		return false
	if _spectating:
		return true
	if get_pawn_of() != null:
		release()
	_spectating = true
	controller.start_spectating()
	spectating_changed.emit(true)
	return true


## Stops flying the spectator. The camera holds where it is until this machine's player has a pawn. Possessing one
## stops spectating by itself, so this is only needed to stop without one.
func stop_spectating() -> void:
	if not _spectating:
		return
	_spectating = false
	if controller:
		controller.stop_spectating()
	spectating_changed.emit(false)


## True while this machine's player is flying the spectator.
func is_spectating() -> bool:
	return _spectating


## Server or offline: gives this player this pawn, and takes away the one they had. False means refused.
func possess_for(peer: int, pawn: Pawn) -> bool:
	if _is_client():
		return false
	var reason := _why_not(peer, pawn)
	if reason != "":
		refused.emit(peer, pawn, reason)
		return false
	if get_pawn_of(peer) == pawn:
		return true
	release_for(peer)
	var entity := _entity_of(pawn)
	if _is_server() and entity != null:
		_session.set_entity_owner(entity.entity_id, peer)
	_assign(peer, pawn)
	_tell_clients(peer, pawn)
	return true


## Server or offline: this player lets go. The pawn stays, with nobody driving it unless something else takes over.
func release_for(peer: int) -> void:
	if _is_client():
		return
	var pawn: Pawn = _by_peer.get(peer)
	if pawn == null:
		return
	var entity := _entity_of(pawn)
	_clear(peer)
	if _is_server() and is_instance_valid(entity):
		_session.set_entity_owner(entity.entity_id, 0)
	_tell_clients(peer, null)


## Server or offline: whoever has this pawn lets go of it. This is the only way to evict someone. Turning possessable
## off doesn't: it only stops new possessions.
func release_pawn(pawn: Pawn) -> void:
	var peer := get_peer_of(pawn)
	if peer != 0:
		release_for(peer)


## Which pawn a player has. With no peer given, this machine's player.
func get_pawn_of(peer: int = 0) -> Pawn:
	var key := peer if peer != 0 else _local_peer()
	var pawn: Pawn = _by_peer.get(key)
	return pawn if is_instance_valid(pawn) else null


## Which player has this pawn, or 0 if none does.
func get_peer_of(pawn: Pawn) -> int:
	for peer: int in _by_peer:
		if _by_peer[peer] == pawn:
			return peer
	return 0


# --- Inside ---


func _make_controller() -> PlayerController:
	var path: String = ProjectSettings.get_setting(CONTROLLER_SCENE_SETTING, "")
	if path != "" and ResourceLoader.exists(path):
		var scene: Variant = load(path)
		var made: Variant = scene.instantiate() if scene is PackedScene else null
		if made is PlayerController:
			return made
		push_warning("PossessionCoordinator: '%s' isn't a PlayerController scene, so this uses the default." % path)
		if made is Node:
			made.free()
	var default_controller := PlayerController.new()
	default_controller.name = "PlayerController"
	return default_controller


func _why_not(peer: int, pawn: Pawn) -> String:
	if not is_instance_valid(pawn):
		return "there's no such pawn"
	# Refused here, before anything changes, rather than stopping on an error halfway.
	if pawn.controller_manager == null:
		return "this pawn has no ControllerManager, so a player's input couldn't reach it"
	if not pawn.controller_manager.possessable:
		return "this pawn can't be possessed"
	var holder := get_peer_of(pawn)
	if holder != 0 and holder != peer:
		return "another player has this pawn"
	return ""


func _assign(peer: int, pawn: Pawn) -> void:
	_by_peer[peer] = pawn
	if pawn.controller_manager: # a pawn built without one, as _clear allows for
		pawn.controller_manager.set_has_player(true)
	if not pawn.tree_exiting.is_connected(_on_pawn_leaving):
		pawn.tree_exiting.connect(_on_pawn_leaving.bind(pawn), CONNECT_ONE_SHOT)
	if peer == _local_peer() and controller:
		controller.take_pawn(pawn) # this stops the controller's spectating too
		if _spectating:
			_spectating = false
			spectating_changed.emit(false)
	possessed.emit(peer, pawn)


func _clear(peer: int) -> void:
	var pawn: Pawn = _by_peer.get(peer)
	_by_peer.erase(peer)
	if peer == _local_peer() and controller:
		controller.take_pawn(null)
	if is_instance_valid(pawn):
		if pawn.controller_manager:
			pawn.controller_manager.set_has_player(false)
		if pawn.tree_exiting.is_connected(_on_pawn_leaving):
			pawn.tree_exiting.disconnect(_on_pawn_leaving)
	released.emit(peer, pawn if is_instance_valid(pawn) else null)


func _on_pawn_leaving(pawn: Pawn) -> void:
	for peer: int in _by_peer.keys():
		if _by_peer[peer] == pawn:
			_clear(peer)
			if _is_server():
				_tell_clients(peer, null)


# --- Multiplayer ---


func _is_client() -> bool:
	return _session != null and _session.is_client()


func _is_server() -> bool:
	return _session != null and _session.is_server()


func _local_peer() -> int:
	if _session != null and _session.is_connected_to_session():
		return _session.get_local_peer()
	return OFFLINE_PEER


func _entity_of(pawn: Pawn) -> NetworkEntity:
	if is_instance_valid(pawn) and pawn.has_meta(&"network_entity"):
		return pawn.get_meta(&"network_entity")
	return null


func _tell_clients(peer: int, pawn: Pawn) -> void:
	if _is_server():
		var entity := _entity_of(pawn)
		_session.send_world_message(CHANNEL, _message_one(peer, entity.entity_id if entity else 0))


func _message_one(peer: int, entity_id: int) -> PackedByteArray:
	var buffer := StreamPeerBuffer.new()
	buffer.put_u8(MESSAGE_ONE)
	buffer.put_32(peer)
	buffer.put_u32(entity_id)
	return buffer.data_array


## Server: what a late joiner needs to know.
func _catch_up_message() -> PackedByteArray:
	var buffer := StreamPeerBuffer.new()
	buffer.put_u8(MESSAGE_ALL)
	var pairs := []
	for peer: int in _by_peer:
		var entity := _entity_of(_by_peer[peer])
		if entity:
			pairs.append([peer, entity.entity_id])
	buffer.put_u32(pairs.size())
	for pair: Array in pairs:
		buffer.put_32(pair[0])
		buffer.put_u32(pair[1])
	return buffer.data_array


## Client: the server says who has what.
func _on_network_message(bytes: PackedByteArray) -> void:
	if not _is_client() or bytes.size() < 5:
		return
	var buffer := StreamPeerBuffer.new()
	buffer.data_array = bytes
	var kind := buffer.get_u8()
	if kind == MESSAGE_ONE and bytes.size() == 9:
		var peer := buffer.get_32()
		_apply_from_server(peer, buffer.get_u32())
	elif kind == MESSAGE_ALL:
		var count := buffer.get_u32()
		if bytes.size() == 5 + count * 8:
			for i in count:
				var peer := buffer.get_32()
				_apply_from_server(peer, buffer.get_u32())


func _apply_from_server(peer: int, entity_id: int) -> void:
	if _by_peer.has(peer):
		_clear(peer)
	# Whatever this peer was waiting to be given is out of date now, so a pawn that spawns here later isn't handed to a peer that has
	# since let go or taken another.
	for waiting_id: int in _waiting.keys():
		if _waiting[waiting_id] == peer:
			_waiting.erase(waiting_id)
	if entity_id == 0:
		return
	var entity: NetworkEntity = _session.get_entity(entity_id)
	if entity == null:
		_waiting[entity_id] = peer # it hasn't spawned here yet
		return
	var pawn := entity.get_parent() as Pawn
	if pawn:
		_assign(peer, pawn)


func _on_entity_spawned(entity: NetworkEntity) -> void:
	if _waiting.has(entity.entity_id):
		var peer: int = _waiting[entity.entity_id]
		_waiting.erase(entity.entity_id)
		var pawn := entity.get_parent() as Pawn
		if pawn:
			_assign(peer, pawn)


## Client: asks the server for a pawn, by id. 0 means let go. The server can say no.
func _ask_server(entity_id: int) -> void:
	var buffer := StreamPeerBuffer.new()
	buffer.put_u32(entity_id)
	_session.send_to_server(REQUEST_CHANNEL, buffer.data_array)


## Server: a client asks for a pawn. A client can send anything, so the size is checked and the usual checks apply.
func _on_request(peer: int, bytes: PackedByteArray) -> void:
	if bytes.size() != 4:
		return
	var buffer := StreamPeerBuffer.new()
	buffer.data_array = bytes
	var entity_id := buffer.get_u32()
	if entity_id == 0:
		release_for(peer)
		return
	var entity: NetworkEntity = _session.get_entity(entity_id)
	var pawn := entity.get_parent() as Pawn if entity else null
	possess_for(peer, pawn)


## Server: a player has gone. Letting go sets the pawn's owner to 0, so NetworkSession doesn't remove it with
## the rest of what they owned. AIActivationManager switches it off if its ground unloads, like any pawn with no player.
func _on_player_leaving(peer: int) -> void:
	release_for(peer)
