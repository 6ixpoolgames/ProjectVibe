# Written by Claude (claude-opus-5-5), 2026-11-15. History: abilities/CHANGELOG.md.
## A parry stance: while it runs, a hit from the front does nothing to this pawn, and the attacker is pushed back instead.
##
## This ability is the stance: it runs for duration (21 ticks, then a 90-tick cooldown), turns the pawn toward where it looks and holds
## it still. Parrying is its running effect's job: an effect granting status.parrying, holding a [ParryModifier] with the front's width
## and what the attacker gets (by default 120 degrees and nothing back), on the pawn while the stance lasts. Hits from the sides and back
## land as usual, and a knockback or a dash cancels the stance. A client sees its own stance at once; the parried hit's result arrives
## in snapshots.
## Design: pawn spec 8.15, 16.7.
class_name ParryAbility
extends AbilityBase

# Its settings with their own type: the same object as settings.
var _parry: ParryDefinition = null
# The default running effect, made once and shared: an effect made in code is recognised by its name, so there's one.
static var _default_effects: Array[Effect] = []

# Its settings, read from its definition (ability spec 3). Writing one is for a script's _init(); see AbilityBase._set.


## Its kind's defaults: a new [ParryDefinition].
func make_default_definition() -> AbilityDefinition:
	return ParryDefinition.new()


func _settings_changed() -> void:
	super()
	_parry = settings as ParryDefinition


func tick(dt: float) -> void:
	# yaw rolls back and look_yaw is input, so a replay turns the same way.
	if _parry.turn_degrees_per_second > 0.0:
		pawn.yaw = rotate_toward(pawn.yaw, look_yaw(), deg_to_rad(_parry.turn_degrees_per_second) * dt)


## Its parry: the first [ParryModifier] in its running effects, or null. The debug drawing reads the front's width from it.
func guard() -> ParryModifier:
	for effect in running_effects_now():
		for modifier in effect.modifiers if effect else []:
			if modifier is ParryModifier:
				return modifier
	return null


## With no running effects of its own, a Parry parries 120 degrees wide, with nothing back.
func default_running_effects_now() -> Array[Effect]:
	if _default_effects.is_empty():
		_default_effects.append(Effect.make_parrying())
	return _default_effects
