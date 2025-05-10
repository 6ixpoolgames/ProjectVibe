extends Node3D
class_name PawnNexusComponent

#unique subcomponent node reference variables
var Pawn: CharacterPawn3D
var CharacterModel: MeshInstance3D
var CharacterCollision: CollisionShape3D
var ControllerManager: MovementControllerManager
var StatManager: CharacterStatManager
var cameraControllerArm: PawnCameraController
var AICore: AICoreComponent
var SensingComponent: AISensingComponent
var AIStateManager: AIStateManagerComponent
#var AIBehaviourManager: AIBehaviourManagerComponent	#still pending implementation
#var CombatManager: CombatManagerComponent				#still pending implementation

@export var allow_overwrites = {
	"Pawn":false,
	"CharacterModel":true,
	"CharacterCollision":true,
	"ControllerManager":false,
	"StatManager":false,
	"cameraControllerArm":false,
	"AICore":false,
	"AISensingComponent":true,
	"AIStateManager":false,
	"AIBehaviourManager":false
}

func _enter_tree() -> void:
	var node = get_parent()
	if node and is_instance_valid(node) and node is CharacterPawn3D:
		Pawn = node
