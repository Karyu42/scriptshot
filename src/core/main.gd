class_name Main
extends Node2D
## Playable sandbox: wires the player to the bullet system, and hosts the
## bullet stress-test toggle and a debug HUD.

@onready var _player: Player = $Player
@onready var _bullets: BulletManager = $BulletManager
@onready var _stress: BulletStressTest = $StressTest
@onready var _camera: FollowCamera = $FollowCamera
@onready var _reticle: AimReticle = $AimReticle
@onready var _hud: Label = $Hud/Label
## Seconds between dying and respawning. The respawn keeps everything (enemies,
## bullets, weapon) and only resets the player's hp to max. The point is chosen
## when the timer fires: the arena centre if the Warden is already dead, else
## RespawnPoints.get_respawn_position() (last cleared arena, or the origin).
@export var respawn_delay := 1.5
## Save slot. Empty, or the player default, means SaveGame.resolved_path():
## the player slot in the game, and the GUT throwaway slot while tests run.
## Set a different path before the node enters the tree to use another file.
@export var save_path := ""

## The player's scripted weapon (LuaShot), the shots/ files it comes from
## (lesson checkers listen to its script_saved / weapon_swapped signals), and
## the in-game editor.
var weapon: LuaShot
var shot_scripts: ShotScripts
var editor: ScriptEditorPanel
var _respawn_timer := 0.0
var _herald: HeraldArm
var _herald_director: HeraldDirector
var _chunks: ChunkStream
var _save: SaveGame
var _slice: SliceLayout
var _progress: SliceProgress
var _slice_hud: SliceHud


func _ready() -> void:
	_player.emitter = _bullets.emitter
	_bind_script_weapon()
	_stress.emitter = _bullets.emitter
	_camera.target = _player
	_reticle.player = _player
	var turrets := get_node_or_null("Turrets")
	if turrets != null:
		for turret: Turret in turrets.get_children():
			turret.emitter = _bullets.emitter
			turret.target = _player
	var mirrors := get_node_or_null("Mirrors")
	if mirrors != null:
		for mirror: Mirror in mirrors.get_children():
			mirror.target = _player
	_bind_open_world()
	_bind_slice_progress()
	_bind_slice_hud()
	WorldQuery.bind_bullets(_bullets)
	_player.died.connect(func() -> void: _respawn_timer = respawn_delay)
	_stress.state_changed.connect(func(_e: bool, _n: int) -> void: _update_hud())
	GameEvents.run_started.emit()


## Equips shots/<saved file> (shots/default.lua on a fresh save) through
## ShotScripts, and connects the editor. A missing or broken file leaves the
## player on BasicShot (one printed line) until a good save.
func _bind_script_weapon() -> void:
	shot_scripts = ShotScripts.new()
	add_child(shot_scripts)
	shot_scripts.setup(_bullets, _player)
	shot_scripts.start()
	weapon = shot_scripts.weapon
	editor = get_node_or_null("ScriptEditor") as ScriptEditorPanel
	if editor != null:
		editor.shards_source = func() -> int: return _save.shards if _save != null else 0
		editor.bind(shot_scripts)


func _bind_open_world() -> void:
	var ground := get_node_or_null("OpenGround") as OpenGround
	if ground != null:
		ground.camera = _camera
	_herald = get_node_or_null("HeraldArm") as HeraldArm
	var dummies := get_node_or_null("Dummies")
	if _herald != null and dummies != null:
		_herald.bind(_player, dummies)
	# The vertical-slice ribbon: its walls stop bullets too, and procedural
	# anchors inside its footprint are dropped.
	_slice = get_node_or_null("SliceLayout") as SliceLayout
	if _slice != null and not _slice.enabled:
		_slice = null
	if _slice != null:
		_slice.bind_bullets(_bullets)
	_chunks = get_node_or_null("ChunkStream") as ChunkStream
	if _chunks == null:
		return
	_save = SaveGame.load_from(_slot_path())
	_chunks.seed = _save.world_seed
	_chunks.load_absent(_save.regular_absent)
	_chunks.load_elite_kills(_save.elite_kills)
	_chunks.player = _player
	if _slice != null:
		_chunks.footprint = SliceLayout.FOOTPRINT
	if _chunks.enemy_scene == null:
		_chunks.enemy_scene = preload("res://scenes/regular_enemy.tscn")
	if _chunks.elite_scene == null:
		_chunks.elite_scene = preload("res://scenes/elite_enemy.tscn")
	_chunks.absent_changed.connect(_on_absent_changed)
	_chunks.elite_kills_changed.connect(_on_elite_kills_changed)
	_chunks.shard_gained.connect(_on_natural_shard)
	_chunks.update_streaming()
	_herald_director = get_node_or_null("HeraldDirector") as HeraldDirector
	if _herald_director != null and _herald != null:
		_herald_director.bind(_herald, _player, _save)
		_herald_director.slice = _slice
	# The bullet window follows the camera. The sandbox scene has no chunk
	# stream and keeps the fixed rect its walls were built for.
	_bullets.bounds_center = _camera


