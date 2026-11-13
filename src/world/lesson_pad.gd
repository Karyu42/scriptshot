class_name LessonPad
extends Node2D
## Room-B HP lesson (vertical-slice §7 lesson 4). On entry, if the player's
## HP is exactly 5, a 0.6 s ring plays on the player, then try_damage for 1 pip.

signal pip_applied

const WORLD_RECT := Rect2(2700, -80, 160, 160)
const WINDUP := 0.6
const RING_RADIUS := 28.0
const RING_COLOR := Color("C9D2E0AA")

var player: Player
var _inside := false
var _windup := -1.0


func tick(delta: float) -> void:
	if not is_finite(delta) or delta < 0.0:
		return
	if player == null or not is_instance_valid(player) or player.health == null:
		_inside = false
		return
	var now_inside := WORLD_RECT.has_point(player.global_position)
	if now_inside and not _inside:
		_on_entered()
	_inside = now_inside
	if _windup < 0.0:
		queue_redraw()
		return
	_windup = maxf(_windup - delta, 0.0)
	if _windup <= 0.0:
		_windup = -1.0
		player.health.try_damage(1.0)
		pip_applied.emit()
	queue_redraw()


func is_winding() -> bool:
	return _windup >= 0.0


func _on_entered() -> void:
	if not is_equal_approx(player.health.hp, 5.0):
		return
	# Restart the ring on a fresh entry at full HP.
	_windup = WINDUP
	queue_redraw()


func _draw() -> void:
	# The pad itself: a faint square on the floor.
	var local_rect := Rect2(WORLD_RECT.position - global_position, WORLD_RECT.size)
	draw_rect(local_rect, Color("C9D2E033"))
	draw_rect(local_rect, Color("C9D2E088"), false, 2.0)
	if _windup < 0.0 or player == null or not is_instance_valid(player):
		return
	var frac := clampf(_windup / WINDUP, 0.0, 1.0)
	var col := Color(RING_COLOR, RING_COLOR.a * (0.35 + 0.65 * frac))
	draw_arc(to_local(player.global_position), RING_RADIUS, 0.0, TAU, 48, col, 2.0, true)
