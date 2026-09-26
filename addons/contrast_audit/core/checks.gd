@tool
extends RefCounted

## The checks themselves. Each one is a measurement taken on a live, laid-out
## control, and each finding carries the two numbers it was decided by, so a
## buyer can argue with it instead of having to trust it.
##
## What is deliberately NOT here: anything that could be decided by reading
## the project files. That ground is already covered by free tools, and a
## paid checker that reports it is selling a worse copy of something free.

const Wcag := preload("res://addons/contrast_audit/core/wcag.gd")
const Paint := preload("res://addons/contrast_audit/core/paint.gd")


class Finding extends RefCounted:
    var scene: String = ""
    var node_path: String = ""
    var node_class: String = ""
    ## "contrast" | "state_contrast" | "unverifiable" | "font_size" | "target_size"
    var kind: String = "contrast"
    ## Free-form detail: which state, which side of the rectangle, and so on.
    var detail: String = ""
    ## What the control shows, trimmed. Empty for findings that are not
    ## about text.
    var text: String = ""
    ## The measured value and the value it had to reach.
    var got: float = 0.0
    var want: float = 0.0
    var fg: Color = Color(0, 0, 0, 0)
    var bg: Color = Color(0, 0, 0, 0)

    func _head() -> String:
        return "%s :: %s (%s) " % [scene, node_path, node_class]

    func _shown() -> String:
        if text == "":
            return ""
        var s := text.substr(0, 40)
        if text.length() > 40:
            s += "…"
        # Backslash first, or the escapes written next would be doubled.
        s = s.replace("\\", "\\\\").replace("\"", "\\\"")
        s = s.replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t")
        return " - \"%s\"" % s

    func to_line() -> String:
        match kind:
            "contrast":
                return _head() + "contrast %s, needs %s (text %s on %s)%s" % [
                    Wcag.fmt(got), Wcag.fmt(want), fg.to_html(false), bg.to_html(false), _shown()]
            "state_contrast":
                return _head() + "contrast %s in state '%s', needs %s (text %s on %s)%s" % [
                    Wcag.fmt(got), detail, Wcag.fmt(want), fg.to_html(false), bg.to_html(false), _shown()]
            "unverifiable":
                return _head() + "contrast not verifiable: background is %s%s" % [detail, _shown()]
            "font_size":
                return _head() + "font is %dpx, below the %dpx floor%s" % [
                    int(got), int(want), _shown()]
            "target_size":
                return _head() + "clickable area is %dx%d, below %dx%d (%s)%s" % [
                    int(got), int(detail.to_int()), int(want), int(want), "WCAG 2.2 SC 2.5.8", _shown()]
        return _head() + kind


## Everything a Button-like control can look like. Each state has its own font
## colour and its own background in Godot's theme, and they are set
## independently - which is exactly why the disabled state is where contrast
## quietly fails. Nobody screenshots a disabled button.
const BUTTON_STATES := [
    {"font": "font_hover_color", "box": "hover", "name": "hover"},
    {"font": "font_pressed_color", "box": "pressed", "name": "pressed"},
    {"font": "font_disabled_color", "box": "disabled", "name": "disabled"},
    {"font": "font_focus_color", "box": "focus", "name": "focus"},
]

## Text properties worth reading, in the order they matter.
const TEXT_PROPS := ["text", "placeholder_text"]

## Inline links are exempt from the target-size rule in WCAG 2.2, and a
## LinkButton is Godot's inline link.
const TARGET_EXEMPT := ["LinkButton"]


class Options extends RefCounted:
    ## "AA" or "AAA".
    var level: String = "AA"
    ## Smallest font, in pixels, that counts as readable. Not a WCAG number -
    ## the guidelines set no minimum size - so it is a house rule with a
    ## default, and the report says so.
    var min_font_px: float = 12.0
    ## WCAG 2.2 SC 2.5.8 Target Size (Minimum). 44 is the AAA figure (2.5.5).
    var min_target_px: float = 24.0
    var check_states: bool = true
    var check_font_size: bool = true
    var check_target_size: bool = true


