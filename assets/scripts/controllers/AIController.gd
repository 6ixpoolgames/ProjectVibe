# Written by Claude (claude-opus-5-5), 2026-11-07. History: controllers/CHANGELOG.md.
## The AI's hands: hands over, as one InputCommand per tick, what the running AI behaviour's steps write.
##
## A component of the pawn's AIManager ([member AIManager.controller]); the ControllerManager puts it in charge whenever no player
## has the pawn. It decides nothing and follows no orders of its own: each tick it's asked for input it runs the running behaviour's
## step timeline ([method AIBehaviourBase.run_steps]), whose move, look and button steps write the input (pawn spec 16.7). A part no
## step wrote falls back to a script's walk ([method move_to], a MoveTo step on its own [member step_host], as the player's
## click-to-move), then its direct input: a still pawn and the pawn's own look, unless a script (a cutscene, a test) set them.
## [codeblock]
## ai.move_to(point)                        # a script's walk along a nav path; false if there's no way there
## ai.move_in_direction(Vector3(1, 0, 0))   # direct input: keeps walking that way while no step moves the pawn
## ai.look_at_point(point)                  # direct input: looks there while no step looks
## ai.press(&"jump")                        # held for one tick, so the pawn sees one press
## [/codeblock]
## A dead pawn's controller lets go of its direct input as the pawn dies, and takes none while dead; the controllers README has the rest. Design: pawn spec 6.3,
## 10.3, 16.7.
class_name AIController
extends ControllerBase

## How walks the AI's steps take follow their paths, for steps that have no settings of their own. Empty: the defaults.
@export var path_settings: PathFollowSettings

## Runs a script's walks ([method move_to]): a MoveTo step, made the first time one's asked for. Null until then.
var step_host: ControllerStepHost = null

# Direct input from a script: what's used where no step writes. Look is kept only once look_at_point has been called.
var _direct := StepInput.new()
var _pressed_once := 0 # bits held for the next command only
# One command, reused every tick so a crowd of AI pawns makes no garbage; the ControllerManager copies it at once.
var _command := InputCommand.new()
var _steps_looked := false # the last command's look came from a running step
var _let_go := false # it let go of everything (its pawn died) and has had no direct input since


# Its pawn is its AIManager's, which entered the tree first.
func _enter_tree() -> void:
	var ai := get_parent() as AIManager
	pawn = ai.pawn if ai else null


func _ready() -> void:
	# As its pawn dies it lets go of its direct input, once, so it comes back from a revive holding nothing.
	if pawn and pawn.ability_manager:
		pawn.ability_manager.died.connect(func(_pawn: Pawn, _hit: HitInfo) -> void: let_go())


## This tick's input: the running behaviour's steps first, then direct input for what they left. Uses up press(), so call it once
## per tick: ControllerManager does.
func take_input_command(_tick: int) -> InputCommand:
	var behaviour := _running_behaviour()
	var elapsed := pawn.ticks_elapsed if pawn else 1
	var steps: StepInput = null
	if behaviour:
		behaviour.run_steps(elapsed)
		steps = behaviour.steps_input
	var walk: StepInput = null
	if step_host and step_host.is_running():
		step_host.run(elapsed)
		walk = step_host.input
	if steps and steps.move_set:
		_command.move = steps.move
	elif walk and walk.move_set:
		_command.move = walk.move
	else:
		_command.move = _direct.move
	_steps_looked = steps != null and steps.look_set
	if steps and steps.look_set:
		_command.look_yaw = steps.look_yaw
		_command.look_pitch = steps.look_pitch
	elif _direct.look_set or pawn == null:
		_command.look_yaw = _direct.look_yaw
		_command.look_pitch = _direct.look_pitch
	else:
		_command.look_yaw = pawn.controller_manager.look_yaw if pawn.controller_manager else pawn.yaw
		_command.look_pitch = pawn.controller_manager.look_pitch if pawn.controller_manager else 0.0
	_command.held_actions = _direct.held_actions | _pressed_once | (steps.held_actions if steps else 0) | (walk.held_actions if walk else 0)
	_pressed_once = 0
	return _command


## True while it's told where to look: by a running step, or [method look_at_point]. AI sight faces this way then (SightSense).
func is_looking_at_something() -> bool:
	return _steps_looked or _direct.look_set


## The path follower the running behaviour's move step walks the pawn along, else a script's walk's, or null.
func get_path_follower() -> PathFollower:
	var behaviour := _running_behaviour()
	var follower := behaviour.moving_follower() if behaviour else null
	if follower == null and is_walking():
		var walk := walk_step()
		follower = walk.follower if walk.follower.is_under_way() else null
	return follower


