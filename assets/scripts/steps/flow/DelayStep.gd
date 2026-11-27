# Written by Claude (claude-opus-5-5), 2026-11-27. History: steps/CHANGELOG.md.
## Does nothing for a while, then is done: for [member Step.length_ticks], or until [member until_tick] (pawn spec 16.7's Wait,
## named after Unreal's Delay, since abilities already have a [WaitStep]).
##
## A pause between walks, a beat before a swing. A deadline set from code (a random pause) goes in [member until_tick], the tick it
## ends on.
class_name DelayStep
extends Step

## The tick it's done on. -1: by its length alone (0 length and no tick: it waits until stopped).
@export var until_tick := -1


func tick(_dt: float) -> Status:
	return Status.DONE if until_tick >= 0 and TickDriver.tick >= until_tick else Status.RUNNING
