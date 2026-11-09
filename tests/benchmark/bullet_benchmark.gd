extends Node
## Headless-friendly bullet benchmark. Keeps N bullets alive in steady state
## (spawning replacements as old ones expire / leave the arena / hit targets),
## runs the full BulletManager.step() every frame including swept collision
## against 32 hurtboxes and 28 static walls, and the MultiMesh buffer fill, and
## reports per-frame times. A tenth of the bullets are fast enough to take the
## swept (anti-tunnelling) path of the collision code. Another tenth pierce
## (3 extra targets), so the pierce sweep and the hit-memory ring are part of
## the measured workload; that choice uses its own RNG and does not consume the
## stream that places the bullets.
##
## Run:  ./tools/run_benchmark.sh            (see README for options)
##       godot --headless --path . res://tests/benchmark/bullet_benchmark.tscn -- --bullets=5000,10000
##
## Options (after `--`):
##   --bullets=5000,10000   bullet counts to test
##   --frames=600           measured frames per count
##   --warmup=120           unmeasured frames per count
##   --floor-bullets=5000   the minimum: HARD FAIL (exit 1) if this count misses the budget
##   --target-bullets=10000 the goal: only a WARN line (exit 0) if this count misses the budget
##   --target-ms=16.6       p95 frame-time budget for both counts
##   --hooked=0.3           share (0..1) of the bullets that carry a no-op on_update hook
##                          (default 0 = no hooked bullets, the original workload; the same
##                          bullet trajectories are simulated at every fraction)
##   --batch=1              every bullet is steered by one on_update_batch callback
##                          (vx += cos(age * 6) * 40 * dt). 0 (default) is the original
##                          workload. This is separate from --hooked; the 22 ms gate stays
##                          on the per-bullet no-op. On the native backend these bullets
##                          live in the sim. On GDScript they stay in the pool.
##   --backend=native       bullet backend: auto (default), gdscript or native.
##                          auto is the native opt-in: --bullet-backend=, then
##                          SCRIPTSHOT_BULLET_BACKEND, then project setting
##                          scriptshot/bullets/backend. Unset stays on gdscript.
##                          --backend=native forces the C++ pool for hook-free
##                          bullets (hooked bullets stay on GDScript).
##   --json=path            also write results as JSON (includes the hooked fraction and backend)
##
## "work" is the cost of one game frame of bullet work (top-up spawns +
## BulletManager.step: kinematics, collision, hooks, despawn, MultiMesh buffer
## fill). The pass/fail verdict uses work p95. "wall" is the interval between
## engine frames; it is informational only, because headless runs are paced at
## roughly 144 Hz (~6.9 ms) regardless of load.
##
## Policy: two checks against the same p95 budget.
##   FLOOR  (--floor-bullets, default 5000): exit code 1 if it misses the budget,
##          or was not actually reached (count not in --bullets, or fewer bullets
##          alive than requested on any measured frame), so a run that quietly
##          simulates less than it claims cannot pass.
##   TARGET (--target-bullets, default 10000): a miss prints a "WARN" line but
##          the exit code stays 0, because the target is a goal, not a gate, and
##          10k p95 is sensitive to how busy the machine is.

const ARENA := Rect2(-1280, -720, 2560, 1440)
const TARGET_COUNT := 32
const FIXED_DELTA := 1.0 / 60.0
const WALL_THICKNESS := 64.0
## Share of bullets that are fast enough to need the swept collision path.
const FAST_FRACTION := 0.1
## Share of bullets spawned with pierce > 0 (see PIERCE_EXTRA). Separate from
## FAST_FRACTION, so some slow bullets take the pierce sweep too.
const PIERCE_FRACTION := 0.1
## Extra targets a piercing benchmark bullet passes through before it is consumed.
const PIERCE_EXTRA := 3