func _bind_slice_progress() -> void:
	_progress = get_node_or_null("SliceProgress") as SliceProgress
	if _progress == null:
		return
	_progress.bind(_player, get_node_or_null("Dummies"), _slice, _save, shot_scripts, _bullets)


func _bind_slice_hud() -> void:
	_slice_hud = get_node_or_null("SliceHud") as SliceHud
	if _slice_hud == null:
		return
	_slice_hud.bind(_player, _progress, editor, shot_scripts)


func current_save_path() -> String:
	if _save != null:
		return _save.path
	return _slot_path()


func _slot_path() -> String:
	if save_path.is_empty() or save_path == SaveGame.DEFAULT_PATH:
		return SaveGame.resolved_path()
	return save_path


func _on_absent_changed() -> void:
	if _save == null or _chunks == null:
		return
	_save.regular_absent = _chunks.absent_records()
	_save.save()


func _on_elite_kills_changed() -> void:
	if _save == null or _chunks == null:
		return
	_save.elite_kills = _chunks.elite_kill_records()
	_save.save()


func _on_natural_shard() -> void:
	if _save == null:
		return
	_save.shards += 1
	_save.save()


func _exit_tree() -> void:
	WorldQuery.unbind_bullets(_bullets)
	_on_absent_changed()


func _process(delta: float) -> void:
	if _respawn_timer > 0.0:
		_respawn_timer -= delta
		if _respawn_timer <= 0.0:
			_player.respawn(respawn_position())
	_update_hud()


## Picked at respawn time so a trade kill during the delay still lands in E.
func respawn_position() -> Vector2:
	if _progress != null:
		return _progress.respawn_position()
	return RespawnPoints.get_respawn_position()


func _update_hud() -> void:
	var device := "gamepad" if InputDevice.is_gamepad() else "mouse + keyboard"
	var stress := "ON" if _stress.enabled else "off"
	var zone := "safe" if _player.global_position.length() <= WorldGen.SAFE_RADIUS else "wild"
	var herald := "sandbox"
	if _herald_director != null and _herald_director.resolved:
		if _herald_director.herald != null and is_instance_valid(_herald_director.herald) and _herald_director.herald.is_alive():
			herald = "up"
		else:
			herald = "done"
	elif _herald_director != null and _herald_director.counting:
		herald = "in %.0fs" % _herald_director.seconds_left()
	elif _herald != null:
		if _herald.armed:
			herald = "armed (%s)" % String(_herald.arm_reason)
		elif _herald.clear_seconds_left >= 0.0:
			herald = "tutorial %.0fs" % _herald.clear_seconds_left
		else:
			herald = "idle"
	var shards := 0
	if _save != null:
		shards = _save.shards
	var chunk := WorldGen.chunk_of(_player.global_position)
	var script_name := weapon.title if shot_scripts != null and shot_scripts.has_script() else "basic"
	var script_problems := editor.runtime_problem_total() if editor != null else 0
	var script_note := "   %d script problem%s" % [script_problems, "" if script_problems == 1 else "s"] if script_problems > 0 else ""
	_hud.text = "%d fps   bullets %d / %d (player %d, enemy %d, dropped %d)   sim %.2f ms   hp %.0f / %.0f   dash %s\ninput: %s   stress test [F1 / Back]: %s, target %d [F2 / Y]   script [E / X]: %s%s\nzone %s   herald %s   shards %d   chunk %d,%d  tier %d" % [
		Engine.get_frames_per_second(),
		_bullets.alive_count(),
		_bullets.pool.logical_cap,
		_bullets.pool.owner_counts[BulletPool.OWNER_PLAYER],
		_bullets.pool.owner_counts[BulletPool.OWNER_ENEMY],
		_bullets.pool.dropped_total,
		_bullets.last_step_usec / 1000.0,
		_player.health.hp,
		_player.health.max_hp,
		"ready" if _player.state.can_dash() else "%.1fs" % _player.get_dash_cooldown_left(),
		device,
		stress,
		_stress.get_target_count(),
		script_name,
		script_note,
		zone,
		herald,
		shards,
		chunk.x,
		chunk.y,
		WorldGen.chunk_tier(chunk.x, chunk.y),
	]
