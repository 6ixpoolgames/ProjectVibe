# Written by Claude (claude-opus-5-5), 2026-11-21. History: abilities/CHANGELOG.md.
@tool
## Jump's settings.
##
## A new one starts with the kind's defaults; see [AbilityDefinition] for variants. The Jump node reads it.
class_name JumpDefinition
extends AbilityDefinition

## Seconds after leaving the ground, without jumping, that a press still jumps.
@export_range(0.0, 1.0, 0.01) var coyote_time: float = 0.1:
	set(value):
		coyote_time = value
		_changed(&"coyote_time", value)


func _init() -> void:
	super()
	trigger_action = &"jump"
	# Tags are constants, so a misspelling is an error, not a warning while playing.
	category = Tags.MOVEMENT_JUMP
	extra_categories = [Tags.MOVEMENT_BASIC]
	buffer_window = 0.15
	interrupt_priority = 5 # between Walk (0) and Sprint (10)
