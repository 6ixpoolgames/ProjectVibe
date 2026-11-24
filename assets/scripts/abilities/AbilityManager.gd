# Written by Claude (claude-opus-5-5), 2026-11-07. History: abilities/CHANGELOG.md.
## Starts, runs and stops a pawn's abilities, and takes the hits that land on it.
##
## A part on the pawn, added by PawnInitializer, with the abilities as its children. The pawn calls [method tick_abilities] once a tick,
## after its input arrives and before [code]move_and_slide[/code]: one locomotion ability runs, then pressed actions start the ready
## ability with the highest priority. Timers are tick deadlines (ability spec 4), so nothing counts down. It owns the cancelling rules,
## the combo counter and the hit path. Everything that persists between ticks lives on the abilities (and the combo counter here) and
## rolls back. Outside code only talks to the manager:
## [codeblock]
## pawn.ability_manager.can_start(&"jump")      # could a press start something now? (the AI asks)
## pawn.ability_manager.action_for_tag(tag)     # the action to press for a kind of ability, such as ability.movement.advanced
## pawn.ability_manager.start_ability(ability)  # starts one with no trigger action, such as Knockback, by the same rules
## pawn.ability_manager.receive_hit(hit)        # something hit this pawn (server)
## [/codeblock]
## Design: pawn spec 8, 8.6, 8.11, 8.16, 8.20, 8.23, 15.2.
class_name AbilityManager
extends Node

# Abilities _run_actions started in place of the one it was looking at, so the same pass doesn't also tick them. Kept so it isn't made
# anew every tick.
var _started_later: Array[AbilityBase] = []

## A [HitInterceptor] stopped a hit, on the server, after its response went out (pawn spec 8.23).
signal hit_intercepted(hit: HitInfo, interceptor: HitInterceptor)

## An ability started.
signal ability_started(ability: AbilityBase)
## An ability stopped, finished or cancelled.
signal ability_finished(ability: AbilityBase)
## An ability was cancelled by another starting, sent after [signal ability_finished] for it.
signal ability_cancelled(ability: AbilityBase, by: AbilityBase)
## A step of a stepped ability started (pawn spec 8.20). Sent by [method AbilityBase.start_step].
@warning_ignore("unused_signal")
signal step_started(ability: AbilityBase, step: AbilityStep)
## A step stopped; reason is "done", "released", "failed" or "cancelled". Sent by [method AbilityBase.stop_step].
@warning_ignore("unused_signal")
signal step_finished(ability: AbilityBase, step: AbilityStep, reason: String)
## A hit reached this pawn, on the server (not dead or invulnerable). Sent before an interceptor can turn it away and before its effects
## land, so the AI notes every attack.
signal hit_arrived(hit: HitInfo)
## A hit landed, on the server, after its effects were applied (pawn spec 8.11); hit.damage_dealt is the Health it took. Not sent for a
## hit an interceptor stopped.
signal hit_received(hit: HitInfo)
## This pawn died, once, on the server, after its Death ability started. hit is what did it, or null. Parts clean up by listening.
signal died(pawn: Pawn, hit: HitInfo)

# Every ability's HitInterceptors by stage, highest priority first (pawn spec 8.23).
var _miss_interceptors: Array[HitInterceptor] = []
var _turn_away_interceptors: Array[HitInterceptor] = []
var _full_movement_abilities: Array[AbilityBase] = [] # those with needs_full_movement (pawn spec 8.22)
var _locomotion_pausers: Array[AbilityBase] = [] # those with pauses_locomotion, usually just Dash

var pawn: Pawn = null
var _driver: Node = null # the TickDriver, for hits during simulate
var _death: DeathAbility = null # found with the abilities
var _knockback: KnockbackAbility = null # likewise, for get_knockback()

var _abilities: Array[AbilityBase] = [] # every ability, in run order: by priority, then tree order
var _locomotions: Array[AbilityBase] = []
var _actions: Array[AbilityBase] = []
var _default_locomotion: AbilityBase = null
var _locked_mask := 0 # categories locked right now, as bits
# Gates and channels (pawn spec 15.2): only what has a reason to run this tick runs.
var _timed: Array[AbilityBase] = [] # abilities with a timer running (a run, a cooldown or a buffered press)
var _next_deadline := -1 # the soonest cooldown, buffer or combo window end still ahead, when _timed was built; -1: none
var _by_action := {} # trigger action -> Array[AbilityBase] answering to it, in run order, so can_start() looks only at those
const _NONE: Array[AbilityBase] = [] # what _by_action gives for an action nothing answers to

# The combo counter, shared by every ability with combo_positions (pawn spec 8.20). Both values roll back.
## The combo position the last combo ability took; 0: none yet. Pushed to the state store when it changes.
var combo_position := 0:
	set(value):
		if value == combo_position:
			return
		combo_position = value
		_push_state(&"combo_position", value)
## The combo window is open until this tick (not including it): a follow-up for the next position can start. Pushed when it changes.
var combo_open_until := 0:
	set(value):
		if value == combo_open_until:
			return
		combo_open_until = value
		_push_state(&"combo_open_until", value)
		_timers_dirty = true
