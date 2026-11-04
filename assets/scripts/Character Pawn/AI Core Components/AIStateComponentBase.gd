## Claude (claude-opus-5-5), 2026-11-04: rewritten as the working base class for AI state nodes.
## Kept from the original: state_name, state_priority (lower = more important, "golf rules"), registering
## with the manager, and the old is_state_valid() / get_state_priorty() names so older state scripts still load.
##
## A state is "what situation am I in" (Idle, Alerted, Routed...). It doesn't act; it gates which
## behaviours may run (a behaviour's stateName). Put state nodes as children of AIStateManagerComponent.
## The manager picks the valid state with the LOWEST state_priority number. See its header for all rules.
##
## Defaults: a state with no code is never valid on its own, so it only appears as the manager's
## default_state or through force_state(). Override only what you need:
##   is_valid(context) -> bool    should I be the state right now? Default: is_state_valid() (false)
##   can_exit(context) -> bool    may the manager leave me? Default: true. Return false for permanent states (Dead)
##   enter(context) / exit(context)
extends Node
class_name AIStateComponentBase

@export var state_name:String ##is set as state name if not left blank
@export var state_priority:int = 255 ## state priority if multiple states are valid at the same time. Lower is higher priorty. Golf rules baybee
@export var min_time_in_state: float = 0.0 ## seconds the manager must stay in this state before leaving it for another

#references
var pawn: CharacterPawn3D
var aiStateManager: AIStateManagerComponent
var nexus: PawnNexusComponent

var isCurrent:= false ## set by the manager
var timeInState: float = 0.0 ## set by the manager: seconds since this state was entered


func _ready() -> void:
	if state_name:
		name = state_name
	if get_parent() is AIStateManagerComponent:
		aiStateManager = get_parent()
		aiStateManager.request_register_state(self)
	else:
		printerr(self, " state is not a child of an AIStateManagerComponent")


##the name behaviours use in their stateName: state_name if set, else the node name
func get_state_name() -> StringName:
	return StringName(state_name) if state_name else StringName(name)


#region override these
##should this be the state right now? Default: the old is_state_valid() hook (false)
func is_valid(_context: AIContext) -> bool:
	return is_state_valid()


##may the manager leave this state? Default: yes. Return false to make a state permanent (e.g. Dead)
func can_exit(_context: AIContext) -> bool:
	return true


##called once when this becomes the current state
func enter(_context: AIContext) -> void:
	pass


##called once when this stops being the current state
func exit(_context: AIContext) -> void:
	pass
#endregion


func get_state_priority() -> int:
	return state_priority


#region original API, kept so existing state scripts keep working
##contains logic for when to set state as active. Older hook; new states should override is_valid(context)
func is_state_valid()->bool:
	return false

func get_state_priorty()->int: #original (misspelled) name
	return state_priority

func set_ready(_flag:bool=true)->void:
	pass

func set_references(nexusRef:PawnNexusComponent)->void:
	nexus = nexusRef
	if nexus:
		pawn = nexus.pawn
#endregion
