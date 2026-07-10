extends SceneTree

## One-off generator for samples/car_wheel.res: the Car's wheel — the same
## r = 0.4 sphere the collider uses, with a crisp CHECKERBOARD baked into
## vertex colors so you can see it spin and steer.
##
## Two details matter for a wheel that reads as spinning TRUE:
##   - the sphere's pole axis lies along +Z (the axle), so the tessellated
##     silhouette is rotationally symmetric about the spin axis and doesn't
##     pulse as it turns (poles-up made the wheel look like a tumbling egg);
##   - the checker comes from integer grid indices (blocks of whole quads),
##     never from UV rounding, so cells are exact rectangles with no ragged
##     chevron edges.
##
## Run from this project:
##   godot --headless --path . -s tools/gen_car_wheel.gd

const RADIUS := 0.4
const SEGMENTS := 24 # around the axle
const RINGS := 12    # pole to pole
# The moving pattern lives ONLY on the equatorial tread band: the equator is
# a great circle, so its projection is always centred on the ball from any
# viewing angle -- a pole-centred pattern reads as off-centre rotation from
# oblique views even when the axle is mathematically perfect. 4 tread blocks,
# not more: at full throttle the wheel turns ~29 deg per 60 Hz physics frame,
# so any pattern repeating faster than every ~58 deg strobes backwards like
# a wagon wheel (a 90 deg period can't alias).
const SEG_STEP := 6    # quads per tread block -> 4 blocks around
const TREAD_RINGS := 3 # rings each side of the equator that carry the tread
const HUB_RINGS := 2   # solid hubcap rings at each pole
const RUBBER := Color(0.07, 0.07, 0.08)
const TREAD := Color(0.78, 0.75, 0.68)
const HUB := Color(0.55, 0.53, 0.5)

func _init() -> void:
	# Lat-long grid with poles on +/-Z: theta from the +Z pole, phi around it.
	var pts: Array = []
	for i in range(RINGS + 1):
		var theta := PI * i / RINGS
		var row: Array = []
		for j in range(SEGMENTS + 1):
			var phi := TAU * j / SEGMENTS
			row.append(RADIUS * Vector3(sin(theta) * cos(phi), sin(theta) * sin(phi), cos(theta)))
		pts.append(row)

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(RINGS):
		for j in range(SEGMENTS):
			var color := RUBBER
			if i < HUB_RINGS or i >= RINGS - HUB_RINGS:
				color = HUB
			elif absi(2 * i + 1 - RINGS) < 2 * TREAD_RINGS and (j / SEG_STEP) % 2 == 0:
				color = TREAD
			var v00: Vector3 = pts[i][j]
			var v01: Vector3 = pts[i][j + 1]
			var v10: Vector3 = pts[i + 1][j]
			var v11: Vector3 = pts[i + 1][j + 1]
			for tri in [[v00, v01, v11], [v00, v11, v10]]:
				var a: Vector3 = tri[0]
				var b: Vector3 = tri[1]
				var c: Vector3 = tri[2]
				var cross := (b - a).cross(c - a)
				if cross.length_squared() < 1e-10:
					continue # degenerate pole sliver
				if cross.dot(a + b + c) > 0.0:
					# Godot front faces wind clockwise seen from outside, i.e.
					# the winding cross-product points inward; flip if not.
					var tmp := b
					b = c
					c = tmp
				for p in [a, b, c]:
					st.set_color(color)
					st.set_normal(p.normalized())
					st.add_vertex(p)

	var mesh := st.commit()
	var err := ResourceSaver.save(mesh, "res://samples/car_wheel.res")
	print("car_wheel.res: %d segs x %d rings, poles on the axle -> %s" % [
		SEGMENTS, RINGS, error_string(err)])
	quit(0 if err == OK else 1)
