class_name ShellTheme
extends RefCounted

## The demo shell's look, built once in code: colour tokens, one Theme for
## every stock control the shell uses, and the panel treatments (card, glass).
##
## WHY IN CODE. The theme carries its own icons (check boxes, switches, radio
## marks, chevrons, slider knobs), rasterised here from distance functions, so
## the look ships with no image files to import and scales with the tokens.
##
## WHERE IT IS APPLIED. A CanvasLayer does not hand a theme down: theme lookup
## climbs Control parents and stops at the layer. main.gd therefore sets
## `theme` on every top-level Control under the UI layer (and on anything added
## there later), on the touch layer's panels and on the touch overlay. Popups
## are Windows parented to the control that opens them and inherit from it.
##
## GLASS. Panels over the scene can be frosted: the panel is drawn in an opaque
## tint and a canvas shader mixes that tint over a blurred, darkened copy of the
## screen behind it, so text stays legible without a heavy slab hiding the
## scene. Desktop Forward+ only (see glass_supported); everywhere else the same
## panels fall back to a plain translucent card of the same shape and colour.

# --- colour tokens -------------------------------------------------------------

const SURFACE := Color(0.14, 0.16, 0.20, 0.86)        ## a panel without glass
const SURFACE_SOLID := Color(0.15, 0.17, 0.21, 0.98)  ## touch panels, the web notice
const SURFACE_RAISED := Color(0.19, 0.21, 0.26, 0.98) ## popups and tooltips: one step up
const BAR := Color(0.14, 0.16, 0.20, 0.76)            ## the top strip without glass
const GLASS_TINT := Color(0.15, 0.17, 0.21)           ## glass: tint over the blurred scene
const GLASS_PANEL := 0.70                             ## glass: tint share on panels
const GLASS_BAR := 0.58                               ## glass: tint share on the top strip
const GLASS_DENSE := 0.86                             ## glass: data-dense panels (profiler)
const WELL := Color(0.0, 0.0, 0.0, 0.26)              ## sunken fields and graph wells
const FILL := Color(1, 1, 1, 0.07)                    ## a button at rest
const FILL_HOVER := Color(1, 1, 1, 0.13)
const FILL_PRESS := Color(1, 1, 1, 0.19)
const LINE := Color(1, 1, 1, 0.10)                    ## section dividers
const LINE_FAINT := Color(1, 1, 1, 0.06)              ## the rim of a text-entry well
const TEXT := Color(0.93, 0.94, 0.96)
const TEXT_MUTED := Color(0.74, 0.77, 0.82)
const TEXT_FAINT := Color(0.58, 0.62, 0.68)
const ACCENT := Color(0.40, 0.76, 1.0)                ## on, selected, focused
const ACCENT_SOFT := Color(0.40, 0.76, 1.0, 0.22)
const ACCENT_TEXT := Color(0.73, 0.87, 1.0)
const INK := Color(0.05, 0.08, 0.13)                  ## dark marks drawn on the accent
const RECORD := Color(1.0, 0.40, 0.40)                ## recording and destructive only
const RECORD_SOFT := Color(1.0, 0.40, 0.40, 0.20)
const CAUTION := Color(1.0, 0.78, 0.32)
const GOOD := Color(0.40, 0.88, 0.62)
const ALERT := Color(1.0, 0.52, 0.45)

# --- shape rules -----------------------------------------------------------------
# No outlines. Things are told apart by surface lightness: the panel tint, a
# lighter raised fill for a button, lighter again on hover, an accent-tinted
# fill when pressed or on. A border survives only where it means something:
# the keyboard focus ring, the faint rim of a text-entry well, and the
# dividers between sidebar sections. Popups and tooltips are lifted by a
# lighter surface and a soft shadow instead.
#
# Radii are small and scale with size (RADIUS, RADIUS_PANEL, RADIUS_TRACK).
# A rounded thing inside a rounded parent uses the parent's radius minus the
# gap between them, and never less than RADIUS. Every box is drawn with
# enough corner_detail for a smooth arc and a 1 px antialiasing edge.

# --- type and spacing ----------------------------------------------------------
# The project lays the UI out on a 1920x1080 canvas that is scaled to the
# window, so these are canvas pixels, one notch above what a native-size UI
# would use.

const FONT_SIZE := 16     ## body text and controls
const FONT_SMALL := 14    ## secondary text, hints
const FONT_TINY := 12     ## uppercase section headers
const FONT_TITLE := 19    ## panel titles
const RADIUS := 3         ## controls: buttons, fields, check marks, tooltips, menu rows
const RADIUS_PANEL := 6   ## panels and cards; a strip touching the screen edges is 0
const RADIUS_TRACK := 2   ## slider tracks and scroll grabbers
const BAR_HEIGHT := 46    ## the top strip; panels start at BAR_HEIGHT + GAP
const GAP := 8

