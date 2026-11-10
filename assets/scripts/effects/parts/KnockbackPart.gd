## Written by Claude (claude-opus-5-5), 2026-11-10: pushes the pawn, once, through its own KnockbackAbility. A do-once part (EffectPart).
## Pawn spec 8.11; it replaces MeleeAttackAbility's knockback settings.
##
## The owner's design: the pawn being hit starts its own Knockback ability, so its own interrupt rules decide what happens. A swing it
## was doing is cancelled (Knockback's interrupt priority 30 beats a swing's threshold 15), and a running Dash isn't (its threshold is
## 40). A pawn with no KnockbackAbility isn't pushed.
##
## The push goes along the hit's direction, from the attacker toward the target. With no hit (an effect from code, or one an ability
## put on its own pawn), it goes straight back from the way the pawn faces.
class_name KnockbackPart
extends EffectPart

## How fast the push is at its start, in metres per second. It fades to nothing over its ticks.
@export_range(0.0, 50.0, 0.1, "or_greater") var speed := 6.0
## How many ticks the push lasts, written for 60 ticks a second (converted to the match's rate).
@export_range(1, 120, 1, "or_greater") var ticks := 10
## How fast it lifts the pawn, in metres per second upward, for a small hop back. 0: it stays on the ground. A pawn already in the
## air isn't lifted again (KnockbackAbility).
@export_range(0.0, 20.0, 0.1, "or_greater") var hop_speed := 0.0


func apply_once(application: EffectApplication) -> void:
	var target := application.target
	if target.ability_manager == null or speed <= 0.0:
		return
	var direction := Vector3.ZERO
	if application.hit and application.hit.direction != Vector3.ZERO:
		direction = application.hit.direction
	else:
		direction = Vector3(sin(target.yaw), 0.0, cos(target.yaw)) # back: a pawn faces -Z at yaw 0
	for ability in target.ability_manager.get_abilities():
		if ability is KnockbackAbility:
			ability.push(direction * speed, TickDriver.ticks_at_rate(ticks), hop_speed)
			return
