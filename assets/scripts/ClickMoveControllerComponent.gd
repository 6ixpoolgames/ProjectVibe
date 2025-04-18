extends ControllerComponentBase
class_name ClickToMoveComponent
 
func _ready():
	super()
	if not pawn is CharacterPawn3D or pawn == null:
		printerr("pawn is not a pawn ", self)
	set_active_camera() #initial active camera setting
	if activeCamera == null:
		printerr("camera is not a camera: ", activeCamera)
	#connects signals
	activeCamera.emit_3D_cursor_position.connect(on_cursor_click)
	activeCamera.possession_event.connect(set_active_camera)
	#creates nav agent
	create_nav_agent(true)

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

var navigationToggle = false
var cursorPosition = Vector3.ZERO
func on_cursor_click(cursorPos):
	cursorPosition = cursorPos
	navAgent.set_target_position(cursorPos)
	navigationToggle = true
	print("click signal recieved")
	
var activeCamera: PlayerCamera3D
##sets the current viewport camera as the active camera. Needs refactoring later on once camera transitions are implemented
func set_active_camera()-> void:
	activeCamera = get_viewport().get_camera_3d()


var destination = Vector3.ZERO
var local_destination = Vector3.ZERO
var aiDirection = Vector3.ZERO
func _physics_process(delta: float) -> void:
	if navigationToggle == true: #only update variables if actively navigating. Not sure if it'll break stuff later, but works for now
		destination = navAgent.get_next_path_position()
		local_destination = destination - pawn.global_position #turns out where you're going minus where you are equals the vector towards there in vector math
		aiDirection = local_destination.normalized()
	var hAiDirection = Vector3(aiDirection.x,0,aiDirection.z)
	
	#if nav is done but still toggled on
	if navAgent.is_navigation_finished() and navigationToggle == true:
		reset_navigation()
		controllerManager.request_move_command(hAiDirection, self)
	elif navigationToggle == true:
		controllerManager.request_move_command(hAiDirection, self)
		
	if pawn.goPrint:
		print("nTog: ", navigationToggle)
	
func reset_navigation()->void:
	navigationToggle = false #toggle navigation off
	navAgent.set_target_position(pawn.global_position) #reset target position to ensure stoppage