static var _theme: Theme = null
static var _glass: Dictionary = {}  ## tint share -> ShaderMaterial, one per value
static var _bold: FontVariation = null
static var _header: FontVariation = null

## Five taps on a mip of the screen copy: the mip does the heavy averaging and
## the taps hide its texel grid, which on its own reads as blocks. The tint is
## the stylebox colour (drawn opaque); its alpha is kept as coverage so rounded
## corners stay antialiased.
const _GLASS_CODE := """
shader_type canvas_item;
render_mode unshaded;

uniform sampler2D screen_copy : hint_screen_texture, filter_linear_mipmap;
uniform float tint_share = 0.7;
uniform float blur_lod = 3.0;
uniform float spread = 6.0;
uniform float darken = 0.72;

void fragment() {
	vec2 o = SCREEN_PIXEL_SIZE * spread;
	vec3 scene = textureLod(screen_copy, SCREEN_UV, blur_lod).rgb * 0.4;
	scene += textureLod(screen_copy, SCREEN_UV + vec2(o.x, o.y), blur_lod).rgb * 0.15;
	scene += textureLod(screen_copy, SCREEN_UV + vec2(-o.x, o.y), blur_lod).rgb * 0.15;
	scene += textureLod(screen_copy, SCREEN_UV + vec2(o.x, -o.y), blur_lod).rgb * 0.15;
	scene += textureLod(screen_copy, SCREEN_UV + vec2(-o.x, -o.y), blur_lod).rgb * 0.15;
	COLOR.rgb = mix(scene * darken, COLOR.rgb, tint_share);
}
"""


# --- panels --------------------------------------------------------------------

## Frosted glass needs the screen copy's mipmaps and a desktop GPU budget, so it
## is a desktop Forward+ feature. The browser, phones and tablets, and the
## Compatibility renderer get the plain translucent card instead. Decided from
## the platform and the live renderer, never from a project setting.
static func glass_supported() -> bool:
	if OS.has_feature("web") or DisplayServer.is_touchscreen_available():
		return false
	if DisplayServer.get_name() == "headless":
		return false
	return RenderingServer.get_current_rendering_method() == "forward_plus"


## A rounded panel box. `margin` is the content inset on all four sides.
static func card(bg := SURFACE, radius := RADIUS_PANEL, margin := 12.0) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(radius)
	sb.set_content_margin_all(margin)
	_crisp(sb)
	return sb


## Smooth arcs at these small radii, and an antialiased edge no wider than a
## pixel (wider smears the corner).
static func _crisp(sb: StyleBoxFlat) -> void:
	sb.corner_detail = 10
	sb.anti_aliasing = true
	sb.anti_aliasing_size = 1.0


## The radius for something inset `gap` px inside a parent of radius `outer`:
## concentric where that leaves a curve, the control radius where it would not.
static func inner_radius(outer: int, gap: float) -> int:
	return maxi(RADIUS, outer - int(gap))


## Style `panel` as a glass panel when the platform allows it, else as a plain
## card of the same shape. `share` is how much tint covers the blurred scene;
## `bg` is the fallback colour. Works on Panel and PanelContainer alike, and
## returns the box so a caller can trim its rim or margins.
static func glass(panel: Control, share := GLASS_PANEL, bg := SURFACE,
		radius := RADIUS_PANEL, margin := 12.0) -> StyleBoxFlat:
	var sb: StyleBoxFlat
	if glass_supported():
		sb = card(GLASS_TINT, radius, margin)
		panel.material = _glass_material(share)
	else:
		sb = card(bg, radius, margin)
		panel.material = null
	panel.add_theme_stylebox_override("panel", sb)
	return sb


## For controls that draw their own content (the stats overlay, the profiler):
## a glass or card Panel added as a child that paints BEHIND its parent and
## follows its rect. It ignores the mouse, so the host keeps its drag handling.
static func backdrop(host: Control, share := GLASS_PANEL, bg := SURFACE,
		radius := RADIUS_PANEL) -> Panel:
	var p := Panel.new()
	p.name = "Backdrop"
	p.show_behind_parent = true
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.set_anchors_preset(Control.PRESET_FULL_RECT)
	glass(p, share, bg, radius, 0.0)
	host.add_child(p, false, Node.INTERNAL_MODE_FRONT)
	return p


static func _glass_material(share: float) -> ShaderMaterial:
	if not _glass.has(share):
		var sh := Shader.new()
		sh.code = _GLASS_CODE
		var m := ShaderMaterial.new()
		m.shader = sh
		m.set_shader_parameter("tint_share", share)
		_glass[share] = m
	return _glass[share]


# --- fonts ---------------------------------------------------------------------

## Synthetic bold: the engine font emboldened, so no font file is needed.
static func bold() -> FontVariation:
	if _bold == null:
		_bold = FontVariation.new()
		_bold.base_font = ThemeDB.fallback_font
		_bold.variation_embolden = 0.6
	return _bold


