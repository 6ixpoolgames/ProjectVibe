# Written by Claude (claude-opus-5-5), 2026-11-07. History: abilities/CHANGELOG.md.
## Running faster while a charge lasts: a locomotion ability bound to &"sprint".
##
## It moves like Walk, at SprintSpeed. While &"sprint" is held and it has charge it runs instead of Walk. Sprinting drains the charge
## one tick per tick; [member recharge_delay] after it stops, the charge refills at [member recharge_rate]. It starts only with at least
## [member min_start_charge], so a held key on an empty charge doesn't flicker it on a tick at a time. An AI uses it by holding &"sprint".
## [br][br]The charge is worked out from two values set only when it starts or stops ([member charge_at_switch], [member switched_at]),
## so nothing changes while it drains or refills (ability spec 4). [member ready_at] is the tick the charge reaches the minimum, so the
## manager and the AI see when it can start again.
## Design: pawn spec 8.5.
class_name SprintAbility
extends WalkAbility

# Its settings with their own type: the same object as settings.
var _sprint: SprintDefinition = null

# Its settings, read from its definition (ability spec 3). Writing one is for a script's _init(); see AbilityBase._write_setting.
## From the definition: [member SprintDefinition.max_charge].
var max_charge: float:
	get:
		if _sprint == null:
			prepare_settings()
		return _sprint.max_charge
	set(value):
		_write_setting(&"max_charge", value)
## From the definition: [member SprintDefinition.recharge_rate].
var recharge_rate: float:
	get:
		if _sprint == null:
			prepare_settings()
		return _sprint.recharge_rate
	set(value):
		_write_setting(&"recharge_rate", value)
## From the definition: [member SprintDefinition.recharge_delay].
var recharge_delay: float:
	get:
		if _sprint == null:
			prepare_settings()
		return _sprint.recharge_delay
	set(value):
		_write_setting(&"recharge_delay", value)
## From the definition: [member SprintDefinition.min_start_charge].
var min_start_charge: float:
	get:
		if _sprint == null:
			prepare_settings()
		return _sprint.min_start_charge
	set(value):
		_write_setting(&"min_start_charge", value)

## Ticks of charge when it last started or stopped. Rolls back (pushed).
var charge_at_switch := 0:
	set(value):
		if value == charge_at_switch:
			return
		charge_at_switch = value
		push_state(&"charge_at_switch", value)
## The tick it last started or stopped; -1: never, so the charge is full. Rolls back (pushed).
var switched_at := -1:
	set(value):
		if value == switched_at:
			return
		switched_at = value
		push_state(&"switched_at", value)


## Ticks of sprinting it has now: draining while it runs, refilling while it doesn't. Worked out from the tick.
## Its kind's defaults: a new [SprintDefinition].
func make_default_definition() -> AbilityDefinition:
	return SprintDefinition.new()


func _settings_changed() -> void:
	super()
	_sprint = settings as SprintDefinition


func charge_ticks() -> int:
	if is_running_timed():
		return maxi(charge_at_switch - (TickDriver.tick - switched_at), 0)
	return _charge_while_stopped()


func is_timed() -> bool:
	return true


func get_pushed_properties() -> Array[String]:
	var out := super()
	if not out.has("ready_at"):
		out.append("ready_at") # when the charge reaches the minimum
	out.append_array(["charge_at_switch", "switched_at"])
	return out


# A run lasts as long as the charge it starts with.
func duration_ticks() -> int:
	return _charge_while_stopped()


func start() -> void:
	charge_at_switch = _charge_while_stopped()
	switched_at = TickDriver.tick


func stop() -> void:
	# ends_at is already cleared, so the charge left is worked out from the start.
	charge_at_switch = maxi(charge_at_switch - (TickDriver.tick - switched_at), 0)
	switched_at = TickDriver.tick
	ready_at = maxi(ready_at, _tick_charge_reaches(maxi(_ticks(minf(min_start_charge, max_charge)), 1)))


func delay_run(ticks: int) -> void:
	super(ticks)
	if is_running_timed():
		switched_at += ticks


func _charge_while_stopped() -> int:
	var full := _ticks(max_charge)
	if switched_at < 0:
		return full
	var refilling := TickDriver.tick - switched_at - _ticks(recharge_delay)
	if refilling <= 0:
		return mini(charge_at_switch, full)
	return mini(charge_at_switch + int(refilling * recharge_rate), full)


# The first tick the stopped charge is at least this many ticks.
func _tick_charge_reaches(wanted: int) -> int:
	if charge_at_switch >= wanted:
		return switched_at
	if recharge_rate <= 0.0:
		return NEVER
	return switched_at + _ticks(recharge_delay) + ceili((wanted - charge_at_switch) / recharge_rate)


func _ticks(seconds: float) -> int:
	return manager.ticks_for(seconds) if manager else 0
