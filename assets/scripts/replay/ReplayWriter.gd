# Written by Claude (claude-opus-5-5), 2026-11-15. History: replay/CHANGELOG.md.
## Writes a replay file on a thread of its own, so the game's ticks never wait for the disk.
##
## [ReplayRecorder] hands it each finished block; the thread compresses it with zstd and appends it to the file. It has its own
## thread, not the job scheduler's, because a slow disk on a scheduler worker would hold up a tick; this one sleeps until a block
## arrives. The thread touches only the queue (under a mutex) and the file.
## [codeblock]
## var writer := ReplayWriter.new()
## writer.open(path, header_bytes)  # writes the header at once, then starts the thread
## writer.push_block(raw_bytes)     # from the main thread; false if refused
## writer.close()                   # writes what's left, then waits for the thread
## [/codeblock]
## Design: replay spec 1 and 2.
class_name ReplayWriter
extends RefCounted

## Off: blocks are compressed and written on the calling thread, at once (for tests, and platforms without threads).
var use_thread := true
## The most blocks that may wait. [method push_block] refuses more, so a slow disk never fills memory; the recorder then stops.
var max_queued_blocks := 60 # the recorder sets it from its own max_queued_blocks

var _file: FileAccess = null
var _thread: Thread = null
var _mutex := Mutex.new()
var _semaphore := Semaphore.new()
var _queue: Array[PackedByteArray] = []
var _closing := false
var _error := OK
var _blocks_written := 0
var _bytes_written := 0


## Creates the file (replacing one at that path), writes the header and starts the thread. Returns the error if the file can't be made.
func open(path: String, header: PackedByteArray) -> Error:
	_file = FileAccess.open(path, FileAccess.WRITE)
	if _file == null:
		_error = FileAccess.get_open_error()
		return _error
	_file.store_buffer(header)
	_file.flush()
	_bytes_written = header.size()
	_closing = false
	if use_thread:
		_thread = Thread.new()
		_thread.start(_run)
	return OK


## Queues a finished block and returns at once. False if refused: not open, a write already failed, or [member max_queued_blocks] waiting.
func push_block(raw: PackedByteArray) -> bool:
	if _file == null or _error != OK:
		return false
	if not use_thread:
		_write_block(raw)
		return _error == OK
	_mutex.lock()
	var full := _queue.size() >= max_queued_blocks
	if not full:
		_queue.append(raw)
	_mutex.unlock()
	if full:
		return false
	_semaphore.post()
	return true


## Writes every queued block, closes the file and stops the thread. Safe to call twice.
func close() -> void:
	if _file == null:
		return
	if _thread:
		_mutex.lock()
		_closing = true
		_mutex.unlock()
		_semaphore.post() # wakes the thread, so it sees it's closing once the queue is empty
		_thread.wait_to_finish()
		_thread = null
	_file.close()
	_file = null


## True between [method open] and [method close].
func is_open() -> bool:
	return _file != null


## The first error writing hit, or OK.
func get_error() -> Error:
	return _error


## Blocks written so far. Read from the main thread while the writer runs, so it may be a block behind.
func get_blocks_written() -> int:
	return _blocks_written


## The file's size so far, header included (may be a block behind).
func get_bytes_written() -> int:
	return _bytes_written


# --- The writing thread ---


func _run() -> void:
	while true:
		_semaphore.wait()
		_mutex.lock()
		var raw: Variant = null if _queue.is_empty() else _queue.pop_front()
		var closing := _closing
		_mutex.unlock()
		if raw != null:
			_write_block(raw)
		elif closing:
			return


# One block: raw size (u32), compressed size (u32), the compressed bytes (replay spec 2). Flushed, so a crash keeps every earlier block.
func _write_block(raw: PackedByteArray) -> void:
	if _error != OK:
		return # after a failed write nothing more is written, so a broken file isn't made worse
	var packed := raw.compress(FileAccess.COMPRESSION_ZSTD)
	_file.store_32(raw.size())
	_file.store_32(packed.size())
	_file.store_buffer(packed)
	_file.flush()
	if _file.get_error() != OK and _error == OK:
		_error = _file.get_error()
	_blocks_written += 1
	_bytes_written += 8 + packed.size()
