## Written by Claude (claude-opus-5-5), 2026-11-08: the pawn's only contact with navigation. Pawn spec section 7, build step 7.
## A part on the pawn, added by PawnInitializer. Both controllers use it: PlayerController for click-to-move, and AIController
## for move_to.
##
## How to use it:
##   pawn.navigation_manager.move_to(point)          # finds a path; false if there's no way there
##   pawn.navigation_manager.get_move_direction()    # which way to walk this tick; zero when there's no path
##   pawn.navigation_manager.is_following_path()
##   pawn.navigation_manager.has_arrived()           # true once the last move_to got there, until the next move_to or stop()
##   pawn.navigation_manager.stop()
##   pawn.navigation_manager.get_path_state()        # Claude 2026-11-16: NONE, FOLLOWING, PENDING, ARRIVED or UNREACHABLE
##   pawn.navigation_manager.is_under_way()          # following a path, or waiting for nav to be built so it can find one
##   pawn.navigation_manager.is_partial()            # the path ends at the closest place it can reach, not at the point
##
## It never moves the pawn and never ticks on its own. A controller asks get_move_direction() once per tick and puts the answer
## in its InputCommand's move, the same way a player's keys would. So over the network a client follows its own path and only
## sends directions: the server never sees a path (pawn spec section 7, netcode spec open question 15).
##
## The path's corners stay private. Something that wants to draw them can call get_path_corners().
##
## What happens in odd cases (all checked in tests/navigation_manager_selftest.gd):
##   Claude 2026-11-16: each case now ends in a path state (get_path_state()) rather than a silent straight line.
##   - No NavServer (the navcore library isn't loaded), or no nav under the pawn and none being built (a level with no nav fed to
##     it): it walks in a straight line to the point, so click-to-move still works in a bare test level. That's a choice,
##     straight_line_without_nav, on by default; off, move_to returns false (UNREACHABLE) instead.
##   - Nav still being built (NavServer isn't idle) and no nav yet under the pawn: PENDING. move_to returns true, the pawn stands,
##     and it tries again every pending_retry_ticks, until it finds a path (FOLLOWING), nav finishes with still none under it (the
##     straight line, as above), or pending_give_up_ticks pass (UNREACHABLE).
##   - Nav under the pawn, but the point is nowhere near nav: move_to returns false (UNREACHABLE), and any path it had is dropped.
##     That's so even while nav is being built elsewhere: in a streaming game it nearly always is, and something asking for a far
##     point, such as AIGoToPointBehaviour's legs, picks a nearer one when told no, rather than standing and waiting.
##   - A point on nav it can't reach, such as an island: the nav library gives the path to the nearest place it can reach, so the
##     pawn walks as close as it can, and arrives there. is_partial() says so, while following and after arriving, so whatever
##     asked can tell "got there" from "got as close as it could". Claude 2026-11-17 (C++ bundle stage 2): with use_links on or
##     off, through NavServer.find_path_now_result (before, a path without links had no partial flag).
##   - Its parent isn't a Pawn: it warns, and move_to always returns false.
##   - The controller in charge changes: ControllerManager calls stop(), so the AI never walks the rest of a player's path.
##
## Claude 2026-11-08: links (nav phase 3). A path may cross links: jumps over gaps and up ledges and drops off them, which nav
## finds by itself, and links a designer placed (NavLinkModule). When the pawn reaches a link's start, take_link_action() gives
## the named action to press, such as jump, and the controller presses it for one tick. A drop has no action: the pawn walks off.
## If the pawn hasn't reached the link's far end within link_timeout seconds, say after a jump that fell short, it finds a new
## path to the same place. That happens once per move_to: missing a second time, it stops, neither following nor arrived, so
## whatever asked can choose something else. A link that can't be crossed is never tried forever. Claude 2026-11-16: that's UNREACHABLE.
##
## Later, from the old guide's section 8: finding a new path when nav tiles change, size tiers per pawn, and domains (air, ships).
class_name NavigationManager
extends Node

## Sent once when the end of a path is reached.
signal arrived

## Claude 2026-11-16: where the last move_to stands. Read it with get_path_state().
enum PathState {
	NONE, ## no move_to yet, or stop() since
	FOLLOWING, ## walking a path, or a straight line where there's no nav
	PENDING, ## nav is still being built, and there's none under the pawn yet; it tries again every pending_retry_ticks
	ARRIVED, ## got to the end of the path. With is_partial(), that's the closest place it could reach, not the point
	UNREACHABLE, ## no way there: nowhere near nav, a link it missed twice, or nav wasn't built in time
}

