class_name SliceHud
extends Node
## Vertical-slice HUD (vertical-slice.md §14 / §10 row 11). Pips, dash arc and
## Sense marks are drawn on the player; the boss arc is drawn on a bound boss
## node (the Warden is not built here). The 70° weak-point gap belongs to the
## Warden's armor ring (row 8), not this bar. The victory card is row 10.
## Hints, the Sense toast and the death overlay are screen labels that keep
## to the left of the script editor.

signal hint_shown(text: String)
signal toast_shown(text: String)

const PIP_RING_RADIUS := 20.0
const PIP_RADIUS := 2.5
const PIP_STROKE := 1.25
const DASH_RADIUS := 24.0
const DASH_STROKE := 2.0
const SENSE_TOP := Vector2(0, 28)
const SENSE_BOTTOM := Vector2(0, 36)
## 4 px diameter (GD on #94).
const SENSE_RADIUS := 2.0
const BOSS_ARC_RADIUS := 78.0
const BOSS_STROKE := 2.0
## 12 o'clock; the arc fills clockwise as hp/max. No gap (GD on #94).
const BOSS_START := -PI * 0.5
const BOSS_FLASH_SEC := 0.15
const BASE_PIPS := 5
const OVERHEAL_PIP_CAP := 5
## Overflow label is shown when hp exceeds this (5 base + 5 extra).
const OVERHEAL_LABEL_AFTER := 10.0
const OVERHEAL_LABEL_SIZE := 10
const PROMPT_SEC := 8.0
const TOAST_SEC := 2.5
const HINT_SIZE := 18
const COLOR_FILL := Color("F2F2F2")
const COLOR_HINT := Color("C9D2E0")
const COLOR_OVERHEAL := Color("C9A7FF")
const COLOR_BOSS := Color("3D7EFF")
const COLOR_DEATH := Color(0.02, 0.03, 0.05, 0.45)
const PROMPT_KB := "E edits."
const PROMPT_PAD := "X edits."
const SENSE_NEAREST := &"nearest_enemy"
const SENSE_ENEMIES := &"enemies_in"
const HINT_TEXT: Array[String] = [
	"The damage number.",
	"One aim, more than one target.",
	"Bend the shot. Put it in a function.",
	"Read player.hp.",
	"Save the file.",
]
const HINT_AFTER: Array[float] = [25.0, 25.0, 30.0, 30.0, 20.0]
## Lessons 1–2 are in S, 3 in A, 4–5 in B.
const HINT_ROOM: Array[StringName] = [&"S", &"S", &"A", &"B", &"B"]
const EDITOR_SAFE := 0.42
const REF_SIZE := Vector2(1280, 720)

var _player: Player
var _progress: SliceProgress
var _editor: ScriptEditorPanel
var _shots: ShotScripts

var _ring: _PlayerRing
var _boss: _BossArc
var _layer: CanvasLayer
var _prompt: Label
var _hint: Label
var _toast: Label
var _death: ColorRect
var _scale := 1.0

var _hp := 5.0
var _max_hp := 5.0
var _dash_left := 0.0
var _dash_cd := 1.5
var _sense_nearest := false
var _sense_enemies := false

var _prompt_left := 0.0
var _toast_left := 0.0
var _toast_text := ""
var _hint_time: Array[float] = [0.0, 0.0, 0.0, 0.0, 0.0]
var _hint_shown: int = 0
var _hint_armed: int = 0b11111
var _hint_current := 0
var _editor_open := false
var _gamepad := false
var _overflow_text := ""
var _overflow_width := 0.0


func _ready() -> void:
	_build()
	set_process(true)
	if not SenseBook.events.granted.is_connected(_on_sense_granted):
		SenseBook.events.granted.connect(_on_sense_granted)
	var vp := get_viewport()
	if vp != null and not vp.size_changed.is_connected(_on_viewport_resized):
		vp.size_changed.connect(_on_viewport_resized)
	_on_viewport_resized()


