# Written by Claude (claude-opus-5-5), 2026-11-21. History: abilities/CHANGELOG.md.
@tool
## A parry's settings.
##
## A new one starts with the kind's defaults; see [AbilityDefinition] for variants. The Parry node reads it.
class_name ParryDefinition
extends AbilityDefinition

## How fast it turns toward where the pawn looks while it runs, in degrees per second. 0: it doesn't turn.
@export_range(0.0, 3600.0, 10.0, "or_greater") var turn_degrees_per_second: float = 900.0:
	set(value):
		turn_degrees_per_second = value
		_changed(&"turn_degrees_per_second", value)


func _init() -> void:
	super()
	trigger_action = &"parry"
	category = Tags.ABILITY.COMBAT_PARRY
	duration = 0.35
	cooldown = 1.5
	locks_out = [Tags.ABILITY.MOVEMENT, Tags.ABILITY.COMBAT]
	interrupt_priority = 10
	interrupt_threshold = 20
