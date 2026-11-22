# Written by Claude (claude-opus-5-5), 2026-11-21. History: abilities/CHANGELOG.md.
@tool
## A melee attack's settings: its timings, reach and sweep.
##
## A new one starts with the kind's defaults; see [AbilityDefinition] for variants. The MeleeAttack node reads it.
class_name MeleeAttackDefinition
extends AbilityDefinition

## Ticks from the start of the swing to when it can hit (its Windup step's length).
@export_range(0, 120, 1, "or_greater") var windup_ticks: int = 8:
	set(value):
		windup_ticks = value
		_changed(&"windup_ticks", value)
## Ticks it can hit for (its Sweep step's length).
@export_range(1, 120, 1, "or_greater") var hit_ticks: int = 4:
	set(value):
		hit_ticks = value
		_changed(&"hit_ticks", value)
## Ticks after hitting before it's over (its Recovery step's length).
@export_range(0, 120, 1, "or_greater") var recovery_ticks: int = 12:
	set(value):
		recovery_ticks = value
		_changed(&"recovery_ticks", value)
## How far it reaches, in metres from the pawn: the far edge of the hit sphere.
@export_range(0.1, 20.0, 0.05, "or_greater") var attack_range: float = 1.8:
	set(value):
		attack_range = value
		_changed(&"attack_range", value)
## The hit sphere's radius, in metres.
@export_range(0.05, 10.0, 0.05, "or_greater") var hit_radius: float = 0.8:
	set(value):
		hit_radius = value
		_changed(&"hit_radius", value)
## The hit sphere's height above the pawn's feet, in metres: about the chest.
@export var hit_height: float = 1.0:
	set(value):
		hit_height = value
		_changed(&"hit_height", value)
## How far round the hit sphere sweeps during the hit ticks, in degrees, centred straight ahead. 0: it holds still.
@export_range(0.0, 360.0, 1.0) var sweep_degrees: float = 100.0:
	set(value):
		sweep_degrees = value
		_changed(&"sweep_degrees", value)
## On: the sweep goes from the pawn's left to its right. Off: right to left.
@export var sweep_from_left: bool = false:
	set(value):
		sweep_from_left = value
		_changed(&"sweep_from_left", value)
## How far above or below hit_height the sphere is at the start of the sweep, in metres: slashes, rises, chops. 0: level.
@export_range(-3.0, 3.0, 0.05, "or_greater", "or_less") var height_at_sweep_start: float = 0.0:
	set(value):
		height_at_sweep_start = value
		_changed(&"height_at_sweep_start", value)
## The same at the end of the sweep. Between the two the sphere moves in a straight line up or down.
@export_range(-3.0, 3.0, 0.05, "or_greater", "or_less") var height_at_sweep_end: float = 0.0:
	set(value):
		height_at_sweep_end = value
		_changed(&"height_at_sweep_end", value)
## The swing's path as keys (ability spec 7): points it goes through, in order of their time, measured from the pawn. Fewer than two: the
## arc from the settings above (sweep_degrees and the heights). A weapon's path baked from its animation goes here.
@export var sweep_keys: Array[SweepKey] = []:
	set(value):
		sweep_keys = value
		_changed(&"sweep_keys", value)
## Degrees per second it turns toward where the pawn looks (its TurnToFace step). -1: the pawn's TurnRate stat (540 without one).
## 0: no turning.
@export_range(-1.0, 3600.0, 10.0, "or_greater") var windup_turn_degrees_per_second: float = -1.0:
	set(value):
		windup_turn_degrees_per_second = value
		_changed(&"windup_turn_degrees_per_second", value)
## How long the combo window stays open after its hit, in ticks at 60 a second (its OpenCombo step).
@export_range(1, 600, 1, "or_greater") var combo_window_ticks: int = 30:
	set(value):
		combo_window_ticks = value
		_changed(&"combo_window_ticks", value)
## On: when a swing starts (server), enemies within reach and in front are told it's coming, so their AI can parry. One sphere query.
@export var warns_targets: bool = true:
	set(value):
		warns_targets = value
		_changed(&"warns_targets", value)


func _init() -> void:
	super()
	trigger_action = &"primary"
	# Tags are constants, so a misspelling is an error, not a warning while playing.
	category = Tags.ABILITY.COMBAT_MELEE
	locks_out = [Tags.ABILITY.MOVEMENT, Tags.ABILITY.COMBAT]
	interrupt_priority = 15
	interrupt_threshold = 15
	buffer_window = 0.15 # a press near the end of a dash waits for it
	combo_positions = [1] # an opener, unless a definition says it's a follow-up (pawn spec 8.20)