func _exit_tree() -> void:
	_unbind()
	if SenseBook.events.granted.is_connected(_on_sense_granted):
		SenseBook.events.granted.disconnect(_on_sense_granted)


## Wires the player ring, SliceProgress signals, the editor (so prompts stay
## off its panel), and optional ShotScripts (hints re-arm on a successful save).
func bind(player: Player, progress: SliceProgress, editor: ScriptEditorPanel = null, shots: ShotScripts = null) -> void:
	_unbind()
	_player = player
	_progress = progress
	_editor = editor
	_shots = shots
	if _player != null:
		_hp = _player.health.hp if _player.health != null else 5.0
		_max_hp = _player.health.max_hp if _player.health != null else 5.0
		_dash_cd = maxf(_player.dash_cooldown, 0.001)
		_sync_overheal()
		if _ring.get_parent() != _player:
			if _ring.get_parent() != null:
				_ring.get_parent().remove_child(_ring)
			_player.add_child(_ring)
		_ring.z_index = 1
	if _progress != null:
		if not _progress.hp_changed.is_connected(_on_hp_changed):
			_progress.hp_changed.connect(_on_hp_changed)
		if not _progress.died.is_connected(_on_died):
			_progress.died.connect(_on_died)
		if not _progress.respawned.is_connected(_on_respawned):
			_progress.respawned.connect(_on_respawned)
		if not _progress.lesson_completed.is_connected(_on_lesson_completed):
			_progress.lesson_completed.connect(_on_lesson_completed)
	if _shots != null and not _shots.script_saved.is_connected(_on_script_saved):
		_shots.script_saved.connect(_on_script_saved)
	_sense_nearest = SenseBook.unlocked(SENSE_NEAREST)
	_sense_enemies = SenseBook.unlocked(SENSE_ENEMIES)
	_ring.queue_redraw()
	_prompt_left = PROMPT_SEC
	_sync_prompt_text()
	_prompt.visible = true
	# The editor already has its own "E edits." line; hide it so we do not
	# draw two prompts, and so the gamepad wording can be used here.
	_hide_editor_start_prompt()
	_layout_labels()



## The boss arc is reparented onto the Warden. If that host is freed, the
## arc goes with it; callers must tolerate a missing node.
func _living_boss() -> _BossArc:
	if _boss != null and is_instance_valid(_boss):
		return _boss
	return null


func _ensure_boss() -> _BossArc:
	var boss := _living_boss()
	if boss != null:
		return boss
	_boss = _BossArc.new()
	add_child(_boss)
	return _boss


## Attaches the radius-78 boss arc to `host`. `health` is used when given;
## otherwise a child or property named `health` is tried. Tests can also drive
## the bar with set_boss_health() without a living Warden.
func bind_boss(host: Node, health: Health = null) -> void:
	var boss := _ensure_boss()
	boss.unbind_health()
	if host != null and is_instance_valid(host) and boss.get_parent() != host:
		if boss.get_parent() != null:
			boss.get_parent().remove_child(boss)
		host.add_child(boss)
	if health == null and host != null and is_instance_valid(host):
		var node := host.get_node_or_null("Health")
		if node is Health:
			health = node
		elif host is Player:
			health = (host as Player).health
	boss.bind_health(health)
	boss.queue_redraw()


func unbind_boss() -> void:
	var boss := _living_boss()
	if boss == null:
		return
	boss.unbind_health()
	boss.clear()
	if boss.get_parent() != self:
		if boss.get_parent() != null:
			boss.get_parent().remove_child(boss)
		add_child(boss)
	boss.queue_redraw()


func set_boss_health(hp: float, max_hp: float) -> void:
	var boss := _living_boss()
	if boss == null:
		return
	boss.set_health(hp, max_hp)


func notify_boss_phase_changed() -> void:
	var boss := _living_boss()
	if boss == null:
		return
	boss.flash()


