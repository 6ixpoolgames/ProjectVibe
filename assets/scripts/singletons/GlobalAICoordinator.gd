extends Node
class_name GlobalAICoordinatorSingleton

@export var polling_freq_frame_count:int = 3

var pollingFrame:int = 0
func _physics_process(_delta: float) -> void:
	iterate_through_polling_frames()

##iterates through polling frames from 1 to [param polling_freq_frame_count]
func iterate_through_polling_frames()->int:
	if pollingFrame == polling_freq_frame_count:
		pollingFrame = 0
	pollingFrame+=1
	return pollingFrame

##returns current polling frame
func get_polling_frame()->int:
	#print("[Global AI Coordinator] current polling frame: ", pollingFrame)
	return pollingFrame
	
##sets the polling frequency by setting how many physics frames it takes to loop polling. freq/60 = polling/sec (e.g. freq = 1 is 60hz, freq = 2 is 30hz, freq = 3 is 20hz, 4 is 15 hz,
##5 is 12.5, 6 is 10hz, etc)
func set_polling_frequency(freq: int)->void:
	polling_freq_frame_count = freq
