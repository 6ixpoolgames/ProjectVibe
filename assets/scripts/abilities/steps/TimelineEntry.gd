# Written by Claude (claude-opus-5-5), 2026-11-22. History: abilities/CHANGELOG.md.
## One entry of an ability's step timeline: which step runs, the values it runs with, and when it starts (ability spec 6.2).
##
## Ticks count from the ability's start. An entry starts when the first of its rules holds: [member at_tick]; [member after] another
## entry starts or ends (with the [member end_reasons] that count, so a cancelled windup doesn't swing), plus [member delay_ticks]; or
## its [member condition]. With no rule set it starts with the ability. Each entry runs once per run of its ability; one step node can be
## in several entries (a second sweep on a backswing), one at a time.
## [codeblock]
## Turn    at_tick 0
## Windup  at_tick 0
## Sweep   after "Windup" (ends, done)          values {"start_angle": 60.0, "end_angle": -60.0}
## [/codeblock]
class_name TimelineEntry
extends Resource

## What the [member after] entry must do: start, or end with one of [member end_reasons].
enum After { ENDS, STARTS }
## Why an entry ended, as flags for [member end_reasons].
enum Reason { DONE = 1, RELEASED = 2, FAILED = 4, CANCELLED = 8 }

## The step node it runs: the name of a step child of the ability.
@export var step: StringName = &""
## What other entries call it in [member after]. Empty: the step's name (give one when a step is in several entries).
@export var label: StringName = &""
## Starts this many ticks after the ability, at 60 a second (converted for the match's rate). -1: not by time.
@export_range(-1, 6000, 1, "or_greater") var at_tick := -1
## Starts when this entry (its label) starts or ends. Empty: not after another.
@export var after: StringName = &""
## Whether it follows the [member after] entry's start or its end.
@export var after_event := After.ENDS
## With ENDS, the reasons that count. Done and released by default: a released step's next steps start as if it were done.
@export_flags("Done:1", "Released:2", "Failed:4", "Cancelled:8") var end_reasons := Reason.DONE | Reason.RELEASED
## Ticks after the [member after] entry's start or end, at 60 a second.
@export_range(0, 6000, 1, "or_greater") var delay_ticks := 0
## Starts on the first tick this holds (checked every tick the ability runs). Empty: not by a condition.
@export var condition: AbilityCondition = null
## Values its step runs with in this entry, by property name, in place of the step's own: {"length_ticks": 12}.
@export var values: Dictionary = {}
## On: no rule starts it; only code does ([method AbilityBase.start_step]), as a bespoke script would.
@export var manual := false


## The name other entries use for it.
func get_label() -> StringName:
	return label if label != &"" else step


## True if no rule is set, so it starts with the ability.
# REFACTOR: named for abilities, though behaviour steps will share the timeline (pawn spec 16.10 step 7). See steps/CHANGELOG.md.
func starts_with_ability() -> bool:
	return not manual and at_tick < 0 and after == &"" and condition == null


## An entry for this step that starts this many ticks after the ability (0: with it).
static func at(step_name: StringName, tick := 0, run_values := {}) -> TimelineEntry:
	var entry := TimelineEntry.new()
	entry.step = step_name
	entry.at_tick = tick
	entry.values = run_values
	return entry


## An entry for this step that starts when another entry ends (done or released, by default).
static func after_end_of(step_name: StringName, other: StringName, run_values := {}, entry_label := &"") -> TimelineEntry:
	var entry := TimelineEntry.new()
	entry.step = step_name
	entry.after = other
	entry.values = run_values
	entry.label = entry_label
	return entry
