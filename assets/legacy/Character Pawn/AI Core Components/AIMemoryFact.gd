## Written by Claude (claude-opus-5-5), 2026-11-03: one remembered fact, stored by AIMemoryComponent.
## A fact means "something of kind [type], about [subject], last known at [position], this sure: [confidence]".
## Senses write facts, decision code reads them. Extra info goes in [data], or subclass this for typed fields.
extends RefCounted
class_name AIMemoryFact

var type: StringName ## what kind of fact, e.g. &"pawn_seen", &"heard_noise", &"took_damage"
var subjectRef: WeakRef = null ## the node this fact is about. Weak, so memory never keeps a freed node alive. null = no subject (e.g. a noise)
var subjectId: int = 0 ## instance id of the subject (0 = no subject). Together with [type] it identifies the fact
var position: Vector3 = Vector3.ZERO ## last known position
var confidence: float = 1.0 ## 1 = certain right now. Decays while not refreshed; forgotten below a threshold
var source: StringName = &"" ## which sense wrote it last (&"vision", &"hearing"...)
var firstTime: float = 0.0 ## seconds since engine start when first recorded
var lastTime: float = 0.0 ## seconds since engine start when last refreshed
var data: Dictionary = {} ## free-form extras for game-specific info


func _init(fact_type: StringName = &"", subject: Object = null, pos: Vector3 = Vector3.ZERO) -> void:
	type = fact_type
	position = pos
	if subject:
		subjectRef = weakref(subject)
		subjectId = subject.get_instance_id()


##returns the subject node, or null if there is none or it has been freed
func get_subject() -> Object:
	if subjectRef == null:
		return null
	return subjectRef.get_ref()


##true if this fact had a subject and that subject has since been freed (e.g. the pawn died and was removed)
func is_subject_gone() -> bool:
	return subjectId != 0 and get_subject() == null


##seconds since this fact was last refreshed
func age(now: float) -> float:
	return now - lastTime


func _to_string() -> String:
	return "[%s %s at %s conf %.2f]" % [type, get_subject() if get_subject() else "-", position.snapped(Vector3.ONE * 0.1), confidence]
