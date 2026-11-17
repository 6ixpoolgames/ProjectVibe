# Written by Claude (claude-opus-5-5), 2026-11-06. History: navigation/CHANGELOG.md.
## A spot that means something to AI: a tactical point or point of interest (nav spec 21.3).
##
## Tags such as point.cover, point.patrol, point.ambush and point.wander say what it's for. It adds nothing to [NavMarker]; it's a
## class of its own so "marker is NavPoint" works as a filter and a module can say it handles points.
class_name NavPoint
extends NavMarker
