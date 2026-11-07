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
## bullets, weapon) and only resets the player's hp to max. It happens at
## RespawnPoints.get_respawn_position(): the last cleared boss arena, else the origin.
@export var respawn_delay := 1.5
## Save slot. Empty, or the player default, means SaveGame.resolved_path():
## the player slot in the game, and the GUT throwaway slot while tests run.
## Set a different path before the node enters the tree to use another file.
@export var save_path := ""

var _respawn_timer := 0.0
var _herald: HeraldArm
var _chunks: ChunkStream
var _save: SaveGame


func _ready() -> void:
	_player.emitter = _bullets.emitter
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
	_player.died.connect(func() -> void: _respawn_timer = respawn_delay)
	_stress.state_changed.connect(func(_e: bool, _n: int) -> void: _update_hud())


func _bind_open_world() -> void:
	var ground := get_node_or_null("OpenGround") as OpenGround
	if ground != null:
		ground.camera = _camera
	_herald = get_node_or_null("HeraldArm") as HeraldArm
	var dummies := get_node_or_null("Dummies")
	if _herald != null and dummies != null:
		_herald.bind(_player, dummies)
	_chunks = get_node_or_null("ChunkStream") as ChunkStream
	if _chunks == null:
		return
	_save = SaveGame.load_from(_slot_path())
	_chunks.seed = _save.world_seed
	_chunks.load_absent(_save.regular_absent)
	_chunks.player = _player
	if _chunks.enemy_scene == null:
		_chunks.enemy_scene = preload("res://scenes/regular_enemy.tscn")
	_chunks.absent_changed.connect(_on_absent_changed)
	_chunks.update_streaming()
	# The bullet window follows the camera. The sandbox scene has no chunk
	# stream and keeps the fixed rect its walls were built for.
	_bullets.bounds_center = _camera


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


func _exit_tree() -> void:
	_on_absent_changed()


func _process(delta: float) -> void:
	if _respawn_timer > 0.0:
		_respawn_timer -= delta
		if _respawn_timer <= 0.0:
			_player.respawn(RespawnPoints.get_respawn_position())
	_update_hud()


func _update_hud() -> void:
	var device := "gamepad" if InputDevice.is_gamepad() else "mouse + keyboard"
	var stress := "ON" if _stress.enabled else "off"
	var zone := "safe" if _player.global_position.length() <= WorldGen.SAFE_RADIUS else "wild"
	var herald := "sandbox"
	if _herald != null:
		if _herald.armed:
			herald = "armed (%s)" % String(_herald.arm_reason)
		elif _herald.clear_seconds_left >= 0.0:
			herald = "tutorial %.0fs" % _herald.clear_seconds_left
		else:
			herald = "idle"
	var chunk := WorldGen.chunk_of(_player.global_position)
	_hud.text = "%d fps   bullets %d / %d (player %d, enemy %d, dropped %d)   sim %.2f ms   hp %.0f / %.0f   dash %s\ninput: %s   stress test [F1 / Back]: %s, target %d [F2 / Y]\nzone %s   herald %s   chunk %d,%d  tier %d" % [
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
		zone,
		herald,
		chunk.x,
		chunk.y,
		WorldGen.chunk_tier(chunk.x, chunk.y),
	]
