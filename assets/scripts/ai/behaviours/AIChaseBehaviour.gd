# Written by Claude (claude-opus-5-5), 2026-11-09. History: ai/CHANGELOG.md.
## Runs after the current target, and stops within reach for Attack to take over.
##
## Allowed in Combat. It follows the target's last known position, holding sprint and looking at it the whole time. It finds a new path
## every [member repath_ticks], or sooner when the target has moved more than [member repath_distance] from where the path leads. Within
## [member stop_distance] it stops and faces the target for Attack. With [member dash_to_close] on it also dashes to close the last few
## metres. It never finishes on its own: when the target is out of sight long enough, Combat's prerequisites fail and the state change
## replaces it.
## Design: pawn spec 10.7.
# REFACTOR: the sprint action's name, &"sprint", is written into Chase, Search and Investigate. A setting (or a tag, as close_in_tag
# is) would let a game with another name for sprinting use them without code (designer friendly). See CHANGELOG.md.
class_name AIChaseBehaviour
extends AIBehaviourBase

## Ticks between new paths.
@export_range(1, 600, 1, "or_greater") var repath_ticks := 20
## How far, in metres, the target must move from where the path leads before a new path is found early.
@export_range(0.1, 50.0, 0.1, "or_greater") var repath_distance := 1.5
## How close, in metres, it gets before stopping.
@export_range(0.0, 20.0, 0.1, "or_greater") var stop_distance := 1.2 # just inside MeleeAttack attack_range (1.8) minus Attack approach_margin (0.3)
## On: it holds sprint while chasing. Sprint's own cooldown decides when it actually sprints.
@export var sprint := true
## On: it presses dash to close in, when the target is between [member dash_to_distance] and [member dash_from_distance] away and the
## ability can start (in the air too, Dash's usable_in_air). Off by default. A dash goes the way the pawn is moving, along its path.
@export var dash_to_close := false
## The group of ability it uses to close in, not one ability by name: any ability tagged with it that can start
## ([method AbilityManager.action_for_tag]). Advanced movement by default.
@export var close_in_tag: StringName = Tags.MOVEMENT_ADVANCED
## The farthest the target can be for a dash, in metres.
@export_range(0.0, 50.0, 0.1, "or_greater") var dash_from_distance := 7.5
## The nearest the target can be for a dash, in metres. A dash from a sprint (9 m/s) covers about 4.2 m, so 5.5 lands it a little
## outside stop_distance.
@export_range(0.0, 50.0, 0.1, "or_greater") var dash_to_distance := 5.5

var _goal := Vector3.ZERO
var _last_path_tick := -1000000
# Looked up once in enter(), and what it last did, so a tick skips repeating it (ai_stress: Chase's tick, repeated by every chasing pawn,
# cost more than its path requests).
var _hands: AIController = null
var _memory: AIMemory = null
var _standing := false # stopped near the target


func _init() -> void:
	super()
	allowed_states = [&"Combat"]
	needs_target = true
	max_score = 0.8
	min_score = 0.8
	tick_interval_ticks = 5 # the AI controller follows the path every tick; Chase only re-aims


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
	if _standing or now - _last_path_tick >= TickDriver.ticks_at_rate(repath_ticks) or last_known.distance_to(_goal) > repath_distance or not _hands.is_following_order():
		_standing = false
		_goal = last_known
		_last_path_tick = now
		_hands.move_to(last_known)
		# A dash to close in: whatever ability in close_in_tag's group can start. Pressed only when it can, so a press never waits in Dash's buffer.
	if dash_to_close and pawn.ability_manager:
		var distance_squared := offset.length_squared()
		if distance_squared <= dash_from_distance * dash_from_distance and distance_squared >= dash_to_distance * dash_to_distance:
			var action := pawn.ability_manager.action_for_tag(close_in_tag)
			if action != &"":
				_hands.press(action)
	return Status.RUNNING


func exit(context: AIContextComponent, _reason: String) -> void:
	if context.controller:
		context.controller.hold(&"sprint", false)
		context.controller.stop()
		context.controller.stop_looking()
