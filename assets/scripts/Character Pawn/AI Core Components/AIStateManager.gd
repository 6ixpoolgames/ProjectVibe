extends Node
class_name AIStateManagerComponent

#node referrences
var AICore: AICoreComponent
var nexus:PawnNexusComponent

var allStates: Array[Dictionary] =[]
var stateEntryTemplate = {
	"name":"",
	"reference":AIStateComponentBase,
}

func _enter_tree() -> void:
	AICore = get_parent()
	if !AICore.AIStateManager:
		AICore.AIStateManager = self

func request_register_state(state: AIStateComponentBase)->void:
	for dict in allStates:
		if dict.name == state.name:
			print(state.name," already registred ", self)
		else:
			var stateDict = stateEntryTemplate.duplicate()
			stateDict.name = state.name
			stateDict.reference = state
			allStates.append(stateDict)
			state.set_references(nexus)
			
func check_valid_state()->AIStateComponentBase:
	var validState:AIStateComponentBase
	var mostPriority:int = 256
	for dict in allStates:
		if dict.reference.is_state_valid():
			if dict.reference.get_state_priority() < mostPriority:
				validState = dict.reference
	return validState

func set_references(nexusRef:PawnNexusComponent)->void:
	nexus = nexusRef