# Where _push_state sends the two above: the pawn's TickStateComponent and their entries there, set by _register_rollback_state.
var _tick_state: TickStateComponent = null
var _pushed_keys := {}
## Goes up by one whenever what [method can_start] answers may change (a run or step starting or ending, a deadline passing, effects
## changing, the owned tags changing while an ability has start requirements); the AI keeps its last answer until it moves (scaling
## spec 6.2). A passed deadline or a tag change moves it when next read, so the AI sees a cooldown end on its tick.
var readiness_version := 0:
	get:
		_note_deadline_passed()
		_note_tags_changed()
		return readiness_version
var _timers_dirty := true # a timer started or reached 0, so _timed is rebuilt before it's next used
var _locks_dirty := true # an action started or stopped, so the locks are worked out again before they're next used
var _every_tick_abilities: Array[AbilityBase] = [] # abilities whose script overrides every_tick()
var _action_bits := 0 # the input bits of every action's trigger_action: the presses anything here answers to
var _follows_body := {} # trigger action -> true when an ability on it has its own can_start(), such as Jump needing the ground
var _charged: Array[AbilityBase] = [] # abilities with limited uses
var _next_charge_tick := -1 # the soonest charge deadline (a restore, a change ending) among them; -1: none
var _has_start_requirements := false # some ability here has start_requirements, so owned-tag changes move readiness_version
var _tags_version_seen := -1


func _init() -> void:
	set_process(false)
	set_physics_process(false)


func _enter_tree() -> void:
	pawn = get_parent() as Pawn
	# It tells its pawn it's here, before any part's _ready; the first AbilityManager a pawn has is the one it uses.
	if pawn and not is_instance_valid(pawn.ability_manager):
		pawn.ability_manager = self
	if pawn == null:
		push_warning("AbilityManager: its parent isn't a Pawn, so it does nothing.")


func _ready() -> void:
	var driver: Node = get_node_or_null("/root/TickDriver")
	_driver = driver
	_collect_abilities()
	_register_rollback_state()
	if pawn:
		pawn.gameplay_event_received.connect(_on_gameplay_event)


## The pawn calls this once a tick; dt is the fixed tick length. Order: deadlines passed, locomotion, then actions (see the README).
func tick_abilities(dt: float) -> void:
	if pawn == null:
		return
	# Each step only touches what has a reason to run (pawn spec 15.2).
	if _locks_dirty:
		_recompute_locks()
	_note_deadline_passed()
	if _timers_dirty:
		_rebuild_timed()
	var now: int = TickDriver.tick
	if _next_charge_tick >= 0 and now >= _next_charge_tick:
		for ability in _charged:
			ability.apply_charge_deadlines(now)
		_timers_dirty = true
		_rebuild_timed()
	for ability in _every_tick_abilities:
		ability.every_tick(dt)
	_run_locomotion(dt)
	if _actions_have_work():
		_run_actions(dt)


## The abilities' timers call this when one is set (pawn spec 15.2).
func timers_changed() -> void:
	_timers_dirty = true
	_locks_dirty = true
	readiness_version += 1


# A cooldown, buffer or combo window ended since the last look: what can start may have changed, and _timed is out of date. Once per
# deadline: the next is found when _timed is rebuilt.
func _note_deadline_passed() -> void:
	if _next_deadline >= 0 and TickDriver.tick >= _next_deadline:
		_next_deadline = -1
		readiness_version += 1
		_timers_dirty = true


## After a rollback loads this pawn's state: what's worked out from the deadlines is worked out again. A loaded deadline equal to the
## one it replaces calls no setter, but the soonest one still ahead depends on the tick, which went back.
func state_loaded() -> void:
	timers_changed()
	for ability in _charged:
		ability.update_charges_tag() # a loaded value equal to the one it replaces calls no setter
	for ability in _abilities:
		if ability.is_stepped():
			ability.timeline_loaded() # its running entries' values back onto their steps


# The owned tags changed since the last look, and some ability's start requirements read them: what can start may have changed.
func _note_tags_changed() -> void:
	if not _has_start_requirements or pawn == null or pawn.owned_tags == null:
		return
	var version := pawn.owned_tags.version
	if version != _tags_version_seen:
		_tags_version_seen = version
		readiness_version += 1


## Moves [member readiness_version] on for a change made outside the abilities; the StatusManager calls it when effects change.
func readiness_changed() -> void:
	readiness_version += 1


## True if an ability on this action has its own [method AbilityBase.can_start], which can change without telling the manager (Jump
## needs the ground). The AI asks such an action at every decision, whatever [member readiness_version] says.
func ready_follows_body(action: StringName) -> bool:
	return _follows_body.has(action)


## True if the pawn can sleep as far as its abilities go (pawn spec 15.3): no timer running (unless that ability can wait), no combo
## window open, and every every_tick() ability agrees.
func can_sleep() -> bool:
	if _timers_dirty:
		_rebuild_timed()
	# Death can wait while Health is 0, so a corpse doesn't run its abilities every tick.
	for ability in _timed:
		if not ability.can_sleep_while_running():
			return false
	if is_combo_window_open(): # the window's end must be seen, to tell the AI (readiness_version)
		return false
	if _next_charge_tick >= 0: # charges coming back flip the has-charges tag the AI reads
		return false
	for ability in _every_tick_abilities:
		if not ability.can_sleep():
			return false
	return true


