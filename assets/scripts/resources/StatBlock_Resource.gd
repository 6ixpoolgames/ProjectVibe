extends Resource
class_name StatBlockRes

@export var statName: String ##sets name to string
@export var maxValue:float = 10 ##base MAX value of the stat
@export var currValue:float ##CURRENT value of the stat
@export var baseRegen: float = 0 ##base regeneration rate of the stat per second. if negative, constantly damages

func _init(Name: String = "", maxStat:float = 10, curr:float = maxStat, regen:float = 0)->void:
	statName = Name
	maxValue = maxStat
	currValue = curr
	baseRegen = regen

func set_initial_values(Name: String, max:float, curr:float = max, regen:float = 0)->void:
	statName = Name
	maxValue = max
	currValue = curr
	baseRegen = regen