var counts: Array[int] = [5000, 10000]
var frames := 600
var warmup := 120
var floor_bullets := 5000
var target_bullets := 10000
var target_ms := 16.6
var json_path := ""
## Share of the bullets spawned with a no-op on_update hook (see --hooked).
var hooked_fraction := 0.0
## 1 when every bullet is driven by one batch hook (see --batch).
var batch_mode := 0
## "auto", "gdscript" or "native". auto follows SCRIPTSHOT_BULLET_BACKEND.
var backend_preference := "auto"
## Reflector zones added on top of the wall field. 0 leaves the original workload.
## Zones reflect both factions with the pool's reflection cap lifted, so plain
## bullets bounce for the whole run instead of once.
var mirror_count := 0

var _manager: BulletManager
var _rng := RandomNumberGenerator.new()
## Separate stream for the hooked/plain choice: drawing from _rng would change the
## trajectories (and so the numbers) of the hooked = 0 baseline.
var _hook_rng := RandomNumberGenerator.new()
## Separate stream for the pierce / plain choice, same reason as _hook_rng.
var _pierce_rng := RandomNumberGenerator.new()
var _noop_behavior_id := 0
var _batch_behavior_id := 0
var _request := ShotRequest.new()
var _results: Array[Dictionary] = []
var _walls: Array[Rect2] = []
var _min_alive := 0
var _phase_sum := PackedFloat64Array([0.0, 0.0, 0.0, 0.0, 0.0])

var _count_index := -1
var _frame := 0
var _work_ms := PackedFloat64Array()
var _wall_ms := PackedFloat64Array()
var _last_frame_usec := 0
var _current_count := 0


## A hook that does nothing: what the benchmark pays for is the machinery around a
## hooked bullet (the call, the owner context, the post-hook sanitize), not script work.
class NoopHook:
	extends BulletBehavior

	func on_update(_pool: BulletPool, _index: int, _delta: float) -> void:
		pass


## One callback for every bullet. The body is the steering kernel the batch
## API is for: read age, write velocity. Not a per-bullet hook.
class BatchSteer:
	extends BulletBehavior

	func _init() -> void:
		update_mode = UpdateMode.BATCH

	func on_update_batch(batch: BatchView) -> void:
		var vx := batch.vx
		var age := batch.age
		var dt := batch.dt
		for i in batch.n:
			vx[i] = vx[i] + cos(age[i] * 6.0) * 40.0 * dt


func _ready() -> void:
	var arg_error := _parse_args()
	if arg_error != "":
		printerr("[bench] ERROR: %s" % arg_error)
		get_tree().quit(2)
		set_process(false)
		return
	_rng.seed = 20260101
	_hook_rng.seed = 20260102
	_pierce_rng.seed = 20260103
	_manager = BulletManager.new()
	_manager.capacity = 32768
	# The benchmark measures raw simulation cost at any bullet count: lift the
	# game's saturation limits (10k logical cap, enemy reserve) out of the way.
	_manager.logical_cap = _manager.capacity
	_manager.enemy_reserve = 0
	_manager.world_bounds = ARENA.grow(32.0)
	_manager.auto_step = false
	_manager.backend_preference = backend_preference
	add_child(_manager)
	_noop_behavior_id = _manager.register_behavior(NoopHook.new())
	# Only when measuring the batch path. Registering it would mark the pool as
	# having a batch-only behavior and add a check to every hooked bullet.
	if batch_mode > 0:
		_batch_behavior_id = _manager.register_behavior(BatchSteer.new())
	_build_walls()
	_build_mirrors()
	for i in TARGET_COUNT:
		var hb := Hurtbox.new()
		hb.radius = 24.0
		hb.layer = Layers.ENEMY
		hb.position = Vector2(_rng.randf_range(ARENA.position.x, ARENA.end.x), _rng.randf_range(ARENA.position.y, ARENA.end.y))
		add_child(hb)
	print("[bench] Godot %s | backend: %s | renderer: %s | %d hurtboxes, %d walls, %d mirrors | %d warmup + %d measured frames per count | hooked fraction %.2f | batch %d | pierce fraction %.2f (pierce %d)"
		% [Engine.get_version_info().string, _manager.backend, RenderingServer.get_video_adapter_name(), TARGET_COUNT, _walls.size(), mirror_count, warmup, frames, hooked_fraction, batch_mode, PIERCE_FRACTION, PIERCE_EXTRA])
	_next_count()


