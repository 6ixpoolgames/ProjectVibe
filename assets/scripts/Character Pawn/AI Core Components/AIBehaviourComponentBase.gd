extends Node
class_name AIBehaviourComponentBase

@export var behaviourID:StringName = &""
@export var stateName: StringName

var BehaviourManager: AIBehaviourManagerComponent
var Pawn: CharacterPawn3D
var AICore: AICoreComponent
var pawnRID: RID

func _enter_tree() -> void:
	if behaviourID == &"":
		behaviourID = StringName(self.name)
	else:
		self.name = behaviourID
	if !BehaviourManager and get_parent() is AIBehaviourManagerComponent:
		BehaviourManager = get_parent()
	else:
		printerr("error getting parent reference", get_parent(), BehaviourManager)

func _ready() -> void:
	BehaviourManager.request_register_behaviour_component(self)

func on_enter_state()->void:
	pass

func pull_down_references(core:AICoreComponent, pwn:CharacterPawn3D):
	AICore = core
	Pawn = pwn
	pawnRID = Pawn.pawnRID
