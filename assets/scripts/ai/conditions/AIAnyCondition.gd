# Written by Claude (claude-opus-5-5), 2026-11-17. History: ai/CHANGELOG.md.
## A condition that passes if any one of its conditions passes: "this, or that".
##
## Scaling spec 6.2. A behaviour's own list of conditions needs all of them ("this and that"); this is how to say "or". Look Toward,
## for example, runs while something half-noticed is in memory, or an unknown attacker hit the pawn lately. With an empty list it
## never passes (none of nothing passes). The conditions are checked in order and it stops at the first that passes.
class_name AIAnyCondition
extends AICondition

## Passes if any one of these does.
@export var conditions: Array[AICondition] = []


## Makes an "any of" condition in code.
static func make(list: Array[AICondition]) -> AIAnyCondition:
	var condition := AIAnyCondition.new()
	condition.conditions = list
	return condition


func passes(inputs: AIInputs, context: AIContextComponent, behaviour_salt: int) -> bool:
	for condition in conditions:
		if condition and condition.passes(inputs, context, behaviour_salt):
			return true
	return false


func describe() -> Dictionary:
	var children: Array = []
	for condition in conditions:
		if condition:
			children.append(condition.describe())
	return {"kind": "any", "conditions": children}


func add_input_slots(slots: Dictionary) -> void:
	for condition in conditions:
		if condition:
			condition.add_input_slots(slots)
