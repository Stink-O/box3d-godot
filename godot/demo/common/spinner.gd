class_name ShellSpinner
extends Control

## The shell's one busy indicator: the supplied `spinner.svg` arc, turning.
##
## WHY IT IS A CONTROL THAT DRAWS AND NOT AN AnimatedTexture / AnimationPlayer.
## The artwork is an SVG whose animation is SMIL, and Godot's SVG import is
## ThorVG rasterising ONE static frame -- no SMIL, no `<animateTransform>`. So
## the file gives the look (a white radial-gradient arc over its own faint
## track) and this gives the motion, which is a rotation and nothing else.
##
## It rotates in `_draw` through `draw_set_transform` rather than by setting the
## Control's own `rotation`. A rotated Control still reports its unrotated rect
## to its container, so either would lay out the same, but a transform confined
## to the draw call cannot leak into anchors, focus rects or the mouse
## rectangle, and this thing lives inside HBoxContainers the shell has already
## tuned to the pixel.
##
## DIRECTION, matching the source: the original sweeps `360 -> 0`, which is
## counterclockwise in SVG's y-down space, and Godot's 2D space is y-down too,
## so counterclockwise is a DECREASING angle here as well. One revolution every
## `SPIN_SECONDS`, linear, exactly as the SMIL says.
##
## It is WHITE on purpose. Hosts tint it with `modulate` where the shell's
## accent reads better than white -- the timeline's indexing readout does
## exactly that, so the spinner and the percentage beside it are the same
## colour.
##
## It costs nothing when it is not showing: `_process` is switched off whenever
## the control is not visible in the tree, so a hidden spinner is not redrawing
## and not accumulating an angle.

const TEXTURE_PATH := "res://common/spinner.svg"

## One revolution every two seconds, from the source animation's `dur="2s"`.
const SPIN_SECONDS := 2.0

## The size it asks its container for when nobody says otherwise. Small enough
## to sit on a 12 px status line without pushing it around.
const DEFAULT_SIZE := 20.0

## Interned once for the whole shell: several spinners exist at once (the
## sidebar's, the top bar's, the timeline's) and they are one image.
static var _texture: Texture2D = null

## Current rotation, radians, counterclockwise. Public because it is the only
## thing a headless selftest can observe about a spinning image.
var angle := 0.0


func _init() -> void:
	# It reports nothing and takes nothing: a busy indicator that could swallow
	# a click on the control behind it would be a bug of its own.
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE
	custom_minimum_size = Vector2(DEFAULT_SIZE, DEFAULT_SIZE)


func _ready() -> void:
	visibility_changed.connect(_sync_processing)
	_sync_processing()


func _sync_processing() -> void:
	set_process(is_visible_in_tree())
	if is_visible_in_tree():
		queue_redraw()


func _process(delta: float) -> void:
	angle = fposmod(angle - TAU * delta / SPIN_SECONDS, TAU)
	queue_redraw()


func _draw() -> void:
	var tex := texture()
	if tex == null:
		return
	# Square and centred, so a container that stretches the control in one axis
	# spins a circle rather than an ellipse.
	var side := minf(size.x, size.y)
	if side <= 0.0:
		side = DEFAULT_SIZE
	var extent := Vector2(side, side)
	draw_set_transform(size * 0.5, angle, Vector2.ONE)
	draw_texture_rect(tex, Rect2(-extent * 0.5, extent), false)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


## The artwork, or null where it could not be loaded -- in which case the
## control simply draws nothing and the text beside it still says what is going
## on. A busy indicator must never be the reason a screen fails.
static func texture() -> Texture2D:
	if _texture == null and ResourceLoader.exists(TEXTURE_PATH):
		_texture = load(TEXTURE_PATH) as Texture2D
	return _texture


## Build one sized for a text line, already tinted. The shell's three call sites
## differ only in these two arguments, so they share this rather than repeating
## the same four property writes.
static func make(p_size: float, p_tint := Color.WHITE) -> ShellSpinner:
	var s := ShellSpinner.new()
	s.custom_minimum_size = Vector2(p_size, p_size)
	s.modulate = p_tint
	s.visible = false
	return s
