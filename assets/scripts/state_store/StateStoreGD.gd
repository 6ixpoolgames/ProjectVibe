# Written by Claude (claude-opus-5-5), 2026-11-19. History: state_store/CHANGELOG.md.
## The GDScript twin of the C++ [code]StateStore[/code]: the central record of every gameplay entity's state, tick by tick.
##
## The tick driver holds one ([member TickDriverSingleton.store]) and commits it at the end of every tick: every bound entity's gathered
## columns are read from its nodes, rounded to their encodings (what rounding changed is written back) and copied into that tick's
## frame; pushed columns take the value last pushed. Rollback, snapshots and corrections read and write the frames. Entities with the
## same columns share a layout; slots never move, and a freed slot is reused only once the history has moved past it, with a new
## generation in its handle. Same calls and same results as the C++ class: a change goes in both, and the self-test compares them.
## Design: docs/state_store/STATE_STORE_SPEC.md (sections 4 to 7).
class_name StateStoreGD
extends RefCounted

## Stored for a value whose node or property was missing that tick. [method load_row] skips it.
const MISSING := &"__tick_state_missing__"

const _SLOT_BITS := 20
const _SLOT_MASK := (1 << 20) - 1
const _LAYOUT_MASK := (1 << 12) - 1


class _Entity:
	var generation := 0
	var alive := false
	var active := true
	var bound := false
	var round_values := true
	var freed_tick := -1
	var owner_id := 0
	var depth := 0
	var newest := -1
	var node_ids: PackedInt64Array = PackedInt64Array()
	var paths: Array[NodePath] = []
	var encodings: Array[StringName] = []
	var pushed: Array = []


class _Layout:
	var signature := ""
	var names := PackedStringArray()
	var encodings: Array[StringName] = []
	var pushed := PackedByteArray()
	var width := 0
	var gathered := 0              # columns read from nodes; 0: only pushed ones, so nothing to bind
	var slots: Array[_Entity] = []
	var free_slots: Array[int] = []
	# REFACTOR: cells are Variants, as in the C++ store; typed lanes come with the first worker job that reads them (changelog row).
	var cells: Array = []          # slot-major: ((slot * depth) + frame) * width + column
	var row_tick := PackedInt64Array()
	var row_generation := PackedInt64Array()


var _depth := 64
var _now := -1
var _commit_usec := 0
var _layouts: Array[_Layout] = []


## Forgets every layout and entity. The depth stays.
func clear() -> void:
	_layouts.clear()
	_now = -1


## Frames kept. Only while the store holds no entity; false otherwise.
func set_depth(depth: int) -> bool:
	for layout in _layouts:
		if not layout.slots.is_empty():
			return false
	_depth = maxi(1, depth)
	return true


func get_depth() -> int:
	return _depth


## A layout from its columns: names, encoding names and, optionally, a 1 for each pushed column. The same columns give the same
## layout number. An "auto" column takes each entity's encoding from its binding. -1, with an error, for an unknown encoding or a size
## mismatch.
func define_layout(names: PackedStringArray, encodings: Array, pushed: PackedByteArray = PackedByteArray()) -> int:
	if names.size() != encodings.size() or (pushed.size() != 0 and pushed.size() != names.size()):
		push_error("StateStore.define_layout: names, encodings and pushed must be the same size")
		return -1
	var signature := ""
	var kinds := PackedByteArray()
	var typed: Array[StringName] = []
	for i in names.size():
		var encoding := StringName(encodings[i])
		if not StateEncoding.is_known(encoding):
			push_error("StateStore.define_layout: '%s' has no usable encoding: %s" % [names[i], encoding])
			return -1
		var kind := (1 if pushed[i] else 0) if pushed.size() else 0
		kinds.append(kind)
		typed.append(encoding)
		signature += names[i] + "@" + String(encoding) + ("^" if kind else "") + "|"
	for l in _layouts.size():
		if _layouts[l].signature == signature:
			return l
	if _layouts.size() > _LAYOUT_MASK:
		push_error("StateStore.define_layout: too many layouts")
		return -1
	var layout := _Layout.new()
	layout.signature = signature
	layout.names = names
	layout.encodings = typed
	layout.pushed = kinds
	layout.width = names.size()
	for kind in kinds:
		layout.gathered += 0 if kind else 1
	_layouts.append(layout)
	return _layouts.size() - 1