func is_boss_bar_visible() -> bool:
	var boss := _living_boss()
	return boss != null and boss.is_shown()


func boss_fraction() -> float:
	var boss := _living_boss()
	return 0.0 if boss == null else boss.fraction()


func pip_filled(index: int) -> bool:
	# 0-based pips inside max_hp. Filled when hp covers that pip.
	return _hp + 0.0001 >= float(index + 1)


func overheal_pips() -> int:
	return mini(maxi(floori(_hp - _max_hp + 0.0001), 0), OVERHEAL_PIP_CAP)


## N for the "+N" label: hp past the 10 drawn pips. Zero when hp <= 10.
func overheal_overflow() -> int:
	return maxi(floori(_hp - OVERHEAL_LABEL_AFTER + 0.0001), 0)


func overheal_overflow_text() -> String:
	return _overflow_text


func _sync_overheal() -> void:
	var n := overheal_overflow()
	_overflow_text = "+%d" % n if n > 0 else ""
	_overflow_width = 0.0
	if _overflow_text.is_empty():
		return
	var font := ThemeDB.fallback_font
	if font == null:
		return
	_overflow_width = font.get_string_size(_overflow_text, HORIZONTAL_ALIGNMENT_LEFT, -1, OVERHEAL_LABEL_SIZE).x


func dash_fraction() -> float:
	if _dash_left <= 0.0:
		return 1.0
	return clampf(1.0 - _dash_left / _dash_cd, 0.0, 1.0)


func dash_visible() -> bool:
	return _dash_left > 0.0


func sense_filled(id: StringName) -> bool:
	if id == SENSE_NEAREST or id == &"sense.nearest_enemy":
		return _sense_nearest
	if id == SENSE_ENEMIES or id == &"sense.enemies_in":
		return _sense_enemies
	return false


func hint_text() -> String:
	return _hint.text if _hint.visible else ""


func toast_text() -> String:
	return _toast_text if _toast.visible else ""


func prompt_text() -> String:
	return _prompt.text if _prompt.visible else ""


func death_overlay_visible() -> bool:
	return _death.visible


func _process(delta: float) -> void:
	if not is_finite(delta) or delta < 0.0:
		return
	_tick_dash()
	_tick_prompt(delta)
	_tick_toast(delta)
	_tick_hints(delta)
	_tick_editor_layout()
	var boss := _living_boss()
	if boss != null:
		boss.tick(delta)


func _tick_dash() -> void:
	if _player == null or not is_instance_valid(_player):
		return
	var left := _player.get_dash_cooldown_left()
	if not is_equal_approx(left, _dash_left):
		_dash_left = left
		_ring.queue_redraw()


func _tick_prompt(delta: float) -> void:
	if _prompt_left <= 0.0:
		return
	_prompt_left -= delta
	_sync_prompt_text()
	if _prompt_left <= 0.0:
		_prompt.hide()
		_prompt.text = ""


func _sync_prompt_text() -> void:
	if _prompt_left <= 0.0:
		return
	var pad := InputDevice.is_gamepad()
	if pad == _gamepad and _prompt.visible:
		return
	_gamepad = pad
	_prompt.text = PROMPT_PAD if pad else PROMPT_KB
	_prompt.visible = true


func _tick_toast(delta: float) -> void:
	if _toast_left <= 0.0:
		return
	_toast_left -= delta
	if _toast_left <= 0.0001:
		_toast.hide()
		_toast_text = ""
		_toast.text = ""


func _tick_hints(delta: float) -> void:
	if _player == null or not is_instance_valid(_player):
		return
	var room := SliceLayout.room_at(_player.global_position)
	# Only the earliest incomplete lesson in this room accumulates time, so
	# two S-room hints with the same wait cannot overwrite each other.
	var chosen := -1
	for i in range(HINT_TEXT.size()):
		var lesson := i + 1
		if _progress != null and _progress.is_lesson_done(lesson):
			if _hint_current == lesson:
				_hide_hint()
			continue
		if (_hint_armed & (1 << i)) == 0:
			continue
		if room != HINT_ROOM[i]:
			_hint_time[i] = 0.0
			continue
		chosen = i
		break
	if chosen < 0:
		return
	_hint_time[chosen] += delta
	if _hint_time[chosen] >= HINT_AFTER[chosen] and (_hint_shown & (1 << chosen)) == 0:
		_show_hint(chosen + 1)


