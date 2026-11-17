# Written by Claude (claude-opus-5-5), 2026-11-15. History: replay/CHANGELOG.md.
## The base for one kind of data in a replay file (replay spec section 3).
##
## The same class writes its data for [ReplayRecorder] and reads it back for [ReplayReader], so the layout of its bytes lives in one
## place. Its id, name and version go in the file's header. A recording calls [method begin] once, [method write_tick] every tick
## ([code]keyframe[/code] is true on the first tick of every block: write everything, not just what changed), [method pawn_added] and
## [method pawn_removed] as pawns come and go, and [method end] once. A reader calls [method read_tick] to apply one tick's bytes to
## [code]state[/code], a Dictionary the channel owns the layout of (empty on a keyframe).
## [br]
## To add a kind of data, extend this (or [ReplayEntityChannel] or [ReplayEventChannel]), give it an unused id, and add it with
## [method ReplayRecorder.add_channel] and [method ReplayReader.add_channel]. A reader without it skips its bytes.
## Design: replay spec 3.
class_name ReplayChannel
extends RefCounted

## The id in the file. 1 to 99 are the base's (replay spec section 3); a game's own channels use 100 and up.
var channel_id := 0
## Reading: the version the file was written with. [method read_tick] checks it when a channel reads older layouts too.
var file_version := 1
## A name for people, shown by the viewer and kept in the header.
var channel_name := ""
## Raised whenever the layout of this channel's bytes changes, so a reader can tell old files from new ones.
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


## Reading: a copy of state that [method read_tick] can change without changing the original. Shallow by default; override it
## when read_tick changes a nested Dictionary or Array in place.
func copy_state(state: Dictionary) -> Dictionary:
	return state.duplicate()
