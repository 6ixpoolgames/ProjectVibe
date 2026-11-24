# Written by Claude (claude-opus-5-5), 2026-11-24. History: status/CHANGELOG.md.
## A level on a stat that sends an event when the stat's current value falls to it or below (pawn spec 16.8).
##
## A [Stat] lists its thresholds ([member Stat.thresholds]); [method StatusManager.change_current] sends the event of each one a change
## crosses on the way down, through the pawn ([method Pawn.send_event]). Health's defaults: at 0 [code]event.health.depleted[/code]
## (Death starts), at 25% of its max [code]event.health.low[/code].
class_name StatThreshold
extends Resource

## The event it sends, an event tag such as [code]event.health.low[/code].
@export var event: StringName = &""
## The level: an amount, or with [member fraction_of_max] a share of the stat's max (0.25 is a quarter).
@export var at_or_below := 0.0
## On: [member at_or_below] is a share of the stat's max value; off: an amount.
@export var fraction_of_max := false


## The level as an amount, for a stat whose max is this.
func level_for(max_value: float) -> float:
	return at_or_below * max_value if fraction_of_max else at_or_below
