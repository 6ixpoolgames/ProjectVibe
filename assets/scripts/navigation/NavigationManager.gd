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
##
## It never moves the pawn and never ticks on its own. A controller asks get_move_direction() once per tick and puts the answer
## in its InputCommand's move, the same way a player's keys would. So over the network a client follows its own path and only
## sends directions: the server never sees a path (pawn spec section 7, netcode spec open question 15).
##
## The path's corners stay private. Something that wants to draw them can call get_path_corners().
##
## What happens in odd cases (all checked in tests/navigation_manager_selftest.gd):
##   - No NavServer (the navcore library isn't loaded), or no nav under the pawn (a level with no nav fed to it): it walks in a
##     straight line to the point, so click-to-move still works in a bare test level.
##   - Nav under the pawn, but the point is nowhere near nav: move_to returns false, and any path it had is dropped.
##   - A point on nav it can't reach, such as an island: the nav library gives the path to the nearest place it can reach, so the
##     pawn walks as close as it can, and arrives there.
##   - Its parent isn't a Pawn: it warns, and move_to always returns false.
##   - The controller in charge changes: ControllerManager calls stop(), so the AI never walks the rest of a player's path.
##
## Later, from the old guide's section 8: finding a new path when nav tiles change, size tiers per pawn, and domains (air, ships).
## Links, such as jumping a gap, come with nav phase 3.
class_name NavigationManager
extends Node

## Sent once when the end of a path is reached.
signal arrived

## How close, in metres, the pawn must get to a corner of the path before it heads for the next one. Measured flat, ignoring
## height, because a path's height between corners isn't the ground.
@export var corner_reached_distance := 0.5
## How close, in metres, it must get to the end of the path to count as arrived. Smaller than corner_reached_distance, because the
## end is where something wanted to be.
@export var arrival_distance := 0.3
## Which size of nav to use. 0 is the smallest. The nav spec's tiers are by pawn radius; t0 builds only tier 0.
@export var nav_tier := 0

## The pawn this manager belongs to, or null if its parent isn't one.
var pawn: Pawn = null

var _corners := PackedVector3Array()
var _next_corner := 0 # index into _corners of the corner being walked to
var _arrived := false


func _init() -> void:
	# GDScript note: this part does nothing per frame. Controllers call get_move_direction() on the pawn's tick.
	set_process(false)
	set_physics_process(false)


func _enter_tree() -> void:
	pawn = get_parent() as Pawn # GDScript note: "as" gives null when the parent isn't a Pawn, rather than an error
	if pawn == null:
		push_warning("NavigationManager: its parent isn't a Pawn, so it can't find paths for anything.")


## Finds a path from the pawn to this point and starts following it. Returns false, and stops, if there's no way there.
## With no nav at all, it goes in a straight line and returns true.
func move_to(point: Vector3) -> bool:
	stop()
	if pawn == null:
		return false
	var start := pawn.global_position
	var nav := _nav_server()
	# GDScript note: closest_point returns null when there's no nav near the point, which is why it's an untyped var.
	if nav == null or nav.closest_point(start, nav_tier) == null:
		_corners = PackedVector3Array([start, point]) # no nav here at all: a straight line
	else:
		var found: PackedVector3Array = nav.find_path_now(start, point, nav_tier)
		if found.size() < 2:
			return false
		_corners = found
	_next_corner = 1 # corner 0 is where the pawn stands
	return true


## Stops following the path. has_arrived() goes back to false.
func stop() -> void:
	_corners = PackedVector3Array()
	_next_corner = 0
	_arrived = false


## Which way to walk now: flat, length 1, or zero when there's no path. Call it once per tick, because it also moves on to the
## next corner when the pawn is close enough, and finishes the path at the end.
func get_move_direction() -> Vector3:
	if pawn == null or _corners.is_empty():
		return Vector3.ZERO
	var at := pawn.global_position
	while _next_corner < _corners.size():
		var to_corner := _corners[_next_corner] - at
		to_corner.y = 0.0
		var is_last := _next_corner == _corners.size() - 1
		var close_enough := arrival_distance if is_last else corner_reached_distance
		if to_corner.length() > close_enough:
			return to_corner.normalized()
		_next_corner += 1
	# Past the last corner: there.
	_corners = PackedVector3Array()
	_next_corner = 0
	_arrived = true
	arrived.emit()
	return Vector3.ZERO


## True while there's a path being followed.
func is_following_path() -> bool:
	return not _corners.is_empty()


## True once the last move_to reached its end, until the next move_to or stop().
func has_arrived() -> bool:
	return _arrived


## The corners still ahead, starting with the one being walked to. For debug drawing. Empty when there's no path.
func get_path_corners() -> PackedVector3Array:
	if _corners.is_empty():
		return PackedVector3Array()
	return _corners.slice(_next_corner)


func _nav_server() -> Object:
	# GDScript note: NavServer comes from the navcore C++ library, registered as an engine singleton, not an autoload. If the
	# library isn't loaded, there's no singleton, and has_singleton says so instead of erroring.
	if Engine.has_singleton(&"NavServer"):
		return Engine.get_singleton(&"NavServer")
	return null
