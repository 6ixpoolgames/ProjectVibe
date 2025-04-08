extends Node3D

@onready var controller: MovementController = $"../MovementController"
var delay = 10
var inputDirection = Vector2.ZERO

func _physics_process(delta: float) ->void:	
	if not controller:
		printerr("No controller found for model rotator")
		return
	
	#gets direction and rotates model 
	#hDirection = controller.get_hDirection()
	#if hDirection != Vector2.ZERO:
	#	var targetYaw = atan2(hDirection.x, hDirection.y)
	#	var currentYaw = rotation.y
	#	newYaw = lerp_angle(currentYaw, targetYaw, controller.rotationSpeedYaw*delta)

	#rotation  = Vector3(0,newYaw,0)
	rotation  = Vector3(0,controller.get_rotationYaw(),0)
