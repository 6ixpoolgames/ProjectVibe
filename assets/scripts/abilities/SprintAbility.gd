## Written by Claude (claude-opus-5-5), 2026-11-07: running faster for a while. A locomotion ability bound to &"sprint". Pawn spec
## section 8.5.
##
## It walks the same way Walk does, at SprintSpeed. For now it has a maximum duration and a cooldown instead of stamina, the owner's
## choice for testing: while &"sprint" is held and Sprint is ready, it runs instead of Walk. When its time runs out, or the key is let
## go, it stops, its cooldown starts, and Walk takes over even if the key is still held. So it wins over Walk when it's ready, but has
## downtime. An AI uses it the same way, by holding &"sprint".
class_name SprintAbility
extends WalkAbility


func _init() -> void:
	super()
	trigger_action = &"sprint"
	category = &"movement.sprint"
	speed_stat = &"SprintSpeed"
	fallback_speed = 9.0
	duration = 3.0
	cooldown = 4.0
	interrupt_priority = 10 # Claude 2026-11-09: above Walk, so sprinting cancels actions with a threshold of 10 or less
