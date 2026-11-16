## Written by Claude (claude-opus-5-5), 2026-11-16: a start menu's match options, built from the settings themselves, the owner's request
## ("add the distance and other options to the start game menu ... this should prove out modularity of gamemode").
##
## What it shows: a heading and one row per setting, for any object that names some of its own properties. Every GameMode module can
## name its settings (GameModeModule.get_match_options), so add_from_game_mode() lists whichever modules this game has: take a module
## out of the project setting project_base/game_mode/modules and its options leave the menu, with nothing here naming it. A level, an
## autoload or anything else is added the same way with add_section().
##
## How a row is made: from the property's own description, as the inspector does (Object.get_property_list):
##   - a bool: a check box
##   - an int with an enum (@export_enum): a drop-down of its names
##   - an int or float: a number box, with the range, step and "or_greater" of an @export_range when it has one
## Changing a row sets the property at once, so a setter runs as it would from code. refresh() reads every value again (call it when
## the menu is shown, since keys or code may have changed them).
##
## Use:
##   var panel := MatchOptionsPanel.new()
##   menu_box.add_child(panel)
##   panel.add_section("This level", self, PackedStringArray(["team_size", "spawn_distance"]))
##   panel.add_from_game_mode()
##   panel.add_from_autoloads()   # Claude 2026-11-16: the tick driver's and network session's, which name their own
class_name MatchOptionsPanel
extends VBoxContainer

## Each row: [object, property name, the control]. refresh() walks these.
var _rows: Array = []


## Adds a heading and a row for each named property of target. Names target doesn't have are skipped with a warning.
func add_section(heading: String, target: Object, names: PackedStringArray) -> void:
	if target == null or names.is_empty():
		return
	var title := Label.new()
	title.text = heading
	title.add_theme_font_size_override(&"font_size", 15)
	add_child(title)
	# GDScript note: get_property_list() gives a Dictionary per property: "name", "type", "hint" and "hint_string" are the ones used here.
	var described := {}
	for info: Dictionary in target.get_property_list():
		described[info["name"]] = info
	for property in names:
		if not described.has(property):
			push_warning("[MatchOptionsPanel] '%s' has no property '%s'" % [heading, property])
			continue
		_add_row(target, described[property])


## Adds a section for every GameMode module that names match options, headed by the module's node name.
func add_from_game_mode() -> void:
	var game_mode: Node = get_node_or_null(^"/root/GameMode")
	if game_mode == null:
		return
	for module: GameModeModule in game_mode.get_modules():
		add_section(String(module.name).capitalize(), module, module.get_match_options())


## Claude 2026-11-16: adds a section for every autoload that names match options (a get_match_options() function, as GameMode
## modules have), headed by its name, in the project's autoload order. The autoloads are the project setting's "autoload/" entries;
## one without the function (GameMode itself, the legacy ones) is skipped.
func add_from_autoloads() -> void:
	for info: Dictionary in ProjectSettings.get_property_list():
		var setting: String = info["name"]
		if not setting.begins_with("autoload/"):
			continue
		var autoload_name := setting.trim_prefix("autoload/")
		var node := get_node_or_null(NodePath("/root/" + autoload_name))
		if node and node.has_method(&"get_match_options"):
			add_section(autoload_name.capitalize(), node, node.get_match_options())


## Reads every value again into its row.
func refresh() -> void:
	for row: Array in _rows:
		_refresh_row(row)


# Claude 2026-11-16 (audit): one row's value read again (refresh() did every row each time one was added).
func _refresh_row(row: Array) -> void:
	var target: Object = row[0]
	if not is_instance_valid(target):
		return
	var control: Control = row[2]
	var value: Variant = target.get(row[1])
	if control is CheckBox:
		(control as CheckBox).set_pressed_no_signal(bool(value))
	elif control is OptionButton:
		var options := control as OptionButton
		for i in options.item_count:
			if options.get_item_id(i) == int(value):
				options.select(i)
	elif control is SpinBox:
		(control as SpinBox).set_value_no_signal(float(value))


func _add_row(target: Object, info: Dictionary) -> void:
	var property: String = info["name"]
	var row := HBoxContainer.new()
	var label := Label.new()
	label.text = property.capitalize() # GDScript note: "spawn_distance" becomes "Spawn Distance"
	label.custom_minimum_size.x = 230
	row.add_child(label)
	var control: Control = null
	var type: int = info["type"]
	var hint: int = info["hint"]
	if type == TYPE_BOOL:
		var box := CheckBox.new()
		box.toggled.connect(func(on: bool) -> void: target.set(property, on))
		control = box
	elif type == TYPE_INT and hint == PROPERTY_HINT_ENUM:
		control = _enum_choice(target, property, info["hint_string"])
	elif type == TYPE_INT or type == TYPE_FLOAT:
		control = _number_box(target, property, type, hint, info["hint_string"])
	else:
		push_warning("[MatchOptionsPanel] '%s' is a %s, which has no row yet" % [property, type_string(type)])
		return
	control.custom_minimum_size.x = 120
	row.add_child(control)
	add_child(row)
	_rows.append([target, property, control])
	_refresh_row(_rows[-1])


# An @export_enum's hint_string is "Name:value,Name:value" (or just names, numbered from 0).
func _enum_choice(target: Object, property: String, hint_string: String) -> OptionButton:
	var options := OptionButton.new()
	var next := 0
	for part in hint_string.split(","):
		var pieces := part.split(":")
		var id := int(pieces[1]) if pieces.size() > 1 else next
		options.add_item(pieces[0], id)
		next = id + 1
	options.item_selected.connect(func(index: int) -> void: target.set(property, options.get_item_id(index)))
	return options


# An @export_range's hint_string is "min,max,step" with extras such as "or_greater".
func _number_box(target: Object, property: String, type: int, hint: int, hint_string: String) -> SpinBox:
	var box := SpinBox.new()
	box.min_value = -1000000.0
	box.max_value = 1000000.0
	box.step = 1.0 if type == TYPE_INT else 0.01
	if hint == PROPERTY_HINT_RANGE:
		var parts := hint_string.split(",")
		if parts.size() >= 2:
			box.min_value = float(parts[0])
			box.max_value = float(parts[1])
		if parts.size() >= 3 and parts[2].is_valid_float():
			box.step = float(parts[2])
		box.allow_greater = parts.has("or_greater")
		box.allow_lesser = parts.has("or_less")
	# GDScript note: an if, not "a if b else c", because an int and a float aren't one type and the editor warns about that.
	box.value_changed.connect(func(value: float) -> void:
		if type == TYPE_INT:
			target.set(property, int(value))
		else:
			target.set(property, value))
	return box
