# Written by Claude (claude-opus-5-5), 2026-11-08. History: navigation/CHANGELOG.md.
## The pawn's only contact with navigation: finds paths and says which way to walk.
##
## A part on the pawn, added by PawnInitializer. A controller (player click-to-move, AI move_to) calls [method move_to], then asks
## [method get_move_direction] once per tick and puts the answer in its InputCommand's move, as a player's keys would. It never moves
## the pawn and never ticks on its own. Over the network a client follows its own path and only sends directions (pawn spec 7).
## [codeblock]
## pawn.navigation_manager.move_to(point)        # finds a path; false if there's no way there
## pawn.navigation_manager.get_move_direction()  # which way to walk this tick; zero when there's no path
## pawn.navigation_manager.get_path_state()      # NONE, FOLLOWING, PENDING, ARRIVED or UNREACHABLE
## [/codeblock]
## Paths may cross links (jumps, drops, placed [NavLink]s): [method take_link_action] gives the action to press at a link's start.
## No nav at all means a straight line ([member straight_line_without_nav]); nav still building means PENDING. The README's "How a
## move works" has the odd cases.
class_name NavigationManager
extends Node

## Sent once when the end of a path is reached.
signal arrived
## Sent once when a path ends: reached is true after [signal arrived], false when it gave up (no way, nav too slow, a link not
## crossed). Not sent for [method stop]. AI behaviours wait on it (AIBehaviourBase.wake_on_path_end).
signal path_ended(reached: bool)

## Where the last move_to stands. Read it with [method get_path_state].
enum PathState {
	NONE, ## no move_to yet, or stop() since
	FOLLOWING, ## walking a path, or a straight line where there's no nav
	PENDING, ## waiting: for nav to be built under the pawn (it tries again every pending_retry_ticks), or for a queued path
	ARRIVED, ## got to the end of the path. With is_partial(), that's the closest place it could reach, not the point
	UNREACHABLE, ## no way there: nowhere near nav, a link it missed twice, or nav or a queued path didn't come in time
}

## How close, in metres, the pawn must get to a corner of the path before it heads for the next one. Measured flat, ignoring
## height, because a path's height between corners isn't the ground.
@export var corner_reached_distance := 0.5
## How close, in metres, it must get to the end of the path to count as arrived. Smaller than corner_reached_distance, because the
## end is where something wanted to be.
@export var arrival_distance := 0.3
## Which size of nav to use. 0 is the smallest. The nav spec's tiers are by pawn radius; t0 builds only tier 0.
@export var nav_tier := 0
## On, paths may cross links (jumps, drops, placed links). Turn it off for a pawn that can't jump, so it only goes where it can walk.
@export var use_links := true
## How long, in seconds, the pawn has to get from a link's start to its end. Past that it finds a new path, from wherever it ended
## up, to the same place.
@export var link_timeout := 3.0
## On, a move_to where there's no nav at all, and none being built, walks in a straight line (bare test levels, click-to-move without
## nav). Off, it's UNREACHABLE, for a game where walking off the nav would be a bug.
@export var straight_line_without_nav := true
## While PENDING for nav to be built, how often it tries again to find a path, in ticks at 60 a second.
@export var pending_retry_ticks := 10
## How long it stays PENDING, in ticks at 60 a second, for nav to be built or a queued path to come, before giving up
## (UNREACHABLE). 300 is 5 s.
@export var pending_give_up_ticks := 300

## How many paths all pawns together find straight away in one tick. Any more go to NavServer's queue (searched within its own budget
## a tick, across links too), and those pawns wait PENDING. 0 sends every path through the queue. Shared by every NavigationManager.
static var paths_now_per_tick := 8
static var _paths_now_tick := -1 # the tick _paths_now_used counts
static var _paths_now_used := 0

## The pawn this manager belongs to, or null if its parent isn't one.
var pawn: Pawn = null

var _corners := PackedVector3Array()
var _next_corner := 0 # index into _corners of the corner being walked to
var _state := PathState.NONE
var _partial := false # the path ends at the closest place it can reach; kept after arriving, until the next move_to or stop()
var _pending_ticks := 0 # how long it's been PENDING
var _link_ids := PackedInt64Array() # one id per corner, not 0 where that corner starts a link; empty when the path has no link info
var _goal := Vector3.ZERO # where the last move_to was going, for finding a new path after a missed link
var _action_to_press: StringName = &"" # waiting for the controller to take it
var _ticks_on_link := -1 # -1: not crossing a link
var _new_paths_left := 1 # how many more times a missed link may lead to a new path, before it gives up
var _path_request := 0 # the queued search this pawn is waiting for (NavServer.find_path), or 0


