extends Node3D
class_name AIUnitManager

#AI sense polling frequency
@export var polling_freq_frame_count: int = 3 ##number of physics frames between polling calls
@export var polling_group: int = 0 ##which frame this component polls. Choose 0 for random assignment.

var StateManagerComponent: AIStateManagerComponent
var SensingComponent: AISensingComponent

#public variable accessed by subcomponents for when to poll
var pollingGroupActive:int = 0

func initialize()->void:
	polling_outofbounds_reassignment()
	clear_subcomponents()
	SensingComponent = AISensingComponent.new()
	StateManagerComponent = AIStateManagerComponent.new()
	SensingComponent.name = "AISensingComponent"
	StateManagerComponent.name = "AIStatemanagerComponent"
	self.add_child(SensingComponent)
	self.add_child(StateManagerComponent)
	

func clear_subcomponents():
	if SensingComponent:
		SensingComponent.queue_free()
		SensingComponent = null
	if StateManagerComponent:
		StateManagerComponent.queue_free()
		StateManagerComponent = null

##count through frames and set which polling group should fire
func should_poll_group()->int:
	pollingGroupActive += 1
	if pollingGroupActive >= polling_freq_frame_count:
		pollingGroupActive = 0
	return pollingGroupActive
	
##checks if polling group is valid and reassigns a random valid group if not
func polling_outofbounds_reassignment()->void:
	if polling_freq_frame_count < 1:
		polling_freq_frame_count = 3 # defaults polling frequency to 20hz if not set properly
	if polling_group < 1 or polling_group > polling_freq_frame_count:
		polling_group = randi_range(1, polling_freq_frame_count) #randomizes polling group if less than 1 or greater than polling frequency
		#print("polling group outbounds. randomly reassigned to: ", polling_group, " of ", polling_freq_frame_count)
	
func _physics_process(_delta: float) -> void:
	should_poll_group()
	
func _ready() -> void:
	initialize()
