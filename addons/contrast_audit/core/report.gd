@tool
extends RefCounted

## Turns findings into the three shapes a buyer needs them in: a summary they
## read in the dock, a Markdown file they paste into a ticket, and JSON a
## build server can fail a pipeline on.
##
## The JSON shape is the contract. It is versioned, and the tests pin every
## key name, because the moment someone wires it into CI a renamed field is a
## broken build rather than a cosmetic change.

const SCHEMA_VERSION := 1

## Severity is not invented per report. A ratio that misses AA is a fail; a
## background nobody can read is a warning, because the tool genuinely does
## not know and saying "fail" would be a guess dressed as a measurement.
const SEVERITY := {
    "contrast": "fail",
    "state_contrast": "fail",
    "font_size": "warn",
    "target_size": "warn",
    "unverifiable": "warn",
}

const KIND_LABEL := {
    "contrast": "Text contrast",
    "state_contrast": "Contrast in a button state",
    "font_size": "Font below the size floor",
    "target_size": "Clickable area too small",
    "unverifiable": "Contrast could not be verified",
}


static func severity_of(kind: String) -> String:
    return String(SEVERITY.get(kind, "warn"))


static func counts(findings: Array) -> Dictionary:
    var out := {"fail": 0, "warn": 0, "total": 0}
    for f in findings:
        var s := severity_of(f.kind)
        out[s] = int(out.get(s, 0)) + 1
        out["total"] = int(out["total"]) + 1
    return out


static func by_kind(findings: Array) -> Dictionary:
    var out := {}
    for f in findings:
        var k: String = f.kind
        if not out.has(k):
            out[k] = []
        out[k].append(f)
    return out


## One line per finding, grouped by kind, kinds in a fixed order so two runs
## of the same project produce the same text and a diff means something.
const KIND_ORDER := ["contrast", "state_contrast", "target_size", "font_size", "unverifiable"]


static func to_lines(findings: Array) -> PackedStringArray:
    var out := PackedStringArray()
    var groups := by_kind(findings)
    for k in KIND_ORDER:
        if not groups.has(k):
            continue
        var list: Array = groups[k]
        out.append("%s (%d)" % [KIND_LABEL.get(k, k), list.size()])
        for f in list:
            out.append("  " + f.to_line())
    # A kind that was added to checks.gd but not to KIND_ORDER would silently
    # vanish from every report. Emit it rather than lose it.
    for k in groups.keys():
        if KIND_ORDER.has(k):
            continue
        var extra: Array = groups[k]
        out.append("%s (%d)" % [KIND_LABEL.get(k, k), extra.size()])
        for f in extra:
            out.append("  " + f.to_line())
    return out


static func summary(findings: Array, scenes_checked: int, ms: int) -> String:
    var c := counts(findings)
    if c["total"] == 0:
        return "%d scene(s) checked in %dms - nothing to report" % [scenes_checked, ms]
    return "%d scene(s) checked in %dms - %d fail, %d warn" % [
        scenes_checked, ms, c["fail"], c["warn"]]



## Only these two kinds are decided by a pair of colours. The rest never set
## fg/bg, and emitting their zero value as "000000" would put a colour nobody
## measured into a file a build server reads as data.
const COLOUR_KINDS := ["contrast", "state_contrast"]




## Removes a temporary file after a failure. Never touches anything else.
static func _discard(tmp: String) -> void:
    var d := DirAccess.open(tmp.get_base_dir())
    if d != null and d.file_exists(tmp.get_file()):
        d.remove(tmp.get_file())
