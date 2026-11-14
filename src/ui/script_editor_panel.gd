class_name ScriptEditorPanel
extends CanvasLayer
## The in-game script editor (vertical-slice §6.3, §7): a Lua CodeEdit beside
## the arena, the starter palette, the shots/ file picker, one plain-language
## line for problems, and the shard count in the footer.
##
## E (action `script_editor`; gamepad X) opens it. Esc or the Close button
## closes it; E types an "e" while it is open, but the opening press (and its
## repeats) is consumed and does not type into the buffer. While open, time
## runs at OPEN_TIME_SCALE (the world keeps moving) and the player reads no
## input; it is 1 again when the editor shuts. Ctrl+S or Ctrl+Enter saves: the file is
## written to shots/ and the weapon reloads at the next frame boundary through
## ShotScripts. A file that does not load leaves the last good weapon firing,
## and the line says so ("line 4: expected ')'. Still running the last good
## script."), with a marker on that line. The stack and the original message
## are behind the "details" toggle.
##
## Runtime errors and script warnings from play are polled a few times a
## second (never per error), merged by kind and line, and shown with a count.
##
## Sense unlocks (vertical-slice §6.3), on SenseBook.events `granted` at
## level 1: a one-time toast (`sense.nearest_enemy`), the palette refresh (the
## homing row unlocks), the name highlighted in autocomplete until a saved
## script uses it (mark_fresh_names), and the Sense's Codex page: one screen in
## this panel with an annotated, runnable snippet (Insert puts it in the
## editor). The page opens once, the next time the editor is open; the Codex
## button lists every earned page after that. No modal. A save that restores a
## Sense quietly (SenseBook.bind_save) does none of this.

signal opened
signal closed
## Emitted after a save's load ran (deferred), with whether it took.
signal applied(ok: bool)

## Time scale while the editor is open (Q5 option A; Q5 is still open).
const OPEN_TIME_SCALE := 0.15
## How long the "E edits." prompt shows after the game starts, in seconds.
const PROMPT_SEC := 8.0
const NEW_FILE_ITEM := "+ new file"
## How long a toast ("shots/foo.lua saved (not equipped)") stays up.
const TOAST_SEC := 2.5

const LUA_KEYWORDS: PackedStringArray = [
	"and", "break", "do", "else", "elseif", "end", "false", "for", "function", "goto", "if", "in",
	"local", "nil", "not", "or", "repeat", "return", "then", "true", "until", "while",
]
## Globals of the shot API and the Lua library tables (docs/scripting/api.md).
const API_GLOBALS: PackedStringArray = [
	"sense", "spawn", "wait", "player", "ctx", "state", "vec2", "rad", "PI", "TAU", "reflect_bullet",
	"math", "string", "table", "utf8", "coroutine", "os", "print", "pairs", "ipairs", "type",
	"tostring", "tonumber", "select", "error", "assert", "pcall", "xpcall", "setmetatable",
	"getmetatable", "next", "rawget", "rawset", "rawlen", "rawequal", "load", "self",
]
## Weapon fields and callbacks, ctx, spawn{} fields, bullet handle `b`, hit
## table and batch view `v`.
const API_MEMBERS: PackedStringArray = [
	"name", "cooldown", "speed", "lifetime", "damage", "radius", "angle", "spin", "accel", "pos",
	"on_fire", "on_spawn", "on_hit", "can_hit", "on_death", "on_despawn", "on_expire", "on_wall", "on_batch",
	"on_tick", "aim", "aim_dir", "time", "shot_count", "pressed", "just_pressed", "just_released", "held_time",
	"id", "x", "y", "vx", "vy", "set_velocity", "spawn_child",
	"n", "dt", "px", "py", "age", "pa", "pb", "owner", "kill", "teleport", "nearest_enemy", "enemies_in",
	"kind", "alive",
]
## Senses in api.md order, for autocomplete. Locked ones are listed grey with
## how they are found.
const SENSE_NAMES: PackedStringArray = ["nearest_enemy", "enemies_in", "enemy_bullets", "terrain", "boss", "world"]
const SENSE_LOCK_HINTS := {"nearest_enemy": "3 kills"}
const SENSE_LOCK_HINT_DEFAULT := "found at: ???"
## Codex pages, one per Sense with a page: res://scripting/codex/<id>.lua.txt
## (text, not `.lua`: see ScriptLibrary.BUNDLED_EXT).
const CODEX_DIR := "res://scripting/codex"
const POLL_SEC := 0.25
## Errors and warnings shown at once; the rest are summarised in one row.
const MAX_ROWS := 8
## Left edge of the editor panel, as a fraction of the viewport. The toast
## sits to the left of this while the editor is open so it does not cover
## the details or the footer.
const EDITOR_ANCHOR_LEFT := 0.42

const COLOR_BG := Color(0.0784314, 0.0862745, 0.109804, 0.94)
const COLOR_PANEL := Color(0.105, 0.115, 0.145, 0.98)
const COLOR_TEXT := Color(0.91, 0.91, 0.94)
const COLOR_DIM := Color(0.55, 0.57, 0.64)
const COLOR_KEYWORD := Color(0.78, 0.6, 0.98)
const COLOR_API := Color(0.45, 0.82, 0.95)
const COLOR_STRING := Color(0.6, 0.85, 0.55)
const COLOR_NUMBER := Color(1.0, 0.72, 0.42)
const COLOR_COMMENT := Color(0.45, 0.48, 0.55)
const COLOR_ERROR := Color(1.0, 0.45, 0.42)
const COLOR_WARN := Color(1.0, 0.8, 0.4)
const COLOR_OK := Color(0.55, 0.9, 0.6)
const COLOR_FRESH := Color(1.0, 0.9, 0.35)
const COLOR_PROMPT := Color(0.949, 0.949, 0.949)
const LINE_TINT := Color(1.0, 0.35, 0.3, 0.12)

