extends ControllerComponentBase
class_name AIControllerBase


func _enter_tree() -> void:
	super()
	controllerManager.aiController = self #need to add dupe checking here.


func _ready() -> void:
	_create_nav_agent(true)
	if !pawn:
		set_physics_process(false)
	else:
		isReady = true


func _physics_process(_delta: float) -> void:
	if isReady:
		_pawn_navigation()


var destination = Vector3.ZERO
var local_destination = Vector3.ZERO
var aiDirection = Vector3.ZERO
##called each frame to handle navAgent movement. Runs if navigationToggle flag is TRUE. If is_navigation_finished() is TRUE, calls stop_navigation() automatically	
func _pawn_navigation()->void:
	var hAiDirection = Vector3.ZERO
	if navigationToggle == true: #only get_next_path_position() if actively navigating. Not sure if it'll break stuff later, but works for now
		destination = navAgent.get_next_path_position()
		local_destination = destination - pawn.global_position #turns out where you're going minus where you are equals the vector towards there in vector math
		aiDirection = local_destination.normalized()
		hAiDirection = Vector3(aiDirection.x,0,aiDirection.z)
	#if nav is done but still toggled on
	if nexus.controllerNavAgent3D.is_navigation_finished() and navigationToggle == true:
		stop_navigation()
		controllerManager.request_move_command(hAiDirection, self)
	elif navigationToggle == true:
		controllerManager.request_move_command(hAiDirection, self)


var navigationToggle = false
func move_to(dest: Vector3)->void:
	nexus.controllerNavAgent3D.set_target_position(dest)
	navigationToggle = true


##stops navigation by setting navigationToggle flag to FALSE and setting the nav target position to pawn's current position		
func stop_navigation()->void:
	navigationToggle = false #toggle navigation off
	nexus.controllerNavAgent3D.set_target_position(pawn.global_position) #reset target position to ensure stoppage


func run_to(_dest: Vector3)->void:
	print("run_to() function currently empty")
	return
