## Written by Claude (claude-opus-5-5), 2026-11-07: starts, runs and stops a pawn's abilities. A part on the pawn, added by
## PawnInitializer, with the abilities as its children. Pawn spec section 8.
##
## The pawn calls tick_abilities(dt) once per tick, after its input arrives and before move_and_slide. Each tick, in this order:
##   1. Counters: cooldowns and waiting presses count down, and every ability's every_tick() runs.
##   2. Locomotion: exactly one runs. A locomotion ability whose trigger_action is held, and which can run, wins, by priority and then
##      tree order (Sprint). Otherwise the default runs: the first locomotion ability with no trigger_action (Walk).
##   3. Actions: running timed ones tick. A pressed action starts the ability bound to it that can start with the highest priority
##      (plus its priority_jitter's offset, if it has one), then the first in the tree. One that can't yet keeps the press for its
##      buffer_window and tries again each tick.
## Claude 2026-11-09: priority is higher-wins now, as interrupt_priority and behaviour scores are; it was lowest-wins. A press is a
## request: an attack action can start a normal attack, or a follow-up when the normal one can't.
## Claude 2026-11-10 (pawn spec 8.11): effects on the pawn add to the numbers while they last (AbilityPriorityPart): a press compares
## priority plus those, and cancelling compares interrupt_priority and interrupt_threshold plus those. That's how combos work: a
## swing boosts the second swing's priority for a moment, so the next press picks it. A press waiting in a buffer is a press of its
## action, so when the wait ends every ability on that action that's ready competes, including the one that just finished.
## FollowUpAttackAbility, which opened a window after the normal swing, is gone: a boost does the same without a gate.
## An ability's EffectApplier children are collected here once: on-start effects are applied to the pawn when it starts.
## Everything that persists between ticks lives on the abilities and rolls back (see AbilityBase), so this node keeps none.
##
## How to use it (outside code only talks to the manager):
##   pawn.ability_manager.can_start(&"jump")    # could a press start something right now? For an AI deciding what to press
##   pawn.ability_manager.is_busy()             # is a timed action running?
##   pawn.ability_manager.has_action(&"sprint") # does anything answer to this action?
##   pawn.ability_manager.cancel(&"sprint")     # stops whatever is running for this action
##
## Lockouts: while an ability runs, the categories in its locks_out can't start, and a locked-out locomotion ability stops steering
## (the pawn slows to a stop). Categories are tags (TagRegistry), so locking &"movement" also locks &"movement.jump".
##
## Claude 2026-11-09, cancelling (pawn spec 8.6): two abilities conflict when either one's locks_out covers the other's category. A
## conflicting ability can start only if its interrupt_priority is at least the interrupt_threshold of every conflicting ability
## running; then those are cancelled (they stop, and their cooldowns start) and it starts. Otherwise it's locked out, as before. So
## Dash (20) cancels MeleeAttack (15) and Sprint (10) doesn't; moving cancels only actions with a threshold of 0. Claude 2026-11-10:
## an ability's cancelled_by lists categories that can cancel it whatever the numbers say, for the exceptions; as bits, so it costs
## one bit test, only when something tries to start. And an action with pauses_locomotion stops Walk running at all while it runs
## (Dash), where a locked-out Walk would otherwise slow the pawn. The rules live
## here, not in the controllers, so a player and the AI cancel the same way and a rollback replays the same cancels.
##   pawn.ability_manager.start_ability(ability)   # starts one that has no trigger action, such as Knockback, by the same rules
##   ability_cancelled(ability, by)
##
## What happens in odd cases (all checked in tests/ability_selftest.gd):
##   - Its parent isn't a Pawn: it warns and does nothing.
##   - No locomotion with an empty trigger_action: when nothing else runs, nothing steers, and the pawn keeps its velocity.
##   - Two abilities on one action: only one starts per press, and the others' waiting presses are dropped.
##   - No TickStateComponent on the pawn: abilities work, but nothing about them rolls back.
class_name AbilityManager
extends Node

signal ability_started(ability: AbilityBase)
signal ability_finished(ability: AbilityBase)
## Claude 2026-11-09: sent when an ability is cancelled by another starting, after ability_finished for it.
signal ability_cancelled(ability: AbilityBase, by: AbilityBase)
## Claude 2026-11-16 (pawn spec 8.20): a step of a stepped ability started.
## GDScript note: the abilities send these two (AbilityBase.start_step), so the editor's "never used in this class" warning is switched off.
@warning_ignore("unused_signal")
signal step_started(ability: AbilityBase, step: AbilityStep)
## Claude 2026-11-16: a step stopped: reason is "done", "failed" or "cancelled".
@warning_ignore("unused_signal")
signal step_finished(ability: AbilityBase, step: AbilityStep, reason: String)
## Claude 2026-11-16 (pawn M3): a hit reached this pawn, on the server: it isn't dead or invulnerable. Sent before a parry can turn it away and before its
## effects land, so the AI notes every attack (AIContextComponent listens).
signal hit_arrived(hit: HitInfo)
## Claude 2026-11-09: sent on the server when something hits this pawn, after its effects are applied (pawn spec 8.11);
## hit.damage_dealt says how much Health it took. Claude 2026-11-16 (pawn M3): moved here from Pawn.
signal hit_received(hit: HitInfo)
## Claude 2026-11-09, step 10: sent once on the server when this pawn dies, after its Death ability starts. hit is what did it, or null.
## Claude 2026-11-16 (pawn M3): moved here from Pawn. Each part cleans up after itself by listening (the EffectManager, the AI behaviour manager,
## the ControllerManager), where Pawn._die used to do it for them.
signal died(pawn: Pawn, hit: HitInfo)

