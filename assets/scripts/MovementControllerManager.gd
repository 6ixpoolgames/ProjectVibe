extends Node3D
class_name MovementControllerManager

var pawn: CharacterPawn3D
var isInit: bool = false

@export var addPlayerController = false ##debug function for creating and attaching player controllers to the pawn at ready
@export var addClickController = false ##debug function for creating and attaching click to move controller to the pawn at ready
@export var hasAIController = false
@export var spawnDebugControllers = false

func _ready():
	#check if properly attached
	pawn = self.get_parent()
	if pawn == null or not pawn is CharacterPawn3D: #improper if NULL or parent NOT CharacterPawn3D
		isInit = false
		print("Movement controller initialization error! ", self, " p: " , pawn)
	else: #if properly attached
		isInit = true
		if spawnDebugControllers:
			create_and_attach_player_controllers() # yes the long name means its a test function lol
	get_controllers_attached()

var controllersAttached: Array[ControllerComponentBase]
##gets an array of attached controllers to the manager
func get_controllers_attached()->void:
	controllersAttached.clear()
	var children = get_children()
	for c in children:
		if c is ControllerComponentBase:
			controllersAttached.append(c)
		
##test function that creates player controllers for the movement controller
func create_and_attach_player_controllers()->void:
	#currently hardcoded to attach a player controller by default. Will modify later to accept a controller programatically
	if addPlayerController:
		var controller = PlayerControllerComponent.new()
		controller.name = "PlayerControllerComponent"
		add_child(controller)
		print("controller attached: ", controller)
	#also a hardcoded attachment of click to move controller
	if addClickController:
		var controller2 = ClickToMoveComponent.new()
		controller2.name = "ClickToMoveComponent"
		add_child(controller2)
		print("controller2 attached: ", controller2)

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
func assess_request_priority()->int:
	var lastPriority:int = 255 #default lowest priority
	var priorityControllerIndex:int = -1
	var i = 0
	for c in conBuffer:
		if c.inputPriority <= lastPriority and not iDirBuffer[i].is_zero_approx(): #gets the highest priority controller with an input
			lastPriority = c.inputPriority
			priorityControllerIndex = i
		i += 1
	return priorityControllerIndex

func _physics_process(_delta: float) -> void:
	var commandIndex = assess_request_priority()
	if assess_request_priority() == -1: #if no controllers giving inputs, give no input commands 
		pawn.give_move_command(Vector3.ZERO) #(zero iDir is treated as no commands by the pawn)
	elif not commandIndex < 0 and pawn is CharacterPawn3D and pawn != null: #if has command queued up, AND manager is attached to a pawn (checked 2 ways)
		playerInputOverride(commandIndex) #checks to see if controller giving command is manual player controller -> will abort Nav Agent based movement
		pawn.give_move_command(iDirBuffer[commandIndex]) 
	clear_move_requests()

##overrides click to move navigation if a playercontroller provides an input
func playerInputOverride(cmdIdx):
	if conBuffer[cmdIdx] is PlayerControllerComponent: #if greatest priority controller is a manual player controller
		for c in controllersAttached:
			if c is ClickToMoveComponent:
				c.stop_navigation() #gives stop navigation command to all click to move components
