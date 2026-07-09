extends SceneTree

## One-off generator for samples/car_terrain.res: the Car sample's rolling
## ground, a triangle-mesh port of the wave height field box3d's own Driving
## sample builds with b3CreateWave(50, 50, {4, 2, 4}, 0.02, 0.04) — heights are
## sin(2*PI*0.02*row) * sin(2*PI*0.04*column), so the car crests long gentle
## swells. The phase is centred so the spawn point sits on a flat saddle.
##
## Run from this project:
##   godot --headless --path . -s tools/gen_car_terrain.gd
##
## The committed car_terrain.res is the source of truth; car.tscn shows it in
## a MeshInstance3D under a shape_type = Mesh static body (the collider is
## built from the same mesh).

const VERTS := 49 # vertices per side -> 48x48 cells
const CELL := 3.0 # metres per cell -> a 144 m square
const AMPLITUDE := 2.0
const ROW_FREQ := 0.02 # cycles per row index, as upstream
const COLUMN_FREQ := 0.04

func _init() -> void:
	var c := (VERTS - 1) / 2.0 # integer for odd VERTS: sin(0) = 0 at the origin
	var omega_z := TAU * ROW_FREQ
	var omega_x := TAU * COLUMN_FREQ

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	# Vertex grid: i walks z, j walks x (matching upstream's rows/columns).
	var pos: Array = []
	var nrm: Array = []
	for i in range(VERTS):
		for j in range(VERTS):
			var x := (j - c) * CELL
			var z := (i - c) * CELL
			var y := AMPLITUDE * sin(omega_z * (i - c)) * sin(omega_x * (j - c))
			pos.append(Vector3(x, y, z))
			# Analytic surface normal from the height gradient.
			var dydx := AMPLITUDE * (omega_x / CELL) * sin(omega_z * (i - c)) * cos(omega_x * (j - c))
			var dydz := AMPLITUDE * (omega_z / CELL) * cos(omega_z * (i - c)) * sin(omega_x * (j - c))
			nrm.append(Vector3(-dydx, 1.0, -dydz).normalized())

	# Godot front faces wind clockwise seen from outside (above, for ground).
	for i in range(VERTS - 1):
		for j in range(VERTS - 1):
			var v00 := i * VERTS + j
			var v01 := i * VERTS + j + 1
			var v10 := (i + 1) * VERTS + j
			var v11 := (i + 1) * VERTS + j + 1
			for k in [v00, v01, v11, v00, v11, v10]:
				st.set_normal(nrm[k])
				st.add_vertex(pos[k])

	st.index()
	var mesh := st.commit()
	var err := ResourceSaver.save(mesh, "res://samples/car_terrain.res")
	print("car_terrain.res: %d verts, %d tris -> %s" % [
		VERTS * VERTS, 2 * (VERTS - 1) * (VERTS - 1), error_string(err)])
	quit(0 if err == OK else 1)
