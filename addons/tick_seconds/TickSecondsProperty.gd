@tool
# Written by Claude (claude-opus-5-5), 2026-11-24. History: singletons/CHANGELOG.md.
## An inspector editor for a setting counted in ticks at 60 a second: the number, with the time it stands for in seconds beside it.
## Made by TickSecondsInspectorPlugin for whole-number settings whose names end in [code]_ticks[/code]. Negative values usually mean
## something special (-1: never, or use another setting), so they show no seconds.
extends EditorProperty

## The rate settings are written for (TickDriver.REFERENCE_RATE; the autoload doesn't run in the editor).
const REFERENCE_RATE := 60.0

var _spin := EditorSpinSlider.new()
var _seconds := Label.new()
var _updating := false


func _init(hint_type: PropertyHint, hint_string: String) -> void:
	var limits := range_of(hint_type, hint_string)
	_spin.min_value = limits["min"]
	_spin.max_value = limits["max"]
	_spin.allow_lesser = limits["or_less"]
	_spin.allow_greater = limits["or_greater"]
	_spin.step = 1.0
	_spin.rounded = true
	_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_seconds.custom_minimum_size.x = 64.0
	_seconds.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_seconds.modulate = Color(1.0, 1.0, 1.0, 0.6)
	var row := HBoxContainer.new()
	row.add_child(_spin)
	row.add_child(_seconds)
	add_child(row)
	add_focusable(_spin)
	_spin.value_changed.connect(_on_value_changed)


## The inspector calls this whenever the value may have changed.
func _update_property() -> void:
	var value: int = int(get_edited_object()[get_edited_property()])
	_updating = true
	_spin.value = value
	_updating = false
	_seconds.text = seconds_text(value)


func _on_value_changed(value: float) -> void:
	if _updating:
		return
	_seconds.text = seconds_text(int(value))
	emit_changed(get_edited_property(), int(value))


## The seconds a tick count stands for at 60 a second, as shown: "0.5 s". Empty for a negative count. Static, so the tests can check it.
static func seconds_text(ticks: int) -> String:
	if ticks < 0:
		return ""
	var seconds := ticks / REFERENCE_RATE
	var text := "%.2f" % seconds
	text = text.rstrip("0").rstrip(".") if text.contains(".") else text
	return "%s s" % text


## The limits a range hint gives ("0,600,1,or_greater"): min, max, or_less, or_greater. With no range hint, wide limits both ways.
## Static, so the tests can check it.
static func range_of(hint_type: PropertyHint, hint_string: String) -> Dictionary:
	var out := {"min": -1000000.0, "max": 1000000.0, "or_less": true, "or_greater": true}
	if hint_type != PROPERTY_HINT_RANGE:
		return out
	var parts := hint_string.split(",")
	if parts.size() >= 2 and parts[0].is_valid_float() and parts[1].is_valid_float():
		out["min"] = parts[0].to_float()
		out["max"] = parts[1].to_float()
		out["or_less"] = parts.has("or_less")
		out["or_greater"] = parts.has("or_greater")
	return out
