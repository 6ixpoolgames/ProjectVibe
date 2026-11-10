## Written by Claude (claude-opus-5-5), 2026-11-07: the base for one thing a pawn can do, such as walk, jump or sprint. A child of the
## pawn's AbilityManager. Pawn spec section 8.
##
## An ability is pressed like a skill in an MMO or MOBA: its trigger_action (a named action from InputActions, such as &"jump") starts
## it. The player's keys and an AI behaviour press the same actions, so both reach the same ability through the same rules.
##
## Two kinds:
##   LOCOMOTION   moves the pawn, every tick it's chosen. Exactly one runs each tick. The one with no trigger_action (Walk) is the
##                default; one whose trigger_action is held (Sprint) runs instead while it can.
##   ACTION       starts on a press. With no duration it happens at once (Jump); with a duration it runs for that long.
##
## How to make one: extend this, set what's needed in _init(), and override any of:
##   can_start() -> bool    extra conditions, such as being on the ground. Cooldowns and lockouts are already checked
##   start()                once, when it starts. An action with no duration does its whole job here
##   tick(dt)               every tick it runs. A locomotion ability writes the pawn's velocity here
##   stop()                 once, when it stops
##   every_tick(dt)         every tick, running or not, for counters such as time off the ground. Claude 2026-11-09: only called on
##                          abilities that override it; such an ability also overrides can_rest() (pawn spec 15.3)
## Times are set in seconds and kept in ticks, so they line up exactly between server and client.
##
## Rollback: what an ability keeps between ticks has to roll back. get_rollback_properties() names those properties, and the
## AbilityManager registers them with the pawn's TickStateComponent. The base already handles its own: ticks_left (only with a
## duration), cooldown_ticks_left (only with a cooldown) and buffer_ticks_left (only with a buffer window). They count down to 0, so
## they're small numbers on the network. An ability with more state adds it to the list.
class_name AbilityBase
extends Node

enum Kind { LOCOMOTION, ACTION }

@export var kind := Kind.ACTION
## The named action that starts it, such as &"jump". Empty: only the manager starts it, as the default locomotion.
@export var trigger_action: StringName = &""
## What it is, as a tag such as &"movement.jump". Used for lockouts. Empty: nothing can lock it out.
@export var category: StringName = &""
## Claude 2026-11-10: more groups this ability belongs to, besides category, such as &"movement.advanced" for a dash, or a school and a
## range for an attack (&"school.magic", &"range.ranged"). It answers to all of them, for lockouts, cancels and the AI's searches
## (AbilityManager.action_for_tag): each is a group, so one rule covers every ability in it. All of them share one 64-bit mask, with
## every other ability tag; how strong it is stays in the interrupt numbers, not in tags.
@export var extra_categories: Array[StringName] = []
## When several abilities share a trigger_action, the highest priority that can start wins; then the first in the tree. Claude
## 2026-11-09: was lowest-wins; now it's higher-wins like interrupt_priority and behaviour scores (the owner's call). Among locomotion
## abilities whose action is held, the same. Claude 2026-11-10: effects on the pawn can add to it while they last
## (AbilityPriorityPart, pawn spec 8.11), which is how combos work; and to interrupt_priority and interrupt_threshold.
@export var priority := 0
## Claude 2026-11-09: a random offset, up to ± this much, added to priority each time a press picks between abilities on one action,
## like a behaviour's score_jitter. 0 (the default): none, so the order is always the same. The offset comes from the tick's own
## random numbers (TickDriver.tick_rng), so a rollback replay picks the same ability. Locomotion ignores it, because it's chosen every
## tick and would flicker.
@export var priority_jitter := 0.0
## Seconds. For an action, 0 means it happens at once. For locomotion, 0 means it runs as long as it's wanted.
@export_range(0.0, 60.0, 0.05, "or_greater") var duration := 0.0
## Seconds after it stops before it can start again.
@export_range(0.0, 60.0, 0.05, "or_greater") var cooldown := 0.0
## Categories that can't start, or steer, while this runs, such as &"movement" for an attack that roots the pawn.
@export var locks_out: Array[StringName] = []
## Seconds a press waits if the ability can't start yet, such as jump pressed just before landing. 0: a press is tried once.
@export_range(0.0, 2.0, 0.01, "or_greater") var buffer_window := 0.0
## Claude 2026-11-09: how strong this ability is at cancelling a running ability it conflicts with (pawn spec 8.6). Two abilities
## conflict when either one's locks_out covers the other's category. Walk 0, Sprint 10, Jump 5, Dash 20, knockback 30. Claude
## 2026-11-10: Dash 40 now, the one thing that cancels a knockback (threshold 35).
@export var interrupt_priority := 0
## Claude 2026-11-09: while this runs, a conflicting ability whose interrupt_priority is at least this cancels it and starts; a
## weaker one is locked out, as before. 100: nothing in t0 can cancel it. MeleeAttack uses 15, so Dash cancels a swing and Sprint
## doesn't. An action meant to be cancelled by sprinting (a reload, say) uses 10 or less; by just moving, 0.
@export var interrupt_threshold := 100
## Claude 2026-11-10: on: while this runs, hits don't land on the pawn: no damage, no knockback, nothing (invulnerability frames).
## Dash has it, the owner's call. It's read from the running timer, which rolls back, so a replay agrees about what was dodged.
@export var invulnerable_while_running := false
## Claude 2026-11-10: with invulnerable_while_running on, how long it lasts from the start of the run, in seconds. 0: the whole run.
## Dash uses 0.18 (the owner's call), so the end of its slow-down can be hit.
@export_range(0.0, 10.0, 0.01, "or_greater") var invulnerable_seconds := 0.0
## Claude 2026-11-10: categories that can always cancel this while it runs, whatever the interrupt numbers say, such as
## &"movement.jump" for an ability a jump should cut short. Empty (the default): only the numbers decide. For the exceptions a single
## ladder of numbers can't express. A category covers its children, as in locks_out.
@export var cancelled_by: Array[StringName] = []
## Claude 2026-11-10: on: while this runs, the pawn's locomotion (Walk, Sprint) doesn't run at all, so it neither steers nor slows the
## pawn and this ability's own movement isn't fought. Dash has it. Off (the default): a locked-out locomotion still slows the pawn to
## a stop, which is what an attack that roots the pawn wants.
@export var pauses_locomotion := false

