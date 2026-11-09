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
	_lite_connect()
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
	if res.skipped.is_empty():
		_lite_note()

var _lite_press := Vector2.ZERO
var _lite_dragged := false


func _lite_connect() -> void:
	if is_instance_valid(_log):
		if not _log.meta_clicked.is_connected(_on_lite_meta):
			_log.meta_clicked.connect(_on_lite_meta)
		if not _log.gui_input.is_connected(_on_lite_gui):
			_log.gui_input.connect(_on_lite_gui)


# Godot 4.6+ still sends meta_clicked after a drag that began on the link.
func _on_lite_gui(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_lite_press = event.position
			_lite_dragged = false
		elif event.position.distance_to(_lite_press) > 4.0:
			_lite_dragged = true


func _lite_note() -> void:
	if is_instance_valid(_log):
		var lite_shown: String = _log.get_parsed_text()
		if lite_shown.count("Contrast Audit Lite. Paid full version adds: Check all scenes in one press; Markdown and JSON reports. https://theidlehands.itch.io/contrast-audit") >= 4:
			_log.remove_paragraph(_log.get_character_paragraph(lite_shown.find("Contrast Audit Lite. Paid full version adds: Check all scenes in one press; Markdown and JSON reports. https://theidlehands.itch.io/contrast-audit") + 10))
		_log.append_text("Contrast Audit Lite. Paid full version adds: Check all scenes in one press; Markdown and JSON reports. [url=https://theidlehands.itch.io/contrast-audit]https://theidlehands.itch.io/contrast-audit[/url]\n")


func _on_lite_meta(meta: Variant) -> void:
	if not (meta is String):
		return
	if meta != "https://theidlehands.itch.io/contrast-audit":
		return
	if _lite_dragged:
		return
	if is_instance_valid(_log) and not _log.get_selected_text().is_empty():
		return
	var error := OS.shell_open("https://theidlehands.itch.io/contrast-audit")
	if error != OK and is_instance_valid(_log):
		_say("Could not open the browser. Copy this URL: https://theidlehands.itch.io/contrast-audit")
