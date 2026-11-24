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

## The name status.dead is added under in the pawn's [OwnedTags].
const OWNED_TAGS_SOURCE := &"death"


## Its kind's defaults: a new [DeathDefinition].
func make_default_definition() -> AbilityDefinition:
	return DeathDefinition.new()


## Timed: it runs while Health is 0.
func is_timed() -> bool:
	return true


# Keeps Pawn.dead current: a plain value C++ (sensing, memory) reads directly (scaling spec step 4). And the pawn owns status.dead
# while dead (tag spec 3), as its own source: the ability itself is the source of its ability.death tag.
func _running_changed(running: bool) -> void:
	if pawn:
		pawn.dead = running
		if pawn.owned_tags:
			pawn.owned_tags.set_source(OWNED_TAGS_SOURCE, [Tags.STATUS.DEAD] if running else [])


# Started with one tick, then put off for as long as Health is 0 (start and tick).
func run_length_ticks() -> int:
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
