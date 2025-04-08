extends Node3D
class_name MovementController

@export var speed: float = 5 #max speed
@export var acceleration: float = 20 #accel on move input
@export var deceleration: float = 50 #decel when input released
@export var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")
@export var controllerScript: Script
@onready var inputDirection = Vector2.ZERO
@onready var moveDirection = Vector2.ZERO
func _ready():
	if controllerScript:
		set_script(controllerScript)
		print("script set: ", get_script().resource_path)
	else:
		printerr("null or invalid controller script")