func _tick_editor_layout() -> void:
	var open := _editor != null and _editor.is_open()
	if open == _editor_open:
		return
	_editor_open = open
	_layout_labels()


func _show_hint(lesson: int) -> void:
	var i := lesson - 1
	_hint_shown |= 1 << i
	_hint_armed &= ~(1 << i)
	_hint_current = lesson
	_hint.text = HINT_TEXT[i]
	_hint.visible = true
	hint_shown.emit(HINT_TEXT[i])


func _hide_hint() -> void:
	_hint_current = 0
	_hint.visible = false
	_hint.text = ""


func _on_lesson_completed(id: int) -> void:
	if _hint_current == id:
		_hide_hint()


func _on_script_saved(_file_name: String, _origin: StringName) -> void:
	# A successful save re-arms any incomplete lesson's hint.
	for i in range(HINT_TEXT.size()):
		var lesson := i + 1
		if _progress != null and _progress.is_lesson_done(lesson):
			continue
		_hint_armed |= 1 << i
		_hint_shown &= ~(1 << i)
		_hint_time[i] = 0.0
	if _hint_current != 0:
		_hide_hint()


func _on_hp_changed(hp: float, max_hp: float) -> void:
	_hp = hp
	_max_hp = max_hp
	_sync_overheal()
	_ring.queue_redraw()


func _on_died() -> void:
	_death.visible = true


func _on_respawned(_at: Vector2) -> void:
	_death.visible = false
	if _player != null and _player.health != null:
		_hp = _player.health.hp
		_max_hp = _player.health.max_hp
		_sync_overheal()
		_ring.queue_redraw()


func _on_sense_granted(id: StringName, _level: int) -> void:
	var key := StringName(String(id).trim_prefix("sense."))
	if key == SENSE_NEAREST:
		_sense_nearest = true
		_show_toast("sense.nearest_enemy")
	elif key == SENSE_ENEMIES:
		_sense_enemies = true
		_show_toast("sense.enemies_in")
	_ring.queue_redraw()


func _show_toast(text_value: String) -> void:
	_toast_text = text_value
	_toast.text = text_value
	_toast.visible = true
	_toast_left = TOAST_SEC
	toast_shown.emit(text_value)


func _on_viewport_resized() -> void:
	var vp := get_viewport()
	if vp == null:
		return
	var size := vp.get_visible_rect().size
	if size.x <= 1.0 or size.y <= 1.0:
		return
	_scale = maxf(minf(size.x / REF_SIZE.x, size.y / REF_SIZE.y), 0.6)
	var font := roundi(HINT_SIZE * _scale)
	_prompt.add_theme_font_size_override("font_size", font)
	_hint.add_theme_font_size_override("font_size", font)
	_toast.add_theme_font_size_override("font_size", font)
	_layout_labels()


func _layout_labels() -> void:
	var vp := get_viewport()
	var width := 1280.0
	if vp != null:
		width = vp.get_visible_rect().size.x
	var right_frac := EDITOR_SAFE if _editor_open else 1.0
	# Keep copy centred in the playable band, left of the editor when it is open.
	_place_bottom(_prompt, width, right_frac, 56.0 * _scale)
	_place_bottom(_hint, width, right_frac, 88.0 * _scale)
	_place_bottom(_toast, width, right_frac, 120.0 * _scale)