var shots: ShotScripts
## The shots/ file in the editor (what Save writes).
var file_name := ScriptLibrary.DEFAULT_FILE
## Returns the save's shard count for the footer (read-only). Set by Main.
var shards_source := Callable()
## Problems from the last load (compile / load), then from play.
var load_problems: Array[ScriptProblem] = []
var runtime_problems: Array[ScriptProblem] = []
var show_details := false

var _root: Control
var _frame: Control
var _details_pad: MarginContainer
var _code: CodeEdit
var _title: Label
var _status: Label
var _footer: Label
var _prompt: Label
var _toast: Label
var _toast_until_msec := 0
var _starters: OptionButton
var _files: OptionButton
var _list: ItemList
var _details_toggle: CheckButton
var _details: Label
var _save_button: Button
var _highlighter: CodeHighlighter
var _marker_icon: Texture2D
var _marker_gutter := -1
var _marked_lines: PackedInt32Array = []
var _open := false
## True after the editor is opened by the action key, until that key is
## released: swallow the press and its repeats so they do not type, and
## delay CodeEdit focus until keyup.
var _swallow_open_key := false
var _time_scale_before := 1.0
var _next_poll_msec := 0
var _prompt_until_msec := 0
var _seen_warn_rev := -1
var _seen_errors := -1
var _warn_base: Dictionary[String, int] = {}
var _starter_ids: PackedStringArray = []
var _file_names: PackedStringArray = []
var _fresh_names: PackedStringArray = []
var _codex_button: Button
var _codex_box: VBoxContainer
var _codex_title: Label
var _codex_view: CodeEdit
## Sense id of the page on screen, "" when the code is showing.
var _codex_page := ""
## Pages earned this session that have not been shown yet (oldest first).
var _codex_unread: PackedStringArray = []
## Text of file_name as last loaded or saved, to tell unsaved edits apart.
var _clean_text := ""


func _init() -> void:
	layer = 50
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build()


func _ready() -> void:
	SenseBook.events.granted.connect(_on_sense_granted)
	_root.hide()
	_prompt_until_msec = Time.get_ticks_msec() + int(PROMPT_SEC * 1000.0)


func _exit_tree() -> void:
	if SenseBook.events.granted.is_connected(_on_sense_granted):
		SenseBook.events.granted.disconnect(_on_sense_granted)
	if _open:
		close()


## Connects the panel to the player's shots and shows the selected file.
func bind(shot_scripts: ShotScripts) -> void:
	shots = shot_scripts
	shots.weapon_swapped.connect(_on_weapon_swapped)
	shots.load_failed.connect(_on_load_failed)
	shots.script_saved.connect(_on_script_saved)
	shots.unequipped_file_saved.connect(_on_unequipped_file_saved)
	file_name = shots.selected
	_refresh_files()
	_show_file(file_name)
	load_problems.clear()
	if shots.problem != null:
		load_problems.append(shots.problem)
		_status_text(shots.problem.headline(shots.has_script()), COLOR_ERROR)
	else:
		load_problems.append_array(shots.warnings)
	_reset_warning_base()
	_refresh_title()
	_refresh_problems()


func is_open() -> bool:
	return _open


func text() -> String:
	return _code.text


## True when the editor holds edits that were not saved.
func is_dirty() -> bool:
	return _code.text != _clean_text


## Replaces the editor text as one undoable edit.
func set_text(value: String) -> void:
	if _code.text == "":
		_code.text = value
		_code.clear_undo_history()
		return
	_code.begin_complex_operation()
	_code.select_all()
	_code.delete_selection()
	_code.insert_text_at_caret(value)
	_code.end_complex_operation()
	_code.set_caret_line(0)
	_code.set_caret_column(0)


func toggle() -> void:
	if _open:
		close()
	else:
		open()


func open() -> void:
	if _open:
		return
	_open = true
	_root.show()
	_prompt.hide()
	_prompt_until_msec = 0
	_time_scale_before = Engine.time_scale
	Engine.time_scale = OPEN_TIME_SCALE
	_set_player_blocked(true)
	_set_ui_cursor(true)
	_refresh_starters()
	_refresh_files()
	_refresh_codex_button()
	poll_now()
	_swallow_open_key = false
	_code.grab_focus()
	if not _codex_unread.is_empty():
		show_codex(_codex_unread[0])
	_place_toast()
	opened.emit()


func close() -> void:
	if not _open:
		return
	_open = false
	_root.hide()
	# The victory card owns time scale 0. Restoring here would resume the
	# world under the card (Esc while the editor was open when it appeared).
	if not _victory_card_up():
		Engine.time_scale = _time_scale_before if _time_scale_before != OPEN_TIME_SCALE else 1.0
	_set_player_blocked(false)
	_set_ui_cursor(false)
	_swallow_open_key = false
	_place_toast()
	closed.emit()


## Saves the editor text to shots/<file_name>; ShotScripts loads it at the
## next frame boundary and the result arrives through its signals.
func request_save() -> bool:
	if shots == null:
		return false
	if not shots.save(file_name, _code.text, ShotScripts.ORIGIN_EDITOR):
		_status_text("Could not write %s." % ScriptLibrary.display_path(file_name), COLOR_ERROR)
		return false
	_clean_text = _code.text
	_note_used_names(_code.text)
	_status_text("Saving…", COLOR_DIM)
	return true


