extends Node3D
class_name AICoreComponent

#AI sense polling frequency
@onready var polling_freq_frame_count: int = 3 ##number of physics frames between polling calls
@export var polling_group: int = 0 ##which frame this component polls. Choose 0 for random assignment.

#node references
var isReferenceSet:= false
var pawn: CharacterPawn3D
var nexus: PawnNexusComponent
#var CharacterModel: MeshInstance3D
#var CollisionCapsule: CollisionShape3D
#var ControllerManager: MovementControllerManager
var statManager: CharacterStatManager
#var CameraControllerArm: PawnCameraController
#var AICore: AICoreComponent
var sensingComponent: AISensingComponent
#var AIStateManager: AIStateManagerComponent
var aiStateManager: AIStateManagerComponent
var aiBehaviourManager: AIBehaviourManagerComponent
var aiMemory: AIMemoryComponent # Claude 2026-11-03: working memory, written by sensing, read by states/behaviours
var context:= AIContext.new() # Claude 2026-11-04: one shared context per pawn, used by both the state and behaviour managers


#references and ready checks
#var pawn: CharacterPawn3D
#var stateManagerComponent: AIStateManagerComponent
#var sensingComponent: AISensingComponent
@export var addAISensingComponentOnSpawn:= true
@export var addAIStateManagerOnSpawn:= true
@export var addAIBehaviourManagerOnSpawn:= true
@export var addAIMemoryOnSpawn:= true # Claude 2026-11-03: spawn an AIMemoryComponent like the other subcomponents

#initalization resources
@export var sensingInitRes:AISensingInitializerBaseRes = ResourcePreloadManager.SenseInitRes_default ##initializer resource for sensing component of type AISensingInitializerBaseRes
@export var stateInitRes = null
@export var behaviourInitRes = null

#Global AI coordinater  variables
@export var useGlobalPollingFrame:= true ##if true, polls using global AI coordinator polling frame. FALSE uses internal polling counts

#public variable accessed by subcomponents for when to poll
var pollingGroupActive:int = 0
	
func _init(addSense:bool = addAISensingComponentOnSpawn, addState:bool = addAIStateManagerOnSpawn, addBehave:bool = addAIBehaviourManagerOnSpawn, pollFreq: int = polling_freq_frame_count, pollGrp: int = polling_group)-> void:
#region initialize variables
	addAISensingComponentOnSpawn = addSense
	addAIStateManagerOnSpawn = addState
	addAIBehaviourManagerOnSpawn = addBehave
	polling_freq_frame_count = pollFreq
	polling_group = pollGrp
	context.aiCore = self # Claude 2026-11-04: the context reads every other reference through the AI core
#endregion


#var children:Array[Node]		
func _enter_tree() -> void:
	print_stack()
	_update_component_references()
	_init_memory_component() # Claude 2026-11-03: before sensing, so sensing has somewhere to write from its first poll
	_init_sensing_component(sensingInitRes)
	_init_state_manager_component()
	_init_behaviour_manager_component()

func _ready() -> void:
	_polling_outofbounds_reassignment()
	#pass_subcomponent_references()
	sensingComponent.set_is_sensing_active(true) #probably need to move this to the nexus component
	_nullify_init_resources(true)
	#GlobalTools.print_sequence_counter(self, "_ready")


func _init_sensing_component(senseRes: AISensingInitializerBaseRes = sensingInitRes)->void:
	if addAISensingComponentOnSpawn:
		sensingComponent = AISensingComponent.new(senseRes)
		sensingComponent.name = "AISensingComponent"
		self.add_child(sensingComponent)


# Claude 2026-11-03: spawns the memory component, same pattern as the sensing/state/behaviour spawners
func _init_memory_component()->void:
	if addAIMemoryOnSpawn:
		aiMemory = AIMemoryComponent.new()
		aiMemory.name = "AIMemoryComponent"
		self.add_child(aiMemory)


func _init_state_manager_component():
	if addAIStateManagerOnSpawn:
		aiStateManager = AIStateManagerComponent.new()
		aiStateManager.name = "AIStatemanager"
		self.add_child(aiStateManager)


func _init_behaviour_manager_component():
	if addAIBehaviourManagerOnSpawn:
		aiBehaviourManager = AIBehaviourManagerComponent.new()
		aiBehaviourManager.name = "AIBehaviourManager"
		self.add_child(aiBehaviourManager)


#nulls initialization resource references to remove them from memory
func _nullify_init_resources(nullify:bool=true):
	if nullify:
		sensingInitRes = null
		stateInitRes = null
		behaviourInitRes = null


##count through frames and set which polling group should fire. Can use either globlAIcoordinator or self for timing
func should_poll_group()->int:
	if useGlobalPollingFrame:
		#print("[AI Core polling] polling frame is: ", pollingGroupActive, " ", pawn)
		pollingGroupActive = GlobalAICoordinator.get_polling_frame()
		return pollingGroupActive
	#region self timing (legacy functionality)
	pollingGroupActive += 1
	if pollingGroupActive > polling_freq_frame_count:
		pollingGroupActive = 1
	return pollingGroupActive
	#endregion


func poll_now()->bool:
	if pollingGroupActive == polling_group:
		return true
	else:
		return false


##checks if polling group is valid and reassigns a random valid group if not
func _polling_outofbounds_reassignment()->void:
	if polling_freq_frame_count < 1:
		polling_freq_frame_count = 3 # defaults polling frequency to 20hz if not set properly
	if polling_group < 1 or polling_group > polling_freq_frame_count:
		polling_group = randi_range(1, polling_freq_frame_count) #randomizes polling group if less than 1 or greater than polling frequency
		#print("polling group outbounds. randomly reassigned to: ", polling_group, " of ", polling_freq_frame_count)


var doOnce:= false
func _physics_process(_delta: float) -> void:  
	should_poll_group()
	if pawn: #WARNING refactor this
		#janky ASF way of passing along CharStatManager reference to AIStateManager need to noodle on a better implementation
		if nexus.statManager and !doOnce:
			print("||||", pawn, " statmanager: ", pawn.statManager)
			statManager = pawn.statManager
			pass_subcomponent_references()
			sensingComponent.set_is_sensing_active(true)
			if aiStateManager: # Claude 2026-11-04: guard, the state manager is optional (addAIStateManagerOnSpawn)
				aiStateManager.set_is_state_manager_active(true)
			doOnce = true


func get_sensing_component()->AISensingComponent:
	return sensingComponent


func get_state_manager()->AIStateManagerComponent:
	return aiStateManager


func get_behaviour_component()->AIBehaviourManagerComponent:         #WARNING not yet implemented
	return aiBehaviourManager


# Claude 2026-11-03: accessor for the new memory component, matching the getters above
func get_memory_component()->AIMemoryComponent:
	return aiMemory


func _update_component_references()->void:
	if !nexus and get_parent() is PawnNexusComponent:
		nexus = get_parent()
		pawn = nexus.pawn
		nexus.aiCore = self


func set_references()->void:
	statManager = nexus.statManager


##mostly depracated
func pass_subcomponent_references()->void:
	if sensingComponent: sensingComponent.set_references(nexus)
	else: printerr("sense component NULL ",nexus.pawn)
	if aiStateManager: aiStateManager.set_references(nexus) 
	else: printerr("state manager NULL ",nexus.pawn)
	#AIStateManager.pull_component_references(self, sensingComponent, statManager)
	#sensingComponent.pull_component_references(self)
