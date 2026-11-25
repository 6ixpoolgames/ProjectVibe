# Written by Claude (claude-opus-5-5), 2026-11-25. History: controllers/CHANGELOG.md.
## Runs steps that write a controller's input, such as the player's click-to-move ([MoveToStep]): a small step host (pawn spec 16.4).
##
## A child of its controller, with its steps as its own children. It owns a [StepTimeline] whose entries are all manual: nothing
## starts until [method start] does, and one start ends any run before it. Each tick its controller calls [method run], which clears
## [member input] and lets the running steps write it; the controller then uses what they wrote. It runs on the controller's machine
## only, so nothing here rolls back: the input it makes does.
## [codeblock]
## host.start(host.get_node(^"MoveTo"))   # begins a run with this step
## host.run(pawn.ticks_elapsed)           # once per tick, while is_running()
## [/codeblock]
class_name ControllerStepHost
extends Node

## What the running steps wrote this tick: move, and actions to press. Look is left to the controller.
var input := InputCommand.new()
## The pawn its steps move. [method set_pawn] changes it.
var pawn: Pawn = null
## The timeline its steps run on, built when it's ready.
var timeline := StepTimeline.new()

var _running := false


func _init() -> void:
	set_process(false)
	set_physics_process(false)


func _ready() -> void:
	var steps: Array[Step] = []
	var entries: Array[TimelineEntry] = []
	for child in get_children():
		if child is Step:
			child.pawn = pawn
			steps.append(child)
			var entry := TimelineEntry.new() # manual: started from code only
			entry.step = child.name
			entry.manual = true
			entries.append(entry)
	timeline.host = self
	timeline.owner_name = "%s's step host" % get_parent().name if get_parent() else "A step host"
	timeline.build(steps, entries)


## Moves its steps to this pawn (null: none), ending any run, since its steps belonged to the last one.
func set_pawn(new_pawn: Pawn) -> void:
	stop()
	pawn = new_pawn
	for step in timeline.steps:
		step.pawn = new_pawn


## Ends any run, then begins one with this step, which enters at once. False if it isn't one of this host's steps or there's no pawn.
func start(step: Step) -> bool:
	stop()
	if step == null or step.timeline != timeline or pawn == null:
		return false
	timeline.begin(TickDriver.tick)
	timeline.start_step(step)
	_running = step.running
	return _running


## Runs the running steps for this tick, covering elapsed ticks, after clearing [member input]. The run ends once no step is left.
func run(elapsed := 1) -> void:
	input.move = Vector3.ZERO
	input.held_actions = 0
	if not _running:
		return
	if timeline.run(TickDriver.get_tick_dt() * elapsed, elapsed) != StepTimeline.Result.RUNNING:
		_running = false


## The input its steps write ([member input]): how a [MoveStep] finds it when the timeline is built.
func step_input() -> InputCommand:
	return input


## Ends the run, stopping every running step ("cancelled").
func stop() -> void:
	if _running:
		_running = false
		timeline.end("cancelled")


## True while a run is going.
func is_running() -> bool:
	return _running


# What its timeline tells it (StepTimeline's host methods). Nothing rolls back here, so state changes need no pushing.
func _timeline_state_written() -> void:
	pass


func _timeline_step_started(_step: Step) -> void:
	pass


func _timeline_step_finished(_step: Step, _reason: String) -> void:
	pass


func _timeline_runaway() -> void:
	stop()
