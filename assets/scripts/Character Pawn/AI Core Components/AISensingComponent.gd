extends Node3D
class_name AISensingComponent

#node reference
#var Pawn: CharacterPawn3D
#var Nexus: PawnNexusComponent
#var AICore: AICoreComponent
#var stateManagerComponent: AIStateManagerComponent

#node references
var isReferenceSet:= false
var pawn: CharacterPawn3D
var nexus: PawnNexusComponent
#var characterModel: MeshInstance3D
#var collisionCapsule: CollisionShape3D
#var controllerManager: MovementControllerManager
#var statManager: CharacterStatManager
#var cameraControllerArm: PawnCameraController
var aiCore: AICoreComponent
#var sensingComponent: AISensingComponent
#var stateManager: AIStateManagerComponent

@export var isPremade:= false
var referencesUpdated:= false
var isActive:= false

##default AI sense variables
@export var sense_radius: float = 20 ##detection radius for AI sensing
@export var forward_sense_bias: bool = true
@export var sense_forward_offset: float = 5 ##note: offset increases sense range by this much
@export var forward_vision_angle: float = 160 ##in degrees.

@export var sense_init_res: AISensingInitializerBaseRes = AISensingInitializerBaseRes.new(sense_radius, forward_sense_bias,sense_forward_offset, forward_vision_angle)

#array of sensed entities
var allSensedEntities: Array[CharacterPawn3D]
var entitiesInDetectionAngle: Array[CharacterPawn3D]
var entitiesInLOS: Array[CharacterPawn3D]

#shape stuff
var sensingArea3D: Area3D
var sensingCollisionShape3D: CollisionShape3D

#facing direction buffer var
var facingDirection: Vector3


##initializes variables and creates sensing area
func _init(senseRes:=sense_init_res)->void:
	#region assign init variables
	sense_radius = senseRes.sense_radius
	forward_sense_bias = senseRes.forward_sense_bias
	sense_forward_offset = senseRes.sense_forward_offset
	forward_vision_angle = senseRes.forward_vision_angle
	#endregion
	#print("initialized sense ", self, " ",sense_radius,",",forward_sense_bias,",",sense_forward_offset,",",forward_vision_angle)
	#print("test ", senseRes.sense_radius, senseRes.forward_sense_bias,senseRes.forward_sense_bias,senseRes.forward_vision_angle)


func _enter_tree() -> void:
	#pull_component_references()
	aiCore = get_parent()
	nexus = aiCore.nexus
	pawn = nexus.pawn
	_check_overwrite_premade()
	nexus.sensingComponent = self
	name = "premadeSense" if isPremade else "instanceSense" 
	
	_initialize_sensing()


func _ready() -> void:
	if !nexus:
		printerr("Nexus component reference not available ", self)
	GlobalTools.print_sequence_counter(self, "_ready")


func _check_overwrite_premade()->void:	
	#region check if should overwrite and cleanup extra nodes
	if nexus.allow_overwrites.AISensingComponent:
		if aiCore.sensingComponent != self:
			if isPremade:
				self.queue_free() #free SELF if overwrites, ref NOT self, and is premade (instance should apply)
				return
			else:
				aiCore.sensingComponent.queue_free() #free REF if overwrites, ref NOT self, and not premade (instance should apply)
	else:
		if aiCore.sensingComponent != self:
			if isPremade:
				aiCore.sensingComponent.queue_free() #free REF if no overwrites, ref NOT self, and is premade (premade should apply)
			else: 
				self.queue_free() #free SELF if no overwrites, ref NOT self, and NOT premade (premade should apply)
				return
	#endregion
	#prints(nexus.pawn, "premade:",isPremade, "overwrites:", AICore.nexus.allow_overwrites.AISensingComponent, "ref is self:", AICore.sensingComponent != self)
	aiCore.sensingComponent = self


func _physics_process(_delta: float) -> void:
	if nexus:
		_update_facing_direction_vector()
		_update_sensing_area_offset()
		if isActive:
			if aiCore and aiCore.poll_now():
				_update_entity_in_detection_angle()
				_update_entities_in_LOS()
		if GlobalTools.go_print: print(self, " is present ", nexus.pawn)


func set_is_sensing_active(active:bool)->void:
	isActive = active
	pawnRID = pawn.get_rid()
	if exclude.find(pawnRID) > -1:
		exclude.append(pawnRID)


#var capsuleHalfHeight: float
##creates sensing areas and connects signals
func _initialize_sensing()->void:
	_create_sensing_area()
	sensingArea3D.body_entered.connect(_add_sensed_entity)
	sensingArea3D.body_exited.connect(_remove_sensed_entity)
	#capsuleHalfHeight = pawn.$CollisionShape3D

