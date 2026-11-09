## Written by Claude (claude-opus-5-5), 2026-11-07: the tier -1 pawn: a body something can possess, with movement in a module.
## No nexus, managers or abilities yet. This is enough to test cameras, nav and netcode with real ground movement. Spec:
## docs/pawn/PLAYER_AND_CAMERA.md. Claude 2026-11-07: it now has managers and abilities (docs/pawn/PAWN_SPEC.md); still no nexus. The old CharacterPawn3D is untouched, and carries on working in test scene.tscn
## (Claude 2026-11-08: both are now in assets/legacy/).
##
## How to use it: use assets/scenes/pawn/pawn.tscn as it is, or inherit from it. Something writes this pawn's input each tick,
## such as a PlayerController, or an AI script on the server. Its abilities make that into movement.
##
## Claude 2026-11-07: parts and input, pawn spec steps 3 to 6.
##   - When it enters the tree, GameMode's PawnInitializer adds the default parts its scene doesn't have: ControllerManager (with an
##     AIController), NavigationManager (Claude 2026-11-08), StatManager (with movement stats) and AbilityManager (with Walk, Jump
##     and Sprint). fill_in_default_parts and skip_default_parts opt out.
##   - Each tick, in its input phase, it asks its ControllerManager for input from whoever is in charge: this machine's player, or
##     else its AI controller. It only asks where its input is decided here. A client's pawn on the server gets its input over the
##     network instead.
##   - Each tick, its AbilityManager runs the abilities, which write velocity and facing. Then the pawn adds gravity and makes the one
##     move_and_slide call. Claude 2026-11-07: this replaced GroundMovement and MovementModule, which are gone.
##   - Claude 2026-11-09: each tick, before asking for input, it runs its AI parts (AIContextComponent, AIStateManager,
##     AIBehaviourManager) in a fixed order, offline or on the server only. See _tick_ai and pawn spec section 10.
##
## What it needs in its scene, all optional:
##   - an AbilityManager child. With none, nothing steers it, and it only falls. It comes from PawnInitializer by default.
##   - a TickStateComponent and a NetworkEntity child, for rollback and multiplayer. With none, it plays as single player. These
##     two stay in the scene, because NetworkSession reads them before the pawn joins the tree.
##   - a Node3D child called Visual, which the camera and the model hang from.
## pawn.tscn puts bodies on collision layer 2, and they collide with layers 1 and 2. The ground is on layer 1, so a camera arm
## can tell the ground from a pawn walking past.
##
## Why the body's rotation is never written: writing rotation every tick slowly changed the body's scale through rounding, which
## made collision differ in a replay (see TickSamplePawn). So facing is a plain number, and only the model turns.
##
## Why Visual exists: the body moves in ticks and gets corrected, and looks jerky if you watch it directly. Visual follows it
## smoothly per rendered frame, and hides corrections by fading them out. Anything on screen hangs from it.
##
## Claude 2026-11-07: input is now an InputCommand, given with apply_input(). Actions such as jump and sprint are named, held as bits,
## and a press is "held this tick, not last tick" (was_action_pressed). Pawn spec section 5.
##
## What happens in odd cases (all checked in tests/pawn_selftest.gd):
##   - No TickDriver: it ticks itself from _physics_process.
##   - AI pawn in unloaded ground: AIActivationManager stops its ticks, and it keeps all its state.
##   - On the server, a client's input goes missing: the last one repeats for missing_input_hold_ticks, then its direction fades out
##     over missing_input_fade_ticks. Held actions keep repeating, so a key still held when input comes back isn't a new press. Both
##     settings default to -1, which uses NetworkSession's settings of the same names.
class_name Pawn
extends CharacterBody3D

## Sent when a player takes this pawn, or lets it go.
signal possession_changed(pawn: Pawn, has_player: bool)
## Claude 2026-11-09: sent on the server when something hits this pawn, after its knockback starts. For effects.
signal hit_received(hit: HitInfo)
## Claude 2026-11-09, step 10: sent once on the server when this pawn dies. hit is what did it, or null.
signal died(pawn: Pawn, hit: HitInfo)

## Whether a player may take control of this pawn. Turn it off on pawns players should never control.
# Claude 2026-11-07: on by default, the owner's choice. Off, people would be left wondering why their pawn doesn't work. Something
# still has to ask for a possession, so a wrong one is a clear bug that gets looked at.
@export var possessable := true
## On: an AI pawn keeps the world loaded around it, as a player's pawn always does. Off, it's switched off wherever no
## source keeps the ground loaded, which is what you want for a horde.
@export var ai_loads_chunks := false:
	set(value):
		ai_loads_chunks = value
		_refresh_source()
