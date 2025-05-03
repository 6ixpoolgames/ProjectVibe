##singleton class that houses globally available debug methods
extends Node


func _physics_process(_delta: float) -> void:
	#print_on_physics_frame(delta, .5)
	printFuncRationalizer(90)

func _process(delta: float) -> void:
	#print_on_process_frame(delta, .2)
	final_cleanup(delta)

## Returns an array of all ascendant nodes (parent, grandparent, etc.) up to the root.
## If the node has no parent, returns an empty array.
##should probably move to a global tools singleton
func get_all_ascendants(target:Node) -> Array[Node]:
	var ascendants: Array[Node] = []
	var current: Node = target.get_parent()    
	while current:
		ascendants.append(current)
		current = current.get_parent()    
	return ascendants

##returns array of all descendant nodes. Can be offloaded to global tools singleton probably
func get_all_descendants(node: Node, descendants: Array[Node] = []) -> Array[Node]:
	for child in node.get_children():
		descendants.append(child)
		get_all_descendants(child, descendants)
	return descendants
	
#consider moving to a global tools singleton
var printTimer: int = -1
var go_print: bool = false
##counts down printTime number of frames before setting "go_print" to true, sets it to false every other frame. To apply, just add "if goPrint:" before calling a debug print output to 'rationalize' it
## [param printTime] is number of frames before setting go_print to true.
func printFuncRationalizer(printTime: int):
	if printTimer > 0:
		printTimer -= 1
		go_print = false
	else:
		printTimer = printTime
		go_print = true
		
	
func lines_with_points(from:Vector3, to:Vector3, color:Color, persist_ms:float):
	line(from,to,color,persist_ms)
	point(from,0.05,Color.RED,persist_ms)
	point(to,0.05,Color.RED,persist_ms)
	
var printSeq:int = -1
func print_sequence_counter(node:Node, method_name:String)->int:
	printSeq += 1
	print("	####-[ ", printSeq, " ]-#### 	 NODE=[[ ",node," ]]			METHOD=[['", method_name,"']]	#################")
	return printSeq

var processFrame: int = -1
var procTimer: float = 0
var inBetFr_pro: int = -1
func print_on_process_frame(delta:float, seconds_to_run, frames_btw_prnt:int = 0)-> int:
	procTimer += delta
	if procTimer > seconds_to_run:
		return processFrame
	processFrame += 1
	inBetFr_pro += 1
	if inBetFr_pro == frames_btw_prnt and frames_btw_prnt > -1:
		inBetFr_pro = -1
		print("------------PROCess-Frame----------------------------------------[	",processFrame,"	]----------------------------------------------------",delta)
	return processFrame
	
	
var physicsFrame: int = -1
var physTimer: float = 0
var inBetFr_phy: int = -1
func print_on_physics_frame(delta:float, seconds_to_run:float, frames_btw_prnt:int = 0)-> int:
	physTimer += delta
	if physTimer > seconds_to_run:
		return physicsFrame
	physicsFrame += 1
	inBetFr_phy += 1
	if inBetFr_phy == frames_btw_prnt and frames_btw_prnt > -1:
		inBetFr_phy = -1
		print("			------------PHYSics-Frame-------------------------------------_[	",physicsFrame,"	]----------------------------------------------------",delta,"*")
	return physicsFrame

var default_persist_ms:= 0.5
func line(pos1: Vector3, pos2: Vector3, color = Color.DARK_RED, persist_ms:float = default_persist_ms):
	var mesh_instance := MeshInstance3D.new()
	var immediate_mesh := ImmediateMesh.new()
	var material := ORMMaterial3D.new()

	mesh_instance.mesh = immediate_mesh
	mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	immediate_mesh.surface_begin(Mesh.PRIMITIVE_LINES, material)
	immediate_mesh.surface_add_vertex(pos1)
	immediate_mesh.surface_add_vertex(pos2)
	immediate_mesh.surface_end()

	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = color

	get_tree().get_root().add_child(mesh_instance)
	if debug_mesh_buffer.size() > 100: # Arbitrary limit
		#wprint("Warning: Debug mesh buffer overflow, clearing oldest ", debug_mesh_buffer.size())
		if is_instance_valid(debug_mesh_buffer[0]):
			debug_mesh_buffer[0].queue_free()
		debug_mesh_buffer.remove_at(0)
		debug_mesh_timer.remove_at(0)
	debug_mesh_buffer.append(mesh_instance)
	debug_mesh_timer.append(persist_ms)
	return

func point(pos: Vector3, radius:float = 0.05, color = Color.RED, persist_ms:float = default_persist_ms):
	var mesh_instance := MeshInstance3D.new()
	var sphere_mesh := SphereMesh.new()
	var material := ORMMaterial3D.new()

	mesh_instance.mesh = sphere_mesh
	mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mesh_instance.position = pos

	sphere_mesh.radius = radius
	sphere_mesh.height = radius*2
	sphere_mesh.material = material

	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = color

	get_tree().get_root().add_child(mesh_instance)
	if debug_mesh_buffer.size() > 1000: # Arbitrary limit
		print("Warning: Debug mesh buffer overflow, clearing oldest")
		if is_instance_valid(debug_mesh_buffer[0]):
			debug_mesh_buffer[0].queue_free()
		debug_mesh_buffer.remove_at(0)
		debug_mesh_timer.remove_at(0)
	debug_mesh_buffer.append(mesh_instance)
	debug_mesh_timer.append(persist_ms)
	return

func square(pos: Vector3, size: Vector2, color = Color.RED, persist_ms:float = default_persist_ms):
	var mesh_instance := MeshInstance3D.new()
	var box_mesh := BoxMesh.new()
	var material := ORMMaterial3D.new()

	mesh_instance.mesh = box_mesh
	mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mesh_instance.position = pos

	box_mesh.size = Vector3(size.x, size.y, 1)
	box_mesh.material = material

	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = color
	
	get_tree().get_root().add_child(mesh_instance)
	if debug_mesh_buffer.size() > 100: # Arbitrary limit
		print("Warning: Debug mesh buffer overflow, clearing oldest")
		if is_instance_valid(debug_mesh_buffer[0]):
			debug_mesh_buffer[0].queue_free()
		debug_mesh_buffer.remove_at(0)
		debug_mesh_timer.remove_at(0)
	debug_mesh_buffer.append(mesh_instance)
	debug_mesh_timer.append(persist_ms)
	return

## 1 -> Lasts ONLY for current physics frame
## >1 -> Lasts X time duration.
## <1 -> Stays indefinitely
var debug_mesh_buffer: Array[MeshInstance3D]
var debug_mesh_timer: Array[float]
func final_cleanup(delta:float):
	var bufferM: Array[MeshInstance3D]
	var bufferT: Array[float]
	for i in range(debug_mesh_timer.size()):
		debug_mesh_timer[i] -= delta
		if debug_mesh_timer[i] > 0:
			bufferM.append(debug_mesh_buffer[i])
			bufferT.append(debug_mesh_timer[i])
		else:
			debug_mesh_buffer[i].queue_free()
	debug_mesh_buffer.clear()
	debug_mesh_timer.clear()
	debug_mesh_buffer = bufferM
	debug_mesh_timer = bufferT
	