func _place_bottom(label: Label, _width: float, right_frac: float, from_bottom: float) -> void:
	label.anchor_left = 0.0
	label.anchor_right = right_frac
	label.anchor_top = 1.0
	label.anchor_bottom = 1.0
	label.offset_left = 0.0
	label.offset_right = 0.0
	label.offset_top = -from_bottom - 22.0 * _scale
	label.offset_bottom = -from_bottom
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER


func _hide_editor_start_prompt() -> void:
	if _editor == null:
		return
	var prompt := _editor.get_node_or_null("Prompt") as Label
	if prompt != null:
		prompt.hide()


func _unbind() -> void:
	if _progress != null and is_instance_valid(_progress):
		if _progress.hp_changed.is_connected(_on_hp_changed):
			_progress.hp_changed.disconnect(_on_hp_changed)
		if _progress.died.is_connected(_on_died):
			_progress.died.disconnect(_on_died)
		if _progress.respawned.is_connected(_on_respawned):
			_progress.respawned.disconnect(_on_respawned)
		if _progress.lesson_completed.is_connected(_on_lesson_completed):
			_progress.lesson_completed.disconnect(_on_lesson_completed)
	if _shots != null and is_instance_valid(_shots) and _shots.script_saved.is_connected(_on_script_saved):
		_shots.script_saved.disconnect(_on_script_saved)
	_progress = null
	_player = null
	_editor = null
	_shots = null


func _build() -> void:
	_ring = _PlayerRing.new()
	_ring.hud = self
	add_child(_ring)
	_boss = _BossArc.new()
	add_child(_boss)
	_layer = CanvasLayer.new()
	_layer.layer = 40
	_layer.name = "SliceHudLayer"
	add_child(_layer)
	_death = ColorRect.new()
	_death.name = "DeathOverlay"
	_death.color = COLOR_DEATH
	_death.set_anchors_preset(Control.PRESET_FULL_RECT)
	_death.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_death.visible = false
	_layer.add_child(_death)
	_prompt = _make_label("Prompt", COLOR_FILL)
	_hint = _make_label("Hint", COLOR_HINT)
	_toast = _make_label("Toast", COLOR_FILL)
	_prompt.visible = false
	_hint.visible = false
	_toast.visible = false


func _make_label(node_name: String, color: Color) -> Label:
	var l := Label.new()
	l.name = node_name
	l.add_theme_color_override("font_color", color)
	l.add_theme_font_size_override("font_size", HINT_SIZE)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_layer.add_child(l)
	return l


## World-space pips, dash arc and Sense marks. Reads the HUD's cached numbers
## so _draw does not allocate or query the tree.
class _PlayerRing:
	extends Node2D
	var hud: SliceHud

	func _draw() -> void:
		if hud == null:
			return
		_draw_pips()
		_draw_dash()
		_draw_senses()

	func _draw_pips() -> void:
		# Base pips keep a fixed TAU/5 spacing, even when overheal pips sit
		# in the midpoints or a "+N" label is showing (GD on #94).
		var n := SliceHud.BASE_PIPS
		var step := TAU / float(n)
		for i in range(n):
			var ang := -PI * 0.5 + step * float(i)
			var at := Vector2(cos(ang), sin(ang)) * SliceHud.PIP_RING_RADIUS
			if hud.pip_filled(i):
				draw_circle(at, SliceHud.PIP_RADIUS, SliceHud.COLOR_FILL)
			else:
				draw_arc(at, SliceHud.PIP_RADIUS, 0.0, TAU, 16, SliceHud.COLOR_FILL, SliceHud.PIP_STROKE, true)
		var extra := hud.overheal_pips()
		for j in range(extra):
			# Midpoints, so the five base pips do not move.
			var ang2 := -PI * 0.5 + step * (float(j) + 0.5)
			var at2 := Vector2(cos(ang2), sin(ang2)) * SliceHud.PIP_RING_RADIUS
			draw_circle(at2, SliceHud.PIP_RADIUS, SliceHud.COLOR_OVERHEAL)
		if hud._overflow_text.is_empty():
			return
		var font := ThemeDB.fallback_font
		if font == null:
			return
		var fs := SliceHud.OVERHEAL_LABEL_SIZE
		# Baseline just below the bottom pip (6 o'clock on the radius-20 ring).
		var at_label := Vector2(-hud._overflow_width * 0.5, SliceHud.PIP_RING_RADIUS + SliceHud.PIP_RADIUS + fs + 1.0)
		draw_string(font, at_label, hud._overflow_text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, SliceHud.COLOR_OVERHEAL)

	func _draw_dash() -> void:
		if not hud.dash_visible():
			return
		var frac := hud.dash_fraction()
		var from := -PI * 0.5
		draw_arc(Vector2.ZERO, SliceHud.DASH_RADIUS, from, from + TAU * frac, 32, SliceHud.COLOR_FILL, SliceHud.DASH_STROKE, true)

	func _draw_senses() -> void:
		_sense_mark(SliceHud.SENSE_TOP, hud._sense_nearest)
		_sense_mark(SliceHud.SENSE_BOTTOM, hud._sense_enemies)

	func _sense_mark(at: Vector2, filled: bool) -> void:
		if filled:
			draw_circle(at, SliceHud.SENSE_RADIUS, SliceHud.COLOR_FILL)
		else:
			draw_arc(at, SliceHud.SENSE_RADIUS, 0.0, TAU, 12, SliceHud.COLOR_FILL, 1.0, true)