func _process(_delta: float) -> void:
	var now := Time.get_ticks_usec()
	var wall := (now - _last_frame_usec) / 1000.0 if _last_frame_usec != 0 else 0.0
	_last_frame_usec = now

	var t0 := Time.get_ticks_usec()
	_top_up(_current_count)
	var alive_before_step := _manager.alive_count()
	_manager.step(FIXED_DELTA)
	var work := (Time.get_ticks_usec() - t0) / 1000.0

	_frame += 1
	if _frame > warmup:
		_work_ms.append(work)
		_wall_ms.append(wall)
		for k in _phase_sum.size():
			_phase_sum[k] += _manager.last_phase_usec[k] / 1000.0
		_min_alive = mini(_min_alive, alive_before_step) if _min_alive >= 0 else alive_before_step
	if _frame >= warmup + frames:
		_finish_count()


## Border walls just outside the arena plus a deterministic field of pillars.
func _build_walls() -> void:
	var t := WALL_THICKNESS
	_walls.append(Rect2(ARENA.position.x - t, ARENA.position.y - t, ARENA.size.x + 2.0 * t, t))
	_walls.append(Rect2(ARENA.position.x - t, ARENA.end.y, ARENA.size.x + 2.0 * t, t))
	_walls.append(Rect2(ARENA.position.x - t, ARENA.position.y, t, ARENA.size.y))
	_walls.append(Rect2(ARENA.end.x, ARENA.position.y, t, ARENA.size.y))
	for gx in 6:
		for gy in 4:
			var centre := Vector2(
				ARENA.position.x + ARENA.size.x * (float(gx) + 0.5) / 6.0,
				ARENA.position.y + ARENA.size.y * (float(gy) + 0.5) / 4.0
			)
			var size := Vector2(140.0, 36.0) if (gx + gy) % 2 == 0 else Vector2(36.0, 140.0)
			_walls.append(Rect2(centre - size * 0.5, size))
	for wall in _walls:
		_manager.add_wall(wall)


func _build_mirrors() -> void:
	if mirror_count <= 0:
		return
	# Unlimited, so a bullet that has already bounced still meets the next zone.
	# The default cap of 1 would make this a one-bounce scene.
	_manager.pool.max_reflections = 0
	var cols := maxi(ceili(sqrt(float(mirror_count))), 1)
	for i in mirror_count:
		var zone := Reflector.new()
		zone.radius = 48.0
		zone.mode = Reflector.Mode.REVERSE
		zone.reflects_owners = Layers.PLAYER | Layers.ENEMY
		var col := i % cols
		var row := int(i / cols)
		zone.position = Vector2(
			ARENA.position.x + ARENA.size.x * (float(col) + 0.5) / float(cols),
			ARENA.position.y + ARENA.size.y * (float(row) + 0.5) / float(maxi(ceili(float(mirror_count) / float(cols)), 1))
		)
		add_child(zone)


func _inside_wall(p: Vector2) -> bool:
	for wall in _walls:
		if wall.grow(4.0).has_point(p):
			return true
	return false


