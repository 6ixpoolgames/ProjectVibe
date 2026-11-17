# Written by Claude (claude-opus-5-5), 2026-11-09. History: ai/CHANGELOG.md.
## Shared data and settings for one pawn's AI, and the step that runs the AI parts in order.
##
## A part on the pawn, added by PawnInitializer. Pawn spec section 10. It makes no decisions. It holds what the other AI parts share,
## so they don't each look it up again:
## [br]- references: the pawn, its AI controller (the hands), and the other AI parts ([member state_manager],
##   [member behaviour_manager], [member sensing_manager], [member memory], [member target_selector])
## [br]- settings for the whole AI: [member while_possessed], [member decision_interval_ticks], [member random_seed]
## [br]- the decision waiting to happen this tick, if any, and how strong its reason is (the "event", pawn spec 10.7)
## [br]- random numbers that depend only on (seed, pawn, tick, what they're for), so a replay makes the same choices
## [br]- the current target, and shared inputs behaviours read ([method current_target_index], [method most_aware_index])
## [br]- the pawn's AI inputs ([member inputs]): the named numbers behaviours' conditions read (scaling spec 6.2)
## [br]- the last hit the pawn took and the latest swing coming at it, for states and behaviours
## [br]
## The pawn calls [method run_ai] from its own tick, which runs the AI parts in a fixed order. Nothing here ticks on its own.
## [br]
## How to use it (behaviours and states get it as their "context"):
## [codeblock]
## context.pawn, context.controller, context.memory, context.state_manager, context.behaviour_manager
## context.current_tick            # the tick the AI is running now
## context.current_state_name()    # &"Idle", or &"" before the first state is picked
## context.has_target()            # true while the target selector has picked a target
## context.random_unit(salt)       # a number from 0 up to 1, the same on every run for this pawn and tick
## [/codeblock]
class_name AIContextComponent
extends Node

## What the AI does while a player has the pawn (pawn spec 10.3).
enum WhilePossessed {
	OFF, ## nothing runs
	MEMORY_ONLY, ## sensing and memory run; states and behaviours pause. The default
	FULL, ## everything runs. The AI controller keeps its last order without acting on it until it's in charge again
}

## What the AI does while a player has the pawn. Which is right depends on the game: MEMORY_ONLY suits possessing an NPC and
## letting go, where the AI should already know what's around.
@export var while_possessed := WhilePossessed.MEMORY_ONLY
## How often the AI decides, in ticks: 15 is four times a second at 60 ticks a second. Each pawn is offset by its own number, so a
## crowd doesn't all decide on the same tick. Some events wake a decision early (pawn spec 10.9).
@export_range(1, 600, 1, "or_greater") var decision_interval_ticks := 15
## Part of every random number this AI uses. Two pawns with the same seed still differ, because their own number goes in too.
## A game can set it from its world seed, so a replay of the same world makes the same choices.
@export var random_seed := 0

## The pawn this AI belongs to, or null if its parent isn't one.
var pawn: Pawn = null
## The tick the AI is running now. Set by the pawn at the start of each AI step.
var current_tick := 0
## What the AI is focused on, picked by the target selector. Null when there's none.
var current_target: Node3D = null:
	set(value):
		current_target = value
		refresh_shared_inputs() # the shared inputs depend on it

## The pawn's AI inputs, the numbers its behaviours' conditions read ([AIInputs]). Worked out at each decision; a game writes its
## own with [code]inputs.set_input(name, value)[/code].
var inputs: AIInputs = null

var _decision_waiting := false
var _event_priority := 0 # the strongest reason for the waiting decision (pawn spec 10.7)
var _event_is_normal := true # true when every reason was an ordinary decision tick


func _init() -> void:
	# GDScript note: nothing here runs per frame. The pawn calls into the AI parts on its tick.
	set_process(false)
	set_physics_process(false)
	inputs = AIInputs.new(self)


func _enter_tree() -> void:
	pawn = get_parent() as Pawn # GDScript note: "as" gives null when the parent isn't a Pawn, rather than an error
	if pawn == null:
		push_warning("AIContextComponent: its parent isn't a Pawn, so this AI has nothing to drive.")
		return
	_parts_found = false # see _find_parts_if_needed
	if not pawn.child_entered_tree.is_connected(_on_pawn_parts_changed):
		pawn.child_entered_tree.connect(_on_pawn_parts_changed)
		pawn.child_exiting_tree.connect(_on_pawn_parts_changed)


# Stops listening to the pawn it leaves.
func _exit_tree() -> void:
	if pawn and pawn.child_entered_tree.is_connected(_on_pawn_parts_changed):
		pawn.child_entered_tree.disconnect(_on_pawn_parts_changed)
		pawn.child_exiting_tree.disconnect(_on_pawn_parts_changed)