## Short uppercase section headers: a lighter embolden, opened up a little.
static func header_font() -> FontVariation:
	if _header == null:
		_header = FontVariation.new()
		_header.base_font = ThemeDB.fallback_font
		_header.variation_embolden = 0.45
		_header.spacing_glyph = 1
	return _header


# --- the theme -----------------------------------------------------------------

## The shared Theme. Built on first use and cached for the session.
static func theme() -> Theme:
	if _theme == null:
		_theme = _build()
	return _theme


static func _box(bg: Color, border := Color(0, 0, 0, 0), radius := RADIUS,
		mh := 10.0, mv := 5.0) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(radius)
	sb.content_margin_left = mh
	sb.content_margin_right = mh
	sb.content_margin_top = mv
	sb.content_margin_bottom = mv
	if border.a > 0.0:
		sb.border_color = border
		sb.set_border_width_all(1)
	_crisp(sb)
	return sb


static func _empty(mh := 0.0, mv := 0.0) -> StyleBoxEmpty:
	var sb := StyleBoxEmpty.new()
	sb.content_margin_left = mh
	sb.content_margin_right = mh
	sb.content_margin_top = mv
	sb.content_margin_bottom = mv
	return sb


static func _hairline(color: Color, vertical: bool, grow := 0.0) -> StyleBoxLine:
	var sb := StyleBoxLine.new()
	sb.color = color
	sb.thickness = 1
	sb.vertical = vertical
	sb.grow_begin = grow
	sb.grow_end = grow
	return sb


## The button family's states. `menu` keeps a menu-opening button from lighting
## up in the accent while its popup is open: it holds the hover look instead.
static func _button_states(t: Theme, type: StringName, menu := false) -> void:
	t.set_stylebox("normal", type, _box(FILL))
	t.set_stylebox("hover", type, _box(FILL_HOVER))
	var on := _box(Color(ACCENT, 0.24))
	var on_hover := _box(Color(ACCENT, 0.32))
	t.set_stylebox("pressed", type, _box(FILL_PRESS) if menu else on)
	t.set_stylebox("hover_pressed", type, _box(FILL_PRESS) if menu else on_hover)
	t.set_stylebox("disabled", type, _box(Color(1, 1, 1, 0.03)))
	t.set_stylebox("focus", type, _focus_ring())
	t.set_color("font_color", type, TEXT)
	t.set_color("font_hover_color", type, Color.WHITE)
	t.set_color("font_focus_color", type, TEXT)
	t.set_color("font_pressed_color", type, TEXT if menu else ACCENT_TEXT)
	t.set_color("font_hover_pressed_color", type, Color.WHITE if menu else ACCENT_TEXT)
	t.set_color("font_disabled_color", type, Color(TEXT, 0.35))
	t.set_color("icon_normal_color", type, TEXT)
	t.set_color("icon_hover_color", type, Color.WHITE)
	t.set_color("icon_pressed_color", type, ACCENT_TEXT)
	t.set_color("icon_disabled_color", type, Color(1, 1, 1, 0.35))
	t.set_constant("h_separation", type, 6)


static func _focus_ring() -> StyleBoxFlat:
	var sb := _box(Color(0, 0, 0, 0), Color(ACCENT, 0.7))
	sb.draw_center = false
	return sb


