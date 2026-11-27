# Written by Claude (claude-opus-5-5), 2026-11-09. History: ai/CHANGELOG.md.
## The pawn's AI: holds its AI components as children, what they share, and the step that runs them in order.
##
## A component on the pawn ([member Pawn.ai]), added by PawnInitializer from parts/AIManager.tscn. Its children are the AI's components:
## the [AIController] (the AI's hands), [AISensingManager], [AIMemory], [AITargetSelector], [AIStateManager] and
## [AIBehaviourManager]. A pawn scene overrides one by putting its own of that name under its AIManager; PawnInitializer fills in the
## rest. It makes no decisions: it holds what the components share (the pawn, the current target, the pawn's [AIInputs], the last hit
## and swing coming, the waiting decision, and random numbers that replay the same), and the pawn calls [method run_ai] from its own
## tick, which runs [method think]. Behaviours and states get it as their "context" ([code]context.memory[/code],
## [code]context.current_tick[/code], [code]context.random_unit(salt)[/code]). Code outside the AI asks through its request inbox
## ([method add_modifier], [method remove_modifiers], [method set_input]): requests wait for the pawn's next AI step and apply in the
## order asked, so no result depends on which pawn ran first. Design: pawn spec 10, 10.7, 10.9 and 16.5.
class_name AIManager
extends Node

## What the AI does while a player has the pawn (pawn spec 10.3).
enum WhilePossessed {
	OFF, ## nothing runs
	MEMORY_ONLY, ## sensing and memory run; states and behaviours pause. The default
	FULL, ## everything runs. The running behaviour's steps wait, and run once the AI controller is in charge again
}

## What the AI does while a player has the pawn. MEMORY_ONLY suits possessing an NPC and letting go: the AI already knows what's around.
@export var while_possessed := WhilePossessed.MEMORY_ONLY
## How often the AI decides, in ticks at 60 a second (15: four times a second). Each pawn is offset by its own number, so a crowd
## doesn't all decide on one tick. Some events wake a decision early (pawn spec 10.9).
@export_range(1, 600, 1, "or_greater") var decision_interval_ticks := 15
## Part of every random number this AI uses, with the match seed; entity numbers still make two pawns differ.
@export var random_seed := 0

## Where every AI pawn's orders come from, if not from its own AI: called instead of [method think] in each pawn's AI step, as
## [code]order_source.call(context, tick)[/code], to start and stop its behaviours and their steps
## ([method AIBehaviourManager.play_behaviour_started], [method AIBehaviourBase.start_step]). Empty (the default): the AI thinks. For
## playing back an order stream (netcode spec 19.3), recorded through [member AIBehaviourManager.order_listener].
static var order_source := Callable()

## The pawn this AI belongs to, or null if its parent isn't one.
var pawn: Pawn = null
## The tick the AI is running now. Set by [method run_ai] at the start of each AI step.
var current_tick := 0
## What the AI is focused on, picked by the target selector. Null when there's none.
var current_target: Node3D = null:
	set(value):
		current_target = value
		refresh_shared_inputs() # the shared inputs depend on it
		facts_version += 1
## Goes up by one whenever a fact the C++ decider works inputs out from changes: the target, the last hit, the swing coming at it
## ([AIDeciderBridge] copies them again before the next decision).
var facts_version := 0

## The pawn's AI inputs, the numbers its behaviours' conditions read ([AIInputs]). Worked out at each decision; a game writes its
## own with [code]inputs.set_input(name, value)[/code].
var inputs: AIInputs = null

var _requests: Array = [] # the request inbox: [what, arguments], in the order asked
var _warned_client_request := false
var _decision_waiting := false
var _event_priority := 0 # the strongest reason for the waiting decision (pawn spec 10.7)
var _event_is_normal := true # true when every reason was an ordinary decision tick


func _init() -> void:
	# Nothing here runs per frame: the pawn calls into the AI parts on its tick.
	set_process(false)
	set_physics_process(false)
	inputs = AIInputs.new(self)
	# A component added or removed: look again next time one is asked for.
	child_entered_tree.connect(_on_components_changed)
	child_exiting_tree.connect(_on_components_changed)


