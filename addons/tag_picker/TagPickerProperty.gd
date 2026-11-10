@tool
## Written by Claude (claude-opus-5-5), 2026-11-10: an inspector editor for one tag or a list of tags, made by TagInspectorPlugin.
##
## One tag (an ability's category): a dropdown of the declared tags, with "(none)" first for no tag.
## A list (locks_out, cancelled_by): a dropdown per tag, each with a button to remove it, and "Add tag" under them.
## A value that isn't declared (typed before this plugin, or the tag was taken out of the declarations) still shows, marked
## "(not declared)", so nothing is lost silently; picking another tag replaces it.
##
## New tags are added to the declarations file (resources/tag_declarations.tres); the dropdowns list them at once.
extends EditorProperty

const NOT_DECLARED := "%s  (not declared)"

var _is_list := false
var _tags: Array[StringName] = []
var _box := VBoxContainer.new()


func _init(is_list: bool, tags: Array[StringName]) -> void:
	_is_list = is_list
	_tags = tags
	add_child(_box)
	if _is_list:
		set_bottom_editor(_box) # a list goes under the property's name, where there's room for several rows


## The inspector calls this whenever the value may have changed, including after our own emit_changed. It builds the controls again.
func _update_property() -> void:
	for child in _box.get_children():
		_box.remove_child(child)
		child.queue_free() # not free(): one of them may be the button whose signal led here
	var value: Variant = get_edited_object()[get_edited_property()]
	if not _is_list:
		var picker := _make_picker(value, true)
		picker.item_selected.connect(_on_single_selected.bind(picker))
		_box.add_child(picker)
		add_focusable(picker)
		return
	var list := _current_list()
	for i in list.size():
		var row := HBoxContainer.new()
		var picker := _make_picker(list[i], false)
		picker.item_selected.connect(_on_list_item_selected.bind(i, picker))
		row.add_child(picker)
		add_focusable(picker)
		var remove := Button.new()
		remove.text = "x"
		remove.tooltip_text = "Remove this tag"
		remove.pressed.connect(_on_remove.bind(i))
		row.add_child(remove)
		_box.add_child(row)
	var add := Button.new()
	add.text = "Add tag"
	add.pressed.connect(_on_add)
	_box.add_child(add)


func _make_picker(current: Variant, allow_none: bool) -> OptionButton:
	return make_picker(_tags, current, allow_none)


## A dropdown of these tags with current selected. Each item's metadata is its tag. Static, so the tests can check it outside the
## editor (an EditorProperty can only be made inside it).
static func make_picker(tags: Array[StringName], current: Variant, allow_none: bool) -> OptionButton:
	var picker := OptionButton.new()
	picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	picker.clip_text = true
	if allow_none:
		picker.add_item("(none)")
		picker.set_item_metadata(picker.item_count - 1, &"")
	for tag in tags:
		picker.add_item(String(tag))
		picker.set_item_metadata(picker.item_count - 1, tag)
	var wanted := StringName(current) if current != null else &""
	for i in picker.item_count:
		if picker.get_item_metadata(i) == wanted:
			picker.select(i)
			return picker
	if wanted != &"":
		picker.add_item(NOT_DECLARED % wanted)
		picker.set_item_metadata(picker.item_count - 1, wanted)
	picker.select(picker.item_count - 1 if wanted != &"" else 0)
	return picker


# The current list, as a typed copy to change and send back.
func _current_list() -> Array[StringName]:
	var out: Array[StringName] = []
	var value: Variant = get_edited_object()[get_edited_property()]
	if value is Array:
		for tag in value:
			out.append(StringName(tag))
	return out


func _on_single_selected(index: int, picker: OptionButton) -> void:
	emit_changed(get_edited_property(), picker.get_item_metadata(index))


func _on_list_item_selected(index: int, row: int, picker: OptionButton) -> void:
	var list := _current_list()
	if row < list.size():
		list[row] = picker.get_item_metadata(index)
		emit_changed(get_edited_property(), list)


func _on_remove(row: int) -> void:
	var list := _current_list()
	if row < list.size():
		list.remove_at(row)
		emit_changed(get_edited_property(), list)


# Adds the first declared tag the list doesn't have yet, ready to be changed with its dropdown.
func _on_add() -> void:
	var list := _current_list()
	var next: StringName = _tags[0] if not _tags.is_empty() else &""
	for tag in _tags:
		if not list.has(tag):
			next = tag
			break
	list.append(next)
	emit_changed(get_edited_property(), list)
