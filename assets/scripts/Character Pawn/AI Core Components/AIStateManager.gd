extends Node
class_name AIStateManagerComponent

#node referrences
var aiCore: AICoreComponent
var nexus:PawnNexusComponent

@export var isPremade:= false

var allStates: Array[Dictionary] =[]
var stateEntryTemplate = {
	"name":"",
	"reference":AIStateComponentBase,
}


func _enter_tree() -> void:
	print_stack()
	aiCore = get_parent()
	nexus = aiCore.nexus
	_check_overwrite_premade()
	if not isForDeletion:
		nexus.aiStateManager = self

var isForDeletion:= false
func _check_overwrite_premade()->void:
	#region check if should overwrite and cleanup extra nodes
	if nexus.allow_overwrites.AIStateManager:
		if aiCore.aiStateManager != self:
			if isPremade:
				isForDeletion = true
				self.queue_free()
				return
			else:
				aiCore.aiStateManager.queue_free()
	else:
		if aiCore.aiStateManager != self:
			if isPremade:
				aiCore.aiStateManager.queue_free()
			else:
				isForDeletion = true
				self.queue_free()
				return
	#endregion
	aiCore.aiStateManager = self


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


func _check_valid_state()->AIStateComponentBase:
	var validState:AIStateComponentBase
	var mostPriority:int = 256
	for dict in allStates:
		if dict.reference.is_state_valid():
			if dict.reference.get_state_priority() < mostPriority:
				validState = dict.reference
	return validState


func set_references(nexusRef:PawnNexusComponent)->void:
	nexus = nexusRef
