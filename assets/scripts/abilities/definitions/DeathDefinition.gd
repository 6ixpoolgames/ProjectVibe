# Written by Claude (claude-opus-5-5), 2026-11-21. History: abilities/CHANGELOG.md.
@tool
## Death's settings: the base ones, with its defaults.
##
## A new one starts with the kind's defaults; see [AbilityDefinition] for variants. The Death node reads it.
class_name DeathDefinition
extends AbilityDefinition


func _init() -> void:
	super()
	# Tags are constants, so a misspelling is an error, not a warning while playing.
	category = Tags.STATUS_DEAD
	locks_out = [Tags.MOVEMENT, Tags.COMBAT, Tags.UTILITY]
	interrupt_priority = 1000
	interrupt_threshold = 1000
