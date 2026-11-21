# Written by Claude (claude-opus-5-5), 2026-11-21. History: abilities/CHANGELOG.md.
@tool
## Sprint's settings: Walk's, plus its charge.
##
## A new one starts with the kind's defaults; see [AbilityDefinition] for variants. The Sprint node reads it.
class_name SprintDefinition
extends WalkDefinition

## Seconds of sprinting on a full charge.
@export var max_charge: float = 3.0:
	set(value):
		max_charge = value
		_changed(&"max_charge", value)
## How fast the charge refills while not sprinting, in seconds of sprint per second: 0.5 refills at half the rate it drains.
@export var recharge_rate: float = 0.5:
	set(value):
		recharge_rate = value
		_changed(&"recharge_rate", value)
## Seconds after it stops before the charge starts refilling.
@export var recharge_delay: float = 1.0:
	set(value):
		recharge_delay = value
		_changed(&"recharge_delay", value)
## The charge needed to start, in seconds (at most [member max_charge]).
@export var min_start_charge: float = 0.5:
	set(value):
		min_start_charge = value
		_changed(&"min_start_charge", value)


func _init() -> void:
	super()
	trigger_action = &"sprint"
	category = Tags.MOVEMENT_SPRINT
	extra_categories = [Tags.MOVEMENT_BASIC]
	speed_stat = &"SprintSpeed"
	fallback_speed = 9.0
	interrupt_priority = 10 # above Walk, so sprinting cancels actions with a threshold of 10 or less
