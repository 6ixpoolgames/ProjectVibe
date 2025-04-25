extends Node3D

class_name ActionComponentBase

@export var base_priority: float = 1
var actionManager: AIActionManagerClass

func _ready():
	pass

func on_enter():
	pass

func on_exit():
	pass

func on_interupt():
	pass

func do_action():
	pass
	
func is_valid()->bool:
	return false
	
	
