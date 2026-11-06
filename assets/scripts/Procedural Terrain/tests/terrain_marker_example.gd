## Written by Claude (claude-opus-5-5), 2026-11-06: an example of a terrain whose chunks announce their own markers.
## Copy this to give your own terrain links and points of interest. terrain_marker_sample.tscn shows it working, and
## its test is terrain_markers_selftest.
##
## It puts a seat in the middle of every chunk, and scatters cover points across it. Nothing here is random: which
## spots get cover comes from the grid point's number, so every machine and every reload gets the same markers.
@tool
class_name TerrainMarkerExample
extends HeightmapTerrain

## Checks a grid point for cover every this many squares.
const COVER_SPACING := 6


func _make_chunk_markers(key: Vector2i) -> Array[NavMarker]:
	var markers: Array[NavMarker] = []

	var seat := NavSmartObject.new()
	seat.tag = &"use.seat"
	seat.radius = 6.0 # large, so it can be seen from the sample's camera
	var middle := grid_size / 2
	seat.position = _point_at(key.x * grid_size + middle, key.y * grid_size + middle)
	markers.append(seat)

	# GDScript note: range's third number is the step, so this visits every COVER_SPACING squares.
	for z in range(0, grid_size, COVER_SPACING):
		for x in range(0, grid_size, COVER_SPACING):
			# The same numbers _make_point uses, so a point's number decides everything about it.
			var world_x_number := key.x * grid_size + x
			var world_z_number := key.y * grid_size + z
			# hash() always gives the same answer for the same input, so about a third of the spots get cover.
			if hash(Vector3i(world_x_number, world_z_number, noise_seed)) % 3 != 0:
				continue
			var cover := NavPoint.new()
			cover.tag = &"point.cover"
			cover.radius = 3.0
			cover.position = _point_at(world_x_number, world_z_number)
			markers.append(cover)
	return markers
