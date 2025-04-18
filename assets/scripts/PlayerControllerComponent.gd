extends ControllerComponentBase
class_name PlayerControllerComponent

@onready var inputDirection = Vector3.ZERO

@export var sprint_multiplier: float = 2.5 ##multiplier to speed and acceleration when spriting
@export var jump_deceleration_multiplier: float = .4 ##set upward velocity by this factor after releasing jump button
@export var jump_cooldown: float = .3334 ##cooldown in seconds
@export var coyote_time: float = .1125 ##grace period to jump after falling
var canJump = false
var coyoteTimer: float = coyote_time #current coyote time
var jumpTimer: float = jump_cooldown
var baseSpd: float
var baseAcl: float

func _ready() -> void:
	super()
	inputPriority = 0 #sets input priority to highest
	print("playercontroller ready")
	if pawn == null or not pawn is CharacterPawn3D:
		print("PlayerMovementController failed to initialize!")
	baseSpd = pawn.speed
	baseAcl = pawn.acceleration

var toggleOnce = false
#physics process extension
func _physics_process(delta: float) -> void:
	
	is_sprinting(Input.is_action_pressed("move_sprint"))
	set_input_direction()
	if not inputDirection.is_zero_approx(): #if there are inputs
		controllerManager.request_move_command(input_camera_yaw_adjustment(inputDirection), self) #apply movement inputs 
	else:
		controllerManager.request_move_command(Vector3.ZERO, self)
	jump_handler(delta) #apply all jump logic

	#debug trace to check if physics process is properly running
	if not toggleOnce:
		toggleOnce = true
		print("------------ all is set ----------------")
		
##get inputs to set the input direction and normalize it
func set_input_direction():
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
	 
	if pawn.is_on_floor(): #reset coyote time if on floor
		coyoteTimer = coyote_time
	
	if not pawn.is_on_floor() and coyoteTimer > 0 and jumpTimer <= 0: 
		canJump = true #can only jump if (1)not on floor, w/ coyote time, AND jump off cooldown 
	elif pawn.is_on_floor() and jumpTimer <= 0: 
		canJump = true	#(2) on floor AND jump off cooldown
	return canJump

func is_sprinting(isSprinting: bool)->void:
	pawn.speed = baseSpd
	pawn.acceleration = baseAcl
	if isSprinting:
		pawn.speed *= sprint_multiplier
		pawn.acceleration *= sprint_multiplier
	
func jump_handler(delta)->void:
	can_jump(delta) #check if can jump
	#print("canJump?: ", canJump, " cTmr: ", coyoteTimer, " jTmr: ", jumpTimer)
	if Input.is_action_just_pressed("move_jump") and canJump:
		pawn.velocity.y += pawn.jump_velocity 
		coyoteTimer = 0
		jumpTimer = jump_cooldown
		#print("jump!")
	if Input.is_action_just_released("move_jump"):
		var wtt = (jump_cooldown-jumpTimer)/jump_cooldown
		wtt = clampf(wtt,0,1)
		pawn.velocity.y *= lerpf(jump_deceleration_multiplier,1,wtt)
		#print(wtt)

##returns vector to add to input direction based on the camera's rotation by yaw 
func input_camera_yaw_adjustment(iDir)->Vector3:
	var newIDir = Vector3.ZERO
	if pawn.isPossessed and pawn.isCommandedMovement:
		var cameraYawRotRads = pawn.springArmRef.rotation.y
		newIDir = inputDirection.rotated(Vector3.UP,cameraYawRotRads)
	else:
		newIDir = iDir
	return newIDir