## How close, in metres, the pawn must get to a corner of the path before it heads for the next one. Measured flat, ignoring
## height, because a path's height between corners isn't the ground.
@export var corner_reached_distance := 0.5
## How close, in metres, it must get to the end of the path to count as arrived. Smaller than corner_reached_distance, because the
## end is where something wanted to be.
@export var arrival_distance := 0.3
## Which size of nav to use. 0 is the smallest. The nav spec's tiers are by pawn radius; t0 builds only tier 0.
@export var nav_tier := 0
## Claude 2026-11-08: on, paths may cross links (jumps, drops, placed links). Turn it off for a pawn that can't jump, so it only
## goes where it can walk.
@export var use_links := true
## Claude 2026-11-08: how long, in seconds, the pawn has to get from a link's start to its end. Past that it finds a new path,
## from wherever it ended up, to the same place.
@export var link_timeout := 3.0
## Claude 2026-11-16: on, a move_to where there's no nav at all, and none being built, walks in a straight line (bare test levels,
## click-to-move without nav). Off, it's UNREACHABLE, for a game where walking off the nav would be a bug.
@export var straight_line_without_nav := true
## Claude 2026-11-16: while PENDING, how often it tries again to find a path, in ticks at 60 a second.
@export var pending_retry_ticks := 10
## Claude 2026-11-16: how long it waits, in ticks at 60 a second, for nav to be built before giving up (UNREACHABLE). 300 is 5 s.
## Claude 2026-11-17: and for a queued path (paths_now_per_tick) to come.
@export var pending_give_up_ticks := 300

## Claude 2026-11-17 (C++ bundle stage 3, from the code audit): how many paths every pawn together finds straight away in one tick.
## Any more go to NavServer's queue, which searches within its own budget a tick (query_iterations_per_tick, across links too) and
## spreads them over the next ticks, and each of those pawns waits, PENDING, for its path. Most ticks need a handful; this is for a
## mass repath, an army given a new goal in one tick, which used to search every path at once on the main thread. 0 sends every path
## through the queue. GDScript note: a static var is shared by every NavigationManager, since the budget is the whole game's.
static var paths_now_per_tick := 8
static var _paths_now_tick := -1 # the tick _paths_now_used counts
static var _paths_now_used := 0

## The pawn this manager belongs to, or null if its parent isn't one.
var pawn: Pawn = null

var _corners := PackedVector3Array()
var _next_corner := 0 # index into _corners of the corner being walked to
# Claude 2026-11-16: path states. _state replaces a has-arrived flag; has_arrived() reads it.
var _state := PathState.NONE
var _partial := false # the path ends at the closest place it can reach; kept after arriving, until the next move_to or stop()
var _pending_ticks := 0 # how long it's been PENDING
# Claude 2026-11-08: links. One id per corner, not 0 where that corner starts a link. Empty when the path has no link info.
var _link_ids := PackedInt64Array()
var _goal := Vector3.ZERO # where the last move_to was going, for finding a new path after a missed link
var _action_to_press: StringName = &"" # waiting for the controller to take it
var _ticks_on_link := -1 # -1: not crossing a link
var _new_paths_left := 1 # how many more times a missed link may lead to a new path, before it gives up
var _path_request := 0 # Claude 2026-11-17: the queued search this pawn is waiting for (NavServer.find_path), or 0


func _init() -> void:
	# GDScript note: this part does nothing per frame. Controllers call get_move_direction() on the pawn's tick.
	set_process(false)
	set_physics_process(false)


func _enter_tree() -> void:
	pawn = get_parent() as Pawn # GDScript note: "as" gives null when the parent isn't a Pawn, rather than an error
	if pawn == null:
		push_warning("NavigationManager: its parent isn't a Pawn, so it can't find paths for anything.")


## Finds a path from the pawn to this point and starts following it. Returns false, and stops, if there's no way there
## (UNREACHABLE). With no nav at all, it goes in a straight line and returns true. Claude 2026-11-16: while nav is still being
## built, it returns true and waits (PENDING); see the top of the file.
func move_to(point: Vector3) -> bool:
	stop()
	if pawn == null:
		_state = PathState.UNREACHABLE
		return false
	_goal = point
	_new_paths_left = 1 # Claude 2026-11-08
	_state = _find_path(point) # Claude 2026-11-16: the finding moved to _find_path, which PENDING's retries use too
	return _state != PathState.UNREACHABLE