## Charge changed hands: a script's walk ends, as the player's click-to-move does, so nobody walks the rest of a path once charge
## comes back. The running behaviour's move step only drops its path, and finds a new one the next time it runs ([MoveStep]): the
## behaviour still wants to go there.
func drop_path() -> void:
	_stop_walking()
	var behaviour := _running_behaviour()
	var follower := behaviour.moving_follower() if behaviour else null
	if follower:
		follower.stop()


# --- A script's walk ---


## Walks to this point along a nav path, for a script or test (behaviours use their own MoveTo steps), and stands once there. False
## (and it stands) if there's no way there. Direct movement ([method move_in_direction], [method stop]) and charge changing hands
## end it.
func move_to(point: Vector3) -> bool:
	if pawn == null or pawn.is_dead():
		return false
	_let_go = false
	var walk := walk_step()
	walk.goal = point
	if not step_host.start(walk) or walk.gave_up():
		step_host.stop()
		return false
	return true


## True while a script's walk ([method move_to]) is under way, waiting included.
func is_walking() -> bool:
	return step_host != null and step_host.is_running()


## The MoveTo step a script's walk runs on, made with its [member step_host] the first time it's asked for. Its follower is the
## walk's path.
func walk_step() -> MoveToStep:
	if step_host == null:
		step_host = ControllerStepHost.new()
		step_host.name = "StepHost"
		var walk := MoveToStep.new()
		walk.name = "MoveTo"
		walk.settings = path_settings
		walk.follower.pawn = pawn
		walk.follower.settings = path_settings # as MoveStep.enter gives it, so it reads the same before the first walk
		step_host.add_child(walk)
		add_child(step_host)
		step_host.set_pawn(pawn)
	return step_host.get_node(^"MoveTo") as MoveToStep


func _stop_walking() -> void:
	if step_host:
		step_host.stop()



# --- Direct input, for scripts and tests: used where no step writes ---


## Walks this way, in world space, up to length 1, until told otherwise. Shorter is slower.
func move_in_direction(direction: Vector3) -> void:
	if _ignores_input():
		return
	_let_go = false
	_stop_walking()
	_direct.move = direction.limit_length(1.0)


## Stands still, as far as direct input and a script's walk go. Held actions stay held.
func stop() -> void:
	_stop_walking()
	_direct.move = Vector3.ZERO


## Looks at a point in the world, aimed from the pawn's eyes. Does nothing without a pawn, since there's nowhere to look from.
func look_at_point(point: Vector3) -> void:
	if pawn == null or _ignores_input():
		return
	_let_go = false
	_direct.look_at(pawn.global_position + Vector3(0.0, pawn.eye_height, 0.0), point)


## Stops looking at anything in particular, and keeps whatever look the pawn already has.
func stop_looking() -> void:
	_direct.look_set = false


## Holds this action for the next tick only, so the pawn sees one press.
func press(action: StringName) -> void:
	if _ignores_input():
		return
	_let_go = false
	_pressed_once |= InputActions.mask_of(action)


## Holds or lets go of this action, until changed.
func hold(action: StringName, held := true) -> void:
	if _ignores_input():
		return
	_let_go = false
	if held:
		_direct.held_actions |= InputActions.mask_of(action)
	else:
		_direct.held_actions &= ~InputActions.mask_of(action)


## Back to idle as far as direct input goes: standing still, nothing held. The look stays.
func release_all() -> void:
	_stop_walking()
	_direct.move = Vector3.ZERO
	_direct.held_actions = 0
	_pressed_once = 0


## Forgets all direct input (standing, nothing held, no look). The pawn calls it through its ControllerManager on each tick it's
## dead, on every machine that runs it, so it comes back from a revive holding nothing (netcode spec 19.10). The running behaviour
## stops as the pawn dies, and its steps with it.
func let_go() -> void:
	if _let_go:
		return
	_stop_walking()
	_direct.clear()
	_pressed_once = 0
	_let_go = true


# A dead pawn's controller takes no direct input, so it comes back from a revive with none (netcode spec 19.10).
func _ignores_input() -> bool:
	return pawn != null and pawn.is_dead()


func _running_behaviour() -> AIBehaviourBase:
	var ai := pawn.ai if pawn else null
	var behaviours := ai.behaviour_manager if ai else null
	return behaviours.get_running_behaviour() if behaviours else null
