# Written by Claude (claude-opus-5-5), 2026-11-21. History: abilities/CHANGELOG.md.
## Gives every definition file (abilities, projectiles) an id that's the same on every machine with the same files (ability spec 3.1).
##
## The permanent id is the file's Godot resource UID (replays and saves keep it); the index is small, for the store and the network:
## the files in [constant FOLDERS], sorted by UID and numbered from 0, so machines with the same files agree. [method table] is the
## index-to-UID list a replay keeps. A definition embedded in a scene has no index. Why it's built this way: ability spec 3.1.
class_name DefinitionRegistry
extends RefCounted

## Where definition files are found, searched with their subfolders.
const FOLDERS: Array[String] = ["res://assets/scripts/resources/abilities/"]

# Index -> UID, sorted; UID -> path; UID -> index. Filled by scan.
static var _uids := PackedInt64Array()
static var _paths := {}
static var _index_of_uid := {}
static var _scanned := false


## Finds every definition file in the folders, numbers them and reports UIDs that clash (a file copied outside the editor keeps its
## original's). Called on first use; call it again after adding files while running.
static func scan(folders: Array[String] = FOLDERS) -> void:
	_paths.clear()
	_index_of_uid.clear()
	var found: Array[int] = []
	for folder in folders:
		for path in _files_in(folder):
			var uid := ResourceLoader.get_resource_uid(path)
			if uid == ResourceUID.INVALID_ID:
				push_warning("[DefinitionRegistry] %s has no UID; open and save it in the editor to give it one. It has no index." % path)
				continue
			if not load(path) is Definition:
				continue
			if _paths.has(uid):
				push_error("[DefinitionRegistry] %s and %s have the same UID (one was copied outside the editor); give one a new UID. Only the first has an index." % [_paths[uid], path])
				continue
			_paths[uid] = path
			found.append(uid)
	found.sort()
	_uids = PackedInt64Array(found)
	for index in _uids.size():
		_index_of_uid[_uids[index]] = index
	_scanned = true


## The definition's index, or -1 if it has none (embedded, made in code, or outside the folders). A resolved copy answers for the
## definition it was worked out from.
static func index_of(definition: Definition) -> int:
	if definition == null:
		return -1
	_scan_once()
	var source: Definition = definition.resolved_from if definition.resolved_from else definition
	if source.resource_path == "" or source.is_embedded():
		return -1
	return _index_of_uid.get(ResourceLoader.get_resource_uid(source.resource_path), -1)


## The index of this definition, or of the nearest one it's based on that has one: what a client can look up for an embedded variant,
## whose own changes then have to travel some other way (a projectile's launch record carries its flight numbers). -1 with none.
static func nearest_index(definition: Definition) -> int:
	var at: Definition = definition.resolved_from if definition and definition.resolved_from else definition
	var depth := 0
	while at and depth < Definition.MAX_BASE_DEPTH:
		var index := index_of(at)
		if index >= 0:
			return index
		at = at.based_on
		depth += 1
	return -1


## The definition with this index, or null.
static func find(index: int) -> Definition:
	_scan_once()
	if index < 0 or index >= _uids.size():
		return null
	return load(_paths[_uids[index]])


## The definition with this permanent id (a UID), wherever its file is now, or null.
static func find_by_uid(uid: int) -> Definition:
	_scan_once()
	return load(_paths[uid]) if _paths.has(uid) else null


## Index to UID, the list a replay keeps in its header.
static func table() -> PackedInt64Array:
	_scan_once()
	return _uids


## How many definitions have an index.
static func count() -> int:
	_scan_once()
	return _uids.size()


static func _scan_once() -> void:
	if not _scanned:
		scan()


# Resource files under the folder. An exported game lists a text resource as "x.tres.remap"; it loads by its own name.
static func _files_in(folder: String) -> PackedStringArray:
	var out := PackedStringArray()
	var dir := DirAccess.open(folder)
	if dir == null:
		return out
	for file in dir.get_files():
		var name := file.trim_suffix(".remap")
		if name.ends_with(".tres") or name.ends_with(".res"):
			out.append(folder.path_join(name))
	for sub in dir.get_directories():
		out.append_array(_files_in(folder.path_join(sub)))
	return out