## Stops following the path. has_arrived() goes back to false, and the state to NONE.
func stop() -> void:
	if _path_request != 0: # Claude 2026-11-17: a queued search nobody wants any more
		var nav := _nav_server()
		if nav:
			nav.cancel_path(_path_request)
		_path_request = 0
	_corners = PackedVector3Array()
	_next_corner = 0
	_state = PathState.NONE # Claude 2026-11-16
	_partial = false
	_pending_ticks = 0
	_link_ids = PackedInt64Array() # Claude 2026-11-08
	_action_to_press = &""
	_ticks_on_link = -1


## Which way to walk now: flat, length 1, or zero when there's no path. Call it once per tick, because it also moves on to the
## next corner when the pawn is close enough, and finishes the path at the end.
func get_move_direction() -> Vector3:
	if pawn == null:
		return Vector3.ZERO
	# Claude 2026-11-16: waiting for nav to be built. Try again now and then, and give up after a while.
	if _state == PathState.PENDING:
		var elapsed := pawn.ticks_elapsed # Claude 2026-11-16 (pawn spec 8.21): the ticks since its pawn last ran
		_pending_ticks += elapsed
		if _pending_ticks >= TickDriver.ticks_at_rate(pending_give_up_ticks):
			stop() # Claude 2026-11-17: which also cancels a queued search
			_state = PathState.UNREACHABLE
			return Vector3.ZERO
		if _path_request != 0:
			# Claude 2026-11-17 (C++ bundle stage 3): waiting for a queued path, which comes as a dictionary once it's found.
			var nav := _nav_server()
			var found: Dictionary = nav.take_path_result(_path_request) if nav else {}
			if not found.is_empty():
				_path_request = 0
				_state = _follow(found)
		elif _pending_ticks % maxi(1, TickDriver.ticks_at_rate(pending_retry_ticks)) < elapsed:
			_state = _find_path(_goal)
		if _state != PathState.FOLLOWING:
			return Vector3.ZERO # still waiting, or found there's no way after all
	if _corners.is_empty():
		return Vector3.ZERO
	# Claude 2026-11-08: crossing a link and taking too long, such as after falling short of a jump: a new path, same goal.
	if _ticks_on_link >= 0:
		_ticks_on_link += pawn.ticks_elapsed # Claude 2026-11-16 (pawn spec 8.21): was 1
		if _ticks_on_link > roundi(link_timeout * Engine.physics_ticks_per_second):
			# Once per move_to. A link that can't be crossed would otherwise be tried forever, since a new path picks it again.
			if _new_paths_left <= 0:
				stop()
				_state = PathState.UNREACHABLE # Claude 2026-11-16
				return Vector3.ZERO # gave up: not following, not arrived
			var left := _new_paths_left - 1
			move_to(_goal)
			_new_paths_left = left # move_to resets it for a fresh request; this isn't one
			# Claude 2026-11-16: was "if not found". A PENDING new path has no corners yet, and would have counted as arrived below.
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
	_state = PathState.ARRIVED # Claude 2026-11-16: _partial stays, so whatever asked can tell how close it got
	arrived.emit()
	return Vector3.ZERO


## Claude 2026-11-08: the named action to press this tick for a link the pawn just reached, such as &"jump", or empty. It's given
## once: call it after get_move_direction(), each tick, and press what it gives for that tick.
func take_link_action() -> StringName:
	var action := _action_to_press
	_action_to_press = &""
	return action


## Claude 2026-11-08: true while the pawn is between a link's start and its end.
func is_crossing_link() -> bool:
	return _ticks_on_link >= 0


## True while there's a path being followed.
func is_following_path() -> bool:
	return _state == PathState.FOLLOWING # Claude 2026-11-16: the same as having corners, said by the state


## True once the last move_to reached its end, until the next move_to or stop().
func has_arrived() -> bool:
	return _state == PathState.ARRIVED # Claude 2026-11-16


## Claude 2026-11-16: where the last move_to stands (PathState at the top of the file).
func get_path_state() -> PathState:
	return _state


## Claude 2026-11-16: true while the last move_to is going somewhere: following its path, or waiting for nav (PENDING). Controllers
## ask for a direction each tick while this is true, which is also what lets a PENDING wait try again.
func is_under_way() -> bool:
	return _state == PathState.FOLLOWING or _state == PathState.PENDING