# Claude 2026-11-10: _any_jitter is gone: a press always compares the abilities on its action now, since effects can boost them.
var _invulnerable_abilities: Array[AbilityBase] = [] # Claude 2026-11-10: those with invulnerable_while_running, usually just Dash
var _parry_abilities: Array[AbilityBase] = [] # Claude 2026-11-15: ParryAbility nodes, asked about each hit (parry_hit)
var _locomotion_pausers: Array[AbilityBase] = [] # Claude 2026-11-10: those with pauses_locomotion, usually just Dash
var _stepped: Array[AbilityBase] = [] # Claude 2026-11-16 (pawn spec 8.20): abilities built from steps

var pawn: Pawn = null
var _driver: Node = null # Claude 2026-11-16 (pawn M3): for hits during simulate
var _death: DeathAbility = null # Claude 2026-11-16 (pawn M3): found with the abilities (was on Pawn)
# Claude 2026-11-09: hits queued during simulate, for every pawn, and the tick driver that delivers them (pawn spec 15.4).
# Claude 2026-11-16 (pawn M3): moved here from Pawn. GDScript note: static, so one queue is shared by every manager.
static var _queued_hits: Array = [] # [attacker's entity id, target's entity id, place in the queue, HitInfo]
static var _hit_queue_driver: Node = null

var _abilities: Array[AbilityBase] = [] # every ability, in run order: by priority, then tree order
var _locomotions: Array[AbilityBase] = []
var _actions: Array[AbilityBase] = []
var _default_locomotion: AbilityBase = null
var _locked_mask := 0 # categories locked right now, as bits
var _tick_rate := 60.0
# Claude 2026-11-09, gates and channels (pawn spec 15.2): only what has a reason to run this tick runs.
var _timed: Array[AbilityBase] = [] # abilities with a timer running (a run, a cooldown or a buffered press)

# Claude 2026-11-16 (pawn spec 8.20, the owner's design): the combo counter, shared by every ability with combo_positions. Both roll
# back. A combo ability starting takes the next position if the window is open and it fits there, else 1; the window closes as it
# starts, and its OpenComboStep opens it again after its hit.
## The combo position the last combo ability took (0: none yet).
var combo_position := 0
## Ticks left in the combo window: while above 0, a follow-up whose positions include combo_position + 1 can start.
var combo_window_ticks_left := 0
var _timers_dirty := true # a timer started or reached 0, so _timed is rebuilt before it's next used
var _locks_dirty := true # an action started or stopped, so the locks are worked out again before they're next used
var _every_tick_abilities: Array[AbilityBase] = [] # abilities whose script overrides every_tick()
var _action_bits := 0 # the input bits of every action's trigger_action: the presses anything here answers to
# Script -> whether it overrides every_tick(), worked out once per script. GDScript note: a static var is shared by every manager.
static var _overrides_every_tick := {}


func _init() -> void:
	set_process(false)
	set_physics_process(false)


func _enter_tree() -> void:
	pawn = get_parent() as Pawn
	if pawn == null:
		push_warning("AbilityManager: its parent isn't a Pawn, so it does nothing.")


func _ready() -> void:
	var driver: Node = get_node_or_null("/root/TickDriver")
	_driver = driver # Claude 2026-11-16 (pawn M3)
	if driver:
		_tick_rate = float(driver.get_tick_rate())
	_collect_abilities()
	_register_rollback_state()


## The pawn calls this once per tick. dt is the fixed tick length.
func tick_abilities(dt: float) -> void:
	if pawn == null:
		return
	# Claude 2026-11-09 (pawn spec 15.2): the same steps as before, in the same order, but each only touches what has a reason to
	# run: the locks only after an action started or stopped, the counters only of running timers, every_tick() only where an
	# ability overrides it, and the action step only with a press, a buffered press or a running action.
	if _locks_dirty:
		_recompute_locks()
	if _timers_dirty:
		_rebuild_timed()
	# Claude 2026-11-16 (pawn spec 8.21): every timer advances by the ticks this run covers (1, or more for a pawn running every Nth tick).
	var elapsed := pawn.ticks_elapsed
	for ability in _timed:
		if ability.cooldown_ticks_left > 0:
			ability.cooldown_ticks_left = maxi(ability.cooldown_ticks_left - elapsed, 0)
		if ability.buffer_ticks_left > 0:
			ability.buffer_ticks_left = maxi(ability.buffer_ticks_left - elapsed, 0)
	for ability in _every_tick_abilities:
		ability.every_tick(dt)
	if combo_window_ticks_left > 0: # Claude 2026-11-16 (pawn spec 8.20)
		combo_window_ticks_left = maxi(combo_window_ticks_left - elapsed, 0)
	_run_locomotion(dt)
	if _actions_have_work():
		_run_actions(dt)


## Claude 2026-11-09: the abilities' timers call this when one starts or reaches 0 (pawn spec 15.2).
func timers_changed() -> void:
	_timers_dirty = true
	_locks_dirty = true


