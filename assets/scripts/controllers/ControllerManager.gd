## Written by Claude (claude-opus-5-5), 2026-11-07: picks whose input a pawn follows. Pawn spec section 6.4. A part on the pawn, added
## by PawnInitializer, with the pawn's AIController as its child.
##
## The rule is fixed and simple:
##   - A player's controller is attached here (this machine's player has the pawn): that controller is in charge.
##   - A player elsewhere has the pawn: nobody here is in charge, because the input arrives over the network.
##   - Nobody has it: the AI controller is in charge. That's how the AI takes over the moment a player lets go.
##
## The pawn asks take_input_command() once per tick, in its input phase. Controllers never write to the pawn themselves.
##
## How to use it:
##   pawn.controller_manager.get_controller_in_charge()   # a ControllerBase, or null
##   pawn.controller_manager.ai_controller                 # the AI's hands
## PlayerController calls attach_player and detach_player when it takes or lets go of a pawn. Nothing else should.
##
## Claude 2026-11-16 (pawn M4): it also holds the pawn's input and whether a player has it, the owner's call (they were on Pawn):
##   move_input, held_actions, look_yaw, look_pitch, view_ticks_behind   this tick's input, written from an InputCommand (apply_input)
##   previous_held_actions                                               last tick's held_actions, so a press can be told from a hold
##   is_action_held(action), was_action_pressed(action)                   held this tick; held this tick but not last tick
##   has_player(), set_has_player(value), possession_changed              a player has the pawn (PossessionCoordinator sets it)
##   sanitize_network_input, _network_input_missing                       the server's checks on a client's input (NetworkEntity
##                                                                        calls them here: this registers as its input_owner)
## The input rolls back: the pawn's TickStateComponent lists "ControllerManager:move_input" and the others. A pawn without a
## ControllerManager has no input and no player: it stands still, and can't be possessed.
##
## What happens in odd cases (all checked in tests/controller_manager_selftest.gd):
##   - Its parent isn't a Pawn: it warns, and nobody is ever in charge.
##   - No AIController child: an unpossessed pawn has nobody in charge, and its input stays as it is.
##   - A player's controller is freed while attached: it's ignored, as if it had let go.
##   - Claude 2026-11-08: control changes hands while the pawn is following a path: the path is dropped.
class_name ControllerManager
extends Node

## Sent when a different controller is in charge, or none. The controller is null when nobody here is. It's sent at the end of the
## frame, once, with the final answer: possessing takes two steps (a player has it, then their controller attaches), and listeners
## shouldn't see "nobody" in between.
signal controller_changed(controller: ControllerBase)
## Sent when a player takes this pawn, or lets it go. Claude 2026-11-16 (pawn M4): moved here from Pawn.
signal possession_changed(pawn: Pawn, has_player: bool)

## On the server: when a client's input goes missing, the last one repeats in full for this many ticks. -1 uses NetworkSession's
## setting of the same name, which is the game-wide rule. Set a number only for a pawn that needs its own. Claude 2026-11-16 (pawn M4): moved from Pawn.
@export_range(-1, 60, 1, "or_greater") var missing_input_hold_ticks := -1
## Then its direction fades to nothing over this many ticks. -1 uses NetworkSession's setting.
@export_range(-1, 60, 1, "or_greater") var missing_input_fade_ticks := -1

# This tick's input, as plain data. Listed in the pawn's TickState, so it goes over the network and rolls back. Claude 2026-11-16 (pawn M4): moved from Pawn.
var move_input := Vector3.ZERO ## the direction to go, in world space, up to length 1
var held_actions := 0 ## which named actions are held this tick, as bits from InputActions
var look_yaw := 0.0 ## where the player is looking, which is often not where the pawn is facing
var look_pitch := 0.0
## How many ticks behind its own tick the controller was drawing other pawns, for lag compensation. The server limits it to what's
## believable (LagCompensation).
var view_ticks_behind := 0.0
## Last tick's held_actions, so a press can be told from a hold. In the TickState's state list, so a correction fixes it.
var previous_held_actions := 0

## The pawn this manager belongs to, or null if its parent isn't one.
var pawn: Pawn = null
## The AI's controller: the first ControllerBase child. Null if there's none.
var ai_controller: ControllerBase = null
## This machine's player controller while it has the pawn, or null.
var player_controller: ControllerBase = null

var _last_in_charge: ControllerBase = null
var _check_queued := false
var _has_player := false # Claude 2026-11-16 (pawn M4): moved from Pawn
var _missing_input_ticks := 0 # on the server: how many ticks in a row a client's input has been missing
var _input_missing_this_tick := false


func _init() -> void:
	# GDScript note: nothing here runs per frame. The pawn calls take_input_command() on its tick.
	set_process(false)
	set_physics_process(false)


func _enter_tree() -> void:
	pawn = get_parent() as Pawn # GDScript note: "as" gives null when the parent isn't a Pawn, rather than an error
	if pawn == null:
		push_warning("ControllerManager: its parent isn't a Pawn, so it never puts anyone in charge.")


