extends Resource
class_name AISensingInitializerBaseRes

@export var sense_radius: float = 20 ##detection radius for AI sensing
@export var forward_sense_bias: bool = true ##if AI sensing has a forward bias
@export var sense_forward_offset: float = 5 ##note: offset increases sense range by this much
@export var forward_vision_angle: float = 160 ##in degrees.

func _init(radius:= sense_radius, bias:= forward_sense_bias, offset:=sense_forward_offset, angle:=forward_vision_angle)->void:
	sense_radius = radius
	forward_sense_bias = bias
	sense_forward_offset = offset
	forward_vision_angle = angle