func _top_up(n: int) -> void:
	while _manager.alive_count() < n:
		_request.reset()
		var spawn_at := Vector2.ZERO
		for _attempt in 8:
			spawn_at = Vector2(_rng.randf_range(ARENA.position.x, ARENA.end.x), _rng.randf_range(ARENA.position.y, ARENA.end.y))
			if not _inside_wall(spawn_at):
				break
		_request.position = spawn_at
		var speed := _rng.randf_range(1500.0, 2500.0) if _rng.randf() < FAST_FRACTION else _rng.randf_range(80.0, 320.0)
		_request.velocity = Vector2.from_angle(_rng.randf() * TAU) * speed
		_request.lifetime = _rng.randf_range(2.0, 6.0)
		_request.radius = 3.0
		_request.hit_mask = Layers.ENEMY
		if _pierce_rng.randf() < PIERCE_FRACTION:
			_request.pierce = PIERCE_EXTRA
		if batch_mode > 0:
			_request.behavior_id = _batch_behavior_id
		elif hooked_fraction > 0.0 and _hook_rng.randf() < hooked_fraction:
			_request.behavior_id = _noop_behavior_id
		if not _manager.emitter.request_shot(_request):
			break


func _next_count() -> void:
	_count_index += 1
	if _count_index >= counts.size():
		_report()
		return
	_current_count = counts[_count_index]
	_manager.clear_bullets()
	_frame = 0
	_work_ms.clear()
	_wall_ms.clear()
	_last_frame_usec = 0
	_min_alive = -1
	_phase_sum.fill(0.0)


func _finish_count() -> void:
	var result := {
		"bullets": _current_count,
		"hooked_fraction": hooked_fraction,
		"batch": batch_mode,
		"hooked_alive_at_end": _hooked_alive(),
		"frames": _work_ms.size(),
		"alive_at_end": _manager.alive_count(),
		"min_alive_before_step": _min_alive,
		"reached": _min_alive >= _current_count,
		"wall_hits_last_step": _manager.last_wall_hit_count,
		"work_p50_ms": BenchStats.percentile(_work_ms, 50.0),
		"work_p95_ms": BenchStats.percentile(_work_ms, 95.0),
		"work_p99_ms": BenchStats.percentile(_work_ms, 99.0),
		"work_max_ms": BenchStats.percentile(_work_ms, 100.0),
		"work_mean_ms": BenchStats.mean(_work_ms),
		"phase_mean_ms": {
			"advance": _phase_sum[0] / maxf(_work_ms.size(), 1.0),
			"hooks_walls": _phase_sum[1] / maxf(_work_ms.size(), 1.0),
			"hurtboxes": _phase_sum[2] / maxf(_work_ms.size(), 1.0),
			"despawn": _phase_sum[3] / maxf(_work_ms.size(), 1.0),
			"render": _phase_sum[4] / maxf(_work_ms.size(), 1.0),
		},
		"wall_p50_ms": BenchStats.percentile(_wall_ms, 50.0),
		"wall_p95_ms": BenchStats.percentile(_wall_ms, 95.0),
		"wall_max_ms": BenchStats.percentile(_wall_ms, 100.0),
	}
	_results.append(result)
	var ph: Dictionary = result.phase_mean_ms
	print("[bench]          mean ms by phase: advance %.2f | hooks+walls %.2f | hurtboxes %.2f | despawn %.2f | render fill %.2f"
		% [ph.advance, ph.hooks_walls, ph.hurtboxes, ph.despawn, ph.render])
	var native_alive := _manager.native.count() if _manager.native != null else 0
	var alive_at_end: int = result.alive_at_end
	result["native_alive_at_end"] = native_alive
	result["pool_alive_at_end"] = alive_at_end - native_alive
	print("[bench] %6d bullets: work p50 %.2f ms  p95 %.2f ms  p99 %.2f ms  max %.2f ms | wall p50 %.2f ms  p95 %.2f ms | alive %d (min %d, pool %d, native %d)"
		% [result.bullets, result.work_p50_ms, result.work_p95_ms, result.work_p99_ms, result.work_max_ms,
			result.wall_p50_ms, result.wall_p95_ms, result.alive_at_end, result.min_alive_before_step,
			result.pool_alive_at_end, native_alive])
	_next_count()


## Alive bullets that carry a behaviour (hooked), counted over the dense range.
func _hooked_alive() -> int:
	var n := 0
	var pool := _manager.pool
	for i in pool.count:
		if pool.behavior[i] != 0:
			n += 1
	return n