## True if pressing this action now would start something, counting abilities it would cancel. Changes nothing; looks only at the
## abilities on that action.
func can_start(action: StringName) -> bool:
	for ability: AbilityBase in _by_action.get(action, _NONE):
		if not ability.is_running_timed() and _is_ready(ability):
			return true
	return false


## The action to press to start an ability in this group (a category or extra_category such as &"ability.movement.advanced"): the
## highest-priority one that could start now, boosts included; &"" if none. For the AI, so a behaviour asks for a kind of ability, not
## one by name. It answers with an action because everything a pawn does goes through its (rolled back) input. Changes nothing.
func action_for_tag(tag: StringName) -> StringName:
	var bit := TagRegistry.own_bit(tag) if TagRegistry.has_tag(tag) else 0
	if bit == 0:
		return &"" # an unknown tag matches nothing, and isn't added
	var best: AbilityBase = null
	for ability in _actions:
		if ability.settings.trigger_action != &"" and ability.category_mask & bit != 0 and not ability.is_running_timed() and _is_ready(ability):
			if best == null or press_priority_now(ability) > press_priority_now(best):
				best = ability
	return best.settings.trigger_action if best else &""


## Starts an ability by the same rules as a press (cooldown, can_start, cancelling what conflicts). For abilities started by code,
## such as Knockback. One already running starts again from the beginning. Returns false if it couldn't start.
func start_ability(ability: AbilityBase) -> bool:
	if ability == null or ability.manager != self:
		return false
	if ability.is_running_timed():
		# Starting again ends the run properly first (steps end, stop() runs, ability_finished goes out). Whether it may start is
		# checked first, as if it weren't running; if not, the run carries on.
		var ends := ability.ends_at
		ability.ends_at = -1
		var may_restart := _is_ready(ability)
		ability.ends_at = ends
		if not may_restart:
			return false
		_finish(ability)
		ability.ready_at = TickDriver.tick # starts again from the beginning, without a cooldown in between
	if not _is_ready(ability):
		return false
	_clear_way(ability)
	_start(ability)
	return true


## The first active TURN_AWAY interceptor that stops this hit, or null (pawn spec 8.23). Its response and [signal hit_intercepted] have
## gone out. A reply to an interception isn't turned away.
func intercept_hit(hit: HitInfo) -> HitInterceptor:
	if hit.from_interception:
		return null
	for interceptor in _turn_away_interceptors:
		if interceptor.is_active() and interceptor.intercept(hit) == HitInterceptor.Result.STOP:
			interceptor.respond(hit)
			hit_intercepted.emit(hit, interceptor)
			return interceptor
	return null


## True while a MISS-stage interceptor is on, such as a Dash's first 0.18 s. Hits don't arrive and harmful effects are refused.
func is_invulnerable() -> bool:
	for interceptor in _miss_interceptors:
		if interceptor.is_active():
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
		if ability.settings.trigger_action == action:
			return true
	return false


## Stops every running ability, which starts their cooldowns.
func stop_all() -> void:
	for ability in _abilities:
		if ability.is_running_timed():
			_finish(ability)
	_recompute_locks()


## Stops whatever is running for this action, which starts its cooldown.
func cancel(action: StringName) -> void:
	for ability in _abilities:
		if ability.settings.trigger_action == action and ability.is_running_timed():
			_finish(ability)


## True if this ability's category is locked out right now.
func is_locked(ability: AbilityBase) -> bool:
	return ability.category_mask & _locked_mask != 0


## True while an ability with needs_full_movement runs (Dash, Knockback), so the pawn moves by physics, not the CrowdMover (pawn spec 8.22).
func needs_full_movement() -> bool:
	for ability in _full_movement_abilities:
		if ability.is_running_timed():
			return true
	return false


## Every ability, in run order.
func get_abilities() -> Array[AbilityBase]:
	return _abilities.duplicate()


## This pawn's Knockback ability, or null. A KnockbackPart asks on every push.
func get_knockback() -> KnockbackAbility:
	return _knockback


## True while any ability on this action runs. Cheap, for asking every tick: looks only at abilities with a timer going.
func is_action_running(action: StringName) -> bool:
	if _timers_dirty:
		_rebuild_timed()
	for ability in _timed:
		if ability.settings.trigger_action == action and ability.is_running_timed():
			return true
	return false


# --- Internals ---


