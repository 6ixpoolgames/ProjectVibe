extends AIStateComponentBase
class_name IdleAIStateBase

func _ready() -> void:
	super()
	state_priority = 25

func is_state_valid()->bool:
	return false
