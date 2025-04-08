class_name CharacterPawn3D
extends CharacterBody3D

@onready var CharacterModel: MeshInstance3D = $CharacterModel

@export var speed: float = 5 #max speed
@export var acceleration: float = 20 #accel on move input
@export var deceleration: float = 50 #decel when input released
@export var gravity_multiplier: float = 1
@export var turn_speed_yaw: float = 720 #rotation speed in deg/sec
@export var turn_speed_pitch: float = 720 #rotation speed in deg/sec
@export var turn_speed_tilt: float = 720 #rotation speed in deg/sec
@export var jump_velocity: float = 5 #jump power
@export var air_control: float = 0.66
@export var is_floating: bool = false
var isCommandedMovement: bool = false
var gravity: float  = ProjectSettings.get_setting("physics/3d/default_gravity")
var moveDirection = Vector3.ZERO


#model rotation variables
var targetYaw: float = 0
var targetPitch: float = 0
var targetTilt: float = 0
var lastInputRotationYaw: float = targetYaw
var lastInputRotationPitch: float = targetPitch
var lastInputRotationTilt: float = targetTilt

var activeCamera: Camera3D
func _ready():
	activeCamera = get_viewport().get_camera_3d()
	activeCamera.connect("possession_event", _on_possession_event)
	print(activeCamera)
	
func _physics_process(delta: float) -> void:
	printFuncRationalizer(90)
	yaw_to_facing(delta)
	apply_gravity(delta)
	move_in_direction(moveDirection, delta)
	move_and_slide()
	
	
## apply velocity for movement in a target direction of vector3.
## param moveDir: vector3 direction
## param delta: the time delta, either from _physics_process, or _process
func move_in_direction(moveDir: Vector3, delta: float) -> void:
	moveDir.normalized()
	var airCont = 1.0 if is_on_floor() else air_control #Apply aircontrol modifier when not on the ground
	if is_floating:     #does not exclude Y axis for floating pawns
		if isCommandedMovement == true:
			velocity = velocity.move_toward(speed * moveDir, acceleration * delta * airCont)          
		else:  # Decelerate when no input
			velocity = velocity.move_toward(Vector3.ZERO, deceleration * delta * airCont)
	else:	#excludes Y axis for floating pawns
		if isCommandedMovement == true:             
			velocity.x = move_toward(velocity.x, speed * moveDir.x, acceleration * delta * airCont)
			velocity.z = move_toward(velocity.z, speed * moveDir.z, acceleration * delta * airCont)
		else:  # Decelerate when no input
			velocity.x = move_toward(velocity.x, 0, deceleration * delta * airCont)
			velocity.z = move_toward(velocity.z, 0, deceleration * delta * airCont)
	#print("movDir: ", moveDir, " vel: ", velocity)
	
	
##function to set the move direction, designed to be called from the controller script or elsewhere every (physics)frame
##@param inputDirection direction of desired movement
func give_move_command(inputDir:Vector3)-> void:
	if inputDir != Vector3.ZERO: #if with inputs
		moveDirection = inputDir
		isCommandedMovement = true
	else:
		moveDirection = Vector3.ZERO
		isCommandedMovement = false

##apply gravity every tick, with coyote time code. Possibly refactor this
func apply_gravity(delta:float):
	velocity.y -= gravity * gravity_multiplier * delta		
		
##gets a reference to the pawn's springArm3D. If null for some reason, returns a reference to self
func get_camera_attachment_point():
	var attachTo
	if $SpringArm3D != null:
		attachTo = $SpringArm3D
	else:
		attachTo = self
	return attachTo

##rotates character model to target facing with yaw
func yaw_to_facing(delta: float)->void:
	var currRot = CharacterModel.rotation.y
	lastInputRotationYaw = currRot
	#target is movement direction if commanded, else is last input
	if isCommandedMovement: 
		targetYaw = atan2(moveDirection.x * -1, moveDirection.z * -1)
	else:
		targetYaw = lastInputRotationYaw
	#math for lerp weight as factor of turn speed over distance to rotate
	var dist = abs(wrapf(targetYaw - currRot, -PI, PI)) #wrap around angles
	var wt = clamp((deg_to_rad(turn_speed_yaw) * delta) / dist, 0.0, 1.0) if dist > 0.001 else 1.0 # if statement to stop turn locking
	#apply rotation
	CharacterModel.rotation.y = lerp_angle(currRot, targetYaw, wt)



var isPossessed = false
#sets isPossessed to TRUE if 
func _on_possession_event(emitter)->void:
	var children = get_children()
	activeCamera = get_viewport().get_camera_3d()
	isPossessed = false
	for child in children.size():
		if children[child] == activeCamera:
			isPossessed = true
		#print(child," child: ", children[child], " camera ", activeCamera," isPossessed ", isPossessed)
		var subChildren = children[child].get_children()
		for subChild in subChildren.size():
			if subChildren[subChild] == activeCamera:
				isPossessed = true
			#print(subChild, "subC: ", subChildren[subChild]," camera ", activeCamera," isPossessed ", isPossessed)
			var sub2Children = subChildren[subChild].get_children()
			for sub2Child in sub2Children.size():
				if sub2Children[sub2Child] == activeCamera:
					isPossessed = true
	print("signal recieved ", isPossessed)


var printTimer: int = -1
var goPrint: bool = false
##counts down printTime number of frames before setting "goPrint" to true, sets it to false every other frame
##to apply, just add "if goPrint:" before calling a debug print output to 'rationalize' it
func printFuncRationalizer(printTime: int):
	if printTimer > 0:
		printTimer -= 1
		goPrint = false
	else:
		printTimer = printTime
		goPrint = true