## The object handed to stage.gd. It holds the options and collects findings.
class Inspector extends RefCounted:
    var opts: Options = null

    func _init(options: Options = null) -> void:
        opts = options if options != null else Options.new()

    func inspect(root: Node, ctx: Dictionary, out: Array) -> void:
        var scene := String(ctx.get("scene", ""))
        _walk(root, root, scene, out)

    func _walk(node: Node, root: Node, scene: String, out: Array) -> void:
        if not is_instance_valid(node):
            return
        # A hidden branch is not laid out and not on screen. Its rectangles
        # are meaningless and reporting them would bury the real findings.
        if node is CanvasItem and not (node as CanvasItem).visible:
            return
        if node is Control:
            _inspect(node as Control, root, scene, out)
        for child in node.get_children():
            _walk(child, root, scene, out)

    func _inspect(c: Control, root: Node, scene: String, out: Array) -> void:
        if not c.is_visible_in_tree():
            return
        var path := String(root.get_path_to(c))
        var texts := _texts(c)

        if not texts.is_empty():
            _check_text(c, root, scene, path, texts[0], out)

        if opts.check_target_size:
            _check_target(c, scene, path, texts, out)

    func _texts(c: Control) -> PackedStringArray:
        var out := PackedStringArray()
        for prop in TEXT_PROPS:
            if prop in c:
                var v = c.get(prop)
                if v is String and String(v).strip_edges() != "":
                    out.append(String(v))
        return out

    func _check_text(c: Control, root: Node, scene: String, path: String,
            text: String, out: Array) -> void:
        var fg := Paint.text_color(c)
        if fg.a < 0.0:
            # No font colour item on this class at all - not a text control
            # in the sense this check means.
            return
        var px := Paint.font_size(c)

        if opts.check_font_size and px < opts.min_font_px:
            out.append(_make(scene, path, c, "font_size", "", text, px, opts.min_font_px))

        var back := Paint.background_behind(c, root)
        var unknown := String(back.get("unknown", ""))
        if unknown != "":
            out.append(_make(scene, path, c, "unverifiable", unknown, text, 0.0, 0.0))
            return
        var bg: Color = back["color"]
        var flat := Wcag.over(fg, bg)
        var ratio := Wcag.contrast(flat, bg)
        var want := Wcag.required(px, false, opts.level)
        if ratio < want:
            var f := _make(scene, path, c, "contrast", "", text, ratio, want)
            f.fg = flat
            f.bg = bg
            out.append(f)

        if opts.check_states and c is BaseButton:
            _check_states(c, scene, path, text, bg, px, out)

    ## A button carries four more looks that the resting state says nothing
    ## about. Each is checked against its own background, because Godot gives
    ## every state its own stylebox too.
    func _check_states(c: Control, scene: String, path: String, text: String,
            resting_bg: Color, px: float, out: Array) -> void:
        var want := Wcag.required(px, false, opts.level)
        for st in BUTTON_STATES:
            var font_item := String(st["font"])
            if not c.has_theme_color(font_item):
                continue
            var sfg: Color = Paint.multiply(c.get_theme_color(font_item), Paint.own_tint(c))
            var sbg := resting_bg
            var box_item := String(st["box"])
            if c.has_theme_stylebox(box_item):
                var surf := Paint._stylebox_surface(c.get_theme_stylebox(box_item), Paint.own_tint(c))
                if surf.has("image"):
                    # A state painted with a picture cannot be measured. It
                    # used to be skipped in silence, which let a button whose
                    # hover state is a texture pass without ever being
                    # checked - the one thing this tool promises never to do.
                    out.append(_make(scene, path, c, "unverifiable",
                        "the '%s' state is painted with %s" % [String(st["name"]), surf["image"]],
                        text, 0.0, 0.0))
                    continue
                if surf.has("color"):
                    sbg = Wcag.over(surf["color"], resting_bg)
            var flat := Wcag.over(sfg, sbg)
            var ratio := Wcag.contrast(flat, sbg)
            if ratio < want:
                var f := _make(scene, path, c, "state_contrast", String(st["name"]), text, ratio, want)
                f.fg = flat
                f.bg = sbg
                out.append(f)

    func _check_target(c: Control, scene: String, path: String,
            texts: PackedStringArray, out: Array) -> void:
        if not _is_interactive(c):
            return
        if TARGET_EXEMPT.has(c.get_class()):
            return
        var r := c.size
        # A control the layout has not given any size to yet is not a small
        # target, it is an unfinished measurement. Saying "0x0 is too small"
        # for every one of them would drown the real findings.
        if r.x <= 0.0 or r.y <= 0.0:
            return
        if r.x >= opts.min_target_px and r.y >= opts.min_target_px:
            return
        var label := texts[0] if not texts.is_empty() else ""
        var f := _make(scene, path, c, "target_size", str(int(r.y)), label, r.x, opts.min_target_px)
        out.append(f)

    func _is_interactive(c: Control) -> bool:
        if c.mouse_filter == Control.MOUSE_FILTER_IGNORE:
            return false
        if c is BaseButton:
            # A button that is switched off cannot be hit at all, so its size
            # is not a barrier.
            return not (c as BaseButton).disabled
        return (c is LineEdit) or (c is TextEdit) or (c is Slider) or (c is SpinBox)

    func _make(scene: String, path: String, c: Control, kind: String,
            detail: String, text: String, got: float, want: float) -> Finding:
        var f := Finding.new()
        f.scene = scene
        f.node_path = path
        f.node_class = c.get_class()
        f.kind = kind
        f.detail = detail
        f.text = text
        f.got = got
        f.want = want
        return f
