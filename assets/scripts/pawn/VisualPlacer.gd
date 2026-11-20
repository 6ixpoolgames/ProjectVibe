# Written by Claude (claude-opus-5-5), 2026-11-21. History: pawn/CHANGELOG.md.
## Places every pawn's Visual between ticks, once a frame, in one call: the "place what's drawn" pass (state store spec 12.5).
##
## Each pawn's [VisualSmoother] holds a slot here and tells it about its runs, snaps and corrections; the crowd mover tells it about all
## its pawns' runs at once ([method note_runs]). The work is in [member placement]: the C++ VisualPlacement where the library has it,
## else its GDScript twin [VisualPlacementGD]. Made on first use ([method get_or_make]), under the TickDriver, so it's placed before
## the scene's own nodes run their frame (a camera following a Visual sees where it is this frame).
## [codeblock]
## VisualPlacer.get_or_make(pawn).placement.snap(slot, position, yaw)
## [/codeblock]
class_name VisualPlacer
extends Node

## The one placer, or null until something needs it.
static var current: VisualPlacer = null

## Off: the GDScript twin, even where the C++ one is available. Only read when the placer is made.
static var use_cpp := true

## The slots and the placing: a C++ VisualPlacement or a [VisualPlacementGD].
var placement: Object = null

var _driver: Node = null


## The placer, made now if there's none. from: any node in the tree, which it's made beside.
static func get_or_make(from: Node) -> VisualPlacer:
	if is_instance_valid(current):
		return current
	var placer := VisualPlacer.new()
	placer.name = "VisualPlacer"
	placer.placement = ClassDB.instantiate(&"VisualPlacement") if use_cpp and ClassDB.class_exists(&"VisualPlacement") \
			else VisualPlacementGD.new()
	placer._driver = from.get_node_or_null(^"/root/TickDriver")
	# Deferred: it's usually asked for in a pawn's _ready, when its parent may be busy adding children. Slots work before it's in.
	var parent: Node = placer._driver if placer._driver else from.get_tree().root
	parent.add_child.call_deferred(placer)
	current = placer
	return placer


## Many runs at once: each slot's Visual glides to its position and yaw over its span (the crowd mover's pawns). A slot below 0 is
## skipped.
func note_runs(slots: PackedInt64Array, positions: PackedVector3Array, yaws: PackedFloat32Array, spans: PackedInt64Array, tick: int) -> void:
	placement.note_runs(slots, positions, yaws, spans, tick)


func _process(delta: float) -> void:
	var started := PerfScopes.begin() # timed for diagnostics, in its animation category
	if _driver:
		placement.place(_driver.tick, _driver.get_interpolation_fraction(), delta, true)
	else:
		placement.place(0, 1.0, delta, false)
	PerfScopes.end(&"animation.smoothing", started)


func _exit_tree() -> void:
	if current == self:
		current = null