## Claude 2026-11-16: true when the path ends at the closest place it can reach rather than at the point, such as a point on an
## island. Stays true after arriving there, until the next move_to or stop(). False for a path found with use_links off (see the top).
func is_partial() -> bool:
	return _partial


## The corners still ahead, starting with the one being walked to. For debug drawing. Empty when there's no path.
func get_path_corners() -> PackedVector3Array:
	if _corners.is_empty():
		return PackedVector3Array()
	return _corners.slice(_next_corner)


# Claude 2026-11-08: a corner was just reached. If a link starts there, the pawn begins crossing it: the next corner is its end.
func _reached_corner(index: int) -> void:
	_ticks_on_link = -1 # reaching any corner means the link before it, if any, is done
	if index >= _link_ids.size() or _link_ids[index] == 0:
		return
	var nav := _nav_server()
	_action_to_press = nav.get_link_action(_link_ids[index]) if nav else &""
	_ticks_on_link = 0


# Claude 2026-11-16: finds a path from where the pawn stands to the point, and sets it up to follow. Returns the state it leads
# to: FOLLOWING (a path, or a straight line), PENDING (nav still being built) or UNREACHABLE. move_to and PENDING's retries use it.
func _find_path(point: Vector3) -> PathState:
	var start := pawn.global_position
	var nav := _nav_server()
	if nav == null:
		return _straight_line(start, point) # no nav library at all
	# GDScript note: closest_point returns null when there's no nav near the point, which is why it's compared with null.
	if nav.closest_point(start, nav_tier) == null:
		# NavServer is idle once every tile it was asked for is built. Not idle, the nav under the pawn may just not be built yet.
		return PathState.PENDING if not nav.is_idle() else _straight_line(start, point)
	# Nav under the pawn. From here, no path is UNREACHABLE whether or not nav is still building (see the top of the file).
	# Claude 2026-11-17 (C++ bundle stage 3): straight away if this tick's budget allows (paths_now_per_tick); otherwise queued, and
	# the pawn waits, PENDING, until get_move_direction takes the answer.
	if not _may_search_now():
		_path_request = nav.find_path(start, point, nav_tier, use_links)
		return PathState.PENDING
	# Claude 2026-11-17 (C++ bundle stage 2): one search either way, which says whether the path is partial with links or without
	# (find_path_now gave only points). With use_links, a path may cross links, with each link's id at the corner where it starts.
	return _follow(nav.find_path_now_result(start, point, nav_tier, use_links))


# Claude 2026-11-17 (C++ bundle stage 3): one more path straight away this tick, if the budget allows; counts it if so.
static func _may_search_now() -> bool:
	if TickDriver.tick != _paths_now_tick:
		_paths_now_tick = TickDriver.tick
		_paths_now_used = 0
	if _paths_now_used >= paths_now_per_tick:
		return false
	_paths_now_used += 1
	return true


# Claude 2026-11-17 (C++ bundle stage 3): sets up a found path to follow, straight away or from the queue: {points, link_ids, partial}
# (a queued one also says ok and why not). Returns FOLLOWING, or UNREACHABLE if there's no path. Was the end of _find_path.
func _follow(found: Dictionary) -> PathState:
	var points: PackedVector3Array = found.points
	_link_ids = found.link_ids
	_partial = found.partial # Claude 2026-11-16: the nav library's own flag, which was dropped before
	if points.size() < 2:
		_link_ids = PackedInt64Array()
		_partial = false
		return PathState.UNREACHABLE
	_corners = points
	_next_corner = 1 # corner 0 is where the pawn stands
	return PathState.FOLLOWING


# Claude 2026-11-16: a straight line from the pawn to the point, if straight_line_without_nav allows it.
func _straight_line(start: Vector3, point: Vector3) -> PathState:
	if not straight_line_without_nav:
		return PathState.UNREACHABLE
	_corners = PackedVector3Array([start, point])
	_next_corner = 1
	return PathState.FOLLOWING


func _nav_server() -> Object:
	# GDScript note: NavServer comes from the navcore C++ library, registered as an engine singleton, not an autoload. If the
	# library isn't loaded, there's no singleton, and has_singleton says so instead of erroring.
	if Engine.has_singleton(&"NavServer"):
		return Engine.get_singleton(&"NavServer")
	return null
