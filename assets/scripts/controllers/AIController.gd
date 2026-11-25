# Written by Claude (claude-opus-5-5), 2026-11-07. History: controllers/CHANGELOG.md.
## The AI's hands: turns what the AI's behaviours tell it into one InputCommand per tick.
##
## A component of the pawn's AIManager ([member AIManager.controller]); the ControllerManager puts it in charge whenever no player
## has the pawn. It decides nothing: the AI's behaviours (or a
## script or test) tell it what to do, and it builds the same input a player's controller makes. Everything it's told stays until
## changed, except [method press], which lasts one tick. Until [method look_at_point] is called it keeps the pawn's own look. Its walks
## follow its own [member path_follower].
## [codeblock]
## ai.move_to(point)                        # walks there along a nav path; false if there's no way there
## ai.move_in_direction(Vector3(1, 0, 0))   # keeps walking that way; drops any path
## ai.press(&"jump")                        # held for one tick, so the pawn sees one press
## ai.follow(target, 1.2)                   # a persistent order: closes in on target until a move order (netcode spec 19.10)
## [/codeblock]
## A dead pawn's controller takes no orders, and lets go of everything as the pawn dies; the controllers README has the rest. Design: pawn spec 6.3, 10.3.
class_name AIController
extends ControllerBase
# REFACTOR: the order API (move_to, follow, keep_distance, press, look_at_*) stays until the behaviour steps write the input (pawn spec
# 16.10 step 7); then the controller only hands over what the running behaviour's steps write. See controllers/CHANGELOG.md.

## Sees every order given to any AIController, in order: [code]order_listener.call(controller, order, args)[/code], order being the
## method's name (&"move_to", &"press"...). Empty by default. The order stream's tap (netcode spec 19.3): the same orders, at the same
## point of the same ticks, give the same input.
static var order_listener := Callable()

## How its walks follow their paths (closeness, nav tier, links, waiting for nav). Empty: the defaults.
@export var path_settings: PathFollowSettings:
	set(value):
		path_settings = value
		path_follower.settings = value
## The path its walks follow (move_to, follow, keep_distance), with [member path_settings].
var path_follower := PathFollower.new()
## Where its look pitch is measured from: metres above the pawn's feet. Matches a ranged attack's muzzle_height (1.3), so a shot fired
## along the look meets the point looked at.
var look_from_height := 1.3

var _move := Vector3.ZERO
var _look_yaw := 0.0
var _look_pitch := 0.0
var _look_set := false # false: keep the pawn's own look
var _look_node: Node3D = null # look_at_node's node, followed at every input; null: none
var _look_offset := Vector3.ZERO
var _held := 0 # bits from InputActions
var _pressed_once := 0 # bits held for the next command only
# One command, reused every tick so a crowd of AI pawns makes no garbage; the ControllerManager copies it at once.
var _command := InputCommand.new()
# A move_to given while not in charge, started when it's in charge again.
var _waiting_point := Vector3.ZERO
var _has_waiting_point := false
# A persistent order being carried out (follow, keep_distance): the node, how near or how far, and how it's going.
enum _Follow { NONE, CLOSE_IN, KEEP_AWAY }
var _follow := _Follow.NONE
var _follow_node: Node3D = null
var _follow_distance := 0.0
var _follow_band := 0.0
var _follow_repath_ticks := 20
var _follow_repath_distance := 1.5
var _follow_goal := Vector3.ZERO
var _follow_path_tick := -1000000
var _follow_standing := false
var _let_go := false # it let go of everything (its pawn died) and has taken no order since


# Its pawn is its AIManager's, which entered the tree first.
func _enter_tree() -> void:
	var ai := get_parent() as AIManager
	pawn = ai.pawn if ai else null
	path_follower.pawn = pawn


func _ready() -> void:
	# As its pawn dies it lets go of every order, once, so it comes back from a revive holding nothing. The pawn's parts have all
	# entered the tree by now.
	if pawn and pawn.ability_manager:
		pawn.ability_manager.died.connect(func(_pawn: Pawn, _hit: HitInfo) -> void: let_go())


## Closes in on a node and stops stop_distance away (flat), looking at it offset above its origin; walks again once it's further than
## stop_distance plus band. Repaths every repath_ticks (at 60 a second) or when the node has moved repath_distance from where the path
## leads. Carried out at every input until a move order or another persistent order; a freed node ends it (standing still).
func follow(node: Node3D, stop_distance: float, look_offset := Vector3(0.0, 1.0, 0.0), band := 0.3, repath_ticks := 20,
		repath_distance := 1.5) -> void:
	if not _note(&"follow", [node, stop_distance, look_offset, band, repath_ticks, repath_distance]):
		return
	_start_following(_Follow.CLOSE_IN, node, stop_distance, band, repath_ticks, repath_distance)
	look_at_node_quietly(node, look_offset)