func _init() -> void:
	# Nothing here runs per frame: controllers call get_move_direction() on the pawn's tick.
	set_process(false)
	set_physics_process(false)


func _enter_tree() -> void:
	pawn = get_parent() as Pawn
	# It tells its pawn it's here, before any part's _ready; the first NavigationManager a pawn has is the one it uses.
	if pawn and not is_instance_valid(pawn.navigation_manager):
		pawn.navigation_manager = self
	if pawn == null:
		push_warning("NavigationManager: its parent isn't a Pawn, so it can't find paths for anything.")


## Finds a path from the pawn to this point and starts following it. Returns false, and stops, if there's no way there
## (UNREACHABLE). With no nav at all, it goes in a straight line and returns true. While nav is still being built, or the path is
## queued, it returns true and waits (PENDING).
func move_to(point: Vector3) -> bool:
	stop()
	if pawn == null:
		_state = PathState.UNREACHABLE
		return false
	_goal = point
	_new_paths_left = 1
	_state = _find_path(point)
	return _state != PathState.UNREACHABLE


## Stops following the path, and cancels a queued one. [method has_arrived] goes back to false, and the state to NONE.
func stop() -> void:
	if _path_request != 0: # a queued search nobody wants any more
		var nav := _nav_server()
		if nav:
			nav.cancel_path(_path_request)
		_path_request = 0
	_corners = PackedVector3Array()
	_next_corner = 0
	_state = PathState.NONE
	_partial = false
	_pending_ticks = 0
	_link_ids = PackedInt64Array()
	_action_to_press = &""
	_ticks_on_link = -1


## Which way to walk now: flat, length 1, or zero when there's no path. Call it once per tick, because it also moves on to the
## next corner when the pawn is close enough, finishes the path at the end, and runs PENDING's retries.
func get_move_direction() -> Vector3:
	if pawn == null:
		return Vector3.ZERO
	# Waiting for nav to be built or for a queued path. Try again now and then, and give up after a while.
	if _state == PathState.PENDING:
		var elapsed := pawn.ticks_elapsed # the ticks since its pawn last ran: a distant pawn runs every 2nd or 4th tick
		_pending_ticks += elapsed
		if _pending_ticks >= TickDriver.ticks_at_rate(pending_give_up_ticks):
			stop() # which also cancels a queued search
			_state = PathState.UNREACHABLE
			path_ended.emit(false)
			return Vector3.ZERO
		if _path_request != 0:
			# A queued path comes as a dictionary once it's found.
			var nav := _nav_server()
			var found: Dictionary = nav.take_path_result(_path_request) if nav else {}
			if not found.is_empty():
				_path_request = 0
				_state = _follow(found)
		elif _pending_ticks % maxi(1, TickDriver.ticks_at_rate(pending_retry_ticks)) < elapsed:
			_state = _find_path(_goal)
		if _state != PathState.FOLLOWING:
			if _state == PathState.UNREACHABLE:
				path_ended.emit(false) # found there's no way after all; not asked again, since it's no longer under way
			return Vector3.ZERO # still waiting, or found there's no way after all
	if _corners.is_empty():
		return Vector3.ZERO
	# Crossing a link and taking too long, such as after falling short of a jump: a new path, same goal.
	if _ticks_on_link >= 0:
		_ticks_on_link += pawn.ticks_elapsed
		if _ticks_on_link > roundi(link_timeout * Engine.physics_ticks_per_second):
			# Once per move_to. A link that can't be crossed would otherwise be tried forever, since a new path picks it again.
			if _new_paths_left <= 0:
				stop()
				_state = PathState.UNREACHABLE
				path_ended.emit(false)
				return Vector3.ZERO # gave up: not following, not arrived
			var left := _new_paths_left - 1
			move_to(_goal)
			_new_paths_left = left # move_to resets it for a fresh request; this isn't one
			# A PENDING new path has no corners yet, and would count as arrived below.
			if _state != PathState.FOLLOWING:
				return Vector3.ZERO # nowhere to go from here, or waiting for nav
	var at := pawn.global_position
	while _next_corner < _corners.size():
		var to_corner := _corners[_next_corner] - at
		to_corner.y = 0.0
		var is_last := _next_corner == _corners.size() - 1
		var close_enough := arrival_distance if is_last else corner_reached_distance
		if to_corner.length() > close_enough:
			return to_corner.normalized()
		_reached_corner(_next_corner)
		_next_corner += 1
	# Past the last corner: there.
	_corners = PackedVector3Array()
	_next_corner = 0
	_link_ids = PackedInt64Array()
	_ticks_on_link = -1
	_state = PathState.ARRIVED # _partial stays, so whatever asked can tell how close it got
	arrived.emit()
	path_ended.emit(true)
	return Vector3.ZERO


