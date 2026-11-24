# Written by Claude (claude-opus-5-5), 2026-11-15. History: abilities/CHANGELOG.md.
## A parry stance: while it runs, a hit from the front does nothing to this pawn, and the attacker is pushed back instead.
##
## This ability is the stance: it runs for duration (0.35 s, then a 1.5 s cooldown), turns the pawn toward where it looks and holds it
## still. Turning hits away is its [ParryInterceptor] child's job (made by default with the 120 degree front), and what the attacker
## gets is that interceptor's ON_INTERCEPT EffectApplier children. Hits from the sides and back land as usual, and a knockback or a dash
## cancels the stance. A client sees its own stance at once; the parried hit's result arrives in snapshots.
## Design: pawn spec 8.15, 8.23.
class_name ParryAbility
extends AbilityBase

# Its settings with their own type: the same object as settings.
var _parry: ParryDefinition = null

# Its settings, read from its definition (ability spec 3). Writing one is for a script's _init(); see AbilityBase._write_setting.


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


## Its [ParryInterceptor], or null. The debug drawing reads the front's width from it.
func guard() -> ParryInterceptor:
	for interceptor in interceptors:
		if interceptor is ParryInterceptor:
			return interceptor
	return null


## With no interceptor of its own, a ParryInterceptor with the default front (120 degrees).
func make_default_interceptors() -> void:
	var front := ParryInterceptor.new()
	front.name = "Front"
	add_child(front)
