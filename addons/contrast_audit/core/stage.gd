@tool
extends RefCounted

## Mounts a scene off screen, under a Control that carries the game's own
## theme, and lets the layout settle for real frames before anything is read.
##
## Why the detour. Every number this addon reports - a resolved colour, a
## laid-out rectangle, a font size after theme scaling - only exists once
## Godot has actually built the control tree. Reading the .tscn text gives
## none of them: a colour is looked up through the theme chain (override on
## the node, then the node's theme, then each ancestor's theme, then the
## project theme, then the default theme), and a rectangle comes from
## whatever container the control happens to sit in.
##
## And it has to be the *game's* theme. Inside the editor a node parented to
## the editor tree inherits the editor's theme - its font, its 14px, its
## paddings - so the same button measures one width in the dock and another
## in the running game. Loc Audit measured 215px against 240px for one button
## on 2026-09-02. A Control carrying the game theme sits between the viewport
## and the scene, so the lookup stops there.
##
## measure() returns null when the scene could not be loaded or the host left
## the tree mid-run, and an Array (possibly empty) when the scene really was
## measured. The two must never be conflated: an empty Array means "nothing
## wrong", null means "not measured". Reporting null as "clean" is how a
## checker quietly starts lying.

## Frames to wait after mounting. One for the tree to enter, one for
## containers to sort their children, one for anything that resizes in
## response to that first sort.
const SETTLE_FRAMES := 3


static func window_size() -> Vector2i:
    var w := int(ProjectSettings.get_setting("display/window/size/viewport_width", 1152))
    var h := int(ProjectSettings.get_setting("display/window/size/viewport_height", 648))
    # A project that stores 0 (or something silly) would make an unusable
    # viewport, and every rectangle read out of it would be zero-sized.
    if w < 16:
        w = 1152
    if h < 16:
        h = 648
    return Vector2i(w, h)


## The theme the game runs with: Godot's default theme, with the project's own
## theme (gui/theme/custom) merged over it, plus the project's default font,
## size and scale. Every item is present, so no lookup escapes past it into
## the editor's theme.
static func game_theme() -> Theme:
    var t := Theme.new()
    var base := ThemeDB.get_default_theme()
    if base != null:
        t.merge_with(base)
    var project := ThemeDB.get_project_theme()
    if project != null:
        t.merge_with(project)
    t.default_font = project.default_font if project != null and project.default_font != null else ThemeDB.fallback_font
    t.default_font_size = project.default_font_size if project != null and project.default_font_size > 0 else ThemeDB.fallback_font_size
    t.default_base_scale = project.default_base_scale if project != null and project.default_base_scale > 0.0 else ThemeDB.fallback_base_scale
    return t


## The colour the window is cleared to. It is the last thing behind every
## control, so a screen that draws no background of its own is still being
## read against something real rather than against an assumed white.
static func clear_color() -> Color:
    var v = ProjectSettings.get_setting("rendering/environment/defaults/default_clear_color", Color(0.3, 0.3, 0.3, 1.0))
    if v is Color:
        var c: Color = v
        # The clear colour is what the screen ends up being; it is opaque by
        # definition even if the setting carries an alpha.
        c.a = 1.0
        return c
    return Color(0.3, 0.3, 0.3, 1.0)


