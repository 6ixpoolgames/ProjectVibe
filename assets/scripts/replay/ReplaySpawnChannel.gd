# Written by Claude (claude-opus-5-5), 2026-11-15. History: replay/CHANGELOG.md.
## Replay channel 3, "spawns": which pawns exist (replay spec section 3).
##
## Events: "spawned" (data: name, scene, team) and "despawned" (no data). A keyframe's snapshot lists every live pawn the same way, so
## a reader starting at any block knows who's there.
## [br]
## Reading: state["pawns"] is replay id -> {name, scene, team}, for the pawns alive at that tick. The other channels' records are
## only shown for pawns listed here.
class_name ReplaySpawnChannel
extends ReplayEventChannel

const ID := 3

var _live: Array = [] # [pawn, replay id], in the order they arrived


func _init() -> void:
	channel_id = ID
	channel_name = "spawns"
	version = 1


func end() -> void:
	_live.clear()
	super()


func pawn_added(pawn: Pawn, id: int) -> void:
	_live.append([pawn, id])
	add_event("spawned", id, _describe(pawn))


func pawn_removed(_pawn: Pawn, id: int) -> void:
	for i in _live.size():
		if _live[i][1] == id:
			_live.remove_at(i)
			break
	add_event("despawned", id)


func snapshot() -> Dictionary:
	var pawns := {}
	for entry: Array in _live:
		if is_instance_valid(entry[0]):
			pawns[entry[1]] = _describe(entry[0])
	return {"pawns": pawns}


func read_snapshot(shot: Dictionary, state: Dictionary) -> void:
	var pawns: Variant = shot.get("pawns", {})
	state["pawns"] = (pawns as Dictionary).duplicate() if pawns is Dictionary else {}


func apply_event(event: Dictionary, state: Dictionary) -> void:
	if not state.has("pawns"):
		state["pawns"] = {}
	match event.kind:
		"spawned":
			state.pawns[event.id] = event.data
		"despawned":
			state.pawns.erase(event.id)


func copy_state(state: Dictionary) -> Dictionary:
	var copy := state.duplicate()
	if state.has("pawns"):
		copy["pawns"] = (state.pawns as Dictionary).duplicate() # changed in place by apply_event, so it's copied too
	return copy


static func _describe(pawn: Pawn) -> Dictionary:
	return {"name": String(pawn.name), "scene": pawn.scene_file_path, "team": pawn.team}
