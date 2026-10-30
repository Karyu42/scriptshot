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


func _ready() -> void:
	_player.emitter = _bullets.emitter
	_stress.emitter = _bullets.emitter
	_camera.target = _player
	_reticle.player = _player
	_stress.state_changed.connect(func(_e: bool, _n: int) -> void: _update_hud())


func _process(_delta: float) -> void:
	_update_hud()


func _update_hud() -> void:
	var device := "gamepad" if InputDevice.is_gamepad() else "mouse + keyboard"
	var stress := "ON" if _stress.enabled else "off"
	_hud.text = "%d fps   bullets %d / %d   sim %.2f ms\ninput: %s   stress test [F1 / Back]: %s, target %d [F2 / Y]" % [
		Engine.get_frames_per_second(),
		_bullets.alive_count(),
		_bullets.pool.capacity,
		_bullets.last_step_usec / 1000.0,
		device,
		stress,
		_stress.get_target_count(),
	]
