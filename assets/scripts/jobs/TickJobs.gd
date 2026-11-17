# Written by Claude (claude-opus-5-5), 2026-11-09. History: jobs/README.md.
## Finds the one job scheduler every job kind shares (scaling spec section 4).
##
## The scheduler is C++ (JobScheduler in navcore): worker threads that take batches of plain-data work, such as the sensing job
## (AISensingJob), from one shared queue. This class only holds it and the two settings a game or test might change. Everything is
## static; it's never instanced and isn't an autoload. Without the C++ library, [method get_scheduler] returns null and every job
## kind runs on the main thread.
class_name TickJobs
extends RefCounted

## Off: no jobs, and every job kind runs on the main thread. On by default; read when each part is ready, so set it before pawns are
## made.
static var enabled := true

# The scheduler, made on first use. Untyped, because the C++ class only exists when the library loads.
static var _scheduler: Object = null
static var _worker_count := -1


## The shared scheduler, or null without the C++ library or with enabled off.
static func get_scheduler() -> Object:
	if not enabled or not ClassDB.class_exists(&"JobScheduler"):
		return null
	if _scheduler == null:
		# Made by name, so this script still runs where the C++ library isn't available.
		_scheduler = ClassDB.instantiate(&"JobScheduler")
		_scheduler.set_worker_count(_worker_count)
	return _scheduler


## How many worker threads: -1 (the default) sizes it to the machine (scaling spec 4.1: its cores, minus one for the main thread, minus
## one more if this machine also draws the game, at most 8); 0 means none, so every job runs on the main thread when its result is
## needed; any other number fixes it, as tests do so they repeat on any machine. The answers are the same with any number.
static func set_worker_count(count: int) -> void:
	_worker_count = count
	if _scheduler:
		_scheduler.set_worker_count(count)


## The worker count last set with [method set_worker_count]: -1 means sized to the machine.
static func get_worker_count_setting() -> int:
	return _worker_count
