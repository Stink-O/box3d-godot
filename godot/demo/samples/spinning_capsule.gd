extends Node3D

## Spinning Capsule -- a port of upstream's "Bodies / Spinning Capsule" sample
## (samples/sample_bodies.cpp:586-685). A long, thin capsule stands tilted on
## its lower cap and spins at 20 rad/s about its own axis. Upstream's comment
## (:586) is the point: gyroscopic torque is necessary for plausible
## behaviour on long skinny objects.
##
## A top is held up by its spin only when the spin is about its LARGEST
## inertia axis or is very fast. A slender capsule spins about its smallest
## one, and 20 rad/s is orders of magnitude short of what would hold it, so
## the real thing simply falls over, still spinning. That is what Box3D does
## with gyroscopic torque on (the capsule is down within about two seconds).
## Raise Tolerance above the capsule's anisotropy and Box3D treats it as a
## sphere and skips that torque: the capsule then stays balanced at its tilt
## like an impossibly stable top, which is the implausible behaviour the
## sample warns about. Shorten it toward a sphere and the measure drops to
## 0, where skipping the torque is harmless.
##
## The world decides per body: a body whose relative anisotropy (the
## Frobenius norm of the deviatoric inertia over its mean) is at most
## Box3DWorld.isotropic_inertia_tolerance skips the gyroscopic solve
## (src/body.c:895-920). The first readout prints that same measure, computed
## here from get_mass_data()["inertia"] the way upstream computes it from
## b3Body_GetLocalRotationalInertia (:654-662).
##
## Upstream's numbers are kept: radius 0.2, Length (the segment between the
## cap centres) slider 0..8 default 4, Tolerance slider 0..1 defaulting to
## the world's own (0.2), the capsule tilted 15 degrees about Z standing on
## its lower cap, angular velocity 20 rad/s along its axis, density 1000
## (b3DefaultShapeDef) and angular damping 0 (b3DefaultBodyDef; the node
## default is 0.05), on AddGroundBox(20) under gravity -10 (:603-628).
## Length and Tolerance are sidebar dials, and any change rebuilds the
## capsule as upstream's DrawControls does (:640-643); Activate is
## upstream's Reset button. The tolerance only applies to bodies created
## after it is set (:605), which is why a change rebuilds the capsule.
## Upstream rebuilds the whole world there; the ground is static and
## identical either way, so this port rebuilds only the capsule.
##
## The yellow line is upstream's omega line, 0.2 s of angular velocity drawn
## from the centre of mass (:669), and the second readout is the tilt from
## vertical and the spin about the capsule's axis (:671-672).

const RADIUS := 0.2
const LENGTH_RANGE := Vector2(0.0, 8.0)
const TOLERANCE_RANGE := Vector2(0.0, 1.0)
const TILT_DEG := 15.0
const SPIN := 20.0
const DENSITY := 1000.0
const ANGULAR_DAMPING := 0.0
const OMEGA_SCALE := 0.2

## m_camera->SetView(30, 25, 15, {0, 1, 0}) (:595): eye = pivot + radius *
## (sin yaw cos pitch, sin pitch, cos yaw cos pitch)
## (samples/host/camera.cpp:35-39,216-220).
var camera_home := Vector3(0.0, 1.0, 0.0) + 15.0 * Vector3(
		sin(deg_to_rad(30.0)) * cos(deg_to_rad(25.0)),
		sin(deg_to_rad(25.0)),
		cos(deg_to_rad(30.0)) * cos(deg_to_rad(25.0)))
var camera_look_at := Vector3(0.0, 1.0, 0.0)

var _length := 4.0
## Upstream reads its initial tolerance off the world (:599); a dial value
## restored by Reset (set before _ready) takes precedence.
var _tolerance := -1.0
var _capsule: Box3DBody
var _material := StandardMaterial3D.new()
var _lines: ImmediateMesh
@onready var _world: Box3DWorld = $Box3DWorld
@onready var _label: Label3D = $Status


func _ready() -> void:
	# After the world's step, so the readouts describe the step just taken.
	process_physics_priority = 1
	if _tolerance < 0.0:
		_tolerance = _world.isotropic_inertia_tolerance
	_material.albedo_color = Color(0.85, 0.55, 0.3)
	_material.roughness = 0.45

	_lines = ImmediateMesh.new()
	var overlay := MeshInstance3D.new()
	overlay.name = "OmegaLine"
	overlay.mesh = _lines
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 1.0, 0.0)  # b3_colorYellow
	mat.no_depth_test = true
	overlay.material_override = mat
	add_child(overlay)

	_create_scene()


## Upstream's Reset button.
func activate() -> void:
	_create_scene()