## Claude 2026-11-09: true if the pawn can sleep as far as its abilities go (pawn spec 15.3): no timer running, and every ability
## with every_tick() agrees.
func can_sleep() -> bool:
	if _timers_dirty:
		_rebuild_timed()
	if not _timed.is_empty():
		return false
	if combo_window_ticks_left > 0: # Claude 2026-11-16: the combo window counts down every tick
		return false
	for ability in _every_tick_abilities:
		if not ability.can_sleep():
			return false
	return true


## True if pressing this action now would start something, counting abilities it would cancel. Asking changes nothing.
func can_start(action: StringName) -> bool:
	for ability in _abilities:
		if ability.trigger_action == action and not ability.is_running_timed() and _is_ready(ability):
			return true
	return false


## Claude 2026-11-10: the action to press to start an ability in this group (its category or one of its extra_categories, such as
## &"movement.advanced"), picking the highest-priority one that could start right now; &"" if none could. For the AI, so a behaviour
## asks for a kind of ability instead of naming one: a pawn with a grappling hook instead of a dash closes in the same way. It
## answers with an action, not an ability, because everything a pawn does goes through its input, which rolls back. Asking changes
## nothing. The press goes through the usual rules, so if another ability shares that action and wins it, that one starts.
func action_for_tag(tag: StringName) -> StringName:
	var bit := TagRegistry.own_bit(tag) if TagRegistry.has_tag(tag) else 0
	if bit == 0:
		return &"" # an unknown tag matches nothing, and isn't added
	# Claude 2026-11-10: the highest priority now, boosts included (it was the first in priority order).
	var best: AbilityBase = null
	for ability in _actions:
		if ability.trigger_action != &"" and ability.category_mask & bit != 0 and not ability.is_running_timed() and _is_ready(ability):
			if best == null or press_priority_now(ability) > press_priority_now(best):
				best = ability
	return best.trigger_action if best else &""


## Claude 2026-11-09: starts an ability by the same rules as a press: its cooldown, can_start(), and cancelling what it conflicts
## with. For abilities with no trigger action, started by code, such as Knockback from a hit. One already running starts again.
## Returns false if it couldn't start.
func start_ability(ability: AbilityBase) -> bool:
	if ability == null or ability.manager != self:
		return false
	if ability.is_running_timed():
		ability.ticks_left = 0 # starts again from the beginning, without a cooldown in between
	if not _is_ready(ability):
		return false
	_clear_way(ability)
	_start(ability)
	return true


## Claude 2026-11-15: true if a running ParryAbility turns this hit away (from the front, while it runs). It has then already sent the
## attacker the parry's effects. Pawn asks this for every hit, on the server, before the hit's effects land.
func parry_hit(hit: HitInfo) -> bool:
	for ability in _parry_abilities:
		if (ability as ParryAbility).try_parry(hit):
			return true
	return false


## Claude 2026-11-10: true while an ability with invulnerable_while_running runs, such as a Dash: hits don't land (Pawn.is_invulnerable).
## Claude 2026-11-10: only for its first invulnerable_seconds, when that's above 0.
func is_invulnerable() -> bool:
	# Claude 2026-11-16 (pawn spec 8.20): or a running step with invulnerable on.
	for ability in _stepped:
		if ability.is_running_timed() and ability.has_invulnerable_step():
			return true
	for ability in _invulnerable_abilities:
		if not ability.is_running_timed():
			continue
		if ability.invulnerable_seconds <= 0.0 or ability.ticks_running() < ticks_for(ability.invulnerable_seconds):
			return true
	return false


## True while a timed action is running, such as an attack's swing.
func is_busy() -> bool:
	for ability in _actions:
		if ability.is_running_timed():
			return true
	return false


## True if any ability answers to this action.
func has_action(action: StringName) -> bool:
	for ability in _abilities:
		if ability.trigger_action == action:
			return true
	return false


## Claude 2026-11-09: stops every running ability, which starts their cooldowns.
func stop_all() -> void:
	for ability in _abilities:
		if ability.is_running_timed():
			_finish(ability)
	_recompute_locks()


## Stops whatever is running for this action, which starts its cooldown.
func cancel(action: StringName) -> void:
	for ability in _abilities:
		if ability.trigger_action == action and ability.is_running_timed():
			_finish(ability)


## True if this ability's category is locked out right now.
func is_locked(ability: AbilityBase) -> bool:
	return ability.category_mask & _locked_mask != 0


## Seconds as whole ticks, at least 1 for anything above 0.
func ticks_for(seconds: float) -> int:
	return 0 if seconds <= 0.0 else maxi(1, roundi(seconds * _tick_rate))


## Every ability, in run order.
func get_abilities() -> Array[AbilityBase]:
	return _abilities.duplicate()


# --- Internals ---


