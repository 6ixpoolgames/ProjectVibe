## Written by Claude (claude-opus-5-5), 2026-11-09: runs after the current target. Pawn spec section 10.7. Allowed in Combat by default.
##
## It follows the current target's last known position (which sight keeps updating while the target is in view), holding sprint,
## and looks at it the whole time, so the AI's eyes stay on the target. It finds a new path every repath_ticks, or sooner when the
## target has moved more than repath_distance from where the path leads, rather than every tick. Within stop_distance it stops and
## faces the target; the Attack behaviour that comes with MeleeAttack (step 9) takes over from there.
##
## It never finishes on its own. When the target is out of sight long enough, Combat's prerequisites fail and the state change
## replaces it.
class_name AIChaseBehaviour
extends AIBehaviourBase

## Ticks between new paths.
@export_range(1, 600, 1, "or_greater") var repath_ticks := 20
## How far, in metres, the target must move from where the path leads before a new path is found early.
@export_range(0.1, 50.0, 0.1, "or_greater") var repath_distance := 1.5
## How close, in metres, it gets before stopping.
@export_range(0.0, 20.0, 0.1, "or_greater") var stop_distance := 1.5
## On: it holds sprint while chasing. Sprint's own cooldown decides when it actually sprints.
@export var sprint := true

var _goal := Vector3.ZERO
var _last_path_tick := -1000000
# Claude 2026-11-09: looked up once in enter(), and what it last did, so a tick skips repeating it. Each call costs about 0.3 to
# 1.5 µs in GDScript, and ai_stress showed Chase's tick, repeated by every chasing pawn, cost more than its path requests.
var _hands: AIController = null
var _memory: AIMemory = null
var _standing := false # stopped near the target


func _init() -> void:
	super()
	allowed_states = [&"Combat"]
	needs_target = true
	max_score = 0.8
	min_score = 0.8
	tick_interval_ticks = 5 # Claude 2026-11-09: the AI controller follows the path every tick; Chase only re-aims


func enter(context: AIContextComponent) -> void:
	_hands = context.controller
	_memory = context.memory
	_last_path_tick = -1000000
	_standing = false
	_hands.hold(&"sprint", sprint)


func tick(context: AIContextComponent) -> Status:
	var index := context.current_target_index()
	if index < 0:
		return Status.FAILED # the target is gone
	var last_known := _memory.last_known_position_at(index)
	# Every tick it runs: the look is a direction from where the pawn stands now, so it goes stale as the pawn moves.
	_hands.look_at_point(last_known + Vector3(0.0, 1.0, 0.0))
	var offset := last_known - pawn.global_position
	offset.y = 0.0
	if offset.length_squared() <= stop_distance * stop_distance:
		if not _standing:
			_standing = true
			_hands.stop()
		return Status.RUNNING
	var now := context.current_tick
	if _standing or now - _last_path_tick >= repath_ticks or last_known.distance_to(_goal) > repath_distance or not _hands.is_following_order():
		_standing = false
		_goal = last_known
		_last_path_tick = now
		_hands.move_to(last_known)
	return Status.RUNNING


func exit(context: AIContextComponent, _reason: String) -> void:
	if context.controller:
		context.controller.hold(&"sprint", false)
		context.controller.stop()
		context.controller.stop_looking()