func _run_locomotion(dt: float) -> void:
	var chosen: AbilityBase = null
	for ability in _locomotions:
		if ability.trigger_bit == 0: # no action of its own (reads the bit, not the setting: this runs every tick)
			continue
		var wanted := _held() & ability.trigger_bit != 0
		if ability.is_running_timed():
			if wanted and not is_locked(ability):
				chosen = ability
				break
			_finish(ability) # let go, or locked out
		elif wanted and _is_ready(ability):
			_clear_way(ability)
			_start(ability)
			chosen = ability
			break
	if chosen == null:
		chosen = _default_locomotion
		# Moving cancels a conflicting action that allows it (threshold 0, such as an emote).
		if chosen and is_locked(chosen) and _move().length_squared() > 0.0001 and _conflicts_allow(chosen):
			_clear_way(chosen)
	# Only one locomotion runs. Any other timed one still going stops.
	for ability in _locomotions:
		if ability != chosen and ability.is_running_timed():
			_finish(ability)
	if chosen == null:
		return
	# An action with pauses_locomotion is running (a Dash): no steering and no slowing this tick, so the action's own movement isn't
	# fought. A timed locomotion's time waits too: its deadlines move on by the ticks this run covers.
	for ability in _locomotion_pausers:
		if ability.is_running_timed():
			chosen.delay_run(pawn.ticks_elapsed)
			return
	chosen.tick(dt)
	if chosen.is_stepped() and chosen.is_running_timed():
		chosen.run_steps(dt)
	if chosen.is_run_over():
		_finish(chosen) # its time is up, or its last step ended: stopped, with its cooldown


func _run_actions(dt: float) -> void:
	# This tick's presses as bits, worked out once (pawn spec 15.2).
	var pressed_bits: int = _held() & ~_previous_held()
	var used_bits := 0 # actions that started something this tick, so one press starts one ability
	# Actions with a press waiting in a buffer: every ready ability on one competes when the wait ends, not only the one holding it.
	var waiting_bits := 0
	for ability in _timed:
		if ability.is_buffered():
			waiting_bits |= ability.trigger_bit
	_started_later.clear()
	for ability in _actions:
		if ability.is_running_timed():
			# Started in this pass by an earlier ability's press (_best_ready picked it); its first tick is the next one.
			if not _started_later.is_empty() and _started_later.has(ability):
				continue
			ability.tick(dt)
			if ability.is_stepped():
				ability.run_steps(dt) # may end it (end_run)
			if ability.is_run_over():
				_finish(ability)
			continue
		if ability.trigger_bit == 0 or used_bits & ability.trigger_bit != 0:
			continue
		var pressed := pressed_bits & ability.trigger_bit != 0
		if not pressed and not ability.is_buffered():
			continue
		if _is_ready(ability):
			# Jitter or an effect's boost can lift another ability on this action above this one.
			var chosen := _best_ready(ability, pressed_bits | waiting_bits)
			_clear_way(chosen) # cancels what it's strong enough to cancel
			_start(chosen)
			if chosen != ability:
				_started_later.append(chosen) # see the top of this loop
			used_bits |= ability.trigger_bit
		elif pressed and ability.settings.buffer_window_ticks > 0:
			ability.buffer_until = TickDriver.tick + TickDriver.ticks_at_rate(ability.settings.buffer_window_ticks)
	# A press that started something doesn't also wait in another ability on the same action.
	if used_bits != 0: # skipped when nothing started
		for ability in _actions:
			if used_bits & ability.trigger_bit != 0 and not ability.is_running_timed():
				ability.buffer_until = 0


# Of the ready abilities on first's action that are pressed or waiting, the highest priority plus jitter and boosts (pawn spec 8.11);
# ties go to the earlier in the list. With no jitter and no boost that is always first. wanted_bits: actions pressed or buffered.
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


# Priority plus effect boosts plus this tick's random offset, drawn from the tick's own random numbers so a replay draws the same.
func _priority_now(ability: AbilityBase) -> float:
	if ability.settings.priority_jitter <= 0.0:
		return float(press_priority_now(ability))
	return press_priority_now(ability) + ability.settings.priority_jitter * DeterministicRandom.signed(pawn.entity_number(), TickDriver.tick, ability.jitter_salt)


## An ability's priority now: its own plus what effects add (AbilityPriorityPart, pawn spec 8.11), without the jitter offset.
func press_priority_now(ability: AbilityBase) -> int:
	return ability.settings.priority + _bonus(ability, AbilityPriorityPart.Number.PRESS_PRIORITY)


## Its interrupt_priority right now, with what effects add.
func interrupt_priority_now(ability: AbilityBase) -> int:
	return ability.settings.interrupt_priority + _bonus(ability, AbilityPriorityPart.Number.INTERRUPT_PRIORITY)


## Its interrupt_threshold now, with what effects add; for a stepped ability, the strictest of its running steps'.
func interrupt_threshold_now(ability: AbilityBase) -> int:
	return ability.current_interrupt_threshold() + _bonus(ability, AbilityPriorityPart.Number.INTERRUPT_THRESHOLD)


# What the pawn's effects add to one of an ability's numbers; 0 with no StatusManager or nothing held.
func _bonus(ability: AbilityBase, number: int) -> int:
	var effects := pawn.status_manager if pawn else null
	if effects == null or not effects.has_ability_bonuses():
		return 0
	return effects.ability_bonus(ability, number)


