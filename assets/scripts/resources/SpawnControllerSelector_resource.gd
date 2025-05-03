extends Resource
class_name spawnControllerSelectorRes

@export var player_controller:= false
@export var click_move_controller:= false
@export var AI_movement_controller:= false

func _init(player_con:= false, click_con:=false, AI_con:= false) ->void: #nameS:String = "ControllerSelectorRes")->void:
	player_controller = player_con
	click_move_controller = click_con
	AI_movement_controller = AI_con
	#self.name = nameS
