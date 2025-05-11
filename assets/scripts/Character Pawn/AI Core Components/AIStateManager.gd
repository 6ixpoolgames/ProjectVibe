extends Node
class_name AIStateManagerComponent

#node referrences
var AICore: AICoreComponent
var nexus:PawnNexusComponent

@export var isPremade:= false

var allStates: Array[Dictionary] =[]
var stateEntryTemplate = {
	"name":"",
	"reference":AIStateComponentBase,
}

func _enter_tree() -> void:
	AICore = get_parent()
	nexus = AICore.nexus
	nexus.AIStateManager = self
	check_overwrite_premade()


func check_overwrite_premade()->void:
	#region check if should overwrite and cleanup extra nodes
	if nexus.allow_overwrites.AIStateManager:
		if AICore.AIStateManager != self:
			if isPremade:
				self.queue_free()
				return
			else:
				AICore.AIStateManager.queue_free()
	else:
		if AICore.AIStateManager != self:
			if isPremade:
				AICore.AIStateManager.queue_free()
			else:
				self.queue_free()
				return
	#endregion
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
