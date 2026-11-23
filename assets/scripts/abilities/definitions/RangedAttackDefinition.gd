# Written by Claude (claude-opus-5-5), 2026-11-21. History: abilities/CHANGELOG.md.
@tool
## A ranged attack's settings: its projectile, timings and muzzle.
##
## A new one starts with the kind's defaults; see [AbilityDefinition] for variants. The RangedAttack node reads it.
class_name RangedAttackDefinition
extends AbilityDefinition

## For a projectile with code of its own (homing, splitting): a scene whose root extends [Projectile], with a TickStateComponent and a
## NetworkEntity, registered at startup ([method Projectile.register_scene]). Empty: the built-in projectile, flown by
## [member projectile_definition].
@export var projectile_scene: PackedScene:
	set(value):
		projectile_scene = value
		_changed(&"projectile_scene", value)
## What it fires: speed, arc, size, hits, and how it looks ([ProjectileDefinition]). A definition file, so clients can find it by its
## registry index.
@export var projectile_definition: ProjectileDefinition:
	set(value):
		projectile_definition = value
		_changed(&"projectile_definition", value)
## Ticks of aiming before the shot, at 60 a second.
@export_range(0, 120, 1, "or_greater") var windup_ticks: int = 12:
	set(value):
		windup_ticks = value
		_changed(&"windup_ticks", value)
## Ticks after the shot before it's over, at 60 a second.
@export_range(0, 120, 1, "or_greater") var recovery_ticks: int = 18:
	set(value):
		recovery_ticks = value
		_changed(&"recovery_ticks", value)
## How far away a target may be for the AI to shoot, in metres (the AI's reach; the projectile's own range can be longer).
@export_range(0.5, 200.0, 0.5, "or_greater") var attack_range: float = 14.0:
	set(value):
		attack_range = value
		_changed(&"attack_range", value)
## Where the projectile leaves from: metres above the feet and in front of the pawn.
@export var muzzle_height: float = 1.3:
	set(value):
		muzzle_height = value
		_changed(&"muzzle_height", value)
## How far in front of the pawn the projectile starts, in metres.
@export var muzzle_forward: float = 0.5:
	set(value):
		muzzle_forward = value
		_changed(&"muzzle_forward", value)
## How fast it turns toward its aim during the windup, degrees a second; -1 uses the pawn's TurnRate stat.
@export_range(-1.0, 3600.0, 10.0, "or_greater") var windup_turn_degrees_per_second: float = -1.0:
	set(value):
		windup_turn_degrees_per_second = value
		_changed(&"windup_turn_degrees_per_second", value)
## On: the first enemy on the projectile's path hears it's coming, so its AI can parry.
@export var warns_targets: bool = true:
	set(value):
		warns_targets = value
		_changed(&"warns_targets", value)


func _init() -> void:
	super()
	# A projectile stops at the first pawn it hits and pushes along its flight, unless its hit definition says otherwise.
	hit = HitDefinition.new()
	hit.max_hits = 1
	hit.push = HitDefinition.Push.ALONG_MOTION
	trigger_action = &"primary"
	category = Tags.ABILITY.COMBAT_RANGED
	has_charges_tag = Tags.STATUS.HAS_AMMO_RANGED # owned while it can shoot: Keep Distance runs only then
	locks_out = [Tags.ABILITY.MOVEMENT, Tags.ABILITY.COMBAT]
	interrupt_priority = 15
	interrupt_threshold = 15
	cooldown = 0.6
