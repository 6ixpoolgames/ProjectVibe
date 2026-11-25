# Written by Claude (claude-opus-5-5), 2026-11-25. History: diagnostics/CHANGELOG.md.
## The newest frames' numbers in a fixed amount of memory: a ring buffer, each new frame overwriting the oldest.
##
## [DiagnosticsManager] keeps one for its live views: summaries, the F2 frame graph, the editor's monitors and captures. A frame is a row of
## numbers in one packed array, in the columns named when the history is made, plus the frame's scopes. Once full, adding a frame
## allocates and moves nothing. The whole session's frames are in the replay's diagnostics channel.
## [codeblock]
## var frame_ms := history.column(&"frame_ms")
## for age in history.size():          # 0 is the newest frame
##     total += history.value(frame_ms, age)
## [/codeblock]
class_name DiagnosticsFrameHistory
extends RefCounted

var _names := PackedStringArray()
var _index := {} # column name (StringName) -> its number
var _width := 0
var _capacity := 1
var _data := PackedFloat64Array() # row after row, _width numbers each
var _scopes: Array = [] # each row's scopes
var _next := 0 # the row the next frame goes in
var _size := 0


func _init(capacity: int, columns: PackedStringArray) -> void:
	_capacity = maxi(capacity, 1)
	_names = columns
	_width = columns.size()
	for i in _width:
		_index[StringName(columns[i])] = i
	_data.resize(_capacity * _width)
	_scopes.resize(_capacity)


## The most frames it keeps.
func capacity() -> int:
	return _capacity


## How many frames it holds now.
func size() -> int:
	return _size


## The column names, in order.
func columns() -> PackedStringArray:
	return _names


## A column's number, for [method value]; -1 if there's no such column.
func column(column_name: StringName) -> int:
	return _index.get(column_name, -1)


## Adds a frame: each column from the record's value of that name (0 when it has none), and the record's "scopes".
func add(record: Dictionary) -> void:
	var base := _next * _width
	for i in _width:
		_data[base + i] = float(record.get(_names[i], 0.0))
	_scopes[_next] = record.get("scopes", {})
	_next = (_next + 1) % _capacity
	_size = mini(_size + 1, _capacity)


## A column's value in the frame age frames ago (0: the newest). Age must be below [method size].
func value(column_number: int, age: int) -> float:
	return _data[_row(age) * _width + column_number]


## The scopes of the frame age frames ago: name -> [microseconds, calls].
func scopes(age: int) -> Dictionary:
	return _scopes[_row(age)]


## The frame age frames ago as a record: column name -> value, plus "scopes". A new Dictionary each call, so not for every frame.
func record(age: int) -> Dictionary:
	var row := _row(age)
	var out := {}
	for i in _width:
		out[_names[i]] = _data[row * _width + i]
	out["scopes"] = _scopes[row]
	return out


## Forgets every frame.
func clear() -> void:
	_size = 0
	_next = 0
	_scopes.fill(null)


func _row(age: int) -> int:
	return posmod(_next - 1 - age, _capacity)