# Ready to start: no cooldown, a charge left, its start requirements pass, a combo position it fits, every conflicting running ability can be
# cancelled by it, and its own can_start().
func _is_ready(ability: AbilityBase) -> bool:
	return TickDriver.tick >= ability.ready_at and (not ability.uses_charges() or ability.charges_left() > 0) and _tags_allow(ability) \
		and _combo_allows(ability) and _conflicts_allow(ability) and ability.can_start()


# Its start requirements against the pawn's owned tags (no requirements: yes).
func _tags_allow(ability: AbilityBase) -> bool:
	var query := ability.settings.start_requirements
	return query == null or query.matches(pawn.owned_tags if pawn else null)


## Opens the combo window for this many ticks. An [OpenComboStep] calls it after its ability's hit.
func open_combo_window(ticks: int) -> void:
	combo_open_until = TickDriver.tick + maxi(ticks, 0)
	readiness_version += 1


## True while the combo window is open.
func is_combo_window_open() -> bool:
	return TickDriver.tick < combo_open_until


## Ticks left in the combo window; 0 when it's shut. For readouts.
func combo_window_ticks_left() -> int:
	return maxi(combo_open_until - TickDriver.tick, 0)


## The combo position it would take if it started now: the next, if the window is open and it fits; else 1 for an opener; else 0
## (can't start now). 0 too with no combo_positions.
func combo_position_for(ability: AbilityBase) -> int:
	if ability.settings.combo_positions.is_empty():
		return 0
	var next := combo_position + 1
	if is_combo_window_open() and ability.settings.combo_positions.has(next):
		return next
	return 1 if ability.settings.combo_positions.has(1) else 0


# A combo follow-up can only start where it fits; anything else isn't held back by combos.
func _combo_allows(ability: AbilityBase) -> bool:
	return ability.settings.combo_positions.is_empty() or combo_position_for(ability) > 0


# Two abilities conflict when either one's locks_out covers the other's category.
func _conflicts(a: AbilityBase, b: AbilityBase) -> bool:
	return a.locks_out_mask & b.category_mask != 0 or b.locks_out_mask & a.category_mask != 0


# True if every running ability that conflicts with this one lets it through (_lets_through). Looks at _timed, never rebuilding it
# here because _run_actions loops over it while asking; when it's out of date, every ability is looked at, with the same answer.
func _conflicts_allow(ability: AbilityBase) -> bool:
	for other in (_abilities if _timers_dirty else _timed):
		if other != ability and other.is_running_timed() and not _lets_through(ability, other):
			return false
	return true


# The one rule, shared by starting and the interrupt table so they can't disagree: they don't conflict, or starting is strong enough
# (effects included), or running lists starting's group in cancelled_by.
func _lets_through(starting: AbilityBase, running: AbilityBase) -> bool:
	return not _conflicts(starting, running) or interrupt_threshold_now(running) <= interrupt_priority_now(starting) \
			or running.cancelled_by_mask & starting.category_mask != 0


## What happens if starting tries to start while running runs, by this pawn's numbers now (effects included). Ignores cooldowns and can_start.
## [br]Returns {"result": "alongside" | "cancels" | "blocked", "reason": text}: alongside (no lockout between them), cancels (priority at
## least the threshold, or cancelled_by), blocked (a locomotion ability stops steering instead).
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


## The interrupt table (pawn spec 8.10): a row per ability that can run (timed ones and locomotion), in run order, with an
## [method interrupt_rule] answer per other ability. Instant actions such as Jump have no row.
func get_interrupt_table() -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	for running in _abilities:
		# Timed abilities, not instant ones (their length can come from a duration, steps, phases or a push).
		if running.kind != AbilityBase.Kind.LOCOMOTION and not running.is_timed():
			continue
		var row := {"running": running.name, "priority": interrupt_priority_now(running), "threshold": interrupt_threshold_now(running), "cells": {}}
		for starting in _abilities:
			if starting != running:
				row["cells"][starting.name] = interrupt_rule(starting, running)
		rows.append(row)
	return rows


## The interrupt table as text, a line per ability with what cancels it and what it blocks.
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


# Cancels every running ability that conflicts with this one. Only after _conflicts_allow said yes.
func _clear_way(ability: AbilityBase) -> void:
	var cancelled := false
	for other in _abilities:
		if other != ability and other.is_running_timed() and _conflicts(ability, other):
			_finish(other)
			ability_cancelled.emit(other, ability)
			cancelled = true
	if cancelled:
		_recompute_locks()


# The categories locked out now, from every running timed action.
func _recompute_locks() -> void:
	_locked_mask = 0
	_locks_dirty = false
	for ability in _actions:
		if ability.is_running_timed():
			_locked_mask |= ability.locks_out_mask