func _run_locomotion(dt: float) -> void:
	var chosen: AbilityBase = null
	for ability in _locomotions:
		if ability.trigger_action == &"":
			continue
		var wanted := _held() & ability.trigger_bit != 0 # Claude 2026-11-09: was pawn.is_action_held(trigger_action)
		if ability.is_running_timed():
			if wanted and not is_locked(ability):
				chosen = ability
				break
			_finish(ability) # let go, or locked out
		elif wanted and _is_ready(ability):
			_clear_way(ability) # Claude 2026-11-09
			_start(ability)
			chosen = ability
			break
	if chosen == null:
		chosen = _default_locomotion
		# Claude 2026-11-09: moving cancels a conflicting action that allows it (threshold 0, such as an emote).
		if chosen and is_locked(chosen) and _move().length_squared() > 0.0001 and _conflicts_allow(chosen):
			_clear_way(chosen)
	# Only one locomotion runs. Any other timed one still going stops.
	for ability in _locomotions:
		if ability != chosen and ability.is_running_timed():
			_finish(ability)
	if chosen == null:
		return
	# Claude 2026-11-10: an action with pauses_locomotion is running (a Dash): no steering and no slowing this tick, so the action's
	# own movement isn't fought. A timed locomotion's timer waits too.
	for ability in _locomotion_pausers:
		if ability.is_running_timed():
			return
	chosen.tick(dt)
	if chosen.is_stepped() and chosen.is_running_timed():
		chosen.run_steps(dt) # Claude 2026-11-16 (pawn spec 8.20)
		if not chosen.is_running_timed():
			_finish(chosen) # its last step ended: stopped, with its cooldown, as a timed one running out is
			return
	if chosen.is_running_timed():
		chosen.ticks_left -= pawn.ticks_elapsed # Claude 2026-11-16 (pawn spec 8.21): was 1
		if chosen.ticks_left <= 0:
			_finish(chosen)


func _run_actions(dt: float) -> void:
	# Claude 2026-11-09: bits instead of names (pawn spec 15.2): this tick's presses worked out once, and the actions that started
	# something kept as bits, where they were a Dictionary of names made every tick. The same rules.
	var pressed_bits: int = _held() & ~_previous_held()
	var used_bits := 0 # actions that started something this tick, so one press starts one ability
	# Claude 2026-11-10: actions with a press waiting in some ability's buffer. Every ready ability on such an action competes when
	# the wait ends, not only the one holding it, so the swing that was running when the press came can win it too.
	var waiting_bits := 0
	for ability in _timed:
		if ability.buffer_ticks_left > 0:
			waiting_bits |= ability.trigger_bit
	for ability in _actions:
		if ability.is_running_timed():
			ability.tick(dt)
			if ability.is_stepped():
				ability.run_steps(dt) # Claude 2026-11-16 (pawn spec 8.20): may end it, by setting ticks_left to 0
			ability.ticks_left -= pawn.ticks_elapsed # Claude 2026-11-16 (pawn spec 8.21): was 1
			if ability.ticks_left <= 0:
				_finish(ability)
			continue
		if ability.trigger_action == &"" or used_bits & ability.trigger_bit != 0:
			continue
		var pressed := pressed_bits & ability.trigger_bit != 0
		if not pressed and ability.buffer_ticks_left <= 0:
			continue
		if _is_ready(ability):
			# Claude 2026-11-09: with jitter on any of them, the best ready one on this action, not just the first.
			# Claude 2026-11-10: always now, since an effect can boost one at any time; with no jitter and no boost it's still this one.
			var chosen := _best_ready(ability, pressed_bits | waiting_bits)
			_clear_way(chosen) # Claude 2026-11-09: cancels what it's strong enough to cancel
			_start(chosen)
			used_bits |= ability.trigger_bit
		elif pressed and ability.buffer_window > 0.0:
			ability.buffer_ticks_left = ticks_for(ability.buffer_window)
	# A press that started something doesn't also wait in another ability on the same action.
	if used_bits != 0: # Claude 2026-11-09: bits, and skipped when nothing started
		for ability in _actions:
			if used_bits & ability.trigger_bit != 0 and not ability.is_running_timed():
				ability.buffer_ticks_left = 0


# Claude 2026-11-09: of the abilities on first's action that are pressed or waiting and ready, the one with the highest priority plus
# jitter; ties go to the earlier in the list (first itself, when nobody has jitter). The list is sorted by priority, so with no
# jitter this is always first.
# Claude 2026-11-10: and boosts (pawn spec 8.11). wanted_bits is the actions pressed this tick or waiting in a buffer: every ready
# ability on first's action is in it, so with no jitter and no boost, first still wins.
func _best_ready(first: AbilityBase, wanted_bits: int) -> AbilityBase:
	var best := first
	var best_score := _priority_now(first)
	for ability in _actions:
		if ability == first or ability.trigger_bit != first.trigger_bit or ability.is_running_timed():
			continue
		if wanted_bits & ability.trigger_bit == 0:
			continue
		if not _is_ready(ability):
			continue
		var score := _priority_now(ability)
		if score > best_score:
			best = ability
			best_score = score
	return best


# Claude 2026-11-09: priority plus this tick's random offset, from the tick's own random numbers, so a replay draws the same.
# Claude 2026-11-10: plus boosts from effects (press_priority_now).
func _priority_now(ability: AbilityBase) -> float:
	if ability.priority_jitter <= 0.0:
		return float(press_priority_now(ability))
	var entity := pawn.get_network_entity()
	var key: int = entity.entity_id if entity and entity.entity_id >= 0 else pawn.get_instance_id()
	var rng: RandomNumberGenerator = TickDriver.tick_rng(key, ability.jitter_salt)
	return press_priority_now(ability) + rng.randf_range(-ability.priority_jitter, ability.priority_jitter)


## Claude 2026-11-10 (pawn spec 8.11): an ability's priority right now: its own, plus what effects on the pawn add to it
## (AbilityPriorityPart). Without priority_jitter's random offset.
func press_priority_now(ability: AbilityBase) -> int:
	return ability.priority + _bonus(ability, AbilityPriorityPart.Number.PRESS_PRIORITY)


