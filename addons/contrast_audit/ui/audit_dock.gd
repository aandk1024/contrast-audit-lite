@tool
extends VBoxContainer

## The dock. A thin skin: it reads the controls, calls core/, and prints.
## No rule lives here, so every rule stays testable without an editor.

const Audit := preload("res://addons/contrast_audit/core/audit.gd")
const Checks := preload("res://addons/contrast_audit/core/checks.gd")
const Report := preload("res://addons/contrast_audit/core/report.gd")
const Stage := preload("res://addons/contrast_audit/core/stage.gd")

const MD_PATH := "res://contrast_audit_report.md"
const JSON_PATH := "res://contrast_audit_report.json"

@onready var _level: OptionButton = $LevelRow/Level
@onready var _min_font: SpinBox = $FontRow/MinFont
@onready var _min_target: SpinBox = $TargetRow/MinTarget
@onready var _log: RichTextLabel = $Log

var _busy := false
## The last run, kept so the export buttons write what the buyer just saw
## rather than silently re-running with whatever the settings say now.
var _last: Object = null
var _last_opts: Object = null


func _ready() -> void:
	_level.clear()
	_level.add_item("AA")
	_level.add_item("AAA")
	_level.select(0)
	$CheckOpen.pressed.connect(_on_check_open)
	_say("Ready. Open a saved scene and press \"Check open scene\".")
	_lite_note()
	$CheckAll.queue_free()
	$ExportRow.queue_free()


## Keys, node names and translated strings are arbitrary text. Printed raw
## into a bbcode label, a "[" turns the rest of the line into a tag and the
## report silently loses characters.
func _esc(s: String) -> String:
	return s.replace("[", "[lb]")


func _say(s: String) -> void:
	if _log != null:
		_log.append_text(_esc(s) + "\n")


func _options() -> Object:
	var o = Checks.Options.new()
	o.level = "AAA" if _level.selected == 1 else "AA"
	o.min_font_px = float(_min_font.value)
	o.min_target_px = float(_min_target.value)
	return o


## Every button goes through this. A run takes real frames, and a second
## press part way through would interleave two sets of findings into one
## report - which reads as a result rather than as a bug.
func _refuse_while_busy() -> bool:
	if _busy:
		_say("Still checking - wait for the current run to finish.")
		return true
	return false



func _on_check_open() -> void:
	if _refuse_while_busy():
		return
	var root := get_tree().edited_scene_root if get_tree() != null else null
	if root == null or root.scene_file_path == "":
		_say("No saved scene is open. Open a scene and save it first.")
		return
	await _run(PackedStringArray([root.scene_file_path]))


func _run(scenes: PackedStringArray) -> void:
	_busy = true
	var opts := _options()
	_say("Checking %d scene(s) at WCAG 2.1 %s…" % [scenes.size(), opts.level])
	var res = await Audit.run(scenes, self, opts)
	_busy = false
	_last = res
	_last_opts = opts

	for s in res.skipped:
		_say("  could not measure: " + s)
	for line in Report.to_lines(res.findings):
		_say(line)
	_say(Report.summary(res.findings, res.scenes_checked, res.ms))
	if not res.skipped.is_empty():
		_say("%d scene(s) were not measured - they are not covered by the counts above." % res.skipped.size())

## Lite: say once, in the dock itself, what the full version adds and where it is.
func _lite_note() -> void:
	_say("Contrast Audit Lite. The full version adds: Check all scenes in one press; Markdown and JSON reports (pinned schema for a build server). https://theidlehands.itch.io/contrast-audit")
