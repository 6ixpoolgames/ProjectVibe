extends ControllerComponentBase
class_name AIControllerBase


func _enter_tree() -> void:
	super()
	create_nav_agent(true)

func _ready() -> void:
	if !Pawn:
		set_physics_process(false)

func _physics_process(_delta: float) -> void:
	pawn_navigation()

	
var navAgent: NavigationAgent3D
##creates a new navigation agent 3D for the click to move controller.
## [param overwrite] if overwrite is true, deletes all other NavAgent3Ds attached to the controller
func create_nav_agent(overwrite:bool)->void:
	if overwrite: #checks all child
		var children = self.get_children()
		for c in children:
			if c is NavigationAgent3D:
				c.queue_free()
	navAgent = NavigationAgent3D.new()
	navAgent.name = "playerNavAgent"
	add_child(navAgent)
	navAgent.debug_enabled = true

	
var navigationToggle = false
func move_to(dest: Vector3)->void:
	navAgent.set_target_position(dest)
	navigationToggle = true

var destination = Vector3.ZERO
var local_destination = Vector3.ZERO
var aiDirection = Vector3.ZERO
##called each frame to handle navAgent movement. Runs if navigationToggle flag is TRUE. If is_navigation_finished() is TRUE, calls stop_navigation() automatically	
func pawn_navigation()->void:
	var hAiDirection = Vector3.ZERO
	if navigationToggle == true: #only get_next_path_position() if actively navigating. Not sure if it'll break stuff later, but works for now
		destination = navAgent.get_next_path_position()
		local_destination = destination - Pawn.global_position #turns out where you're going minus where you are equals the vector towards there in vector math
		aiDirection = local_destination.normalized()
		hAiDirection = Vector3(aiDirection.x,0,aiDirection.z)
	#if nav is done but still toggled on
	if navAgent.is_navigation_finished() and navigationToggle == true:
		stop_navigation()
		controllerManager.request_move_command(hAiDirection, self)
	elif navigationToggle == true:
		controllerManager.request_move_command(hAiDirection, self)

##stops navigation by setting navigationToggle flag to FALSE and setting the nav target position to pawn's current position		
func stop_navigation()->void:
	navigationToggle = false #toggle navigation off
	navAgent.set_target_position(Pawn.global_position) #reset target position to ensure stoppage
	
	
func run_to(_dest: Vector3)->void:
	print("run_to() function currently empty")
	return