# Its components read the pawn from here as they enter the tree, which is after this (a parent enters first).
func _enter_tree() -> void:
	pawn = get_parent() as Pawn
	# It tells its pawn it's here, before any part's _ready; the first AIManager a pawn has is the one it uses.
	if pawn and not is_instance_valid(pawn.ai):
		pawn.ai = self
	if pawn == null:
		push_warning("AIManager: its parent isn't a Pawn, so this AI has nothing to drive.")


# The AI notes every hit that reaches the pawn, parried ones included, by listening to the AbilityManager's hit_arrived.
func _ready() -> void:
	var abilities := pawn.ability_manager if pawn else null
	if abilities:
		abilities.hit_arrived.connect(note_hit)


# --- Its components (its children; the first of each kind) ---
# Looked for the first time one is asked for, and again after a child is added or removed, so one swapped later is still found.


## The AI's hands, or null if it has no AIController. The pawn's ControllerManager puts it in charge while no player has the pawn.
var controller: AIController:
	get:
		_find_parts_if_needed()
		return _controller

## The pawn's state manager, or null.
var state_manager: AIStateManager:
	get:
		_find_parts_if_needed()
		return _state_manager

## The pawn's behaviour manager, or null.
var behaviour_manager: AIBehaviourManager:
	get:
		_find_parts_if_needed()
		return _behaviour_manager

## The pawn's sensing manager, or null.
var sensing_manager: AISensingManager:
	get:
		_find_parts_if_needed()
		return _sensing_manager

## The pawn's memory, or null.
var memory: AIMemory:
	get:
		_find_parts_if_needed()
		return _memory

## The pawn's target selector, or null.
var target_selector: AITargetSelector:
	get:
		_find_parts_if_needed()
		return _target_selector

var _parts_found := false
var _controller: AIController = null
var _state_manager: AIStateManager = null
var _behaviour_manager: AIBehaviourManager = null
var _sensing_manager: AISensingManager = null
var _memory: AIMemory = null
var _target_selector: AITargetSelector = null


# The first of each AI component among its children.
func _find_parts_if_needed() -> void:
	if _parts_found:
		return
	_parts_found = true
	_controller = null
	_state_manager = null
	_behaviour_manager = null
	_sensing_manager = null
	_memory = null
	_target_selector = null
	for child in get_children():
		if child is AIController and _controller == null:
			_controller = child
		elif child is AIStateManager and _state_manager == null:
			_state_manager = child
		elif child is AIBehaviourManager and _behaviour_manager == null:
			_behaviour_manager = child
		elif child is AISensingManager and _sensing_manager == null:
			_sensing_manager = child
		elif child is AIMemory and _memory == null:
			_memory = child
		elif child is AITargetSelector and _target_selector == null:
			_target_selector = child


func _on_components_changed(_node: Node) -> void:
	_parts_found = false


# --- Shared inputs (pawn spec 10.8) ---
# Values many states and behaviours read. Each is worked out the first time something asks in a tick, and kept for the rest of
# that tick, so if nothing asks, it costs nothing. Memory indexes only change on a sensing pass, which comes before any reader.

# Each one separately, so asking for the cheap one never pays for the other. ai_stress measured it: Chase asks for the target
# every tick, and working out the most aware entry with it (a loop over every entry) cost more than the rest of the AI together.
var _shared_tick := -1 # the tick the values below belong to; -1: none yet
var _target_index := -1
var _target_index_known := false
var _most_aware := -1
var _most_aware_known := false


## The memory index of the current target, or -1.
func current_target_index() -> int:
	_start_shared_tick()
	if not _target_index_known:
		_target_index_known = true
		var remembered := memory
		_target_index = remembered.find(current_target) if remembered and has_target() else -1
	return _target_index


## The memory index of the entry with the highest awareness now, or -1.
func most_aware_index() -> int:
	_start_shared_tick()
	if not _most_aware_known:
		_most_aware_known = true
		var remembered := memory
		_most_aware = remembered.most_aware_index(current_tick) if remembered else -1
	return _most_aware


