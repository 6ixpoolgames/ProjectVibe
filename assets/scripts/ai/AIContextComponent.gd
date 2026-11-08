## Written by Claude (claude-opus-5-5), 2026-11-09: shared data and settings for one pawn's AI. A part on the pawn, added by
## PawnInitializer. Pawn spec section 10.
##
## It makes no decisions. It holds what the other AI parts share, so they don't each look it up again:
##   - references: the pawn, its AI controller (the hands), its state and behaviour managers
##   - settings for the whole AI: while_possessed, decision_interval_ticks, random_seed
##   - the decision waiting to happen this tick, if any, and how strong its reason is (the "event", pawn spec 10.7)
##   - random numbers that depend only on (seed, pawn, tick, what they're for), so a replay makes the same choices
##   - Claude 2026-11-09, step 8b: the current target, and shared inputs behaviours read (current_target_index, most_aware_index)
##
## The pawn runs its AI from its own tick, in a fixed order (Pawn._tick_ai). Nothing here ticks on its own.
##
## How to use it (behaviours and states get it as their "context"):
##   context.pawn, context.controller, context.state_manager, context.behaviour_manager
##   context.current_tick                     # the tick the AI is running now
##   context.current_state_name()             # &"Idle", or &"" before the first state is picked
##   context.has_target()                     # false until step 8b adds target selection
##   context.random_unit(salt)                # a number from 0 up to 1, the same on every run for this pawn and tick
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
## What the AI is focused on, picked by the target selector (Claude 2026-11-09). Null when there's none.
var current_target: Node3D = null:
	set(value):
		current_target = value
		refresh_shared_inputs() # the shared inputs depend on it

var _decision_waiting := false
var _event_priority := 0 # the strongest reason for the waiting decision (pawn spec 10.7)
var _event_is_normal := true # true when every reason was an ordinary decision tick


func _init() -> void:
	# GDScript note: nothing here runs per frame. The pawn calls into the AI parts on its tick.
	set_process(false)
	set_physics_process(false)


func _enter_tree() -> void:
	pawn = get_parent() as Pawn # GDScript note: "as" gives null when the parent isn't a Pawn, rather than an error
	if pawn == null:
		push_warning("AIContextComponent: its parent isn't a Pawn, so this AI has nothing to drive.")


# --- References (read when needed, because the pawn finds its parts in its own _ready, after ours) ---


## The AI's hands, or null if the pawn has no AI controller.
var controller: AIController:
	get:
		if pawn and pawn.controller_manager:
			return pawn.controller_manager.ai_controller as AIController
		return null

## The pawn's state manager, or null.
var state_manager: AIStateManager:
	get:
		return pawn.ai_state_manager if pawn else null

## The pawn's behaviour manager, or null.
var behaviour_manager: AIBehaviourManager:
	get:
		return pawn.ai_behaviour_manager if pawn else null

## Claude 2026-11-09: the pawn's memory, or null.
var memory: AIMemory:
	get:
		return pawn.ai_memory if pawn else null

## Claude 2026-11-09: the pawn's target selector, or null.
var target_selector: AITargetSelector:
	get:
		return pawn.ai_target_selector if pawn else null


# --- Shared inputs (Claude 2026-11-09, pawn spec 10.8) ---
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


## Claude 2026-11-09, step 10: the last hit this pawn took, noted by Pawn.receive_hit on the server. State rules (AIAwarenessState)
## and behaviours read it; the hit isn't turned into a memory entry, because there's no damage sense (the owner's call).
var last_hit_tick := -1 # -1: never hit
var last_attacker: Node3D = null
var last_hit_from := Vector3.ZERO # where the attacker stood when it hit


## Claude 2026-11-09: called by Pawn.receive_hit. Notes the hit and asks for a decision at once, so the pawn reacts this tick.
func note_hit(hit: HitInfo) -> void:
	last_hit_tick = hit.tick
	last_attacker = hit.attacker
	last_hit_from = hit.attacker.global_position if is_instance_valid(hit.attacker) else last_hit_from
	request_decision()


## Claude 2026-11-09: true if the pawn was hit within this many ticks.
func was_hit_within(ticks: int) -> bool:
	return last_hit_tick >= 0 and current_tick - last_hit_tick <= ticks


## Claude 2026-11-09: true if the last attacker is in memory.
func last_attacker_is_known() -> bool:
	var remembered := memory
	return remembered != null and is_instance_valid(last_attacker) and remembered.find(last_attacker) >= 0


## Claude 2026-11-09: where an unknown attacker hit from, if that was within this many ticks; null otherwise. Look Toward and
## Investigate head there when nothing else is half-noticed.
func unknown_hit_point(within_ticks: int) -> Variant:
	if was_hit_within(within_ticks) and not last_attacker_is_known():
		return last_hit_from
	return null


## True when there's a current target. Claude 2026-11-09: set by the target selector from step 8b.
func has_target() -> bool:
	return is_instance_valid(current_target)


# --- Decisions ---


## True on this pawn's regular decision ticks, every decision_interval_ticks, offset by its own number.
func is_decision_tick(tick: int) -> bool:
	return posmod(tick + pawn_number(), decision_interval_ticks) == 0


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


## This pawn's own number, for spreading decisions and for random numbers: its network id when it has one, which is the same on
## every machine, or else a hash of its name.
func pawn_number() -> int:
	if pawn == null:
		return 0
	var entity := pawn.get_network_entity()
	if entity and entity.entity_id >= 0:
		return entity.entity_id
	return String(pawn.name).hash() & 0x7FFFFFFF
