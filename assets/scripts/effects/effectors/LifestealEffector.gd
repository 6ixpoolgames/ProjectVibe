# Written by Claude (claude-opus-5-5), 2026-11-10. History: effects/CHANGELOG.md.
## Gives whoever applied the effect a share of the damage it just dealt, once. An effector ([EffectEffector]).
##
## Put it after the effect's StatChangeEffector: effectors fire in order, and this reads the damage taken so far in this application (after
## resistances). Nothing happens with no source, a dead source, or no damage.
## Design: pawn spec 8.11.
class_name LifestealEffector
extends EffectEffector

## The share of the damage dealt that comes back, such as 0.3 for 30%.
@export_range(0.0, 1.0, 0.01, "or_greater") var fraction := 0.3
## The stat the source gets it back in.
@export var stat: StringName = StatusManager.HEALTH


func fire(application: EffectApplication) -> void:
	var source := application.source
	if not is_instance_valid(source) or source.is_dead() or source.status_manager == null:
		return
	if application.damage_dealt > 0.0:
		source.status_manager.change_current(stat, application.damage_dealt * fraction, source)