## Keeps about distance (flat) from a node, closing in when further and backing away when nearer, and stands, looking at it, once
## within band of that distance (half of it, from walking). Otherwise as [method follow].
func keep_distance(node: Node3D, distance: float, band := 1.5, look_offset := Vector3(0.0, 1.0, 0.0), repath_ticks := 20,
		repath_distance := 1.5) -> void:
	if not _note(&"keep_distance", [node, distance, band, look_offset, repath_ticks, repath_distance]):
		return
	_start_following(_Follow.KEEP_AWAY, node, distance, band, repath_ticks, repath_distance)
	look_at_node_quietly(node, look_offset)


## The node a persistent order follows, or null.
func get_followed_node() -> Node3D:
	return _follow_node if _follow != _Follow.NONE else null


## True while a persistent order has it standing (near enough, or at its distance).
func is_standing_by() -> bool:
	return _follow != _Follow.NONE and _follow_standing


## Walks to this point along a nav path, and stands still once there. Returns false (and stands still) if there's no way there.
## While not in charge it only remembers the point and returns true.
func move_to(point: Vector3) -> bool:
	if not _note(&"move_to", [point]):
		return false
	_follow = _Follow.NONE
	_move = Vector3.ZERO # once the path ends, it stands
	if not _is_in_charge():
		path_follower.stop()
		_waiting_point = point
		_has_waiting_point = true
		return true
	_has_waiting_point = false
	return path_follower.move_to(point)


## True while its own last move_to is under way: following its path (or waiting for nav, PENDING) when in charge, or waiting to
## start it when not. False once it arrives, gives up, or is told to do something else.
func is_following_order() -> bool:
	if _has_waiting_point:
		return true
	return _is_in_charge() and path_follower.is_under_way()


## Walks this way, in world space, up to length 1, until told otherwise. Shorter is slower.
func move_in_direction(direction: Vector3) -> void:
	if not _note(&"move_in_direction", [direction]):
		return
	_follow = _Follow.NONE
	_move = direction.limit_length(1.0)
	_stop_path()


## Stands still. Held actions stay held.
func stop() -> void:
	if not _note(&"stop", []):
		return
	_follow = _Follow.NONE
	_move = Vector3.ZERO
	_stop_path()


## Looks at a point in the world. Does nothing without a pawn, since there's nowhere to look from.
func look_at_point(point: Vector3) -> void:
	if _note(&"look_at_point", [point]):
		_aim_at(point)


# The aim itself, apart from the order, so following a node and building input don't count as orders.
func _aim_at(point: Vector3) -> void:
	if pawn == null:
		return
	var offset := point - pawn.global_position
	_look_node = null # a point replaces a node being followed
	if offset.length_squared() < 0.000001:
		return
	# Godot's forward is -Z, so a point straight ahead has yaw 0.
	_look_yaw = atan2(-offset.x, -offset.z)
	_look_pitch = atan2(offset.y - look_from_height, Vector2(offset.x, offset.z).length())
	_look_set = true


## Keeps looking at a node, at offset from its origin, worked out again at every input, until [method stop_looking] or another
## look. For a behaviour that sleeps through a swing. A freed node ends it.
func look_at_node(node: Node3D, offset := Vector3.ZERO) -> void:
	if _note(&"look_at_node", [node, offset]):
		look_at_node_quietly(node, offset)


## The same as [method look_at_node] without counting as an order: for a persistent order, whose own order covers its look.
func look_at_node_quietly(node: Node3D, offset := Vector3.ZERO) -> void:
	_look_node = node
	_look_offset = offset
	if is_instance_valid(node):
		_aim_at(node.global_position + offset)
		_look_node = node # _aim_at clears it


## Stops looking at anything in particular, and keeps whatever look the pawn already has.
func stop_looking() -> void:
	if not _note(&"stop_looking", []):
		return
	_look_set = false
	_look_node = null


## True while it's looking at a point it was given. AI sight faces this way then (SightSense).
func is_looking_at_point() -> bool:
	return _look_set


## Holds this action for the next tick only, so the pawn sees one press.
func press(action: StringName) -> void:
	if not _note(&"press", [action]):
		return
	_pressed_once |= InputActions.mask_of(action)


## Holds or lets go of this action, until changed.
func hold(action: StringName, held := true) -> void:
	if not _note(&"hold", [action, held]):
		return
	if held:
		_held |= InputActions.mask_of(action)
	else:
		_held &= ~InputActions.mask_of(action)


## Back to idle: standing still, nothing held. The look direction stays.
func release_all() -> void:
	if not _note(&"release_all", []):
		return
	_follow = _Follow.NONE
	_move = Vector3.ZERO
	_held = 0
	_pressed_once = 0
	_stop_path()