func _ready() -> void:
	# Claude 2026-11-16 (pawn M3): the AI's hands let go when the pawn dies: this listens for it now, where Pawn._die used to do it.
	var abilities := _sibling_ability_manager()
	if abilities:
		abilities.died.connect(func(_pawn: Pawn, _hit: HitInfo) -> void:
			var hands := ai_controller as AIController
			if hands:
				hands.release_all())
	for child in get_children():
		if child is ControllerBase:
			ai_controller = child
			ai_controller.pawn = pawn
			break
	possession_changed.connect(_on_possession_changed) # Claude 2026-11-16 (pawn M4): the signal is this manager's own now
	# Claude 2026-11-16 (pawn M4): the server's checks on a client's input come here, not to the pawn.
	if pawn:
		for child in pawn.get_children():
			if child is NetworkEntity:
				child.input_owner = self
	_last_in_charge = get_controller_in_charge()


## Who the pawn follows right now, or null. See the rule at the top.
func get_controller_in_charge() -> ControllerBase:
	if pawn == null:
		return null
	if is_instance_valid(player_controller):
		return player_controller
	if _has_player:
		return null # a player on another machine has it, so its input comes over the network
	return ai_controller if is_instance_valid(ai_controller) else null


## This tick's input from the controller in charge, or null when nobody here is.
func take_input_command(tick: int) -> InputCommand:
	var controller := get_controller_in_charge()
	return controller.take_input_command(tick) if controller else null


# --- The input (Claude 2026-11-16 (pawn M4): moved here from Pawn) ---


## The pawn calls this once per tick, in its input phase: where this pawn's input is decided here, asks the controller in charge and
## writes its command into the input. A script that writes input itself, such as a test brain, can still do so later in the same phase
## and win.
func tick_input(tick: int) -> void:
	if not decides_own_input():
		return
	var command := take_input_command(tick)
	if command:
		apply_input(command)


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


## Nothing pressed, no direction. Keeps where it looks. The pawn calls this when it dies, or when nobody drives it any more.
func clear_input() -> void:
	move_input = Vector3.ZERO
	held_actions = 0


## The end of every tick: what was held this tick, so the next tick can tell a press from a hold; and a tick with real input ends a
## run of missing ones. The pawn calls this from its own end of tick.
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


# --- Who has the pawn (Claude 2026-11-16 (pawn M4): moved here from Pawn) ---


## True if a player controls this pawn. On a client, that's any player, not only this machine's.
func has_player() -> bool:
	return _has_player


## PossessionCoordinator tells the pawn's manager. Nothing else should call this.
func set_has_player(value: bool) -> void:
	if _has_player == value:
		return
	_has_player = value
	# Claude 2026-11-07: with nobody driving it, a pawn stands idle. The last tick's input would otherwise repeat forever. From the next
	# tick the AI controller is in charge, if there is one.
	if not value and pawn and pawn.is_simulated_here():
		clear_input()
	possession_changed.emit(pawn, value)


# --- The server's checks on a client's input (NetworkEntity calls these, as this pawn's input_owner) ---


## On the server: a client's input is never trusted. Wrong types are replaced, and direction is limited to full speed. The values are
## keyed as the pawn's TickState lists them ("ControllerManager:move_input"); plain names ("move_input") work too, for scripts and
## tests.
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


## On the server: this tick's input never arrived, so the last one repeats. A held direction repeats fine, and a press doesn't, since a
## repeated hold isn't "newly held". After missing_input_hold_ticks, the direction fades out over missing_input_fade_ticks. Held actions
## are left alone, so a key still held when input comes back doesn't count as a new press.
func _network_input_missing() -> void:
	_input_missing_this_tick = true
	_missing_input_ticks += 1
	# -1 means NetworkSession's rule. With no session at all, 3 and 6, the same as its defaults.
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
	_stop_path()
	_refresh()


## PlayerController calls this when it lets go. A controller that isn't the attached one changes nothing.
func detach_player(controller: ControllerBase) -> void:
	if player_controller == controller:
		player_controller = null
		_stop_path()
		_refresh()


func _on_possession_changed(_pawn: Pawn, _player_has_it: bool) -> void: # Claude 2026-11-16 (pawn M4): renamed, _has_player is this class's own now
	_stop_path()
	_refresh()


# Claude 2026-11-08: a path belongs to whoever asked for it. When someone else takes charge, it's dropped straight away, not at
# the end of the frame like controller_changed, so the AI never walks the rest of a player's click, or the other way round.
func _stop_path() -> void:
	if pawn and pawn.navigation_manager:
		pawn.navigation_manager.stop()


## Checks at the end of the frame whether who's in charge changed. Several changes in one frame give one check.
func _refresh() -> void:
	if not _check_queued:
		_check_queued = true
		# GDScript note: call_deferred runs the function once the current frame's work is done.
		_send_if_changed.call_deferred()


func _send_if_changed() -> void:
	_check_queued = false
	var now := get_controller_in_charge()
	if now != _last_in_charge:
		_last_in_charge = now
		controller_changed.emit(now)

# Claude 2026-11-16 (pawn M3): the pawn's AbilityManager, a sibling, found at _ready (every part is in the pawn by then), or null.
func _sibling_ability_manager() -> AbilityManager:
	if pawn == null:
		return null
	for child in pawn.get_children():
		if child is AbilityManager:
			return child
	return null
