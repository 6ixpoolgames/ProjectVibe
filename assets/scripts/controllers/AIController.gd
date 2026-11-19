# Written by Claude (claude-opus-5-5), 2026-11-07. History: controllers/CHANGELOG.md.
## The AI's hands: turns what the AI's behaviours tell it into one InputCommand per tick.
##
## A child of the pawn's ControllerManager, in charge whenever no player has the pawn. It decides nothing: the AI's behaviours (or a
## script or test) tell it what to do, and it builds the same input a player's controller makes. Everything it's told stays until
## changed, except [method press], which lasts one tick. Until [method look_at_point] is called it keeps the pawn's own look.
## [codeblock]
## ai.move_to(point)                        # walks there along a nav path; false if there's no way there
## ai.move_in_direction(Vector3(1, 0, 0))   # keeps walking that way; drops any path
## ai.press(&"jump")                        # held for one tick, so the pawn sees one press
## ai.hold(&"sprint", true)                 # held until hold(&"sprint", false)
## [/codeblock]
## While a player has the pawn but the AI keeps deciding, [method move_to] only remembers the point (and returns true), so it can't
## overwrite the player's path; the walk starts when the AI is in charge again.
## Design: pawn spec 6.3, 10.3.
class_name AIController
extends ControllerBase

## Where its look pitch is measured from: metres above the pawn's feet. Matches a ranged attack's muzzle_height (1.3), so a shot fired
## along the look meets the point looked at.
var look_from_height := 1.3

var _move := Vector3.ZERO
var _look_yaw := 0.0
var _look_pitch := 0.0
var _look_set := false # false: keep the pawn's own look
var _look_node: Node3D = null # look_at_node's node, followed at every input; null: none
var _look_offset := Vector3.ZERO
var _held := 0 # bits from InputActions
var _pressed_once := 0 # bits held for the next command only
# One command, reused every tick so a crowd of AI pawns makes no garbage; the ControllerManager copies it at once.
var _command := InputCommand.new()
# A move_to given while not in charge, started when it's in charge again.
var _waiting_point := Vector3.ZERO
var _has_waiting_point := false


## Walks to this point along a nav path, and stands still once there. Returns false (and stands still) if there's no way there.
## While not in charge it only remembers the point and returns true.
func move_to(point: Vector3) -> bool:
	_move = Vector3.ZERO # once the path ends, it stands
	var navigation := _navigation()
	if navigation == null:
		push_warning("AIController: %s has no NavigationManager, so move_to can't find a way. Check its skip_default_parts." % (String(pawn.name) if pawn else "this pawn")) # String(), so both sides are text
		return false
	if not _is_in_charge():
		_waiting_point = point
		_has_waiting_point = true
		return true
	_has_waiting_point = false
	return navigation.move_to(point)


## True while its own last move_to is under way: following its path (or waiting for nav, PENDING) when in charge, or waiting to
## start it when not. False once it arrives, gives up, or is told to do something else.
func is_following_order() -> bool:
	if _has_waiting_point:
		return true
	var navigation := _navigation()
	return navigation != null and _is_in_charge() and navigation.is_under_way()


## Walks this way, in world space, up to length 1, until told otherwise. Shorter is slower.
func move_in_direction(direction: Vector3) -> void:
	_move = direction.limit_length(1.0)
	_stop_path()


## Stands still. Held actions stay held.
func stop() -> void:
	_move = Vector3.ZERO
	_stop_path()


## Looks at a point in the world. Does nothing without a pawn, since there's nowhere to look from.
func look_at_point(point: Vector3) -> void:
	if pawn == null:
		return
	var offset := point - pawn.global_position
	_look_node = null # a point replaces a node being followed
	if offset.length_squared() < 0.000001:
		return
	# Godot's forward is -Z, so a point straight ahead has yaw 0.
	_look_yaw = atan2(-offset.x, -offset.z)
	_look_pitch = atan2(offset.y - look_from_height, Vector2(offset.x, offset.z).length())
	_look_set = true


## Keeps looking at a node, at offset from its origin, worked out again at every input, until [method stop_looking] or another
## look. For a behaviour that sleeps through a swing. A freed node ends it.
func look_at_node(node: Node3D, offset := Vector3.ZERO) -> void:
	_look_node = node
	_look_offset = offset
	if is_instance_valid(node):
		look_at_point(node.global_position + offset)
		_look_node = node # look_at_point clears it


## Stops looking at anything in particular, and keeps whatever look the pawn already has.
func stop_looking() -> void:
	_look_set = false
	_look_node = null


## True while it's looking at a point it was given. AI sight faces this way then (SightSense).
func is_looking_at_point() -> bool:
	return _look_set


## Holds this action for the next tick only, so the pawn sees one press.
func press(action: StringName) -> void:
	_pressed_once |= InputActions.mask_of(action)


## Holds or lets go of this action, until changed.
func hold(action: StringName, held := true) -> void:
	if held:
		_held |= InputActions.mask_of(action)
	else:
		_held &= ~InputActions.mask_of(action)


## Back to idle: standing still, nothing held. The look direction stays.
func release_all() -> void:
	_move = Vector3.ZERO
	_held = 0
	_pressed_once = 0
	_stop_path()


## This tick's input. Uses up press(), so call it once per tick: ControllerManager does.
func take_input_command(_tick: int) -> InputCommand:
	# While a path from move_to is being followed, the direction comes from it. ControllerManager drops a path
	# when control changes hands, so any path here is this controller's own.
	var navigation := _navigation()
	# Being asked for input means it's in charge, so a walk it was given while it wasn't starts now.
	if _has_waiting_point and navigation:
		_has_waiting_point = false
		navigation.move_to(_waiting_point)
	var link_press := 0
	# is_under_way, so a path waiting for nav (PENDING) gets asked each tick, which is when it tries again.
	if navigation and navigation.is_under_way():
		_command.move = navigation.get_move_direction()
		# A link it just reached may need an action, such as jump, pressed for this tick.
		var action := navigation.take_link_action()
		if action != &"":
			link_press = InputActions.mask_of(action)
	else:
		_command.move = _move
	if _look_node != null:
		if is_instance_valid(_look_node):
			var node := _look_node
			var offset := _look_offset
			look_at_point(node.global_position + offset)
			_look_node = node # look_at_point clears it
			_look_offset = offset
		else:
			_look_node = null # it's gone: keep the last aim
	if _look_set or pawn == null:
		_command.look_yaw = _look_yaw
		_command.look_pitch = _look_pitch
	else:
		_command.look_yaw = pawn.controller_manager.look_yaw if pawn.controller_manager else pawn.yaw
		_command.look_pitch = pawn.controller_manager.look_pitch if pawn.controller_manager else 0.0
	_command.held_actions = _held | _pressed_once | link_press
	_pressed_once = 0
	return _command


# The pawn's NavigationManager, or null.
func _navigation() -> NavigationManager:
	return pawn.navigation_manager if pawn else null


func _stop_path() -> void:
	_has_waiting_point = false
	var navigation := _navigation()
	# Only its own path. While not in charge, the path belongs to whoever is.
	if navigation and _is_in_charge():
		navigation.stop()


# True when the pawn follows this controller's input. With no ControllerManager above it, it counts as in
# charge, so a controller used on its own still works.
func _is_in_charge() -> bool:
	var manager := get_parent() as ControllerManager
	return manager == null or manager.get_controller_in_charge() == self
