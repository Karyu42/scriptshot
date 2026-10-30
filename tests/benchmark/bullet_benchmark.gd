extends Node
## Headless-friendly bullet benchmark. Keeps N bullets alive in steady state
## (spawning replacements as old ones expire / leave the arena / hit targets),
## runs the full BulletManager.step() every frame including collision against 32
## hurtboxes and the MultiMesh buffer fill, and reports per-frame times.
##
## Run:  ./tools/run_benchmark.sh            (see README for options)
##       godot --headless --path . res://tests/benchmark/bullet_benchmark.tscn -- --bullets=5000,10000
##
## Options (after `--`):
##   --bullets=5000,10000   bullet counts to test
##   --frames=600           measured frames per count
##   --warmup=120           unmeasured frames per count
##   --target-bullets=5000  count the pass/fail target applies to
##   --target-ms=16.7       p95 frame-time budget at the target count
##   --json=path            also write results as JSON
##
## "work" is the cost of one game frame of bullet work (top-up spawns +
## BulletManager.step: kinematics, collision, hooks, despawn, MultiMesh buffer
## fill). The pass/fail verdict uses work p95. "wall" is the interval between
## engine frames; it is informational only, because headless runs are paced at
## roughly 144 Hz (~6.9 ms) regardless of load. Exit code is 1 if the target is
## missed.

const ARENA := Rect2(-1280, -720, 2560, 1440)
const TARGET_COUNT := 32
const FIXED_DELTA := 1.0 / 60.0

var counts: Array[int] = [5000, 10000]
var frames := 600
var warmup := 120
var target_bullets := 5000
var target_ms := 16.7
var json_path := ""

var _manager: BulletManager
var _rng := RandomNumberGenerator.new()
var _request := ShotRequest.new()
var _results: Array[Dictionary] = []

var _count_index := -1
var _frame := 0
var _work_ms := PackedFloat64Array()
var _wall_ms := PackedFloat64Array()
var _last_frame_usec := 0
var _current_count := 0


func _ready() -> void:
	_parse_args()
	_rng.seed = 20260101
	_manager = BulletManager.new()
	_manager.capacity = 32768
	_manager.world_bounds = ARENA.grow(32.0)
	_manager.auto_step = false
	add_child(_manager)
	for i in TARGET_COUNT:
		var hb := Hurtbox.new()
		hb.radius = 24.0
		hb.layer = Layers.ENEMY
		hb.position = Vector2(_rng.randf_range(ARENA.position.x, ARENA.end.x), _rng.randf_range(ARENA.position.y, ARENA.end.y))
		add_child(hb)
	print("[bench] Godot %s | renderer: %s | %d hurtboxes | %d warmup + %d measured frames per count"
		% [Engine.get_version_info().string, RenderingServer.get_video_adapter_name(), TARGET_COUNT, warmup, frames])
	_next_count()


func _process(_delta: float) -> void:
	var now := Time.get_ticks_usec()
	var wall := (now - _last_frame_usec) / 1000.0 if _last_frame_usec != 0 else 0.0
	_last_frame_usec = now

	var t0 := Time.get_ticks_usec()
	_top_up(_current_count)
	_manager.step(FIXED_DELTA)
	var work := (Time.get_ticks_usec() - t0) / 1000.0

	_frame += 1
	if _frame > warmup:
		_work_ms.append(work)
		_wall_ms.append(wall)
	if _frame >= warmup + frames:
		_finish_count()


func _top_up(n: int) -> void:
	var pool := _manager.pool
	while pool.count < n:
		_request.reset()
		_request.position = Vector2(_rng.randf_range(ARENA.position.x, ARENA.end.x), _rng.randf_range(ARENA.position.y, ARENA.end.y))
		_request.velocity = Vector2.from_angle(_rng.randf() * TAU) * _rng.randf_range(80.0, 320.0)
		_request.lifetime = _rng.randf_range(2.0, 6.0)
		_request.radius = 3.0
		_request.hit_mask = Layers.ENEMY
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


func _finish_count() -> void:
	var result := {
		"bullets": _current_count,
		"frames": _work_ms.size(),
		"alive_at_end": _manager.pool.count,
		"work_p50_ms": BenchStats.percentile(_work_ms, 50.0),
		"work_p95_ms": BenchStats.percentile(_work_ms, 95.0),
		"work_p99_ms": BenchStats.percentile(_work_ms, 99.0),
		"work_max_ms": BenchStats.percentile(_work_ms, 100.0),
		"work_mean_ms": BenchStats.mean(_work_ms),
		"wall_p50_ms": BenchStats.percentile(_wall_ms, 50.0),
		"wall_p95_ms": BenchStats.percentile(_wall_ms, 95.0),
		"wall_max_ms": BenchStats.percentile(_wall_ms, 100.0),
	}
	_results.append(result)
	print("[bench] %6d bullets: work p50 %.2f ms  p95 %.2f ms  p99 %.2f ms  max %.2f ms | wall p50 %.2f ms  p95 %.2f ms | alive %d"
		% [result.bullets, result.work_p50_ms, result.work_p95_ms, result.work_p99_ms, result.work_max_ms,
			result.wall_p50_ms, result.wall_p95_ms, result.alive_at_end])
	_next_count()


func _report() -> void:
	set_process(false)
	var exit_code := 0
	var verdict := "n/a (target count not benchmarked)"
	for r in _results:
		if r.bullets == target_bullets:
			var ok: bool = r.work_p95_ms <= target_ms
			verdict = "%s: %d bullets, work p95 %.2f ms vs budget %.1f ms"\
				% ["PASS" if ok else "FAIL", target_bullets, r.work_p95_ms, target_ms]
			exit_code = 0 if ok else 1
	print("[bench] TARGET %s" % verdict)
	if json_path != "":
		var f := FileAccess.open(json_path, FileAccess.WRITE)
		if f != null:
			f.store_string(JSON.stringify({"godot": Engine.get_version_info().string, "target": verdict, "results": _results}, "\t"))
	get_tree().quit(exit_code)


func _parse_args() -> void:
	for arg in OS.get_cmdline_user_args():
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
			"target-bullets": target_bullets = int(kv[1])
			"target-ms": target_ms = float(kv[1])
			"json": json_path = kv[1]
