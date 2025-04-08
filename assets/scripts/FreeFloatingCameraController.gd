extends PlayerCamera3D

@export var speed: float = 10

@onready var inputDirection = Vector3.ZERO


func _physics_process(delta: float) -> void:
	#get horizontal direciton and normalize
	inputDirection.x = Input.get_action_strength("move_right") - Input.get_action_strength("move_left")
	inputDirection.z = Input.get_action_strength("move_backward") - Input.get_action_strength("move_forward")
	#inputDirection.y = Input.get_action_strength("move_upward") - Input.get_action_strength("move_downward")
	inputDirection.normalized()
	
	#this is a test part infinidades
