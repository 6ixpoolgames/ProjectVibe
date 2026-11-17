# Written by Claude (claude-opus-5-5), 2026-11-07. History: abilities/CHANGELOG.md.
## Running faster for a while: a locomotion ability bound to &"sprint".
##
## It moves like Walk, at SprintSpeed. While &"sprint" is held and it's ready it runs instead of Walk; it has a maximum duration and a
## cooldown in place of stamina, so it has downtime. An AI uses it by holding &"sprint".
## Design: pawn spec 8.5.
class_name SprintAbility
extends WalkAbility


func _init() -> void:
	super()
	trigger_action = &"sprint"
	# Tags are constants, so a misspelling is an error, not a warning while playing.
	category = Tags.MOVEMENT_SPRINT
	extra_categories = [Tags.MOVEMENT_BASIC]
	speed_stat = &"SprintSpeed"
	fallback_speed = 9.0
	duration = 3.0
	cooldown = 4.0
	interrupt_priority = 10 # above Walk, so sprinting cancels actions with a threshold of 10 or less
