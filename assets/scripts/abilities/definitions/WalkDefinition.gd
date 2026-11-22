# Written by Claude (claude-opus-5-5), 2026-11-21. History: abilities/CHANGELOG.md.
@tool
## Walk's settings: the default locomotion.
##
## A new one starts with the kind's defaults; see [AbilityDefinition] for variants. The Walk node reads it.
class_name WalkDefinition
extends AbilityDefinition

## The stat for top speed, in metres per second. Sprint uses its own.
@export var speed_stat: StringName = &"MoveSpeed":
	set(value):
		speed_stat = value
		_changed(&"speed_stat", value)
## Top speed when the pawn has no such stat.
@export var fallback_speed: float = 5.0:
	set(value):
		fallback_speed = value
		_changed(&"fallback_speed", value)


func _init() -> void:
	super()
	# Tags are constants, so a misspelling is an error, not a warning while playing.
	category = Tags.ABILITY.MOVEMENT_WALK
	extra_categories = [Tags.ABILITY.MOVEMENT_BASIC] # a group, so a rule can name all basic movement at once
	# Moving cancels only actions with a threshold of 0, such as an emote. Locomotion never blocks an action.
	interrupt_priority = 0
	interrupt_threshold = 0
