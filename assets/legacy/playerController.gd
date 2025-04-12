extends MovementController

@export var jumpVelocity: float = 5 #jump power
@export var jumpCooldown: float = .33
@export var turnSpeedYaw: float = 12.5
@export var airControl: float = 0.66
@export var coyoteTime: float = 0.1 #grace period to jump after falling

#camera control variables
var currentYaw: float = 0
var lastInputRotation: float = currentYaw

#jump logic variables
var coyoteTimer: float = 0 #current coyote time
var jumpTimer: float = 0
var physicsDelta: float = 0

#pathfinding variables
var destination = Vector3.ZERO
var local_destination = Vector3.ZERO
var aiDirection = Vector3.ZERO

var goto = Vector3.ZERO
var gotoWalkerOn: bool = false

@onready var body = get_parent() as CharacterBody3D
@onready var cameraArm = $"../SpringArm3D" as SpringArm3D
@onready var navAgent3D: NavigationAgent3D = $"../NavigationAgent3D"

@onready var tolerance = navAgent3D.target_desired_distance/2

func _physics_process(delta):
	#safety code at instantiantion MUST BE CHILD OF CHARCTERBODY3D
	if not body:
		printerr("not attached to CharacterBody3D")
		return

#click to walk
	if Input.is_action_just_pressed("left_click"):
		goto = cameraArm.get_3D_cursor_world_position()
		navAgent3D.set_target_position(goto)
		gotoWalkerOn = true
		
	destination = navAgent3D.get_next_path_position()
	local_destination = destination - global_position #turns out where you're going minus where you are equals the vector towards there in vector math
	aiDirection = local_destination.normalized()


	#get horizontal direciton and normalize
	inputDirection.x = Input.get_action_strength("move_right") - Input.get_action_strength("move_left")
	inputDirection.y = Input.get_action_strength("move_backward") - Input.get_action_strength("move_forward")
	
	#makes character face where camera is pointed when no movement inputs
	if inputDirection == Vector2.ZERO:
		lastInputRotation = cameraArm.rotation.y + PI
	
	if inputDirection != Vector2.ZERO: #if no directional inputs
		#add camera rotation to move direction
		inputDirection = inputDirection.normalized()
		moveDirection.x = cos(atan2(inputDirection.y, inputDirection.x) -cameraArm.rotation.y)
		moveDirection.y = sin(atan2(inputDirection.y, inputDirection.x) -cameraArm.rotation.y)
		moveDirection.normalized()
		navAgent3D.set_target_position(global_position) #stop navigating if with input
	else: #with directional inputs
		#move direction is AI direction, which should be just about zero if not navigating
		moveDirection.x = aiDirection.x
		moveDirection.y = aiDirection.z
	
		
	
	#move horizontally with smooth acceleration/decceleration
	var airCont = 1.0 if body.is_on_floor() else airControl #Apply aircontrol modifier when not on the ground
	body.velocity.x = move_toward(body.velocity.x, speed * moveDirection.x, acceleration * delta * airCont)
	body.velocity.z = move_toward(body.velocity.z, speed * moveDirection.y, acceleration * delta * airCont)
	if inputDirection == Vector2.ZERO and navAgent3D.is_navigation_finished():  # Decelerate when no input
		body.velocity.x = move_toward(body.velocity.x, 0, deceleration * delta * airCont)
		body.velocity.z = move_toward(body.velocity.z, 0, deceleration * delta * airCont)
	
	#apply movement
	body.move_and_slide()
	physicsDelta = delta
	
	#spams navigation calls to "motivate" the nav agent to traverse sticky spots
	if navAgent3D.is_navigation_finished():
		goto = Vector3.ZERO
		gotoWalkerOn = false
	else:
		goto_random_walker(tolerance)
		
	#gravity and jump logic
	jumpTimer -= delta 
	jumpTimer = clamp(jumpTimer, 0, jumpCooldown)	
	if  body.is_on_floor():
		coyoteTimer = coyoteTime
	else:
		body.velocity.y -= gravity * delta
		coyoteTimer -= delta
	if coyoteTimer > 0 and jumpTimer == 0 and Input.is_action_just_pressed("move_jump"):
		body.velocity.y += jumpVelocity
		coyoteTimer = 0
		jumpTimer = jumpCooldown
	if Input.is_action_just_released("move_jump") and body.velocity.y > 0:
		body.velocity.y *= .4

var frameTime: int = 45
var frameTimer: int = frameTime
func goto_random_walker(tolerance:float):
	frameTimer -= 1
	if not navAgent3D.is_navigation_finished() and frameTimer == 0:
		goto.x += randf()*(tolerance*.4)
		goto.y += randf()*(tolerance*.4)
		goto.z += randf()*(tolerance*.4)
		navAgent3D.set_target_position(goto)
		frameTimer = frameTime
	print("click ", frameTimer)

func get_inputDirection() -> Vector2:
	return inputDirection

func get_rotationYaw() -> float:
	var targetYaw = 0
	if inputDirection != Vector2.ZERO or not navAgent3D.is_navigation_finished():
		targetYaw = atan2(moveDirection.x,moveDirection.y)
	else:
		targetYaw = lastInputRotation
	"""
	if inputDirection == Vector2.ZERO and navAgent3D.is_navigation_finished():
		targetYaw = lastInputRotation
	else:
		targetYaw = atan2(moveDirection.x,moveDirection.y)
	"""
	var newYaw = lerp_angle(currentYaw, targetYaw, turnSpeedYaw * physicsDelta)
	currentYaw = newYaw
	
	#print("camR: ",cameraArm.rotation.y, " curR: ", currentYaw, " tarR: ", targetYaw," lIR: ", lastInputRotation)
	return currentYaw
