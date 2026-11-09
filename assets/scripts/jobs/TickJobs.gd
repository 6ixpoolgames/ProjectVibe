## Written by Claude (claude-opus-5-5), 2026-11-09: the one job scheduler every job kind shares (scaling spec section 4, tier 1 step
## 2). The scheduler itself is C++ (JobScheduler in navcore): worker threads that take batches of plain-data work, such as the sensing
## job (AISensingJob), from one shared queue. This class only holds it, so any script can find it, and keeps the two settings a game
## or a test might change.
##
## Not an autoload and never instanced: everything here is static (minimize autoloads). GDScript note: a static var belongs to the
## class, not to an object, so there's one of each for the whole game, like Pawn's shared table.
##
## Without the C++ library, get_scheduler() returns null and every job kind runs the old way, on the main thread.
class_name TickJobs
extends RefCounted

## Off: no jobs. Everything runs on the main thread exactly as before tier 1 step 2. On by default; read when each part is ready, so
## set it before pawns are made.
static var enabled := true

# The scheduler, made on first use. Untyped, because the C++ class only exists when the library loads.
static var _scheduler: Object = null
static var _worker_count := -1


## The shared scheduler, or null without the C++ library or with enabled off.
static func get_scheduler() -> Object:
	if not enabled or not ClassDB.class_exists(&"JobScheduler"):
		return null
	if _scheduler == null:
		# GDScript note: made by name, so this script still runs where the C++ library isn't available.
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


static func get_worker_count_setting() -> int:
	return _worker_count
