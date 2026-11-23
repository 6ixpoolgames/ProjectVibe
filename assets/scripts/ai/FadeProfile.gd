# Written by Claude (claude-opus-5-5), 2026-11-09. History: ai/CHANGELOG.md.
## How a value fades over ticks, from full to nothing, as a Resource designers tune in the inspector.
##
## Used by behaviour persistence, memory's awareness and the target selector's current target bonus. One profile has one curve
## ([enum Mode]): LINEAR, HALF_LIFE (counts as nothing below 1%) or CURVE (a drawn curve). Its tick settings are written for 60 a
## second and used at the match's rate ([code]TickDriver.ticks_at_rate[/code]). For a fade no mode covers, extend it and override
## [method value_at] and [method ends_after]; the C++ memory store then calls it, and the C++ decider hands that pawn to GDScript.
## [codeblock]
## var fade := FadeProfile.new()  # or a .tres file made in the inspector, shared by everything that uses it
## fade.value_at(30)              # 1.0 at the start, falling to 0.0
## fade.ends_after()              # ticks until it's nothing; from then on value_at() gives exactly 0.0
## [/codeblock]
## Design: pawn spec 10.2.
class_name FadeProfile
extends Resource

## The kinds of fade: a straight line, halving, or a drawn curve.
enum Mode { LINEAR, HALF_LIFE, CURVE }

## Which curve the fade follows. See the class description.
@export var mode := Mode.LINEAR:
	set(value):
		mode = value
		emit_changed() # so whatever copied its settings (AIMemory's C++ store) copies them again
## Ticks at full strength before the fade begins.
@export_range(0, 36000, 1, "or_greater") var hold_ticks := 0:
	set(value):
		hold_ticks = value
		emit_changed() # so whatever copied its settings (AIMemory's C++ store) copies them again
## LINEAR and CURVE: ticks from full to nothing, after the hold.
@export_range(0, 36000, 1, "or_greater") var fade_ticks := 60:
	set(value):
		fade_ticks = value
		emit_changed() # so whatever copied its settings (AIMemory's C++ store) copies them again
## HALF_LIFE: the value halves every this many ticks, after the hold.
@export_range(0, 36000, 1, "or_greater") var half_life_ticks := 30:
	set(value):
		half_life_ticks = value
		emit_changed() # so whatever copied its settings (AIMemory's C++ store) copies them again
## CURVE: the shape of the fade. x runs from 0 (the end of the hold) to 1 (fade_ticks later); y is the value.
@export var curve: Curve:
	set(value):
		curve = value
		emit_changed() # so whatever copied its settings (AIMemory's C++ store) copies them again

# HALF_LIFE counts as over after this many halvings: 0.5^7 is about 0.8%, the first step below 1%.
const HALVINGS_UNTIL_NOTHING := 7

var _warned_no_curve := false


## Its settings as plain data at the match's tick rate: mode, hold, fade, half_life (ticks) and curve. Twin: the C++ decider's
## [code]fade_math.h[/code] does the same maths as [method value_at].
func values_at_rate() -> Dictionary:
	return {"mode": mode, "hold": TickDriver.ticks_at_rate(hold_ticks), "fade": TickDriver.ticks_at_rate(fade_ticks),
		"half_life": TickDriver.ticks_at_rate(half_life_ticks), "curve": curve}


## The value this many ticks after the fade started: 1.0 at the start, falling to 0.0. ticks can be fractional and are real ticks at
## the match's rate. A tick below 0 gives 1.0.
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
			# pow(0.5, n) halves n times; n can be fractional, which gives the smooth curve between halvings.
			return pow(0.5, into_fade / TickDriver.ticks_at_rate(half_life_ticks))
		Mode.CURVE:
			if curve:
				# sample_baked reads a table Godot precomputes, so it's cheap to call often.
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
