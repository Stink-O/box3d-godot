extends Node3D

## Huge Pyramid: upstream's Large Pyramid benchmark scaled to a 180-box base —
## 16,290 one-metre boxes in a single planar pyramid. A stack this tall only
## stands because of Box3D's contact recycling (matching contacts are reused
## between steps while a pair barely moves, keeping warm-start impulses
## intact); the Settings sidebar's "Contact Recycling" checkbox disables it
## on every body so you can watch the difference. Blocks are generated in code (a baked scene
## would be megabytes) and rendered by Box3DMultiMeshRenderer — the C++ bulk
## path (one interpolated buffer upload per frame), since a 16k-iteration
## GDScript sync loop would cost more per frame than the solver itself.
## Layout, box size and density follow upstream shared/benchmarks.c.

const BASE_COUNT := 180  # rows; total boxes = 180 * 181 / 2 = 16290

## Upstream's benchmark uses density 100, but at 100 even the blast slider's
## max cannot excavate the wall. 10 keeps the blocks properly heavy (10x a
## demo cube; the stack still stands and still collapses without recycling)
## while max blast craters it.
const BLOCK_DENSITY := 10.0

const Cube = preload("res://common/cube.gd")

var _blocks: Box3DMultiMeshRenderer


static func _block_positions() -> PackedVector3Array:
	var half := 0.5
	var out := PackedVector3Array()
	for i in BASE_COUNT:
		var y := (2.0 * i + 1.0) * half
		for j in range(i, BASE_COUNT):
			out.append(Vector3(
				(i + 1.0) * half + 2.0 * (j - i) * half - half * BASE_COUNT, y, 0.0))
	return out


func _ready() -> void:
	var world: Node = get_node("Box3DWorld")
	# Build the whole subtree detached, then add it once: the grid renderer's
	# _ready collects the bodies under it, so they must exist before it enters
	# the tree.
	_blocks = Box3DMultiMeshRenderer.new()
	_blocks.name = "Blocks"
	for pos in _block_positions():
		var b := Box3DBody.new()
		b.density = BLOCK_DENSITY
		b.position = pos
		_blocks.add_child(b)
	world.add_child(_blocks)


## The blocks above are generated in _ready, which never runs on the
## unparented instance RigExtract walks — so the native rebuild used to get an
## empty scene. This hands it the same layout instead, colored from the cube
## palette to match the look the MultiMesh renderer gives the Box3D side.
func rig_bodies() -> Array:
	var out: Array = []
	for pos in _block_positions():
		out.append({
			"position": pos,
			"density": BLOCK_DENSITY,
			"material": Cube.pick_material(),
		})
	return out
