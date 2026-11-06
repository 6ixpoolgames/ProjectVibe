## Written by Claude (claude-opus-5-5), 2026-11-06: a spot that means something to AI (nav spec section 21.3).
## The usual terms are tactical point and point of interest (POI). Tags such as point.cover, point.patrol,
## point.ambush and point.wander say what it's for.
## It needs nothing beyond the base marker for now. It's a class of its own so that "marker is NavPoint"
## works as a filter, and so a module can announce that it handles points.
class_name NavPoint
extends NavMarker