static func _build() -> Theme:
	var t := Theme.new()
	t.default_font_size = FONT_SIZE

	# Labels and their variations.
	t.set_color("font_color", "Label", TEXT)
	t.set_stylebox("normal", "Label", _empty())
	_variation(t, &"TitleLabel", &"Label", bold(), FONT_TITLE, TEXT)
	_variation(t, &"HeaderLabel", &"Label", header_font(), FONT_TINY, Color(ACCENT_TEXT, 0.8))
	# A little air above a section header, so it binds to the rows under it.
	var head := _empty()
	head.content_margin_top = 6.0
	t.set_stylebox("normal", &"HeaderLabel", head)
	_variation(t, &"MutedLabel", &"Label", null, FONT_SMALL, TEXT_MUTED)
	_variation(t, &"HintLabel", &"Label", null, FONT_SMALL - 1, TEXT_FAINT)
	_variation(t, &"BarHint", &"Label", null, FONT_SMALL + 1, TEXT_MUTED)
	# A status pill (the top bar's recording state).
	_variation(t, &"PillLabel", &"Label", bold(), FONT_SMALL, Color(1.0, 0.72, 0.72))
	t.set_stylebox("normal", &"PillLabel", _box(Color(RECORD, 0.26), Color(0, 0, 0, 0), RADIUS, 10.0, 3.0))
	# A readout floating over the 3D view (the body counter): no box at all,
	# just text kept legible over sky or floor by a dark outline and a soft
	# offset shadow.
	_variation(t, &"CounterLabel", &"Label", bold(), 28, TEXT)
	t.set_color("font_outline_color", &"CounterLabel", Color(0, 0, 0, 0.62))
	t.set_constant("outline_size", &"CounterLabel", 6)
	t.set_color("font_shadow_color", &"CounterLabel", Color(0, 0, 0, 0.42))
	t.set_constant("shadow_offset_x", &"CounterLabel", 2)
	t.set_constant("shadow_offset_y", &"CounterLabel", 3)
	t.set_constant("shadow_outline_size", &"CounterLabel", 8)

	# Buttons.
	_button_states(t, &"Button")
	_button_states(t, &"MenuButton", true)
	_button_states(t, &"OptionButton", true)
	t.set_icon("arrow", &"OptionButton", _chevron(12, false, TEXT_MUTED))
	t.set_constant("arrow_margin", &"OptionButton", 8)
	t.set_constant("modulate_arrow", &"OptionButton", 0)
	# Transparent until hovered: inline helpers (revert, disclosure, close).
	t.add_type(&"FlatButton")
	t.set_type_variation(&"FlatButton", &"Button")
	t.set_stylebox("normal", &"FlatButton", _empty(6.0, 4.0))
	t.set_stylebox("hover", &"FlatButton", _box(FILL_HOVER, Color(0, 0, 0, 0), RADIUS, 6.0, 4.0))
	t.set_stylebox("pressed", &"FlatButton", _box(FILL_PRESS, Color(0, 0, 0, 0), RADIUS, 6.0, 4.0))
	t.set_stylebox("hover_pressed", &"FlatButton", _box(FILL_PRESS, Color(0, 0, 0, 0), RADIUS, 6.0, 4.0))
	t.set_color("font_color", &"FlatButton", TEXT_MUTED)
	t.set_color("font_pressed_color", &"FlatButton", TEXT)
	t.set_color("font_hover_pressed_color", &"FlatButton", Color.WHITE)
	# A split button: the main half and its menu arrow drawn as one unit, the
	# outer corners rounded and the shared edge square.
	for half: StringName in [&"SplitMain", &"SplitArrow"]:
		var base := &"Button" if half == &"SplitMain" else &"MenuButton"
		t.add_type(half)
		t.set_type_variation(half, base)
		for state in ["normal", "hover", "pressed", "hover_pressed", "disabled"]:
			var sb: StyleBoxFlat = (t.get_stylebox(state, base) as StyleBoxFlat).duplicate()
			if half == &"SplitMain":
				sb.corner_radius_top_right = 0
				sb.corner_radius_bottom_right = 0
			else:
				sb.corner_radius_top_left = 0
				sb.corner_radius_bottom_left = 0
				sb.content_margin_left = 6.0
				sb.content_margin_right = 6.0
			t.set_stylebox(state, half, sb)
	# A button that is running something (the bar's Rec while recording): the
	# record red as a soft fill, pale red text.
	t.add_type(&"RunningButton")
	t.set_type_variation(&"RunningButton", &"Button")
	t.set_stylebox("normal", &"RunningButton", _box(Color(RECORD, 0.24)))
	t.set_stylebox("hover", &"RunningButton", _box(Color(RECORD, 0.34)))
	t.set_stylebox("pressed", &"RunningButton", _box(Color(RECORD, 0.40)))
	t.set_stylebox("hover_pressed", &"RunningButton", _box(Color(RECORD, 0.40)))
	for c in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color",
			"icon_normal_color", "icon_hover_color", "icon_pressed_color"]:
		t.set_color(c, &"RunningButton", Color(1.0, 0.80, 0.80))

	# The settings sidebar's tab bar: muted text on nothing at rest, a hover
	# fill, and for the selected tab a stronger surface with a 2 px accent
	# underline. Square along the underline, the control radius on top.
	t.add_type(&"SideTab")
	t.set_type_variation(&"SideTab", &"Button")
	var tab_rest := _empty(8.0, 6.0)
	var tab_hover := _box(FILL, Color(0, 0, 0, 0), RADIUS, 8.0, 6.0)
	var tab_on := _box(Color(1, 1, 1, 0.11), Color(0, 0, 0, 0), RADIUS, 8.0, 6.0)
	for sb: StyleBoxFlat in [tab_hover, tab_on]:
		sb.corner_radius_bottom_left = 0
		sb.corner_radius_bottom_right = 0
	tab_on.border_color = ACCENT
	tab_on.border_width_bottom = 2
	var tab_on_hover: StyleBoxFlat = tab_on.duplicate()
	tab_on_hover.bg_color = Color(1, 1, 1, 0.14)
	t.set_stylebox("normal", &"SideTab", tab_rest)
	t.set_stylebox("hover", &"SideTab", tab_hover)
	t.set_stylebox("pressed", &"SideTab", tab_on)
	t.set_stylebox("hover_pressed", &"SideTab", tab_on_hover)
	t.set_color("font_color", &"SideTab", TEXT_MUTED)
	t.set_color("font_hover_color", &"SideTab", TEXT)
	t.set_color("font_pressed_color", &"SideTab", Color.WHITE)
	t.set_color("font_hover_pressed_color", &"SideTab", Color.WHITE)

	# Big floating buttons over the scene on touch screens: they have no panel
	# under them, so they carry a solid surface of their own.
	t.add_type(&"TouchButton")
	t.set_type_variation(&"TouchButton", &"Button")
	# Big targets (up to 230 x 92), so the panel radius rather than the
	# control one.
	var clear := Color(0, 0, 0, 0)
	t.set_stylebox("normal", &"TouchButton", _box(SURFACE, clear, RADIUS_PANEL, 14.0, 8.0))
	t.set_stylebox("hover", &"TouchButton", _box(SURFACE, clear, RADIUS_PANEL, 14.0, 8.0))
	t.set_stylebox("pressed", &"TouchButton",
			_box(Color(0.22, 0.36, 0.50, 0.94), clear, RADIUS_PANEL, 14.0, 8.0))
	t.set_stylebox("hover_pressed", &"TouchButton",
			_box(Color(0.22, 0.36, 0.50, 0.94), clear, RADIUS_PANEL, 14.0, 8.0))
	t.set_color("font_hover_color", &"TouchButton", TEXT)

	# Check boxes: no box, a drawn mark beside the text.
	for type: StringName in [&"CheckBox", &"CheckButton"]:
		t.set_color("font_color", type, TEXT)
		t.set_color("font_hover_color", type, Color.WHITE)
		t.set_color("font_pressed_color", type, TEXT)
		t.set_color("font_hover_pressed_color", type, Color.WHITE)
		t.set_color("font_focus_color", type, TEXT)
		t.set_color("font_disabled_color", type, Color(TEXT, 0.35))
		t.set_constant("h_separation", type, 8)
		t.set_stylebox("focus", type, _focus_ring())
	# Vertical padding chosen so a check row, a spin-box row and a button row
	# all come out 32 px tall at the body size: one rhythm down the sidebar.
	var row_box := _empty(4.0, 5.0)
	var row_hover := _box(Color(1, 1, 1, 0.05), Color(0, 0, 0, 0), RADIUS, 4.0, 5.0)
	for state in ["normal", "pressed", "disabled"]:
		t.set_stylebox(state, &"CheckBox", row_box)
	t.set_stylebox("hover", &"CheckBox", row_hover)
	t.set_stylebox("hover_pressed", &"CheckBox", row_hover)
	t.set_icon("checked", &"CheckBox", _check(true, 1.0))
	t.set_icon("unchecked", &"CheckBox", _check(false, 1.0))
	t.set_icon("checked_disabled", &"CheckBox", _check(true, 0.4))
	t.set_icon("unchecked_disabled", &"CheckBox", _check(false, 0.4))
	t.set_icon("radio_checked", &"CheckBox", _radio(true, 1.0))
	t.set_icon("radio_unchecked", &"CheckBox", _radio(false, 1.0))
	t.set_icon("radio_checked_disabled", &"CheckBox", _radio(true, 0.4))
	t.set_icon("radio_unchecked_disabled", &"CheckBox", _radio(false, 0.4))
	# Switches live in the top bar beside buttons, so they wear the button's
	# fill and add the switch on the right.
	t.set_stylebox("normal", &"CheckButton", _box(FILL))
	t.set_stylebox("hover", &"CheckButton", _box(FILL_HOVER))
	t.set_stylebox("pressed", &"CheckButton", _box(FILL))
	t.set_stylebox("hover_pressed", &"CheckButton", _box(FILL_HOVER))
	t.set_stylebox("disabled", &"CheckButton", _box(Color(1, 1, 1, 0.03)))
	# The mirrored set (right-to-left layouts) is the same picture: a switch
	# is symmetric, so the four textures are drawn once and used twice.
	var switches := {
		"checked": _switch(true, 1.0),
		"unchecked": _switch(false, 1.0),
		"checked_disabled": _switch(true, 0.4),
		"unchecked_disabled": _switch(false, 0.4),
	}
	for icon: String in switches:
		t.set_icon(icon, &"CheckButton", switches[icon])
		t.set_icon(icon + "_mirrored", &"CheckButton", switches[icon])

	# Text fields and spin boxes.
	var field := _box(WELL, LINE_FAINT, RADIUS, 8.0, 5.0)
	var field_focus := _box(WELL, Color(ACCENT, 0.7), RADIUS, 8.0, 5.0)
	t.set_stylebox("normal", &"LineEdit", field)
	t.set_stylebox("focus", &"LineEdit", field_focus)
	t.set_stylebox("read_only", &"LineEdit", _box(Color(0, 0, 0, 0.12), LINE_FAINT, RADIUS, 8.0, 5.0))
	t.set_color("font_color", &"LineEdit", TEXT)
	t.set_color("caret_color", &"LineEdit", ACCENT)
	t.set_color("selection_color", &"LineEdit", Color(ACCENT, 0.35))
	t.set_color("font_placeholder_color", &"LineEdit", TEXT_FAINT)
	t.set_color("font_uneditable_color", &"LineEdit", Color(TEXT, 0.5))

	# Sliders: a thin track, the filled part in the accent, a round knob.
	var knob := _knob(false)
	var knob_lit := _knob(true)
	var knob_off := _knob(false, 0.4)
	for type: StringName in [&"HSlider", &"VSlider"]:
		var track := _box(Color(1, 1, 1, 0.16), Color(0, 0, 0, 0), RADIUS_TRACK, 0.0, 0.0)
		var lit := _box(Color(ACCENT, 0.75), Color(0, 0, 0, 0), RADIUS_TRACK, 0.0, 0.0)
		var lit_hi := _box(ACCENT, Color(0, 0, 0, 0), RADIUS_TRACK, 0.0, 0.0)
		if type == &"HSlider":
			for sb: StyleBoxFlat in [track, lit, lit_hi]:
				sb.content_margin_top = 2.0
				sb.content_margin_bottom = 2.0
		else:
			for sb: StyleBoxFlat in [track, lit, lit_hi]:
				sb.content_margin_left = 2.0
				sb.content_margin_right = 2.0
		t.set_stylebox("slider", type, track)
		t.set_stylebox("grabber_area", type, lit)
		t.set_stylebox("grabber_area_highlight", type, lit_hi)
		t.set_icon("grabber", type, knob)
		t.set_icon("grabber_highlight", type, knob_lit)
		t.set_icon("grabber_disabled", type, knob_off)

	# Scroll bars: thin, no arrows.
	for type: StringName in [&"VScrollBar", &"HScrollBar"]:
		var vertical := type == &"VScrollBar"
		var lane := _empty(3.0 if vertical else 0.0, 0.0 if vertical else 3.0)
		t.set_stylebox("scroll", type, lane)
		t.set_stylebox("scroll_focus", type, lane)
		t.set_stylebox("grabber", type, _box(Color(1, 1, 1, 0.16), Color(0, 0, 0, 0), RADIUS_TRACK, 0.0, 0.0))
		t.set_stylebox("grabber_highlight", type, _box(Color(1, 1, 1, 0.28), Color(0, 0, 0, 0), RADIUS_TRACK, 0.0, 0.0))
		t.set_stylebox("grabber_pressed", type, _box(Color(ACCENT, 0.6), Color(0, 0, 0, 0), RADIUS_TRACK, 0.0, 0.0))
		var none := _blank()
		for icon in ["increment", "increment_highlight", "increment_pressed",
				"decrement", "decrement_highlight", "decrement_pressed"]:
			t.set_icon(icon, type, none)

	# Separators.
	t.set_stylebox("separator", &"HSeparator", _hairline(LINE, false))
	t.set_constant("separation", &"HSeparator", 9)
	# Vertical dividers sit on the top bar between groups, over a lighter
	# strip than the sidebar's, so a step brighter than LINE to stay visible.
	t.set_stylebox("separator", &"VSeparator", _hairline(Color(1, 1, 1, 0.16), true, -6.0))
	t.set_constant("separation", &"VSeparator", 9)

	# Panels: a plain card by default; glass is applied per panel in code.
	t.set_stylebox("panel", &"PanelContainer", card())
	t.set_stylebox("panel", &"Panel", card(SURFACE, RADIUS_PANEL, 0.0))

	# Popup menus and tooltips.
	var menu := card(SURFACE_RAISED, RADIUS_PANEL, 6.0)
	menu.shadow_color = Color(0, 0, 0, 0.40)
	menu.shadow_size = 12
	menu.shadow_offset = Vector2(0, 3)
	t.set_stylebox("panel", &"PopupMenu", menu)
	# Rows sit 6 px inside a 6 px panel: concentric would be 0, so the
	# control radius.
	t.set_stylebox("hover", &"PopupMenu", _box(Color(ACCENT, 0.24), Color(0, 0, 0, 0),
			inner_radius(RADIUS_PANEL, 6.0), 0.0, 0.0))
	t.set_stylebox("separator", &"PopupMenu", _hairline(LINE, false))
	t.set_stylebox("labeled_separator_left", &"PopupMenu", _hairline(LINE, false))
	t.set_stylebox("labeled_separator_right", &"PopupMenu", _hairline(LINE, false))
	t.set_color("font_color", &"PopupMenu", TEXT)
	t.set_color("font_hover_color", &"PopupMenu", Color.WHITE)
	t.set_color("font_disabled_color", &"PopupMenu", Color(TEXT, 0.35))
	t.set_color("font_separator_color", &"PopupMenu", Color(ACCENT_TEXT, 0.75))
	t.set_font("font_separator", &"PopupMenu", header_font())
	t.set_font_size("font_separator_size", &"PopupMenu", FONT_TINY + 1)
	var tick := _tick(14, ACCENT)
	var no_tick := _blank(14)
	t.set_icon("radio_checked", &"PopupMenu", tick)
	t.set_icon("radio_unchecked", &"PopupMenu", no_tick)
	t.set_icon("checked", &"PopupMenu", tick)
	t.set_icon("unchecked", &"PopupMenu", no_tick)
	t.set_icon("submenu", &"PopupMenu", _chevron(12, true, TEXT_MUTED))
	t.set_constant("v_separation", &"PopupMenu", 6)
	t.set_constant("item_start_padding", &"PopupMenu", 10)
	t.set_constant("item_end_padding", &"PopupMenu", 12)
	t.set_constant("h_separation", &"PopupMenu", 8)
	var tip := card(SURFACE_RAISED, RADIUS, 0.0)
	tip.content_margin_left = 10.0
	tip.content_margin_right = 10.0
	tip.content_margin_top = 7.0
	tip.content_margin_bottom = 7.0
	tip.shadow_color = Color(0, 0, 0, 0.35)
	tip.shadow_size = 8
	tip.shadow_offset = Vector2(0, 2)
	t.set_stylebox("panel", &"TooltipPanel", tip)
	t.set_color("font_color", &"TooltipLabel", TEXT)
	t.set_font_size("font_size", &"TooltipLabel", FONT_SMALL)

	# Progress bar (the charge-shot meter).
	t.set_stylebox("background", &"ProgressBar", _box(Color(0, 0, 0, 0.45), Color(0, 0, 0, 0), RADIUS, 0.0, 0.0))
	t.set_stylebox("fill", &"ProgressBar", _box(ACCENT, Color(0, 0, 0, 0), RADIUS, 0.0, 0.0))
	t.set_color("font_color", &"ProgressBar", TEXT)

	t.set_color("font_color", &"LinkButton", ACCENT_TEXT)
	t.set_color("font_hover_color", &"LinkButton", Color.WHITE)
	t.set_color("font_pressed_color", &"LinkButton", ACCENT)
	return t


