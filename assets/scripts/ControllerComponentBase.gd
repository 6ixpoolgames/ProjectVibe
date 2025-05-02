extends Node
class_name ControllerComponentBase

@export var isPriorityController = false
@export var inputPriority:int = 255
var Pawn: CharacterPawn3D
var controllerManager: MovementControllerManager

func _ready():
	controllerManager = get_parent()
	Pawn = controllerManager.Pawn
	if not controllerManager is MovementControllerManager or controllerManager == null:
		print("Not a valid MovementControllerManager!")
	if not Pawn is CharacterPawn3D or Pawn == null:
		print("Not a valid pawn!")
	#print("ControllerBase ready super", pawn, " ", controllerManager, " inputPriority ", inputPriority)
	
func set_input_priority(prio:int)->void:
	inputPriority = prio
	
func get_input_priority()->int:
	return inputPriority
