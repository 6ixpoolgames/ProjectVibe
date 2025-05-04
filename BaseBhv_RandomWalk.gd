##randomly walks around during idle
extends AIBehaviourComponentBase
class_name BaseRandomWalkBehaviour

@export var stateOverwrite: StringName ##overwrites stateName. Leave blank to keep default statename
@export var behaviourIdOverwrite: StringName ##overwrites stateName. Leave blank to keep default statename

func _enter_tree() -> void:
	set_physics_process(false)

func _ready()->void:
	if stateOverwrite != &"":
		stateName = stateOverwrite
	if behaviourIdOverwrite != &"":
		behaviourID = behaviourIdOverwrite
		
func _physics_process(delta: float) -> void:
	delta_timer(delta)
	if Pawn.controllerManager.AIController:
		#if !isWandering:
		#	pause_random_duration()
		if !isPausing:
			if !Pawn.controllerManager.AIController.navigationToggle:
				Pawn.controllerManager.AIController.move_to(pick_random_location().position)
				isWandering = true 
			if Pawn.controllerManager.AIController.navAgent.is_navigation_finished():
				isWandering = false
				pause_random_duration()
func enter_state()->void:
	if !Pawn:
		Pawn = BehaviourManager.AICore.Pawn
	set_physics_process(true)
	#BehaviourManager.isRunningBehaviour = true
	print(Pawn," entered random walk behavior")

func exit_state()->void:
	if Pawn.controllerManager.AIController:
		Pawn.controllerManager.AIController.stop_navigation()
	set_physics_process(false)
	print(Pawn," left random walk behavior")
	
	
@onready var spaceState = get_tree().root.get_world_3d().direct_space_state
@onready var query = PhysicsRayQueryParameters3D.new()
@export var wanderRadius: float = 10
@export var y_offset_default: float = 120
@export var collisionMask:int = 31 ## 31 is collision layers 1-5
@export var excludeRID: Array[RID] = []
var isWandering:= false
func pick_random_location(radius:float = wanderRadius, y_offset:float= y_offset_default, mask:int= collisionMask, exclude:Array[RID] = excludeRID) -> Dictionary:
	var pos = Pawn.global_position
	var randX = randf_range(-radius,radius)
	var randZ = randf_range(-radius,radius)
	var from = Vector3( randX, (pos + y_offset),randZ)
	var to = Vector3(randX, (pos - y_offset), randZ)
	query.from = from
	query.to = to
	query.collision_mask = mask
	query.exclude = exclude
	GlobalTools.lines_with_points(from,to,Color.BLUE_VIOLET,5)
	return spaceState.intersect_ray(query)

var isPausing:bool = false
@export var minPauseDurr: float = 5
@export var maxPauseDurr: float = 15
func pause_random_duration(min:float = minPauseDurr, max:float = maxPauseDurr)->bool:
	if !timerDone and !timerDoneName == &"pauseRandom":
		var pauseTime = randf_range(min,max)
		timer_start(pauseTime,&"pauseRandom")
		isPausing = true
		return isPausing
	if timerDone and timerDoneName == &"pauseRandom":
		isPausing = false
	return isPausing

var methodName:StringName = &""
func timer_start(duration:float, method: StringName):
	timerDurr = duration
	timerActive = true
	methodName = method
	print("timer started! ", methodName)
	
var timerDone: bool = false
var timerDoneName: StringName = &""
func timer_finished(method:StringName = methodName):
	if methodName == &"pauseRandom":
		pause_random_duration()
	print("timer finished! ", methodName)
	methodName = &""


var timerActive:= false
var timerDurr:= -1
func delta_timer(delta:float):
	if timerActive and methodName != &"":
		timerDurr -= delta
		if timerDurr < (0-delta):
			timerActive = false
			timerDurr = -1
			timer_finished(methodName)
			timerDone = true
			timerDoneName = methodName
			methodName = &""
			