static func _variation(t: Theme, name: StringName, base: StringName, font: Font,
		px: int, color: Color) -> void:
	t.add_type(name)
	t.set_type_variation(name, base)
	if font != null:
		t.set_font("font", name, font)
	t.set_font_size("font_size", name, px)
	t.set_color("font_color", name, color)


# --- drawn icons ---------------------------------------------------------------
#
# Each icon is a function from a point (in icon pixels) to a colour, sampled
# 3x3 per pixel and averaged with premultiplied alpha. Shapes are signed
# distance functions, so an edge is antialiased by the supersampling alone.

const _SS := 3


static func _raster(w: int, h: int, shade: Callable) -> ImageTexture:
	var img := Image.create_empty(w, h, false, Image.FORMAT_RGBA8)
	var n := float(_SS * _SS)
	for y in h:
		for x in w:
			var r := 0.0
			var g := 0.0
			var b := 0.0
			var a := 0.0
			for sy in _SS:
				for sx in _SS:
					var p := Vector2(x + (sx + 0.5) / _SS, y + (sy + 0.5) / _SS)
					var c: Color = shade.call(p)
					r += c.r * c.a
					g += c.g * c.a
					b += c.b * c.a
					a += c.a
			if a > 0.0:
				img.set_pixel(x, y, Color(r / a, g / a, b / a, a / n))
	return ImageTexture.create_from_image(img)


