extends Node3D
class_name AIUnitManager

#AI sense polling frequency
@export var polling_freq_frame_count: int = 3 ##number of physics frames between polling calls
@export var polling_group: int = 0 ##which frame this component polls. Choose 0 for random assignment.

#references and ready checks
#var pawn: CharacterPawn3D
#var stateManagerComponent: AIStateManagerComponent
#var sensingComponent: AISensingComponent
var stateManagerReady:= false
var sensingComponentReady:= false

#public variable accessed by subcomponents for when to poll
var pollingGroupActive:int = 0

func initialize()->void:
	polling_outofbounds_reassignment()
	clear_subcomponents()
	SensingComponent = AISensingComponent.new()
	StateManager = AIStateManagerComponent.new()
	SensingComponent.name = "AISensingComponent"
	StateManager.name = "AIStatemanagerComponent"
	if get_parent_node_3d() is CharacterPawn3D:
		Pawn = get_parent_node_3d()
	self.add_child(SensingComponent)
	self.add_child(StateManager)
	
func _enter_tree() -> void:
	init_sensing_component()
	init_state_manager_component()


func init_sensing_component():
	if !SensingComponent:
		SensingComponent = AISensingComponent.new()
		SensingComponent.name = "AISensingComponent"
		self.add_child(SensingComponent)

func init_state_manager_component():
	if !StateManager:
		StateManager = AIStateManagerComponent.new()
		StateManager.name = "AIStatemanagerComponent"
		self.add_child(StateManager)
	
func clear_subcomponents():
	if SensingComponent:
		SensingComponent.queue_free()
		SensingComponent = null
	if StateManager:
		StateManager.queue_free()
		StateManager = null

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
	#pass_down_references()
	#if !allComponentsReady:
	#	is_all_components_ready()
	#if allComponentsReady:
	#	pass_down_references()
		should_poll_group()
	
func _ready() -> void:
	#initialize()
	polling_outofbounds_reassignment()
	
	
var componentsReady: Array[Node]
func component_has_intialized(component: Node):
	if component is AISensingComponent and !sensingComponentReady:
		componentsReady.append(component)
		sensingComponentReady = true
	if component is AIStateManagerComponent and !stateManagerReady:
		componentsReady.append(component)
		stateManagerReady = true
		
var allComponentsReady:= false
func is_all_components_ready():
	if sensingComponentReady and stateManagerReady:
		allComponentsReady = true
		print("all components ready")

var stopOnOne:=false
func pass_down_references():
	if !stopOnOne and allComponentsReady and Pawn:
		for c in componentsReady:
			c.Pawn = Pawn
			if c is AISensingComponent:
				c.StateManager = StateManager
			if c is AIStateManagerComponent:
				c.SensingComponent = SensingComponent
		stopOnOne = true
		print(">>>Manager.polling_group = ", polling_group)

#node references
var isReferenceSet:= false
var Pawn: CharacterPawn3D
var CharacterModel: MeshInstance3D
var CollisionCapsule: CollisionShape3D
var ControllerManager: MovementControllerManager
var StatManager: StatManagerComponent
var CameraControllerArm: PawnCameraController
var AIManager: AIUnitManager
var SensingComponent: AISensingComponent
func set_references(references:Array[Node])->void:
	for r in references:
		if r is CharacterPawn3D:
			Pawn = r
		if r.name == "CharacterModel":
			CharacterModel = r
		if r.name == "CollisionCapsule":
			CollisionCapsule = r
		if r is MovementControllerManager:
			ControllerManager = r
		if r is StatManagerComponent:
			StatManager = r
		if r is PawnCameraController:
			CameraControllerArm = r
		if r is AIUnitManager:
			AIManager = r
		if r is AISensingComponent:
			SensingComponent = r
	isReferenceSet = true
