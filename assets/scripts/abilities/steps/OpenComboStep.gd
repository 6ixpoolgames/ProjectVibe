## Written by Claude (claude-opus-5-5), 2026-11-16 (pawn spec 8.20, the owner's design): opens the combo window when it starts, so a
## follow-up (an ability whose combo_positions include the next position) can start for window_ticks. Put after a hit, not at the start,
## so an attack cancelled in its windup opens nothing. Done on its next tick.
class_name OpenComboStep
extends AbilityStep

## How long the window stays open, in ticks at 60 a second (converted for the match's tick rate). 30: half a second.
@export_range(1, 600, 1, "or_greater") var window_ticks := 30


func enter() -> void:
	if ability.manager:
		ability.manager.open_combo_window(TickDriver.ticks_at_rate(window_ticks))


func tick(_dt: float) -> Status:
	return Status.DONE