## Upstream's CreateScene (:603-628): set the tolerance first, then build the
## capsule, so the new body is classified under the new tolerance.
func _create_scene() -> void:
	if not is_inside_tree():
		return
	_world.isotropic_inertia_tolerance = _tolerance
	if _capsule != null:
		_capsule.free()
	var half_length := 0.5 * _length
	var rotation := Basis(Vector3(0.0, 0.0, 1.0), deg_to_rad(TILT_DEG))
	var axis := rotation * Vector3.UP

	_capsule = Box3DBody.new()
	_capsule.name = "Capsule"
	_capsule.shape_type = Box3DBody.CAPSULE
	_capsule.capsule_radius = RADIUS
	_capsule.capsule_height = _length + 2.0 * RADIUS
	_capsule.density = DENSITY
	_capsule.angular_damping = ANGULAR_DAMPING
	# Stand on the lower cap, tilted about it (:616-624).
	_capsule.transform = Transform3D(rotation, Vector3(0.0, RADIUS, 0.0) + half_length * axis)
	var mesh := CapsuleMesh.new()
	mesh.radius = RADIUS
	mesh.height = _length + 2.0 * RADIUS
	var visual := MeshInstance3D.new()
	visual.mesh = mesh
	visual.material_override = _material
	_capsule.add_child(visual)
	_world.add_child(_capsule)
	_capsule.set_angular_velocity(SPIN * axis)
	_refresh()


## Upstream's measure (:654-662), the same one the world uses to decide
## whether a body gets the gyroscopic solve (src/body.c:895-920).
static func anisotropy_of(inertia: Basis) -> float:
	var mean := (inertia.x.x + inertia.y.y + inertia.z.z) / 3.0
	var dx := inertia.x.x - mean
	var dy := inertia.y.y - mean
	var dz := inertia.z.z - mean
	var off_diagonal := inertia.y.x * inertia.y.x + inertia.z.x * inertia.z.x + inertia.z.y * inertia.z.y
	var deviation := dx * dx + dy * dy + dz * dz + 2.0 * off_diagonal
	return sqrt(2.0 * deviation / 3.0) / mean if mean > 0.0 else 0.0


func _physics_process(_delta: float) -> void:
	_refresh()


func _refresh() -> void:
	if _capsule == null:
		return
	var anisotropy := anisotropy_of(_capsule.get_mass_data()["inertia"])
	var gyroscopic := anisotropy > _tolerance
	var center := _capsule.get_center_of_mass()
	var axis := _capsule.global_transform.basis.orthonormalized() * Vector3.UP
	var omega := _capsule.get_angular_velocity()
	var tilt := acos(clampf(absf(axis.y), 0.0, 1.0))

	_lines.clear_surfaces()
	_lines.surface_begin(Mesh.PRIMITIVE_LINES)
	_lines.surface_add_vertex(center)
	_lines.surface_add_vertex(center + OMEGA_SCALE * omega)
	_lines.surface_end()

	_label.text = "anisotropy %.2f, gyroscopic torque %s\ntilt %.0f deg, spin %.1f rad/s" % [
		anisotropy, "on" if gyroscopic else "off", rad_to_deg(tilt), omega.dot(axis)]


# --- Sidebar dials: upstream's Length and Tolerance sliders ----------------

func sample_size_dials() -> Array:
	return [
		{
			"key": "length", "label": "Length", "value": _length,
			"min": LENGTH_RANGE.x, "max": LENGTH_RANGE.y, "step": 0.1,
			"tooltip": "Distance between the capsule's two cap centres. 0 is a sphere.",
		},
		{
			"key": "tolerance", "label": "Tolerance", "value": _tolerance,
			"min": TOLERANCE_RANGE.x, "max": TOLERANCE_RANGE.y, "step": 0.001,
			"tooltip": "Box3DWorld.isotropic_inertia_tolerance: bodies whose anisotropy is"
					+ " at most this skip the gyroscopic solve.",
		},
	]


func sample_size_hint(key: String, value: float) -> String:
	var length := value if key == "length" else _length
	var tolerance := value if key == "tolerance" else _tolerance
	return "A %.1f m capsule, gyroscopic torque when its anisotropy is above %.3f" % [
		length + 2.0 * RADIUS, tolerance]


func set_sample_size(key: String, value: float) -> void:
	if key == "length":
		_length = clampf(value, LENGTH_RANGE.x, LENGTH_RANGE.y)
	elif key == "tolerance":
		_tolerance = clampf(value, TOLERANCE_RANGE.x, TOLERANCE_RANGE.y)
	_create_scene()


## Measured claim not made: this only states what the engines lack.
func rig_notes() -> Array:
	return ["The capsule is built in code and Godot Physics and Jolt have no "
			+ "isotropic inertia tolerance (nor gyroscopic torque), so only the ground is rebuilt there."]
