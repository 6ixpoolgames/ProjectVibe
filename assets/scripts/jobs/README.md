<!-- Written by Claude (claude-opus-5-5), 2026-11-17: the jobs folder's overview, beside its code. -->

# Jobs

`TickJobs` finds the one job scheduler every kind of background work shares: worker threads in C++ (`JobScheduler`, in the navcore library) that take batches of plain-data work, such as AI sensing (`AISensingJob`), from one queue. Design: [SCALING_SPEC.md](../../../docs/scaling/SCALING_SPEC.md) section 4.

**Status:** built, tier 1 step 2. Not yet: the main thread's budget and deferring work to later ticks (scaling spec step 5, set aside).

- `TickJobs.get_scheduler()`: the scheduler, or null without the C++ library or with `TickJobs.enabled` off; each job kind then runs on the main thread.
- `TickJobs.set_worker_count(n)`: -1 (the default) sizes it to the machine (its cores, less one for the main thread and one more if it draws the game, at most 8); 0 runs every job on the main thread; tests fix a number. The answers are the same with any count.
- It's static, not an autoload, to keep autoloads few.

Every class and function: [REFERENCE.md](REFERENCE.md) (`python tools/docs/make_reference.py jobs`). History: built 2026-11-09 (scaling spec step 2); the later change is listed below. Tests: `ai/tests/ai_sensing_job_selftest`.

- 2026-11-18: **Comments rewritten to the reference style** (the documentation pass): the `TickJobs` class comment shortened; `GDScript note:` teaching comments removed, keeping any non-obvious fact shortened.
