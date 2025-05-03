extends ControllerComponentBase
class_name PlayerControllerComponent

@onready var inputDirection = Vector3.ZERO


@export var sprint_multiplier: float = 2.5 ##multiplier to speed and acceleration when spriting
@export var apex_velocity: float = .2
@export var apex_gravity_multiplier: float = 0.675
@export var fall_gravity_multiplier: float = 1.35
@export var max_fall_time: float = 5 ##the maximum number of seconds fall gravity is applied to the pawn
@export var jump_deceleration_multiplier: float = .4 ##set upward velocity by this factor after releasing jump button
@export var jump_cooldown: float = .3334 ##cooldown in seconds
@export var coyote_time: float = .1125 ##grace period to jump after falling
var canJump = false
var coyoteTimer: float = coyote_time #current coyote time
var jumpTimer: float = jump_cooldown
var baseSpd: float
var baseAcl: float
var baseGrav: float 

func _ready() -> void:
	inputPriority = 0 #sets input priority to highest
	#print("playercontroller ready")
	if !Pawn:
		set_physics_process(false)
		print("PlayerMovementController failed to initialize!")
	baseSpd = Pawn.speed
	baseAcl = Pawn.acceleration
	baseGrav = Pawn.gravity
	

#physics process extension
func _physics_process(delta: float) -> void:
	is_sprinting(Input.is_action_pressed("move_sprint")) #sprint code
	poll_input_direction() # gets horizontal directional movement inputs and sets it to the input direction variable
	if not inputDirection.is_zero_approx(): #if there are inputs
		controllerManager.request_move_command(input_camera_yaw_adjustment(inputDirection), self) #sends request for movement to controller manager with saved input directions
	else:
		controllerManager.request_move_command(Vector3.ZERO, self) #sends request for NO movemet input if inputs given are near ZERO. Just an extra error checking step
	jump_handler(delta) #apply all jump logic
	jump_variable_gravity(true)
	

##get inputs to set the input direction and normalize it
func poll_input_direction():
	#get horizontal input direciton and normalize
	inputDirection.x = Input.get_action_strength("move_right") - Input.get_action_strength("move_left")
	inputDirection.z = Input.get_action_strength("move_backward") - Input.get_action_strength("move_forward")
	inputDirection = inputDirection.normalized()
	
##jump checker logic using coyote time and jump cooldown
##[param delta] needed to decrement timers
func can_jump(delta) -> bool: 
	canJump = false #can't jump by default
	#decrement timers and clamp
	coyoteTimer -= delta
	jumpTimer -= delta
	clampf(coyoteTimer, 0.0, coyote_time)
	clampf(jumpTimer, 0.0 , jump_cooldown)
	 
	if Pawn.is_on_floor(): #reset coyote time if on floor
		coyoteTimer = coyote_time
	
	if not Pawn.is_on_floor() and coyoteTimer > 0 and jumpTimer <= 0: 
		canJump = true #can only jump if (1)not on floor, w/ coyote time, AND jump off cooldown 
	elif Pawn.is_on_floor() and jumpTimer <= 0: 
		canJump = true	#(2) on floor AND jump off cooldown
	return canJump

##sprinting code. Might need a refactor but works as implemented for now
func is_sprinting(isSprinting: bool)->void:
	Pawn.speed = baseSpd
	Pawn.acceleration = baseAcl
	if isSprinting:
		Pawn.speed *= sprint_multiplier #increase max speed of pawn by the multiplier. Does not hard reset momentum when sprint is deactivated
		Pawn.acceleration *= sprint_multiplier #increased acceleration rate of pawn by the multiplier.

var isJumping: bool = false #bool utilized in variable jump gravity code. Differentiates between simple falling and jumping
##jump logic code for jump validity, cooldown, coyote time, and input handling. Takes [param delta] as its meant to run during _physics_process()
func jump_handler(delta)->void:
	can_jump(delta) #check if can jump
	#print("canJump?: ", canJump, " cTmr: ", coyoteTimer, " jTmr: ", jumpTimer)
	if isJumping and Pawn.is_on_floor():
		isJumping = false
	if Input.is_action_just_pressed("move_jump") and canJump:
		Pawn.velocity.y += Pawn.jump_velocity
		isJumping = true 
		coyoteTimer = 0
		jumpTimer = jump_cooldown
	if Input.is_action_just_released("move_jump"):
		var wtt = (jump_cooldown-jumpTimer)/jump_cooldown
		wtt = clampf(wtt,0,1)
		#pawn.velocity.y *= lerpf(jump_deceleration_multiplier,1,wtt)
		#print(wtt)
	

##returns vector to add to input direction based on the camera's rotation by yaw 
func input_camera_yaw_adjustment(iDir)->Vector3:
	var newIDir = Vector3.ZERO
	if Pawn.isPossessed and Pawn.isCommandedMovement:
		if Pawn.cameraControllerArm:
			var cameraYawRotRads = Pawn.cameraControllerArm.rotation.y
			newIDir = inputDirection.rotated(Vector3.UP,cameraYawRotRads)
		else:
			if GlobalTools.go_print: print("control arm invalid ", Pawn.cameraControllerArm)
	elif not Pawn.isPossessed and Pawn.isCommandedMovement:
		var cameraYawRotRads = Pawn.activePlayerCamera.rotation.y
		newIDir = inputDirection.rotated(Vector3.UP,cameraYawRotRads)

	else:
		newIDir = iDir
	return newIDir

func jump_variable_gravity(toggle:bool):
	if toggle:
		if Pawn.velocity.y < apex_velocity and Pawn.velocity.y >= 0 and isJumping:
			Pawn.gravity = baseGrav * apex_gravity_multiplier
		elif Pawn.velocity.y < 0 and isJumping:
			Pawn.gravity = baseGrav * fall_gravity_multiplier
		else:
			Pawn.gravity = baseGrav
		if Pawn.velocity.y < baseGrav * max_fall_time * -1:
			Pawn.velocity.y = baseGrav * max_fall_time * -1
