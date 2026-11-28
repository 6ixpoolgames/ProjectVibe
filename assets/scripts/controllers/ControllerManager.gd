# Written by Claude (claude-opus-5-5), 2026-11-07. History: controllers/CHANGELOG.md.
## Picks whose input a pawn follows, and holds that input and whether a player has the pawn.
##
## A part on the pawn, added by PawnInitializer. This machine's player controller is in charge when it has the pawn; nobody is when a
## player elsewhere has it (the input arrives over the network); otherwise the AI's controller is ([member ai_controller], from the
## AIManager), so it takes over the moment a player lets go. The pawn calls [method tick_input] once per tick, which asks the controller
## in charge and writes its command into the input; controllers never write to the pawn themselves. While the pawn owns a tag
## [member input_blocked_by] matches (status.dead by default), or nobody here is in charge, the input is cleared (pawn spec 16.4).
## [br]
## The input rolls back (the pawn's TickStateComponent lists it, with [member previous_held_actions] as state). The server's checks on
## a client's input are here too ([method sanitize_network_input]), as the NetworkEntity's input_owner. Only PlayerController calls
## [method attach_player] and [method detach_player]. Use [code]get_controller_in_charge()[/code] (a ControllerBase, or null) and
## [code]was_action_pressed(&"jump")[/code] (held this tick, not last tick). Design: pawn spec 6.4, 8.17, 16.4.
class_name ControllerManager
extends Node

## Sent when a different controller is in charge, or none. The controller is null when nobody here is. It's sent at the end of the
## frame, once, with the final answer: possessing takes two steps (a player has it, then their controller attaches), and listeners
## shouldn't see "nobody" in between.
signal controller_changed(controller: ControllerBase)
## Sent when a player takes this pawn, or lets it go.
signal possession_changed(pawn: Pawn, has_player: bool)

## Whether a player may take control of this pawn. Turn it off on pawns players should never control. To change it where the
## ControllerManager comes from the game's defaults, add parts/ControllerManager.tscn to the pawn scene first.
@export var possessable := true
## While the pawn owns tags this matches, its input is cleared (nothing held, no direction; the look stays), whoever is in charge: the
## pattern of Unreal GAS's blocking tags. By default any of status.dead; add status.stunned or a cutscene's tag. Empty: never blocked.
@export var input_blocked_by: TagQuery = TagQuery.make([], [Tags.STATUS.DEAD], [])

## On the server: when a client's input goes missing, the last one repeats in full for this many ticks. -1 uses NetworkSession's
## setting of the same name, which is the game-wide rule. Set a number only for a pawn that needs its own.
@export_range(-1, 60, 1, "or_greater") var missing_input_hold_ticks := -1
## Then its direction fades to nothing over this many ticks. -1 uses NetworkSession's setting.
@export_range(-1, 60, 1, "or_greater") var missing_input_fade_ticks := -1

# This tick's input, as plain data. Listed in the pawn's TickState, so it goes over the network and rolls back.
var move_input := Vector3.ZERO ## the direction to go, in world space, up to length 1
var held_actions := 0 ## which named actions are held this tick, as bits from InputActions
var look_yaw := 0.0 ## where the player is looking, which is often not where the pawn is facing
var look_pitch := 0.0 ## where the player is looking, up and down
## How many ticks behind its own tick the controller was drawing other pawns, for lag compensation. The server limits it to what's
## believable (LagCompensation).
var view_ticks_behind := 0.0
## Last tick's held_actions, so a press can be told from a hold. In the TickState's state list, so a correction fixes it.
var previous_held_actions := 0

## The pawn this manager belongs to, or null if its parent isn't one.
var pawn: Pawn = null
## The AI's controller, from the pawn's AIManager ([member AIManager.controller]). Null if the pawn has no AI or its AI has none.
var ai_controller: ControllerBase:
	get:
		var ai := pawn.ai if pawn else null
		return ai.controller if is_instance_valid(ai) else null
## This machine's player controller while it has the pawn, or null.
var player_controller: ControllerBase = null

var _last_in_charge: ControllerBase = null
var _check_queued := false
var _has_player := false
# is_input_blocked's answer, kept until the owned tags, the query or the tag registry change: it's asked every tick.
var _blocked := false
var _blocked_tags_version := -1
var _blocked_query: TagQuery = null
var _blocked_query_version := -1
var _blocked_generation := -1
var _missing_input_ticks := 0 # on the server: how many ticks in a row a client's input has been missing
var _input_missing_this_tick := false


func _init() -> void:
	# Nothing here runs per frame: the pawn calls tick_input() on its tick.
	set_process(false)
	set_physics_process(false)


