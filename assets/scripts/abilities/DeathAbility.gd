# Written by Claude (claude-opus-5-5), 2026-11-09. History: abilities/CHANGELOG.md.
## Being dead: an action with no trigger action, started when the pawn's Health reaches 0.
##
## The EffectManager calls [method AbilityManager.health_ran_out] when an effect takes Health to 0, and the AbilityManager starts this
## and sends [signal AbilityManager.died]. While it runs it locks out movement, combat and utility, nothing cancels it, and
## [method Pawn.is_dead] is true (the pawn ignores its input and AI, and other pawns' sensing ignores it). It keeps running while Health
## is 0; [method AbilityManager.revive] ends it. The body stays where it falls: removing it or respawning is game code's job.
## [br][br]Rollback: its timer rolls back with Health, so clients see the pawn dead from snapshots. It watches [constant StatManager.HEALTH].
## Design: pawn spec 8.7, 8.16.
class_name DeathAbility
extends AbilityBase


func _init() -> void:
	super()
	kind = Kind.ACTION
	# Tags are constants, so a misspelling is an error, not a warning while playing.
	category = Tags.STATUS_DEAD
	locks_out = [Tags.MOVEMENT, Tags.COMBAT, Tags.UTILITY]
	interrupt_priority = 1000
	interrupt_threshold = 1000


## Timed: it runs while Health is 0.
func is_timed() -> bool:
	return true


# Keeps Pawn.dead current: a plain value C++ (sensing, memory) reads directly (scaling spec step 4).
func _running_changed(running: bool) -> void:
	if pawn:
		pawn.dead = running


# Started with one tick, then put off for as long as Health is 0 (start and tick).
func duration_ticks() -> int:
	return 1


func start() -> void:
	if _health_is_gone():
		ends_at = NEVER


# A corpse lying still may sleep. When Health comes back (revive) this turns false, the pawn wakes and Death ends.
func can_sleep_while_running() -> bool:
	return _health_is_gone()


func _health_is_gone() -> bool:
	var stats := pawn.stat_manager if pawn else null
	return stats == null or stats.get_health() <= 0.0


func tick(_dt: float) -> void:
	if _health_is_gone():
		ends_at = NEVER
	else:
		end_run() # Health is back (revive)
