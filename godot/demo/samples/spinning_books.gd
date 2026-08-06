extends Node3D

## Spinning Books -- a port of upstream's "Bodies / Spinning Book" sample
## (samples/sample_bodies.cpp). Three identical book-shaped slabs float in
## free fall (gravity_scale 0) and are spun about each of their three
## principal axes at 5 rad/s, with a 0.01 rad/s wobble on the other two so
## none of them starts perfectly balanced.
##
## The slab is 0.7 x 0.16 x 1.0, so its moments of inertia go Z (smallest),
## X, Y (largest). The green (Y) and blue (Z) books spin about the extremes
## and hold their axis. The red one spins about the INTERMEDIATE axis, which
## is unstable: the tiny wobble grows until the book tumbles, settles, and
## tumbles again -- measured here it bursts roughly every two seconds and
## never stops. That is the tennis racket theorem (the Dzhanibekov effect),
## and it falls out of the free-body rotation Box3D integrates -- nothing
## here applies a torque.
##
## The books carry angular_damping 0, which is upstream's b3BodyDef default
## but NOT the GDExtension's (0.05): left at the node default the spin bleeds
## away to a third of its speed inside half a minute and the effect with it.
##
## The T-handle in "Gyroscopic Torque" is the same instability in one body;
## this one shows all three axes side by side for comparison.

## Angular speed about the chosen axis, and the wobble on the other two.
const SPIN := 5.0
const WOBBLE := 0.01


var camera_home := Vector3(0.0, 6.0, 8.66)
var camera_look_at := Vector3(0.0, 1.5, 0.0)


func _ready() -> void:
	var books := $Box3DWorld/Books
	(books.get_node("BookX") as Box3DBody).set_angular_velocity(
			Vector3(SPIN, WOBBLE, WOBBLE))
	(books.get_node("BookY") as Box3DBody).set_angular_velocity(
			Vector3(WOBBLE, SPIN, WOBBLE))
	(books.get_node("BookZ") as Box3DBody).set_angular_velocity(
			Vector3(WOBBLE, WOBBLE, -SPIN))
