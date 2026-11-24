# Written by Claude (claude-opus-5-5), 2026-11-21. History: abilities/CHANGELOG.md.
@tool
## Jump's settings.
##
## A new one starts with the kind's defaults; see [AbilityDefinition] for variants. The Jump node reads it.
class_name JumpDefinition
extends AbilityDefinition

## Ticks at 60 a second after leaving the ground, without jumping, that a press still jumps.
@export_range(0, 60, 1) var coyote_ticks: int = 6:
	set(value):
		coyote_ticks = value
		_changed(&"coyote_ticks", value)


func _init() -> void:
	super()
	trigger_action = &"jump"
	# Tags are constants, so a misspelling is an error, not a warning while playing.
	category = Tags.ABILITY.MOVEMENT_JUMP
	extra_categories = [Tags.ABILITY.MOVEMENT_BASIC]
	buffer_window_ticks = 9
	interrupt_priority = 5 # between Walk (0) and Sprint (10)
