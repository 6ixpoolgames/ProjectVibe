## Claude (claude-opus-5-5), 2026-11-03: rewritten as the working base class for behaviour nodes.
## Kept from the original: behaviourID, stateName, the pawn/aiCore references and registering with the manager.
##
## A behaviour is "something the pawn can decide to do". Put it as a child of AIBehaviourManagerComponent.
## Every 0.2 s or so the manager asks each behaviour for a score and runs the highest. See the manager's header
## for the full selection rules and corner cases.
##
## Defaults: a behaviour with no code still works. It scores base_score and runs until it finishes
## (tick() returns SUCCEEDED/FAILED) or becomes ineligible; a better score doesn't interrupt it (NEVER_UNTIL_DONE).
## Claude 2026-11-04: the default tick() returns RUNNING forever, so a behaviour that never finishes
## must set interrupt_policy = ALWAYS (like IdleBehaviour does), or it holds the pawn until it becomes unavailable.
## Override only what you need:
##   is_available(context) -> bool      hard yes/no ("do I have a target?"). Default: true
##   score(context) -> float            how much I want to run right now. Default: base_score
##   enter(context)                     called once when chosen
##   tick(context, delta) -> Status     called every decision interval while running. Default: RUNNING
##   exit(context, reason)              called once when stopped, with why (ExitReason)
##   can_be_interrupted_by(other)       default: follows interrupt_policy and min_run_time
extends Node
class_name AIBehaviourComponentBase

enum Status { RUNNING, SUCCEEDED, FAILED }
enum ExitReason {
	SUCCEEDED, ## tick() returned SUCCEEDED
	FAILED, ## tick() returned FAILED
	INTERRUPTED, ## something else scored higher and this behaviour allowed the switch
	STATE_CHANGED, ## the AI state changed to one this behaviour isn't eligible in
	UNAVAILABLE, ## is_available() went false, or score() dropped to 0 or below
	REMOVED, ## the behaviour or its manager left the scene tree
}
enum InterruptPolicy {
	ALWAYS, ## switch as soon as anything scores higher
	NEVER_UNTIL_DONE, ## keep running until tick() returns SUCCEEDED/FAILED (or the behaviour becomes ineligible)
}

@export var behaviourID:StringName = &"" ## defaults to the node name
@export var stateName: StringName ## which AI state this runs in. Empty or "All" = any state
@export var base_score: float = 0.5 ## the default score(). 0 or below = never chosen
@export var randomness: float = 0.0 ## adds a random 0..randomness to the score each decision
@export var commitment_bonus: float = 0.0 ## added to the score while running, to make it "sticky". Off by default
@export var cooldown: float = 0.0 ## seconds after finishing before it can be chosen again
@export var min_run_time: float = 0.0 ## seconds it must run before it can be interrupted by a better option
@export var interrupt_policy: InterruptPolicy = InterruptPolicy.NEVER_UNTIL_DONE ## Claude 2026-11-04: default changed from ALWAYS at the owner's request. Behaviours that never finish should set ALWAYS
@export var wake_on_facts: Array[StringName] = [] ## new memory facts of these types trigger an immediate re-decide

var behaviourManager: AIBehaviourManagerComponent
var pawn: CharacterPawn3D ## convenience copy of context.pawn
var aiCore: AICoreComponent ## convenience copy of context.aiCore
var pawnRID: RID

#bookkeeping owned by the manager; read-only for behaviours
var isRunning:= false
var runTime: float = 0.0 ## seconds since enter()
var cooldownUntil: float = 0.0 ## manager time when the cooldown ends
var lastScore: float = 0.0 ## for debugging


func _enter_tree() -> void:
	if behaviourID == &"":
		behaviourID = StringName(self.name)
	else:
		self.name = behaviourID
	if !behaviourManager and get_parent() is AIBehaviourManagerComponent:
		behaviourManager = get_parent()
	else:
		printerr("error getting parent reference", get_parent(), behaviourManager)


func _ready() -> void:
	if behaviourManager:
		behaviourManager.request_register_behaviour_component(self)


#region override these
##hard yes/no: can this behaviour run at all right now? (e.g. "do I remember an enemy?")
func is_available(_context: AIContext) -> bool:
	return true


##how much this behaviour wants to run. Higher wins. 0 or below means "don't pick me"
func score(_context: AIContext) -> float:
	return base_score


##called once when this behaviour is chosen
func enter(_context: AIContext) -> void:
	pass


##called every decision interval while running. Return SUCCEEDED/FAILED to finish, RUNNING to continue
func tick(_context: AIContext, _delta: float) -> Status:
	return Status.RUNNING


##called once when this behaviour stops, whatever the reason
func exit(_context: AIContext, _reason: ExitReason) -> void:
	pass


##asked when something else scores higher. Default: interrupt_policy, but never before min_run_time
func can_be_interrupted_by(_other: AIBehaviourComponentBase) -> bool:
	if runTime < min_run_time:
		return false
	return interrupt_policy == InterruptPolicy.ALWAYS


##text for debug overlays
func get_debug_text() -> String:
	return "%s  score %.2f%s" % [behaviourID, lastScore, "  RUNNING %.1fs" % runTime if isRunning else ""]
#endregion


##true if this behaviour may run in [param state]. No known state (&"") means every behaviour is eligible
func is_eligible_in_state(state: StringName) -> bool:
	return stateName == &"" or stateName == &"All" or state == &"" or stateName == state


##called by the manager so pawn/aiCore stay usable as shortcuts
func set_references_from(context: AIContext) -> void:
	pawn = context.pawn
	aiCore = context.aiCore
	if pawn:
		pawnRID = pawn.get_rid()