#region create sensing area
var debugMarker: MeshInstance3D
##creates area 3D, collision for it, and a offset visualizer (debug marker)
func _create_sensing_area()->void:
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
#endregion
#region create debug offset maker
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
#endregion


##updates the direction vector for the facing direction. Run every physics/frame
func _update_facing_direction_vector()->void:
	var currYaw:float
	if pawn:
		currYaw = pawn.currentYaw
	facingDirection = Vector3(-sin(currYaw), 0, -cos(currYaw)).normalized() #don't ask me why this math works @_@


##offsets area3D sensing sphere [param sense_forward_offset] units forward. Gives sensing directionality. 
##Turn it on/off with [param forward_sense_bias] export variable
func _update_sensing_area_offset()->void:
	if sensingArea3D == null:
		printerr("No sensing area in ", self)
		return
	if forward_sense_bias:
		var offset = facingDirection * sense_forward_offset
		sensingArea3D.position = offset
		debugMarker.position = Vector3(offset.x, offset.y + 1, offset.z)
		#sensingArea3D.rotation.y = currYaw		 #commented out until rotation of detection area matters


##listens to body_entered signal and adds it if is character pawn. Probably want to include other types in a later refactor
func _add_sensed_entity(body: Node3D)->void:
	if body is CharacterPawn3D and not allSensedEntities.has(body) and not body == pawn:
		allSensedEntities.append(body)
		#print("entered ", body, " is now tracked")
	else:
		#print("entered ", body, " is not a pawn")
		return


##listens to body_exited signal and removes it from buffer
func _remove_sensed_entity(body: Node3D)->void:
	if body is CharacterPawn3D:
		var at = allSensedEntities.find(body)
		if at != -1:
			allSensedEntities.remove_at(at)
	else:
		return


var visRad = cos(deg_to_rad(forward_vision_angle/2))
##uses dot product vs forward angle to check if within the target forward angle
func _is_in_detection_angle(entity: CharacterPawn3D)->bool:
	var forwards = facingDirection
	var targetDirection = (entity.global_position - global_position).normalized()
	var dotProduct = forwards.dot(targetDirection)
	if dotProduct > visRad: #forward angle halved because that's how math works to get the proper result apparently
		return true
	else:
		return false

##checks if within vision "cone" and appends to the buffer. called each AI polling updated
func _update_entity_in_detection_angle()->void:
	entitiesInDetectionAngle.clear()
	for e in allSensedEntities:
		if _is_in_detection_angle(e):
			entitiesInDetectionAngle.append(e)


#region raycast variables
var debugFlag = false
@export var collisionMask: int = 3 #collision layers 1 and 2
var exclude: Array[RID] #exclusion array for space query. Currently not working
@onready var space_state = get_world_3d().direct_space_state
@onready var query = PhysicsRayQueryParameters3D.new()
var pawnRID: RID
#endregion
##does a raycast towards [param entity] from pawn with a ground offset = unitHalfHeight
func _is_in_LOS(entity: CharacterPawn3D)->bool:
	#setup a space state query on specifically pawns with capsule colliders with a half height offset
	#region raycast codeblock
	var pwnPos = global_transform.origin
	var entPos = entity.global_transform.origin
	var pwnYOffset = pawn.unitHalfHeight #refactor halfheight to be contained in nexus
	var entYOffset = entity.unitHalfHeight
	
	#do the fuckin query
	var from = Vector3(pwnPos.x,(pwnPos.y + pwnYOffset),pwnPos.z)
	var to = Vector3(entPos.x, (entPos.y + entYOffset), entPos.z)
	query.from = from
	query.to = to
	query.collision_mask = collisionMask
	query.exclude = exclude
	var result = space_state.intersect_ray(query)
	#endregion
	#return succes
	if result and result.collider == entity:
		GlobalTools.lines_with_points(from, to, Color.DARK_RED,1)
		return true
	else:
		GlobalTools.lines_with_points(from, to, Color.YELLOW,1)
		return false


##checks all entities within detection angle for LOS and adds them to that array
func _update_entities_in_LOS() -> void: 
	entitiesInLOS.clear()
	for e in entitiesInDetectionAngle:
		if _is_in_LOS(e):
			entitiesInLOS.append(e)


##gets all colliders in the parent pawn, supposedly for raycast exclusion purposes.
func _get_all_colliders_in_pawn()->Array:
	var colArr: Array
	for c in pawn.allChildren:
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


func pull_component_references(core:AICoreComponent):
	aiCore = core
	pawn = aiCore.pawn
	print(self, "AI sensing references set: ", aiCore, " ", pawn)


func set_references(nexusRef: PawnNexusComponent)->void:
	nexus = nexusRef
	pawn = nexus.pawn
	
