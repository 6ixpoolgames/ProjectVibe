extends Node3D

@onready var controller: MovementController = $"../MovementController"
var delay: int = 10
var hDirection := Vector2.ZERO
var newYaw: float = 0.0

func _physics_process(delta: float) -> void:
	if not controller:
		printerr("No controller found for model rotator")
		return
	
	if not controller.is_node_ready():
		printerr("Controller not ready yet")
		return
	
	if not controller.has_method("get_hDirection"):
		printerr("get_hDirection() not found on controller")
		return
	
	if delay > 0:
		delay -= 1
		return
	
	hDirection = controller.get_hDirection()
	if hDirection != Vector2.ZERO:
		var targetYaw = atan2(-hDirection.x, -hDirection.y)
		var currentYaw = rotation.y
		newYaw = lerp_angle(currentYaw, targetYaw, controller.rotationSpeed * delta)
		rotation = Vector3(0, newYaw, 0)