## This tick's input. Uses up press(), so call it once per tick: ControllerManager does.
func take_input_command(_tick: int) -> InputCommand:
	# While a path from move_to is being followed, the direction comes from it. ControllerManager has it drop its path when control
	# changes hands, so a path here was found while it was in charge.
	# Being asked for input means it's in charge, so a walk it was given while it wasn't starts now.
	if _has_waiting_point:
		_has_waiting_point = false
		path_follower.move_to(_waiting_point)
	if _follow != _Follow.NONE:
		_carry_out_follow(_tick)
	var link_press := 0
	# is_under_way, so a path waiting for nav (PENDING) gets asked each tick, which is when it tries again.
	if path_follower.is_under_way():
		_command.move = path_follower.get_move_direction()
		link_press = path_follower.take_link_press() # a link it just reached may need an action, such as jump, pressed for this tick
	else:
		_command.move = _move
	if _look_node != null:
		if is_instance_valid(_look_node):
			var node := _look_node
			var offset := _look_offset
			_aim_at(node.global_position + offset)
			_look_node = node # _aim_at clears it
			_look_offset = offset
		else:
			_look_node = null # it's gone: keep the last aim
	if _look_set or pawn == null:
		_command.look_yaw = _look_yaw
		_command.look_pitch = _look_pitch
	else:
		_command.look_yaw = pawn.controller_manager.look_yaw if pawn.controller_manager else pawn.yaw
		_command.look_pitch = pawn.controller_manager.look_pitch if pawn.controller_manager else 0.0
	_command.held_actions = _held | _pressed_once | link_press
	_pressed_once = 0
	return _command


# Tells the order listener, if there is one. False while the pawn is dead: the order is ignored, and not heard.
# REFACTOR: a prototype tap, one static listener for every controller, made for the order replay test; the order stream (netcode spec
# 19.3) settles its real shape. Orders that change nothing (a stop while already stopped: over 90% of stops) still count here; drop
# them before a stream sends them.
func _note(order: StringName, args: Array) -> bool:
	if pawn and pawn.is_dead():
		return false
	_let_go = false
	if order_listener.is_valid():
		order_listener.call(self, order, args)
	return true


func _start_following(mode: _Follow, node: Node3D, distance: float, band: float, repath_ticks: int, repath_distance: float) -> void:
	_follow = mode
	_follow_node = node
	_follow_distance = distance
	_follow_band = band
	_follow_repath_ticks = repath_ticks
	_follow_repath_distance = repath_distance
	_follow_path_tick = -1000000
	_follow_standing = false
	_move = Vector3.ZERO
	_has_waiting_point = false


# One input's worth of a persistent order: stand once near enough (or at its distance), walk again once outside the band, and find a
# new path when the goal has moved or the path is old. Only from the node's real position, so every machine does the same.
func _carry_out_follow(tick: int) -> void:
	if not is_instance_valid(_follow_node) or pawn == null:
		_follow = _Follow.NONE # the node is gone: stand
		path_follower.stop()
		return
	var there := _follow_node.global_position
	var away := pawn.global_position - there
	away.y = 0.0
	var distance := away.length()
	var goal := there
	var off_by := distance - _follow_distance # closing in: only too far matters
	if _follow == _Follow.KEEP_AWAY:
		off_by = absf(off_by)
		var direction := away / distance if distance > 0.01 else pawn.global_basis.z
		goal = there + direction * _follow_distance
	# Stands once inside (half the band, from walking), walks again once outside the whole band, so it doesn't twitch at the edge.
	if off_by <= (_follow_band if _follow_standing else _follow_band * 0.5):
		if not _follow_standing:
			_follow_standing = true
			path_follower.stop()
		return
	if _follow_standing or tick - _follow_path_tick >= TickDriver.ticks_at_rate(_follow_repath_ticks) \
			or goal.distance_to(_follow_goal) > _follow_repath_distance or not path_follower.is_under_way():
		_follow_standing = false
		_follow_goal = goal
		_follow_path_tick = tick
		path_follower.move_to(goal)


## Forgets every order (standing, nothing held, no look, no persistent order), without counting as one. The pawn calls it through its
## ControllerManager on each tick it's dead, on every machine that runs it, so it comes back from a revive with no orders and gives none
## while dead (netcode spec 19.10).
func let_go() -> void:
	if _let_go:
		return
	_follow = _Follow.NONE
	_move = Vector3.ZERO
	_held = 0
	_pressed_once = 0
	_look_set = false
	_look_node = null
	_stop_path()
	_let_go = true
	_has_waiting_point = false


## Its [member path_follower] while a walk is under way, else null.
func get_path_follower() -> PathFollower:
	return path_follower if path_follower.is_under_way() else null


## Drops the path it's following. A walk given while it wasn't in charge is kept, and starts when it's in charge again.
func drop_path() -> void:
	path_follower.stop()


func _stop_path() -> void:
	_has_waiting_point = false
	path_follower.stop()


# True when the pawn follows this controller's input. With no ControllerManager on the pawn, it counts as in charge, so a controller
# used on its own still works.
func _is_in_charge() -> bool:
	var manager := pawn.controller_manager if pawn else null
	return manager == null or manager.get_controller_in_charge() == self
