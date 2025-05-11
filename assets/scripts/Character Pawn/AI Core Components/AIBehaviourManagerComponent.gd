extends Node
class_name AIBehaviourManagerComponent

var stateIndex:Array[StringName] = []
var stateBehaviour2DArr:Array = []
var allBehaviours: Array[AIBehaviourComponentBase] = []
var allBehaviourNames: Array[StringName] = []

var AICore: AICoreComponent
var pawn: CharacterPawn3D
var nexus: PawnNexusComponent

func _enter_tree()->void:
	if get_parent() is AICoreComponent:
		AICore = get_parent()
		pawn = AICore.pawn
		nexus = AICore.nexus
		AICore.AIBehaviourManager = self
	#else:
	#	Pawn = get_parent() #debug feature. refactor later!
	#	print("not attached to AI Core! ", Pawn)

func _ready()->void:
	var children = self.get_children()
	for c in children:
		if c.has_method("pull_down_references"):
			c.pull_down_references(AICore, pawn)

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
			
