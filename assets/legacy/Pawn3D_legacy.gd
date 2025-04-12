class_name CharacterPawn3D_legacy
extends CharacterBody3D

@export var speed: float = 5 #max speed
@export var acceleration: float = 20 #accel on move input
@export var deceleration: float = 50 #decel when input released
@export var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")
@export var controllerScript: Script
@export var jumpVelocity: float = 5 #jump power
@export var jumpCooldown: float = .33
@export var turnSpeedYaw: float = 12.5
@export var airControl: float = 0.66
@export var coyoteTime: float = 0.1 #grace period to jump after falling

@onready var moveDirection = Vector3.ZERO

#camera control variables
var currentYaw: float = 0
var lastInputRotation: float = currentYaw

#jump logic variables
var coyoteTimer: float = 0 #current coyote time
var jumpTimer: float = 0
var physicsDelta: float = 0

var isCommandedMovement: bool = false

#func _ready():
	#if controllerScript:
	#	set_script(controllerScript)
	#	print("script set: ", get_script().resource_path)
	#else:
	#	printerr("null or invalid controller script")


func _physics_process(delta: float) -> void:
	move_in_direction(moveDirection, delta)
	move_and_slide()
	
	
##apply velocity for movement in a target direction of vector3.
##@moveDirection vector3 direction
##@delta the time delta, either from _physics_process, or _process
##@return the updated velocity of the Pawn3D body
func move_in_direction(moveDirection: Vector3, delta: float):
	#move horizontally with smooth acceleration/decceleration
	var airCont = 1.0 if is_on_floor() else airControl #Apply aircontrol modifier when not on the ground
	velocity.x = move_toward(velocity.x, speed * moveDirection.x, acceleration * delta * airCont)            #sideways
	velocity.z = move_toward(velocity.z, speed * moveDirection.y, acceleration * delta * airCont)            #forwards/backwards
	velocity.y = move_toward(velocity.y, speed * moveDirection.y, acceleration * delta * airCont)            #up/down
	if isCommandedMovement == false:  # Decelerate when no input
		velocity.x = move_toward(velocity.x, 0, deceleration * delta * airCont)                              #sideways
		velocity.z = move_toward(velocity.z, 0, deceleration * delta * airCont)                              #forwards/backwards
		velocity.y = move_toward(velocity.y, 0, deceleration * delta * airCont)                              #up/down


##function to set the move direction, designed to be called from the controller script or elsewhere every (physics)frame
##@inputDirection direction of desired movement
func give_move_command(inputDirection:Vector3):	
	if inputDirection != Vector3.ZERO: #if with inputs
		moveDirection = inputDirection
		isCommandedMovement = true
	else:
		moveDirection = Vector3.ZERO
		isCommandedMovement = false
		
		
##gets a reference to the pawn's springArm3D. If null for some reason, returns a reference to self
func getRef_springArm3D():
	var attachTo
	if $SpringArm3D != null:
		attachTo = $SpringArm3D
	else:
		attachTo = self
	return $SpringArm3D
