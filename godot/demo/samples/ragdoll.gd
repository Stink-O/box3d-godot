extends Node3D

## Ragdoll: a wooden-mannequin humanoid in the style of box3d's own human
## prefab -- every bone is a capsule (a four-segment torso stack, an egg head,
## capsule limbs) linked by ball joints (spine, neck, shoulders, hips) and
## hinge joints (elbows, knees) with upstream human.c's own limit ranges:
## knees only fold backward (45 deg), elbows only forward (60 deg). Every
## joint carries a soft spring toward the spawn pose plus a little dry
## friction (upstream's ragdoll-sample tuning: hertz 1, damping 0.7), so the
## figure stands like a posed mannequin instead of collapsing on load. Grab a
## limb, shoot it, or bomb it and it crumples believably -- non-adjacent bones
## collide with each other, so it can't fold through itself -- then slowly
## sags back toward its pose. Use Reset to stand it up again.

## Frame the opening view: a 3/4 front view of the standing figure.
var camera_home := Vector3(1.7, 1.5, 2.8)
var camera_look_at := Vector3(0.0, 0.95, 0.0)
