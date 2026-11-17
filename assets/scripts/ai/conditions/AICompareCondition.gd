# Written by Claude (claude-opus-5-5), 2026-11-17. History: ai/CHANGELOG.md.
## A condition that compares one input with a number, or with another input plus a number.
##
## Inputs that are yes or no are 1 or 0, so compare them with EQUAL 1 or EQUAL 0. Design: scaling spec 6.2. Examples:
## [codeblock]
## target_distance  AT_MOST  2.5                           # the target is within 2.5 m
## most_aware_certain  EQUAL  1                            # the AI is certain about what it's most aware of
## ticks_since_unknown_hit  AT_MOST  300                   # hit by someone unknown within 5 s (ticks at 60 a second)
## target_distance  AT_MOST  -0.5, other_input "reach"     # within the "reach" input minus half a metre
## [/codeblock]
class_name AICompareCondition
extends AICondition

## How the input is compared with the value.
enum Comparison {
	AT_MOST, ## input <= value
	LESS_THAN, ## input < value
	AT_LEAST, ## input >= value
	MORE_THAN, ## input > value
	EQUAL, ## input == value
	NOT_EQUAL, ## input != value
}

## The input to check, such as target_distance. See [AIInputs] for the built-in ones.
@export_custom(PROPERTY_HINT_ENUM_SUGGESTION, AICondition.INPUT_SUGGESTIONS) var input := ""
## How it's compared.
@export var comparison := Comparison.AT_MOST
## The number it's compared with. For an input that's a time in ticks (its name starts with ticks_), written for 60 ticks a second.
## With [member other_input] set, it's added to that input's value instead.
@export var value := 0.0
## Optional: compare with this input's value plus [member value], instead of with value alone.
@export_custom(PROPERTY_HINT_ENUM_SUGGESTION, AICondition.INPUT_SUGGESTIONS) var other_input := ""

var _slot := -1
var _other_slot := -1
var _ticks := false # the input is a time in ticks, so value is converted to the match's rate
var _resolved := false


## Makes a compare condition in code: AICompareCondition.make(AIInputs.TARGET_DISTANCE, AICompareCondition.Comparison.AT_MOST, 2.5).
static func make(input_name: StringName, how: Comparison, number: float, other_name: StringName = &"") -> AICompareCondition:
	var condition := AICompareCondition.new()
	condition.input = input_name
	condition.comparison = how
	condition.value = number
	condition.other_input = other_name
	return condition


func passes(inputs: AIInputs, _context: AIContextComponent, _behaviour_salt: int) -> bool:
	if not _resolved:
		_resolve()
	var left := inputs.value(_slot)
	var right := AICondition.at_rate_for(_slot, value) if _ticks else value
	if _other_slot >= 0:
		right += inputs.value(_other_slot)
	match comparison:
		Comparison.AT_MOST: return left <= right
		Comparison.LESS_THAN: return left < right
		Comparison.AT_LEAST: return left >= right
		Comparison.MORE_THAN: return left > right
		Comparison.EQUAL: return left == right
		_: return left != right


func describe() -> Dictionary:
	if not _resolved:
		_resolve()
	return {"kind": "compare", "input_slot": _slot, "comparison": comparison, "value": AICondition.at_rate_for(_slot, value),
		"other_slot": _other_slot}


func add_input_slots(slots: Dictionary) -> void:
	if not _resolved:
		_resolve()
	slots[_slot] = true
	if _other_slot >= 0:
		slots[_other_slot] = true


# The inputs' slots, looked up once. A Resource can be shared by many pawns (the same brain scene); the slots are the same for every
# pawn, so sharing the looked-up numbers is safe.
func _resolve() -> void:
	_resolved = true
	_slot = AIInputs.slot_of(StringName(input))
	_other_slot = AIInputs.slot_of(StringName(other_input)) if other_input != "" else -1
	_ticks = AIInputs.is_ticks(_slot)
