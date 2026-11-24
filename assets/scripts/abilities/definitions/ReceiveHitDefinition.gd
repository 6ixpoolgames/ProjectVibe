# Written by Claude (claude-opus-5-5), 2026-11-24. History: abilities/CHANGELOG.md.
@tool
## The hit ability's settings: the base ones, with its defaults.
##
## A new one starts with the kind's defaults; see [AbilityDefinition] for variants. The ReceiveHit node reads it. It starts on
## event.hit.taken; its start requirements decide whether a hit counts at all (by default, not while the pawn owns status.hit_immune).
class_name ReceiveHitDefinition
extends AbilityDefinition


func _init() -> void:
	super()
	# Tags are constants, so a misspelling is an error, not a warning while playing.
	category = Tags.ABILITY.RECEIVE_HIT
	trigger_event = Tags.EVENT.HIT_TAKEN
	start_requirements = TagQuery.make([], [], [Tags.STATUS.HIT_IMMUNE])