## On: the camera arm exists all the time, so taking this pawn has no delay at all. For a handful of hero pawns. Leave it off
## for anything there are many of, or a horde gets thousands of arms that do nothing.
@export var always_has_camera_arm := false
## How far this pawn keeps the world loaded, when it does, in metres.
@export var streaming_load_distance := 320.0
## How far nav is built around it, in metres.
@export var streaming_nav_distance := 128.0
## The arm's settings, for a pawn that wants its own. Empty means the defaults.
@export var camera_preset: CameraPreset
## On the server: when a client's input goes missing, the last one repeats in full for this many ticks. -1 uses NetworkSession's
## setting of the same name, which is the game-wide rule. Set a number only for a pawn that needs its own.
# Claude 2026-11-07: -1 by default, so the rule is set once per game on NetworkSession rather than on every pawn.
@export_range(-1, 60, 1, "or_greater") var missing_input_hold_ticks := -1
## Then its direction fades to nothing over this many ticks. -1 uses NetworkSession's setting.
@export_range(-1, 60, 1, "or_greater") var missing_input_fade_ticks := -1
## Claude 2026-11-07: on, GameMode's PawnInitializer adds every default part this pawn's scene doesn't already have. Off, the pawn
## gets only what its scene has.
@export var fill_in_default_parts := true
## Claude 2026-11-07: how strongly it falls, in metres per second per second. Below 0, the project's gravity setting. Moved here from
## GroundMovement: the pawn adds gravity, and abilities only steer.
@export var gravity := -1.0
## Claude 2026-11-07: default parts to leave out, by name, such as &"AbilityManager". A part with that name in the scene is kept
## either way.
@export var skip_default_parts: Array[StringName] = []
## Claude 2026-11-09: which side this pawn is on. AI sensing only notices pawns of other teams (pawn spec 10.4). A player who
## possesses a pawn plays for its team.
@export var team := 0:
	set(value):
		if team == value:
			return
		if is_inside_tree():
			_count_team(team, -1)
			_count_team(value, 1)
		team = value
## Claude 2026-11-09: how easy this pawn is for AI to see: 1 is normal, lower is harder, 0 is invisible. Sight multiplies its fill
## rate by this (pawn spec 10.4). Nothing in the base changes it: how stealth, gear or light level turn into this number is a game
## rule, for a GameMode module to set.
@export_range(0.0, 4.0, 0.01, "or_greater") var detectability := 1.0
## Claude 2026-11-09: on: a pawn standing still with nothing to do rests, skipping its abilities, gravity and move_and_slide until
## something wakes it (pawn spec 15.3). Off: it simulates fully every tick.
@export var rest_when_idle := true
## Claude 2026-11-09: a resting pawn still runs a full tick this often, staggered by entity id, so ground that went away under it is
## noticed. 15 ticks is a quarter of a second at 60 ticks a second.
@export_range(1, 600, 1, "or_greater") var rest_check_ticks := 15
## Claude 2026-11-09: whether this pawn rested on its last tick, for readouts and tests. Worked out again every tick from its state,
## so it isn't rollback state. Setting it changes nothing.
var is_resting := false

# Claude 2026-11-09: how many pawns in the tree are on each team, so AI sensing can skip looking when there's nobody to find.
# GDScript note: a static var belongs to the class, not to one pawn, so every pawn shares this one dictionary.
static var _pawns_per_team := {}
# Claude 2026-11-09: the shared table of plain pawn data (a PawnTable from the navcore C++ library, scaling spec section 3), or null
# without the library. Every pawn in the tree has a row, in entity-id order. Pawns NetworkSession never configured, as in most
# tests, have no entity id; they get keys from TABLE_KEYS_WITHOUT_ID up, after every networked pawn, in the order they joined.
static var _table: Object = null
const TABLE_KEYS_WITHOUT_ID := 1 << 40
static var _next_table_key := TABLE_KEYS_WITHOUT_ID
# Claude 2026-11-09: hits queued during simulate, for every pawn, and the tick driver that delivers them (pawn spec 15.4).
static var _queued_hits: Array = [] # [attacker's entity id, target's entity id, place in the queue, HitInfo]
static var _hit_queue_driver: Node = null

# This tick's input, as plain data. Listed in the TickState, so it goes over the network and rolls back.
var move_input := Vector3.ZERO ## the direction to go, in world space, up to length 1
# Claude 2026-11-07: replaces wants_sprint and wants_jump. Bits from InputActions.
var held_actions := 0 ## which named actions are held this tick
var look_yaw := 0.0 ## where the player is looking, which is often not where the pawn is facing
var look_pitch := 0.0
## Claude 2026-11-09: how many ticks behind its own tick the controller was drawing other pawns, for lag compensation. In the input
## list, so a client's swing reaches the server with it; the server limits it to what's believable (LagCompensation).
var view_ticks_behind := 0.0

