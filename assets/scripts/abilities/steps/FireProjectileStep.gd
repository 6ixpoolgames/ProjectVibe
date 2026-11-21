# Written by Claude (claude-opus-5-5), 2026-11-18. History: abilities/CHANGELOG.md.
## Fires a projectile on its first tick, from the pawn's muzzle point toward where it looks.
##
## The server (or offline game) spawns it, never in a rollback replay. The shooter's own client draws a [PredictedProjectile] at once,
## a visual only, instead of waiting a round trip for the server's.
## Aim is the pawn's look (yaw and pitch, so an AI looking at a target's chest aims at it). If [member warns_targets], the first enemy on
## the straight line ahead is told a hit is coming, so its AI can parry or dodge. Design: pawn spec 8.24.
class_name FireProjectileStep
extends AbilityStep

## What it fires: speed, arc, size, hits and look. The built-in projectile flies it (register it at startup on every machine,
## [method Projectile.register]).
@export var projectile_definition: ProjectileDefinition
## For a projectile with code of its own: its scene (see [member RangedAttackDefinition.projectile_scene]). Empty: the built-in one.
@export var projectile_scene: PackedScene
## Where it leaves from: metres above the pawn's feet.
@export var muzzle_height := 1.3
## Where it leaves from: metres in front of the pawn.
@export var muzzle_forward := 0.5
## On: the first enemy on the straight path ahead hears a hit is coming (AIContextComponent.note_incoming_attack).
@export var warns_targets := true

## The projectile fired on this run, on the server; null on clients.
var fired: Projectile = null


func _init() -> void:
	super()
	length_ticks = 1


func tick(_dt: float) -> Status:
	if step_ticks == 0 and not TickDriver.is_resimulating() and (projectile_definition or projectile_scene):
		if pawn.is_authority():
			_fire()
		elif _is_shooters_own_client():
			PredictedProjectile.fire(projectile_definition, projectile_scene, pawn, muzzle_point(), aim_direction(), TickDriver.tick)
	return Status.RUNNING


## The point it fires from, in the world.
func muzzle_point() -> Vector3:
	var yaw := pawn.yaw
	return pawn.global_position + Vector3(0.0, muzzle_height, 0.0) + Vector3(-sin(yaw), 0.0, -cos(yaw)) * muzzle_forward


## The direction it fires in: the look yaw and pitch.
func aim_direction() -> Vector3:
	var yaw := ability.look_yaw()
	var pitch: float = pawn.controller_manager.look_pitch if pawn.controller_manager else 0.0
	return Vector3(-sin(yaw) * cos(pitch), sin(pitch), -cos(yaw) * cos(pitch))


func _fire() -> void:
	var origin := muzzle_point()
	var direction := aim_direction()
	fired = Projectile.fire(ability, origin, direction, projectile_definition, projectile_scene)
	if fired and warns_targets:
		_warn_first_on_path(origin, direction)


# True on the client that predicts this pawn: the player who fired.
func _is_shooters_own_client() -> bool:
	var entity := pawn.get_network_entity()
	return entity != null and entity.role == NetworkEntity.Role.LOCAL_PREDICTED


# Tells the first enemy on the straight path, within range, that a hit is coming and when.
func _warn_first_on_path(origin: Vector3, direction: Vector3) -> void:
	if SharedPawnTable.get_grid() == null:
		return
	var reach := fired.max_range
	var centres := PackedVector3Array()
	var spots := maxi(1, ceili(reach)) # a spot a metre, with a sphere wide enough to cover the gaps
	for i in spots + 1:
		centres.append(origin + direction * (reach * i / spots))
	var now: int = TickDriver.tick
	var best: Pawn = null
	var best_along := INF
	for found: Object in SharedPawnTable.get_grid().find_touching(centres, fired.radius + 0.5, pawn, now):
		var other := found as Pawn
		if other == null or other.team == pawn.team or other.is_dead():
			continue
		var along := (other.global_position - origin).dot(direction)
		if along > 0.0 and along < best_along:
			best_along = along
			best = other
	if best and best.ai_context and best.is_authority():
		var ticks := ceili(best_along / maxf(fired.speed, 0.01) * TickDriver.get_tick_rate())
		best.ai_context.note_incoming_attack(pawn, now, now + ticks)