# State that rolls back. See the top of the file.
# Claude 2026-11-09: each timer tells the manager when it starts or reaches 0, so the manager only counts down the timers that are
# running (pawn spec 15.2). That includes a rollback loading new values, which writes them through these setters.
# GDScript note: inside its own setter, a variable's name means the stored value, so "ticks_left" there is the old value.
## ticks left of a timed run. 0: not running a timed run
var ticks_left := 0:
	set(value):
		var flips := (value > 0) != (ticks_left > 0)
		if manager and flips:
			manager.timers_changed()
		ticks_left = value
		if flips:
			_running_changed(value > 0) # Claude 2026-11-09 (scaling spec step 4)
## ticks until it can start again
var cooldown_ticks_left := 0:
	set(value):
		if manager and (value > 0) != (cooldown_ticks_left > 0):
			manager.timers_changed()
		cooldown_ticks_left = value
## ticks a waiting press has left
var buffer_ticks_left := 0:
	set(value):
		if manager and (value > 0) != (buffer_ticks_left > 0):
			manager.timers_changed()
		buffer_ticks_left = value

## Set by the AbilityManager.
var manager: AbilityManager = null
## Claude 2026-11-09: set by the AbilityManager: a number from this ability's name, for its priority_jitter's random offset.
var jitter_salt := 0
var pawn: Pawn = null
## This ability's category as bits, with its parents' bits too. Worked out once by the manager. Claude 2026-11-10: and its
## extra_categories', with theirs.
var category_mask := 0
## locks_out as bits. Worked out once by the manager.
var locks_out_mask := 0
## Claude 2026-11-10: cancelled_by as bits. Worked out once by the manager, so the check while playing is one bit test.
var cancelled_by_mask := 0
## Claude 2026-11-09: trigger_action's input bit (InputActions), or 0 with none. Worked out once by the manager, so a tick tests a bit
## instead of looking the name up (pawn spec 15.2).
var trigger_bit := 0
## Claude 2026-11-10 (pawn spec 8.11): what this ability applies, from its EffectApplier children, collected once by the manager.
## on_start_effects go on its own pawn when it starts. on_hit_effects go on a pawn it hits, and on_hit_self_effects on its own pawn
## when it hits; an ability that hits (MeleeAttack) hands both to the HitInfo.
var on_start_effects: Array[Effect] = []
var on_hit_effects: Array[Effect] = []
var on_hit_self_effects: Array[Effect] = []


func _init() -> void:
	set_process(false)
	set_physics_process(false)


## The properties on this node that roll back. Add to it with super() in an ability that keeps more.
func get_rollback_properties() -> Array[String]:
	var out: Array[String] = []
	if duration > 0.0:
		out.append("ticks_left")
	if cooldown > 0.0:
		out.append("cooldown_ticks_left")
	if buffer_window > 0.0 and trigger_action != &"":
		out.append("buffer_ticks_left")
	return out


## Claude 2026-11-09: how many ticks a timed run lasts. The default turns duration's seconds into ticks; an ability that thinks in
## ticks, such as MeleeAttack with its phases, overrides this.
func duration_ticks() -> int:
	return manager.ticks_for(duration) if manager else 0


## True while a timed run is going.
func is_running_timed() -> bool:
	return ticks_left > 0


## Claude 2026-11-10: how many ticks of the current run have been ticked: 0 on the tick it starts, before its first tick. 0 when not
## running. Read from ticks_left, which rolls back, so it needs no state of its own.
func ticks_running() -> int:
	return duration_ticks() - ticks_left if ticks_left > 0 else 0


## Claude 2026-11-09 (scaling spec step 4): called whenever a timed run starts or ends, through the ticks_left setter, so also when a
## rollback loads new values. Nothing by default; DeathAbility uses it to keep Pawn.dead current.
func _running_changed(_running: bool) -> void:
	pass


## A stat from the pawn's StatManager, or fallback if there's no such stat or no StatManager.
func read_stat(stat_name: StringName, fallback: float) -> float:
	if pawn and pawn.stat_manager:
		return pawn.stat_manager.get_value(stat_name, fallback)
	return fallback


# --- Override these ---


func can_start() -> bool:
	return true


func start() -> void:
	pass


func tick(_dt: float) -> void:
	pass


func stop() -> void:
	pass


func every_tick(_dt: float) -> void:
	pass


## Claude 2026-11-09: true if this ability is fine with the pawn resting (pawn spec 15.3): standing still, it skips its abilities,
## gravity and move_and_slide. Only an ability that overrides every_tick() needs to think about it: answer false while every_tick()
## would still change something with the pawn standing still. Jump answers false until its time off the ground is back to 0.
func can_rest() -> bool:
	return true
