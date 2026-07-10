extends SceneTree

## One-off generator for samples/car_wheel.res: the Car's wheel — the same
## r = 0.4 sphere the collider uses, but with a per-face CHECKERBOARD baked
## into vertex colors so you can actually see the wheel spinning (and the
## front pair steering). Built from SphereMesh's own arrays (winding and
## normals preserved), each triangle flat-colored by its UV cell; the wheel
## material has vertex_color_use_as_albedo on.
##
## Run from this project:
##   godot --headless --path . -s tools/gen_car_wheel.gd

const RADIUS := 0.4
const CHECKS_AROUND := 8 # checker cells around the equator
const CHECKS_DOWN := 4   # checker cells pole to pole
const DARK := Color(0.08, 0.08, 0.09)
const LIGHT := Color(0.78, 0.75, 0.68)

func _init() -> void:
	var sphere := SphereMesh.new()
	sphere.radius = RADIUS
	sphere.height = RADIUS * 2.0
	sphere.radial_segments = 16
	sphere.rings = 8

	var arrays := sphere.get_mesh_arrays()
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var index: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for t in range(0, index.size(), 3):
		# Flat checker per triangle, from the cell its UV centroid lands in.
		var uv := (uvs[index[t]] + uvs[index[t + 1]] + uvs[index[t + 2]]) / 3.0
		var cell := int(floor(uv.x * CHECKS_AROUND)) + int(floor(uv.y * CHECKS_DOWN))
		var color := DARK if cell % 2 == 0 else LIGHT
		for k in range(3):
			var i := index[t + k]
			st.set_color(color)
			st.set_normal(normals[i])
			st.add_vertex(verts[i])

	var mesh := st.commit()
	var err := ResourceSaver.save(mesh, "res://samples/car_wheel.res")
	print("car_wheel.res: %d tris -> %s" % [index.size() / 3, error_string(err)])
	quit(0 if err == OK else 1)
