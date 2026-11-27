# Written by Claude (claude-opus-5-5), 2026-11-22. History: steps/CHANGELOG.md.
## A condition a step timeline entry can start on: one value of the owner's pawn compared with a number (ability spec 6.3).
##
## Data, not code, so timelines stay no-code and C++ can judge them later. Any timeline owner can use it: an ability, an AI behaviour,
## a controller's step host. It follows the AI's [AICompareCondition]; the two may share a base later. Values that are yes or no are 1
## or 0. BETWEEN holds from [member value] to [member upper], so a distance band ("dash when 4 to 8 m away") is one condition.
## [codeblock]
## LOOK_ANGLE       AT_MOST  15        # facing within 15 degrees of where it looks
## ACTION_HELD      EQUAL    0         # its action was let go
## STAT "Health"    AT_MOST  20
## TARGET_DISTANCE  BETWEEN  4 .. 8    # the AI's target, at its real position
## [/codeblock]
class_name StepCondition
extends Resource

## What it reads.
enum Reads {
	LOOK_ANGLE, ## degrees between where the pawn faces and where it looks
	ACTION_HELD, ## 1 while [member action] (or the owner's own action: an ability's trigger, a behaviour's presses_action) is held, else 0
	GROUNDED, ## 1 on the ground, else 0
	STAT, ## the pawn's [member stat]
	TICKS_RUNNING, ## ticks since the owner's run began, at the match's rate
	TARGET_DISTANCE, ## flat metres to the AI's current target where it really is; [constant AIInputs.FAR] with none
}
## How the value is compared with [member value]: the same as [enum AICompareCondition.Comparison], plus BETWEEN.
enum Comparison {
	AT_MOST,
	LESS_THAN,
	AT_LEAST,
	MORE_THAN,
	EQUAL,
	NOT_EQUAL,
	BETWEEN, ## from [member value] to [member upper], both included
}

## What it reads.
@export var input := Reads.LOOK_ANGLE
## How it's compared.
@export var comparison := Comparison.AT_MOST
## The number it's compared with; with BETWEEN, the lowest that holds.
@export var value := 0.0
## With BETWEEN: the highest that holds.
@export var upper := 0.0
## With ACTION_HELD: the action. Empty: the owner's own ([code]default_action()[/code] on the timeline's host).
@export var action: StringName = &""
## With STAT: the stat's name.
@export var stat: StringName = &""


## A condition in one line: [code]StepCondition.make(StepCondition.Reads.TARGET_DISTANCE, StepCondition.Comparison.BETWEEN, 4, 8)[/code].
static func make(reads: Reads, compare: Comparison, number: float, high := 0.0) -> StepCondition:
	var condition := StepCondition.new()
	condition.input = reads
	condition.comparison = compare
	condition.value = number
	condition.upper = high
	return condition


## True if it holds now for the pawn of this timeline's owner.
func holds(timeline: StepTimeline) -> bool:
	var got := read(timeline)
	match comparison:
		Comparison.AT_MOST:
			return got <= value
		Comparison.LESS_THAN:
			return got < value
		Comparison.AT_LEAST:
			return got >= value
		Comparison.MORE_THAN:
			return got > value
		Comparison.EQUAL:
			return is_equal_approx(got, value)
		Comparison.BETWEEN:
			return got >= value and got <= upper
		_:
			return not is_equal_approx(got, value)


## The value it compares, for the pawn of this timeline's owner now. The owner (the timeline's host) has a [code]pawn[/code].
func read(timeline: StepTimeline) -> float:
	var host: Object = timeline.host if timeline else null
	var pawn: Pawn = host.get(&"pawn") as Pawn if host else null
	var controls := pawn.controller_manager if pawn else null
	match input:
		Reads.LOOK_ANGLE:
			if pawn == null:
				return 0.0
			var look := controls.look_yaw if controls else pawn.yaw
			return rad_to_deg(absf(angle_difference(pawn.yaw, look)))
		Reads.ACTION_HELD:
			var name := action
			if name == &"" and host and host.has_method(&"default_action"):
				name = host.call(&"default_action")
			var bit := InputActions.mask_of(name) if name != &"" else 0
			var held := controls.held_actions if controls else 0
			return 1.0 if bit != 0 and held & bit != 0 else 0.0
		Reads.GROUNDED:
			return 1.0 if pawn and pawn.grounded else 0.0
		Reads.STAT:
			return pawn.status_manager.get_value(stat, 0.0) if pawn and pawn.status_manager else 0.0
		Reads.TICKS_RUNNING:
			return float(maxi(TickDriver.tick - timeline.started_at, 0)) if timeline and timeline.started_at >= 0 else 0.0
		_:
			var target: Node3D = pawn.ai.current_target if pawn and pawn.ai else null
			if pawn == null or not is_instance_valid(target):
				return AIInputs.FAR
			var offset := target.global_position - pawn.global_position
			offset.y = 0.0
			return offset.length()
