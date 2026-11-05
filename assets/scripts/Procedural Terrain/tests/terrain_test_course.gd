## Written by Claude (claude-opus-5-5), 2026-11-05: HeightmapTerrain with the same test course as nav_test_terrain.gd:
## a flat plaza in the middle and a 3 m wall with a gap. The test uses it to compare the two generators, and it's the
## example to copy for shaping terrain beyond the noise.
extends HeightmapTerrain


# GDScript note: this replaces the _shape_height in HeightmapTerrain, because this script extends it. Everything else
# in HeightmapTerrain still runs as written, and calls this version when it needs a height.
func _shape_height(x: float, z: float, noise_height: float) -> float:
	# Flat within about 10 m of the origin, fading in to the full noise by 30 m.
	var flat := smoothstep(10.0, 30.0, Vector2(x, z).length())
	var height := noise_height * flat
	# A wall along x, from z = 8 to z = 10, with a gap of about 2 m at x = 0.
	if absf(z - 9.0) <= 1.0 and absf(x) >= 2.0 and absf(x) <= 40.0:
		height += 3.0
	return height
