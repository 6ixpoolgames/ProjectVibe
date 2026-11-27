# Written by Claude (claude-opus-5-5), 2026-11-25. History: navigation/CHANGELOG.md.
## Follows one nav path for one pawn: finds it through NavServer, keeps its corners, and says which way to walk each tick.
##
## Held by whatever moves a pawn along a path: a [MoveStep] (the player's click-to-move), or the AIController's orders until the
## behaviour steps take over (pawn spec 16.7, 16.10 step 5). It never moves the pawn: its owner asks [method get_move_direction] once
## per tick and puts the answer in an input's move, as a player's keys would, and presses the action [method take_link_press] gives
## at a link's start. Every wait is a tick deadline. Over the network a client follows its own path and only sends directions.
## [codeblock]
## follower.move_to(point)           # finds a path; false if there's no way there
## follower.get_move_direction()     # which way to walk this tick; zero when there's no path
## follower.get_path_state()         # NONE, FOLLOWING, PENDING, ARRIVED or UNREACHABLE
## [/codeblock]
## How it follows is a shared [PathFollowSettings] ([member settings]). No nav at all means a straight line; nav still building means
## PENDING; [method get_end_reason] says why a path ended. The navigation README's "How a move works" has the odd cases.
class_name PathFollower
extends RefCounted

## Sent once when the end of a path is reached.
signal arrived
## Sent once when a path ends: reached is true after [signal arrived], false when it gave up (no way, nav too slow, a link not
## crossed). Not sent for [method stop]. Move steps read the path state instead, and AI behaviours wake when a step ends (AIBehaviourBase.wake_on_step_end).
signal path_ended(reached: bool)

## Where the last move_to stands. Read it with [method get_path_state].
enum PathState {
	NONE, ## no move_to yet, or stop() since
	FOLLOWING, ## walking a path, or a straight line where there's no nav
	PENDING, ## waiting: for nav to be built under the pawn (it tries again every pending_retry_ticks), or for a queued path
	ARRIVED, ## got to the end of the path. With is_partial(), that's the closest place it could reach, not the point
	UNREACHABLE, ## no way there: nowhere near nav, a link it missed twice, or nav or a queued path didn't come in time
}

## Why the last path ended. Read it with [method get_end_reason]; it stays after [method stop], until the next move_to.
enum EndReason {
	NONE, ## still going, or no move_to yet
	ARRIVED, ## got to the end of its path (with is_partial(), the closest place it could reach)
	NO_WAY, ## no path: nowhere near nav, or the point can't be reached and nav is built
	NAV_TOO_SLOW, ## nav under the pawn, or a queued path, didn't come within pending_give_up_ticks
	LINK_MISSED, ## it missed a link twice (the second time on a new path)
	STOPPED, ## stop() was called while it was going somewhere
}

## How it follows: closeness, which nav, links, waiting for nav. Shared, read as it goes; never null (the defaults when none is given).
var settings: PathFollowSettings:
	get:
		return settings if settings else _default_settings
	set(value):
		settings = value

## How many paths all pawns together find straight away in one tick. Any more go to NavServer's queue (searched within its own budget
## a tick, across links too), and those pawns wait PENDING. 0 sends every path through the queue. Shared by every follower.
static var paths_now_per_tick := 8
static var _paths_now_tick := -1 # the tick _paths_now_used counts
static var _paths_now_used := 0
static var _default_settings := PathFollowSettings.new() # for followers given none

## The pawn it moves. Null: move_to finds no way.
var pawn: Pawn = null

var _corners := PackedVector3Array()
var _next_corner := 0 # index into _corners of the corner being walked to
var _state := PathState.NONE
var _partial := false # the path ends at the closest place it can reach; kept after arriving, until the next move_to or stop()
var _give_up_tick := 0 # PENDING: the tick it gives up
var _retry_tick := 0 # PENDING for nav to be built: the tick it next tries again
var _link_ids := PackedInt64Array() # one id per corner, not 0 where that corner starts a link; empty when the path has no link info
var _goal := Vector3.ZERO # where the last move_to was going, for finding a new path after a missed link
var _action_to_press: StringName = &"" # waiting for the owner to take it
var _link_deadline := -1 # crossing a link: the tick it must be across by; -1 when not crossing one
var _new_paths_left := 1 # how many more times a missed link may lead to a new path, before it gives up
var _path_request := 0 # the queued search this pawn is waiting for (NavServer.find_path), or 0
var _end_reason := EndReason.NONE


func _init(for_pawn: Pawn = null) -> void:
	pawn = for_pawn