## Claude 2026-11-10: its interrupt_priority right now, with what effects add.
func interrupt_priority_now(ability: AbilityBase) -> int:
	return ability.interrupt_priority + _bonus(ability, AbilityPriorityPart.Number.INTERRUPT_PRIORITY)


## Claude 2026-11-10: its interrupt_threshold right now, with what effects add.
## Claude 2026-11-16 (pawn spec 8.20): for a stepped ability, the strictest of its running steps' thresholds (current_interrupt_threshold).
func interrupt_threshold_now(ability: AbilityBase) -> int:
	return ability.current_interrupt_threshold() + _bonus(ability, AbilityPriorityPart.Number.INTERRUPT_THRESHOLD)


# Claude 2026-11-10: what the pawn's effects add to one of an ability's numbers; 0 with no EffectManager or nothing held.
func _bonus(ability: AbilityBase, number: int) -> int:
	var effects := pawn.effect_manager if pawn else null
	if effects == null or not effects.has_ability_bonuses():
		return 0
	return effects.ability_bonus(ability, number)


# Claude 2026-11-09: "not locked out" became "every conflicting running ability can be cancelled by it", which is the same thing
# when nothing can be cancelled.
func _is_ready(ability: AbilityBase) -> bool:
	return ability.cooldown_ticks_left <= 0 and _combo_allows(ability) and _conflicts_allow(ability) and ability.can_start()


## Claude 2026-11-16 (pawn spec 8.20): opens the combo window for this many ticks. An OpenComboStep calls it after its ability's hit.
func open_combo_window(ticks: int) -> void:
	combo_window_ticks_left = maxi(ticks, 0)


## Claude 2026-11-16: the combo position this ability would take if it started now: the next one, if the window is open and it fits
## there; else 1, if it's an opener; else 0, meaning it can't start now. 0 too for an ability with no combo_positions.
func combo_position_for(ability: AbilityBase) -> int:
	if ability.combo_positions.is_empty():
		return 0
	var next := combo_position + 1
	if combo_window_ticks_left > 0 and ability.combo_positions.has(next):
		return next
	return 1 if ability.combo_positions.has(1) else 0


# Claude 2026-11-16: a combo follow-up can only start where it fits; anything else isn't held back by combos.
func _combo_allows(ability: AbilityBase) -> bool:
	return ability.combo_positions.is_empty() or combo_position_for(ability) > 0


# Claude 2026-11-09: two abilities conflict when either one's locks_out covers the other's category.
func _conflicts(a: AbilityBase, b: AbilityBase) -> bool:
	return a.locks_out_mask & b.category_mask != 0 or b.locks_out_mask & a.category_mask != 0


# Claude 2026-11-09: true if every running ability that conflicts with this one would let it cancel them.
# Claude 2026-11-10: or lists this one's category in its cancelled_by, which lets it through whatever the numbers say.
func _conflicts_allow(ability: AbilityBase) -> bool:
	for other in _abilities:
		if other != ability and other.is_running_timed() and not _lets_through(ability, other):
			return false
	return true


# Claude 2026-11-10: the one rule, shared by starting abilities and the interrupt table so the two can't disagree: true if running
# lets starting start: they don't conflict, or starting is strong enough, or running lists starting's group in cancelled_by.
# Claude 2026-11-10: with what effects add to the two numbers (pawn spec 8.11).
func _lets_through(starting: AbilityBase, running: AbilityBase) -> bool:
	return not _conflicts(starting, running) or interrupt_threshold_now(running) <= interrupt_priority_now(starting) \
			or running.cancelled_by_mask & starting.category_mask != 0


## Claude 2026-11-10, for the interrupt table: what happens if starting tries to start while running runs, by this pawn's numbers
## now, so a change made while playing (a berserk state raising a threshold) shows. Claude 2026-11-10: including what effects on the
## pawn add (pawn spec 8.11). It doesn't look at cooldowns or can_start().
## {"result": "alongside" | "cancels" | "blocked", "reason": text}:
##   alongside  they don't conflict: neither's locks_out covers the other, so both run
##   cancels    running stops and starting starts (priority at least the threshold, or cancelled_by)
##   blocked    starting can't start while running runs (for a locomotion ability: it stops steering instead)
func interrupt_rule(starting: AbilityBase, running: AbilityBase) -> Dictionary:
	if not _conflicts(starting, running):
		return {"result": "alongside", "reason": "no lockout between them"}
	if running.cancelled_by_mask & starting.category_mask != 0:
		return {"result": "cancels", "reason": "%s lists it in cancelled_by" % running.name}
	var priority := interrupt_priority_now(starting)
	var threshold := interrupt_threshold_now(running)
	if threshold <= priority:
		return {"result": "cancels", "reason": "priority %d >= threshold %d" % [priority, threshold]}
	return {"result": "blocked", "reason": "priority %d < threshold %d" % [priority, threshold]}


## Claude 2026-11-10: the interrupt table for this pawn: one row per ability that could be running (timed ones, and locomotion), one
## entry per other ability, each interrupt_rule's answer plus "running" and "starting" names. In run order. An action that happens
## at once, such as Jump, never runs, so it has no row; it's still in every row's entries, as something starting.
func get_interrupt_table() -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	for running in _abilities:
		# Timed abilities roll back their timer, ticks_left: that's how to tell them from instant ones, whose length can come from
		# duration, phases (MeleeAttack, Dash) or a push (Knockback).
		if running.kind != AbilityBase.Kind.LOCOMOTION and not running.get_rollback_properties().has("ticks_left"):
			continue
		var row := {"running": running.name, "priority": interrupt_priority_now(running), "threshold": interrupt_threshold_now(running), "cells": {}}
		for starting in _abilities:
			if starting != running:
				row["cells"][starting.name] = interrupt_rule(starting, running)
		rows.append(row)
	return rows


