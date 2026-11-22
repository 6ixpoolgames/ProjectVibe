# Written by Claude (claude-opus-5-5), 2026-11-04. History: resources/CHANGELOG.md.
## A declarations file: the tags a game declares up front, each with a one-line description, plus renames and deprecations.
##
## [TagRegistry] reads the base file (resources/tag_declarations.tres) and any more a game lists in a project setting, merges them and
## gives bits in sorted order, so every machine in a multiplayer game agrees on them (tag spec 2). Write full names with dots for
## levels ("ability.combat.melee"); the first level is the category. Declare every level, categories included, so each has a
## description for the tag reference (tools/tags/make_tag_reference.py); a parent left out is added without one.
extends Resource
class_name TagDeclarationsRes

## The tags, full names with dots, each with a one-line description: what it is, not who uses it.
@export var tags: Dictionary[StringName, String] = {}
## Renames: old name -> new name. An old name in saved files is read as the new one (tag spec 5). Keep a redirect for good, so old
## replays and saves still load.
@export var redirects: Dictionary[StringName, StringName] = {}
## Tags on their way out: they still work, with a warning, and the tag picker hides them. Remove one once nothing saved uses it, and
## never reuse its name for something else.
@export var deprecated: Array[StringName] = []