func _start_shared_tick() -> void:
	if _shared_tick != current_tick:
		refresh_shared_inputs()
		_shared_tick = current_tick


## Clears the shared inputs, so the next read works them out again. Setting current_target does it.
func refresh_shared_inputs() -> void:
	_shared_tick = -1
	_target_index_known = false
	_most_aware_known = false


## The name of the current state, such as &"Idle", or &"" before the first state is picked.
func current_state_name() -> StringName:
	var states := state_manager
	var state := states.get_current_state() if states else null
	return state.name if state else &""


## The tick of the last hit this pawn took, noted from the AbilityManager's hit_arrived on the server; -1: never hit. Not a memory
## entry: there's no damage sense.
var last_hit_tick := -1
## Who made the last hit.
var last_attacker: Node3D = null
## Where the attacker stood when it hit.
var last_hit_from := Vector3.ZERO


## Called for the AbilityManager's hit_arrived. Notes the hit and asks for a decision at once, so the pawn reacts this tick.
func note_hit(hit: HitInfo) -> void:
	last_hit_tick = hit.tick
	last_attacker = hit.attacker
	last_hit_from = hit.attacker.global_position if is_instance_valid(hit.attacker) else last_hit_from
	_facts_changed()
	request_decision()


## Who swung the latest swing coming at this pawn ([method note_incoming_attack]), for AIParryBehaviour, or null.
var incoming_attacker: Pawn = null
## The tick that swing started.
var incoming_start_tick := -1
## The tick that swing's hit starts; -1 when nothing is coming.
var incoming_hit_tick := -1


## Called by an enemy's MeleeAttackAbility or FireProjectileStep, on the server, when it starts an attack that may reach this pawn. Notes it and asks for a
## decision at once, since a swing's windup is shorter than the time between ordinary decisions.
func note_incoming_attack(attacker: Pawn, start_tick: int, hit_tick: int) -> void:
	incoming_attacker = attacker
	incoming_start_tick = start_tick
	incoming_hit_tick = hit_tick
	_facts_changed()
	request_decision()


## True while a noted swing hasn't hit yet and its attacker is still there and alive.
func has_incoming_attack() -> bool:
	return incoming_hit_tick >= current_tick and is_instance_valid(incoming_attacker) and not incoming_attacker.is_dead()


## Forgets the noted swing, once it's been answered.
func clear_incoming_attack() -> void:
	incoming_attacker = null
	incoming_start_tick = -1
	incoming_hit_tick = -1
	_facts_changed()


## True if the pawn was hit within this many ticks, counted at 60 a second like every AI setting (converted to the match's rate).
func was_hit_within(ticks: int) -> bool:
	return last_hit_tick >= 0 and current_tick - last_hit_tick <= TickDriver.ticks_at_rate(ticks)


## True if the last attacker is in memory.
func last_attacker_is_known() -> bool:
	var remembered := memory
	return remembered != null and is_instance_valid(last_attacker) and remembered.find(last_attacker) >= 0


## Where an unknown attacker hit from, if that was within this many ticks; null otherwise. Look Toward and
## Investigate head there when nothing else is half-noticed.
func unknown_hit_point(within_ticks: int) -> Variant:
	if was_hit_within(within_ticks) and not last_attacker_is_known():
		return last_hit_from
	return null


## Something half-noticed to look at or go and see: the most aware memory entry's last known position while it isn't certain yet,
## or else where an unremembered attacker hit from, within this many ticks (at 60 a second); null when neither. Their conditions
## check the same facts through [method AIInputs.half_noticed_conditions], which the C++ decider can read.
func point_of_interest(within_ticks: int) -> Variant:
	var index := most_aware_index()
	if index >= 0 and not memory.is_certain_at(index):
		return memory.last_known_position_at(index)
	return unknown_hit_point(within_ticks)


# The C++ decider works the pawn's inputs out from these facts, so it copies them again when this goes up (scaling spec 6.2).
func _facts_changed() -> void:
	facts_version += 1


