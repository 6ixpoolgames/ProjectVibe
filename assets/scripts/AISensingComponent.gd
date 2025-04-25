extends Node3D
class_name AISensingComponent

#node reference
var pawn: CharacterPawn3D
var AIManager: AIUnitManager
var stateManagerComponent: AIStateManagerComponent

#AI sense variables
@export var sense_radius: float = 20 ##detection radius for AI sensing
@export var forward_sense_bias: bool = true
@export var sense_forward_offset: float = 5 ##note: offset increases sense range by this much
@export var forward_vision_angle: float = 160 ##in degrees.

#array of sensed entities
var allSensedEntities: Array[CharacterPawn3D]
var entitiesInDetectionAngle: Array[CharacterPawn3D]
var entitiesInLOS: Array[CharacterPawn3D]

#shape stuff
var sensingArea3D: Area3D
var sensingCollisionShape3D: CollisionShape3D

#facing direction buffer var
var facingDirection: Vector3

func _ready() -> void:
	init()
	if get_parent_node_3d() is AIUnitManager:
		AIManager = get_parent_node_3d()
		AIManager.component_has_intialized(self)

#initializes variables and creates sensing area
func init()->void:
	var ascendants = GlobalTools.get_all_ascendants(self)
	for a in ascendants:
		if a is CharacterPawn3D and pawn == null:
			pawn = a
		if a is AIUnitManager and AIManager == null:
			AIManager = a
	if pawn == null:
		printerr("not attached to pawn! - ", self)
	if AIManager == null: 
		printerr("not attached to unit manager! - ", self)
	#exclude = get_all_colliders_in_pawn()
	initialize_sensing()

func _physics_process(_delta: float) -> void:
	update_facing_direction_vector()
	update_sensing_area_offset()
	if AIManager.pollingGroupActive == AIManager.polling_group:
		update_entity_in_detection_angle()
		update_entities_in_LOS()

#var capsuleHalfHeight: float
##creates sensing areas and connects signals
func initialize_sensing()->void:
	create_sensing_area()
	sensingArea3D.body_entered.connect(add_sensed_entity)
	sensingArea3D.body_exited.connect(remove_sensed_entity)
	#capsuleHalfHeight = pawn.$CollisionShape3D

var debugMarker: MeshInstance3D
##creates area 3D, collision for it, and a offset visualizer (debug marker)
func create_sensing_area()->void:
	if sensingArea3D:
		sensingArea3D.queue_free()
		sensingArea3D = null 
	sensingArea3D = Area3D.new()
	if sensingCollisionShape3D:
		sensingCollisionShape3D = null
	sensingCollisionShape3D = CollisionShape3D.new()
	var sphereShape = SphereShape3D.new()
	sphereShape.radius = sense_radius
	sensingCollisionShape3D.shape = sphereShape
	add_child(sensingArea3D)
	sensingArea3D.add_child(sensingCollisionShape3D)
	
	#create debug offset marker
	debugMarker = MeshInstance3D.new()
	var debugMarkerMesh = SphereMesh.new()
	debugMarkerMesh.height = 0.3
	debugMarkerMesh.radius = .3
	add_child(debugMarker)
	debugMarker.name = "debugMarker"
	debugMarker.mesh = debugMarkerMesh
	var material = StandardMaterial3D.new()
	material.albedo_color = Color.BLUE
	debugMarker.set_surface_override_material(0, material)
	debugMarker.position = Vector3.ZERO

##updates the direction vector for the facing direction. Run every physics/frame
func update_facing_direction_vector()->void:
	var currYaw = pawn.currentYaw
	facingDirection = Vector3(-sin(currYaw), 0, -cos(currYaw)).normalized() #don't ask me why this math works @_@
	
