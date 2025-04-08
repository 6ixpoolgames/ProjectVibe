extends Node3D

@onready var body = get_parent() as CharacterBody3D

@export var speed: float = 5 #max speed
@export var acceleration: float = 20 #accel on move input
@export var deceleration: float = 50 #decel when input released
@export var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")
@export var jumpVelocity: float = 4 #jump power
@export var jumpCooldown: float = .33
@export var airControl: float = 0.66
@export var coyote_time: float = 0.1 #grace period to jump after falling
var coyote_timer: float = 0 #current coyote time
var jumpTimer: float = 0
var hDirection = Vector2.ZERO

func _physics_process(delta):
	#safety code at instantiantion MUST BE CHILD OF CHARCTERBODY3D
	if not body:
		return
	
	#get horizontal direciton and normalize
	hDirection.x = Input.get_action_strength("move_right") - Input.get_action_strength("move_left")
	hDirection.y = Input.get_action_strength("move_backward") - Input.get_action_strength("move_forward")
	if hDirection != Vector2.ZERO:
		hDirection = hDirection.normalized()
		
	#move horizontally with smooth acceleration/decceleration
	var airCont:float = 1 if body.is_on_floor() else airControl
	if hDirection.x != 0:
		body.velocity.x = move_toward(body.velocity.x, speed * hDirection.x, acceleration * delta * airCont)
	else:
		body.velocity.x = move_toward(body.velocity.x, 0, deceleration * delta * airCont)
	if hDirection.y !=0:
		body.velocity.z = move_toward(body.velocity.z, speed * hDirection.y, acceleration * delta * airCont)
	else:
		body.velocity.z = move_toward(body.velocity.z, 0, deceleration * delta* airCont)
	
	#gravity and jump logic

	jumpTimer -= delta 
	jumpTimer = clamp(jumpTimer, 0, jumpCooldown)	
	if  body.is_on_floor():
		coyote_timer = coyote_time
	else:
		body.velocity.y -= gravity * delta
		coyote_timer -= delta
	if coyote_timer > 0 and jumpTimer == 0 and Input.is_action_just_pressed("move_jump"):
		body.velocity.y = jumpVelocity
		coyote_timer = 0
		jumpTimer = jumpCooldown
	if Input.is_action_just_released("move_jump") and body.velocity.y > 0:
		body.velocity.y *= .4
	
	#debug prints
	#if body.is_on_floor():
	#	print("On floor, Jump Timer: ", jumpTimer)
	#else:
	#	print("In air, Coyote Timer: ", coyote_timer, "Jump Timer: ", jumpTimer)		
	#	print("aircontrol= ", str(airCont))
	
	#apply movement
	body.move_and_slide()

func _get_hDirection(hDir: float):
	hDir = hDirection