## True when there's a current target, picked by the target selector.
func has_target() -> bool:
	return is_instance_valid(current_target)


# --- Running the AI ---


## The AI's step, called by the pawn in its input phase. Runs only where the AI runs (offline or the server), never while a rollback
## replays ticks. The pawn's orders for the tick come from [member order_source] if one is set, else from [method think].
func run_ai(tick: int) -> void:
	if pawn == null or not pawn.runs_ai_here():
		return
	if TickDriver.is_resimulating():
		return # the AI is never rolled back, so a replay must not run it again
	current_tick = tick
	# REFACTOR: a prototype hook, one static source for every AI pawn, made for the order replay test; the order stream (netcode spec
	# 19.3) settles its real shape (per world, which pawns it plays).
	if order_source.is_valid():
		order_source.call(self, tick)
		return
	think(tick)


## The AI thinking, in a fixed order (pawn spec 4, 10.9 and 16.5): the request inbox, sensing, a decision when one is due, the running
## behaviour. While a player has the pawn, only as far as [member while_possessed] allows. [method run_ai] calls it; an
## [member order_source] may too.
func think(tick: int) -> void:
	var has_player := pawn.controller_manager != null and pawn.controller_manager.has_player()
	var ai_state_manager := state_manager
	var ai_target_selector := target_selector
	var ai_behaviour_manager := behaviour_manager
	var ai_sensing_manager := sensing_manager
	# Requests from outside the AI since its last step, in the order asked. Before anything else, and even while possessed.
	apply_requests()
	if has_player and while_possessed == WhilePossessed.OFF:
		return
	# Sensing writes into memory. MEMORY_ONLY stops after it.
	if ai_sensing_manager:
		var sensing_started := PerfScopes.begin() # timed for diagnostics (PerfScopes)
		ai_sensing_manager.tick_sensing(tick)
		PerfScopes.end(&"ai.sensing", sensing_started)
	if has_player and while_possessed == WhilePossessed.MEMORY_ONLY:
		return
	if is_decision_tick(tick):
		request_decision()
	# A running behaviour whose tag requirements stopped passing (out of shots, say) is replaced now, not at the next decision tick.
	if ai_behaviour_manager:
		ai_behaviour_manager.check_running(tick)
	var decide_started := PerfScopes.begin()
	if has_decision_waiting():
		# A record of this decision, only while something listens (AIBehaviourManager.decision_listener): what the target and the
		# state were before and after their updates. The behaviour manager fills in the rest.
		var record: AIDecisionRecord = null
		if AIBehaviourManager.decision_listener.is_valid():
			record = AIDecisionRecord.new()
			record.cause = AIDecisionRecord.CAUSE_AI_STEP
			record.note_target_before(current_target)
			record.state_before = current_state_name()
		var part_started := PerfScopes.begin() # each part timed on its own too (PerfScopes)
		if ai_target_selector:
			ai_target_selector.update_target(tick) # first, because states such as Combat look at the current target
		PerfScopes.end(&"ai.decide.target", part_started)
		part_started = PerfScopes.begin()
		if ai_state_manager:
			ai_state_manager.update_state(tick) # a change asks for a decision with the new state's priority
		PerfScopes.end(&"ai.decide.state", part_started)
		if record:
			record.note_target_after(current_target)
			record.state_after = current_state_name()
		part_started = PerfScopes.begin()
		if ai_behaviour_manager:
			ai_behaviour_manager.decide(tick, record)
		else:
			clear_decision()
		PerfScopes.end(&"ai.decide.behaviour", part_started)
	PerfScopes.end(&"ai.decide", decide_started)
	if ai_behaviour_manager:
		var behaviours_started := PerfScopes.begin()
		ai_behaviour_manager.tick_running(tick)
		PerfScopes.end(&"ai.behaviours", behaviours_started)


# --- The request inbox ---


## Asks for a behaviour modifier to be added under this source ([method AIBehaviourManager.add_modifier]), at the pawn's next AI step.
func add_modifier(modifier: AIBehaviourModifier, source: Variant) -> void:
	_request(&"add_modifier", [modifier, _source_key(source)])


