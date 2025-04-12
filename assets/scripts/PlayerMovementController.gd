extends CharacterPawn3D

@onready var inputDirection = Vector3.ZERO

@export var sprint_multiplier: float = 2.5 ##multiplier to speed and acceleration when spriting
@export var jump_deceleration_multiplier: float = .4 ##set upward velocity by this factor after releasing jump button
@export var jump_cooldown: float = .3334 ##cooldown in seconds
@export var coyote_time: float = .1125 ##grace period to jump after falling
var canJump = false
var coyoteTimer: float = coyote_time #current coyote time
var jumpTimer: float = jump_cooldown
var baseSpd: float = speed
var baseAcl: float = acceleration

#physics process extension
func _physics_process(delta: float) -> void:
	is_sprinting(Input.is_action_pressed("move_sprint"))
	set_input_direction()
	give_move_command(input_camera_yaw_adjustment(inputDirection)) #apply movement inputs 
	jump_handler(delta) #apply all jump logic
	super._physics_process(delta) #run movement code in CharacterPawn3D physics process code

##get inputs to set the input direction and normalize it
func set_input_direction():
	#get horizontal input direciton and normalize
	inputDirection.x = Input.get_action_strength("move_right") - Input.get_action_strength("move_left")
	inputDirection.z = Input.get_action_strength("move_backward") - Input.get_action_strength("move_forward")
	inputDirection.normalized()


##jump checker logic using coyote time and jump cooldown
##@param delta needed to decrement timers
func can_jump(delta) -> bool: 
	canJump = false #can't jump by default
	#decrement timers and clamp
	coyoteTimer -= delta
	jumpTimer -= delta
	clampf(coyoteTimer, 0.0, coyote_time)
	clampf(jumpTimer, 0.0 , jump_cooldown)
	 
	if is_on_floor(): #reset coyote time if on floor
		coyoteTimer = coyote_time
	
	if not is_on_floor() and coyoteTimer > 0 and jumpTimer <= 0: 
		canJump = true #can only jump if (1)not on floor, w/ coyote time, AND jump off cooldown 
	elif is_on_floor() and jumpTimer <= 0: 
		canJump = true	#(2) on floor AND jump off cooldown
	return canJump

func is_sprinting(isSprinting: bool)->void:
	speed = baseSpd
	acceleration = baseAcl
	if isSprinting:
		speed *= sprint_multiplier
		acceleration *= sprint_multiplier
	
func jump_handler(delta)->void:
	can_jump(delta) #check if can jump
	#print("canJump?: ", canJump, " cTmr: ", coyoteTimer, " jTmr: ", jumpTimer)
	if Input.is_action_just_pressed("move_jump") and canJump:
		velocity.y += jump_velocity 
		
		coyoteTimer = 0
		jumpTimer = jump_cooldown
		print("jump!")
	if Input.is_action_just_released("move_jump"):
		var wtt = (jump_cooldown-jumpTimer)/jump_cooldown
		wtt = clampf(wtt,0,1)
		velocity.y *= lerpf(jump_deceleration_multiplier,1,wtt)
		print(wtt)

@onready var springArmRef = $SpringArm3D
##returns vector to add to input direction based on the camera's rotation by yaw 
func input_camera_yaw_adjustment(iDir)->Vector3:
	var newIDir = Vector3.ZERO
	if isPossessed and isCommandedMovement:
		var cameraYawRotRads = springArmRef.rotation.y
		newIDir = inputDirection.rotated(Vector3.UP,cameraYawRotRads)
		#if goPrint:
			#print("rotAdd: ", rad_to_deg(cameraYawRotRads), " mDir: ", moveDirection)
	else:
		newIDir = iDir
	return newIDir
