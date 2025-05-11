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
	if pawn.controllerManager.AIController:
		#if !isWandering:
		#	pause_random_duration()
		if !isPausing:
			if !pawn.controllerManager.AIController.navigationToggle:
				pawn.controllerManager.AIController.move_to(pick_random_location().position)
				isWandering = true 
			if pawn.controllerManager.AIController.navAgent.is_navigation_finished():
				isWandering = false
				pause_random_duration()
func enter_state()->void:
	print(pawn," entered random walk behavior")
	if !pawn:
		pawn = behaviourManager.AICore.pawn
	if pawn.controllerManager:
		print("has controller manager")
		if pawn.controllerManager.AIController:
			print("has AI controller")
			set_physics_process(true)
	#BehaviourManager.isRunningBehaviour = true
	

func exit_state()->void:
	if pawn.controllerManager.AIController:
		pawn.controllerManager.AIController.stop_navigation()
	set_physics_process(false)
	print(pawn," left random walk behavior")
	
	
@onready var spaceState = get_tree().root.get_world_3d().direct_space_state
@onready var query = PhysicsRayQueryParameters3D.new()
@export var wanderRadius: float = 10
@export var y_offset_default: float = 120
@export var collisionMask:int = 31 ## 31 is collision layers 1-5
@export var excludeRID: Array[RID] = []
var isWandering:= false
func pick_random_location(radius:float = wanderRadius, y_offset:float= y_offset_default, mask:int= collisionMask, exclude:Array[RID] = excludeRID) -> Dictionary:
	var pos = pawn.global_position
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
func pause_random_duration(minDurr:float = minPauseDurr, maxDurr:float = maxPauseDurr)->bool:
	if !timerDone and !timerDoneName == &"pauseRandom":
		var pauseTime = randf_range(minDurr,maxDurr)
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
	if method == &"pauseRandom":
		pause_random_duration()
	print("timer finished! ", method)
	methodName = &""


var timerActive:= false
var timerDurr:float = -1
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
			
