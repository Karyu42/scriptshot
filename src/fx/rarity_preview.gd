class_name RarityPreview
extends Node2D
## Debug gallery for every rarity tier (F9). Not a spawn: the bodies are not
## elites, not bosses, and world generation never reads them. Tiers the game
## does not roll yet are still drawn and can play their sting so QA can hear
## the generator path. Boss audio here is a 2 s preview one-shot, not the
## proximity hum (INCOMPLETE / deferred). F9 again cycles the sting; after
## the last tier, F9 clears the gallery and any grid-warp chunk it registered.


const KEY := KEY_F9

var shown := false
var _index := 0
var _bodies: Array[Node2D] = []
var _cues: Array[RarityCue] = []
var _stings: Array[RaritySting] = []
## Handle from GridWarpFallback.add_chunk. 0 means this gallery holds none.
var _warp_id := 0


func _ready() -> void:
	set_process(false)


func _exit_tree() -> void:
	# Leaving the tree while shown drops only this gallery's warp entry.
	_release_warp()


func _unhandled_input(event: InputEvent) -> void:
	if not event is InputEventKey:
		return
	var key := event as InputEventKey
	if not key.pressed or key.echo or key.keycode != KEY:
		return
	if not shown:
		show_gallery()
	elif _index + 1 < _cues.size():
		_index += 1
		_play(_index)
	else:
		hide_gallery()
	var viewport := get_viewport()
	if viewport != null:
		viewport.set_input_as_handled()


func show_gallery() -> void:
	hide_gallery()
	shown = true
	set_process(true)
	var origin := _origin()
	for i in RarityCue.TIER_COUNT:
		var body := CueBody.new()
		var tier := i
		var boss := tier >= RarityCue.TIER_BOSS_COMMON
		body.position = origin + Vector2(float(i - 2) * 110.0, -150.0)
		body.radius = 48.0 if boss else 16.0
		body.fill = Color("F28FD0") if boss else RegularEnemy.DRIFTER_FILL
		body.label = _label(tier)
		body.z_index = 20
		var cue := RarityCue.new()
		cue.setup(tier)
		cue.body_radius = body.radius
		cue.boss_hue = Color("F28FD0")
		if tier == RarityCue.TIER_ELITE_RARE:
			cue.glyphs = [RarityCue.GLYPH_SQUARE, RarityCue.GLYPH_TRIANGLE]
		elif tier == RarityCue.TIER_ELITE_LEGENDARY:
			cue.signature_name = "Signature"
			cue.glyph = RarityCue.GLYPH_DIAMOND
		else:
			cue.glyph = RarityCue.GLYPH_CIRCLE
		cue.present()
		add_child(body)
		cue.attach(body)
		cue.start_brighten()
		body.cue = cue
		var sting := RaritySting.new()
		sting.tier = tier
		sting.name = "PreviewSting%d" % tier
		body.add_child(sting)
		_bodies.append(body)
		_cues.append(cue)
		_stings.append(sting)
	_register_warp(origin)
	_index = 0
	_play(0)


func hide_gallery() -> void:
	for cue in _cues:
		cue.release()
	for sting in _stings:
		if is_instance_valid(sting):
			sting.shutdown()
	for body in _bodies:
		if is_instance_valid(body):
			body.queue_free()
	_bodies.clear()
	_cues.clear()
	_stings.clear()
	_release_warp()
	shown = false
	_index = 0
	set_process(false)


func _process(delta: float) -> void:
	if not shown:
		return
	for cue in _cues:
		cue.advance(delta)
	if _warp_id != 0:
		GridWarpFallback.advance(delta)


func _play(index: int) -> void:
	if index < 0 or index >= _stings.size():
		return
	var sting := _stings[index]
	if sting != null and is_instance_valid(sting):
		sting.requested = false
		sting.play_sting()
	if index < _cues.size():
		_cues[index].start_brighten()


func _origin() -> Vector2:
	var parent := get_parent()
	if parent == null:
		return Vector2.ZERO
	var player := parent.get_node_or_null("Player") as Node2D
	if player != null:
		return player.global_position
	return global_position


func _register_warp(origin: Vector2) -> void:
	_release_warp()
	var size := float(WorldGen.CHUNK_PX)
	var rect := Rect2(origin - Vector2(size, size) * 0.5, Vector2(size, size))
	_warp_id = GridWarpFallback.add_chunk(rect)


func _release_warp() -> void:
	if _warp_id == 0:
		return
	var id := _warp_id
	_warp_id = 0
	GridWarpFallback.remove_chunk(id)


func _label(tier: int) -> String:
	match tier:
		RarityCue.TIER_ELITE_COMMON:
			return "common elite"
		RarityCue.TIER_ELITE_RARE:
			return "rare elite"
		RarityCue.TIER_ELITE_LEGENDARY:
			return "legendary elite"
		RarityCue.TIER_BOSS_COMMON:
			return "boss common"
		RarityCue.TIER_BOSS_RARE:
			return "boss rare"
		_:
			return "boss legendary"


class CueBody:
	extends Node2D

	var cue: RarityCue
	var fill := Color.WHITE
	var radius := 16.0
	var label := ""


	func _process(_delta: float) -> void:
		queue_redraw()


	func _draw() -> void:
		draw_circle(Vector2.ZERO, radius, fill)
		var width := 2.0
		var color := RegularEnemy.OUTLINE_COLOR
		if cue != null:
			width = cue.current_outline_width()
			color = cue.outline_color()
		draw_arc(Vector2.ZERO, radius, 0.0, TAU, RarityCue.ARC_POINTS, color, width, true)
		if cue != null:
			cue.draw_on(self, radius)
			if cue.beacon_tick_count() > 0:
				cue.draw_beacon(self, Vector2(0.0, -radius - 22.0), Vector2.UP)
		var font := ThemeDB.fallback_font
		if font != null and label != "":
			draw_string(
				font,
				Vector2(-50.0, radius + 36.0),
				label,
				HORIZONTAL_ALIGNMENT_CENTER,
				100.0,
				12,
				Color("E7E9EE")
			)