## Finds a path from the pawn to this point and starts following it. Returns false, and stops, if there's no way there
## (UNREACHABLE). With no nav at all, it goes in a straight line and returns true. While nav is still being built, or the path is
## queued, it returns true and waits (PENDING).
func move_to(point: Vector3) -> bool:
	_clear()
	_end_reason = EndReason.NONE
	if pawn == null:
		_state = PathState.UNREACHABLE
		_end_reason = EndReason.NO_WAY
		return false
	_goal = point
	_new_paths_left = 1
	_state = _find_path(point)
	if _state == PathState.UNREACHABLE:
		_end_reason = EndReason.NO_WAY
	return _state != PathState.UNREACHABLE


## Stops following the path, and cancels a queued one. [method has_arrived] goes back to false, and the state to NONE; a path still
## under way ends with STOPPED ([method get_end_reason]).
func stop() -> void:
	if is_under_way():
		_end_reason = EndReason.STOPPED
	_clear()


# Drops the path and any queued search, leaving the end reason alone.
func _clear() -> void:
	if _path_request != 0: # a queued search nobody wants any more
		var nav := _nav_server()
		if nav:
			nav.cancel_path(_path_request)
		_path_request = 0
	_corners = PackedVector3Array()
	_next_corner = 0
	_state = PathState.NONE
	_partial = false
	_link_ids = PackedInt64Array()
	_action_to_press = &""
	_link_deadline = -1


## Which way to walk now: flat, length 1, or zero when there's no path. Call it once per tick, because it also moves on to the
## next corner when the pawn is close enough, finishes the path at the end, and runs PENDING's retries.
func get_move_direction() -> Vector3:
	if pawn == null:
		return Vector3.ZERO
	var now: int = TickDriver.tick
	# Waiting for nav to be built or for a queued path. Try again now and then, and give up after a while.
	if _state == PathState.PENDING:
		if now >= _give_up_tick:
			_clear() # which also cancels a queued search
			_state = PathState.UNREACHABLE
			_end_reason = EndReason.NAV_TOO_SLOW
			path_ended.emit(false)
			return Vector3.ZERO
		if _path_request != 0:
			# A queued path comes as a dictionary once it's found.
			var nav := _nav_server()
			var found: Dictionary = nav.take_path_result(_path_request) if nav else {}
			if not found.is_empty():
				_path_request = 0
				_state = _follow(found)
		elif now >= _retry_tick:
			_state = _find_path(_goal, false)
		if _state != PathState.FOLLOWING:
			if _state == PathState.UNREACHABLE:
				_end_reason = EndReason.NO_WAY
				path_ended.emit(false) # found there's no way after all; not asked again, since it's no longer under way
			return Vector3.ZERO # still waiting, or found there's no way after all
	if _corners.is_empty():
		return Vector3.ZERO
	# Crossing a link and taking too long, such as after falling short of a jump: a new path, same goal.
	if _link_deadline >= 0 and now > _link_deadline:
		# Once per move_to. A link that can't be crossed would otherwise be tried forever, since a new path picks it again.
		if _new_paths_left <= 0:
			_clear()
			_state = PathState.UNREACHABLE
			_end_reason = EndReason.LINK_MISSED
			path_ended.emit(false)
			return Vector3.ZERO # gave up: not following, not arrived
		var left := _new_paths_left - 1
		move_to(_goal)
		_new_paths_left = left # move_to resets it for a fresh request; this isn't one
		# A PENDING new path has no corners yet, and would count as arrived below.
		if _state != PathState.FOLLOWING:
			return Vector3.ZERO # nowhere to go from here, or waiting for nav
	var at := pawn.global_position
	var follow := settings
	while _next_corner < _corners.size():
		var to_corner := _corners[_next_corner] - at
		to_corner.y = 0.0
		var is_last := _next_corner == _corners.size() - 1
		var close_enough := follow.arrival_distance if is_last else follow.corner_reached_distance
		if to_corner.length() > close_enough:
			return to_corner.normalized()
		_reached_corner(_next_corner, now)
		_next_corner += 1
	# Past the last corner: there.
	_corners = PackedVector3Array()
	_next_corner = 0
	_link_ids = PackedInt64Array()
	_link_deadline = -1
	_state = PathState.ARRIVED # _partial stays, so whatever asked can tell how close it got
	_end_reason = EndReason.ARRIVED
	arrived.emit()
	path_ended.emit(true)
	return Vector3.ZERO


## How far, flat, the pawn is from the stretch of path it's walking (from the last corner passed to the next); 0 when it isn't
## following a path. A [MoveStep] finds a new path once this is past its off_path_metres, as after a knockback.
func distance_off_path() -> float:
	if pawn == null or _state != PathState.FOLLOWING or _next_corner >= _corners.size():
		return 0.0
	var to := _corners[_next_corner]
	var from := _corners[_next_corner - 1] if _next_corner > 0 else to
	var at := pawn.global_position
	var a := Vector2(from.x, from.z)
	var b := Vector2(to.x, to.z)
	var p := Vector2(at.x, at.z)
	var along := b - a
	var t := clampf((p - a).dot(along) / along.length_squared(), 0.0, 1.0) if along.length_squared() > 0.000001 else 0.0
	return p.distance_to(a + along * t)


