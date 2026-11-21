# Written by Claude (claude-opus-5-5), 2026-11-21. History: abilities/CHANGELOG.md.
@tool
## Knockback's settings: the base ones, with its defaults.
##
## A new one starts with the kind's defaults; see [AbilityDefinition] for variants. The Knockback node reads it.
class_name KnockbackDefinition
extends AbilityDefinition


func _init() -> void:
	super()
	# Tags are constants, so a misspelling is an error, not a warning while playing.
	category = Tags.COMBAT_KNOCKBACK
	needs_full_movement = true # a push should collide properly, and may lift (pawn spec 8.22)
	locks_out = [Tags.MOVEMENT, Tags.COMBAT]
	interrupt_priority = 30
	interrupt_threshold = 35 # only Dash (40) cancels it
