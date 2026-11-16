## Written by Claude (claude-opus-5-5), 2026-11-16 (pawn spec 8.20, the owner's design): one step of an ability, such as a windup, a
## turn or a swing. A child of the ability. An ability with step children runs them; one without works as abilities always have.
##
## How steps run (Unreal's ability-task model):
##   - Steps marked starts_first start when the ability starts. With none marked, the ability's first step does.
##   - When a step is done, the steps in its starts_when_finished start. A step's own code can also start or stop other steps,
##     through ability.start_step() and ability.stop_step(), as a windup starts a turn when the pawn isn't facing its target.
##   - Several steps can run at once, which is how things happen side by side (a turn during a windup).
##   - The ability ends when no step that keeps it running is left (keeps_ability_running, on by default; off for a step that only goes
##     along with the others, such as a turn that follows the crosshair through a swing). A step that fails ends the ability, and its
##     other running steps get exit("failed").
##   - A step started during a tick enters at once and gets its first tick on the next one, so one step finishing hands over to the
##     next with no gap, and the result never depends on where steps sit in the tree.
##
## How to make one: extend this and override any of:
##   enter()              once, when it starts
##   tick(dt) -> Status   every tick it runs: RUNNING, DONE or FAILED
##   exit(reason)         once, when it stops: "done", "released" (its action let go, with ends_when_released), "failed" or
##                        "cancelled" (stopped by its ability ending, an interrupt, or another step)
##   counts_this_tick()   whether this tick counts toward length_ticks (always, by default). A windup waiting for a turn says no.
##   setup()              once, when its ability finds it, for working out settings (an input bit, say). Not for state.
##   can_end_on_release() with ends_when_released, whether letting go may end it now (TurnToFace says no until its minimum turn)
##
## Claude 2026-11-16, holding (the owner's call: important to track, so it's the base's, not one step's): with ends_when_released on,
## the step ends on the first tick its action isn't held, with the reason "released", and its next steps start as if it were done.
## Which action: while_held, or its ability's trigger_action. Held input is rolled-back input (ControllerManager.held_actions, bits
## from InputActions), so the server, a client's prediction and a replay agree on when it was let go. is_held() asks at any time.
##   weapon_point(facing) where the weapon is during this step, from the pawn's feet, for visuals (null: this step doesn't say).
##
## Rollback: running and step_ticks roll back. Claude 2026-11-16 (measured in the mass battle): they're kept in their ability's
## step_state, one small array per ability, which is what's recorded, since two recorded values per step added 2.4 ms a tick at 150
## pawns. A step keeps nothing else between ticks unless it adds it to get_rollback_properties(), as abilities do, because a rollback
## restores these values without calling enter() or exit() again.
##
## GDScript note: this extends Node, not Node3D: a step has no place in the world, only a part in its ability.
class_name AbilityStep
extends Node

enum Status {
	RUNNING, ## still going
	DONE, ## finished: the steps in starts_when_finished start
	FAILED, ## couldn't do its job: the whole ability ends
}

## On: it starts when its ability starts. With no step marked, the ability's first step starts.
@export var starts_first := false
## The steps that start when this one is done (not when it fails or is cancelled). Other steps of the same ability.
@export var starts_when_finished: Array[NodePath] = []
## How long it runs, in ticks at 60 a second (converted for the match's tick rate). 0: until tick() says DONE.
@export_range(0, 600, 1, "or_greater") var length_ticks := 0
## While it runs, how strong a starting ability (or a hit's knockback) must be to cancel its ability. -1: the ability's own
## interrupt_threshold. With several steps running, the strictest counts.
@export var interrupt_threshold := -1
## On: hits don't land on the pawn while it runs (invulnerability frames).
@export var invulnerable := false
## Claude 2026-11-16: on: it ends as soon as its action is let go (reason "released"). See the top of the file.
@export var ends_when_released := false
## Claude 2026-11-16: the action that must stay held. Empty: its ability's trigger_action. With neither, it's never released.
@export var while_held: StringName = &""
## On (the default): its ability keeps running while this step does. Off for a step that only goes along with the others: once only
## such steps are left, the ability ends and they stop with "done".
@export var keeps_ability_running := true

# State that rolls back, kept in the ability's step_state. See the top of the file.
# GDScript note: get and set make these work like plain variables while the values live in the ability's array: step_state[index] is
# 0 while the step isn't running, and its step_ticks + 1 while it is.
## True while it runs.
var running: bool:
	get:
		return index >= 0 and ability != null and ability.step_state[index] > 0
	set(value):
		if index >= 0 and ability != null:
			ability.step_state[index] = 1 if value else 0
## Ticks counted since it started (those counts_this_tick() allowed). In tick(), the ticks before this one. 0 when it isn't running.
var step_ticks: int:
	get:
		return ability.step_state[index] - 1 if running else 0
	set(value):
		if running:
			ability.step_state[index] = maxi(value, 0) + 1
## Claude 2026-11-16: its place in its ability's steps (and step_state), set when its ability finds it; -1 before.
var index := -1

## Set by its ability.
var ability: AbilityBase = null
var pawn: Pawn = null
## starts_when_finished, as steps, found once by its ability.
var next_steps: Array[AbilityStep] = []
## Claude 2026-11-16: while_held's input bit (or its ability's trigger_action's), worked out once by setup_hold(). 0: no action to hold.
var hold_bit := 0


func _init() -> void:
	# GDScript note: steps do nothing on their own; the ability runs them on the pawn's tick.
	set_process(false)
	set_physics_process(false)


## The properties on this node that roll back: none of its own by default (running and step_ticks are its ability's step_state). A step
## that keeps more lists them here.
func get_rollback_properties() -> Array[String]:
	return []


## How long it runs, in this match's ticks; 0 if it runs until it says it's done.
func length() -> int:
	return TickDriver.ticks_at_rate(length_ticks) if length_ticks > 0 else 0


# --- Override these ---


func enter() -> void:
	pass


func tick(_dt: float) -> Status:
	return Status.RUNNING


func exit(_reason: String) -> void:
	pass


func counts_this_tick() -> bool:
	return true


func setup() -> void:
	pass


## Claude 2026-11-16: with ends_when_released, whether letting go may end it now. Yes by default.
func can_end_on_release() -> bool:
	return true


## Claude 2026-11-16: true while its action is held this tick (always false with no action to hold).
func is_held() -> bool:
	return hold_bit != 0 and ability.held_actions() & hold_bit != 0


## Claude 2026-11-16: its ability calls this once, before setup(): which input bit to watch.
func setup_hold() -> void:
	var action := while_held if while_held != &"" else ability.trigger_action
	hold_bit = InputActions.mask_of(action) if action != &"" else 0


## Where the weapon is during this step, as an offset from the pawn's feet for this facing (radians), or null if this step doesn't say.
## The ability answers with its running steps' (AbilityBase.weapon_point), and the visuals draw that, so a new pattern needs no visual work.
func weapon_point(_facing: float) -> Variant:
	return null


## How far through its length it is, 0 to 1, with how far the tick driver is toward the next tick, for smooth visuals. 0 with no length.
func progress() -> float:
	var total := length()
	if total <= 0:
		return 0.0
	var frac: float = TickDriver.get_interpolation_fraction() if counts_this_tick() else 0.0
	return clampf((float(step_ticks) + frac) / float(total), 0.0, 1.0)