# The abilities with a timer running, kept so a tick only looks at those (pawn spec 15.2), and the soonest deadline still ahead, when the
# list next changes by itself.
func _rebuild_timed() -> void:
	_timed.clear()
	_timers_dirty = false
	var now: int = TickDriver.tick
	_next_deadline = -1
	for ability in _abilities:
		var cooling := now < ability.ready_at
		var waiting := now < ability.buffer_until
		if ability.ends_at >= 0 or cooling or waiting:
			_timed.append(ability)
		if cooling and (_next_deadline < 0 or ability.ready_at < _next_deadline):
			_next_deadline = ability.ready_at
		if waiting and (_next_deadline < 0 or ability.buffer_until < _next_deadline):
			_next_deadline = ability.buffer_until
	if now < combo_open_until and (_next_deadline < 0 or combo_open_until < _next_deadline):
		_next_deadline = combo_open_until
	_next_charge_tick = -1
	for ability in _charged:
		var due := ability.next_charge_deadline()
		if due >= 0 and (_next_charge_tick < 0 or due < _next_charge_tick):
			_next_charge_tick = due
	if _next_charge_tick >= 0 and (_next_deadline < 0 or _next_charge_tick < _next_deadline):
		_next_deadline = _next_charge_tick # readiness moves on when charges come back


# Whether _run_actions has work this tick: a new press of an action answered here, an action running, or a buffered press.
func _actions_have_work() -> bool:
	if _held() & ~_previous_held() & _action_bits != 0:
		return true
	for ability in _timed:
		if ability.kind == AbilityBase.Kind.ACTION and (ability.ends_at >= 0 or ability.is_buffered()):
			return true
	return false


func _start(ability: AbilityBase) -> void:
	readiness_version += 1
	ability.buffer_until = 0
	ability.spend_charge()
	ability.pawns_hit_this_run = PackedInt64Array()
	if ability.hit_run:
		ability.hit_run.clear() # its swing's log starts again with the run
	# A combo ability takes its position and closes the window until its OpenComboStep opens it again.
	var taken := combo_position_for(ability)
	if taken > 0:
		combo_position = taken
		combo_open_until = 0
	var length := ability.run_length_ticks()
	if length > 0:
		ability.started_at = TickDriver.tick
		ability.ends_at = TickDriver.tick + length
	if ability.kind == AbilityBase.Kind.ACTION and ability.is_running_timed():
		_locked_mask |= ability.locks_out_mask # later abilities this tick respect it at once
	ability.start()
	# On-start effects go on its own pawn on every machine that runs it, replays too, so an over-time one (a combo boost) is
	# predicted; their do-once parts run only on the authority (StatusManager). Pawn spec 8.11.
	if not ability.on_start_effects.is_empty() and pawn.status_manager:
		pawn.status_manager.apply_effects(ability.on_start_effects, pawn, ability)
	ability_started.emit(ability)
	if ability.is_stepped() and ability.is_running_timed():
		ability.begin_steps() # after ability_started, so a replay lists the ability before its steps
	if ability.kind == AbilityBase.Kind.ACTION and not ability.is_running_timed():
		_finish(ability) # an action with no duration is done as soon as it starts


func _finish(ability: AbilityBase) -> void:
	readiness_version += 1
	ability.end_steps("cancelled") # steps still running when it ends early; none when they finished
	ability.ends_at = -1
	if ability.settings.cooldown_ticks > 0:
		ability.ready_at = TickDriver.tick + TickDriver.ticks_at_rate(ability.settings.cooldown_ticks)
	ability.stop()
	ability_finished.emit(ability)


# --- Hits and death (pawn spec 8.16: hits and death are abilities' business) ---


## Something hit this pawn; the server's attacker calls it, such as a [MeleeSweepStep]. Dead or invulnerable pawns ignore it. During
## simulate it's booked with the tick scheduler and delivered after every pawn has simulated, in a fixed order (attacker's entity
## number, target's, booking order), so it never depends on who simulated first (pawn spec 15.4); otherwise it takes effect at once.
## Steps: see the README.
func receive_hit(hit: HitInfo) -> void:
	if pawn == null or not pawn.is_authority() or hit == null or pawn.is_dead():
		return
	if _driver and _driver.is_in_simulate():
		# Entity numbers are below 2^31, so attacker then target fit one order number.
		var order := (maxi(EntityNumber.of(hit.attacker), 0) << 31) | maxi(pawn.entity_number(), 0)
		_driver.scheduler.book(_driver.tick, _take_hit.bind(hit), TickScheduler.Point.AFTER_SIMULATE, order)
		return
	_take_hit(hit)


## Death starts and [signal died] goes out, on the authority: called when the pawn's Health reaches 0 ([code]event.health.depleted[/code],
## sent by the status manager). hit is the hit that did it, or null (a poison's tick). Nothing if already dead.
func health_ran_out(hit: HitInfo) -> void:
	if pawn and pawn.is_authority() and not pawn.is_dead():
		_die(hit)


## Brings a dead pawn back with full Health, on the server. Death ends on its next tick.
func revive() -> void:
	if pawn == null or not pawn.is_authority() or pawn.status_manager == null:
		return
	pawn.status_manager.fill_current(StatusManager.HEALTH)
	for ability in _charged:
		ability.refill_charges()


# Gameplay events this pawn receives. Abilities started by events in general come with the hit ability (pawn spec 16.10, step 4).
func _on_gameplay_event(event: GameplayEventData) -> void:
	if event.tag == Tags.EVENT.HEALTH_DEPLETED:
		health_ran_out(event.optional_object as HitInfo)