## Claude 2026-11-10: the interrupt table as text, for a debug print or a readout: a line per running ability, with what cancels it
## and what it blocks.
func get_interrupt_table_text() -> String:
	var lines: PackedStringArray = []
	for row in get_interrupt_table():
		var cancels: PackedStringArray = []
		var blocked: PackedStringArray = []
		for starting_name in row["cells"]:
			var cell: Dictionary = row["cells"][starting_name]
			if cell["result"] == "cancels":
				cancels.append(starting_name)
			elif cell["result"] == "blocked":
				blocked.append(starting_name)
		lines.append("%s (priority %d, threshold %d): cancelled by %s; blocks %s" % [row["running"], row["priority"], row["threshold"],
				", ".join(cancels) if not cancels.is_empty() else "nothing", ", ".join(blocked) if not blocked.is_empty() else "nothing"])
	return "\n".join(lines)


# Claude 2026-11-09: cancels every running ability that conflicts with this one. Call it only after _conflicts_allow said yes.
func _clear_way(ability: AbilityBase) -> void:
	var cancelled := false
	for other in _abilities:
		if other != ability and other.is_running_timed() and _conflicts(ability, other):
			_finish(other)
			ability_cancelled.emit(other, ability)
			cancelled = true
	if cancelled:
		_recompute_locks()


# Claude 2026-11-09: the categories locked out right now, from every running timed action.
func _recompute_locks() -> void:
	_locked_mask = 0
	_locks_dirty = false # Claude 2026-11-09
	for ability in _actions:
		if ability.is_running_timed():
			_locked_mask |= ability.locks_out_mask


# Claude 2026-11-09: the abilities with a timer running, kept so a tick only counts those down (pawn spec 15.2).
func _rebuild_timed() -> void:
	_timed.clear()
	_timers_dirty = false
	for ability in _abilities:
		if ability.ticks_left > 0 or ability.cooldown_ticks_left > 0 or ability.buffer_ticks_left > 0:
			_timed.append(ability)


# Claude 2026-11-09, the input channel: whether _run_actions would do anything this tick. It does with a new press of an action
# something here answers to, or an action running, or a press waiting in a buffer. Otherwise it would only loop and skip.
func _actions_have_work() -> bool:
	if _held() & ~_previous_held() & _action_bits != 0:
		return true
	for ability in _timed:
		if ability.kind == AbilityBase.Kind.ACTION and (ability.ticks_left > 0 or ability.buffer_ticks_left > 0):
			return true
	return false


# Claude 2026-11-09: whether this script overrides every_tick(). Godot's method list includes the base scripts' methods too, so an
# override shows as a second every_tick (AbilityBase has one). Worked out once per script.
static func _script_overrides_every_tick(script: Script) -> bool:
	if script == null:
		return false
	if not _overrides_every_tick.has(script):
		var count := 0
		for method in script.get_script_method_list():
			if method["name"] == "every_tick":
				count += 1
		_overrides_every_tick[script] = count > 1
	return _overrides_every_tick[script]


func _start(ability: AbilityBase) -> void:
	ability.buffer_ticks_left = 0
	ability.pawns_hit_this_run.clear() # Claude 2026-11-16 (pawn spec 8.20)
	# Claude 2026-11-16: a combo ability takes its position, and the window closes until its OpenComboStep opens it again.
	var taken := combo_position_for(ability)
	if taken > 0:
		combo_position = taken
		combo_window_ticks_left = 0
	ability.ticks_left = ability.duration_ticks() # Claude 2026-11-09: was ticks_for(duration); MeleeAttack counts its phases
	if ability.kind == AbilityBase.Kind.ACTION and ability.is_running_timed():
		_locked_mask |= ability.locks_out_mask # later abilities this tick respect it at once
	ability.start()
	# Claude 2026-11-10 (pawn spec 8.11): its on-start effects, on its own pawn, on every machine that runs it (replays too), so an
	# over-time one such as a combo boost is predicted. Their do-once parts only run on the authority (EffectManager).
	if not ability.on_start_effects.is_empty() and pawn.effect_manager:
		pawn.effect_manager.apply_effects(ability.on_start_effects, pawn, ability)
	ability_started.emit(ability)
	if ability.is_stepped() and ability.is_running_timed():
		ability.begin_steps() # Claude 2026-11-16 (pawn spec 8.20): after ability_started, so a replay lists the ability before its steps
	if ability.kind == AbilityBase.Kind.ACTION and not ability.is_running_timed():
		_finish(ability) # an action with no duration is done as soon as it starts


func _finish(ability: AbilityBase) -> void:
	ability.end_steps("cancelled") # Claude 2026-11-16 (pawn spec 8.20): steps still running when it ends early; none when they finished
	ability.ticks_left = 0
	ability.cooldown_ticks_left = ticks_for(ability.cooldown)
	ability.stop()
	ability_finished.emit(ability)


# --- Hits and death (Claude 2026-11-16 (pawn M3): moved here from Pawn: hits and death are abilities' business) ---


