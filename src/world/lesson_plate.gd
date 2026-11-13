class_name LessonPlate
extends Node2D
## Room-B speed lesson (vertical-slice §7 lesson 5). A 16×64 plate at (3500, 0).
## Reports the speed of any overlapping player bullet; the checker passes at ≥ 640.

signal overlapped(speed: float)

const SIZE := Vector2(16, 64)
const PASS_SPEED := 640.0
const COLOR := Color("C9D2E0")

## Most recent overlapping player-bullet speed, or -1 if none has touched it yet.
var last_speed := -1.0
var bullets: BulletManager


func world_rect() -> Rect2:
	return Rect2(global_position - SIZE * 0.5, SIZE)


## Tests live player bullets against the plate. Returns the speed of the
## first overlap this call (or -1). Always stores that speed in last_speed
## when an overlap happens, even below PASS_SPEED, so the plate "reports"
## the overlapping bullet's speed.
func scan(manager: BulletManager = null) -> float:
	var bm := manager if manager != null else bullets
	if bm == null or not is_instance_valid(bm) or bm.pool == null:
		return -1.0
	var pool := bm.pool
	var rect := world_rect()
	for i in pool.count:
		if (pool.owner_layer[i] & Layers.PLAYER) == 0:
			continue
		var speed := _overlap_speed(rect, pool.pos[i], pool.radius[i], pool.vel[i])
		if speed >= 0.0:
			last_speed = speed
			overlapped.emit(speed)
			return speed
	return -1.0


func _overlap_speed(rect: Rect2, pos: Vector2, radius: float, vel: Vector2) -> float:
	var closest := Vector2(
		clampf(pos.x, rect.position.x, rect.end.x),
		clampf(pos.y, rect.position.y, rect.end.y)
	)
	if pos.distance_squared_to(closest) > radius * radius:
		return -1.0
	return vel.length()


func _draw() -> void:
	var half := SIZE * 0.5
	var rect := Rect2(-half, SIZE)
	draw_rect(rect, Color(COLOR, 0.85))
	draw_rect(rect, Color("14161c"), false, 2.0)
