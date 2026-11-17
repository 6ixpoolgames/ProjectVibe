# Written by Claude (claude-opus-5-5), 2026-11-06. History: navigation/CHANGELOG.md.
## A volume that changes how nav treats the ground in it (nav spec 21.3).
##
## Tags such as area.road, area.hazard and area.water say what it means. An area names a surface, not a cost, because each kind of
## agent has its own cost per surface (NavFilter, nav spec 4): a soldier avoids mud a tank drives through. NavAreaModule will hand
## areas to nav; until it exists they're registered and do nothing.
class_name NavArea
extends NavMarker

## The box this area covers, in metres, centered on the marker's position. Boxes only for now.
@export var size := Vector3(4.0, 4.0, 4.0)
## The nav surface it sets, such as &"road" or &"water". There are 16 per game, including the default,
## so designers choose these with care. Empty = no surface change.
@export var surface: StringName
