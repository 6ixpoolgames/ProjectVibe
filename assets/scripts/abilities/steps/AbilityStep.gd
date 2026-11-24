# Written by Claude (claude-opus-5-5), 2026-11-16. History: abilities/CHANGELOG.md.
## One step of an ability, such as a windup, a turn or a swing: a child node of the ability, run by its [StepTimeline].
##
## A [Step] with what abilities add: a cancel window ([member interrupt_threshold]) and ending when its action is let go
## ([member ends_when_released]). When steps start is the ability's step timeline ([TimelineEntry]); see [Step] for what to override
## and how rollback works.
## Design: ability spec 6, pawn spec 8.20 and 16.7.
class_name AbilityStep
extends Step

## While it runs, how strong a starting ability (or a hit's knockback) must be to cancel its ability. -1: the ability's own
## interrupt_threshold. With several steps running, the strictest counts.
@export var interrupt_threshold := -1
## Effects on its pawn while it runs: applied as it starts, removed as it ends (pawn spec 16.7). For a step during which hits can't
## land, an effect granting status.invulnerable that lasts until removed.
@export var running_effects: Array[Effect] = []
## On: it ends on the first tick its action isn't held (reason "released"), which starts what follows it as done does (unless an entry
## says otherwise). Held input is rolled-back input, so server, prediction and replay agree.
@export var ends_when_released := false:
	set(value):
		ends_when_released = value
		checks_release = value and hold_bit != 0 # timeline entries can change it for a run
## The action that must stay held. Empty: its ability's trigger_action. With neither, it's never released.
@export var while_held: StringName = &""

## Set by its ability.
var ability: AbilityBase = null
## while_held's input bit (or its ability's trigger_action's), worked out once by setup_hold(). 0: no action to hold.
var hold_bit := 0:
	set(value):
		hold_bit = value
		checks_release = ends_when_released and value != 0


## With [member ends_when_released], it ends once its action is let go, if [method can_end_on_release] allows.
func released_now() -> bool:
	return ends_when_released and hold_bit != 0 and not is_held() and can_end_on_release()


## With ends_when_released, whether letting go may end it now. Yes by default; TurnToFace says no until its minimum turn.
func can_end_on_release() -> bool:
	return true


## True while its action is held this tick (always false with no action to hold).
func is_held() -> bool:
	return hold_bit != 0 and ability.held_actions() & hold_bit != 0


## Its ability calls this once, before setup(): which input bit to watch.
func setup_hold() -> void:
	var action := while_held if while_held != &"" else ability.settings.trigger_action
	hold_bit = InputActions.mask_of(action) if action != &"" else 0


## Where the weapon is during this step, as an offset from the pawn's feet for this facing in radians; null: this step doesn't say.
## [method AbilityBase.weapon_point] collects them, so visuals need no work for a new pattern.
func weapon_point(_facing: float) -> Variant:
	return null