## Distance to a rounded box centred at `c` with half extents `half`.
static func _sd_rbox(p: Vector2, c: Vector2, half: Vector2, r: float) -> float:
	var q := (p - c).abs() - half + Vector2(r, r)
	return q.max(Vector2.ZERO).length() + minf(maxf(q.x, q.y), 0.0) - r


## Distance to the segment a-b.
static func _sd_seg(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var t := clampf((p - a).dot(ab) / ab.length_squared(), 0.0, 1.0)
	return (p - (a + ab * t)).length()


## Paint `top` over `under` (straight alpha).
static func _over(under: Color, top: Color) -> Color:
	var a := top.a + under.a * (1.0 - top.a)
	if a <= 0.0:
		return Color(0, 0, 0, 0)
	var rgb := (Color(top.r, top.g, top.b) * top.a
			+ Color(under.r, under.g, under.b) * under.a * (1.0 - top.a)) / a
	return Color(rgb.r, rgb.g, rgb.b, a)


static func _fade(c: Color, alpha: float) -> Color:
	return Color(c.r, c.g, c.b, c.a * alpha)


## Check box: a small rounded square, filled in the accent with a dark tick
## when on, a raised light fill when off. No rim either way.
static func _check(on: bool, alpha: float) -> ImageTexture:
	const S := 18
	var c := Vector2(S, S) * 0.5
	return _raster(S, S, func(p: Vector2) -> Color:
		var d := _sd_rbox(p, c, Vector2(7.5, 7.5), float(RADIUS))
		if d > 0.0:
			return Color(0, 0, 0, 0)
		if on:
			var col := ACCENT
			var tick := minf(_sd_seg(p, Vector2(5.0, 9.2), Vector2(7.8, 12.0)),
					_sd_seg(p, Vector2(7.8, 12.0), Vector2(13.0, 6.2)))
			if tick < 1.15:
				col = INK
			return _fade(col, alpha)
		return _fade(Color(1, 1, 1, 0.20), alpha))


static func _radio(on: bool, alpha: float) -> ImageTexture:
	const S := 18
	var c := Vector2(S, S) * 0.5
	return _raster(S, S, func(p: Vector2) -> Color:
		var d := p.distance_to(c) - 7.5
		if d > 0.0:
			return Color(0, 0, 0, 0)
		if on:
			return _fade(INK if p.distance_to(c) < 3.0 else ACCENT, alpha)
		return _fade(Color(1, 1, 1, 0.20), alpha))


## Switch: a pill with a round knob, right and accent when on, left and grey
## when off.
static func _switch(on: bool, alpha: float) -> ImageTexture:
	const W := 34
	const H := 20
	var c := Vector2(W, H) * 0.5
	var knob := Vector2(W - 10.0, 10.0) if on else Vector2(10.0, 10.0)
	var track := Color(ACCENT, 0.88) if on else Color(1, 1, 1, 0.18)
	var face := Color.WHITE if on else Color(0.84, 0.86, 0.90)
	return _raster(W, H, func(p: Vector2) -> Color:
		var d := _sd_rbox(p, c, Vector2(16.5, 9.5), 9.5)
		if d > 0.0:
			return Color(0, 0, 0, 0)
		var col := track
		if p.distance_to(knob) < 7.0:
			col = _over(col, face)
		return _fade(col, alpha))


## Slider knob: a plain light dot; lit (hovered or dragged), the accent.
static func _knob(lit: bool, alpha := 1.0) -> ImageTexture:
	const S := 16
	var c := Vector2(S, S) * 0.5
	var face := ACCENT if lit else Color(0.90, 0.92, 0.95)
	return _raster(S, S, func(p: Vector2) -> Color:
		return _fade(face, alpha) if p.distance_to(c) < 6.5 else Color(0, 0, 0, 0))


## A chevron, pointing down, or right for a submenu.
static func _chevron(s: int, right: bool, col: Color) -> ImageTexture:
	var k := float(s)
	var a := Vector2(k * 0.22, k * 0.36)
	var m := Vector2(k * 0.5, k * 0.66)
	var b := Vector2(k * 0.78, k * 0.36)
	if right:
		a = Vector2(a.y, a.x)
		m = Vector2(m.y, m.x)
		b = Vector2(b.y, b.x)
	return _raster(s, s, func(p: Vector2) -> Color:
		var d := minf(_sd_seg(p, a, m), _sd_seg(p, m, b))
		return col if d < 1.0 else Color(0, 0, 0, 0))


## Transport glyphs for the top bar's recorder, drawn so they cannot fall back
## to a missing font glyph (the browser build has no system fonts).
static var _transport := {}


static func transport_icon(kind: String) -> Texture2D:
	if not _transport.has(kind):
		const S := 14
		var c := Vector2(S, S) * 0.5
		var tex: ImageTexture
		match kind:
			"record":
				tex = _raster(S, S, func(p: Vector2) -> Color:
					return RECORD if p.distance_to(c) < 5.0 else Color(0, 0, 0, 0))
			"stop":
				tex = _raster(S, S, func(p: Vector2) -> Color:
					return Color.WHITE if _sd_rbox(p, c, Vector2(4.5, 4.5), 1.0) < 0.0 \
							else Color(0, 0, 0, 0))
			_:  # "play": a right-pointing triangle
				var a := Vector2(4.0, 2.5)
				var b := Vector2(4.0, 11.5)
				var tip := Vector2(11.5, 7.0)
				tex = _raster(S, S, func(p: Vector2) -> Color:
					var inside := (b - a).cross(p - a) <= 0.0 and (tip - b).cross(p - b) <= 0.0 \
							and (a - tip).cross(p - tip) <= 0.0
					return Color.WHITE if inside else Color(0, 0, 0, 0))
		_transport[kind] = tex
	return _transport[kind]


## The popup's radio and check mark.
static func _tick(s: int, col: Color) -> ImageTexture:
	var k := float(s)
	var a := Vector2(k * 0.2, k * 0.52)
	var m := Vector2(k * 0.42, k * 0.72)
	var b := Vector2(k * 0.8, k * 0.3)
	return _raster(s, s, func(p: Vector2) -> Color:
		var d := minf(_sd_seg(p, a, m), _sd_seg(p, m, b))
		return col if d < 1.1 else Color(0, 0, 0, 0))


## An invisible icon that still reserves its width (unchecked popup rows line
## up with checked ones). Size 1 for the scroll bars' arrow slots.
static func _blank(s := 1) -> ImageTexture:
	var img := Image.create_empty(s, s, false, Image.FORMAT_RGBA8)
	return ImageTexture.create_from_image(img)
