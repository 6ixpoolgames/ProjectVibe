extends Node
class_name AIStateComponentBase

@export var state_name:String ##is set as state name if not left blank
@export var state_priority:int = 255 ## state priority if multiple states are valid at the same time. Lower is higher priorty. Golf rules baybee

#references
var pawn: CharacterPawn3D

func _ready() -> void:
	if state_name:
		name = state_name
	pass
	
##contains logic for when to set state as active
func should_state_be_active()->bool:
	var stateIsValid:= false
	return stateIsValid

func get_state_priorty()->int:
	return state_priority