# State that affects the next tick. Listed in the TickState too.
## Claude 2026-11-07: last tick's held_actions, so a press can be told from a hold. It's in the TickState's state list, so the
## server's value reaches clients in snapshots and a correction fixes it, like position. From the audit of 6df1464: reading it back
## from the client's own saved input instead went wrong when the server never got a press. Protocol 5 made it 2 bytes per pawn.
var previous_held_actions := 0
var yaw := 0.0
## Our own copy of "on the floor", because rollback has to restore it, and is_on_floor() can't be set.
var grounded := false

## Claude 2026-11-07: runs this pawn's abilities, which steer it. Null if it has none. Replaces the old movement module.
var ability_manager: AbilityManager = null
## Claude 2026-11-07: this pawn's stats, which abilities read. Null if it has none, and then abilities use their fallbacks.
var stat_manager: StatManager = null
## Claude 2026-11-07: picks whose input this pawn follows. Null if the pawn has none, and then nothing writes its input for it.
var controller_manager: ControllerManager = null
## Claude 2026-11-08: finds paths and says which way to walk, for click-to-move and the AI. Null if the pawn has none.
var navigation_manager: NavigationManager = null
## Claude 2026-11-09: shared data and settings for this pawn's AI (pawn spec 10). Null if the pawn has no AI.
var ai_context: AIContextComponent = null
## Claude 2026-11-09: picks the AI's current state. Null if the pawn has none.
var ai_state_manager: AIStateManager = null
## Claude 2026-11-09: picks and runs the AI's behaviour. Null if the pawn has none.
var ai_behaviour_manager: AIBehaviourManager = null
## Claude 2026-11-09: the AI's senses, which write into its memory. Null if the pawn has none.
var ai_sensing_manager: AISensingManager = null
## Claude 2026-11-09: what the AI has sensed, and how aware of each it is. Null if the pawn has none.
var ai_memory: AIMemory = null
## Claude 2026-11-09: picks the AI's current target from its memory. Null if the pawn has none.
var ai_target_selector: AITargetSelector = null


var _driver: Node = null
var _death: DeathAbility = null # Claude 2026-11-09: found when ready
var _entity: NetworkEntity = null
var _has_player := false
var _source: StreamingSource = null
var _visual: Node3D = null
var _model: Node3D = null
var _previous_position := Vector3.ZERO # the body before and after the last tick, for smoothing Visual
var _current_position := Vector3.ZERO
var _previous_yaw := 0.0
var _current_yaw := 0.0
var _correction_offset := Vector3.ZERO # what's left of a correction, fading to nothing
var _fallback_tick := 0
var _simulating := true
var _missing_input_ticks := 0 # on the server: how many ticks in a row a client's input has been missing
var _input_missing_this_tick := false


func _init() -> void:
	floor_snap_length = 0.3
	floor_max_angle = deg_to_rad(50.0)
	# Godot's default margin is exactly 1 mm, and TickState rounds positions to exact 1 mm steps. That parks a standing body on
	# the edge of "touching the floor", so float noise flips the contact. A margin between two steps avoids it.
	safe_margin = 0.0014


func _enter_tree() -> void:
	add_to_group(TerrainBodyLifter.GROUP)
	_count_team(team, 1) # Claude 2026-11-09
	_join_table() # Claude 2026-11-09: the shared table of plain pawn data, which AI sensing's grid reads (C++ only; scaling spec step 1)
	# Claude 2026-11-07: default parts first, so they're children before anything below or any _ready looks for them. A node may
	# add children to itself here: Godot enters them right after.
	var game_mode: Node = get_node_or_null("/root/GameMode")
	if game_mode and game_mode.pawn_initializer:
		game_mode.pawn_initializer.initialize(self)
	_driver = get_node_or_null("/root/TickDriver")
	if _driver:
		_driver.register(self)


func _exit_tree() -> void:
	_count_team(team, -1) # Claude 2026-11-09
	if _table: # Claude 2026-11-09: leaves the shared table (scaling spec step 1)
		_table.remove(self)
	# Claude 2026-11-07: this first, because leaving the list can switch the pawn back on, which would register it again.
	var ai := _ai_activation_manager()
	if ai:
		ai.remove_pawn(self)
	if _driver:
		_driver.unregister(self)


