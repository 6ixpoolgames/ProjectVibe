extends Node
class_name AIStateComponentBase

@export var state_name:String ##is set as state name if not left blank
@export var state_priority:int = 255 ## state priority if multiple states are valid at the same time. Lower is higher priorty. Golf rules baybee

#references
var pawn: CharacterPawn3D
var AIStateManager: AIStateManagerComponent
var nexus: PawnNexusComponent

#ready flags
var isReady:= false


func _ready() -> void:
	if state_name:
		name = state_name
	AIStateManager = get_parent()
	AIStateManager.request_register_state(self)
	
##contains logic for when to set state as active
func is_state_valid()->bool:
	var stateIsValid:= false
	return stateIsValid

func get_state_priorty()->int:
	return state_priority

func set_ready(flag:bool=true)->void:
	isReady = flag
	pawn = AIStateManager.AICore.pawn
	
func set_references(nexusRef:PawnNexusComponent)->void:
	nexus = nexusRef
	pawn = nexus.pawn
