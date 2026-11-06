## Written by Claude (claude-opus-5-5), 2026-11-06: a volume that changes how nav treats the ground in it (nav spec section 21.3).
## The usual term is a nav modifier volume. Tags such as area.road, area.hazard and area.water say what it means.
## NavAreaModule will hand these to nav. Until that exists they're registered and do nothing.
##
## An area names a surface instead of storing a cost, because each kind of agent has its own cost per surface
## (NavFilter, nav spec section 4). That lets a soldier avoid mud that a tank drives through.
class_name NavArea
extends NavMarker

## The box this area covers, in metres, centered on the marker's position. Boxes only for now.
@export var size := Vector3(4.0, 4.0, 4.0)
## The nav surface it sets, such as &"road" or &"water". There are 16 per game, including the default,
## so designers choose these with care. Empty = no surface change.
@export var surface: StringName