func _ready() -> void:
	set_physics_process(_driver == null) # the driver calls us. Godot turns this on at ready for any script that defines it
	yaw = rotation.y # whatever the scene placed it at. From here on, the body itself stays unrotated
	rotation = Vector3.ZERO
	for child in get_children():
		if child is AbilityManager and ability_manager == null: # Claude 2026-11-07: was the movement module
			ability_manager = child
		elif child is StatManager and stat_manager == null: # Claude 2026-11-07
			stat_manager = child
		elif child is NetworkEntity:
			_entity = child
		elif child is ControllerManager and controller_manager == null: # Claude 2026-11-07
			controller_manager = child
		elif child is NavigationManager and navigation_manager == null: # Claude 2026-11-08
			navigation_manager = child
		elif child is AIContextComponent and ai_context == null: # Claude 2026-11-09: the AI parts
			ai_context = child
		elif child is AIStateManager and ai_state_manager == null:
			ai_state_manager = child
		elif child is AIBehaviourManager and ai_behaviour_manager == null:
			ai_behaviour_manager = child
		elif child is AISensingManager and ai_sensing_manager == null:
			ai_sensing_manager = child
		elif child is AIMemory and ai_memory == null:
			ai_memory = child
		elif child is AITargetSelector and ai_target_selector == null:
			ai_target_selector = child

	if ability_manager: # Claude 2026-11-09
		for ability in ability_manager.get_abilities():
			if ability is DeathAbility:
				_death = ability
				break
	_visual = get_node_or_null(^"Visual")
	if _visual:
		_visual.top_level = true # it's placed by _process, between ticks, not by the body
		_model = _visual.get_node_or_null(^"Model")
	_previous_position = global_position
	_current_position = global_position
	_previous_yaw = yaw
	_current_yaw = yaw
	_refresh_source()
	_refresh_ai_activity()
	if always_has_camera_arm:
		make_camera_arm()


# --- Things other scripts can call ---


## True if a player controls this pawn. On a client, that's any player, not only this machine's.
func has_player() -> bool:
	return _has_player


## PossessionCoordinator tells the pawn. Nothing else should call this.
func set_has_player(value: bool) -> void:
	if _has_player == value:
		return
	_has_player = value
	# Claude 2026-11-07: with nobody driving it, a pawn stands idle. The last tick's input would otherwise repeat forever, which is
	# what happened offline. Claude 2026-11-07: from the next tick its ControllerManager hands it to its AI controller, if it has one.
	if not value and _is_simulated_here():
		_clear_input()
	_refresh_source()
	_refresh_ai_activity()
	possession_changed.emit(self, value)


## What a controller gives the pawn each tick.
# Claude 2026-11-07: replaces apply_player_input(move, yaw, pitch, sprint, jump).
func apply_input(command: InputCommand) -> void:
	move_input = command.move
	look_yaw = command.look_yaw
	look_pitch = command.look_pitch
	held_actions = command.held_actions
	view_ticks_behind = command.view_ticks_behind # Claude 2026-11-09


## True while this named action is held, such as &"sprint".
func is_action_held(action: StringName) -> bool:
	return held_actions & InputActions.mask_of(action) != 0


## True on the one tick this named action became held, such as &"jump". Holding it down doesn't repeat it.
func was_action_pressed(action: StringName) -> bool:
	var bit := InputActions.mask_of(action)
	return held_actions & bit != 0 and previous_held_actions & bit == 0


## The node that follows the body smoothly, for hanging things from. With no Visual, it's the body.
func get_visual() -> Node3D:
	return _visual if _visual else self


## This pawn's arm, or null. An arm placed in the scene counts.
func get_camera_arm() -> CameraArm:
	var parent := get_visual()
	for child in parent.get_children():
		if child is CameraArm:
			return child
	return null


## Makes the arm, from camera_preset or the defaults, if there isn't one. It's created idle.
func make_camera_arm() -> CameraArm:
	var arm := get_camera_arm()
	if arm:
		return arm
	arm = CameraArm.new()
	arm.name = "CameraArm"
	arm.preset = camera_preset if camera_preset else CameraPreset.new()
	arm.spawned_by_possession = not always_has_camera_arm
	get_visual().add_child(arm)
	arm.ignore_body(self)
	return arm


## The view a camera should attach to when this pawn is possessed: the first VirtualCamera in its scene, or null.
func get_default_view() -> VirtualCamera:
	var arm := get_camera_arm()
	if arm:
		return arm.get_view()
	return _find_view(self)


## AIActivationManager calls this. Everything about the pawn stays as it is, and it simply stops ticking.
# Claude 2026-11-07: through the NetworkEntity, because it decides what ticks. This only stopped the pawn itself, and left its entity and
# TickState running: 2,000 pawns that were off still cost 53 ms a tick.
func set_simulation_active(active: bool) -> void:
	if _simulating == active:
		return
	_simulating = active
	if _driver == null:
		set_physics_process(active)
	elif _entity:
		_entity.set_paused(not active)
	elif active:
		_driver.register(self)
	else:
		_driver.unregister(self)


func is_simulation_active() -> bool:
	return _simulating


## Claude 2026-11-09: true where this pawn's AI runs: offline, or on the server. The AI never runs on a client (pawn spec 10.2).
func runs_ai_here() -> bool:
	return is_authority()


## Claude 2026-11-09: true where this pawn's state is decided: offline, or on the server. Hits are decided here.
func is_authority() -> bool:
	return _entity == null or _entity.role == NetworkEntity.Role.AUTHORITY


## Claude 2026-11-09, step 10: true while this pawn's Death ability runs: from Health reaching 0 until revive(). A pawn with no Death
## ability never dies.
func is_dead() -> bool:
	return _death != null and _death.is_running_timed()


