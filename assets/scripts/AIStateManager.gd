extends Node3D

class_name AIStateManagerComponent

enum AIState {Idle, Alerted, Aggressive, Stunned}

#node reference
var pawn: CharacterPawn3D
var AIManager: AIUnitManager
var sensingComponent: AISensingComponent

func _ready() -> void:
	initialize()
	if get_parent_node_3d() is AIUnitManager:
		AIManager = get_parent_node_3d()
		AIManager.component_has_intialized(self)

func initialize():
	pass

func _physics_process(_delta: float) -> void:	
	
	pass



		
