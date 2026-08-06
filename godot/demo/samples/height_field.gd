extends Node3D

## Height Field -- a port of upstream's "Mesh / Height Field" sample
## (samples/sample_mesh.cpp). A height field is not a triangle mesh: box3d
## stores one quantized height per grid point and walks the grid analytically,
## so a 100 x 100 terrain costs a fraction of the memory of the equivalent
## mesh and a ray or shape cast across it visits only the cells it crosses.
##
## Upstream builds the field with `b3CreateWave(rows, cols, scale, 0.1,
## 0.03333, holes)` and drops the body by half its span so the terrain is
## centred: the same call is what `height_field_wave` asks for on the node
## (the frequencies are given x-first there). Scale is upstream's
## (2, 2 * amplitude, 2) with amplitude 0.75. The grid line count is a slider
## upstream (1..500, 400 in release / 10 in debug builds); 100 is picked here
## so the browser build stays comfortable.
##
## The moving probe is upstream's Step(): a 0.2 m sphere swept 8 m straight
## down, drawn where it lands with its surface normal. Upstream drags the
## origin with "ray x" / "ray z" sliders; this port walks it in a slow circle
## so the cast is always tracking new ground.

## Grid LINE counts, upstream's m_columnCount / m_rowCount.
const COUNT_X := 100
const COUNT_Z := 100
const AMPLITUDE := 0.75
const SCALE := Vector3(2.0, 2.0 * AMPLITUDE, 2.0)
## b3CreateWave's columnFrequency (along x) and rowFrequency (along z).
const WAVE := Vector2(0.03333, 0.1)

const PROBE_RADIUS := 0.2
const PROBE_START := Vector3(5.5, 4.0, 1.01)
const PROBE_TRAVEL := Vector3(0.0, -8.0, 0.0)
## Radius and rate of the circle the probe origin is walked around.
const PROBE_ORBIT := 6.0
const PROBE_RATE := 0.35

var camera_home := Vector3(24.5, 20.0, 24.5)
var camera_look_at := Vector3(0.0, 0.0, 0.0)

var _world: Box3DWorld
var _terrain: Box3DBody
var _probe: MeshInstance3D
var _lines: ImmediateMesh
var _t := 0.0


func _ready() -> void:
	_world = $Box3DWorld
	# The field itself is authored on the node in the scene, so the shape is
	# built once, when the body is created. b3CreateHeightFieldShape has no
	# local transform -- the grid grows from the body origin along +x / +z --
	# so the body carries upstream's centring offset of half the span.
	_terrain = $Box3DWorld/Terrain

	var visual := MeshInstance3D.new()
	visual.name = "TerrainMesh"
	visual.mesh = _build_surface()
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.35, 0.45, 0.38)
	material.roughness = 0.75
	visual.material_override = material
	_terrain.add_child(visual)

	_probe = MeshInstance3D.new()
	_probe.name = "Probe"
	var sphere := SphereMesh.new()
	sphere.radius = PROBE_RADIUS
	sphere.height = 2.0 * PROBE_RADIUS
	_probe.mesh = sphere
	var probe_mat := StandardMaterial3D.new()
	probe_mat.albedo_color = Color(0.95, 0.55, 0.15)
	probe_mat.emission_enabled = true
	probe_mat.emission = Color(0.95, 0.55, 0.15)
	probe_mat.emission_energy_multiplier = 1.2
	_probe.material_override = probe_mat
	add_child(_probe)

	_lines = ImmediateMesh.new()
	var line_node := MeshInstance3D.new()
	line_node.name = "ProbeLines"
	line_node.mesh = _lines
	var line_mat := StandardMaterial3D.new()
	line_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	line_mat.albedo_color = Color(0.85, 0.95, 0.3)
	line_node.material_override = line_mat
	add_child(line_node)


func _process(delta: float) -> void:
	_t += delta
	var origin := PROBE_START + Vector3(
			PROBE_ORBIT * cos(PROBE_RATE * _t), 0.0, PROBE_ORBIT * sin(PROBE_RATE * _t))
	var target := origin + PROBE_TRAVEL
	var hit: Dictionary = _world.shape_cast_sphere(origin, target, PROBE_RADIUS)

	_lines.clear_surfaces()
	_lines.surface_begin(Mesh.PRIMITIVE_LINES)
	_lines.surface_add_vertex(origin)
	_lines.surface_add_vertex(target)
	if hit.get("hit", false):
		var point: Vector3 = hit["position"]
		var normal: Vector3 = hit["normal"]
		_probe.position = origin.lerp(target, hit["fraction"])
		_probe.visible = true
		_lines.surface_add_vertex(point)
		_lines.surface_add_vertex(point + 0.5 * normal)
	else:
		_probe.visible = false
	_lines.surface_end()


## The same wave box3d generates, as a Godot surface: height(i, j) is
## sin(2 * PI * rowFrequency * i) * sin(2 * PI * columnFrequency * j) and the
## grid point sits at scale * (j, height, i) (src/height_field.c:1384-1444).
##
## The triangles are wound box3d's way -- counter-clockwise by the right-hand
## rule, so the face normal points at the collidable side -- and handed to
## Box3DGeometry.make_array_mesh, which is the one place that knows how to turn
## that into a Godot surface (Godot's front face is the other order).
func _build_surface() -> ArrayMesh:
	var verts := PackedVector3Array()
	verts.resize(COUNT_X * COUNT_Z)
	for i in COUNT_Z:
		var row := sin(TAU * WAVE.y * i)
		for j in COUNT_X:
			var h := row * sin(TAU * WAVE.x * j)
			verts[i * COUNT_X + j] = Vector3(j * SCALE.x, h * SCALE.y, i * SCALE.z)

	var indices := PackedInt32Array()
	for i in COUNT_Z - 1:
		for j in COUNT_X - 1:
			var i11 := i * COUNT_X + j
			var i12 := i11 + 1
			var i21 := i11 + COUNT_X
			var i22 := i21 + 1
			indices.append_array([i11, i21, i12, i12, i21, i22])

	return Box3DGeometry.make_array_mesh({"vertices": verts, "indices": indices})
