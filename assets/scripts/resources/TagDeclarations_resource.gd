## Written by Claude (claude-opus-5-5), 2026-11-04: the list of tags (ability categories, later nav capabilities) the game declares up front.
## TagRegistry reads this at startup and gives bits in sorted order, so every machine in a multiplayer game agrees on them.
## Write full names with dots for levels ("combat.melee.sword"); parent levels ("combat", "combat.melee") are added automatically.
extends Resource
class_name TagDeclarationsRes

@export var tags: Array[StringName] = []
