extends Node
class_name ControllerComponentBase

@export var isPriorityController = false
@export var inputPriority:int = 255
var pawn: CharacterPawn3D
var nexus: PawnNexusComponent
var controllerManager: MovementControllerManager

var isReady:bool = false

func _enter_tree() -> void:
	controllerManager = get_parent()
	nexus = controllerManager.nexus
	pawn = controllerManager.pawn
	print(self, pawn)
	if not controllerManager is MovementControllerManager or controllerManager == null:
		print("Not a valid MovementControllerManager!")
	if not pawn is CharacterPawn3D or pawn == null:
		print("Not a valid pawn!")
	#print("ControllerBase ready super", pawn, " ", controllerManager, " inputPriority ", inputPriority)
	
func set_input_priority(prio:int)->void:
	inputPriority = prio
	
func get_input_priority()->int:
	return inputPriority

var navAgent: NavigationAgent3D
##creates a new navigation agent 3D for the click to move controller.
## [param overwrite] if overwrite is true, deletes all other NavAgent3Ds attached to the controller
func _create_nav_agent(overwrite:bool):
	var valid:= is_instance_valid(nexus.controllerNavAgent3D)
	if overwrite or !valid: 
		if valid:
			nexus.controllerNavAgent3D.queue_free()
		navAgent = NavigationAgent3D.new()
		#region : create Nav Agent code block
		navAgent.name = "ControllerNavAgent3D"
		print(pawn, " created ", navAgent, " attached to ", nexus)
		nexus.add_child.call_deferred(navAgent)
		nexus.controllerNavAgent3D = navAgent
		#endregion
		navAgent.debug_enabled = true
	elif valid:
		navAgent = nexus.controllerNavAgent3D
