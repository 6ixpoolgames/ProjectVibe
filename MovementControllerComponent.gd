extends Node3D
class_name MovementControllerComponent

var thisParent: CharacterPawn3D
var isInit: bool = false

func _ready():
	print("Mcon ready run!")
	thisParent = self.get_parent()
	if thisParent == null or not thisParent is CharacterPawn3D:
		isInit = false
		print("Movement controller initialization error! ", self, " p: " , thisParent)
	else:
		isInit = true
		var script = load("res://assets/scripts/PlayerMovementController.gd")
		self.set_script(script)
		print("scrpit set to: ", script)


func _physics_process(delta: float) -> void:
	return

func _process(delta: float) -> void:
	return