func _enter_tree() -> void:
	pawn = get_parent() as Pawn # null when the parent isn't a Pawn
	# It tells its pawn it's here, before any part's _ready; the first ControllerManager a pawn has is the one it uses.
	if pawn and not is_instance_valid(pawn.controller_manager):
		pawn.controller_manager = self
	if pawn == null:
		push_warning("ControllerManager: its parent isn't a Pawn, so it never puts anyone in charge.")


func _ready() -> void:
	possession_changed.connect(_on_possession_changed)
	# The server's checks on a client's input come here, not to the pawn, and so does a change of who runs the pawn.
	if pawn:
		for child in pawn.get_children():
			if child is NetworkEntity:
				child.input_owner = self
				child.role_changed.connect(_on_network_role_changed)
	_last_in_charge = get_controller_in_charge()


## Who the pawn follows right now, or null. See the rule in the class description.
func get_controller_in_charge() -> ControllerBase:
	if pawn == null:
		return null
	if is_instance_valid(player_controller):
		return player_controller
	if _has_player:
		return null # a player on another machine has it, so its input comes over the network
	return ai_controller if is_instance_valid(ai_controller) else null


## The path follower the controller in charge walks the pawn along now, or null (pawn spec 16.7).
func get_path_follower() -> PathFollower:
	var controller := get_controller_in_charge()
	return controller.get_path_follower() if controller else null


## This tick's input from the controller in charge, or null when nobody here is.
func take_input_command(tick: int) -> InputCommand:
	var controller := get_controller_in_charge()
	return controller.take_input_command(tick) if controller else null


# --- The input ---


## The pawn calls this once per tick, in its input phase: asks the controller in charge and writes its command into the input. It's
## cleared instead while blocked ([member input_blocked_by]), on every machine, and with nobody in charge (no controller here, no player
## elsewhere). A script that writes input later in the same phase wins.
func tick_input(tick: int) -> void:
	var check_started := PerfScopes.begin_detailed() if PerfScopes.detailed else 0 # timed for diagnostics (PerfScopes)
	var blocked := is_input_blocked()
	if check_started != 0:
		PerfScopes.end(&"pawn.input.blocked_check", check_started)
	if blocked:
		clear_input()
		return
	if not decides_own_input():
		return
	var command := take_input_command(tick)
	if command:
		apply_input(command)
	elif not _has_player:
		clear_input() # nobody in charge: the last input doesn't repeat (a player elsewhere sends theirs over the network)


## True while the pawn owns a tag [member input_blocked_by] matches, such as status.dead.
func is_input_blocked() -> bool:
	var query := input_blocked_by
	var owned: OwnedTags = pawn.owned_tags if pawn else null
	if query == null or owned == null:
		return false
	if owned.version != _blocked_tags_version or query != _blocked_query or query.version != _blocked_query_version \
			or TagRegistry.generation != _blocked_generation:
		_blocked_tags_version = owned.version
		_blocked_query = query
		_blocked_query_version = query.version
		_blocked_generation = TagRegistry.generation
		_blocked = not query.is_empty() and query.matches(owned)
	return _blocked


## Writes a command into this tick's input.
func apply_input(command: InputCommand) -> void:
	move_input = command.move
	look_yaw = command.look_yaw
	look_pitch = command.look_pitch
	held_actions = command.held_actions
	view_ticks_behind = command.view_ticks_behind


## True if a named action is held this tick.
func is_action_held(action: StringName) -> bool:
	return held_actions & InputActions.mask_of(action) != 0


## True if a named action is held this tick but wasn't last tick: a press.
func was_action_pressed(action: StringName) -> bool:
	var bit := InputActions.mask_of(action)
	return held_actions & bit != 0 and previous_held_actions & bit == 0


## Nothing pressed, no direction. Keeps where it looks. Done while the input is blocked, with nobody in charge, and when a player lets
## go.
func clear_input() -> void:
	move_input = Vector3.ZERO
	held_actions = 0


## Once this tick's input has been read: what was held, so the next tick can tell a press from a hold; and a tick with real input
## ends a run of missing ones. The pawn calls this in its simulate step, after its abilities, before it moves.
func finish_tick() -> void:
	previous_held_actions = held_actions
	if not _input_missing_this_tick:
		_missing_input_ticks = 0
	_input_missing_this_tick = false


## True where this pawn's input is decided: offline, its owner's machine, or the server for a pawn nobody owns. False on the server
## for a client's pawn, whose input arrives over the network, and on a client for anyone else's pawn.
func decides_own_input() -> bool:
	var entity := pawn.get_network_entity() if pawn else null
	return entity == null or entity.is_local or (entity.role == NetworkEntity.Role.AUTHORITY and entity.owner_peer == 0)


# --- Who has the pawn ---


## True if a player controls this pawn. On a client, that's any player, not only this machine's.
func has_player() -> bool:
	return _has_player