func _on_script_saved(saved: String, origin: StringName) -> void:
	# An outside edit to the open file replaces the text unless the player
	# has unsaved changes here.
	if origin == ShotScripts.ORIGIN_FILE and saved == file_name and not is_dirty():
		_show_file(saved)


func _on_weapon_swapped(swapped: String, origin: StringName) -> void:
	if swapped != file_name and origin != ShotScripts.ORIGIN_START:
		return
	load_problems.clear()
	# Non-fatal notes from this load (what the `state` copy dropped or cut).
	load_problems.append_array(shots.warnings)
	runtime_problems.clear()
	_reset_warning_base()
	var via := " (changed on disk)" if origin == ShotScripts.ORIGIN_FILE else ""
	_status_text("Saved%s. Running %s." % [via, shots.weapon.title], COLOR_OK)
	_refresh_title()
	_refresh_problems()
	applied.emit(true)


func _on_load_failed(failed: String, problem: ScriptProblem, _origin: StringName) -> void:
	if failed != file_name:
		return
	load_problems.clear()
	load_problems.append(problem)
	_status_text(problem.headline(shots.has_script()), COLOR_ERROR)
	_refresh_title()
	_refresh_problems()
	applied.emit(false)


## The status line under the code ("line 4: … Still running the last good
## script." after a failed save).
func status_text() -> String:
	return _status.text


## All problems the panel would list right now, load problems first.
func problems() -> Array[ScriptProblem]:
	var out: Array[ScriptProblem] = []
	out.append_array(load_problems)
	out.append_array(runtime_problems)
	return out


## Problems from play since the last load (for the HUD badge).
func runtime_problem_total() -> int:
	var n := 0
	for p in runtime_problems:
		n += p.count
	return n


## Lines (1-based) that carry a problem marker in the gutter.
func marked_lines() -> PackedInt32Array:
	return _marked_lines.duplicate()


## Moves the caret to `line` (1-based) and shows it.
func jump_to_line(line: int) -> void:
	if line <= 0:
		return
	var l := clampi(line - 1, 0, _code.get_line_count() - 1)
	_code.set_caret_line(l)
	_code.set_caret_column(_code.get_line(l).length())
	_code.center_viewport_to_caret()
	_code.grab_focus()


## Palette: puts starter `id` in the editor (one undo step; not saved). False
## when it is locked.
func load_starter(id: String) -> bool:
	var s := ScriptLibrary.starter(id)
	if s == null or not s.unlocked():
		return false
	set_text(s.source)
	# The buffer is new unsaved text; a load error from the last save would
	# point at the wrong lines and linger in the Problems list.
	load_problems.clear()
	_status_text("Inserted %s. Save (Ctrl+S) to fire it." % s.title, COLOR_DIM)
	_refresh_problems()
	return true


## Shows shots/<name> in the editor (what Save writes to). Does not equip it
## until it is saved.
func open_file(name_value: String) -> void:
	if not ScriptLibrary.valid_name(name_value):
		return
	file_name = name_value
	_refresh_files()
	_show_file(name_value)
	_refresh_title()


## Starts a new file from the editor's text (saved right away).
func new_file() -> String:
	var n := ScriptLibrary.next_free_name()
	if n == "":
		return ""
	file_name = n
	request_save()
	_refresh_files()
	_refresh_title()
	return n


func _show_file(name_value: String) -> void:
	var t := ScriptLibrary.read(name_value)
	if t == "" and not ScriptLibrary.exists(name_value):
		var s := ScriptLibrary.starter(ScriptLibrary.DEFAULT_STARTER)
		t = s.source if s != null else ""
	set_text(t)
	_clean_text = t if ScriptLibrary.exists(name_value) else ""


## Names highlighted (autocomplete first, in COLOR_FRESH; the code
## highlighter too) until a saved script uses them. A new Sense marks its name.
func mark_fresh_names(names: PackedStringArray) -> void:
	for n in names:
		if not _fresh_names.has(n):
			_fresh_names.append(n)
	_apply_highlight_colors()


func fresh_names() -> PackedStringArray:
	return _fresh_names.duplicate()


## A save whose text uses a fresh name ends its highlight ("first use").
func _note_used_names(source: String) -> void:
	var kept := PackedStringArray()
	for n in _fresh_names:
		if not _uses_name(source, n):
			kept.append(n)
	if kept.size() == _fresh_names.size():
		return
	_fresh_names = kept
	_rebuild_highlighter()


static func _uses_name(source: String, name_value: String) -> bool:
	return RegEx.create_from_string("\\b%s\\b" % name_value).search(source) != null


## Autocomplete rows as [display, insert, color], in the order offered:
## earned Senses first (fresh ones in COLOR_FRESH), then the API, the globals,
## the keywords, and the Senses not earned yet (grey, with how they are found).
func completion_entries() -> Array:
	var out: Array = []
	var locked: Array = []
	var fresh: Array = []
	var earned: Array = []
	for n in SENSE_NAMES:
		if SenseBook.unlocked(StringName(n)):
			if _fresh_names.has(n):
				fresh.append([n, n, COLOR_FRESH])
			else:
				earned.append([n, n, COLOR_API])
		else:
			var hint: String = SENSE_LOCK_HINTS.get(n, SENSE_LOCK_HINT_DEFAULT)
			locked.append(["%s  (%s)" % [n, hint], n, COLOR_DIM])
	out.append_array(fresh)
	out.append_array(earned)
	for m in API_MEMBERS:
		if SENSE_NAMES.has(m):
			continue
		out.append([m, m, COLOR_FRESH if _fresh_names.has(m) else COLOR_API])
	for g in API_GLOBALS:
		out.append([g, g, COLOR_API])
	for k in LUA_KEYWORDS:
		out.append([k, k, COLOR_KEYWORD])
	out.append_array(locked)
	return out


