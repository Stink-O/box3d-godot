extends SceneTree

## One-off generator for samples/car_terrain.res: the Car sample's rolling
## ground, grown from the wave height field box3d's own Driving sample builds
## with b3CreateWave (heights are products of sines). Two scales are stacked
## so the ground is never billiard-flat between hills:
##   - long swells the car crests (as upstream, but taller), and
##   - short gentle ripples that give the surface visible relief everywhere.
## The phase is centred so the spawn point sits on a flat saddle.
##
## Each vertex also gets a COLOR from its height (moss lows -> sun-dried
## highs) and slope (steeper -> earthier), so the terrain reads as rolling
## ground instead of one flat-lit blob; the scene's terrain material has
## vertex_color_use_as_albedo on.
##
## Run from this project:
##   godot --headless --path . -s tools/gen_car_terrain.gd
##
## The committed car_terrain.res is the source of truth; car.tscn shows it in
## a MeshInstance3D under a shape_type = Mesh static body (the collider is
## built from the same mesh).

const VERTS := 81 # vertices per side -> 80x80 cells
const CELL := 3.0 # metres per cell -> a 240 m square
const SWELL_AMP := 3.0
const SWELL_ROW_FREQ := 0.02 # cycles per row index, as upstream
const SWELL_COLUMN_FREQ := 0.04
const RIPPLE_AMP := 0.45
const RIPPLE_ROW_FREQ := 0.11
const RIPPLE_COLUMN_FREQ := 0.13

const COLOR_LOW := Color(0.2, 0.32, 0.17)    # moss in the hollows
const COLOR_HIGH := Color(0.56, 0.6, 0.32)   # dried grass on the crests
const COLOR_STEEP := Color(0.4, 0.32, 0.2)   # earth on the slopes
# The rim darkens toward a distant-ridge green. It must stay GREEN: a
# neutral grey out there sits in the key light's falloff and picks up only
# the blue sky ambient + fill, rendering as flat navy "lakes".
const COLOR_FAR := Color(0.12, 0.18, 0.11)
const RIM_FADE_START := 95.0  # metres from centre where the far darkening begins

func _init() -> void:
	var c := (VERTS - 1) / 2.0 # integer for odd VERTS: sin(0) = 0 at the origin
	var sw_z := TAU * SWELL_ROW_FREQ
	var sw_x := TAU * SWELL_COLUMN_FREQ
	var rp_z := TAU * RIPPLE_ROW_FREQ
	var rp_x := TAU * RIPPLE_COLUMN_FREQ

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	# Vertex grid: i walks z, j walks x (matching upstream's rows/columns).
	var pos: Array = []
	var nrm: Array = []
	var col: Array = []
	for i in range(VERTS):
		for j in range(VERTS):
			var x := (j - c) * CELL
			var z := (i - c) * CELL
			var y := SWELL_AMP * sin(sw_z * (i - c)) * sin(sw_x * (j - c)) \
					+ RIPPLE_AMP * sin(rp_z * (i - c)) * sin(rp_x * (j - c))
			pos.append(Vector3(x, y, z))

			# Analytic surface normal from the summed height gradients.
			var dydx := SWELL_AMP * (sw_x / CELL) * sin(sw_z * (i - c)) * cos(sw_x * (j - c)) \
					+ RIPPLE_AMP * (rp_x / CELL) * sin(rp_z * (i - c)) * cos(rp_x * (j - c))
			var dydz := SWELL_AMP * (sw_z / CELL) * cos(sw_z * (i - c)) * sin(sw_x * (j - c)) \
					+ RIPPLE_AMP * (rp_z / CELL) * cos(rp_z * (i - c)) * sin(rp_x * (j - c))
			var n := Vector3(-dydx, 1.0, -dydz).normalized()
			nrm.append(n)

			# Height gradient, earthier on slopes, plus a whisper of hash
			# variation so large faces don't band.
			var t := clampf(inverse_lerp(-SWELL_AMP - RIPPLE_AMP, SWELL_AMP + RIPPLE_AMP, y), 0.0, 1.0)
			var ground := COLOR_LOW.lerp(COLOR_HIGH, t)
			ground = ground.lerp(COLOR_STEEP, clampf((1.0 - n.y) * 14.0, 0.0, 0.55))
			var grain := 0.94 + 0.06 * fposmod(sin(i * 12.9898 + j * 78.233) * 43758.55, 1.0)
			ground = ground * Color(grain, grain, grain, 1.0)
			# Darken the rim like a distant ridge line, so the field's edge
			# recedes instead of cutting a hard bright seam at the horizon.
			var rim := clampf(inverse_lerp(RIM_FADE_START, (VERTS - 1) / 2.0 * CELL, Vector2(x, z).length()), 0.0, 1.0)
			col.append(ground.lerp(COLOR_FAR, rim * rim))

	# Godot front faces wind clockwise seen from outside (above, for ground).
	for i in range(VERTS - 1):
		for j in range(VERTS - 1):
			var v00 := i * VERTS + j
			var v01 := i * VERTS + j + 1
			var v10 := (i + 1) * VERTS + j
			var v11 := (i + 1) * VERTS + j + 1
			for k in [v00, v01, v11, v00, v11, v10]:
				st.set_color(col[k])
				st.set_normal(nrm[k])
				st.add_vertex(pos[k])

	st.index()
	var mesh := st.commit()
	var err := ResourceSaver.save(mesh, "res://samples/car_terrain.res")
	print("car_terrain.res: %d verts, %d tris -> %s" % [
		VERTS * VERTS, 2 * (VERTS - 1) * (VERTS - 1), error_string(err)])
	quit(0 if err == OK else 1)
