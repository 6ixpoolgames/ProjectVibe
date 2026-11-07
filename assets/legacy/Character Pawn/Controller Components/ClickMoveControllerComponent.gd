extends ControllerComponentBase
class_name ClickToMoveComponent
 
var activeCamera: PlayerCamera3D

#func _enter_tree() -> void:
#	super()
	

func _ready()->void:
	if not pawn is CharacterPawn3D or !pawn: #must be controlled by a pawn
		printerr("pawn is not a pawn ", self)
		set_physics_process(false)
	activeCamera = get_viewport().get_camera_3d()
	if !activeCamera:#must have a PlayerCamera3D in the scene to handle cursor inputs
		printerr("camera is not a camera: ", activeCamera)
	#connects signals
	activeCamera.emit_3D_cursor_position.connect(_on_cursor_click)
	activeCamera.possession_event.connect(_set_active_camera)
	_create_nav_agent(true)
	isReady = true


func _physics_process(_delta: float) -> void:
	if isReady:
		_pawn_navigation()


 

##sets the current viewport camera as the active camera. Needs refactoring later on once camera transitions are implemented
func _set_active_camera(_emitter)-> void:
	activeCamera = get_viewport().get_camera_3d()

var lastTargetPosition = Vector3.ZERO
##test function signal reciever for setting the clicked position to the movement target of the pawn. Needs to be expanded later to include checks for if the pawn is actively selected and which command is being given to it (other than movement).
##[param cursor3DPos] the world position of the 3D cursor passed from the emitted signal.
func _on_cursor_click(cursor3DPos):
	lastTargetPosition = cursor3DPos
	move_to(cursor3DPos)
	print("click signal recieved", pawn, " dest:",cursor3DPos)
	
var navigationToggle = false
func move_to(dest: Vector3)->void:
	nexus.controllerNavAgent3D.set_target_position(dest)
	navigationToggle = true
	print("--- Target pos:", dest, " pawn: ", pawn)
	
var destination = Vector3.ZERO
var local_destination = Vector3.ZERO
var aiDirection = Vector3.ZERO
##called each frame to handle navAgent movement. Runs if navigationToggle flag is TRUE. If is_navigation_finished() is TRUE, calls stop_navigation() automatically
func _pawn_navigation()->void:
	var hAiDirection = Vector3.ZERO
	if navigationToggle == true: #only update variables if actively navigating. Not sure if it'll break stuff later, but works for now
		destination = nexus.controllerNavAgent3D.get_next_path_position()
		local_destination = destination - pawn.global_position #turns out where you're going minus where you are equals the vector towards there in vector math
		aiDirection = local_destination.normalized()
		hAiDirection = Vector3(aiDirection.x,0,aiDirection.z)
	#if nav is done but still toggled on
	if nexus.controllerNavAgent3D.is_navigation_finished() and navigationToggle == true:
		stop_navigation()
		controllerManager.request_move_command(hAiDirection, self)
	elif navigationToggle == true:
		controllerManager.request_move_command(hAiDirection, self)
		
##stops navigation by setting navigationToggle flag to FALSE and setting the nav target position to pawn's current position
func stop_navigation()->void:
	navigationToggle = false #toggle navigation off
	nexus.controllerNavAgent3D.set_target_position(pawn.global_position) #reset target position to ensure stoppage
