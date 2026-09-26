@tool
extends RefCounted

## Runs the checks over a set of scenes. Kept apart from the dock on purpose:
## the dock is a thin skin with no judgement in it, so every rule can be
## exercised headlessly by tests/run_tests.gd without an editor anywhere.

const Stage := preload("res://addons/contrast_audit/core/stage.gd")
const Checks := preload("res://addons/contrast_audit/core/checks.gd")


class Result extends RefCounted:
    var findings: Array = []
    var scenes_checked: int = 0
    ## Scenes that could not be measured at all, with the reason. These are
    ## not "clean" and must never be counted as such.
    var skipped: Array = []
    var ms: int = 0

    func ok() -> bool:
        return skipped.is_empty()


## Must be awaited.
static func run(scenes: PackedStringArray, host: Node, opts: Object = null) -> Result:
    var res := Result.new()
    var started := Time.get_ticks_msec()
    var options = opts if opts != null else Checks.Options.new()
    for scene in scenes:
        var inspector := Checks.Inspector.new(options)
        var got = await Stage.measure(scene, host, inspector)
        if got == null:
            res.skipped.append(scene)
            continue
        res.scenes_checked += 1
        for f in got:
            res.findings.append(f)
    _sort(res.findings)
    res.ms = Time.get_ticks_msec() - started
    return res


## Stable order: scene, then node path, then kind. Two runs over an unchanged
## project must produce byte-identical output, or the JSON report is useless
## for spotting what a commit actually changed.
static func _sort(findings: Array) -> void:
    findings.sort_custom(func(a, b):
        if a.scene != b.scene:
            return a.scene < b.scene
        if a.node_path != b.node_path:
            return a.node_path < b.node_path
        if a.kind != b.kind:
            return a.kind < b.kind
        return a.detail < b.detail)