# --- Codex ---------------------------------------------------------------------

## Sense ids with a Codex page the player has earned, in SENSE_NAMES order.
func codex_pages() -> PackedStringArray:
	var out := PackedStringArray()
	for n in SENSE_NAMES:
		if SenseBook.unlocked(StringName(n)) and FileAccess.file_exists(_codex_path(n)):
			out.append(n)
	return out


## The page source (an annotated Lua file that runs as a weapon), or "".
static func codex_source(id: String) -> String:
	var path := _codex_path(id)
	if not FileAccess.file_exists(path):
		return ""
	return FileAccess.get_file_as_string(path)


static func _codex_path(id: String) -> String:
	return CODEX_DIR.path_join(id + ScriptLibrary.BUNDLED_EXT)


## Shows the Codex page of Sense `id` in place of the code. False when the
## Sense is not earned or has no page.
func show_codex(id: String) -> bool:
	if not SenseBook.unlocked(StringName(id)):
		return false
	var src := codex_source(id)
	if src == "":
		return false
	_codex_page = id
	var i := _codex_unread.find(id)
	if i >= 0:
		_codex_unread.remove_at(i)
	_codex_title.text = "Codex · sense.%s" % id
	_codex_view.text = src
	_codex_view.clear_undo_history()
	_code.hide()
	_codex_box.show()
	_refresh_codex_button()
	return true


func close_codex() -> void:
	_codex_page = ""
	_codex_box.hide()
	_code.show()
	_refresh_codex_button()


func codex_visible() -> bool:
	return _codex_box.visible


func codex_page() -> String:
	return _codex_page


func codex_text() -> String:
	return _codex_view.text if _codex_box.visible else ""


## Pages earned this session and not yet shown.
func codex_unread() -> PackedStringArray:
	return _codex_unread.duplicate()


## Puts the open page's snippet in the editor (one undo step; not saved).
func insert_codex_snippet() -> bool:
	if _codex_page == "":
		return false
	var src := codex_source(_codex_page)
	if src == "":
		return false
	close_codex()
	set_text(src)
	_status_text("Inserted the Codex snippet. Save (Ctrl+S) to fire it.", COLOR_DIM)
	return true


func _on_codex_pressed() -> void:
	if _codex_box.visible:
		close_codex()
		return
	var pages := codex_pages()
	if pages.is_empty():
		_status_text("The Codex fills as you earn Senses.", COLOR_DIM)
		return
	var next := pages[0]
	if not _codex_unread.is_empty():
		next = _codex_unread[0]
	show_codex(next)


func _refresh_codex_button() -> void:
	if _codex_button == null:
		return
	var n := codex_pages().size()
	_codex_button.text = "Codex" if _codex_unread.is_empty() else "Codex •"
	_codex_button.tooltip_text = "Sense pages you have earned (%d)" % n if n > 0 else "The Codex fills as you earn Senses"


func set_show_details(on: bool) -> void:
	show_details = on
	_details_toggle.set_pressed_no_signal(on)
	_refresh_problems()


func details_visible() -> bool:
	return _details.visible


## The footer text ("shards 3").
func footer_text() -> String:
	return _footer.text


## Reads runtime errors, warnings and the shard count now (the panel also
## does this every POLL_SEC).
func poll_now() -> void:
	_next_poll_msec = Time.get_ticks_msec() + int(POLL_SEC * 1000.0)
	_refresh_footer()
	if shots == null or shots.weapon == null:
		return
	var b := shots.weapon.behavior()
	var errors := b.error_total if b != null else 0
	if errors == _seen_errors and ScriptWarnings.revision == _seen_warn_rev:
		return
	_seen_errors = errors
	_seen_warn_rev = ScriptWarnings.revision
	runtime_problems = _collect_runtime(b)
	_refresh_problems()
	if _status.text.begins_with("Saved") or _status.text == "":
		var first := runtime_problems[0] if not runtime_problems.is_empty() else null
		if first != null and first.kind != ScriptProblem.Kind.WARNING:
			_status_text(first.headline(true), COLOR_ERROR)


func _process(_delta: float) -> void:
	# Real time: the editor slows the game, not its own polling.
	if Time.get_ticks_msec() >= _next_poll_msec:
		poll_now()
	if _prompt.visible and Time.get_ticks_msec() >= _prompt_until_msec:
		_prompt.hide()
	if _toast.visible and Time.get_ticks_msec() >= _toast_until_msec:
		_toast.hide()


## Shows `text_value` bottom centre for TOAST_SEC, whether or not the editor
## is open. A new toast replaces the current one.
func show_toast(text_value: String) -> void:
	_toast.text = text_value
	_place_toast()
	_toast.show()
	_toast_until_msec = Time.get_ticks_msec() + int(TOAST_SEC * 1000.0)


## The toast on screen, "" when there is none.
func toast_text() -> String:
	return _toast.text if _toast.visible else ""


func _on_unequipped_file_saved(changed: String) -> void:
	show_toast(ShotScripts.unequipped_text(changed))
	# The editor may have that file open without equipping it.
	if changed == file_name and not is_dirty():
		_show_file(changed)


