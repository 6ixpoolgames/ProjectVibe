# Written by Claude (claude-opus-5-5), 2026-11-17. History: ai/CHANGELOG.md.
## Turns one input into an amount from 0 to 1 that scales a behaviour's score: the "how much" to a condition's "whether".
##
## Scaling spec 6.2. A straight line: [member from_value] gives 0, [member to_value] gives 1, with 0 below and 1 above. Set to_value
## below from_value to turn it round (more input, less score). A behaviour's score is
## [code]low + (max_score - low) × every curve's amount multiplied together[/code], where low is min_score, or 0 when min_score isn't
## set ([method AIBehaviourBase.score]). With no curves the score is max_score, as before.
## [codeblock]
## target_distance, from 20 to 2     # 0 at 20 m or further, 1 at 2 m or closer: the nearer, the keener
## [/codeblock]
class_name AIScoreCurve
extends Resource

## The input it reads, such as target_distance. See [AIInputs].
@export_custom(PROPERTY_HINT_ENUM_SUGGESTION, AICondition.INPUT_SUGGESTIONS) var input := ""
## The input value that gives 0. For a time in ticks, written for 60 ticks a second.
@export var from_value := 0.0
## The input value that gives 1.
@export var to_value := 1.0

var _slot := -1
var _resolved := false


## Makes a curve in code.
static func make(input_name: StringName, zero_at: float, one_at: float) -> AIScoreCurve:
	var curve := AIScoreCurve.new()
	curve.input = input_name
	curve.from_value = zero_at
	curve.to_value = one_at
	return curve


## The amount from 0 to 1 for this pawn's inputs now.
func amount(inputs: AIInputs) -> float:
	if not _resolved:
		_resolve()
	var low := AICondition.at_rate_for(_slot, from_value)
	var high := AICondition.at_rate_for(_slot, to_value)
	if high == low:
		return 1.0 if inputs.value(_slot) >= high else 0.0
	return clampf((inputs.value(_slot) - low) / (high - low), 0.0, 1.0)


## The curve as plain data, for the C++ decider, with times converted to the match's rate.
func describe() -> Dictionary:
	if not _resolved:
		_resolve()
	return {"input_slot": _slot, "from": AICondition.at_rate_for(_slot, from_value), "to": AICondition.at_rate_for(_slot, to_value)}


## Adds the slot of the input it reads to slots (as a key).
func add_input_slots(slots: Dictionary) -> void:
	if not _resolved:
		_resolve()
	slots[_slot] = true


func _resolve() -> void:
	_resolved = true
	_slot = AIInputs.slot_of(StringName(input))
