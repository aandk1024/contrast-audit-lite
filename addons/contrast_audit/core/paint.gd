@tool
extends RefCounted

## Works out what colour a control actually puts on the screen, and what is
## actually behind it.
##
## This is the part that cannot be done by reading files. A .tscn stores
## overrides and nothing else; the colour a Label ends up drawing comes from
## a lookup that walks the override, then the node's own theme, then every
## ancestor's theme, then the project theme, then the default theme - and
## then gets multiplied by the modulate of every CanvasItem above it. The
## background is worse: it is whatever happens to be painted underneath after
## the containers have decided where everything sits, which is not knowable
## until the scene is laid out.
##
## So everything here takes a live Control that is already inside a tree.

const Wcag := preload("res://addons/contrast_audit/core/wcag.gd")

## Colour item names, per class, for the text a control shows. Godot's default
## theme is not uniform about this and a wrong name silently returns the
## default theme's fallback rather than failing, which would make every report
## quietly wrong.
const FONT_COLOR_ITEM := {
    "RichTextLabel": "default_color",
    "TextEdit": "font_color",
    "CodeEdit": "font_color",
}
const DEFAULT_FONT_COLOR_ITEM := "font_color"

const FONT_SIZE_ITEM := {
    "RichTextLabel": "normal_font_size",
}
const DEFAULT_FONT_SIZE_ITEM := "font_size"

## The stylebox that paints a control's own background in its resting state.
const PANEL_ITEM := {
    "Panel": "panel",
    "PanelContainer": "panel",
    "PopupPanel": "panel",
    "TabContainer": "panel",
    "MarginContainer": "",
}
const DEFAULT_PANEL_ITEM := "normal"

## Classes whose surface is a picture. Their pixels are not knowable without
## reading the texture back, so anything sitting on one is reported as
## unverifiable rather than passed.
const IMAGE_CLASSES := ["TextureRect", "NinePatchRect", "VideoStreamPlayer", "TextureButton"]


## The tint every CanvasItem above this one multiplies onto it. modulate is
## inherited by children; self_modulate is not.
static func chain_modulate(node: CanvasItem) -> Color:
    var acc := Color(1, 1, 1, 1)
    var n: Node = node.get_parent()
    while n != null and n is CanvasItem:
        var m: Color = (n as CanvasItem).modulate
        acc = Color(acc.r * m.r, acc.g * m.g, acc.b * m.b, acc.a * m.a)
        n = n.get_parent()
    return acc


## The tint applied to what this control itself draws.
static func own_tint(c: CanvasItem) -> Color:
    var acc := chain_modulate(c)
    var m := c.modulate
    var s := c.self_modulate
    return Color(
        acc.r * m.r * s.r,
        acc.g * m.g * s.g,
        acc.b * m.b * s.b,
        acc.a * m.a * s.a)


static func multiply(a: Color, b: Color) -> Color:
    return Color(a.r * b.r, a.g * b.g, a.b * b.b, a.a * b.a)


static func font_color_item(c: Control) -> String:
    return FONT_COLOR_ITEM.get(c.get_class(), DEFAULT_FONT_COLOR_ITEM)


static func font_size_item(c: Control) -> String:
    return FONT_SIZE_ITEM.get(c.get_class(), DEFAULT_FONT_SIZE_ITEM)


## The colour this control draws its text in, already tinted, alpha kept.
## Returns a Color with a < 0 when the control has no such item at all, which
## a caller must treat as "not applicable" rather than as black.
static func text_color(c: Control, item: String = "") -> Color:
    if item == "":
        item = font_color_item(c)
    if not c.has_theme_color(item):
        return Color(0, 0, 0, -1.0)
    var col: Color = c.get_theme_color(item)
    return multiply(col, own_tint(c))


## The resolved font size in pixels, after the theme's base scale.
static func font_size(c: Control) -> float:
    var item := font_size_item(c)
    var px := 0.0
    if c.has_theme_font_size(item):
        px = float(c.get_theme_font_size(item))
    if px <= 0.0:
        var t := ThemeDB.get_default_theme()
        px = float(t.default_font_size) if t != null else float(ThemeDB.fallback_font_size)
    # A theme with default_base_scale != 1 scales every drawn size. Godot
    # applies it at draw time, so the number in the inspector is not the
    # number on the screen.
    var scale := 1.0
    var stage_theme := c.get_theme()
    if stage_theme != null and stage_theme.default_base_scale > 0.0:
        scale = stage_theme.default_base_scale
    return px * scale


## One opaque-or-not background colour contributed by a node, or null when the
## node paints nothing knowable.
##
## Returns a Dictionary: {"color": Color} for a known flat fill,
## {"image": String} for a surface whose pixels are a picture, or {} for
## a node that paints nothing at all.
static func surface_of(n: CanvasItem, state_item: String = "") -> Dictionary:
    if not (n is Control):
        return {}
    var c := n as Control
    # A material repaints whatever is underneath with a shader, and the
    # licence promises that text on a shader is reported rather than guessed
    # at. Reading the theme colour and calling it the background would be the
    # guess.
    if c.material != null:
        return {"image": "a material (%s)" % c.material.get_class()}
    if IMAGE_CLASSES.has(c.get_class()):
        # An empty TextureRect paints nothing, so it is not an obstacle.
        if "texture" in c and c.get("texture") == null:
            return {}
        return {"image": c.get_class()}
    if c is ColorRect:
        return {"color": multiply((c as ColorRect).color, own_tint(c))}
    var item := state_item
    if item == "":
        item = PANEL_ITEM.get(c.get_class(), DEFAULT_PANEL_ITEM)
    if item == "" or not c.has_theme_stylebox(item):
        return {}
    var sb: StyleBox = c.get_theme_stylebox(item)
    return _stylebox_surface(sb, own_tint(c))


