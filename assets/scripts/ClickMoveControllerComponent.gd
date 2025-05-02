extends ControllerComponentBase
class_name ClickToMoveComponent
 
var activeCamera: PlayerCamera3D
var readySet:bool = false

#func _enter_tree() -> void:
	
	

func _ready():
	super()
	if not Pawn is CharacterPawn3D or !Pawn: #must be controlled by a pawn
		printerr("pawn is not a pawn ", self)
		set_physics_process(false)
	activeCamera = get_viewport().get_camera_3d()
	if !activeCamera:#must have a PlayerCamera3D in the scene to handle cursor inputs
		printerr("camera is not a camera: ", activeCamera)
	#connects signals
	activeCamera.emit_3D_cursor_position.connect(on_cursor_click)
	activeCamera.possession_event.connect(set_active_camera)
	#creates nav agent
	create_nav_agent(true)
	readySet = true

func _physics_process(_delta: float) -> void:
	if readySet:
		pawn_navigation()

var navAgent: NavigationAgent3D
##creates a new navigation agent 3D for the click to move controller.
## [param overwrite] if overwrite is true, deletes all other NavAgent3Ds attached to the controller
func create_nav_agent(overwrite:bool):
	if overwrite: #checks all child
		var children = self.get_children()
		for c in children:
			if c is NavigationAgent3D:
				c.queue_free()
	navAgent = NavigationAgent3D.new()
	navAgent.name = "playerNavAgent"
	add_child(navAgent)
	navAgent.debug_enabled = true
	print("nav agent created", self, " ", Pawn)
 
##sets the current viewport camera as the active camera. Needs refactoring later on once camera transitions are implemented
func set_active_camera(_emitter)-> void:
	activeCamera = get_viewport().get_camera_3d()

var lastTargetPosition = Vector3.ZERO
##test function signal reciever for setting the clicked position to the movement target of the pawn. Needs to be expanded later to include checks for if the pawn is actively selected and which command is being given to it (other than movement).
##[param cursorPos] the world position of the 3D cursor passed from the emitted signal.
func on_cursor_click(cursorPos):
	lastTargetPosition = cursorPos
	move_to(cursorPos)
	print("click signal recieved", Pawn)
	
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
	if navigationToggle == true: #only update variables if actively navigating. Not sure if it'll break stuff later, but works for now
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