##offsets area3D sensing sphere [param sense_forward_offset] units forward. Gives sensing directionality. 
##Turn it on/off with [param forward_sense_bias] export variable
func update_sensing_area_offset()->void:
	if sensingArea3D == null:
		printerr("No sensing area in ", self)
		return
	if forward_sense_bias:
		var offset = facingDirection * sense_forward_offset
		sensingArea3D.position = offset
		debugMarker.position = Vector3(offset.x, offset.y + 1, offset.z)
		#sensingArea3D.rotation.y = currYaw		 #commented out until rotation of detection area matters

##listens to body_entered signal and adds it if is character pawn. Probably want to include other types in a later refactor
func add_sensed_entity(body: Node3D)->void:
	if body is CharacterPawn3D and not allSensedEntities.has(body) and not body == pawn:
		allSensedEntities.append(body)
		#print("entered ", body, " is now tracked")
	else:
		#print("entered ", body, " is not a pawn")
		return

##listens to body_exited signal and removes it from buffer
func remove_sensed_entity(body: Node3D)->void:
	if body is CharacterPawn3D:
		var at = allSensedEntities.find(body)
		if at != -1:
			allSensedEntities.remove_at(at)
			#print("exited ",body, " is untracked")	
	else:
		#print("exited ",body, " is not a pawn")	
		return
		
var visRad = cos(deg_to_rad(forward_vision_angle/2))
##uses dot product vs forward angle to check if within the target forward angle
func is_in_detection_angle(entity: CharacterPawn3D)->bool:
	var forwards = facingDirection
	var targetDirection = (entity.global_position - global_position).normalized()
	var dotProduct = forwards.dot(targetDirection)
	if dotProduct > visRad: #forward angle halved because that's how math works to get the proper result apparently
		return true
	else:
		return false

##checks if within vision "cone" and appends to the buffer. called each AI polling updated
func update_entity_in_detection_angle()->void:
	entitiesInDetectionAngle.clear()
	for e in allSensedEntities:
		if is_in_detection_angle(e):
			entitiesInDetectionAngle.append(e)

var debugFlag = false
var collisionMask: int = 3 #collision layers 1 and 2
var exclude: Array #exclusion array for space query. Currently not working
##does a raycast towards [param entity] from pawn with a ground offset = unitHalfHeight
func is_in_LOS(entity: CharacterPawn3D)->bool:
	#setup a space state query on specifically pawns with capsule colliders with a half height offset
	var space_state = get_world_3d().direct_space_state
	var pwnPos = global_transform.origin
	var entPos = entity.global_transform.origin
	var pwnYOffset = pawn.unitHalfHeight
	var entYOffset = entity.unitHalfHeight
	
	#do the fuckin query
	var from = Vector3(pwnPos.x,(pwnPos.y + pwnYOffset),pwnPos.z)
	var to = Vector3(entPos.x, (entPos.y + entYOffset), entPos.z)
	var query = PhysicsRayQueryParameters3D.create(from, to, collisionMask, exclude)	
	var result = space_state.intersect_ray(query)
	
	GlobalTools.lines_with_points(from, to, Color.DARK_RED,1)
	
	#return succes
	if result and result.collider == entity:
		return true
	else:
		return false

##checks all entities within detection angle for LOS and adds them to that array
func update_entities_in_LOS() -> void: 
	entitiesInLOS.clear()
	for e in entitiesInDetectionAngle:
		if is_in_LOS(e):
			entitiesInLOS.append(e)
	
##gets all colliders in the parent pawn, supposedly for raycast exclusion purposes.
func get_all_colliders_in_pawn()->Array:
	var colArr: Array
	var descArr = pawn.get_all_descendants(pawn)
	for c in descArr:
		if c is CollisionShape3D:
			colArr.append(c)
	return colArr

##debug function, prints all sensing buffers for validation
func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_TAB:
			print("all entities: ", allSensedEntities)
			print("within front angle: ", entitiesInDetectionAngle, " angle: ", forward_vision_angle, " dot: ", visRad )
			print("with LOS: ", entitiesInLOS)