## Claude 2026-11-09: how much Health this pawn has now, from its Health stat. A pawn with no such stat reports 0 and can't be hurt.
func get_health() -> float:
	return stat_manager.get_current(&"Health", 0.0) if stat_manager else 0.0


## Claude 2026-11-09: brings a dead pawn back with full Health, on the server. Its Death ability ends on its next tick.
func revive() -> void:
	if not is_authority() or stat_manager == null:
		return
	var stat := stat_manager.get_stat(&"Health")
	if stat and stat.changes_during_play:
		stat.current = stat.value


## Claude 2026-11-09: something hit this pawn. Called on the server by the attacking ability, such as MeleeAttack (step 9). In
## order (step 10 added the first three):
##   1. Its AI notes the hit (AIContextComponent.note_hit), for the "being hit" state rules, and wakes a decision.
##   2. Its memory adds threat to the attacker's entry, if it has one: damage × AIMemory.threat_per_damage.
##   3. It takes the damage from its Health stat. At 0 its Death ability starts, its AI stops, died goes out, and nothing below
##      happens.
##   4. Its own knockback starts, through its own AbilityManager, so the push moves it like its other movement and rolls back.
##   5. hit_received goes out.
## Claude 2026-11-09 (pawn spec 15.4): called during the simulate phase, as an ability's hit is, it's queued, and every queued hit is
## delivered after all pawns have simulated, in a fixed order, so the result never depends on whether this pawn simulated before or
## after its attacker. Called at any other time, such as from game code or a test, it takes effect at once.
func receive_hit(hit: HitInfo) -> void:
	if not is_authority() or hit == null or is_dead():
		return
	if _driver and _driver.is_in_simulate():
		_queue_hit(hit)
		return
	_take_hit(hit)


# Claude 2026-11-09: the hit itself, steps 1 to 5 above. Checked again here, because a queued hit can arrive after another killed it.
func _take_hit(hit: HitInfo) -> void:
	if not is_authority() or is_dead():
		return
	if ai_context:
		ai_context.note_hit(hit)
	if ai_memory and is_instance_valid(hit.attacker):
		ai_memory.add_threat(hit.attacker, hit.damage * ai_memory.threat_per_damage)
	if stat_manager and hit.damage > 0 and stat_manager.has_stat(&"Health"):
		if stat_manager.change_current(&"Health", -hit.damage) <= 0.0:
			_die(hit)
			hit_received.emit(hit)
			return
	if ability_manager and hit.knockback_speed > 0.0 and hit.knockback_ticks > 0:
		for ability in ability_manager.get_abilities():
			if ability is KnockbackAbility:
				ability.push(hit.direction * hit.knockback_speed, hit.knockback_ticks)
				break
	hit_received.emit(hit)


# Claude 2026-11-09 (pawn spec 15.4): holds a hit until after simulate. One queue for all pawns, delivered by the tick driver's
# after_simulate signal, which is connected the first time a hit is queued.
func _queue_hit(hit: HitInfo) -> void:
	if _hit_queue_driver != _driver:
		# GDScript note: Pawn._deliver_queued_hits is a Callable on the class itself, not on this pawn, so it keeps working after
		# this pawn is freed.
		if is_instance_valid(_hit_queue_driver) and _hit_queue_driver.after_simulate.is_connected(Pawn._deliver_queued_hits):
			_hit_queue_driver.after_simulate.disconnect(Pawn._deliver_queued_hits)
		_driver.after_simulate.connect(Pawn._deliver_queued_hits)
		_hit_queue_driver = _driver
	_queued_hits.append([_order_key(hit.attacker), _order_key(self), _queued_hits.size(), hit])


# Claude 2026-11-09: the entity id, which is the same on every machine, or -1 for a pawn that isn't networked (the queue order then
# decides, which is the order pawns simulated in).
static func _order_key(node: Node) -> int:
	var pawn := node as Pawn
	if pawn == null or not is_instance_valid(pawn) or pawn._entity == null:
		return -1
	return pawn._entity.entity_id


# Claude 2026-11-09: delivers every queued hit, sorted by the attacker's entity id, then the target's, then the order they were queued.
static func _deliver_queued_hits(_dt: float, _tick: int) -> void:
	if _queued_hits.is_empty():
		return
	var hits := _queued_hits
	_queued_hits = []
	hits.sort_custom(func(a: Array, b: Array) -> bool:
		if a[0] != b[0]:
			return a[0] < b[0]
		if a[1] != b[1]:
			return a[1] < b[1]
		return a[2] < b[2])
	for entry in hits:
		var hit: HitInfo = entry[3]
		if is_instance_valid(hit.target):
			hit.target._take_hit(hit)


## Claude 2026-11-09: the shared table of plain pawn data (scaling spec section 3), or null without the C++ library. Read-only for
## anyone but Pawn: pawns join and leave it themselves. Its rows are read from the pawns once a tick, at the first refresh(tick).
static func get_table() -> Object:
	return _table