## Verdict for one bullet count: {"ok": bool, "text": String}. Not ok when the
## count was not benchmarked, was not reached, or missed the p95 budget.
func _judge(bullets: int) -> Dictionary:
	for r in _results:
		if r.bullets != bullets:
			continue
		var detail := "%d bullets, work p95 %.2f ms vs budget %.1f ms" % [bullets, r.work_p95_ms, target_ms]
		if not r.reached:
			return {"ok": false, "text": "only %d of %d bullets were alive on the slowest-filled frame (%s)" % [r.min_alive_before_step, bullets, detail]}
		if r.work_p95_ms > target_ms:
			return {"ok": false, "text": detail}
		return {"ok": true, "text": detail}
	return {"ok": false, "text": "%d bullets was not benchmarked (add it to --bullets)" % bullets}


func _report() -> void:
	set_process(false)
	var floor_result := _judge(floor_bullets)
	var target_result := _judge(target_bullets)
	var floor_text: String = ("PASS: " if floor_result.ok else "FAIL: ") + floor_result.text
	var target_text: String = ("PASS: " if target_result.ok else "WARN: ") + target_result.text
	print("[bench] FLOOR  %s" % floor_text)
	print("[bench] TARGET %s" % target_text)
	if not target_result.ok:
		print("[bench] WARN the %d-bullet target misses its budget; this does not fail the run (only the %d-bullet floor does)" % [target_bullets, floor_bullets])
	var exit_code := 0 if floor_result.ok else 1
	print("[bench] RESULT %s (exit %d)" % ["OK" if exit_code == 0 else "FAILED", exit_code])
	if json_path != "":
		var f := FileAccess.open(json_path, FileAccess.WRITE)
		if f != null:
			f.store_string(JSON.stringify({
				"godot": Engine.get_version_info().string,
				"backend": _manager.backend,
				"floor": floor_text, "floor_bullets": floor_bullets,
				"target": target_text, "target_bullets": target_bullets,
				"target_ms": target_ms, "hooked_fraction": hooked_fraction, "batch": batch_mode, "mirrors": mirror_count,
				"pierce_fraction": PIERCE_FRACTION, "pierce": PIERCE_EXTRA, "results": _results,
			}, "\t"))
	get_tree().quit(exit_code)


## Returns "" or a message describing the first invalid option.
func _parse_args() -> String:
	for arg in OS.get_cmdline_user_args():
		if arg == "--hooked" or arg.begins_with("--hooked") and not "=" in arg:
			return "--hooked needs a value: --hooked=0.3 (a fraction between 0 and 1), got '%s'" % arg
		if not arg.begins_with("--") or not "=" in arg:
			continue
		var kv := arg.trim_prefix("--").split("=", true, 1)
		match kv[0]:
			"bullets":
				counts.clear()
				for part in kv[1].split(",", false):
					counts.append(int(part))
			"frames": frames = int(kv[1])
			"warmup": warmup = int(kv[1])
			"floor-bullets": floor_bullets = int(kv[1])
			"target-bullets": target_bullets = int(kv[1])
			"target-ms": target_ms = float(kv[1])
			"json": json_path = kv[1]
			"hooked":
				var parsed := BenchStats.parse_fraction(kv[1])
				if not parsed.ok:
					return parsed.error
				hooked_fraction = parsed.value
			"batch":
				batch_mode = int(kv[1])
				if batch_mode != 0 and batch_mode != 1:
					return "--batch must be 0 or 1, got '%s'" % kv[1]
			"backend":
				if not kv[1] in ["auto", "gdscript", "native"]:
					return "--backend must be auto, gdscript or native, got '%s'" % kv[1]
				backend_preference = kv[1]
			"mirrors":
				mirror_count = int(kv[1])
				if mirror_count < 0:
					return "--mirrors must be >= 0, got '%s'" % kv[1]
	return ""
