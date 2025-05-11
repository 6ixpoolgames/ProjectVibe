extends Node3D
class_name PawnNexusComponent

#unique subcomponent node reference variables
var pawn: CharacterPawn3D
var characterModel: MeshInstance3D
var characterCollision: CollisionShape3D
var controllerManager: MovementControllerManager
var statManager: CharacterStatManager
var cameraControllerArm: PawnCameraController
var AICore: AICoreComponent
var sensingComponent: AISensingComponent
var AIStateManager: AIStateManagerComponent
var AIBehaviourManager: AIBehaviourManagerComponent
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
		pawn = node