## Moves the toast so it stays in the playfield while the editor is open
## (the panel covers the right side, including the details and footer).
func _place_toast() -> void:
	if _toast == null:
		return
	_toast.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_toast.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_toast.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_toast.offset_top = -100
	_toast.offset_bottom = -76
	if _open:
		_toast.anchor_left = 0.0
		_toast.anchor_right = EDITOR_ANCHOR_LEFT
		_toast.offset_left = 12
		_toast.offset_right = -12
	else:
		_toast.anchor_left = 0.0
		_toast.anchor_right = 1.0
		_toast.offset_left = 12
		_toast.offset_right = -12


func _refresh_footer() -> void:
	var n := 0
	if shards_source.is_valid():
		var v: Variant = shards_source.call()
		if v is int:
			n = v
	_footer.text = "shards %d" % n


func _collect_runtime(b: LuaBulletBehavior) -> Array[ScriptProblem]:
	var out: Array[ScriptProblem] = []
	if b != null:
		for cb in b.failed_callbacks():
			var last := b.last_error(cb)
			if last == null:
				continue
			var p := ScriptProblem.from_result(last, shots.weapon.chunk_name, cb)
			p.count = b.error_count(cb)
			out.append(p)
	for key in ScriptWarnings.keys():
		if key.begins_with("LuaBulletBehavior.error."):
			continue
		var n: int = ScriptWarnings.count(key) - _warn_base.get(key, 0)
		if n > 0:
			out.append(ScriptProblem.from_warning(key, ScriptWarnings.last_message(key), n))
	return out


func _reset_warning_base() -> void:
	_warn_base.clear()
	for key in ScriptWarnings.keys():
		_warn_base[key] = ScriptWarnings.count(key)
	_seen_warn_rev = ScriptWarnings.revision
	var b := shots.weapon.behavior() if shots != null and shots.weapon != null else null
	_seen_errors = b.error_total if b != null else 0


func _input(event: InputEvent) -> void:
	if not _open:
		return
	if _swallow_open_key and event.is_action("script_editor"):
		get_viewport().set_input_as_handled()
		if event.is_released():
			_swallow_open_key = false
			_code.grab_focus()
		return
	var key := event as InputEventKey
	if key != null and key.pressed and not key.echo:
		if key.keycode == KEY_ESCAPE and _code.get_code_completion_selected_index() < 0:
			close()
			get_viewport().set_input_as_handled()
			return
		if key.ctrl_pressed and (key.keycode == KEY_ENTER or key.keycode == KEY_KP_ENTER or key.keycode == KEY_S):
			request_save()
			get_viewport().set_input_as_handled()
			return
	var pad := event as InputEventJoypadButton
	if pad != null and pad.pressed and event.is_action("script_editor"):
		close()
		get_viewport().set_input_as_handled()


func _unhandled_input(event: InputEvent) -> void:
	if _open:
		return
	if _victory_card_up():
		return
	if event.is_action_pressed("script_editor"):
		open()
		# open() focuses the code view; take that back until the opening
		# key (and its repeats) is released, or it types into the buffer.
		_swallow_open_key = true
		_code.release_focus()
		get_viewport().set_input_as_handled()


func _victory_card_up() -> bool:
	var tree := get_tree()
	if tree == null:
		return false
	for n in tree.get_nodes_in_group(&"slice_hud"):
		if n != null and is_instance_valid(n) and n.has_method("is_victory_card_up"):
			var up: Variant = n.call("is_victory_card_up")
			if up is bool and up:
				return true
	return false


func _set_player_blocked(on: bool) -> void:
	if shots != null and shots.player != null and is_instance_valid(shots.player):
		shots.player.input_blocked = on


func _set_ui_cursor(on: bool) -> void:
	var device := get_node_or_null("/root/InputDevice")
	if device != null and device.has_method("set_ui_cursor"):
		device.call("set_ui_cursor", on)


# --- layout ---------------------------------------------------------------------