# The hit itself. Checked again here: a queued hit can arrive after another killed this pawn, and a dash started in the same tick
# dodges it.
func _take_hit(hit: HitInfo) -> void:
	if not pawn.is_authority() or pawn.is_dead() or is_invulnerable():
		return
	hit_arrived.emit(hit)
	# An active interceptor can turn it away. The AI above still notes it was attacked.
	if intercept_hit(hit):
		return
	if pawn.status_manager:
		pawn.status_manager.take_hit(hit)
	hit_received.emit(hit)
	var attacker := hit.attacker
	if not hit.attacker_effects.is_empty() and is_instance_valid(attacker) and attacker.status_manager:
		attacker.status_manager.apply_effects(hit.attacker_effects, attacker, hit.ability, hit)


# Health reached 0: Death starts (it locks out everything), then died goes out and the parts that care clean up.
func _die(hit: HitInfo) -> void:
	if _death == null:
		return
	start_ability(_death)
	died.emit(pawn, hit)


func _collect_abilities() -> void:
	_abilities.clear()
	_miss_interceptors.clear() # filled as each ability is collected below
	_turn_away_interceptors.clear()
	for child in get_children():
		if child is AbilityBase:
			child.manager = self
			child.pawn = pawn
			child.prepare_settings() # its definition worked out, or its kind's defaults
			child.category_mask = TagRegistry.mask_of(child.settings.category) if child.settings.category != &"" else 0
			child.category_mask |= TagRegistry.full_mask_of_list(child.settings.extra_categories)
			child.locks_out_mask = TagRegistry.mask_of_list(child.settings.locks_out)
			child.cancelled_by_mask = TagRegistry.mask_of_list(child.settings.cancelled_by)
			_collect_effects(child)
			child.collect_steps()
			_collect_interceptors(child) # after its steps, which can hold them too
			_abilities.append(child)
	# Highest priority first, then tree order.
	_abilities.sort_custom(func(a: AbilityBase, b: AbilityBase) -> bool:
		return a.settings.priority > b.settings.priority or (a.settings.priority == b.settings.priority and a.get_index() < b.get_index()))
	_death = null
	_knockback = null
	_full_movement_abilities.clear()
	_locomotion_pausers.clear()
	for ability in _abilities:
		ability.jitter_salt = hash(String(ability.name))
		if ability.settings.needs_full_movement:
			_full_movement_abilities.append(ability)
		# REFACTOR: Death and Knockback are found by class, so a game changes dying or staggering only by extending them. A tag
		# (ability.death, ability.combat.knockback) would let any ability fill the role; extensible.
		if ability is DeathAbility and _death == null:
			_death = ability
		if ability is KnockbackAbility and _knockback == null:
			_knockback = ability
		if ability.settings.pauses_locomotion and ability.kind != AbilityBase.Kind.LOCOMOTION:
			_locomotion_pausers.append(ability)
	_locomotions.clear()
	_actions.clear()
	_default_locomotion = null
	_every_tick_abilities.clear()
	_action_bits = 0
	for ability in _abilities:
		ability.trigger_bit = InputActions.mask_of(ability.settings.trigger_action) if ability.settings.trigger_action != &"" else 0
		if ability.kind == AbilityBase.Kind.LOCOMOTION:
			_locomotions.append(ability)
			if ability.settings.trigger_action == &"" and _default_locomotion == null:
				_default_locomotion = ability
		else:
			_actions.append(ability)
			_action_bits |= ability.trigger_bit # the input channel
		if ScriptOverrides.overrides(ability.get_script(), &"every_tick"):
			_every_tick_abilities.append(ability)
	_note_start_requirements()
	_charged.clear()
	for ability in _abilities:
		if ability.uses_charges():
			_charged.append(ability)
		ability.update_charges_tag()
	_timers_dirty = true
	_by_action.clear()
	_follows_body.clear()
	for ability in _abilities:
		if ability.settings.trigger_action != &"":
			if not _by_action.has(ability.settings.trigger_action):
				var list: Array[AbilityBase] = []
				_by_action[ability.settings.trigger_action] = list
			_by_action[ability.settings.trigger_action].append(ability)
			if ScriptOverrides.overrides(ability.get_script(), &"can_start"):
				_follows_body[ability.settings.trigger_action] = true
	_timers_dirty = true
	_locks_dirty = true
	readiness_version += 1


## An ability's settings changed while playing ([method AbilityBase.use_definition]): its masks, priority order and lists are worked
## out again.
func settings_changed() -> void:
	_collect_abilities()


# Which abilities have start requirements (so owned-tag changes move readiness_version), with a warning for a query that names the
# AI's own tags, which clients never own.
func _note_start_requirements() -> void:
	_has_start_requirements = false
	_tags_version_seen = -1
	for ability in _abilities:
		var query := ability.settings.start_requirements
		if query == null or query.is_empty():
			continue
		_has_start_requirements = true
		for tag in query.all_of + query.any_of + query.none_of:
			if String(tag).begins_with("ai.") or String(tag) == "ai":
				push_warning("AbilityManager: %s's start requirements name %s, an AI tag only the server owns, so a client predicts its start wrong. Use ability, effect or status tags." % [ability.name, tag])
				break


