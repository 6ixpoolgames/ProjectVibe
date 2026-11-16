## Written by Claude (claude-opus-5-5), 2026-11-12: a height below which pawns die, the owner's request after falling through the world
## twice while away from the keyboard. Like Unreal's "kill Z": place one in a level, at the height you want (its own Y), well below
## the lowest ground. A pawn that falls below it gets kill_effect, which by default takes all its Health, so it dies the usual way:
## its Death ability runs, a player comes back at a spawn point (SpawnManager), and a spawner's pawn is replaced.
##
## How it works: on the authority only (the server, or offline), every check_every_ticks ticks, after every pawn has simulated, it
## looks at each pawn in the tree. One below the height that isn't dead already gets the effect. Clients do nothing: the death
## reaches them in snapshots, as any death does.
##
## Odd cases:
##   - A pawn with no Health or no Death ability can't die, so it keeps falling. It's warned about once, by name.
##   - No kill_effect: nothing happens to anyone, and a warning says so once.
##   - Several KillFloors: each checks on its own.
##
## Claude 2026-11-12: reporting falls (report_falls). The owner fell through the world twice while away, and a long idle run here
## didn't do it again, so when a pawn falls this far, a warning in the Debugger says how it got there: where it was last standing,
## how long before, how fast it was going, and whether there's ground at the spot it fell through. Ground there means it went through
## solid ground (a physics bug); no ground means it went off the edge of the loaded world (a streaming bug, or the end of the map).
class_name KillFloor
extends Node3D

## Claude 2026-11-15: every kill floor joins this group, so a replay recording can find them and record their reports.
const GROUP := &"kill_floors"

## Claude 2026-11-15: a pawn fell below this floor and died here, with the report of how it got here (the same words as the warning).
## Sent only while report_falls is on. The replay recorder records it (ReplayGameplayChannel).
signal pawn_fell(pawn: Pawn, report: String)

## What a pawn falling below gets. By default resources/effects/kill_self.tres, which takes all its Health. Another effect can do
## something gentler, as long as it moves the pawn back up or kills it: otherwise it gets it again on every check.
@export var kill_effect: Effect = preload("res://assets/scripts/resources/effects/kill_self.tres")
## How often it checks, in ticks written for 60 a second (converted to the match's rate). A pawn falling for a few ticks more before
## it dies makes no difference, and checking less often costs less with many pawns.
@export_range(1, 600, 1, "or_greater") var check_every_ticks := 10
## Claude 2026-11-12: on: each pawn caught here is reported in the Debugger, saying how it got here (see the top of the file). Off:
## nothing is reported, for a game where falling off the map is normal.
@export var report_falls := true

var _warned := {}
# Claude 2026-11-12: for the reports, where each pawn was last seen standing: instance id -> [position, velocity, tick]. Rebuilt on
# every check from the pawns there are, so pawns that are gone drop out of it.
var _last_on_ground := {}


func _ready() -> void:
	add_to_group(GROUP) # Claude 2026-11-15
	# GDScript note: after_simulate fires once per tick, after every pawn has simulated, with the tick's length and number.
	TickDriver.after_simulate.connect(_on_after_simulate)


func _exit_tree() -> void:
	if TickDriver.after_simulate.is_connected(_on_after_simulate):
		TickDriver.after_simulate.disconnect(_on_after_simulate)


func _on_after_simulate(_dt: float, tick: int) -> void:
	var started := PerfScopes.begin() # Claude 2026-11-16: timed for diagnostics (PerfScopes)
	_check_pawns(tick)
	PerfScopes.end(&"world.kill_floor", started)


# Claude 2026-11-16: the work itself, timed by _on_after_simulate.
func _check_pawns(tick: int) -> void:
	if tick % TickDriver.ticks_at_rate(check_every_ticks) != 0:
		return
	var height := global_position.y
	var seen := {} # Claude 2026-11-12: the next _last_on_ground
	for node in get_tree().get_nodes_in_group(Pawn.GROUP): # Claude 2026-11-16 (wider audit): the list of all pawns
		var pawn := node as Pawn
		if pawn == null or not pawn.is_authority() or pawn.is_dead():
			continue
		var id := pawn.get_instance_id()
		if pawn.global_position.y >= height:
			if report_falls and pawn.grounded: # Claude 2026-11-12
				seen[id] = [pawn.global_position, pawn.velocity, tick]
			elif report_falls and _last_on_ground.has(id): # in the air: keep where it last stood
				seen[id] = _last_on_ground[id]
			continue
		# Claude 2026-11-12: the report is written before it dies, and shown only if it did, so a pawn that can't die (which carries on
		# falling) isn't reported on every check. GDScript note: dictionary.get(key) gives null when the key isn't there.
		var report := fall_report(pawn, _last_on_ground.get(id), tick) if report_falls else ""
		if kill(pawn) and report_falls:
			push_warning(report)
			pawn_fell.emit(pawn, report) # Claude 2026-11-15: for replay recordings
	_last_on_ground = seen


## Gives a pawn the kill effect. Public, so a test or a game rule can use the same way of dying. Claude 2026-11-12: true if it got
## the effect, false if it couldn't (no effect set, or a pawn with no Health or EffectManager).
func kill(pawn: Pawn) -> bool:
	if kill_effect == null:
		_warn_once("no effect", "KillFloor %s has no kill_effect, so pawns that fall below it carry on falling." % name)
		return false
	if pawn.effect_manager == null or pawn.stat_manager == null or not pawn.stat_manager.has_stat(StatManager.HEALTH):
		_warn_once(String(pawn.name), "KillFloor: %s fell below it but has no Health or no EffectManager, so it can't die there." % pawn.name)
		return false
	pawn.effect_manager.apply_effect(kill_effect, null)
	return true


## Claude 2026-11-12: the words of a fall's report. last_seen is [position, velocity, tick] from the last check that found the pawn
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


# Claude 2026-11-12: the level's terrain, if it has one (every TerrainGenerator joins its group).
func _terrain() -> TerrainGenerator:
	for node in get_tree().get_nodes_in_group(TerrainGenerator.GROUP):
		if node is TerrainGenerator:
			return node
	return null


func _warn_once(key: String, message: String) -> void:
	if not _warned.has(key):
		_warned[key] = true
		push_warning(message)
