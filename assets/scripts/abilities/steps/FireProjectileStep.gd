# Written by Claude (claude-opus-5-5), 2026-11-18. History: abilities/CHANGELOG.md.
## Fires a projectile on its first tick, from the pawn's muzzle point toward where it looks.
##
## Server or offline only, and never in a rollback replay: a client doesn't spawn anything, it sees the server's projectile arrive.
## Aim is the pawn's look (yaw and pitch, so an AI looking at a target's chest aims at it). If [member warns_targets], the first enemy on
## the straight line ahead is told a hit is coming, so its AI can parry or dodge. Design: pawn spec 8.24.
class_name FireProjectileStep
extends AbilityStep

## The projectile scene to fire: a [Projectile] with a TickStateComponent and a NetworkEntity. Register it at startup
## ([method Projectile.register_scene]) on every machine.
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
	if step_ticks == 0 and pawn.is_authority() and not TickDriver.is_resimulating() and projectile_scene:
		_fire()
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
	fired = Projectile.spawn_from(projectile_scene, ability, origin, direction)
	if fired and warns_targets:
		_warn_first_on_path(origin, direction)


# Tells the first enemy on the straight path, within range, that a hit is coming and when.
func _warn_first_on_path(origin: Vector3, direction: Vector3) -> void:
	if Pawn.get_grid() == null:
		return
	var reach := fired.max_range
	var centres := PackedVector3Array()
	var spots := maxi(1, ceili(reach)) # a spot a metre, with a sphere wide enough to cover the gaps
	for i in spots + 1:
		centres.append(origin + direction * (reach * i / spots))
	var now: int = TickDriver.tick
	var best: Pawn = null
	var best_along := INF
	for found: Object in Pawn.get_grid().find_touching(centres, fired.radius + 0.5, pawn, now):
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