static func _stylebox_surface(sb: StyleBox, tint: Color) -> Dictionary:
    if sb == null:
        return {}
    if sb is StyleBoxEmpty:
        return {}
    if sb is StyleBoxFlat:
        var flat := sb as StyleBoxFlat
        # draw_center = false means the box paints its border and nothing
        # else, so bg_color is a value that never reaches the screen. Godot's
        # own default focus stylebox is exactly this, and reading its
        # bg_color made every focusable button in the demo report a contrast
        # failure against a background that is not there.
        if not flat.draw_center:
            return {}
        return {"color": multiply(flat.bg_color, tint)}
    if sb is StyleBoxTexture:
        return {"image": "StyleBoxTexture"}
    # StyleBoxLine draws a line, not a fill.
    return {}


## The border colour a StyleBoxFlat draws, for SC 1.4.11 checks. Alpha < 0
## when there is no border to speak of.
static func border_color(c: Control, item: String = "") -> Color:
    if item == "":
        item = PANEL_ITEM.get(c.get_class(), DEFAULT_PANEL_ITEM)
    if item == "" or not c.has_theme_stylebox(item):
        return Color(0, 0, 0, -1.0)
    var sb: StyleBox = c.get_theme_stylebox(item)
    if not (sb is StyleBoxFlat):
        return Color(0, 0, 0, -1.0)
    var f := sb as StyleBoxFlat
    var widest := maxi(maxi(f.border_width_left, f.border_width_right),
            maxi(f.border_width_top, f.border_width_bottom))
    if widest <= 0:
        return Color(0, 0, 0, -1.0)
    return multiply(f.border_color, own_tint(c))


## What is behind this control's text, front to back.
##
## The walk goes up the tree. At each level it takes the node's own fill
## first, then the siblings drawn before that branch - in Godot a later
## sibling paints on top of an earlier one, so anything before is underneath.
## A sibling only counts when its rectangle actually covers the text; a
## ColorRect off to one side is not the background of anything.
##
## Returns {"color": Color (opaque, composited), "unknown": String}.
## "unknown" is "" when the stack really did reach an opaque known fill, and
## otherwise names the surface that could not be read. A caller must report
## that case rather than silently comparing against the clear colour.
static func background_behind(c: Control, root: Node) -> Dictionary:
    var target := c.get_global_rect()
    var layers: Array = []
    var unknown := ""

    var node: Node = c
    while node != null:
        if node is Control:
            var ctl := node as Control
            # The control's own fill is behind its own text. For the control
            # the text belongs to this is its "normal" stylebox; for an
            # ancestor it is whatever that class paints.
            var s := surface_of(ctl)
            if s.has("image"):
                unknown = "%s (%s)" % [String(root.get_path_to(ctl)), s["image"]]
                return {"color": Wcag.flatten(layers, Color(0.5, 0.5, 0.5, 1)), "unknown": unknown}
            if s.has("color"):
                var col: Color = s["color"]
                layers.append(col)
                if col.a >= 1.0:
                    return {"color": Wcag.flatten(layers, Color(0, 0, 0, 1)), "unknown": ""}

        # Siblings painted before this branch.
        var parent := node.get_parent()
        if parent == null or node == root:
            break
        var idx := node.get_index()
        for i in range(idx - 1, -1, -1):
            var sib := parent.get_child(i)
            if not (sib is Control):
                continue
            var sc := sib as Control
            if not sc.is_visible_in_tree():
                continue
            if not sc.get_global_rect().encloses(target):
                continue
            var ss := surface_of(sc)
            if ss.has("image"):
                unknown = "%s (%s)" % [String(root.get_path_to(sc)), ss["image"]]
                return {"color": Wcag.flatten(layers, Color(0.5, 0.5, 0.5, 1)), "unknown": unknown}
            if ss.has("color"):
                var scol: Color = ss["color"]
                layers.append(scol)
                if scol.a >= 1.0:
                    return {"color": Wcag.flatten(layers, Color(0, 0, 0, 1)), "unknown": ""}
        node = parent

    # Nothing opaque was found on the way up, so the window's own clear colour
    # is what is showing through.
    return {"color": Wcag.flatten(layers, _clear_color()), "unknown": ""}


static func _clear_color() -> Color:
    var v = ProjectSettings.get_setting("rendering/environment/defaults/default_clear_color", Color(0.3, 0.3, 0.3, 1.0))
    if v is Color:
        var col: Color = v
        col.a = 1.0
        return col
    return Color(0.3, 0.3, 0.3, 1.0)
