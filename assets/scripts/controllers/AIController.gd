## Written by Claude (claude-opus-5-5), 2026-11-07: the AI's hands. A child of the pawn's ControllerManager, in charge whenever no
## player has the pawn. Pawn spec section 6.3.
##
## It decides nothing. Something else tells it what to do, and it turns that into one InputCommand per tick, the same shape a
## player's controller makes. For now that something is a script or a test. From pawn spec step 8, it's the behaviour manager.
## Claude 2026-11-08: move_to() walks a nav path, through the pawn's NavigationManager (step 7).
##
## How to use it:
##   ai.move_to(point)                        # walks there along a nav path; false if there's no way there
##   ai.move_in_direction(Vector3(1, 0, 0))   # keeps walking that way until told otherwise; drops any path
##   ai.stop()                                # stands still; drops any path
##   ai.press(&"jump")                        # held for one tick, so the pawn sees one press
##   ai.hold(&"sprint", true)                 # held until hold(&"sprint", false)
##   ai.look_at_point(target)
##   ai.stop_looking()                        # keeps whatever look the pawn already has
##   ai.release_all()                         # back to idle: standing, nothing held
##
## Everything it's told stays until changed, except press(), which lasts one tick.
## Claude 2026-11-07: until look_at_point() is called, it keeps the pawn's own look, so taking over from a player doesn't snap the
## pawn's head to straight ahead.
##
## Claude 2026-11-09: while it isn't in charge (pawn spec 6.3 and 10.3). That happens when a player has the pawn and the AI keeps
## deciding anyway (AIContextComponent.while_possessed FULL). Then move_to() only remembers the point, without touching the pawn's
## NavigationManager, so it can't overwrite the player's path, and returns true. When it's in charge again, its next
## take_input_command() starts that walk. stop(), move_in_direction() and release_all() forget it, and leave the player's path
## alone. is_following_order() says whether its own last move_to is still under way, in charge or not.
class_name AIController
extends ControllerBase

var _move := Vector3.ZERO
var _look_yaw := 0.0
var _look_pitch := 0.0
var _look_set := false # false: keep the pawn's own look
var _held := 0 # bits from InputActions
var _pressed_once := 0 # bits held for the next command only
# One command, reused every tick, so a crowd of AI pawns doesn't make thousands of new objects a second. The pawn copies its
# values straight away, so reusing it is safe.
var _command := InputCommand.new()
# Claude 2026-11-09: a move_to given while not in charge, started when it's in charge again.
var _waiting_point := Vector3.ZERO
var _has_waiting_point := false


## Claude 2026-11-08: walks to this point along a nav path, and stands still once there. Returns false if there's no way there,
## or the pawn has no NavigationManager, and then the pawn stands still. pawn.navigation_manager.has_arrived() says when it's there.
## Claude 2026-11-09: while not in charge, it remembers the point for later and returns true (see the top of the file).
func move_to(point: Vector3) -> bool:
	_move = Vector3.ZERO # once the path ends, it stands
	var navigation := _navigation()
	if navigation == null:
		push_warning("AIController: %s has no NavigationManager, so move_to can't find a way. Check its skip_default_parts." % (pawn.name if pawn else "this pawn"))
		return false
	if not _is_in_charge():
		_waiting_point = point
		_has_waiting_point = true
		return true
	_has_waiting_point = false
	return navigation.move_to(point)


## Claude 2026-11-09: true while its own last move_to is under way: following its path when in charge, or waiting to start it when
## not. False once it arrives, gives up, or is told to do something else.
func is_following_order() -> bool:
	if _has_waiting_point:
		return true
	var navigation := _navigation()
	return navigation != null and _is_in_charge() and navigation.is_following_path()


## Walks this way, in world space, up to length 1, until told otherwise. Shorter is slower.
func move_in_direction(direction: Vector3) -> void:
	_move = direction.limit_length(1.0)
	_stop_path() # Claude 2026-11-08


## Stands still. Held actions stay held.
func stop() -> void:
	_move = Vector3.ZERO
	_stop_path() # Claude 2026-11-08


## Looks at a point in the world. Does nothing without a pawn, since there's nowhere to look from.
func look_at_point(point: Vector3) -> void:
	if pawn == null:
		return
	var offset := point - pawn.global_position
	if offset.length_squared() < 0.000001:
		return
	# Godot's forward is -Z, so a point straight ahead has yaw 0.
	_look_yaw = atan2(-offset.x, -offset.z)
	_look_pitch = atan2(offset.y, Vector2(offset.x, offset.z).length())
	_look_set = true


## Stops looking at anything in particular, and keeps whatever look the pawn already has.
func stop_looking() -> void:
	_look_set = false


## Claude 2026-11-09: true while it's looking at a point it was given. AI sight faces this way then (SightSense).
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
	_stop_path() # Claude 2026-11-08


## This tick's input. Uses up press(), so call it once per tick: ControllerManager does.
func take_input_command(_tick: int) -> InputCommand:
	# Claude 2026-11-08: while a path from move_to is being followed, the direction comes from it. ControllerManager drops a path
	# when control changes hands, so any path here is this controller's own.
	var navigation := _navigation()
	# Claude 2026-11-09: being asked for input means it's in charge, so a walk it was given while it wasn't starts now.
	if _has_waiting_point and navigation:
		_has_waiting_point = false
		navigation.move_to(_waiting_point)
	var link_press := 0
	if navigation and navigation.is_following_path():
		_command.move = navigation.get_move_direction()
		# Claude 2026-11-08: a link it just reached may need an action, such as jump, pressed for this tick.
		var action := navigation.take_link_action()
		if action != &"":
			link_press = InputActions.mask_of(action)
	else:
		_command.move = _move
	if _look_set or pawn == null:
		_command.look_yaw = _look_yaw
		_command.look_pitch = _look_pitch
	else:
		_command.look_yaw = pawn.look_yaw
		_command.look_pitch = pawn.look_pitch
	_command.held_actions = _held | _pressed_once | link_press
	_pressed_once = 0
	return _command


# Claude 2026-11-08: the pawn's NavigationManager, or null.
func _navigation() -> NavigationManager:
	return pawn.navigation_manager if pawn else null


func _stop_path() -> void:
	_has_waiting_point = false # Claude 2026-11-09
	var navigation := _navigation()
	# Claude 2026-11-09: only its own path. While not in charge, the path belongs to whoever is.
	if navigation and _is_in_charge():
		navigation.stop()


# Claude 2026-11-09: true when the pawn follows this controller's input. With no ControllerManager above it, it counts as in
# charge, so a controller used on its own still works.
func _is_in_charge() -> bool:
	var manager := get_parent() as ControllerManager
	return manager == null or manager.get_controller_in_charge() == self