## PossessionCoordinator tells the pawn's manager. Nothing else should call this.
func set_has_player(value: bool) -> void:
	if _has_player == value:
		return
	_has_player = value
	# With nobody driving it, a pawn stands idle. The last tick's input would otherwise repeat forever. From the next
	# tick the AI controller is in charge, if there is one.
	if not value and pawn and pawn.is_simulated_here():
		clear_input()
	possession_changed.emit(pawn, value)


# --- The server's checks on a client's input (NetworkEntity calls these, as this pawn's input_owner) ---


## On the server: a client's input is never trusted. Wrong types are replaced and direction is limited to full speed. Keys are as the
## pawn's TickState lists them ("ControllerManager:move_input"); plain names work too.
func sanitize_network_input(values: Dictionary) -> Dictionary:
	var clean := values.duplicate()
	var key := func(field: String) -> String:
		var full := "%s:%s" % [name, field]
		return full if values.has(full) or not values.has(field) else field
	var wanted: Variant = values.get(key.call("move_input"), Vector3.ZERO)
	clean[key.call("move_input")] = wanted.limit_length(1.0) if wanted is Vector3 and wanted.is_finite() else Vector3.ZERO
	# Bits for actions that aren't listed are thrown away.
	var held: Variant = values.get(key.call("held_actions"), 0)
	clean[key.call("held_actions")] = held & InputActions.all_listed_mask() if held is int else 0
	# A number of ticks, never negative. LagCompensation limits how far back it really goes.
	var behind: Variant = values.get(key.call("view_ticks_behind"), 0.0)
	clean[key.call("view_ticks_behind")] = maxf(behind, 0.0) if behind is float and is_finite(behind) else 0.0
	for angle: String in ["look_yaw", "look_pitch"]:
		var value: Variant = values.get(key.call(angle), 0.0)
		clean[key.call(angle)] = value if value is float and is_finite(value) else 0.0
	return clean


## On the server: this tick's input never arrived, so the last one repeats (a held direction repeats; a press doesn't). After
## missing_input_hold_ticks the direction fades out over missing_input_fade_ticks. Held actions are left alone.
func _network_input_missing() -> void:
	_input_missing_this_tick = true
	_missing_input_ticks += 1
	# -1 means NetworkSession's rule. With no session at all, 3 and 6, the same as its defaults.
	# REFACTOR: 3 and 6 copy NetworkSession's defaults by hand; shared constants would keep them from drifting apart (one place to
	# change). See CHANGELOG.md.
	var session: Node = get_node_or_null("/root/NetworkSession")
	var hold: int = missing_input_hold_ticks if missing_input_hold_ticks >= 0 else (session.missing_input_hold_ticks if session else 3)
	var fade: int = missing_input_fade_ticks if missing_input_fade_ticks >= 0 else (session.missing_input_fade_ticks if session else 6)
	# Written for 60 ticks a second (scaling spec step 6).
	hold = TickDriver.ticks_at_rate(hold)
	fade = TickDriver.ticks_at_rate(fade)
	if _missing_input_ticks <= hold:
		return
	if fade <= 0:
		move_input = Vector3.ZERO
	else:
		# A full-length direction reaches zero in "fade" ticks. A shorter one gets there sooner.
		move_input = move_input.move_toward(Vector3.ZERO, 1.0 / fade)


## PlayerController calls this when it takes the pawn.
func attach_player(controller: ControllerBase) -> void:
	player_controller = controller
	_drop_paths()
	_refresh()


## PlayerController calls this when it lets go. A controller that isn't the attached one changes nothing.
func detach_player(controller: ControllerBase) -> void:
	if player_controller == controller:
		_drop_paths()
		player_controller = null
		_refresh()


# The server runs the pawn now (no player owns it): it stops doing what the last player's final input said.
func _on_network_role_changed(entity: NetworkEntity) -> void:
	if entity.role == NetworkEntity.Role.AUTHORITY and entity.owner_peer == 0:
		clear_input()


func _on_possession_changed(_pawn: Pawn, _player_has_it: bool) -> void:
	_drop_paths()
	_refresh()


# Each controller follows its own path. When charge changes hands, both drop theirs straight away, not at the end of the frame like
# controller_changed, so neither walks on from a stale path once it's back in charge.
func _drop_paths() -> void:
	if is_instance_valid(player_controller):
		player_controller.drop_path()
	var ai := ai_controller
	if is_instance_valid(ai):
		ai.drop_path()


## Checks at the end of the frame whether who's in charge changed. Several changes in one frame give one check.
func _refresh() -> void:
	if not _check_queued:
		_check_queued = true
		# Deferred, so several changes in one frame give one check.
		_send_if_changed.call_deferred()


func _send_if_changed() -> void:
	_check_queued = false
	var now := get_controller_in_charge()
	if now != _last_in_charge:
		_last_in_charge = now
		controller_changed.emit(now)
