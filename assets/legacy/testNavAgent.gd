extends Node3D

@onready var navAgent3D: NavigationAgent3D = $"../NavigationAgent3D"
@onready var body: CharacterBody3D = $".."
@onready var cameraArm: SpringArm3D = $"../SpringArm3D"

func _physics_process(delta: float) -> void:
	var goto = Vector3.ZERO
	if Input.is_action_just_pressed("left_click"):
		goto = cameraArm.get_3D_cursor_world_position()
		navAgent3D.set_target_position(goto)
		
	var destination = navAgent3D.get_next_path_position()
	var local_destination = destination - global_position
	var direction = local_destination.normalized