## The named action to press this tick for a link the pawn just reached, such as &"jump", or empty. It's given once: call it after
## [method get_move_direction], each tick, and press what it gives for that tick.
func take_link_action() -> StringName:
	var action := _action_to_press
	_action_to_press = &""
	return action


## [method take_link_action] as input bits ([InputActions]), 0 when there's nothing to press: OR it into this tick's held actions.
func take_link_press() -> int:
	var action := take_link_action()
	return InputActions.mask_of(action) if action != &"" else 0


## True while the pawn is between a link's start and its end. CrowdMover moves such a pawn by physics, since a jump or a drop leaves
## the nav mesh on purpose.
func is_crossing_link() -> bool:
	return _link_deadline >= 0


## True while there's a path being followed.
func is_following_path() -> bool:
	return _state == PathState.FOLLOWING


## True once the last move_to reached its end, until the next move_to or [method stop].
func has_arrived() -> bool:
	return _state == PathState.ARRIVED


## Where the last move_to stands (see [enum PathState]).
func get_path_state() -> PathState:
	return _state


## True while the last move_to is going somewhere: following its path, or waiting (PENDING). Its owner asks for a direction each tick
## while this is true, which is also what lets a PENDING wait try again.
func is_under_way() -> bool:
	return _state == PathState.FOLLOWING or _state == PathState.PENDING


## True when the path ends at the closest place it can reach rather than at the point, such as a point on an island. Stays true after
## arriving there, until the next move_to or [method stop].
func is_partial() -> bool:
	return _partial


## Why the last path ended ([enum EndReason]); NONE while it's still going. Kept after [method stop], until the next move_to.
func get_end_reason() -> EndReason:
	return _end_reason


## Where the last move_to was going. Kept after it ends, until the next one.
func get_goal() -> Vector3:
	return _goal


## The corners still ahead, starting with the one being walked to. For debug drawing. Empty when there's no path.
func get_path_corners() -> PackedVector3Array:
	if _corners.is_empty():
		return PackedVector3Array()
	return _corners.slice(_next_corner)


# A corner was just reached. If a link starts there, the pawn begins crossing it: the next corner is its end.
func _reached_corner(index: int, now: int) -> void:
	_link_deadline = -1 # reaching any corner means the link before it, if any, is done
	if index >= _link_ids.size() or _link_ids[index] == 0:
		return
	var nav := _nav_server()
	_action_to_press = nav.get_link_action(_link_ids[index]) if nav else &""
	_link_deadline = now + TickDriver.ticks_at_rate(settings.link_timeout_ticks)


# Finds a path from where the pawn stands to the point, and sets it up to follow. Returns the state it leads to: FOLLOWING (a path,
# or a straight line), PENDING (nav still being built, or the path queued) or UNREACHABLE. move_to and PENDING's retries use it; a
# retry keeps the give-up deadline the first try set.
func _find_path(point: Vector3, first_try := true) -> PathState:
	var start := pawn.global_position
	var nav := _nav_server()
	if nav == null:
		return _straight_line(start, point) # no nav library at all
	var now: int = TickDriver.tick
	var follow := settings
	if nav.closest_point(start, follow.nav_tier) == null:
		# NavServer is idle once every tile it was asked for is built. Not idle, the nav under the pawn may just not be built yet.
		if nav.is_idle():
			return _straight_line(start, point)
		_wait_from(now, first_try)
		_retry_tick = now + maxi(1, TickDriver.ticks_at_rate(follow.pending_retry_ticks))
		return PathState.PENDING
	# Nav under the pawn. From here, no path is UNREACHABLE whether or not nav is still building (README, How a move works).
	# Straight away if this tick's budget allows; otherwise queued, and the pawn waits until get_move_direction takes the answer.
	if not _may_search_now():
		_path_request = nav.find_path(start, point, follow.nav_tier, follow.use_links)
		_wait_from(now, first_try)
		return PathState.PENDING
	# One search either way, which says whether the path is partial, with links or without. With use_links, a path may cross links,
	# with each link's id at the corner where it starts.
	return _follow(nav.find_path_now_result(start, point, follow.nav_tier, follow.use_links))


# PENDING starts now: the give-up deadline, set once per wait.
func _wait_from(now: int, first_try: bool) -> void:
	if first_try:
		_give_up_tick = now + TickDriver.ticks_at_rate(settings.pending_give_up_ticks)


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
	if not settings.straight_line_without_nav:
		return PathState.UNREACHABLE
	_corners = PackedVector3Array([start, point])
	_next_corner = 1
	return PathState.FOLLOWING


func _nav_server() -> Object:
	# NavServer is an engine singleton from the navcore library; without the library there is none.
	if Engine.has_singleton(&"NavServer"):
		return Engine.get_singleton(&"NavServer")
	return null
