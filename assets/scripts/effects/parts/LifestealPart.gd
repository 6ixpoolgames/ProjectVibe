## Written by Claude (claude-opus-5-5), 2026-11-10: gives whoever applied the effect a share of the damage it just dealt, once. A
## do-once part (EffectPart). Pawn spec 8.11.
##
## Put it after the effect's StatChangePart: parts run in order, and this reads the Health they've taken so far in this application
## (after resistances), so a resisted hit heals less. Nothing happens with no source, a dead source, or no damage.
class_name LifestealPart
extends EffectPart

## The share of the damage dealt that comes back, such as 0.3 for 30%.
@export_range(0.0, 1.0, 0.01, "or_greater") var fraction := 0.3
## The stat the source gets it back in.
@export var stat: StringName = &"Health"


func apply_once(application: EffectApplication) -> void:
	var source := application.source
	if not is_instance_valid(source) or source.is_dead() or source.stat_manager == null:
		return
	if application.damage_dealt > 0.0:
		source.stat_manager.change_current(stat, application.damage_dealt * fraction)