## Asks for every behaviour modifier this source added to be taken away, at the pawn's next AI step.
func remove_modifiers(source: Variant) -> void:
	_request(&"remove_modifiers", [_source_key(source)])


## Asks for one of the AI's own inputs (a game's, such as &"morale") to be set, at the pawn's next AI step ([method AIInputs.set_input]).
func set_input(input_name: StringName, value: float) -> void:
	_request(&"set_input", [input_name, value])


## Applies the requests waiting in the inbox, in the order asked. [method think] calls it first; a test can call it directly.
func apply_requests() -> void:
	if _requests.is_empty():
		return
	var waiting := _requests
	_requests = []
	var behaviours := behaviour_manager
	for request: Array in waiting:
		var args: Array = request[1]
		match request[0]:
			&"add_modifier":
				if behaviours:
					behaviours.add_modifier(args[0], args[1])
			&"remove_modifiers":
				if behaviours:
					behaviours.remove_modifiers(args[0])
			&"set_input":
				if inputs:
					inputs.set_input(args[0], args[1])


## How many requests are waiting for the pawn's next AI step.
func waiting_requests() -> int:
	return _requests.size()


func _request(what: StringName, args: Array) -> void:
	if pawn and not pawn.runs_ai_here():
		if not _warned_client_request:
			_warned_client_request = true
			push_warning("AIManager: %s (on %s) is ignored here: the AI runs only on the server." % [what, pawn.name])
		return
	_requests.append([what, args])


# A source as a key, taken when asked: an object by its instance id, so one freed before the request applies still matches.
static func _source_key(source: Variant) -> Variant:
	return source.get_instance_id() if source is Object else source


# --- Decisions ---


## True on this pawn's regular decision ticks, every [member decision_interval_ticks], offset by its own number.
func is_decision_tick(tick: int) -> bool:
	# Or one it skipped since its last run, for a pawn running every Nth tick (pawn spec 8.21).
	return pawn.fired_since_last_run(tick, pawn.entity_number(), TickDriver.ticks_at_rate(decision_interval_ticks))


## Asks for a decision this tick. priority is how strong the reason is: 0 for an ordinary decision, a state's priority for a state
## change. normal is true only for an ordinary decision, the one kind a behaviour's min_run_ticks holds off. Several requests in one
## tick combine into one decision with the strongest reason.
func request_decision(priority: int = 0, normal: bool = true) -> void:
	if _decision_waiting:
		_event_priority = maxi(_event_priority, priority)
		_event_is_normal = _event_is_normal and normal
	else:
		_decision_waiting = true
		_event_priority = priority
		_event_is_normal = normal


## True when a decision is waiting to happen.
func has_decision_waiting() -> bool:
	return _decision_waiting


## The strongest reason for the waiting decision. Only meaningful while one is waiting.
func waiting_event_priority() -> int:
	return _event_priority


## True when the waiting decision is only an ordinary one.
func waiting_event_is_normal() -> bool:
	return _event_is_normal


## The behaviour manager calls this once it has made the decision.
func clear_decision() -> void:
	_decision_waiting = false
	_event_priority = 0
	_event_is_normal = true


# --- Random numbers that replay the same ---


## A number from 0 up to (not including) 1 for this tick. salt says what it's for (a behaviour uses its name's hash). The same
## seed, pawn, tick and salt give the same number on every machine and run.
func random_unit(salt: int) -> float:
	return random_unit_at(current_tick, salt)


## random_unit() for a given tick.
func random_unit_at(tick: int, salt: int) -> float:
	return DeterministicRandom.unit_seeded(effective_seed(), pawn.entity_number() if pawn else 0, tick, salt)


## A number from -1 to 1. See random_unit().
func random_signed(salt: int) -> float:
	return random_unit(salt) * 2.0 - 1.0


## The seed this AI's rolls use: [member random_seed] plus the match's ([member DeterministicRandom.match_seed]). The C++ decider is
## given the same when the pawn joins it.
func effective_seed() -> int:
	return random_seed + DeterministicRandom.match_seed