func get_layout_count() -> int:
	return _layouts.size()


func get_layout_columns(layout: int) -> PackedStringArray:
	return _layouts[layout].names if layout >= 0 and layout < _layouts.size() else PackedStringArray()


## A new entity in a layout, owned by owner (asked to gather when the store can't; may be null). Returns its handle, or -1.
func add_entity(layout_index: int, owner: Object) -> int:
	if layout_index < 0 or layout_index >= _layouts.size():
		return -1
	var layout := _layouts[layout_index]
	var slot := -1
	if not layout.free_slots.is_empty():
		var oldest: int = layout.free_slots[0]
		if _now - layout.slots[oldest].freed_tick >= _depth:
			slot = oldest
			layout.free_slots.pop_front()
	if slot < 0:
		if layout.slots.size() > _SLOT_MASK:
			push_error("StateStore.add_entity: the layout is full")
			return -1
		slot = layout.slots.size()
		layout.slots.append(_Entity.new())
		layout.cells.resize(layout.cells.size() + _depth * layout.width)
		var rows := layout.row_tick.size()
		layout.row_tick.resize(rows + _depth)
		layout.row_generation.resize(rows + _depth)
		for r in range(rows, rows + _depth):
			layout.row_tick[r] = -1
			layout.row_generation[r] = 0
	var entity := layout.slots[slot]
	entity.generation += 1
	if entity.generation >= 0x7fffffff:
		entity.generation = 1
	entity.alive = true
	entity.active = true
	entity.bound = false
	entity.round_values = true
	entity.freed_tick = -1
	entity.owner_id = owner.get_instance_id() if owner else 0
	entity.depth = _depth
	entity.newest = -1
	entity.node_ids = PackedInt64Array()
	entity.paths = []
	entity.pushed = []
	entity.pushed.resize(layout.width)
	# With only pushed columns there's nothing to bind: it commits from the start.
	if layout.gathered == 0:
		entity.node_ids.resize(layout.width)
		entity.paths.resize(layout.width)
		entity.bound = true
	return _make_handle(entity.generation, layout_index, slot)


## Frees an entity: it stops committing at once, and its rows stay readable until overwritten.
func remove_entity(handle: int) -> void:
	var layout := _layout_of(handle)
	if layout == null:
		return
	var slot := handle & _SLOT_MASK
	var entity := layout.slots[slot]
	entity.alive = false
	entity.bound = false
	entity.node_ids = PackedInt64Array()
	entity.paths = []
	entity.freed_tick = _now
	layout.free_slots.append(slot)


func is_alive(handle: int) -> bool:
	return _entity_of(handle) != null


## An inactive entity isn't committed (a client's entity drawn from the server, a paused pawn). Rows already written stay.
func set_active(handle: int, active: bool) -> void:
	var entity := _entity_of(handle)
	if entity:
		entity.active = active


func is_active(handle: int) -> bool:
	var entity := _entity_of(handle)
	return entity != null and entity.active


## How many ticks back this entity's rows count, at most the store's depth.
func set_entity_depth(handle: int, depth: int) -> void:
	var entity := _entity_of(handle)
	if entity:
		entity.depth = clampi(depth, 1, _depth)


func get_owner(handle: int) -> Object:
	var entity := _entity_of(handle)
	return instance_from_id(entity.owner_id) if entity and entity.owner_id else null