class _BossArc:
	extends Node2D
	var _hp := 0.0
	var _max_hp := 900.0
	var _shown := false
	var _flash_left := 0.0
	var _health: Health

	func _ready() -> void:
		z_index = -1
		z_as_relative = true

	func bind_health(health: Health) -> void:
		unbind_health()
		_health = health
		if _health != null:
			if not _health.hp_changed.is_connected(_on_hp_changed):
				_health.hp_changed.connect(_on_hp_changed)
			if not _health.died.is_connected(_on_died):
				_health.died.connect(_on_died)
			set_health(_health.hp, _health.max_hp)

	func unbind_health() -> void:
		if _health != null and is_instance_valid(_health):
			if _health.hp_changed.is_connected(_on_hp_changed):
				_health.hp_changed.disconnect(_on_hp_changed)
			if _health.died.is_connected(_on_died):
				_health.died.disconnect(_on_died)
		_health = null

	func set_health(hp: float, max_hp: float) -> void:
		_hp = hp
		_max_hp = maxf(max_hp, 0.0001)
		_shown = hp > 0.0
		queue_redraw()

	func clear() -> void:
		_hp = 0.0
		_shown = false
		_flash_left = 0.0
		queue_redraw()

	func flash() -> void:
		_flash_left = SliceHud.BOSS_FLASH_SEC
		queue_redraw()

	func tick(delta: float) -> void:
		if _flash_left <= 0.0:
			return
		_flash_left -= delta
		if _flash_left <= 0.0:
			_flash_left = 0.0
		queue_redraw()

	func is_shown() -> bool:
		return _shown

	func fraction() -> float:
		return clampf(_hp / _max_hp, 0.0, 1.0)

	func is_flashing() -> bool:
		return _flash_left > 0.0

	func _on_hp_changed(hp: float, max_hp: float) -> void:
		set_health(hp, max_hp)

	func _on_died() -> void:
		clear()

	func _draw() -> void:
		if not _shown:
			return
		var color := SliceHud.COLOR_FILL if _flash_left > 0.0 else SliceHud.COLOR_BOSS
		var frac := fraction()
		if frac <= 0.0:
			return
		# Godot 2D angles increase clockwise visually (Y is down), so a
		# rising end angle from 12 o'clock fills clockwise.
		var start := SliceHud.BOSS_START
		var points := maxi(roundi(64.0 * frac), 8)
		draw_arc(Vector2.ZERO, SliceHud.BOSS_ARC_RADIUS, start, start + TAU * frac, points, color, SliceHud.BOSS_STROKE, true)
