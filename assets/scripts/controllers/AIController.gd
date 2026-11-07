## Written by Claude (claude-opus-5-5), 2026-11-07: the AI's hands. A child of the pawn's ControllerManager, in charge whenever no
## player has the pawn. Pawn spec section 6.3.
##
## It decides nothing. Something else tells it what to do, and it turns that into one InputCommand per tick, the same shape a
## player's controller makes. For now that something is a script or a test. From pawn spec step 8, it's the behaviour manager.
## move_to(), which walks a nav path, comes with the navigation manager (step 7).
##
## How to use it:
##   ai.move_in_direction(Vector3(1, 0, 0))   # keeps walking that way until told otherwise
##   ai.stop()                                # stands still
##   ai.press(&"jump")                        # held for one tick, so the pawn sees one press
##   ai.hold(&"sprint", true)                 # held until hold(&"sprint", false)
##   ai.look_at_point(target)
##   ai.stop_looking()                        # keeps whatever look the pawn already has
##   ai.release_all()                         # back to idle: standing, nothing held
##
## Everything it's told stays until changed, except press(), which lasts one tick.
## Claude 2026-11-07: until look_at_point() is called, it keeps the pawn's own look, so taking over from a player doesn't snap the
## pawn's head to straight ahead.
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


## Walks this way, in world space, up to length 1, until told otherwise. Shorter is slower.
func move_in_direction(direction: Vector3) -> void:
	_move = direction.limit_length(1.0)


## Stands still. Held actions stay held.
func stop() -> void:
	_move = Vector3.ZERO


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


## This tick's input. Uses up press(), so call it once per tick: ControllerManager does.
func take_input_command(_tick: int) -> InputCommand:
	_command.move = _move
	if _look_set or pawn == null:
		_command.look_yaw = _look_yaw
		_command.look_pitch = _look_pitch
	else:
		_command.look_yaw = pawn.look_yaw
		_command.look_pitch = pawn.look_pitch
	_command.held_actions = _held | _pressed_once
	_pressed_once = 0
	return _command
