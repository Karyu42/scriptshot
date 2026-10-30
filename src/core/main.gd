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
@onready var _turrets: Node = $Turrets
@onready var _mirrors: Node = $Mirrors

## Seconds between dying and respawning. The respawn keeps everything (enemies,
## bullets, weapon) and only resets the player's hp to max. It happens at
## RespawnPoints.get_respawn_position(): the last cleared boss arena, else the origin.
@export var respawn_delay := 1.5

var _respawn_timer := 0.0


func _ready() -> void:
	_player.emitter = _bullets.emitter
	_stress.emitter = _bullets.emitter
	_camera.target = _player
	_reticle.player = _player
	for turret: Turret in _turrets.get_children():
		turret.emitter = _bullets.emitter
		turret.target = _player
	for mirror: Mirror in _mirrors.get_children():
		mirror.target = _player
	_player.died.connect(func() -> void: _respawn_timer = respawn_delay)
	_stress.state_changed.connect(func(_e: bool, _n: int) -> void: _update_hud())


func _process(delta: float) -> void:
	if _respawn_timer > 0.0:
		_respawn_timer -= delta
		if _respawn_timer <= 0.0:
			_player.respawn(RespawnPoints.get_respawn_position())
	_update_hud()


func _update_hud() -> void:
	var device := "gamepad" if InputDevice.is_gamepad() else "mouse + keyboard"
	var stress := "ON" if _stress.enabled else "off"
	_hud.text = "%d fps   bullets %d / %d (dropped %d)   sim %.2f ms   hp %.0f / %.0f   dash %s\ninput: %s   stress test [F1 / Back]: %s, target %d [F2 / Y]" % [
		Engine.get_frames_per_second(),
		_bullets.pool.count,
		_bullets.pool.capacity,
		_bullets.pool.dropped_total,
		_bullets.last_step_usec / 1000.0,
		_player.health.hp,
		_player.health.max_hp,
		"ready" if _player.state.can_dash() else "%.1fs" % _player.get_dash_cooldown_left(),
		device,
		stress,
		_stress.get_target_count(),
	]
