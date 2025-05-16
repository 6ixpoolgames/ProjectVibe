extends Node
class_name AIBehaviourManagerComponent

var stateIndex:Array[StringName] = []
var stateBehaviour2DArr:Array = []
var allBehaviours: Array[AIBehaviourComponentBase] = []
var allBehaviourNames: Array[StringName] = []

var aiCore: AICoreComponent
var pawn: CharacterPawn3D
var nexus: PawnNexusComponent

@export var isPremade:=false

func _enter_tree()->void:
	print_stack()
	if get_parent() is AICoreComponent:
		aiCore = get_parent()
		nexus = aiCore.nexus
		pawn = nexus.pawn
		_check_overwrite_premade()
		if not isForDeletion:
			aiCore.aiBehaviourManager = self
	#else:
	#	Pawn = get_parent() #debug feature. refactor later!
	#	print("not attached to AI Core! ", Pawn)

var isForDeletion:= false
func _check_overwrite_premade()->void:
	#region check if should overwrite and cleanup extra nodes
	if nexus.allow_overwrites.AIBehaviourManager:
		if aiCore.aiBehaviourManager != self:
			if isPremade:
				isForDeletion = true
				self.queue_free()
				return
			else:
				aiCore.aiBehaviourManager.queue_free()
	else:
		if aiCore.aiBehaviourManager != self:
			if isPremade:
				aiCore.aiBehaviourManager.queue_free()
			else:
				isForDeletion = true
				self.queue_free()
				return
	#endregion
	aiCore.aiBehaviourManager = self

func _ready()->void:
	var children = self.get_children()
	for c in children:
		if c.has_method("pull_down_references"):
			c.pull_down_references(aiCore, pawn)

func request_register_behaviour_component(behaviour: AIBehaviourComponentBase):
	var behaviourIndex = allBehaviours.find(behaviour)
	var bNameIndex = allBehaviourNames.find(behaviour.name)
	if bNameIndex == -1:
		allBehaviours.append(behaviour)
		allBehaviourNames.append(behaviour.name)
		add_behaviour_to_state_array(behaviour)
	else:
		print(behaviour, " already registered at index: ", behaviourIndex, " (", allBehaviours[behaviourIndex] , ")")
	#if AICore and is_instance_valid(AICore):
	#	behaviour.AICore = AICore
	#elif Pawn:
	#	behaviour.AICore = Pawn.AICore
	
func add_behaviour_to_state_array(behaviour: AIBehaviourComponentBase):
	var stIdx = stateIndex.find(behaviour.stateName)
	if stIdx == -1:
		if behaviour.stateName == &"":
			var allInd = stateIndex.find(&"All")
			if allInd == -1:
				stateIndex.append(&"All")
				stateBehaviour2DArr.append([behaviour])
			else:
				stateBehaviour2DArr[allInd].append(behaviour)
		else:
			stateIndex.append(behaviour.stateName)
			stateBehaviour2DArr.append([behaviour])
	else:
		var bhIdx = stateBehaviour2DArr[stIdx].find(behaviour)
		if bhIdx == -1:
			stateBehaviour2DArr[stIdx].append(behaviour)
		else:
			print(behaviour, " already in array ", stateIndex[stIdx])
			
			
	
##debug function, prints all behaviour arrays for validation
func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_1:
			print(">>>>all behaviours ",allBehaviours)
			print(">>>>state index ", stateIndex)
			print(">>>>state behaviour array", stateBehaviour2DArr)
			
