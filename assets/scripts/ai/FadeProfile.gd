# Written by Claude (claude-opus-5-5), 2026-11-09. History: ai/CHANGELOG.md.
## How a value fades over ticks, from full to nothing, as a Resource designers tune in the inspector.
##
## Pawn spec section 10.2. Used by AI behaviour persistence (10.7), memory's awareness and the target selector's current target
## bonus (10.5).
## [br]
## A fade starts at full (1.0) and ends at nothing (0.0). One profile has exactly one curve, so a designer never has to combine two
## kinds of fade in their head:
## [br]- LINEAR: full for [member hold_ticks], then a straight line down to nothing over [member fade_ticks]
## [br]- HALF_LIFE: full for hold_ticks, then halves every [member half_life_ticks]. Counts as nothing below 1%, which is after 7
##   halvings
## [br]- CURVE: full for hold_ticks, then follows the drawn [member curve] over fade_ticks (the curve's x runs 0 to 1, its y is the
##   value)
## [br]
## hold_ticks, fade_ticks and half_life_ticks are written for 60 ticks a second, and used at the match's rate
## ([code]TickDriver.ticks_at_rate[/code]), so a fade lasts the same time at any rate.
## [br]
## How to use it:
## [codeblock]
## var fade := FadeProfile.new()  # or a .tres file made in the inspector, shared by everything that uses it
## fade.value_at(30)              # 1.0 at the start, falling to 0.0
## fade.ends_after()              # ticks until it's nothing; from then on value_at() gives exactly 0.0
## [/codeblock]
## A fade no mode covers: write a script that extends FadeProfile and overrides [method value_at] and [method ends_after]. Everything
## that uses a profile picks it up with no other change.
## [br]
## What happens in odd cases (checked in ai/tests/fade_profile_selftest.gd):
## [br]- A tick count below 0 (before the fade starts): full.
## [br]- LINEAR or CURVE with fade_ticks 0, or HALF_LIFE with half_life_ticks 0: full for the hold, then nothing at once.
## [br]- CURVE with no curve drawn: it behaves as LINEAR, and warns once.
## [br]- A drawn curve that dips below 0 or rises above 1: the value is kept between 0 and 1.
class_name FadeProfile
extends Resource

## The kinds of fade: a straight line, halving, or a drawn curve.
enum Mode { LINEAR, HALF_LIFE, CURVE }

## Which curve the fade follows. See the class description.
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
## slower or faster than one step per tick. ticks here are real ticks at the match's rate.
func value_at(ticks: float) -> float:
	var hold := TickDriver.ticks_at_rate(hold_ticks)
	if ticks < hold:
		return 1.0
	if ticks >= ends_after():
		return 0.0
	var into_fade := ticks - hold
	var fade := TickDriver.ticks_at_rate(fade_ticks)
	match mode:
		Mode.HALF_LIFE:
			# GDScript note: pow(0.5, n) halves n times; n can be fractional, which gives the smooth curve between halvings.
			return pow(0.5, into_fade / TickDriver.ticks_at_rate(half_life_ticks))
		Mode.CURVE:
			if curve:
				# GDScript note: sample_baked reads the curve at x from a table Godot precomputes, so it's cheap to call often.
				return clampf(curve.sample_baked(into_fade / fade), 0.0, 1.0)
			if not _warned_no_curve:
				_warned_no_curve = true
				push_warning("FadeProfile: mode is CURVE but no curve is drawn, so it fades in a straight line instead.")
			return 1.0 - into_fade / fade
		_:
			return 1.0 - into_fade / fade


## Ticks from the start until the value is nothing. From then on, value_at() gives exactly 0.0.
func ends_after() -> int:
	match mode:
		Mode.HALF_LIFE:
			return TickDriver.ticks_at_rate(hold_ticks) + TickDriver.ticks_at_rate(half_life_ticks) * HALVINGS_UNTIL_NOTHING
		_:
			return TickDriver.ticks_at_rate(hold_ticks) + TickDriver.ticks_at_rate(fade_ticks)