## The named action to press this tick for a link the pawn just reached, such as &"jump", or empty. It's given once: call it after
## [method get_move_direction], each tick, and press what it gives for that tick.
func take_link_action() -> StringName:
	var action := _action_to_press
	_action_to_press = &""
	return action


## True while the pawn is between a link's start and its end. CrowdMover moves such a pawn by physics, since a jump or a drop leaves
## the nav mesh on purpose.
func is_crossing_link() -> bool:
	return _ticks_on_link >= 0


## True while there's a path being followed.
func is_following_path() -> bool:
	return _state == PathState.FOLLOWING


## True once the last move_to reached its end, until the next move_to or [method stop].
func has_arrived() -> bool:
	return _state == PathState.ARRIVED


## Where the last move_to stands (see [enum PathState]).
func get_path_state() -> PathState:
	return _state


## True while the last move_to is going somewhere: following its path, or waiting (PENDING). Controllers ask for a direction each
## tick while this is true, which is also what lets a PENDING wait try again.
func is_under_way() -> bool:
	return _state == PathState.FOLLOWING or _state == PathState.PENDING


## True when the path ends at the closest place it can reach rather than at the point, such as a point on an island. Stays true after
## arriving there, until the next move_to or [method stop].
func is_partial() -> bool:
	return _partial


## The corners still ahead, starting with the one being walked to. For debug drawing. Empty when there's no path.
func get_path_corners() -> PackedVector3Array:
	if _corners.is_empty():
		return PackedVector3Array()
	return _corners.slice(_next_corner)


# A corner was just reached. If a link starts there, the pawn begins crossing it: the next corner is its end.
func _reached_corner(index: int) -> void:
	_ticks_on_link = -1 # reaching any corner means the link before it, if any, is done
	if index >= _link_ids.size() or _link_ids[index] == 0:
		return
	var nav := _nav_server()
	_action_to_press = nav.get_link_action(_link_ids[index]) if nav else &""
	_ticks_on_link = 0


# Finds a path from where the pawn stands to the point, and sets it up to follow. Returns the state it leads to: FOLLOWING (a path,
# or a straight line), PENDING (nav still being built, or the path queued) or UNREACHABLE. move_to and PENDING's retries use it.
func _find_path(point: Vector3) -> PathState:
	var start := pawn.global_position
	var nav := _nav_server()
	if nav == null:
		return _straight_line(start, point) # no nav library at all
	if nav.closest_point(start, nav_tier) == null:
		# NavServer is idle once every tile it was asked for is built. Not idle, the nav under the pawn may just not be built yet.
		return PathState.PENDING if not nav.is_idle() else _straight_line(start, point)
	# Nav under the pawn. From here, no path is UNREACHABLE whether or not nav is still building (README, How a move works).
	# Straight away if this tick's budget allows; otherwise queued, and the pawn waits until get_move_direction takes the answer.
	if not _may_search_now():
		_path_request = nav.find_path(start, point, nav_tier, use_links)
		return PathState.PENDING
	# One search either way, which says whether the path is partial, with links or without. With use_links, a path may cross links,
	# with each link's id at the corner where it starts.
	return _follow(nav.find_path_now_result(start, point, nav_tier, use_links))


# One more path straight away this tick, if the budget allows; counts it if so.
static func _may_search_now() -> bool:
	if TickDriver.tick != _paths_now_tick:
		_paths_now_tick = TickDriver.tick
		_paths_now_used = 0
	if _paths_now_used >= paths_now_per_tick:
		return false
	_paths_now_used += 1
	return true


# Sets up a found path to follow, straight away or from the queue: {points, link_ids, partial} (a queued one also says ok and why
# not). Returns FOLLOWING, or UNREACHABLE if there's no path.
func _follow(found: Dictionary) -> PathState:
	var points: PackedVector3Array = found.points
	_link_ids = found.link_ids
	_partial = found.partial
	if points.size() < 2:
		_link_ids = PackedInt64Array()
		_partial = false
		return PathState.UNREACHABLE
	_corners = points
	_next_corner = 1 # corner 0 is where the pawn stands
	return PathState.FOLLOWING


# A straight line from the pawn to the point, if straight_line_without_nav allows it.
func _straight_line(start: Vector3, point: Vector3) -> PathState:
	if not straight_line_without_nav:
		return PathState.UNREACHABLE
	_corners = PackedVector3Array([start, point])
	_next_corner = 1
	return PathState.FOLLOWING


func _nav_server() -> Object:
	# NavServer is an engine singleton from the navcore library; without the library there is none.
	if Engine.has_singleton(&"NavServer"):
		return Engine.get_singleton(&"NavServer")
	return null
