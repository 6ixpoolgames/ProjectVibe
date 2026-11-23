# Written by Claude (claude-opus-5-5), 2026-11-09. History: ai/CHANGELOG.md.
## Runs after the current target, and stops within reach for Attack to take over.
##
## Allowed in Combat. While the target is seen it gives one persistent order, [method AIController.follow]: the controller closes in on
## the target, repathing every [member repath_ticks] or when the target moves [member repath_distance], stops within
## [member stop_distance] and faces it for Attack. Once the target hasn't been seen for [member lost_after_ticks] it walks to where it
## was last seen instead. It holds sprint throughout; with [member dash_to_close] on it also dashes to close the last few metres. It
## never finishes on its own: when the target is out of sight long enough, Combat's prerequisites fail and the state change replaces it.
## Orders only when one of those changes, so an order stream carries a few per chase, not one a tick (netcode spec 19.10).
## Design: pawn spec 10.7.
# REFACTOR: the sprint action's name, &"sprint", is written into Chase, Search and Investigate. A setting (or a tag, as close_in_tag
# is) would let a game with another name for sprinting use them without code (designer friendly). See CHANGELOG.md.
class_name AIChaseBehaviour
extends AIBehaviourBase

## Ticks between new paths.
@export_range(1, 600, 1, "or_greater") var repath_ticks := 20
## How far, in metres, the target must move from where the path leads before a new path is found early.
@export_range(0.1, 50.0, 0.1, "or_greater") var repath_distance := 1.5
## Ticks since the target was last seen after which it's chased to where it was last seen, not where it is (at 60 a second).
@export_range(0, 600, 1, "or_greater") var lost_after_ticks := 30
## How close, in metres, it gets before stopping.
@export_range(0.0, 20.0, 0.1, "or_greater") var stop_distance := 1.2 # just inside MeleeAttack attack_range (1.8) minus Attack approach_margin (0.3)
## On: it holds sprint while chasing. Sprint's own cooldown decides when it actually sprints.
@export var sprint := true
## On: it presses dash to close in, when the target is between [member dash_to_distance] and [member dash_from_distance] away and the
## ability can start (in the air too, Dash's usable_in_air). Off by default. A dash goes the way the pawn is moving, along its path.
@export var dash_to_close := false
## The group of ability it uses to close in, not one ability by name: any ability tagged with it that can start
## ([method AbilityManager.action_for_tag]). Advanced movement by default.
@export var close_in_tag: StringName = Tags.ABILITY.MOVEMENT_ADVANCED
## The farthest the target can be for a dash, in metres.
@export_range(0.0, 50.0, 0.1, "or_greater") var dash_from_distance := 7.5
## The nearest the target can be for a dash, in metres. A dash from a sprint (9 m/s) covers about 4.2 m, so 5.5 lands it a little
## outside stop_distance.
@export_range(0.0, 50.0, 0.1, "or_greater") var dash_to_distance := 5.5

var _goal := Vector3.ZERO
# Looked up once in enter(), and what it last ordered, so a tick gives an order only when something changed.
var _hands: AIController = null
var _memory: AIMemory = null
var _following: Node3D = null # the target it told the controller to follow; null while it walks to the last known position


func _init() -> void:
	super()
	tag_requirements = TagQuery.shared([Tags.AI.STATE_COMBAT])
	tags = [Tags.AI.STANCE_MELEE]
	needs_target = true
	max_score = 0.8
	min_score = 0.8
	tick_interval_ticks = 5 # the AI controller follows the path every tick; Chase only re-aims


func enter(context: AIContextComponent) -> void:
	_hands = context.controller
	_memory = context.memory
	_following = null
	_goal = Vector3.INF
	_hands.hold(&"sprint", sprint)


func tick(context: AIContextComponent) -> Status:
	var index := context.current_target_index()
	if index < 0:
		return Status.FAILED # the target is gone
	var target := context.current_target
	var seen := is_instance_valid(target) and _memory.ticks_since_seen_at(index, context.current_tick) <= TickDriver.ticks_at_rate(lost_after_ticks)
	var there := target.global_position if seen else _memory.last_known_position_at(index)
	if seen:
		if _following != target:
			_following = target
			_hands.follow(target, stop_distance, Vector3(0.0, 1.0, 0.0), 0.3, repath_ticks, repath_distance)
	elif _following != null or there.distance_to(_goal) > repath_distance:
		# Out of sight: one walk to where it was last seen, given again only if that spot moves (memory heard of it again).
		_following = null
		_goal = there
		_hands.move_to(there)
		_hands.look_at_point(there + Vector3(0.0, 1.0, 0.0))
	var offset := there - pawn.global_position
	offset.y = 0.0
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
