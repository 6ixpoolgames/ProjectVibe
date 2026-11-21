# Written by Claude (claude-opus-5-5), 2026-11-21. History: abilities/CHANGELOG.md.
@tool
## The settings one variant of an ability has, shared by every pawn that uses it, such as "Goblin Swing": a Resource an ability node
## points at (ability spec 3).
##
## Each kind of ability has its own class with its settings added ([MeleeAttackDefinition]); a new one starts with the kind's defaults.
## [member based_on] makes it a variant: each setting it hasn't changed comes from its base, so changing the base changes its variants.
## In the inspector a variant shows its base's values, and the revert arrow on a changed one goes back to following the base.
## [br][br]Read-only while playing: every pawn using it shares it. A pawn that needs other numbers uses another definition
## ([method AbilityBase.use_definition]), or gets them from stats and effects. An ability runs with [method resolved], the copy with
## every setting worked out.
class_name AbilityDefinition
extends Resource

## The settings this variant has changed from its base: set as they're edited, and saved with it. Only these are saved in a variant's
## file; the rest follow the base.
@export_storage var changed_values := PackedStringArray()
## The definition this one is a variant of. Empty: one of its own, starting from the kind's defaults.
@export var based_on: AbilityDefinition:
	set(value):
		based_on = value
		_resolved = null
		if Engine.is_editor_hint():
			_show_base_values()
			notify_property_list_changed()

## The named action that starts it, such as &"jump". Empty: only the manager starts it, as the default locomotion.
@export var trigger_action: StringName = &"":
	set(value):
		trigger_action = value
		_changed(&"trigger_action", value)
## What it is, as a tag such as &"movement.jump". Used for lockouts. Empty: nothing can lock it out.
@export var category: StringName = &"":
	set(value):
		category = value
		_changed(&"category", value)
## More groups it belongs to besides category, such as &"movement.advanced" for a dash. Lockouts, cancels and
## [method AbilityManager.action_for_tag] answer to all of them. They share one 64-bit mask with every other ability tag.
@export var extra_categories: Array[StringName] = []:
	set(value):
		extra_categories = value
		_changed(&"extra_categories", value)
## Which ability a press picks among those on one action: the highest that can start wins, then the first in the tree. Locomotion
## with a held action works the same. Effects can add to it (AbilityPriorityPart, pawn spec 8.11).
@export var priority: int = 0:
	set(value):
		priority = value
		_changed(&"priority", value)
## Which combo positions it can fill: [1] an opener, [2] a second hit, [2, 3] second or third. A follow-up (no 1) starts only while the
## combo window is open; give it a higher priority than the opener so it wins there. Empty: not in combos. Pawn spec 8.20.
@export var combo_positions: Array[int] = []:
	set(value):
		combo_positions = value
		_changed(&"combo_positions", value)
## A random offset, up to plus or minus this, added to priority when a press picks between abilities. 0: none. It comes from the tick's
## own random numbers ([method TickDriver.tick_rng]), so a replay picks the same ability. Locomotion ignores it.
@export var priority_jitter: float = 0.0:
	set(value):
		priority_jitter = value
		_changed(&"priority_jitter", value)
## Seconds. For an action, 0 means it happens at once. For locomotion, 0 means it runs as long as it's wanted.
@export_range(0.0, 60.0, 0.05, "or_greater") var duration: float = 0.0:
	set(value):
		duration = value
		_changed(&"duration", value)
## Seconds after it stops before it can start again.
@export_range(0.0, 60.0, 0.05, "or_greater") var cooldown: float = 0.0:
	set(value):
		cooldown = value
		_changed(&"cooldown", value)
## Categories that can't start, or steer, while this runs, such as &"movement" for an attack that roots the pawn.
@export var locks_out: Array[StringName] = []:
	set(value):
		locks_out = value
		_changed(&"locks_out", value)
## Seconds a press waits if the ability can't start yet, such as jump pressed just before landing. 0: a press is tried once.
@export_range(0.0, 2.0, 0.01, "or_greater") var buffer_window: float = 0.0:
	set(value):
		buffer_window = value
		_changed(&"buffer_window", value)
## How hard it cancels a running ability it conflicts with (pawn spec 8.6): Walk 0, Jump 5, Sprint 10, Parry 10, MeleeAttack 15,
## Knockback 30, Dash 40, Death 1000.
@export var interrupt_priority: int = 0:
	set(value):
		interrupt_priority = value
		_changed(&"interrupt_priority", value)
## While it runs, a conflicting ability with at least this interrupt_priority cancels it; a weaker one is locked out. 100: only Death
## cancels it. MeleeAttack uses 15, so Dash cancels a swing and Sprint doesn't.
@export var interrupt_threshold: int = 100:
	set(value):
		interrupt_threshold = value
		_changed(&"interrupt_threshold", value)
# For invulnerability while it runs, give it an InvulnerabilityInterceptor child (HitInterceptor); Dash makes one by default.
## Categories that can always cancel it while it runs, whatever the interrupt numbers say, such as &"movement.jump". A category covers
## its children, as in locks_out.
@export var cancelled_by: Array[StringName] = []:
	set(value):
		cancelled_by = value
		_changed(&"cancelled_by", value)
## On: locomotion (Walk, Sprint) doesn't run at all while this does, so it neither steers nor slows the pawn (Dash). Off: a locked-out
## locomotion still slows the pawn to a stop, as an attack that roots the pawn wants.
@export var pauses_locomotion: bool = false:
	set(value):
		pauses_locomotion = value
		_changed(&"pauses_locomotion", value)
