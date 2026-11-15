## Written by Claude (claude-opus-5-5), 2026-11-15: writes a replay file on a thread of its own (replay spec sections 1 and 2). The
## recorder hands it each finished block; this thread compresses the block with zstd and appends it to the file. So the game's ticks
## never wait for the disk.
##
## Why its own thread and not the job scheduler's: the scheduler's workers run work a tick is waiting for, such as AI sensing. A slow
## disk on one of them would hold a tick up. This thread sleeps until a block arrives, so it costs almost nothing.
##
## How to use it (ReplayRecorder does):
##   var writer := ReplayWriter.new()
##   writer.open(path, header_bytes)    # writes the header at once, then starts the thread
##   writer.push_block(raw_bytes)       # any number of times, from the main thread
##   writer.close()                     # writes what's left, then waits for the thread to finish
##
## GDScript note: Mutex and Semaphore are how threads take turns safely. The mutex guards the queue, so the two threads never change
## it at the same moment; the semaphore counts blocks waiting, and the writing thread sleeps on it until there's one.
class_name ReplayWriter
extends RefCounted

## Off: blocks are compressed and written on the calling thread instead, at once. For tests that compare the two, and for platforms
## without threads.
var use_thread := true

var _file: FileAccess = null
var _thread: Thread = null
var _mutex := Mutex.new()
var _semaphore := Semaphore.new()
var _queue: Array[PackedByteArray] = []
var _closing := false
var _error := OK
var _blocks_written := 0
var _bytes_written := 0


## Creates the file (replacing one at that path), writes the header, and starts the thread. Returns the error if the file couldn't
## be made.
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


## Queues a finished block. Returns at once; the block is written on the thread.
func push_block(raw: PackedByteArray) -> void:
	if _file == null:
		return
	if not use_thread:
		_write_block(raw)
		return
	_mutex.lock()
	_queue.append(raw)
	_mutex.unlock()
	_semaphore.post()


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


func is_open() -> bool:
	return _file != null


## The first error writing hit, or OK.
func get_error() -> Error:
	return _error


## Blocks written so far, and the file's size. GDScript note: read from the main thread while the writer runs, so they may be a
## block behind; that's fine for a readout.
func get_blocks_written() -> int:
	return _blocks_written


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


# One block: raw size (u32), compressed size (u32), the compressed bytes (replay spec section 2). Flushed, so a crash keeps every
# block before the one being written.
func _write_block(raw: PackedByteArray) -> void:
	var packed := raw.compress(FileAccess.COMPRESSION_ZSTD)
	_file.store_32(raw.size())
	_file.store_32(packed.size())
	_file.store_buffer(packed)
	_file.flush()
	if _file.get_error() != OK and _error == OK:
		_error = _file.get_error()
	_blocks_written += 1
	_bytes_written += 8 + packed.size()