# The ability's EffectApplier children, into its three effect lists (pawn spec 8.11). Each effect is registered so an over-time one in
# the active list is recognised by id on every machine (Effect.register).
func _collect_effects(ability: AbilityBase) -> void:
	ability.on_start_effects.clear()
	ability.on_hit_effects.clear()
	ability.on_hit_self_effects.clear()
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
			elif applier.trigger == EffectApplier.Trigger.ON_INTERCEPT:
				# These belong under a HitInterceptor, which collects its own.
				push_warning("AbilityManager: %s has an ON_INTERCEPT EffectApplier directly under it; put it under one of its HitInterceptors." % ability.name)
			elif applier.applies_to == EffectApplier.AppliesTo.SELF:
				ability.on_hit_self_effects.append(effect)
			else:
				ability.on_hit_effects.append(effect)


# An ability's HitInterceptors (pawn spec 8.23), under it and its steps (its defaults are made first if it has none), into the two
# lists, highest priority first. sort_custom isn't stable, so the order found is kept as the tie-break.
func _collect_interceptors(ability: AbilityBase) -> void:
	var found: Array[HitInterceptor] = []
	_find_interceptors(ability, null, ability, found)
	if found.is_empty():
		ability.make_default_interceptors()
		_find_interceptors(ability, null, ability, found)
	ability.interceptors = found
	for interceptor in found:
		interceptor.ability = ability
		interceptor.pawn = pawn
		interceptor.on_intercept_effects.clear()
		interceptor.on_intercept_self_effects.clear()
		for child in interceptor.get_children():
			var applier := child as EffectApplier
			if applier == null or applier.trigger != EffectApplier.Trigger.ON_INTERCEPT:
				continue
			for effect in applier.effects:
				if effect:
					effect.register()
					if applier.applies_to == EffectApplier.AppliesTo.SELF:
						interceptor.on_intercept_self_effects.append(effect)
					else:
						interceptor.on_intercept_effects.append(effect)
		var into := _miss_interceptors if interceptor.stage == HitInterceptor.Stage.MISS else _turn_away_interceptors
		interceptor.set_meta(&"found_order", into.size())
		into.append(interceptor)
	for list: Array[HitInterceptor] in [_miss_interceptors, _turn_away_interceptors]:
		list.sort_custom(func(a: HitInterceptor, b: HitInterceptor) -> bool:
			return a.priority > b.priority or (a.priority == b.priority and int(a.get_meta(&"found_order")) < int(b.get_meta(&"found_order"))))


# The interceptors directly under node (an ability or a step), and under its steps.
func _find_interceptors(node: Node, step: AbilityStep, ability: AbilityBase, found: Array[HitInterceptor]) -> void:
	for child in node.get_children():
		if child is HitInterceptor:
			child.step = step
			found.append(child)
		elif child is AbilityStep and node == ability:
			_find_interceptors(child, child, ability, found)


# Tells the pawn's TickStateComponent which ability properties roll back, before the first tick is recorded.
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
	# The combo counter, when any ability takes part in combos.
	if _abilities.any(func(ability: AbilityBase) -> bool: return not ability.settings.combo_positions.is_empty()):
		var own_path := String(pawn.get_path_to(self))
		for property: String in ["combo_position", "combo_open_until"]:
			entries.append("%s:%s pushed" % [own_path, property])
			_pushed_keys[StringName(property)] = "%s:%s" % [own_path, property]
		_tick_state = tick_state
	for ability in _abilities:
		var path := String(pawn.get_path_to(ability))
		for property in ability.get_rollback_properties():
			entries.append("%s:%s" % [path, property])
		# Pushed: recorded when the setter calls push_state, never read at the commit (state store spec 6.3). An encoding written
		# after the name ("dash_direction @vec3_mm") isn't part of the key.
		for property in ability.get_pushed_properties():
			var key := "%s:%s" % [path, property.split("@")[0].strip_edges()]
			entries.append("%s:%s pushed" % [path, property])
			ability._pushed_keys[StringName(property.split("@")[0].strip_edges())] = key
		ability._tick_state = tick_state
		# Its steps' extra state too, so a replay lands in the same steps on the same tick.
		for step in ability.steps:
			var step_path := String(pawn.get_path_to(step))
			for property in step.get_rollback_properties():
				entries.append("%s:%s" % [step_path, property])
	if not entries.is_empty():
		tick_state.add_state_properties(entries)


# The pawn's input, from its ControllerManager (nothing pressed without one).
func _held() -> int:
	return pawn.controller_manager.held_actions if pawn.controller_manager else 0


func _previous_held() -> int:
	return pawn.controller_manager.previous_held_actions if pawn.controller_manager else 0


func _move() -> Vector3:
	return pawn.controller_manager.move_input if pawn.controller_manager else Vector3.ZERO


# Records the combo counter's new value in the state store (see AbilityBase.push_state).
func _push_state(property: StringName, value: Variant) -> void:
	if _tick_state:
		var key: Variant = _pushed_keys.get(property)
		if key != null:
			_tick_state.push_value(key, value)