func _build() -> void:
	_root = Control.new()
	_root.name = "Root"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.35)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(dim)

	var panel := PanelContainer.new()
	panel.name = "Panel"
	_frame = panel
	panel.anchor_left = EDITOR_ANCHOR_LEFT
	panel.anchor_right = 1.0
	panel.anchor_top = 0.0
	panel.anchor_bottom = 1.0
	panel.offset_left = 0
	panel.offset_top = 12
	panel.offset_right = -12
	panel.offset_bottom = -12
	var style := StyleBoxFlat.new()
	style.bg_color = COLOR_PANEL
	style.border_color = Color(1, 1, 1, 0.08)
	style.set_border_width_all(1)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(12)
	panel.add_theme_stylebox_override("panel", style)
	_root.add_child(panel)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	panel.add_child(col)

	_title = _label("Script", 15, COLOR_TEXT)
	_title.clip_text = true
	_title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	col.add_child(_title)
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 6)
	col.add_child(top)
	_files = OptionButton.new()
	_files.name = "Files"
	_files.tooltip_text = "Your scripts in the shots/ folder"
	_files.item_selected.connect(_on_file_selected)
	_files.fit_to_longest_item = false
	top.add_child(_files)
	_starters = OptionButton.new()
	_starters.name = "Starters"
	_starters.tooltip_text = "Put a starter script in the editor"
	_starters.item_selected.connect(_on_starter_selected)
	_starters.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_starters.clip_text = true
	top.add_child(_starters)
	_codex_button = Button.new()
	_codex_button.name = "CodexButton"
	_codex_button.text = "Codex"
	_codex_button.pressed.connect(_on_codex_pressed)
	top.add_child(_codex_button)
	_save_button = Button.new()
	_save_button.text = "Save"
	_save_button.tooltip_text = "Save to shots/ and reload (Ctrl+S)"
	_save_button.pressed.connect(func() -> void: request_save())
	top.add_child(_save_button)
	var close_button := Button.new()
	close_button.text = "Close"
	close_button.tooltip_text = "Close the editor (Esc)"
	close_button.pressed.connect(close)
	top.add_child(close_button)

	_code = CodeEdit.new()
	_code.name = "Code"
	_code.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_code.gutters_draw_line_numbers = true
	_code.gutters_zero_pad_line_numbers = false
	_code.indent_size = 2
	_code.indent_use_spaces = true
	_code.indent_automatic = true
	_code.indent_automatic_prefixes = ["{", "(", "["]
	_code.auto_brace_completion_enabled = true
	_code.auto_brace_completion_highlight_matching = true
	_code.auto_brace_completion_pairs = {"(": ")", "[": "]", "{": "}", "\"": "\"", "'": "'"}
	_code.code_completion_enabled = true
	_code.code_completion_prefixes = [".", ":"]
	_code.highlight_current_line = true
	_code.draw_tabs = false
	_code.caret_blink = true
	_code.scroll_past_end_of_file = true
	_code.minimap_draw = false
	_code.delimiter_comments = ["--"]
	_code.delimiter_strings = ["\" \"", "' '"]
	_code.add_theme_font_size_override("font_size", 15)
	_code.add_theme_color_override("background_color", COLOR_BG)
	_code.add_theme_color_override("font_color", COLOR_TEXT)
	_code.add_theme_color_override("line_number_color", COLOR_DIM)
	_code.add_theme_color_override("current_line_color", Color(1, 1, 1, 0.04))
	_code.add_theme_color_override("caret_color", COLOR_TEXT)
	_code.add_theme_color_override("selection_color", Color(0.45, 0.82, 0.95, 0.25))
	var code_style := StyleBoxFlat.new()
	code_style.bg_color = COLOR_BG
	code_style.set_corner_radius_all(4)
	code_style.set_content_margin_all(6)
	_code.add_theme_stylebox_override("normal", code_style)
	_code.add_theme_stylebox_override("focus", code_style)
	_highlighter = _make_highlighter()
	_code.syntax_highlighter = _highlighter
	_marker_icon = _make_marker_icon()
	_marker_gutter = 0
	_code.add_gutter(_marker_gutter)
	_code.set_gutter_name(_marker_gutter, "problems")
	_code.set_gutter_type(_marker_gutter, TextEdit.GUTTER_TYPE_ICON)
	_code.set_gutter_width(_marker_gutter, 10)
	_code.code_completion_requested.connect(_on_completion_requested)
	_code.gui_input.connect(_on_code_gui_input)
	col.add_child(_code)

	_codex_box = VBoxContainer.new()
	_codex_box.name = "Codex"
	_codex_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_codex_box.add_theme_constant_override("separation", 6)
	var codex_head := HBoxContainer.new()
	_codex_box.add_child(codex_head)
	_codex_title = _label("Codex", 14, COLOR_FRESH)
	_codex_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	codex_head.add_child(_codex_title)
	var insert := Button.new()
	insert.name = "InsertSnippet"
	insert.text = "Insert snippet"
	insert.tooltip_text = "Put this snippet in the editor (Ctrl+Z undoes it)"
	insert.pressed.connect(func() -> void: insert_codex_snippet())
	codex_head.add_child(insert)
	var back := Button.new()
	back.text = "Back to script"
	back.pressed.connect(close_codex)
	codex_head.add_child(back)
	_codex_view = CodeEdit.new()
	_codex_view.name = "CodexText"
	_codex_view.editable = false
	_codex_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_codex_view.gutters_draw_line_numbers = true
	_codex_view.minimap_draw = false
	_codex_view.add_theme_font_size_override("font_size", 15)
	_codex_view.add_theme_color_override("background_color", COLOR_BG)
	_codex_view.add_theme_color_override("font_color", COLOR_TEXT)
	_codex_view.add_theme_color_override("font_readonly_color", COLOR_TEXT)
	_codex_view.add_theme_color_override("line_number_color", COLOR_DIM)
	_codex_view.add_theme_stylebox_override("normal", code_style)
	_codex_view.add_theme_stylebox_override("read_only", code_style)
	_codex_view.add_theme_stylebox_override("focus", code_style)
	_codex_view.syntax_highlighter = _make_highlighter()
	_codex_box.add_child(_codex_view)
	_codex_box.hide()
	col.add_child(_codex_box)

	_status = _label("", 13, COLOR_DIM)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(_status)

	var problems_row := HBoxContainer.new()
	col.add_child(problems_row)
	var problems_title := _label("Problems", 13, COLOR_DIM)
	problems_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	problems_row.add_child(problems_title)
	_details_toggle = CheckButton.new()
	_details_toggle.text = "details"
	_details_toggle.toggled.connect(set_show_details)
	problems_row.add_child(_details_toggle)

	_list = ItemList.new()
	_list.name = "Problems"
	_list.custom_minimum_size = Vector2(0, 96)
	_list.auto_height = true
	_list.max_text_lines = 2
	_list.add_theme_font_size_override("font_size", 13)
	_list.add_theme_color_override("font_color", COLOR_TEXT)
	var list_style := StyleBoxFlat.new()
	list_style.bg_color = COLOR_BG
	list_style.set_corner_radius_all(4)
	list_style.set_content_margin_all(4)
	_list.add_theme_stylebox_override("panel", list_style)
	_list.item_clicked.connect(_on_problem_clicked)
	col.add_child(_list)

	_details = _label("", 12, COLOR_DIM)
	_details.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_details.add_theme_constant_override("line_spacing", 2)
	_details.hide()
	_details_pad = MarginContainer.new()
	_details_pad.add_theme_constant_override("margin_top", 6)
	_details_pad.add_theme_constant_override("margin_bottom", 8)
	_details_pad.add_child(_details)
	_details_pad.visible = false
	col.add_child(_details_pad)

	var foot_wrap := VBoxContainer.new()
	foot_wrap.add_theme_constant_override("separation", 8)
	var rule := ColorRect.new()
	rule.color = Color(1, 1, 1, 0.08)
	rule.custom_minimum_size = Vector2(0, 1)
	rule.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	foot_wrap.add_child(rule)
	var foot := HBoxContainer.new()
	foot_wrap.add_child(foot)
	col.add_child(foot_wrap)
	var hint := _label("Esc close · Ctrl+S save · time at 15% while open", 12, COLOR_DIM)
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hint.clip_text = true
	foot.add_child(hint)
	_footer = _label("shards 0", 12, COLOR_DIM)
	_footer.name = "Shards"
	_footer.tooltip_text = "Shards in this save"
	foot.add_child(_footer)

	_prompt = _label("E edits.", 18, COLOR_PROMPT)
	_prompt.name = "Prompt"
	_prompt.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_prompt.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_prompt.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_prompt.offset_top = -64
	_prompt.offset_bottom = -40
	_prompt.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_prompt)

	_toast = _label("", 15, COLOR_PROMPT)
	_toast.name = "Toast"
	_toast.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_toast.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_toast.offset_top = -100
	_toast.offset_bottom = -76
	_toast.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var toast_style := StyleBoxFlat.new()
	toast_style.bg_color = Color(COLOR_PANEL, 0.9)
	toast_style.set_corner_radius_all(4)
	toast_style.content_margin_left = 10
	toast_style.content_margin_right = 10
	toast_style.content_margin_top = 4
	toast_style.content_margin_bottom = 4
	_toast.add_theme_stylebox_override("normal", toast_style)
	_toast.hide()
	add_child(_toast)
	_place_toast()
	_refresh_starters()
	_refresh_problems()