# The AI notes every hit that reaches the pawn, parried ones included, by listening to the AbilityManager's hit_arrived.
func _ready() -> void:
	var abilities := _sibling_ability_manager()
	if abilities:
		abilities.hit_arrived.connect(note_hit)


# --- References (read when needed, because the pawn finds its parts in its own _ready, after ours) ---


## The AI's hands, or null if the pawn has no AI controller.
var controller: AIController:
	get:
		if pawn and pawn.controller_manager:
			return pawn.controller_manager.ai_controller as AIController
		return null

# The context finds the pawn's other AI parts itself (pawn.ai_context.memory, say), so the pawn holds only ai_context. They're
# looked for the first time one is asked for, and again after a part is added to or removed from the pawn.
# GDScript note: "get:" under a variable runs whenever it's read, so pawn.ai_context.memory works like a plain variable.

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
var _state_manager: AIStateManager = null
var _behaviour_manager: AIBehaviourManager = null
var _sensing_manager: AISensingManager = null
var _memory: AIMemory = null
var _target_selector: AITargetSelector = null


# The first of each AI part among the pawn's children.
func _find_parts_if_needed() -> void:
	if _parts_found or pawn == null:
		return
	_parts_found = true
	_state_manager = null
	_behaviour_manager = null
	_sensing_manager = null
	_memory = null
	_target_selector = null
	for child in pawn.get_children():
		if child is AIStateManager and _state_manager == null:
			_state_manager = child
		elif child is AIBehaviourManager and _behaviour_manager == null:
			_behaviour_manager = child
		elif child is AISensingManager and _sensing_manager == null:
			_sensing_manager = child
		elif child is AIMemory and _memory == null:
			_memory = child
		elif child is AITargetSelector and _target_selector == null:
			_target_selector = child


# A part added or removed: look again next time one is asked for.
func _on_pawn_parts_changed(_node: Node) -> void:
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


## The tick of the last hit this pawn took, noted from the AbilityManager's hit_arrived on the server; -1: never hit. State rules
## (AIAwarenessState) and behaviours read it; the hit isn't turned into a memory entry, because there's no damage sense (the owner's
## call).
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
	request_decision()


## Who swung the latest swing coming at this pawn ([method note_incoming_attack]), for AIParryBehaviour, or null.
var incoming_attacker: Pawn = null
## The tick that swing started.
var incoming_start_tick := -1
## The tick that swing's hit starts; -1 when nothing is coming.
var incoming_hit_tick := -1


## Called by an enemy's MeleeAttackAbility, on the server, when it starts a swing that may reach this pawn. Notes it and asks for a
## decision at once, since a swing's windup is shorter than the time between ordinary decisions.
func note_incoming_attack(attacker: Pawn, start_tick: int, hit_tick: int) -> void:
	incoming_attacker = attacker
	incoming_start_tick = start_tick
	incoming_hit_tick = hit_tick
	request_decision()


## True while a noted swing hasn't hit yet and its attacker is still there and alive.
func has_incoming_attack() -> bool:
	return incoming_hit_tick >= current_tick and is_instance_valid(incoming_attacker) and not incoming_attacker.is_dead()


## Forgets the noted swing, once it's been answered.
func clear_incoming_attack() -> void:
	incoming_attacker = null
	incoming_start_tick = -1
	incoming_hit_tick = -1


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


## Something half-noticed to look at or go and see: the most aware memory entry's last known position while that entry isn't
## certain yet, or else where an attacker the AI doesn't remember hit from, if that was within this many ticks (at 60 a second);
## null when there's neither. Look Toward and Investigate head there. Their conditions check the same two facts through the inputs
## ([method AIInputs.half_noticed_conditions]), which the C++ decider can read.
func point_of_interest(within_ticks: int) -> Variant:
	var index := most_aware_index()
	if index >= 0 and not memory.is_certain_at(index):
		return memory.last_known_position_at(index)
	return unknown_hit_point(within_ticks)


## True when there's a current target, picked by the target selector.
func has_target() -> bool:
	return is_instance_valid(current_target)


# --- Running the AI ---


