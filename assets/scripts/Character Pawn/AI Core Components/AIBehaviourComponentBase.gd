extends Node
class_name AIBehaviourComponentBase

@export var behaviourID:StringName = &""
@export var stateName: StringName

var BehaviourManager: AIBehaviourManagerComponent

func _enter_tree() -> void:
	if behaviourID == &"":
		behaviourID = StringName(self.name)
	#else:
	#	self.name = behaviourID
	if !BehaviourManager and get_parent() is AIBehaviourManagerComponent:
		BehaviourManager = get_parent()
	else:
		printerr("error getting parent reference", get_parent(), BehaviourManager)

func _ready() -> void:
	BehaviourManager.request_register_behaviour_component(self)
