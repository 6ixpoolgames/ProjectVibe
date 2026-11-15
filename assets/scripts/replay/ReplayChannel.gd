## Written by Claude (claude-opus-5-5), 2026-11-15: the base for one kind of data in a replay file (replay spec section 3). A channel
## has an id, a name and a version, which go in the file's header, and the same class both writes its data (for ReplayRecorder) and
## reads it back (for ReplayReader), so the layout of its bytes lives in one place.
##
## How a recording uses a channel:
##   begin(recorder)                        once, when recording starts. Connect to signals here.
##   write_tick(tick, out, keyframe)        once a tick: write this tick's data into out. keyframe is true on the first tick of every
##                                          block, when the channel writes everything as it is, not just what changed.
##   pawn_added(pawn, id) / pawn_removed    as pawns enter and leave the tree while recording
##   end()                                  once, when recording stops. Disconnect here.
##
## How a reader uses it:
##   read_tick(tick, data, keyframe, state)  one tick's bytes, applied to state (a Dictionary the channel owns the layout of).
##                                           On a keyframe, state starts empty.
##
## To add a kind of data later: extend this (or ReplayEntityChannel or ReplayEventChannel), give it an unused id, and add it with
## ReplayRecorder.add_channel before recording starts. A reader without it skips its bytes (replay spec section 2).
##
## GDScript note: RefCounted, not Node: a channel isn't in the scene tree, and is freed by itself once nothing holds it.
class_name ReplayChannel
extends RefCounted

## The id in the file. 1 to 99 are the base's (replay spec section 3); a game's own channels use 100 and up.
var channel_id := 0
## Reading: the version the file was written with, from its header (Claude 2026-11-15). read_tick checks it when a channel reads
## older layouts too, such as the motion channel's version 1.
var file_version := 1
## A name for people: shown by the viewer and kept in the header.
var channel_name := ""
## Raised when the layout of this channel's bytes changes, so a reader can tell old files from new ones.
var version := 1
## The recorder, while recording; null when reading.
var recorder: ReplayRecorder = null


## Recording starts. Connect to what this channel listens to.
func begin(for_recorder: ReplayRecorder) -> void:
	recorder = for_recorder


## Recording stops. Disconnect what begin connected.
func end() -> void:
	recorder = null


## A pawn entered the tree while recording, with its replay id.
func pawn_added(_pawn: Pawn, _id: int) -> void:
	pass


## A pawn left the tree while recording.
func pawn_removed(_pawn: Pawn, _id: int) -> void:
	pass


## This tick's data, written into out. keyframe: write everything, not just what changed.
func write_tick(_tick: int, _out: StreamPeerBuffer, _keyframe: bool) -> void:
	pass


## Reading: one tick's bytes, applied to state. A keyframe's state starts empty.
func read_tick(_tick: int, _data: StreamPeerBuffer, _keyframe: bool, _state: Dictionary) -> void:
	pass


## Reading: a copy of state that read_tick can change without changing the original. The reader keeps one per tick, so this is
## shallow by default, which is enough when read_tick replaces values rather than changing them in place. Override it when state
## holds a Dictionary or Array that read_tick changes in place, and copy that too.
func copy_state(state: Dictionary) -> Dictionary:
	return state.duplicate()