## Something hit this pawn. Called on the server by the attacking ability, such as MeleeAttack. In order:
##   1. hit_arrived goes out, and the AI notes the hit (its AIContextComponent listens), for the "being hit" state rules.
##   2. A running parry can turn it away from the front (ParryAbility): no effects land, and the attacker is pushed back instead.
##   3. Its EffectManager applies the hit's effects: damage (a StatChangePart; at 0 Health the Death ability starts and died goes
##      out), the push (a KnockbackPart starting Knockback here), and threat for the Health taken.
##   4. hit_received goes out, and the attacker gets the hit's attacker_effects.
## Claude 2026-11-09 (pawn spec 15.4): called during the simulate phase, as an ability's hit is, it's queued, and every queued hit is
## delivered after all pawns have simulated, in a fixed order, so the result never depends on whether this pawn simulated before or
## after its attacker. Called at any other time, such as from game code or a test, it takes effect at once.
func receive_hit(hit: HitInfo) -> void:
	if pawn == null or not pawn.is_authority() or hit == null or pawn.is_dead():
		return
	if _driver and _driver.is_in_simulate():
		_queue_hit(hit)
		return
	_take_hit(hit)


## The EffectManager calls this on the authority when an effect has just taken this pawn's Health to 0: its Death ability starts and
## died goes out. hit is the hit that did it, or null (a poison's tick). Nothing happens if it's already dead.
func health_ran_out(hit: HitInfo) -> void:
	if pawn and pawn.is_authority() and not pawn.is_dead():
		_die(hit)


## Brings a dead pawn back with full Health, on the server. Its Death ability ends on its next tick.
func revive() -> void:
	if pawn == null or not pawn.is_authority() or pawn.stat_manager == null:
		return
	var stat := pawn.stat_manager.get_stat(&"Health")
	if stat and stat.changes_during_play:
		stat.current = stat.value


# The hit itself, steps 1 to 4 above. Checked again here, because a queued hit can arrive after another killed it, and for
# invulnerability, checked when the hit is delivered: a dash started in the same tick dodges it.
func _take_hit(hit: HitInfo) -> void:
	if not pawn.is_authority() or pawn.is_dead() or is_invulnerable():
		return
	hit_arrived.emit(hit)
	# Claude 2026-11-15: a running parry turns away a hit from the front (ParryAbility). The AI above still notes it was attacked.
	if parry_hit(hit):
		return
	if pawn.effect_manager:
		pawn.effect_manager.take_hit(hit)
	hit_received.emit(hit)
	var attacker := hit.attacker
	if not hit.attacker_effects.is_empty() and is_instance_valid(attacker) and attacker.effect_manager:
		attacker.effect_manager.apply_effects(hit.attacker_effects, attacker, hit.ability, hit)


# Health reached 0: the Death ability starts, which locks out everything and stops the pawn steering; then died goes out, and the
# parts that care clean up (effects end, the AI's behaviour stops, its hands let go).
func _die(hit: HitInfo) -> void:
	if _death == null:
		return
	start_ability(_death)
	died.emit(pawn, hit)


# Holds a hit until after simulate. One queue for all pawns, delivered by the tick driver's after_simulate signal, which is connected
# the first time a hit is queued.
func _queue_hit(hit: HitInfo) -> void:
	if _hit_queue_driver != _driver:
		# GDScript note: AbilityManager._deliver_queued_hits is a Callable on the class itself, not on this manager, so it keeps working
		# after this one is freed.
		if is_instance_valid(_hit_queue_driver) and _hit_queue_driver.after_simulate.is_connected(AbilityManager._deliver_queued_hits):
			_hit_queue_driver.after_simulate.disconnect(AbilityManager._deliver_queued_hits)
		_driver.after_simulate.connect(AbilityManager._deliver_queued_hits)
		_hit_queue_driver = _driver
	_queued_hits.append([_order_key(hit.attacker), _order_key(pawn), _queued_hits.size(), hit])


# The entity id, which is the same on every machine, or -1 for a pawn that isn't networked (the queue order then decides, which is
# the order pawns simulated in).
static func _order_key(node: Node) -> int:
	var target := node as Pawn
	if target == null or not is_instance_valid(target) or target.get_network_entity() == null:
		return -1
	return target.get_network_entity().entity_id


# Delivers every queued hit, sorted by the attacker's entity id, then the target's, then the order they were queued.
static func _deliver_queued_hits(_dt: float, _tick: int) -> void:
	if _queued_hits.is_empty():
		return
	var hits := _queued_hits
	_queued_hits = []
	hits.sort_custom(func(a: Array, b: Array) -> bool:
		if a[0] != b[0]:
			return a[0] < b[0]
		if a[1] != b[1]:
			return a[1] < b[1]
		return a[2] < b[2])
	var hits_started := PerfScopes.begin() # Claude 2026-11-16: timed for diagnostics (PerfScopes)
	for entry in hits:
		var hit: HitInfo = entry[3]
		if is_instance_valid(hit.target) and hit.target.ability_manager:
			hit.target.ability_manager._take_hit(hit)
	PerfScopes.end(&"pawn.hits", hits_started)


