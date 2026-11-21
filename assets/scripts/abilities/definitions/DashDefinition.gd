# Written by Claude (claude-opus-5-5), 2026-11-21. History: abilities/CHANGELOG.md.
@tool
## Dash's settings.
##
## A new one starts with the kind's defaults; see [AbilityDefinition] for variants. The Dash node reads it.
class_name DashDefinition
extends AbilityDefinition

## The stat for the speed-up's acceleration, in metres per second per second.
@export var acceleration_stat: StringName = &"DashAcceleration":
	set(value):
		acceleration_stat = value
		_changed(&"acceleration_stat", value)
## The speed-up's acceleration when the pawn has no such stat.
@export var fallback_acceleration: float = 100.0:
	set(value):
		fallback_acceleration = value
		_changed(&"fallback_acceleration", value)
## How long it speeds up for, in seconds.
@export_range(0.0, 2.0, 0.01, "or_greater") var speed_up_seconds: float = 0.1:
	set(value):
		speed_up_seconds = value
		_changed(&"speed_up_seconds", value)
## How hard it slows down after, in metres per second per second.
@export_range(0.0, 1000.0, 1.0, "or_greater") var slow_down_deceleration: float = 50.0:
	set(value):
		slow_down_deceleration = value
		_changed(&"slow_down_deceleration", value)
## How long it slows down for, in seconds. The defaults take off what the speed-up added (50 x 0.2 against 100 x 0.1).
@export_range(0.0, 2.0, 0.01, "or_greater") var slow_down_seconds: float = 0.2:
	set(value):
		slow_down_seconds = value
		_changed(&"slow_down_seconds", value)
## On: it can start in the air as well as on the ground. Off: ground only.
@export var usable_in_air: bool = true:
	set(value):
		usable_in_air = value
		_changed(&"usable_in_air", value)


func _init() -> void:
	super()
	trigger_action = &"dash"
	# Tags are constants, so a misspelling is an error, not a warning while playing.
	category = Tags.MOVEMENT_DASH
	needs_full_movement = true # a dash is too fast for the crowd mover's checks (pawn spec 8.22)
	extra_categories = [Tags.MOVEMENT_ADVANCED] # the AI asks for this group, not for "dash"
	# Its length comes from its two phases (DashAbility.duration_ticks), not duration.
	duration = 0.0
	cooldown = 2.0
	# The basic movement group: walk, sprint and jump.
	locks_out = [Tags.MOVEMENT_BASIC]
	interrupt_priority = 40 # above knockback's threshold (35)
	interrupt_threshold = 25 # a knockback (30) cancels it once its invulnerability is over
	pauses_locomotion = true # Walk would otherwise slow the pawn as well
