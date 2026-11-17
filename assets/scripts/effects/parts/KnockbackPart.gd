# Written by Claude (claude-opus-5-5), 2026-11-10. History: effects/CHANGELOG.md.
## Pushes the pawn, once, through its own KnockbackAbility. A do-once part ([EffectPart]).
##
## The pawn being hit starts its own Knockback ability, so its own interrupt rules decide what the push cancels; a pawn with no
## KnockbackAbility isn't pushed. The push goes along the hit's direction, or straight back from the way the pawn faces if there's no hit.
## Design: pawn spec 8.11.
class_name KnockbackPart
extends EffectPart

## How fast the push is at its start, in metres per second. It fades to nothing over its ticks.
@export_range(0.0, 50.0, 0.1, "or_greater") var speed := 6.0
## How many ticks the push lasts, written for 60 a second (converted with [method TickDriver.ticks_at_rate]).
@export_range(1, 120, 1, "or_greater") var ticks := 10
## How fast it lifts the pawn upward, in metres per second, for a small hop. 0: stays on the ground. A pawn already airborne isn't lifted.
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
	var knockback := target.ability_manager.get_knockback() # found once by the manager, when it collects its abilities
	if knockback:
		knockback.push(direction * speed, TickDriver.ticks_at_rate(ticks), hop_speed)