## The accessors for an entity's gathered columns: one node, one property path and one encoding per column, in column order (pushed
## columns' entries are ignored). An encoding must be settled (never "auto") and match the layout's unless the layout's is "auto".
## round_values: round to each encoding and write back what changed. False, binding nothing, otherwise.
func bind(handle: int, nodes: Array, properties: Array, encodings: Array, round_values: bool) -> bool:
	var layout := _layout_of(handle)
	if layout == null or nodes.size() != layout.width or properties.size() != layout.width or encodings.size() != layout.width:
		return false
	var ids := PackedInt64Array()
	ids.resize(layout.width)
	var paths: Array[NodePath] = []
	paths.resize(layout.width)
	var settled: Array[StringName] = []
	settled.resize(layout.width)
	for c in layout.width:
		if layout.pushed[c]:
			continue
		var node: Object = nodes[c]
		var encoding := StringName(encodings[c])
		if node == null or not StateEncoding.is_known(encoding) or encoding == StateEncoding.AUTO \
				or (layout.encodings[c] != StateEncoding.AUTO and layout.encodings[c] != encoding):
			return false
		ids[c] = node.get_instance_id()
		paths[c] = NodePath(properties[c])
		settled[c] = encoding
	var entity := layout.slots[handle & _SLOT_MASK]
	entity.node_ids = ids
	entity.paths = paths
	entity.encodings = settled
	entity.round_values = round_values
	entity.bound = true
	return true


func unbind(handle: int) -> void:
	var entity := _entity_of(handle)
	if entity:
		entity.bound = false
		entity.node_ids = PackedInt64Array()
		entity.paths = []


func is_bound(handle: int) -> bool:
	var entity := _entity_of(handle)
	return entity != null and entity.bound


## Sets a pushed column's value; every commit from now on records it, until the next push.
func push(handle: int, column: int, value: Variant) -> void:
	var layout := _layout_of(handle)
	if layout == null or column < 0 or column >= layout.width:
		return
	layout.slots[handle & _SLOT_MASK].pushed[column] = StateEncoding.copy_value(value)


## The end of a tick: every active entity's row for this tick. Returns the handles the store couldn't gather (unbound, or a node gone,
## which unbinds it); their owners write them with [method write_row].
func commit(tick: int) -> PackedInt64Array:
	var started := Time.get_ticks_usec()
	_now = tick
	var unfinished := PackedInt64Array()
	for l in _layouts.size():
		var layout := _layouts[l]
		for slot in layout.slots.size():
			var entity := layout.slots[slot]
			if not entity.alive or not entity.active:
				continue
			if not _commit_one(layout, slot, tick):
				unfinished.append(_make_handle(entity.generation, l, slot))
	_commit_usec = Time.get_ticks_usec() - started
	return unfinished


## The same for some entities only (a rollback's re-run rewriting past frames).
func commit_entities(tick: int, handles: PackedInt64Array) -> PackedInt64Array:
	var unfinished := PackedInt64Array()
	for handle in handles:
		var layout := _layout_of(handle)
		if layout == null or not layout.slots[handle & _SLOT_MASK].active:
			continue
		if not _commit_one(layout, handle & _SLOT_MASK, tick):
			unfinished.append(handle)
	return unfinished


## An owner's own gather: the whole row for that tick. False for a dead handle or a size mismatch.
func write_row(handle: int, tick: int, values: Array) -> bool:
	var layout := _layout_of(handle)
	if layout == null or values.size() != layout.width:
		return false
	var slot := handle & _SLOT_MASK
	var entity := layout.slots[slot]
	var row := slot * _depth + _frame_of(tick)
	var base := row * layout.width
	for c in layout.width:
		layout.cells[base + c] = StateEncoding.copy_value(values[c])
	layout.row_tick[row] = tick
	layout.row_generation[row] = entity.generation
	entity.newest = maxi(entity.newest, tick)
	return true


func has_row(handle: int, tick: int) -> bool:
	if handle < 0:
		return false
	var l := (handle >> _SLOT_BITS) & _LAYOUT_MASK
	var slot := handle & _SLOT_MASK
	if l >= _layouts.size() or slot >= _layouts[l].slots.size():
		return false
	var entity := _entity_of(handle)
	# A freed entity's rows still count until they're overwritten.
	return _row_held(_layouts[l], slot, handle >> 32, entity.depth if entity else _depth, tick)