## On: while it runs the pawn moves by physics ([code]move_and_slide[/code]), not the CrowdMover, so fast or forced moves such as Dash
## and Knockback collide properly. Pawn spec 8.22.
@export var needs_full_movement: bool = false:
	set(value):
		needs_full_movement = value
		_changed(&"needs_full_movement", value)
## For a stepped ability, the longest it can run, in ticks at 60 a second. It ends when no step runs, or at this. Ignored without steps.
@export_range(1, 6000, 1, "or_greater") var max_steps_ticks: int = 600:
	set(value):
		max_steps_ticks = value
		_changed(&"max_steps_ticks", value)

## For a resolved copy: the definition it was worked out from. Null on a definition of its own.
var resolved_from: AbilityDefinition = null
var _resolved: AbilityDefinition = null
var _copying_base := false # setting values from the base, which doesn't change them
# Each script's setting names, worked out once.
static var _setting_names_by_script := {}
# How many bases deep value_of may go: a base that leads back to itself is an error, not a hang.
const MAX_BASE_DEPTH := 32


# A kind's definition sets its defaults in its own _init(), after calling this.
func _init() -> void:
	pass


## The names of its settings: what a variant can change.
func setting_names() -> PackedStringArray:
	var script: Script = get_script()
	var names: Variant = _setting_names_by_script.get(script)
	if names == null:
		var found := PackedStringArray()
		for property in get_property_list():
			var usage: int = property["usage"]
			if usage & PROPERTY_USAGE_SCRIPT_VARIABLE and usage & PROPERTY_USAGE_EDITOR and property["name"] != "based_on":
				found.append(property["name"])
		_setting_names_by_script[script] = found
		names = found
	return names


## A setting's value here: its own if it changed it or has no base, else its base's.
func value_of(setting: StringName, depth := 0) -> Variant:
	if based_on == null or changed_values.has(setting) or not setting in based_on:
		return get(setting)
	if depth >= MAX_BASE_DEPTH:
		push_error("[AbilityDefinition] %s: its bases lead back to themselves; using its own value of %s." % [describe(), setting])
		return get(setting)
	return based_on.value_of(setting, depth + 1)


## This definition with every setting worked out, the copy an ability runs with: itself when it has no base. Worked out once while
## playing (definitions don't change then), every time in the editor.
func resolved() -> AbilityDefinition:
	if based_on == null:
		return self
	if _resolved and not Engine.is_editor_hint():
		return _resolved
	if not _base_fits():
		push_warning("[AbilityDefinition] %s is based on %s, a different kind; only the settings both have follow it." % [describe(), based_on.describe()])
	var out: AbilityDefinition = get_script().new()
	out._copying_base = true
	for setting in setting_names():
		out.set(setting, value_of(setting))
	out._copying_base = false
	out.resource_name = resource_name
	out.resolved_from = self
	_resolved = out
	return out


## A short name for warnings and readouts: its resource_name, its file's name, or the kind.
func describe() -> String:
	if resource_name != "":
		return resource_name
	if resource_path != "" and not resource_path.contains("::"):
		return resource_path.get_file().get_basename()
	if resource_path.contains("::"):
		return "%s (embedded in %s)" % [get_script().get_global_name(), resource_path.get_slice("::", 0).get_file()]
	return "%s (made in code)" % get_script().get_global_name()


## True if it's saved inside a scene ("Make Unique"), not in a file of its own: a quick tweak while prototyping. Diagnostics lists them.
func is_embedded() -> bool:
	return resource_path.contains("::")


# Each setting's setter calls this. A variant keeps the settings changed from its base; set back to the base's value (the revert arrow
# does that), it follows the base again. Without a base nothing is kept: every value is its own, including the kind's defaults its
# _init() sets. So give a variant its base first, then change what differs.
func _changed(setting: StringName, value: Variant) -> void:
	_resolved = null
	if _copying_base or based_on == null:
		return
	var at := changed_values.find(setting)
	if Engine.is_editor_hint() and value == based_on.value_of(setting):
		if at >= 0:
			changed_values.remove_at(at)
			notify_property_list_changed()
	elif at < 0:
		changed_values.append(setting)
		if Engine.is_editor_hint():
			notify_property_list_changed()


# In the editor, a variant shows its base's values for the settings it hasn't changed.
func _show_base_values() -> void:
	if based_on == null:
		return
	_copying_base = true
	for setting in setting_names():
		if not changed_values.has(setting) and setting in based_on:
			set(setting, based_on.value_of(setting))
	_copying_base = false


# True if the base is the same kind, or one this kind is built on (a SprintDefinition based on a WalkDefinition).
func _base_fits() -> bool:
	var script: Script = get_script()
	var base_script: Script = based_on.get_script()
	while script:
		if script == base_script:
			return true
		script = script.get_base_script()
	return false


# A variant saves only the settings it changed; the rest follow its base.
func _validate_property(property: Dictionary) -> void:
	var usage: int = property["usage"]
	if based_on and usage & PROPERTY_USAGE_SCRIPT_VARIABLE and usage & PROPERTY_USAGE_EDITOR and property["name"] != "based_on" \
			and not changed_values.has(property["name"]):
		property["usage"] = usage & ~PROPERTY_USAGE_STORAGE


func _property_can_revert(property: StringName) -> bool:
	return based_on != null and changed_values.has(property)


func _property_get_revert(property: StringName) -> Variant:
	return based_on.value_of(property) if based_on else null