## The AI's step, in a fixed order (pawn spec sections 4 and 10.9). The pawn calls it in its input phase; the AI's core part runs
## the AI, and the pawn only calls this. Runs only where the AI runs (offline or the server), never while a rollback replays ticks,
## and, while a player has the pawn, only as far as [member while_possessed] allows. Order:
## [br]1. Forces and taunts asked for during the last tick are applied, in the order they were asked for, even while possessed.
## [br]2. Sensing, which writes into memory. MEMORY_ONLY stops after this.
## [br]3. On a decision tick, or when something asked for a decision: the target is picked, the state is checked, then the
##   behaviour manager decides.
## [br]4. The running behaviour ticks, which calls the AI controller.
func run_ai(tick: int) -> void:
	if pawn == null or not pawn.runs_ai_here():
		return
	if TickDriver.is_resimulating():
		return # the AI is never rolled back, so a replay must not run it again
	current_tick = tick
	var has_player := pawn.controller_manager != null and pawn.controller_manager.has_player()
	var ai_state_manager := state_manager
	var ai_target_selector := target_selector
	var ai_behaviour_manager := behaviour_manager
	var ai_sensing_manager := sensing_manager
	# Forces asked for during the last tick (a taunt from another pawn, say), in the order they were asked for (scaling spec step 3).
	# Before anything else, and even while possessed, as a force between ticks would have been.
	if ai_state_manager:
		ai_state_manager.apply_queued(tick)
	if ai_target_selector:
		ai_target_selector.apply_queued(tick)
	if has_player and while_possessed == WhilePossessed.OFF:
		return
	# Sensing writes into memory. MEMORY_ONLY stops after it.
	if ai_sensing_manager:
		var sensing_started := PerfScopes.begin() # timed for diagnostics (PerfScopes)
		ai_sensing_manager.tick_sensing(tick)
		PerfScopes.end(&"ai.sensing", sensing_started)
	if has_player and while_possessed == WhilePossessed.MEMORY_ONLY:
		return
	if ai_state_manager:
		ai_state_manager.check_force_expiry(tick)
	if ai_target_selector:
		ai_target_selector.check_force_expiry(tick)
	if is_decision_tick(tick):
		request_decision()
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


# --- Decisions ---


## True on this pawn's regular decision ticks, every [member decision_interval_ticks], offset by its own number.
func is_decision_tick(tick: int) -> bool:
	# Or one it skipped since its last run, for a pawn running every Nth tick (pawn spec 8.21).
	return pawn.fired_since_last_run(tick, pawn_number(), TickDriver.ticks_at_rate(decision_interval_ticks))


## Asks for a decision this tick. priority is how strong the reason is: 0 for an ordinary decision, a state's priority for a state
## change, a force's priority for a forced state. normal is true only for an ordinary decision, the one kind a behaviour's
## min_run_ticks holds off. Several requests in one tick combine into one decision with the strongest reason.
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


## A number from 0 up to (not including) 1 for this tick. salt says what it's for, so two uses on one tick differ: a behaviour
## uses its name's hash. The same seed, pawn, tick and salt always give the same number, on every machine and every run.
func random_unit(salt: int) -> float:
	return random_unit_at(current_tick, salt)


## random_unit() for a given tick.
func random_unit_at(tick: int, salt: int) -> float:
	# GDScript note: ints are 64-bit. Each step keeps the value to 32 bits, so the multiplications never overflow, and the result
	# is the same everywhere. This is a small integer hash, not a random generator: nothing is stored between calls, so skipping a
	# call never changes the next one.
	var h := (random_seed * 83492791) ^ (pawn_number() * 19349663) ^ (tick * 73856093) ^ salt
	h &= 0xFFFFFFFF
	h = ((h ^ (h >> 16)) * 0x45D9F3B) & 0xFFFFFFFF
	h = ((h ^ (h >> 16)) * 0x45D9F3B) & 0xFFFFFFFF
	h = h ^ (h >> 16)
	return float(h & 0xFFFFFF) / 16777216.0 # 24 bits, so every value fits exactly in a float


## A number from -1 to 1. See random_unit().
func random_signed(salt: int) -> float:
	return random_unit(salt) * 2.0 - 1.0


var _number_name: StringName = &"" # the name _name_number was worked out from
var _name_number := 0

## This pawn's own number, for spreading decisions and for random numbers: its network id when it has one, which is the same on
## every machine, or else a hash of its name.
func pawn_number() -> int:
	if pawn == null:
		return 0
	var entity := pawn.get_network_entity()
	if entity and entity.entity_id >= 0:
		return entity.entity_id
	# The hash is kept until the name changes, since it's asked for at least twice a tick for every pawn.
	# GDScript note: comparing two StringNames is one pointer comparison, far cheaper than hashing the text.
	if pawn.name != _number_name:
		_number_name = pawn.name
		_name_number = String(pawn.name).hash() & 0x7FFFFFFF
	return _name_number


## Any pawn's number, as [method pawn_number] gives it, for a pawn that may have no AI of its own (a player's, say): its network id
## when it has one, or else a hash of its name. 0 for null.
static func number_of(other: Pawn) -> int:
	if other == null:
		return 0
	var entity := other.get_network_entity()
	if entity and entity.entity_id >= 0:
		return entity.entity_id
	return String(other.name).hash() & 0x7FFFFFFF

# The pawn's AbilityManager, a sibling, found at _ready (every part is in the pawn by then), or null.
# REFACTOR: the same lookup is in AIBehaviourManager. One shared way to find a sibling part before the pawn's own _ready (on Pawn,
# say) would be one place to change (reusable).
func _sibling_ability_manager() -> AbilityManager:
	if pawn == null:
		return null
	for child in pawn.get_children():
		if child is AbilityManager:
			return child
	return null
