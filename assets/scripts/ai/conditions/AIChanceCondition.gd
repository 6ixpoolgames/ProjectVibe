# Written by Claude (claude-opus-5-5), 2026-11-17. History: ai/CHANGELOG.md.
## A condition that passes on a random roll, with a chance from 0 to 1, the same roll on every run.
##
## Scaling spec 6.2. The roll comes from the AI's replayable random numbers ([method AIContextComponent.random_unit_at]): the pawn,
## a tick and a salt. By default it's rolled again at every decision. With [member once_per_input] set, the input's value takes the
## tick's place, so the roll stays the same until that input changes: Parry rolls once per swing, with incoming_attack_tick.
## [codeblock]
## chance 0.3, once_per_input incoming_attack_tick, salt_input incoming_attacker   # 30%, once per swing
## [/codeblock]
class_name AIChanceCondition
extends AICondition

## How likely it is to pass, from 0 (never) to 1 (always).
@export_range(0.0, 1.0, 0.01) var chance := 0.5
## What the roll is for. Two chance conditions on one behaviour need different salts, or they'd roll the same number.
@export var salt := 0
## Optional: roll once per value of this input instead of once per decision, such as incoming_attack_tick for once per swing.
@export_custom(PROPERTY_HINT_ENUM_SUGGESTION, AICondition.INPUT_SUGGESTIONS) var once_per_input := ""
## Optional: an input mixed into the salt, such as incoming_attacker, so two swings that start on the same tick roll differently.
@export_custom(PROPERTY_HINT_ENUM_SUGGESTION, AICondition.INPUT_SUGGESTIONS) var salt_input := ""

var _key_slot := -1
var _salt_slot := -1
var _resolved := false


## Makes a chance condition in code.
static func make(passing_chance: float, roll_salt: int, once_per: StringName = &"", mixed_in: StringName = &"") -> AIChanceCondition:
	var condition := AIChanceCondition.new()
	condition.chance = passing_chance
	condition.salt = roll_salt
	condition.once_per_input = once_per
	condition.salt_input = mixed_in
	return condition


func passes(inputs: AIInputs, context: AIContextComponent, behaviour_salt: int) -> bool:
	if not _resolved:
		_resolve()
	return context.random_unit_at(roll_tick(inputs, context.current_tick), roll_salt(inputs, behaviour_salt)) < chance


## The tick the roll is made for: the decision's, or [member once_per_input]'s value.
func roll_tick(inputs: AIInputs, now: int) -> int:
	return int(inputs.value(_key_slot)) if _key_slot >= 0 else now


## The salt the roll is made with: [member salt], the behaviour's own number and [member salt_input]'s value (its low 16 bits).
func roll_salt(inputs: AIInputs, behaviour_salt: int) -> int:
	var mixed := salt ^ behaviour_salt
	if _salt_slot >= 0:
		mixed ^= int(inputs.value(_salt_slot)) & 0xFFFF
	return mixed


func describe() -> Dictionary:
	if not _resolved:
		_resolve()
	return {"kind": "chance", "chance": chance, "salt": salt, "key_slot": _key_slot, "salt_slot": _salt_slot}


func add_input_slots(slots: Dictionary) -> void:
	if not _resolved:
		_resolve()
	if _key_slot >= 0:
		slots[_key_slot] = true
	if _salt_slot >= 0:
		slots[_salt_slot] = true


func _resolve() -> void:
	_resolved = true
	_key_slot = AIInputs.slot_of(StringName(once_per_input)) if once_per_input != "" else -1
	_salt_slot = AIInputs.slot_of(StringName(salt_input)) if salt_input != "" else -1