func _label(text_value: String, size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text_value
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l


func _make_highlighter() -> CodeHighlighter:
	var h := CodeHighlighter.new()
	h.number_color = COLOR_NUMBER
	h.symbol_color = Color(0.7, 0.72, 0.8)
	h.function_color = COLOR_TEXT
	h.member_variable_color = COLOR_TEXT
	h.add_color_region("--[[", "]]", COLOR_COMMENT, false)
	h.add_color_region("--", "", COLOR_COMMENT, true)
	h.add_color_region("[[", "]]", COLOR_STRING, false)
	h.add_color_region("\"", "\"", COLOR_STRING, false)
	h.add_color_region("'", "'", COLOR_STRING, false)
	_apply_highlight_colors_to(h)
	return h


func _apply_highlight_colors() -> void:
	_apply_highlight_colors_to(_highlighter)
	_code.syntax_highlighter = null
	_code.syntax_highlighter = _highlighter


## A name left _fresh_names: CodeHighlighter keeps old keyword colours, so
## build it again.
func _rebuild_highlighter() -> void:
	_highlighter = _make_highlighter()
	_code.syntax_highlighter = _highlighter


func _apply_highlight_colors_to(h: CodeHighlighter) -> void:
	for k in LUA_KEYWORDS:
		h.add_keyword_color(k, COLOR_KEYWORD)
	for g in API_GLOBALS:
		h.add_keyword_color(g, COLOR_API)
	for m in API_MEMBERS:
		h.add_member_keyword_color(m, COLOR_API)
		if not LUA_KEYWORDS.has(m) and not API_GLOBALS.has(m):
			h.add_keyword_color(m, COLOR_API)
	for f in _fresh_names:
		h.add_member_keyword_color(f, COLOR_FRESH)
		h.add_keyword_color(f, COLOR_FRESH)


func _make_marker_icon() -> Texture2D:
	var img := Image.create(10, 10, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	for y in 10:
		for x in 10:
			var d := Vector2(x + 0.5, y + 0.5).distance_to(Vector2(5, 5))
			if d <= 3.0:
				img.set_pixel(x, y, COLOR_ERROR)
			elif d <= 3.8:
				img.set_pixel(x, y, Color(COLOR_ERROR, 0.4))
	return ImageTexture.create_from_image(img)


# --- behaviour ---------------------------------------------------------------------

func _refresh_title() -> void:
	var running := shots.weapon.title if shots != null and shots.has_script() else "basic shot"
	_title.text = "%s  ·  running: %s" % [ScriptLibrary.display_path(file_name), running]


func _refresh_files() -> void:
	_files.clear()
	_file_names = ScriptLibrary.list_files()
	if not _file_names.has(file_name):
		_file_names.append(file_name)
	for f in _file_names:
		_files.add_item(f)
	_files.add_item(NEW_FILE_ITEM)
	_files.select(_file_names.find(file_name))


## The file picker's names, in order (tests).
func file_labels() -> PackedStringArray:
	return _file_names.duplicate()


func _on_file_selected(index: int) -> void:
	if index >= 0 and index < _file_names.size():
		open_file(_file_names[index])
	else:
		new_file()


func _status_text(text_value: String, color: Color) -> void:
	_status.text = text_value
	_status.add_theme_color_override("font_color", color)


func _refresh_starters() -> void:
	_starters.clear()
	_starter_ids = PackedStringArray()
	_starters.add_item("Insert starter…")
	_starter_ids.append("")
	for s in ScriptLibrary.starters():
		var label := s.title if s.unlocked() else "%s  (locked: %s)" % [s.title, s.lock_hint()]
		_starters.add_item(label)
		var index := _starters.item_count - 1
		_starters.set_item_disabled(index, not s.unlocked())
		_starters.set_item_tooltip(index, "" if s.unlocked() else "Unlocks with sense.%s" % s.lock_hint().trim_prefix("needs "))
		_starter_ids.append(s.id)
	_starters.select(0)


## Labels of the starter picker, in order (tests).
func starter_labels() -> PackedStringArray:
	var out := PackedStringArray()
	for i in range(1, _starters.item_count):
		out.append(_starters.get_item_text(i))
	return out


func starter_locked(id: String) -> bool:
	var i := _starter_ids.find(id)
	return i < 0 or _starters.is_item_disabled(i)


func _on_starter_selected(index: int) -> void:
	if index > 0 and index < _starter_ids.size():
		load_starter(_starter_ids[index])
	_starters.select(0)


func _on_sense_granted(id: StringName, level_value: int) -> void:
	_refresh_starters()
	if level_value != 1:
		return
	var n := String(id)
	show_toast("sense.%s" % n)
	mark_fresh_names(PackedStringArray([n]))
	if FileAccess.file_exists(_codex_path(n)) and not _codex_unread.has(n):
		_codex_unread.append(n)
	_refresh_codex_button()
	if _open and not _codex_box.visible:
		show_codex(n)


func _refresh_problems() -> void:
	_list.clear()
	var all := problems()
	var shown := 0
	var details := PackedStringArray()
	for p in all:
		if shown >= MAX_ROWS:
			break
		_list.add_item(p.text())
		var i := _list.item_count - 1
		_list.set_item_metadata(i, p.line)
		_list.set_item_custom_fg_color(i, COLOR_WARN if p.kind == ScriptProblem.Kind.WARNING else COLOR_ERROR)
		_list.set_item_tooltip(i, p.details)
		details.append(p.detail_text())
		shown += 1
	if all.size() > shown:
		_list.add_item("…and %d more" % (all.size() - shown))
		_list.set_item_metadata(_list.item_count - 1, 0)
	if all.is_empty():
		_list.add_item("No problems.")
		_list.set_item_metadata(0, 0)
		_list.set_item_custom_fg_color(0, COLOR_DIM)
	_details.text = "\n".join(details)
	_details.visible = show_details and not details.is_empty()
	if _details_pad != null:
		_details_pad.visible = _details.visible
	_mark_lines(all)


func _mark_lines(all: Array[ScriptProblem]) -> void:
	for l in _marked_lines:
		if l - 1 < _code.get_line_count():
			_code.set_line_gutter_icon(l - 1, _marker_gutter, null)
			_code.set_line_background_color(l - 1, Color(0, 0, 0, 0))
	_marked_lines = PackedInt32Array()
	for p in all:
		if p.line <= 0 or p.line > _code.get_line_count() or _marked_lines.has(p.line):
			continue
		_code.set_line_gutter_icon(p.line - 1, _marker_gutter, _marker_icon)
		_code.set_line_background_color(p.line - 1, LINE_TINT)
		_marked_lines.append(p.line)


func _on_problem_clicked(index: int, _at: Vector2, _button: int) -> void:
	var meta: Variant = _list.get_item_metadata(index)
	if meta is int:
		var line_no: int = meta
		jump_to_line(line_no)


func _on_completion_requested() -> void:
	for row: Array in completion_entries():
		var display: String = row[0]
		var insert: String = row[1]
		var color: Color = row[2]
		var kind := CodeEdit.KIND_PLAIN_TEXT if color == COLOR_KEYWORD else CodeEdit.KIND_MEMBER
		_code.add_code_completion_option(kind, display, insert, color)
	_code.update_code_completion_options(false)


## Lua blocks: Enter after `then`, `do`, `else`, `repeat` or a function header
## indents the next line one step.
func _on_code_gui_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.ctrl_pressed or key.shift_pressed or key.alt_pressed:
		return
	if key.keycode != KEY_ENTER and key.keycode != KEY_KP_ENTER:
		return
	if _code.is_in_comment(_code.get_caret_line()) >= 0 or _code.get_code_completion_selected_index() >= 0:
		return
	var line := _code.get_line(_code.get_caret_line())
	if _code.get_caret_column() < line.length():
		return
	var trimmed := line.strip_edges()
	if not _opens_block(trimmed):
		return
	var indent := line.substr(0, line.length() - line.strip_edges(true, false).length())
	_code.insert_text_at_caret("\n" + indent + "  ")
	_code.accept_event()


static func _opens_block(trimmed: String) -> bool:
	if trimmed.ends_with(" then") or trimmed == "then" or trimmed.ends_with(" do") or trimmed == "do":
		return true
	if trimmed == "else" or trimmed == "repeat":
		return true
	return RegEx.create_from_string("(^|[\\s=(,])function\\s*[\\w.:]*\\s*\\([^)]*\\)$").search(trimmed) != null
