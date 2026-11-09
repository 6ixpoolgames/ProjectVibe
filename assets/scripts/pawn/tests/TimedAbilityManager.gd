## Written by Claude (claude-opus-5-5), 2026-11-09: test-only. An AbilityManager that also times its own work, for pawn_stress's
## --breakdown, so simulate can be split into the abilities and the rest (mostly move_and_slide) without changing the real manager.
## Every instance adds into the same totals (static vars), in microseconds; pawn_stress resets and reads them.
##
## What's timed, per tick:
##   locomotion   _run_locomotion: picking and running Walk or Sprint (steering, stat reads)
##   actions      _run_actions: timed actions ticking (Dash, MeleeAttack, Knockback, Death) and presses starting them
##   all          the whole tick_abilities; the counters (cooldowns, buffers, every_tick) and lock bookkeeping are all minus the two
class_name TimedAbilityManager
extends AbilityManager

# GDScript note: static vars belong to the class, so every timed manager in the scene adds into the same numbers.
static var usec_all := 0
static var usec_locomotion := 0
static var usec_actions := 0


static func reset_timings() -> void:
	usec_all = 0
	usec_locomotion = 0
	usec_actions = 0


func tick_abilities(dt: float) -> void:
	var started := Time.get_ticks_usec()
	super(dt)
	usec_all += Time.get_ticks_usec() - started


func _run_locomotion(dt: float) -> void:
	var started := Time.get_ticks_usec()
	super(dt)
	usec_locomotion += Time.get_ticks_usec() - started


func _run_actions(dt: float) -> void:
	var started := Time.get_ticks_usec()
	super(dt)
	usec_actions += Time.get_ticks_usec() - started
