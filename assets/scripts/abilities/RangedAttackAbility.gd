# Written by Claude (claude-opus-5-5), 2026-11-18. History: abilities/CHANGELOG.md.
## A ranged attack: an action bound to &"primary" that fires a projectile, built from steps.
##
## A shot is a [WindupStep] with a [TurnToFaceStep] beside it, a [FireProjectileStep], then a [WaitStep] for recovery. With no
## [AbilityStep] children of its own it makes those from the settings below; place steps of your own for another pattern (a volley is
## several fire steps). It locks out movement and other combat while it runs; Dash cancels it. What a hit does is its hit
## definition's effects ([member AbilityDefinition.hit]), carried by the projectile. Design: pawn spec 8.24.
## [codeblock]
## # in a pawn's AbilityManager: a RangedAttack whose definition names a ProjectileDefinition and a hit with effects
## pawn.ability_manager.can_start(&"primary")
## [/codeblock]
class_name RangedAttackAbility
extends AbilityBase

# Its settings with their own type: the same object as settings.
var _ranged: RangedAttackDefinition = null

# Its settings, read from its definition (ability spec 3). Writing one is for a script's _init(); see AbilityBase._set.

var _made_default_steps := false


## Its kind's defaults: a new [RangedAttackDefinition].
func make_default_definition() -> AbilityDefinition:
	return RangedAttackDefinition.new()


func _settings_changed() -> void:
	super()
	_ranged = settings as RangedAttackDefinition


## Its attack_range: the AI shoots from within it.
func attack_reach() -> float:
	return _ranged.attack_range


## Finds its steps, after making the default ones from its settings if it has none of its own.
# REFACTOR: the same pattern as the other attack's collect_steps (default steps made once, then kept in step with the settings);
# one in AbilityBase with hooks (abilities/CHANGELOG.md).
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


## The timeline for the steps it made: Windup and TurnToFace together, Fire when the windup is done, then Recovery. With steps of its
## own and no timeline in its definition, they run one after another.
func default_timeline() -> Array[TimelineEntry]:
	if not _made_default_steps:
		return []
	return [TimelineEntry.at(&"Windup"), TimelineEntry.at(&"TurnToFace"), TimelineEntry.after_end_of(&"Fire", &"Windup"),
		TimelineEntry.after_end_of(&"Recovery", &"Fire")]


# The default steps, run by its default timeline. Named the same everywhere, so a definition's own timeline can name them.
func _make_default_steps() -> void:
	var windup := WindupStep.new()
	windup.name = "Windup"
	add_child(windup)
	var turn := TurnToFaceStep.new()
	turn.name = "TurnToFace"
	add_child(turn)
	var fire := FireProjectileStep.new()
	fire.name = "Fire"
	add_child(fire)
	var recovery := WaitStep.new()
	recovery.name = "Recovery"
	add_child(recovery)
	_made_default_steps = true


func _sync_default_steps() -> void:
	(get_node(^"Windup") as WindupStep).length_ticks = _ranged.windup_ticks
	(get_node(^"TurnToFace") as TurnToFaceStep).degrees_per_second = _ranged.windup_turn_degrees_per_second
	var fire := get_node(^"Fire") as FireProjectileStep
	fire.projectile_scene = _ranged.projectile_scene
	fire.projectile_definition = _ranged.projectile_definition
	fire.muzzle_height = _ranged.muzzle_height
	fire.muzzle_forward = _ranged.muzzle_forward
	fire.warns_targets = _ranged.warns_targets
	(get_node(^"Recovery") as WaitStep).length_ticks = _ranged.recovery_ticks
