extends Node3D
class_name AICoreComponent

#AI sense polling frequency
@export var polling_freq_frame_count: int = 3 ##number of physics frames between polling calls
@export var polling_group: int = 0 ##which frame this component polls. Choose 0 for random assignment.

#references and ready checks
#var pawn: CharacterPawn3D
#var stateManagerComponent: AIStateManagerComponent
#var sensingComponent: AISensingComponent
@export var addAISensingComponentOnSpawn:= true
@export var addAIStateManagerOnSpawn:= true
@export var addAIBehaviourManagerOnSpawn:= true

#public variable accessed by subcomponents for when to poll
var pollingGroupActive:int = 0
	
func _init(addSense:bool = addAISensingComponentOnSpawn, addState:bool = addAIStateManagerOnSpawn, addBehave:bool = addAIBehaviourManagerOnSpawn, pollFreq: int = polling_freq_frame_count, pollGrp: int = polling_group)-> void:
	addAISensingComponentOnSpawn = addSense
	addAIStateManagerOnSpawn = addState
	addAIBehaviourManagerOnSpawn = addBehave
	polling_freq_frame_count = pollFreq
	polling_group = pollGrp
	
		
func _enter_tree() -> void:
	pull_component_references()
	var children:Array[Node] = get_children()
	init_sensing_component(children)
	init_state_manager_component(children)
	init_behaviour_manager_component(children)

func _ready() -> void:
	polling_outofbounds_reassignment()
	pass_subcomponent_references()
	GlobalTools.print_sequence_counter(self, "_ready")

func init_sensing_component(chldr:Array[Node]):
	if !chldr.is_empty():
		for c in chldr:
			if c is AISensingComponent:
				SensingComponent = c
	if !SensingComponent or addAISensingComponentOnSpawn:
		SensingComponent.queue_free()
		SensingComponent = AISensingComponent.new()
		SensingComponent.name = "AISensingComponent"
		self.add_child(SensingComponent)
	

func init_state_manager_component(chldr:Array[Node]):
	if !chldr.is_empty():
		for c in chldr:
			if c is AIStateManagerComponent:
				AIStateManager = c
	if !AIStateManager or addAIStateManagerOnSpawn:
		AIStateManager.queue_free()
		AIStateManager = AIStateManagerComponent.new()
		AIStateManager.name = "AIStatemanager"
		self.add_child(AIStateManager)
	

func init_behaviour_manager_component(chldr:Array[Node]):
	if chldr.is_empty(): pass
	if !AIBehaviourManager:
		if addAIBehaviourManagerOnSpawn:
		#	AIBehaviourManager = AIBehaviourManager.new()
		#	AIBehaviourManager.name = "AIBehaviourManager"
		#	self.add_child(AIBehaviourManager)
			print(Pawn, " hypothetically added behaviour manager. Get on it ya lazy bum!")

##count through frames and set which polling group should fire
func should_poll_group()->int:
	pollingGroupActive += 1
	if pollingGroupActive > polling_freq_frame_count:
		pollingGroupActive = 1
	return pollingGroupActive
	
func poll_now()->bool:
	if pollingGroupActive == polling_group:
		return true
	else:
		return false
##checks if polling group is valid and reassigns a random valid group if not
func polling_outofbounds_reassignment()->void:
	if polling_freq_frame_count < 1:
		polling_freq_frame_count = 3 # defaults polling frequency to 20hz if not set properly
	if polling_group < 1 or polling_group > polling_freq_frame_count:
		polling_group = randi_range(1, polling_freq_frame_count) #randomizes polling group if less than 1 or greater than polling frequency
		#print("polling group outbounds. randomly reassigned to: ", polling_group, " of ", polling_freq_frame_count)
	
func _physics_process(_delta: float) -> void:
	should_poll_group()
	
func get_sensing_component()->AISensingComponent:
	return SensingComponent

func get_state_manager()->AIStateManagerComponent:
	return AIStateManager
	
#func get_behaviour_component()->AIBehaviourManagerComponent:         #not yet implemented
#	return AIBehaviourManager



#node references
var isReferenceSet:= false
var Pawn: CharacterPawn3D
#var CharacterModel: MeshInstance3D
#var CollisionCapsule: CollisionShape3D
#var ControllerManager: MovementControllerManager
var StatManager: CharacterStatManager
#var CameraControllerArm: PawnCameraController
#var AICore: AICoreComponent
var SensingComponent: AISensingComponent
var AIStateManager: AIStateManagerComponent
var AIBehaviourManager = null
func set_references(references:Array[Node])->void:
	for r in references:
		if r is CharacterPawn3D:
			Pawn = r
#		if r.name == "CharacterModel":
#			CharacterModel = r
#		if r.name == "CollisionCapsule":
#			CollisionCapsule = r
#		if r is MovementControllerManager:
#			ControllerManager = r
#		if r is CharacterStatManager:
#			StatManager = r
#		if r is PawnCameraController:
#			CameraControllerArm = r
#		if r is AICoreComponent:
#			AICore = r
		if r is AISensingComponent:
			SensingComponent = r
		if r is AIStateManagerComponent:
			AIStateManager = r
#		if r is AIBehaviourManagerComponent:
#			AIBehaviourManager = r
	isReferenceSet = true
	print(">>>references", references)
	GlobalTools.print_sequence_counter(self, "set_references")

func pull_component_references()->void:
	if get_parent() is CharacterPawn3D and !Pawn:
		Pawn = get_parent()
	if !StatManager and Pawn:
		StatManager = Pawn.StatManager
		
func pass_subcomponent_references()->void:
	SensingComponent.pull_component_references(self)
	AIStateManager.pull_component_references(self, SensingComponent)
