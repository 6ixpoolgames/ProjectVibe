# Written by Claude (claude-opus-5-5), 2026-11-04. History: resources/CHANGELOG.md.
## A list of tags a game declares up front, for one tag set.
##
## Each tag set reads its own file at startup and gives bits in sorted order, so every machine in a multiplayer game agrees on them:
## TagRegistry (ability categories, tag_declarations.tres), NavTags (nav_tag_declarations.tres) and EffectTags
## (effect_tag_declarations.tres). Write full names with dots for levels ("combat.melee.sword"); parent levels ("combat",
## "combat.melee") are added automatically.
extends Resource
class_name TagDeclarationsRes

## The tags, full names with dots.
@export var tags: Array[StringName] = []
