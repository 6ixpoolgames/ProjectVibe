# Written by Claude (claude-opus-5-5), 2026-11-10. History: effects/CHANGELOG.md.
## Gives whoever applied the effect a share of the damage it just dealt, once. A do-once part ([EffectPart]).
##
## Put it after the effect's StatChangePart: parts run in order, and this reads the damage taken so far in this application (after
## resistances). Nothing happens with no source, a dead source, or no damage.
## Design: pawn spec 8.11.
class_name LifestealPart
extends EffectPart

## The share of the damage dealt that comes back, such as 0.3 for 30%.
@export_range(0.0, 1.0, 0.01, "or_greater") var fraction := 0.3
## The stat the source gets it back in.
@export var stat: StringName = StatManager.HEALTH


func apply_once(application: EffectApplication) -> void:
	var source := application.source
	if not is_instance_valid(source) or source.is_dead() or source.stat_manager == null:
		return
	if application.damage_dealt > 0.0:
		source.stat_manager.change_current(stat, application.damage_dealt * fraction)
