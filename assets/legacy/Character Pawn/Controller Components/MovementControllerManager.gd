extends Node
class_name MovementControllerManager

var pawn: CharacterPawn3D
var nexus: PawnNexusComponent
var playerController: PlayerControllerComponent
var clickMoveController: ClickToMoveComponent
var aiController: AIControllerBase

@export var addPlayerController:= false ##debug function for creating and attaching player controllers to the pawn at ready
@export var addClickController:= false ##debug function for creating and attaching click to move controller to the pawn at ready
@export var hasAIController:= false
@export var spawnDebugControllers:= false
@export var shouldCheckDuplicateControllers:= true


func _init(addPlayerCon:= addPlayerController, addClickCon:= addClickController, hasAICon:=hasAIController, spawnDebugCon:= spawnDebugControllers ) -> void:
	addPlayerController = addPlayerCon
	addClickController = addClickCon
	hasAIController = hasAICon
	spawnDebugControllers = spawnDebugCon


func _enter_tree() -> void:
	assert(get_parent() is PawnNexusComponent, "not parented to Nexus component!")
	nexus = get_parent()
	pawn = nexus.pawn
	_init_controllers(addPlayerController, addClickController, hasAIController) 
	set_physics_process(false)
	print(self," ", pawn, " has entered: ", addPlayerController, addClickController, hasAIController)


func _ready():
	#check if properly attached
	_get_controllers_attached()
	if shouldCheckDuplicateControllers:
		_check_duplicate_controllers()
		_get_controllers_attached()
	await get_tree().physics_frame
	await get_tree().physics_frame
	await get_tree().physics_frame
	set_physics_process(true)


func _physics_process(_delta: float) -> void:
	var commandIndex = _assess_request_priority()
	if _assess_request_priority() == -1: #if no controllers giving inputs, give no input commands 
		pawn.give_move_command(Vector3.ZERO) #(zero iDir is treated as no commands by the pawn)
	elif not commandIndex < 0 and pawn: #if has command queued up, AND manager is attached to a pawn (checked 2 ways)
		_playerInputOverride(commandIndex) #checks to see if controller giving command is manual player controller -> will abort Nav Agent based movement
		pawn.give_move_command(iDirBuffer[commandIndex]) 
	clear_move_requests()


var controllersAttached: Array[ControllerComponentBase]
##gets an array of attached controllers to the manager
func _get_controllers_attached()->void:
	controllersAttached.clear()
	var children = get_children()
	for c in children:
		if c is ControllerComponentBase:
			controllersAttached.append(c)
	print(pawn, " &&&& ",controllersAttached)


func _check_duplicate_controllers()->void:
	for c in controllersAttached:
		if c is AIControllerBase :
			if !aiController:
				print("controller set ", c)
				aiController = c
			elif c != aiController:
				print("freed ", c)
				c.queue_free()
		if c is ClickToMoveComponent:
			if !clickMoveController:
				print("controller set ", c)
				clickMoveController = c
			elif c != clickMoveController:
				print("freed ", c)
				c.queue_free()
		if c is PlayerControllerComponent:
			if !playerController:
				print("controller set ", c)
				playerController = c
			elif c != playerController:
				print("freed ", c)
				c.queue_free()


##test function that creates player controllers for the movement controller
func _init_controllers(addPC:bool = addPlayerController, addCC:bool = addClickController, addAI: = hasAIController)->void:
	if addPC:
		var controller = PlayerControllerComponent.new()
		controller.name = "PlayerControllerComponent"
		add_child(controller)
	if addCC:
		var controller2 = ClickToMoveComponent.new()
		controller2.name = "ClickToMoveComponent"
		add_child(controller2)
	if addAI:
		var controller3 = AIControllerBase.new()
		controller3.name = "AIControllerComponent"
		add_child(controller3)


var iDirBuffer: Array[Vector3] = []
var conBuffer: Array[ControllerComponentBase] = []
##adds a move command to the buffer. assess_request_priority() is responsible for checking which of the commands in the buffer to perform this frame.
##[param iDir] direction to command. [param controller] requesting controller.
func request_move_command(iDir: Vector3, controller: ControllerComponentBase):
	iDirBuffer.append(iDir)
	conBuffer.append(controller)


##resets request_move_command() buffer. runs each frame
func clear_move_requests():
	iDirBuffer = []
	conBuffer = []


##returns index for iDirBuffer of the controller that should be followed. if no inputs given / are in buffer, returns -1
func _assess_request_priority()->int:
	var lastPriority:int = 255 #default lowest priority
	var priorityControllerIndex:int = -1
	var i = 0
	for c in conBuffer:
		if c.inputPriority <= lastPriority and not iDirBuffer[i].is_zero_approx(): #gets the highest priority controller with an input
			lastPriority = c.inputPriority
			priorityControllerIndex = i
		i += 1
	return priorityControllerIndex


##overrides click to move navigation if a playercontroller provides an input
func _playerInputOverride(cmdIdx):
	if conBuffer[cmdIdx] is PlayerControllerComponent: #if greatest priority controller is a manual player controller
		for c in controllersAttached:
			if c is ClickToMoveComponent:
				c.stop_navigation() #gives stop navigation command to all click to move components
