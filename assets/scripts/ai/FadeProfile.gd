## Written by Claude (claude-opus-5-5), 2026-11-09: how a value fades over ticks, as a Resource designers tune in the inspector.
## Pawn spec section 10.2. Used by AI behaviour persistence (10.7) now, and by AI memory and target selection (10.5) from step 8b.
##
## A fade starts at full (1.0) and ends at nothing (0.0). One profile has exactly one curve, so a designer never has to combine two
## kinds of fade in their head:
##   LINEAR      full for hold_ticks, then a straight line down to nothing over fade_ticks
##   HALF_LIFE   full for hold_ticks, then halves every half_life_ticks. Counts as nothing below 1%, which is after 7 halvings
##   CURVE       full for hold_ticks, then follows the drawn curve over fade_ticks (the curve's x runs 0 to 1, its y is the value)
##
## How to use it:
##   var fade := FadeProfile.new()          # or a .tres file made in the inspector, shared by everything that uses it
##   fade.value_at(30)                       # 1.0 at the start, falling to 0.0
##   fade.ends_after()                       # ticks until it's nothing; from then on value_at() gives exactly 0.0
##
## A fade no mode covers: write a script that extends FadeProfile and overrides value_at() and ends_after(). Everything that uses a
## profile picks it up with no other change.
##
## What happens in odd cases:
##   - A tick count below 0 (before the fade starts): full.
##   - LINEAR or CURVE with fade_ticks 0, or HALF_LIFE with half_life_ticks 0: full for the hold, then nothing at once.
##   - CURVE with no curve drawn: it behaves as LINEAR, and warns once.
##   - A drawn curve that dips below 0 or rises above 1: the value is kept between 0 and 1.
class_name FadeProfile
extends Resource

enum Mode { LINEAR, HALF_LIFE, CURVE }

## Which curve the fade follows. See the top of the file.
@export var mode := Mode.LINEAR
## Ticks at full strength before the fade begins.
@export_range(0, 36000, 1, "or_greater") var hold_ticks := 0
## LINEAR and CURVE: ticks from full to nothing, after the hold.
@export_range(0, 36000, 1, "or_greater") var fade_ticks := 60
## HALF_LIFE: the value halves every this many ticks, after the hold.
@export_range(0, 36000, 1, "or_greater") var half_life_ticks := 30
## CURVE: the shape of the fade. x runs from 0 (the end of the hold) to 1 (fade_ticks later); y is the value.
@export var curve: Curve

# HALF_LIFE counts as over after this many halvings: 0.5^7 is about 0.8%, the first step below 1%.
const HALVINGS_UNTIL_NOTHING := 7

var _warned_no_curve := false


## The value this many ticks after the fade started: 1.0 at the start, falling to 0.0. ticks can be fractional, so a fade can run
## slower or faster than one step per tick.
func value_at(ticks: float) -> float:
	if ticks < hold_ticks:
		return 1.0
	if ticks >= ends_after():
		return 0.0
	var into_fade := ticks - hold_ticks
	match mode:
		Mode.HALF_LIFE:
			# GDScript note: pow(0.5, n) halves n times; n can be fractional, which gives the smooth curve between halvings.
			return pow(0.5, into_fade / half_life_ticks)
		Mode.CURVE:
			if curve:
				# GDScript note: sample_baked reads the curve at x from a table Godot precomputes, so it's cheap to call often.
				return clampf(curve.sample_baked(into_fade / fade_ticks), 0.0, 1.0)
			if not _warned_no_curve:
				_warned_no_curve = true
				push_warning("FadeProfile: mode is CURVE but no curve is drawn, so it fades in a straight line instead.")
			return 1.0 - into_fade / fade_ticks
		_:
			return 1.0 - into_fade / fade_ticks


## Ticks from the start until the value is nothing. From then on, value_at() gives exactly 0.0.
func ends_after() -> int:
	match mode:
		Mode.HALF_LIFE:
			return hold_ticks + half_life_ticks * HALVINGS_UNTIL_NOTHING
		_:
			return hold_ticks + fade_ticks
