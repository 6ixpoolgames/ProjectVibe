# Written by Claude (claude-opus-5-5), 2026-11-12. History: world/CHANGELOG.md.
## A height below which pawns die, like Unreal's "kill Z".
##
## Place one in a level at the height you want (its own Y), well below the lowest ground. A pawn that falls below it gets
## [member kill_effect], by default all its Health, so it dies the usual way (its Death ability, a respawn at a SpawnManager spawn
## point, a spawner's replacement). It runs on the authority only (the server, or offline), every [member check_every_ticks] ticks, after
## every pawn has simulated; clients see the death in snapshots. With [member report_falls] on, a warning says how the pawn got there.
# REFACTOR: the fall report is a debugging aid inside a gameplay class, on by default, and it tracks every pawn's last standing place
# on every check. A diagnostics module could do the tracking and write the report when pawn_fell fires (production kept apart from
# debug code). See CHANGELOG.md.
class_name KillFloor
extends Node3D

## Every kill floor joins this group, so a replay recording can find them and record their reports.
const GROUP := &"kill_floors"

## A pawn fell below this floor and died here, with the report of how it got here (the same words as the warning). Sent only while
## [member report_falls] is on. The replay recorder records it (ReplayGameplayChannel).
signal pawn_fell(pawn: Pawn, report: String)

## What a pawn falling below gets. By default resources/effects/kill_self.tres, which takes all its Health. Another effect can do
## something gentler, as long as it moves the pawn back up or kills it: otherwise it gets it again on every check.
@export var kill_effect: Effect = preload("res://assets/scripts/resources/effects/kill_self.tres")
## How often it checks, in ticks written for 60 a second (converted to the match's rate). A pawn falling for a few ticks more before
## it dies makes no difference, and checking less often costs less with many pawns.
@export_range(1, 600, 1, "or_greater") var check_every_ticks := 10
## On: each pawn caught here is reported in the Debugger, saying how it got here (see the class description). Off: nothing is
## reported, for a game where falling off the map is normal.
@export var report_falls := true

var _warned := {}
# For the reports, where each pawn was last seen standing: instance id -> [position, velocity, tick]. Rebuilt on every check from the
# pawns there are, so pawns that are gone drop out of it.
var _last_on_ground := {}


func _ready() -> void:
	add_to_group(GROUP)
	TickDriver.after_simulate.connect(_on_after_simulate)


func _exit_tree() -> void:
	if TickDriver.after_simulate.is_connected(_on_after_simulate):
		TickDriver.after_simulate.disconnect(_on_after_simulate)


func _on_after_simulate(_dt: float, tick: int) -> void:
	var started := PerfScopes.begin() # timed for diagnostics (PerfScopes)
	_check_pawns(tick)
	PerfScopes.end(&"world.kill_floor", started)


# The work itself, timed by _on_after_simulate.
func _check_pawns(tick: int) -> void:
	if tick % TickDriver.ticks_at_rate(check_every_ticks) != 0:
		return
	var height := global_position.y
	var seen := {} # the next _last_on_ground
	for node in get_tree().get_nodes_in_group(Pawn.GROUP): # the list of all pawns
		var pawn := node as Pawn
		if pawn == null or not pawn.is_authority() or pawn.is_dead():
			continue
		var id := pawn.get_instance_id()
		if pawn.global_position.y >= height:
			if report_falls and pawn.grounded:
				seen[id] = [pawn.global_position, pawn.velocity, tick]
			elif report_falls and _last_on_ground.has(id): # in the air: keep where it last stood
				seen[id] = _last_on_ground[id]
			continue
		# The report is written before it dies, and shown only if it did, so a pawn that can't die (which carries on falling) isn't
		# reported on every check.
		var report := fall_report(pawn, _last_on_ground.get(id), tick) if report_falls else ""
		if kill(pawn) and report_falls:
			push_warning(report)
			pawn_fell.emit(pawn, report) # for replay recordings
	_last_on_ground = seen


## Gives a pawn the kill effect. Public, so a test or a game rule can use the same way of dying. True if it got the effect, false if
## it couldn't (no effect set, or a pawn with no Health or StatusManager).
func kill(pawn: Pawn) -> bool:
	if kill_effect == null:
		_warn_once("no effect", "KillFloor %s has no kill_effect, so pawns that fall below it carry on falling." % name)
		return false
	if pawn.status_manager == null or not pawn.status_manager.has_stat(StatusManager.HEALTH):
		_warn_once(String(pawn.name), "KillFloor: %s fell below it but has no Health or no StatusManager, so it can't die there." % pawn.name)
		return false
	pawn.status_manager.apply_effect(kill_effect, null)
	return true


## The words of a fall's report. [param last_seen] is [code][position, velocity, tick][/code] from the last check that found the pawn
## standing, or null if none did. Public, so a test can read it.
func fall_report(pawn: Pawn, last_seen: Variant, tick: int) -> String:
	var at := pawn.global_position
	var text := "KillFloor: %s fell below %.0f m at x %.1f, z %.1f, so it was killed." % [pawn.name, global_position.y, at.x, at.z]
	if last_seen == null:
		text += " It wasn't seen standing on anything before."
	else:
		var seconds := float(tick - int(last_seen[2])) / TickDriver.get_tick_rate()
		var place: Vector3 = last_seen[0]
		text += " It was last standing %.1f s before, at (%.1f, %.1f, %.1f), moving at %.1f m/s." % [seconds, place.x, place.y, place.z, (last_seen[1] as Vector3).length()]
	var terrain := _terrain()
	if terrain == null:
		return text
	if terrain.has_chunk(terrain.chunk_of(at)):
		text += " The ground where it fell is built, at height %.1f, so it went through solid ground." % terrain.height_at(at.x, at.z)
	else:
		text += " No ground is built where it fell, so it went off the edge of the loaded world."
	return text


# The level's terrain, if it has one (every TerrainGenerator joins its group). The first one found, if there are several.
func _terrain() -> TerrainGenerator:
	for node in get_tree().get_nodes_in_group(TerrainGenerator.GROUP):
		if node is TerrainGenerator:
			return node
	return null


func _warn_once(key: String, message: String) -> void:
	if not _warned.has(key):
		_warned[key] = true
		push_warning(message)