## A copy of the row (containers copied too), or empty if the history doesn't hold it.
func get_row(handle: int, tick: int) -> Array:
	var out: Array = []
	if not has_row(handle, tick):
		return out
	var layout := _layouts[(handle >> _SLOT_BITS) & _LAYOUT_MASK]
	var base := ((handle & _SLOT_MASK) * _depth + _frame_of(tick)) * layout.width
	out.resize(layout.width)
	for c in layout.width:
		out[c] = StateEncoding.copy_value(layout.cells[base + c])
	return out


func get_value(handle: int, column: int, tick: int) -> Variant:
	if not has_row(handle, tick):
		return null
	var layout := _layouts[(handle >> _SLOT_BITS) & _LAYOUT_MASK]
	if column < 0 or column >= layout.width:
		return null
	return StateEncoding.copy_value(layout.cells[((handle & _SLOT_MASK) * _depth + _frame_of(tick)) * layout.width + column])


## Overwrites one value in a held row (a correction from the server). False if the row isn't held.
func set_value(handle: int, column: int, tick: int, value: Variant) -> bool:
	if not has_row(handle, tick):
		return false
	var layout := _layouts[(handle >> _SLOT_BITS) & _LAYOUT_MASK]
	if column < 0 or column >= layout.width:
		return false
	layout.cells[((handle & _SLOT_MASK) * _depth + _frame_of(tick)) * layout.width + column] = StateEncoding.copy_value(value)
	return true


## Writes a held row back into a bound entity's nodes ([constant MISSING] values skipped) and its pushed values. False if not bound or not held.
func load_row(handle: int, tick: int) -> bool:
	var layout := _layout_of(handle)
	if layout == null or not layout.slots[handle & _SLOT_MASK].bound or not has_row(handle, tick):
		return false
	var entity := layout.slots[handle & _SLOT_MASK]
	var base := ((handle & _SLOT_MASK) * _depth + _frame_of(tick)) * layout.width
	for c in layout.width:
		var value: Variant = layout.cells[base + c]
		if layout.pushed[c]:
			entity.pushed[c] = StateEncoding.copy_value(value)
			continue
		if value is StringName and value == MISSING:
			continue
		var node := instance_from_id(entity.node_ids[c])
		if node:
			node.set_indexed(entity.paths[c], StateEncoding.copy_value(value))
	return true


## The newest tick this entity has a row for; -1 for none.
func newest_tick(handle: int) -> int:
	var entity := _entity_of(handle)
	return entity.newest if entity else -1


## One column of a layout at a tick: {"handles": PackedInt64Array, "values": Array}, for every row held for that tick.
func get_column(layout_index: int, column: int, tick: int) -> Dictionary:
	var handles := PackedInt64Array()
	var values: Array = []
	if layout_index >= 0 and layout_index < _layouts.size() and column >= 0 and column < _layouts[layout_index].width:
		var layout := _layouts[layout_index]
		var frame := _frame_of(tick)
		for slot in layout.slots.size():
			var row := slot * _depth + frame
			if tick < 0 or tick <= _now - _depth or layout.row_tick[row] != tick or layout.row_generation[row] == 0:
				continue
			handles.append(_make_handle(layout.row_generation[row], layout_index, slot))
			values.append(StateEncoding.copy_value(layout.cells[row * layout.width + column]))
	return {"handles": handles, "values": values}


## A checksum of every row held for that tick, in layout and slot order. The C++ store gives the same number.
func frame_checksum(tick: int) -> int:
	var all: Array = [tick]
	if tick >= 0 and tick > _now - _depth:
		var frame := _frame_of(tick)
		for l in _layouts.size():
			var layout := _layouts[l]
			for slot in layout.slots.size():
				var row := slot * _depth + frame
				if layout.row_tick[row] != tick or layout.row_generation[row] == 0:
					continue
				all.append(l)
				all.append(slot)
				all.append(layout.row_generation[row])
				var base := row * layout.width
				for c in layout.width:
					all.append(layout.cells[base + c])
	return hash(all)