# Claude 2026-11-09: joins the shared table, making it on first use. The key is the entity id, which the NetworkEntity already has:
# NetworkSession configures it before the pawn enters the tree. _entity isn't found until _ready, so the child is looked for here.
func _join_table() -> void:
	if _table == null:
		if not ClassDB.class_exists(&"PawnTable"):
			return
		# GDScript note: made by name, so this script still runs where the C++ library isn't available.
		_table = ClassDB.instantiate(&"PawnTable")
	var key := -1
	for child in get_children():
		if child is NetworkEntity and child.entity_id >= 0:
			key = child.entity_id
	if key < 0:
		key = _next_table_key
		_next_table_key += 1
	_table.add(self, key)


## Claude 2026-11-09: this pawn's NetworkEntity, or null when it isn't networked. Its entity_id is the same on every machine.
func get_network_entity() -> NetworkEntity:
	return _entity


## Claude 2026-11-09: how many pawns in the tree are on a team other than this one. AI sensing skips looking when it's 0.
static func count_pawns_not_on_team(own_team: int) -> int:
	var total := 0
	for each_team: int in _pawns_per_team:
		if each_team != own_team:
			total += _pawns_per_team[each_team]
	return total


# --- Ticks ---


## Claude 2026-11-07: the input phase. Asks the controller in charge for this tick's input, where this pawn's input is decided here.
## A script that writes input itself, such as a test brain, can still do so later in the same phase and win.
func _tick_input(_dt: float, tick: int) -> void:
	if is_dead():
		_clear_input() # Claude 2026-11-09: a dead pawn ignores its controllers and its AI
		return
	_tick_ai(tick) # Claude 2026-11-09: step 1 of pawn spec section 4, before the controller in charge is asked for input
	if controller_manager == null or not _decides_own_input():
		return
	var command := controller_manager.take_input_command(tick)
	if command:
		apply_input(command)


## Claude 2026-11-09: the AI's step, in a fixed order (pawn spec sections 4 and 10.9). Runs only where the AI runs (offline or the
## server), never while a rollback replays ticks, and, while a player has the pawn, only as far as the AI context's
## while_possessed allows. Order:
##   1. Sensing, which writes into memory (Claude 2026-11-09, step 8b).
##   2. On a decision tick, or when something asked for a decision: the target is picked, the state is checked, then the
##      behaviour manager decides.
##   3. The running behaviour ticks, which calls the AI controller.
func _tick_ai(tick: int) -> void:
	if ai_context == null or not runs_ai_here():
		return
	if _driver and _driver.is_resimulating():
		return # the AI is never rolled back, so a replay must not run it again
	ai_context.current_tick = tick
	if _has_player and ai_context.while_possessed == AIContextComponent.WhilePossessed.OFF:
		return
	# Claude 2026-11-09: step 1, sensing writes into memory. MEMORY_ONLY stops after it.
	if ai_sensing_manager:
		ai_sensing_manager.tick_sensing(tick)
	if _has_player and ai_context.while_possessed == AIContextComponent.WhilePossessed.MEMORY_ONLY:
		return
	if ai_state_manager:
		ai_state_manager.check_force_expiry(tick)
	if ai_target_selector:
		ai_target_selector.check_force_expiry(tick)
	if ai_context.is_decision_tick(tick):
		ai_context.request_decision()
	if ai_context.has_decision_waiting():
		if ai_target_selector:
			ai_target_selector.update_target(tick) # first, because states such as Combat look at the current target
		if ai_state_manager:
			ai_state_manager.update_state(tick) # a change asks for a decision with the new state's priority
		if ai_behaviour_manager:
			ai_behaviour_manager.decide(tick)
		else:
			ai_context.clear_decision()
	if ai_behaviour_manager:
		ai_behaviour_manager.tick_running(tick)


func _tick_simulate(dt: float, tick: int) -> void:
	# Claude 2026-11-09: resting (pawn spec 15.3). Checked before _current_position is overwritten, because "nothing moved it since
	# its last tick" compares against it. A resting pawn only does the bookkeeping at the end.
	var resting := _can_rest(tick)
	is_resting = resting
	_previous_position = _current_position
	_previous_yaw = _current_yaw
	if resting:
		_finish_tick()
		return
	# Claude 2026-11-07: abilities steer, then gravity, then one move_and_slide. Gravity goes by whether it was on the ground when the
	# tick began, as GroundMovement did, so a jump that starts this tick isn't pulled down in the same tick.
	var was_grounded := grounded
	if ability_manager:
		ability_manager.tick_abilities(dt)
	if not was_grounded:
		velocity.y -= _gravity_strength() * dt
	# move_and_slide uses Godot's physics delta. This scales it so that one tick moves velocity * tick dt.
	var factor: float = _driver.get_physics_factor() if _driver else 1.0
	velocity *= factor
	move_and_slide()
	velocity /= factor
	grounded = is_on_floor()
	_finish_tick() # Claude 2026-11-09: moved into a function, which a resting tick runs too


