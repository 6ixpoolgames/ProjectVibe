# Written by Claude (claude-opus-5-5), 2026-11-17. History: ai/CHANGELOG.md.
## A condition that passes if any one of its conditions passes: "this, or that".
##
## A behaviour's own list of conditions needs all of them; this is how to say "or" (Look Toward: something half-noticed, or an unknown
## attacker hit lately). The conditions are checked in order and it stops at the first that passes; an empty list never passes.
## Design: scaling spec 6.2.
class_name AIAnyCondition
extends AICondition

## Passes if any one of these does.
@export var conditions: Array[AICondition] = []


## Makes an "any of" condition in code.
static func make(list: Array[AICondition]) -> AIAnyCondition:
	var condition := AIAnyCondition.new()
	condition.conditions = list
	return condition


func passes(inputs: AIInputs, context: AIManager, behaviour_salt: int) -> bool:
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
