extends Node3D
class_name AIUnitManager

#AI sense polling frequency
@export var polling_freq_frame_count: int = 3 ##number of physics frames between polling calls
@export var polling_group: int = 0 ##which frame this component polls. Choose 0 for random assignment.

#references and ready checks
var pawn: CharacterPawn3D
var stateManagerComponent: AIStateManagerComponent
var sensingComponent: AISensingComponent
var stateManagerReady:= false
var sensingComponentReady:= false

#public variable accessed by subcomponents for when to poll
var pollingGroupActive:int = 0

func initialize()->void:
	polling_outofbounds_reassignment()
	clear_subcomponents()
	sensingComponent = AISensingComponent.new()
	stateManagerComponent = AIStateManagerComponent.new()
	sensingComponent.name = "AISensingComponent"
	stateManagerComponent.name = "AIStatemanagerComponent"
	if get_parent_node_3d() is CharacterPawn3D:
		pawn = get_parent_node_3d()
	self.add_child(sensingComponent)
	self.add_child(stateManagerComponent)
	

func clear_subcomponents():
	if sensingComponent:
		sensingComponent.queue_free()
		sensingComponent = null
	if stateManagerComponent:
		stateManagerComponent.queue_free()
		stateManagerComponent = null

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
	pass_down_references()
	if !allComponentsReady:
		is_all_components_ready()
	if allComponentsReady:
		pass_down_references()
		should_poll_group()
	
func _ready() -> void:
	initialize()

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
	if !stopOnOne and allComponentsReady and pawn:
		for c in componentsReady:
			c.pawn = pawn
			if c is AISensingComponent:
				c.stateManagerComponent = stateManagerComponent
			if c is AIStateManagerComponent:
				c.sensingComponent = sensingComponent
		stopOnOne = true
		print(">>>Manager.polling_group = ", polling_group)