## The determinism tripwire: handles of bound, active entities whose nodes no longer hold (once rounded) what their row for that tick
## says. Empty when nothing wrote around the store.
func verify_nodes(tick: int) -> PackedInt64Array:
	var differ := PackedInt64Array()
	for l in _layouts.size():
		var layout := _layouts[l]
		for slot in layout.slots.size():
			var entity := layout.slots[slot]
			if not entity.alive or not entity.active or not entity.bound or not _row_held(layout, slot, entity.generation, entity.depth, tick):
				continue
			var base := (slot * _depth + _frame_of(tick)) * layout.width
			for c in layout.width:
				if layout.pushed[c]:
					continue
				var node := instance_from_id(entity.node_ids[c])
				if node == null:
					continue
				var value: Variant = node.get_indexed(entity.paths[c])
				if entity.round_values:
					value = StateEncoding.quantize(value, entity.encodings[c])
				if value != layout.cells[base + c]:
					differ.append(_make_handle(entity.generation, l, slot))
					break
	return differ


## StateEncoding.quantize, the same rounding the commit does.
func quantize(value: Variant, encoding: StringName) -> Variant:
	return StateEncoding.quantize(value, encoding) if StateEncoding.is_known(encoding) and encoding != StateEncoding.AUTO else value


## {layouts, entities, active, bound, cells_per_frame, depth, commit_usec}.
func get_stats() -> Dictionary:
	var entities := 0
	var active := 0
	var bound := 0
	var cells := 0
	for layout in _layouts:
		for entity in layout.slots:
			if not entity.alive:
				continue
			entities += 1
			active += 1 if entity.active else 0
			bound += 1 if entity.bound else 0
			cells += layout.width if entity.active else 0
	return {"layouts": _layouts.size(), "entities": entities, "active": active, "bound": bound, "cells_per_frame": cells, "depth": _depth, "commit_usec": _commit_usec}


# --- Internals ---------------------------------------------------------------------------------

# One entity's row for a tick, gathered from its nodes. False (writing nothing) if it isn't bound or a node is gone, which unbinds it.
func _commit_one(layout: _Layout, slot: int, tick: int) -> bool:
	var entity := layout.slots[slot]
	if not entity.bound:
		return false
	var nodes: Array = []
	nodes.resize(layout.width)
	for c in layout.width:
		if layout.pushed[c]:
			continue
		var node := instance_from_id(entity.node_ids[c])
		if node == null:
			entity.bound = false
			entity.node_ids = PackedInt64Array()
			entity.paths = []
			return false
		nodes[c] = node
	var row := slot * _depth + _frame_of(tick)
	var base := row * layout.width
	for c in layout.width:
		if layout.pushed[c]:
			layout.cells[base + c] = StateEncoding.copy_value(entity.pushed[c])
			continue
		var node: Object = nodes[c]
		var value: Variant = node.get_indexed(entity.paths[c])
		if entity.round_values:
			var rounded: Variant = StateEncoding.quantize(value, entity.encodings[c])
			if rounded != value:
				node.set_indexed(entity.paths[c], rounded)
				value = rounded
		layout.cells[base + c] = StateEncoding.copy_value(value)
	layout.row_tick[row] = tick
	layout.row_generation[row] = entity.generation
	entity.newest = maxi(entity.newest, tick)
	return true


func _row_held(layout: _Layout, slot: int, generation: int, depth: int, tick: int) -> bool:
	if tick < 0 or tick <= _now - depth:
		return false
	var row := slot * _depth + _frame_of(tick)
	return layout.row_tick[row] == tick and layout.row_generation[row] == generation


func _layout_of(handle: int) -> _Layout:
	if handle < 0:
		return null
	var l := (handle >> _SLOT_BITS) & _LAYOUT_MASK
	var slot := handle & _SLOT_MASK
	if l >= _layouts.size() or slot >= _layouts[l].slots.size():
		return null
	var entity := _layouts[l].slots[slot]
	if not entity.alive or entity.generation != (handle >> 32):
		return null
	return _layouts[l]


func _entity_of(handle: int) -> _Entity:
	var layout := _layout_of(handle)
	return layout.slots[handle & _SLOT_MASK] if layout else null


func _frame_of(tick: int) -> int:
	return posmod(tick, _depth)


static func _make_handle(generation: int, layout: int, slot: int) -> int:
	return (generation << 32) | (layout << _SLOT_BITS) | slot
