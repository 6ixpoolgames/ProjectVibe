# Written by Claude (claude-opus-5-5), 2026-11-10. History: effects/CHANGELOG.md.
## Pushes the pawn, once, through its own KnockbackAbility. An effector ([EffectEffector]).
##
## It sends the pawn [code]event.reaction.knockback[/code] with the push ([KnockbackEventData]), and the pawn's Knockback ability
## starts from it, so its own interrupt rules decide what the push cancels; a pawn with nothing answering the event isn't pushed. The
## push goes along the hit's direction, or straight back from the way the pawn faces if there's no hit.
## Design: pawn spec 8.11, 16.7.
class_name KnockbackEffector
extends EffectEffector

## How fast the push is at its start, in metres per second. It fades to nothing over its ticks.
@export_range(0.0, 50.0, 0.1, "or_greater") var speed := 6.0
## How many ticks the push lasts, written for 60 a second (converted with [method TickDriver.ticks_at_rate]).
@export_range(1, 120, 1, "or_greater") var ticks := 10
## How fast it lifts the pawn upward, in metres per second, for a small hop. 0: stays on the ground. A pawn already airborne isn't lifted.
@export_range(0.0, 20.0, 0.1, "or_greater") var hop_speed := 0.0


func fire(application: EffectApplication) -> void:
	var target := application.target
	if target.ability_manager == null or speed <= 0.0:
		return
	var direction := Vector3.ZERO
	if application.hit and application.hit.direction != Vector3.ZERO:
		direction = application.hit.direction
	else:
		direction = Vector3(sin(target.yaw), 0.0, cos(target.yaw)) # back: a pawn faces -Z at yaw 0
	var data := KnockbackEventData.new()
	data.instigator = application.source
	data.optional_object = application.hit
	data.push_velocity = direction * speed
	data.push_ticks = TickDriver.ticks_at_rate(ticks)
	data.hop_speed = hop_speed
	target.send_event(Tags.EVENT.REACTION_KNOCKBACK, data)
