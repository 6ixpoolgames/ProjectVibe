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

## The pawn this manager belongs to, or null if its parent isn't one.
var pawn: Pawn = null
## The AI's controller: the first ControllerBase child. Null if there's none.
var ai_controller: ControllerBase = null
## This machine's player controller while it has the pawn, or null.
var player_controller: ControllerBase = null

var _last_in_charge: ControllerBase = null
var _check_queued := false


func _init() -> void:
	# GDScript note: nothing here runs per frame. The pawn calls take_input_command() on its tick.
	set_process(false)
	set_physics_process(false)


func _enter_tree() -> void:
	pawn = get_parent() as Pawn # GDScript note: "as" gives null when the parent isn't a Pawn, rather than an error
	if pawn == null:
		push_warning("ControllerManager: its parent isn't a Pawn, so it never puts anyone in charge.")


func _ready() -> void:
	for child in get_children():
		if child is ControllerBase:
			ai_controller = child
			ai_controller.pawn = pawn
			break
	if pawn:
		pawn.possession_changed.connect(_on_possession_changed)
	_last_in_charge = get_controller_in_charge()


func _exit_tree() -> void:
	if pawn and pawn.possession_changed.is_connected(_on_possession_changed):
		pawn.possession_changed.disconnect(_on_possession_changed)


## Who the pawn follows right now, or null. See the rule at the top.
func get_controller_in_charge() -> ControllerBase:
	if pawn == null:
		return null
	if is_instance_valid(player_controller):
		return player_controller
	if pawn.has_player():
		return null # a player on another machine has it, so its input comes over the network
	return ai_controller if is_instance_valid(ai_controller) else null


## This tick's input from the controller in charge, or null when nobody here is. The pawn calls this once per tick.
func take_input_command(tick: int) -> InputCommand:
	var controller := get_controller_in_charge()
	return controller.take_input_command(tick) if controller else null


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


func _on_possession_changed(_pawn: Pawn, _has_player: bool) -> void:
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
