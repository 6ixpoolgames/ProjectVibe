# Written by Claude (claude-opus-5-5), 2026-11-22. History: abilities/CHANGELOG.md.
## A condition a step timeline entry can start on: one value of the pawn compared with a number (ability spec 6.3).
##
## Data, not code, so timelines stay no-code and C++ can judge them later. It follows the AI's [AICompareCondition]; the two may share
## a base later. Values that are yes or no are 1 or 0.
## [codeblock]
## LOOK_ANGLE    AT_MOST  15     # facing within 15 degrees of where it looks
## ACTION_HELD   EQUAL    0      # its action was let go
## STAT "Health" AT_MOST  20
## [/codeblock]
class_name AbilityCondition
extends Resource

## What it reads.
enum Reads {
	LOOK_ANGLE, ## degrees between where the pawn faces and where it looks
	ACTION_HELD, ## 1 while [member action] (or the ability's trigger_action) is held, else 0
	GROUNDED, ## 1 on the ground, else 0
	STAT, ## the pawn's [member stat]
	TICKS_RUNNING, ## ticks since the ability started, at the match's rate
}
## How the value is compared with [member value]; the same as [enum AICompareCondition.Comparison].
enum Comparison { AT_MOST, LESS_THAN, AT_LEAST, MORE_THAN, EQUAL, NOT_EQUAL }

## What it reads.
@export var input := Reads.LOOK_ANGLE
## How it's compared.
@export var comparison := Comparison.AT_MOST
## The number it's compared with.
@export var value := 0.0
## With ACTION_HELD: the action. Empty: the ability's trigger_action.
@export var action: StringName = &""
## With STAT: the stat's name.
@export var stat: StringName = &""


## True if it holds for this ability's pawn now.
func holds(ability: AbilityBase) -> bool:
	var got := read(ability)
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
		_:
			return not is_equal_approx(got, value)


## The value it compares, for this ability's pawn now.
func read(ability: AbilityBase) -> float:
	var pawn := ability.pawn
	match input:
		Reads.LOOK_ANGLE:
			return rad_to_deg(absf(angle_difference(pawn.yaw, ability.look_yaw()))) if pawn else 0.0
		Reads.ACTION_HELD:
			var name := action if action != &"" else ability.trigger_action
			var bit := InputActions.mask_of(name) if name != &"" else 0
			return 1.0 if bit != 0 and ability.held_actions() & bit != 0 else 0.0
		Reads.GROUNDED:
			return 1.0 if pawn and pawn.grounded else 0.0
		Reads.STAT:
			return ability.read_stat(stat, 0.0)
		_:
			return float(ability.ticks_running())