func _collect_abilities() -> void:
	_abilities.clear()
	for child in get_children():
		if child is AbilityBase:
			child.manager = self
			child.pawn = pawn
			child.category_mask = TagRegistry.mask_of(child.category) if child.category != &"" else 0
			child.category_mask |= TagRegistry.category_mask_of_list(child.extra_categories) # Claude 2026-11-10
			child.locks_out_mask = TagRegistry.mask_of_list(child.locks_out)
			child.cancelled_by_mask = TagRegistry.mask_of_list(child.cancelled_by) # Claude 2026-11-10
			_collect_effects(child) # Claude 2026-11-10
			child.collect_steps() # Claude 2026-11-16 (pawn spec 8.20)
			_abilities.append(child)
	# GDScript note: sort_custom keeps this rule; abilities with equal priority keep their tree order because each has a distinct index.
	# Claude 2026-11-09: highest priority first (it was lowest first).
	_abilities.sort_custom(func(a: AbilityBase, b: AbilityBase) -> bool:
		return a.priority > b.priority or (a.priority == b.priority and a.get_index() < b.get_index()))
	_death = null # Claude 2026-11-16 (pawn M3)
	_invulnerable_abilities.clear() # Claude 2026-11-10
	_parry_abilities.clear() # Claude 2026-11-15
	_locomotion_pausers.clear() # Claude 2026-11-10
	_stepped.clear() # Claude 2026-11-16
	for ability in _abilities:
		ability.jitter_salt = hash(String(ability.name))
		if ability.is_stepped():
			_stepped.append(ability)
		if ability.invulnerable_while_running:
			_invulnerable_abilities.append(ability)
		if ability is ParryAbility: # Claude 2026-11-15
			_parry_abilities.append(ability)
		if ability is DeathAbility and _death == null: # Claude 2026-11-16 (pawn M3)
			_death = ability
		if ability.pauses_locomotion and ability.kind != AbilityBase.Kind.LOCOMOTION:
			_locomotion_pausers.append(ability)
	_locomotions.clear()
	_actions.clear()
	_default_locomotion = null
	_every_tick_abilities.clear() # Claude 2026-11-09
	_action_bits = 0
	for ability in _abilities:
		ability.trigger_bit = InputActions.mask_of(ability.trigger_action) if ability.trigger_action != &"" else 0 # Claude 2026-11-09
		if ability.kind == AbilityBase.Kind.LOCOMOTION:
			_locomotions.append(ability)
			if ability.trigger_action == &"" and _default_locomotion == null:
				_default_locomotion = ability
		else:
			_actions.append(ability)
			_action_bits |= ability.trigger_bit # Claude 2026-11-09: the input channel
		if _script_overrides_every_tick(ability.get_script()): # Claude 2026-11-09
			_every_tick_abilities.append(ability)
	_timers_dirty = true # Claude 2026-11-09
	_locks_dirty = true


# Claude 2026-11-10 (pawn spec 8.11): the ability's EffectApplier children, into its three effect lists. Each effect is registered,
# so an over-time one in a pawn's active list is recognised by its id on every machine (Effect.register).
func _collect_effects(ability: AbilityBase) -> void:
	ability.on_start_effects.clear()
	ability.on_hit_effects.clear()
	ability.on_hit_self_effects.clear()
	ability.on_parry_effects.clear() # Claude 2026-11-15
	ability.on_parry_self_effects.clear()
	for child in ability.get_children():
		var applier := child as EffectApplier
		if applier == null:
			continue
		for effect in applier.effects:
			if effect == null:
				continue
			effect.register()
			if applier.trigger == EffectApplier.Trigger.ON_START:
				ability.on_start_effects.append(effect)
			elif applier.trigger == EffectApplier.Trigger.ON_PARRY: # Claude 2026-11-15
				if applier.applies_to == EffectApplier.AppliesTo.SELF:
					ability.on_parry_self_effects.append(effect)
				else:
					ability.on_parry_effects.append(effect)
			elif applier.applies_to == EffectApplier.AppliesTo.SELF:
				ability.on_hit_self_effects.append(effect)
			else:
				ability.on_hit_effects.append(effect)


## Tells the pawn's TickStateComponent which ability properties roll back, before the first tick is recorded.
func _register_rollback_state() -> void:
	if pawn == null:
		return
	var tick_state: TickStateComponent = null
	for child in pawn.get_children():
		if child is TickStateComponent:
			tick_state = child
			break
	if tick_state == null:
		return
	var entries: Array[String] = []
	# Claude 2026-11-16 (pawn spec 8.20): the combo counter, when any ability takes part in combos.
	if _abilities.any(func(ability: AbilityBase) -> bool: return not ability.combo_positions.is_empty()):
		var own_path := String(pawn.get_path_to(self))
		entries.append("%s:combo_position" % own_path)
		entries.append("%s:combo_window_ticks_left" % own_path)
	for ability in _abilities:
		var path := String(pawn.get_path_to(ability))
		for property in ability.get_rollback_properties():
			entries.append("%s:%s" % [path, property])
		# Claude 2026-11-16 (pawn spec 8.20): and its steps' state, so a replay lands in the same steps on the same tick.
		for step in ability.steps:
			var step_path := String(pawn.get_path_to(step))
			for property in step.get_rollback_properties():
				entries.append("%s:%s" % [step_path, property])
	if not entries.is_empty():
		tick_state.add_state_properties(entries)


# Claude 2026-11-16 (pawn M4): the pawn's input, from its ControllerManager (nothing pressed without one).
func _held() -> int:
	return pawn.controller_manager.held_actions if pawn.controller_manager else 0


func _previous_held() -> int:
	return pawn.controller_manager.previous_held_actions if pawn.controller_manager else 0


func _move() -> Vector3:
	return pawn.controller_manager.move_input if pawn.controller_manager else Vector3.ZERO
