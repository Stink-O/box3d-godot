extends Node3D

## Weeble -- a port of upstream's "Bodies / Weeble" sample
## (samples/sample_bodies.cpp). A plain capsule that cannot be knocked over,
## because its CENTRE OF MASS has been moved 1.5 m below its geometric
## centre: gravity then pulls the heavy end down and rights it, exactly like
## the toy. The shape is untouched -- only the mass data changes.
##
## Moving the centre of mass means the inertia tensor has to move with it,
## which is the parallel axis (Steiner) theorem: I about the new origin is
## I about the centre of mass plus m * (|d|^2 * Identity - d (x) d). Upstream
## calls b3Steiner for that; _steiner below is the same formula, and the
## result goes back through set_mass_data with the offset as the new centre.
##
## Press the top-bar Activate button to tip it over (upstream's "Teleport":
## drop it from 5 m rotated 0.95 * PI, i.e. very nearly upside down) and
## watch it stand itself back up. The bomb tool works on it too.

## How far below the body origin the centre of mass is moved.
const COM_OFFSET := Vector3(0.0, -1.5, 0.0)
const TELEPORT_HEIGHT := 5.0
const TELEPORT_ANGLE := 0.95 * PI

var camera_home := Vector3(16.0, 10.6, 16.0)
var camera_look_at := Vector3(0.0, 1.0, 0.0)

var _weeble: Box3DBody


func _ready() -> void:
	_weeble = $Box3DWorld/Weeble
	var data: Dictionary = _weeble.get_mass_data()
	var mass: float = data["mass"]
	var inertia: Basis = data["inertia"]
	_weeble.set_mass_data(mass, COM_OFFSET, _add(inertia, _steiner(mass, COM_OFFSET)))


## The shell's reusable Activate button: upstream's "Teleport" control.
func activate() -> void:
	_weeble.teleport(Transform3D(
			Basis(Vector3(0.0, 0.0, 1.0), TELEPORT_ANGLE),
			Vector3(0.0, TELEPORT_HEIGHT, 0.0)))
	_weeble.set_awake(true)


## Inertia of a point mass `mass` at `origin` about the origin -- the term the
## parallel axis theorem adds when the reference point moves. Mirrors
## b3Steiner (src/math_functions.c).
static func _steiner(mass: float, origin: Vector3) -> Basis:
	var ixx := mass * (origin.y * origin.y + origin.z * origin.z)
	var iyy := mass * (origin.x * origin.x + origin.z * origin.z)
	var izz := mass * (origin.x * origin.x + origin.y * origin.y)
	var ixy := -mass * origin.x * origin.y
	var ixz := -mass * origin.x * origin.z
	var iyz := -mass * origin.y * origin.z
	return Basis(
			Vector3(ixx, ixy, ixz),
			Vector3(ixy, iyy, iyz),
			Vector3(ixz, iyz, izz))


static func _add(a: Basis, b: Basis) -> Basis:
	return Basis(a.x + b.x, a.y + b.y, a.z + b.z)
