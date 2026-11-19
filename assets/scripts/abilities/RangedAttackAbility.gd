# Written by Claude (claude-opus-5-5), 2026-11-18. History: abilities/CHANGELOG.md.
## A ranged attack: an action bound to &"primary" that fires a projectile, built from steps.
##
## A shot is a [WindupStep] (which starts a [TurnToFaceStep]), a [FireProjectileStep], then a [WaitStep] for recovery. With no
## [AbilityStep] children of its own it makes those from the settings below; place steps of your own for another pattern (a volley is
## several fire steps). It locks out movement and other combat while it runs; Dash cancels it. What a hit does comes from its
## EffectApplier children, carried by the projectile. Design: pawn spec 8.24.
## [codeblock]
## # in a pawn's AbilityManager: a RangedAttack with projectile_scene set, and an EffectApplier child (on hit)
## pawn.ability_manager.can_start(&"primary")
## [/codeblock]
class_name RangedAttackAbility
extends AbilityBase

## The projectile it fires.
@export var projectile_scene: PackedScene
## Ticks of aiming before the shot, at 60 a second.
@export_range(0, 120, 1, "or_greater") var windup_ticks := 12
## Ticks after the shot before it's over, at 60 a second.
@export_range(0, 120, 1, "or_greater") var recovery_ticks := 18
## How far away a target may be for the AI to shoot, in metres (the AI's reach; the projectile's own range can be longer).
@export_range(0.5, 200.0, 0.5, "or_greater") var attack_range := 14.0
## Where the projectile leaves from: metres above the feet and in front of the pawn.
@export var muzzle_height := 1.3
@export var muzzle_forward := 0.5
## How fast it turns toward its aim during the windup, degrees a second; -1 uses the pawn's TurnSpeed stat.
@export_range(-1.0, 3600.0, 10.0, "or_greater") var windup_turn_degrees_per_second := -1.0
## On: the first enemy on the projectile's path hears it's coming, so its AI can parry.
@export var warns_targets := true

var _made_default_steps := false


func _init() -> void:
	super()
	kind = Kind.ACTION
	trigger_action = &"primary"
	category = Tags.COMBAT_RANGED
	locks_out = [Tags.MOVEMENT, Tags.COMBAT]
	interrupt_priority = 15
	interrupt_threshold = 15
	cooldown = 0.6


## Its attack_range: the AI shoots from within it.
func attack_reach() -> float:
	return attack_range


## Finds its steps, after making the default ones from its settings if it has none of its own.
func collect_steps() -> void:
	var has_own := false
	for child in get_children():
		if child is AbilityStep:
			has_own = true
			break
	if not has_own:
		_make_default_steps()
	super()
	if _made_default_steps:
		_sync_default_steps()


func start() -> void:
	if _made_default_steps:
		_sync_default_steps()


# Windup (starts TurnToFace, then Fire), Fire (then Recovery). The same names everywhere, so their rolled-back state has the same paths
# on every machine.
func _make_default_steps() -> void:
	var windup := WindupStep.new()
	windup.name = "Windup"
	windup.starts_first = true
	windup.turn_step = NodePath("../TurnToFace")
	windup.starts_when_finished = [NodePath("../Fire")]
	add_child(windup)
	var turn := TurnToFaceStep.new()
	turn.name = "TurnToFace"
	add_child(turn)
	var fire := FireProjectileStep.new()
	fire.name = "Fire"
	fire.starts_when_finished = [NodePath("../Recovery")]
	add_child(fire)
	var recovery := WaitStep.new()
	recovery.name = "Recovery"
	add_child(recovery)
	_made_default_steps = true


func _sync_default_steps() -> void:
	(get_node(^"Windup") as WindupStep).length_ticks = windup_ticks
	(get_node(^"TurnToFace") as TurnToFaceStep).degrees_per_second = windup_turn_degrees_per_second
	var fire := get_node(^"Fire") as FireProjectileStep
	fire.projectile_scene = projectile_scene
	fire.muzzle_height = muzzle_height
	fire.muzzle_forward = muzzle_forward
	fire.warns_targets = warns_targets
	(get_node(^"Recovery") as WaitStep).length_ticks = recovery_ticks