# Claude 2026-11-09: the end of every tick, resting or not: where the body is now, for smoothing Visual and for the resting check,
# and the input bookkeeping.
func _finish_tick() -> void:
	_current_position = global_position
	_current_yaw = yaw
	# Claude 2026-11-07: what was held this tick, so the next tick can tell a press from a hold.
	previous_held_actions = held_actions
	# Claude 2026-11-07: a tick with real input ends a run of missing ones.
	if not _input_missing_this_tick:
		_missing_input_ticks = 0
	_input_missing_this_tick = false


## Claude 2026-11-09: true if this pawn rests this tick (pawn spec 15.3). A pure rule of its state and the tick number, with nothing
## remembered, so nothing extra rolls back and a server and a client predicting it rest on the same ticks. In order of cheapness:
##   - rest_when_idle is on, it's grounded, its velocity is exactly zero, and it has no move input and no held actions
##   - nothing moved it since its last tick (a teleport, or TerrainBodyLifter raising it)
##   - this isn't one of its check ticks, every rest_check_ticks, staggered by entity id
##   - its abilities have no timer running and agree (AbilityManager.can_rest)
func _can_rest(tick: int) -> bool:
	if not rest_when_idle or not grounded or velocity != Vector3.ZERO or move_input != Vector3.ZERO or held_actions != 0:
		return false
	if global_position != _current_position:
		return false
	var stagger: int = _entity.entity_id if _entity and _entity.entity_id >= 0 else get_instance_id()
	if (tick + stagger) % rest_check_ticks == 0:
		return false
	return ability_manager == null or ability_manager.can_rest()


## TickState restored our properties, but CharacterBody3D also keeps a private "on floor" flag that still holds what the body is
## doing now. Nothing can set it directly, so this makes the engine work it out again, then puts things back.
func _on_state_loaded(_tick: int) -> void:
	# Claude 2026-11-07: previous_held_actions is restored by the TickState itself now, as rollback state.
	var saved_position := position
	var saved_velocity := velocity
	var saved_snap := floor_snap_length
	floor_snap_length = 0.0
	velocity = Vector3.ZERO
	move_and_slide()
	floor_snap_length = saved_snap
	if grounded and not is_on_floor():
		apply_floor_snap()
	position = saved_position
	velocity = saved_velocity
	_previous_position = global_position
	_current_position = global_position
	_previous_yaw = yaw
	_current_yaw = yaw


func _physics_process(delta: float) -> void:
	_fallback_tick += 1
	_tick_input(delta, _fallback_tick) # Claude 2026-11-07
	_tick_simulate(delta, _fallback_tick)


# --- Per rendered frame: only ever reads game state ---


func _process(delta: float) -> void:
	if _visual == null:
		return
	# Fades over about 100 ms, so the player sees a quick slide rather than a jump (netcode spec section 6.2).
	_correction_offset = _correction_offset.lerp(Vector3.ZERO, 1.0 - exp(-delta / 0.04))
	var fraction: float = _driver.get_interpolation_fraction() if _driver else 1.0
	_visual.global_position = _previous_position.lerp(_current_position, fraction) + _correction_offset
	if _model:
		_model.rotation.y = lerp_angle(_previous_yaw, _current_yaw, fraction)


# --- Multiplayer: optional hooks from NetworkEntity ---


## Works for a role that changes while running, as swapping pawns does.
func _on_network_role(entity: NetworkEntity) -> void:
	_entity = entity
	# The server runs it now: it stops doing what the last player's final input said.
	if entity.role == NetworkEntity.Role.AUTHORITY and entity.owner_peer == 0:
		_clear_input()
	if is_node_ready():
		_refresh_source()
		_refresh_ai_activity()


## On the server: a client's input is never trusted. Wrong types are replaced, and direction is limited to full speed.
func sanitize_network_input(values: Dictionary) -> Dictionary:
	var clean := values.duplicate()
	var wanted: Variant = values.get("move_input", Vector3.ZERO)
	clean["move_input"] = wanted.limit_length(1.0) if wanted is Vector3 and wanted.is_finite() else Vector3.ZERO
	# Claude 2026-11-07: replaces the two bools. Bits for actions that aren't listed are thrown away.
	var held: Variant = values.get("held_actions", 0)
	clean["held_actions"] = held & InputActions.all_listed_mask() if held is int else 0
	# Claude 2026-11-09: a number of ticks, never negative. LagCompensation limits how far back it really goes.
	var behind: Variant = values.get("view_ticks_behind", 0.0)
	clean["view_ticks_behind"] = maxf(behind, 0.0) if behind is float and is_finite(behind) else 0.0
	for angle: String in ["look_yaw", "look_pitch"]:
		var value: Variant = values.get(angle, 0.0)
		clean[angle] = value if value is float and is_finite(value) else 0.0
	return clean