## Instantiates one scene off screen at the given size and hands the live root
## to checker.inspect(root, ctx, out).
##
## checker must expose:  func inspect(root: Node, ctx: Dictionary, out: Array) -> void
## ctx carries "scene" (path) and "size" (Vector2i) so a checker can report
## which sweep step produced a finding without being handed extra arguments.
##
## Must be awaited.
static func measure(scene_path: String, host: Node, checker: Object,
        size: Vector2i = Vector2i.ZERO) -> Variant:
    if host == null or not is_instance_valid(host) or not host.is_inside_tree():
        push_error("contrast_audit: no host node in the tree to mount the off-screen viewport on")
        return null
    if checker == null or not checker.has_method("inspect"):
        push_error("contrast_audit: checker has no inspect() method")
        return null
    if size == Vector2i.ZERO:
        size = window_size()

    # CACHE_MODE_IGNORE: the editor may be holding an older copy of a scene the
    # user just edited, and reporting against yesterday's layout is worse than
    # not reporting at all.
    var packed := ResourceLoader.load(scene_path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE)
    if packed == null or not (packed is PackedScene):
        return null

    # Taken once. The host may be freed while a frame is in flight, and
    # get_tree() on a freed node is an error rather than null.
    var tree := host.get_tree()
    if tree == null:
        return null

    var vp := SubViewport.new()
    vp.size = size
    vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
    host.add_child(vp)

    var stage := Control.new()
    stage.name = "AuditStage"
    stage.theme = game_theme()
    # The stage must fill the viewport exactly, or a control anchored to the
    # right edge is measured against the wrong edge. Anchors do that on their
    # own; assigning size as well is what Godot warns about, and the assigned
    # value would be overridden a frame later anyway.
    stage.set_anchors_preset(Control.PRESET_FULL_RECT)

    vp.add_child(stage)

    var out: Array = []
    var root: Node = packed.instantiate()
    if root == null:
        _tear_down(host, vp)
        return null
    stage.add_child(root)

    for _i in range(SETTLE_FRAMES):
        await tree.process_frame

    if not is_instance_valid(host) or not host.is_inside_tree():
        # The plugin was disabled or the editor closed while frames passed.
        # Put the tree back and say "not measured" rather than return half a
        # result that reads like a clean bill of health.
        _tear_down(host, vp)
        return null

    # A scene whose own code freed the root during those frames was never
    # looked at. Returning the empty Array would count it as measured and
    # clean - the exact lie the top of this file says must not happen.
    if not is_instance_valid(root) or not is_instance_valid(stage) or not is_instance_valid(vp):
        _tear_down(host, vp)
        return null

    var ctx := {"scene": scene_path, "size": size}
    checker.inspect(root, ctx, out)
    if is_instance_valid(root):
        stage.remove_child(root)
        root.queue_free()

    _tear_down(host, vp)
    return out


static func _tear_down(host: Node, vp: SubViewport) -> void:
    if not is_instance_valid(vp):
        return
    if is_instance_valid(host) and vp.get_parent() == host:
        host.remove_child(vp)
    if vp.is_inside_tree():
        vp.queue_free()
    else:
        vp.free()



const SKIP_DIRS := ["addons", ".godot", ".git", ".import", "android", "ios"]

## A folder link that points at one of its own ancestors makes the walk below
## never end, and it takes the whole editor with it - there is no cancel
## button and the project has to be killed. Windows junctions do this by
## accident often enough (a "current" link beside the folder it points into).
## Depth and a folder count are both capped, because a link is not the only
## way to produce a tree that is effectively bottomless.
const MAX_DEPTH := 40
const MAX_DIRS := 20000


static func _walk_dir(path: String, out: PackedStringArray, depth: int = 0,
        budget: Array = []) -> void:
    if budget.is_empty():
        budget.append(MAX_DIRS)
    if depth > MAX_DEPTH:
        push_error("contrast_audit: stopped at %d folders deep (%s). The scan is NOT complete - a folder link probably points at one of its own parents." % [MAX_DEPTH, path])
        return
    if int(budget[0]) <= 0:
        return
    budget[0] = int(budget[0]) - 1
    if int(budget[0]) == 0:
        push_error("contrast_audit: stopped after %d folders. The scan is NOT complete." % MAX_DIRS)
        return
    var d := DirAccess.open(path)
    if d == null:
        return
    # A .gdignore folder is not part of the project as far as Godot's importer
    # is concerned, so its scenes cannot even be loaded. DirAccess walks into
    # it regardless, which is how Loc Audit ended up scanning its own test
    # fixtures (E-374).
    if FileAccess.file_exists(path.path_join(".gdignore")):
        return
    d.list_dir_begin()
    var name := d.get_next()
    while name != "":
        if name.begins_with("."):
            name = d.get_next()
            continue
        var full := path.path_join(name)
        if d.current_is_dir():
            # A link is not followed at all. Anything real inside it is
            # reachable by its own path, so nothing is lost by refusing.
            if SKIP_DIRS.has(name) or _is_link(d, full):
                name = d.get_next()
                continue
            _walk_dir(full, out, depth + 1, budget)
        elif name.ends_with(".tscn"):
            out.append(full)
        name = d.get_next()
    d.list_dir_end()


## DirAccess.is_link() is asked for by name rather than called directly, so
## this file still works if a version does not carry it.
static func _is_link(d: DirAccess, full: String) -> bool:
    if not d.has_method("is_link"):
        return false
    return bool(d.call("is_link", full))
