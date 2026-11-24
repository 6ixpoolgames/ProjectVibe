# Written by Claude (claude-opus-5-5), 2026-11-21. History: abilities/CHANGELOG.md.
@tool
## Sprint's settings: Walk's, plus its charge.
##
## A new one starts with the kind's defaults; see [AbilityDefinition] for variants. The Sprint node reads it.
class_name SprintDefinition
extends WalkDefinition

## Ticks at 60 a second of sprinting on a full charge (180: 3 s).
@export_range(0, 3600, 1, "or_greater") var max_charge_ticks: int = 180:
	set(value):
		max_charge_ticks = value
		_changed(&"max_charge_ticks", value)
## How fast the charge refills while not sprinting, in ticks of sprint per tick: 0.5 refills at half the rate it drains.
@export var recharge_rate: float = 0.5:
	set(value):
		recharge_rate = value
		_changed(&"recharge_rate", value)
## Ticks at 60 a second after it stops before the charge starts refilling.
@export_range(0, 3600, 1, "or_greater") var recharge_delay_ticks: int = 60:
	set(value):
		recharge_delay_ticks = value
		_changed(&"recharge_delay_ticks", value)
## The charge needed to start, in ticks at 60 a second (at most [member max_charge_ticks]).
@export_range(0, 3600, 1, "or_greater") var min_start_charge_ticks: int = 30:
	set(value):
		min_start_charge_ticks = value
		_changed(&"min_start_charge_ticks", value)


func _init() -> void:
	super()
	trigger_action = &"sprint"
	category = Tags.ABILITY.MOVEMENT_SPRINT
	extra_categories = [Tags.ABILITY.MOVEMENT_BASIC]
	speed_stat = &"SprintSpeed"
	fallback_speed = 9.0
	interrupt_priority = 10 # above Walk, so sprinting cancels actions with a threshold of 10 or less