## On the server: this tick's input never arrived, so the last one repeats. A held direction repeats fine, and a press doesn't.
# Claude 2026-11-07: a press can't repeat any more, because a repeated hold isn't "newly held". New: after missing_input_hold_ticks,
# the direction fades out. Held actions are left alone, so a key still held when input comes back doesn't count as a new press.
func _network_input_missing() -> void:
	_input_missing_this_tick = true
	_missing_input_ticks += 1
	# Claude 2026-11-07: -1 means NetworkSession's rule. With no session at all, 3 and 6, the same as its defaults.
	var session: Node = get_node_or_null("/root/NetworkSession")
	var hold: int = missing_input_hold_ticks if missing_input_hold_ticks >= 0 else (session.missing_input_hold_ticks if session else 3)
	var fade: int = missing_input_fade_ticks if missing_input_fade_ticks >= 0 else (session.missing_input_fade_ticks if session else 6)
	if _missing_input_ticks <= hold:
		return
	if fade <= 0:
		move_input = Vector3.ZERO
	else:
		# A full-length direction reaches zero in "fade" ticks. A shorter one gets there sooner.
		move_input = move_input.move_toward(Vector3.ZERO, 1.0 / fade)


## On a client, for a pawn someone else controls: it was just moved between snapshots, so Visual follows.
func _on_network_interpolated() -> void:
	_previous_position = _current_position
	_current_position = global_position
	_previous_yaw = _current_yaw
	_current_yaw = yaw


## On a client: a correction moved our body by this much.
func _on_network_corrected(jump: Variant) -> void:
	if jump is Vector3:
		_correction_offset += jump


# --- Helpers ---


func _find_view(node: Node) -> VirtualCamera:
	for child in node.get_children():
		if child is VirtualCamera:
			return child
		var found := _find_view(child)
		if found:
			return found
	return null


# Claude 2026-11-09, step 10: Health reached 0. The Death ability locks out everything, which stops the pawn steering; the AI's
# running behaviour stops and its hands let go.
func _die(hit: HitInfo) -> void:
	if _death == null or not ability_manager:
		return
	ability_manager.start_ability(_death)
	if ai_behaviour_manager:
		ai_behaviour_manager.stop_running("died")
	var hands := controller_manager.ai_controller as AIController if controller_manager else null
	if hands:
		hands.release_all()
	died.emit(self, hit)


# Claude 2026-11-09: keeps the shared team counts in step with pawns entering and leaving the tree, and changing team.
static func _count_team(which_team: int, change: int) -> void:
	var count: int = _pawns_per_team.get(which_team, 0) + change
	if count <= 0:
		_pawns_per_team.erase(which_team)
	else:
		_pawns_per_team[which_team] = count


func _clear_input() -> void:
	# Claude 2026-11-07: keeps the look direction, as before.
	move_input = Vector3.ZERO
	held_actions = 0


## A pawn only has a source if something wants the world kept loaded around it, so a horde doesn't carry thousands of them.
func _refresh_source() -> void:
	if not is_inside_tree():
		return
	# On a client, another player's pawn needs nothing loaded here. It's drawn from snapshots.
	var wanted := _is_simulated_here() and (_has_player or ai_loads_chunks)
	if wanted and _source == null:
		_source = StreamingSource.new()
		_source.name = "StreamingSource"
		_source.load_distance = streaming_load_distance
		_source.nav_distance = streaming_nav_distance
		add_child(_source)
	elif not wanted and _source != null:
		_source.queue_free()
		_source = null


## Claude 2026-11-07: gravity in metres per second per second, from the gravity setting or else the project's.
func _gravity_strength() -> float:
	if gravity >= 0.0:
		return gravity
	return ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)


## Claude 2026-11-07: true where this pawn's input is decided: offline, its owner's machine, or the server for a pawn nobody owns. False
## on the server for a client's pawn, whose input arrives over the network, and on a client for anyone else's pawn.
func _decides_own_input() -> bool:
	return _entity == null or _entity.is_local or (_entity.role == NetworkEntity.Role.AUTHORITY and _entity.owner_peer == 0)


## False for a pawn on a client that belongs to someone else.
func _is_simulated_here() -> bool:
	return _entity == null or _entity.is_local or _entity.role == NetworkEntity.Role.AUTHORITY


## An AI pawn is switched off where there's no ground. A pawn with a source always has ground, so it's never watched.
func _refresh_ai_activity() -> void:
	var ai := _ai_activation_manager()
	if ai == null:
		return
	if _source != null or _has_player or not _is_simulated_here():
		ai.remove_pawn(self)
	else:
		ai.add_pawn(self)


func _ai_activation_manager() -> AIActivationManager: # Claude 2026-11-07: renamed with the module
	var game_mode: Node = get_node_or_null("/root/GameMode") if is_inside_tree() else null
	return game_mode.ai_activation_manager if game_mode else null
