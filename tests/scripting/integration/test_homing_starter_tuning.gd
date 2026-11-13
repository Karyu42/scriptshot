extends GutTest
## Acceptance harness for the Homing starter (scripting/starters/homing.lua),
## GD's bars on #92. Deterministic and headless: a fixed 1/60 s tick, a fixed
## aim pattern, the real LuaShot + BulletManager + Hurtbox path, both backends.
##
##   * Stationary: the player stands at the origin and fires every 0.25 s at a
##     dummy 220 px away, with the aim off by a fixed sweep of -45..+45 deg.
##     At least 90% of shots hit, and no shot orbits for more than 1 s.
##   * Strafe: the player runs past the dummy at full speed (300 px/s, 220 px
##     to its side, both directions, both sides) firing every 0.25 s at it
##     with -20..+20 deg of aim error. At least 70% of shots hit.
##
## "Orbit time" of a shot: from the first tick it comes within ORBIT_R of the
## dummy's centre, the time it stays alive and within SENSE_R (the starter's
## 400 px query) of it, hit or not. A shot that flies in and hits needs ~0.3 s;
## one that circles, or swings out in a wide loop and comes back, keeps
## counting.
##
## The starter steers direction only (it puts the speed back after each
## turn), so a shot cannot speed up into a wide loop. pull = 1800: the bars
## pass from 800 at speed 280; 900 also lands every shot at +-150 deg of aim
## error; 1800 still passes the bars if a player raises speed to 400 (turning
## circles grow with speed squared), and sits in GD's 1600-2400 range.
##
## A sweep over `pull` prints a table when SCRIPTSHOT_HOMING_SWEEP=1:
##   SCRIPTSHOT_HOMING_SWEEP=1 ./tools/run_tests.sh -gselect=test_homing_starter_tuning

const DT := 1.0 / 60.0
const BACKENDS: Array[String] = ["gdscript", "native"]
const DUMMY_AT := Vector2(220, 0)
const DUMMY_RADIUS := 22.0
const FIRE_EVERY := 15  # ticks: 0.25 s
const ORBIT_R := 100.0
const SENSE_R := 400.0
const PLAYER_SPEED := 300.0  # Player.max_speed
const STATIONARY_HIT_BAR := 0.90
const STRAFE_HIT_BAR := 0.70
const ORBIT_BAR := 1.0

var _mgrs: Array[BulletManager] = []
var _shots: Array[LuaShot] = []


func before_each() -> void:
	ScriptWarnings.reset()
	SenseBook.reset()
	WorldQuery.reset()


func after_each() -> void:
	for m in _mgrs:
		if is_instance_valid(m):
			m._behaviors.clear()
	_mgrs.clear()
	_shots.clear()
	SenseBook.reset()
	WorldQuery.reset()


func _skip(preference: String) -> bool:
	return preference == "native" and not NativeBackend.is_available()


func _mgr(preference: String) -> BulletManager:
	var manager := BulletManager.new()
	manager.backend_preference = preference
	manager.capacity = 256
	manager.logical_cap = 256
	manager.enemy_reserve = 0
	manager.world_bounds = Rect2(-4000, -4000, 8000, 8000)
	manager.render_enabled = false
	manager.auto_step = false
	add_child_autofree(manager)
	_mgrs.append(manager)
	return manager


## A dummy that never dies: a WorldQuery DUMMY row and an ENEMY hurtbox.
## The caller frees it (Hurtbox.registry is global, so a leftover dummy would
## take the next run's hits).
func _dummy(at: Vector2) -> Hurtbox:
	var body := Node2D.new()
	add_child(body)
	body.global_position = at
	var hurtbox := Hurtbox.new()
	hurtbox.radius = DUMMY_RADIUS
	hurtbox.layer = Layers.ENEMY
	body.add_child(hurtbox)
	WorldQuery.register_enemy(body, EnemyKinds.DUMMY, EnemyKinds.RARITY_NONE, 0, DUMMY_RADIUS)
	return hurtbox


## The starter with its tweak number set to `pull`.
static func starter_with_pull(pull: int, src: String = "") -> String:
	if src == "":
		src = ScriptLibrary.starter("homing").source
	var re := RegEx.create_from_string("local pull = \\d+")
	return re.sub(src, "local pull = %d" % pull)


class Shot:
	var tick := 0
	var pos := Vector2.ZERO
	var vel := Vector2.ZERO
	var aim := 0.0

	func _init(t: int, p: Vector2, v: Vector2, a: float) -> void:
		tick = t
		pos = p
		vel = v
		aim = a


class Score:
	var shots := 0
	var hits := 0
	var max_orbit := 0.0
	var errors := 0
	var backend := ""

	func hit_rate() -> float:
		return float(hits) / maxf(float(shots), 1.0)


## Fires `plan` (one Shot per pull of the trigger) and steps `ticks` ticks.
func _run(preference: String, src: String, plan: Array[Shot], ticks: int) -> Score:
	var manager := _mgr(preference)
	var hurtbox := _dummy(DUMMY_AT)
	var shot := LuaShot.new(manager)
	_shots.append(shot)
	var applied := shot.apply(src)
	assert_true(applied.ok, applied.error)
	shot.behavior().host.wall_msec = 5000
	var hit_ids: Dictionary[int, bool] = {}
	hurtbox.hit.connect(func(_d: float, _p: Vector2, _v: Vector2) -> void:
		hit_ids[hurtbox.last_hit_bullet_id] = true)
	var orbit: Dictionary[int, float] = {}  # bullet id -> orbit time so far
	var score := Score.new()
	var next := 0
	for t in ticks:
		while next < plan.size() and plan[next].tick == t:
			var p := plan[next]
			var ctx := ShotContext.new()
			ctx.muzzle_position = p.pos
			ctx.aim_angle = p.aim
			ctx.aim_direction = Vector2.from_angle(p.aim)
			ctx.shooter_velocity = p.vel
			ctx.target_mask = Layers.ENEMY
			var before := manager.spawned_total()
			shot.fire(ctx, manager.emitter)
			score.shots += manager.spawned_total() - before
			next += 1
		WorldQuery.refresh(DT)
		manager.step(DT)
		var view := manager.gather_batch(shot.behavior_id(), DT)
		for i in view.n:
			var d := Vector2(view.px[i], view.py[i]).distance_to(DUMMY_AT)
			var id := view.id[i]
			if orbit.has(id):
				if d <= SENSE_R:
					orbit[id] += DT
			elif d <= ORBIT_R:
				orbit[id] = DT
	var body := hurtbox.get_parent() as Node2D
	WorldQuery.unregister_enemy(body)
	body.free()
	for id: int in orbit:
		score.max_orbit = maxf(score.max_orbit, orbit[id])
	score.hits = hit_ids.size()
	score.errors = shot.behavior().error_total
	score.backend = manager.backend
	return score


## Standing at the origin, 16 shots, aim error -spread..+spread deg in even
## steps (the bar uses 45; the sweep also reports 90 and 150 as margin).
static func stationary_plan(spread: float = 45.0) -> Array[Shot]:
	var plan: Array[Shot] = []
	var base := DUMMY_AT.angle()
	for k in 16:
		var err := -spread + 2.0 * spread * k / 15.0
		plan.append(Shot.new(k * FIRE_EVERY, Vector2.ZERO, Vector2.ZERO, base + deg_to_rad(err)))
	return plan


## Four passes (left/right, above/below), each 900 px at PLAYER_SPEED and
## 220 px to the dummy's side, aiming at it with -20..+20 deg of error.
static func strafe_plan() -> Array[Shot]:
	var plan: Array[Shot] = []
	var errs: Array[float] = [0.0, 10.0, -10.0, 20.0, -20.0]
	var pass_ticks := int(900.0 / PLAYER_SPEED / DT)
	var tick := 0
	var k := 0
	var sides: Array[float] = [-220.0, 220.0]
	var dirs: Array[float] = [1.0, -1.0]
	for side in sides:
		for dir in dirs:
			var vel := Vector2(PLAYER_SPEED * dir, 0.0)
			var start := DUMMY_AT + Vector2(-450.0 * dir, side)
			for t in range(0, pass_ticks, FIRE_EVERY):
				var pos := start + vel * (t * DT)
				plan.append(Shot.new(tick + t, pos, vel, (DUMMY_AT - pos).angle() + deg_to_rad(errs[k % errs.size()])))
				k += 1
			# Let that pass's shots finish (lifetime 2.5 s) before the next.
			tick += pass_ticks + 180
	return plan


func _play(preference: String, src: String, plan: Array[Shot]) -> Score:
	SenseBook.grant(&"nearest_enemy", 1)
	return _run(preference, src, plan, plan[plan.size() - 1].tick + 180)


## [stationary, strafe]
func _measure(preference: String, src: String) -> Array[Score]:
	return [_play(preference, src, stationary_plan()), _play(preference, src, strafe_plan())]


func _check(preference: String) -> void:
	var src := ScriptLibrary.starter("homing").source
	var r := _measure(preference, src)
	var s := r[0]
	var m := r[1]
	assert_eq(s.backend, preference)
	assert_eq(s.errors, 0)
	assert_eq(m.errors, 0)
	assert_eq(s.shots, 16)
	var info := "%s: stationary %d/%d max orbit %.2f s, strafe %d/%d" % [
		preference, s.hits, s.shots, s.max_orbit, m.hits, m.shots]
	gut.p(info)
	assert_gte(s.hit_rate(), STATIONARY_HIT_BAR, "stationary hit rate: " + info)
	assert_lte(s.max_orbit, ORBIT_BAR, "no shot orbits for more than 1 s: " + info)
	assert_gte(m.hit_rate(), STRAFE_HIT_BAR, "strafe hit rate: " + info)


func test_homing_starter_meets_the_bars_on_the_gdscript_backend() -> void:
	_check("gdscript")


func test_homing_starter_meets_the_bars_on_the_native_backend() -> void:
	if _skip("native"):
		pending("NativeBulletSim extension not built (scons in native/)")
		return
	_check("native")


func test_the_starter_keeps_one_tweak_number() -> void:
	var src := ScriptLibrary.starter("homing").source
	assert_eq(src.count("tweak me"), 1)
	assert_eq(RegEx.create_from_string("local pull = \\d+").search_all(src).size(), 1)


## Not a check: prints the sweep table (SCRIPTSHOT_HOMING_SWEEP=1).
func test_sweep_pull() -> void:
	if OS.get_environment("SCRIPTSHOT_HOMING_SWEEP") != "1":
		pass_test("sweep runs only with SCRIPTSHOT_HOMING_SWEEP=1")
		return
	var starter := ScriptLibrary.starter("homing").source
	# "fast": a player who raised the shot speed to 400 (turning circles grow
	# with speed squared), as a margin check on the chosen pull.
	var variants: Dictionary[String, String] = {
		"renorm": starter,
		"renorm, speed 400": starter.replace("speed = 280", "speed = 400"),
	}
	var legacy := OS.get_environment("SCRIPTSHOT_HOMING_LEGACY_SRC")
	if legacy != "":
		variants["legacy"] = FileAccess.get_file_as_string(legacy)
	var pulls: Array[int] = [600, 700, 800, 900, 1200, 1400, 1600, 1800, 2000, 2200, 2400]
	var lines := PackedStringArray(["variant | backend | pull | stationary hit | max orbit s | strafe hit | strafe max orbit s | ±90 hit, orbit | ±150 hit, orbit"])
	for vname: String in variants:
		for pref in BACKENDS:
			if _skip(pref):
				continue
			for pull in pulls:
				var r := _measure(pref, starter_with_pull(pull, variants[vname]))
				var s := r[0]
				var m := r[1]
				var w := _play(pref, starter_with_pull(pull, variants[vname]), stationary_plan(90.0))
				var ww := _play(pref, starter_with_pull(pull, variants[vname]), stationary_plan(150.0))
				lines.append("%s | %s | %d | %d/%d %.0f%% | %.2f | %d/%d %.0f%% | %.2f | %.0f%% %.2f | %.0f%% %.2f" % [
					vname, pref, pull, s.hits, s.shots, 100.0 * s.hit_rate(), s.max_orbit,
					m.hits, m.shots, 100.0 * m.hit_rate(), m.max_orbit,
					100.0 * w.hit_rate(), w.max_orbit, 100.0 * ww.hit_rate(), ww.max_orbit])
				SenseBook.reset()
				WorldQuery.reset()
	print("HOMING_SWEEP\n" + "\n".join(lines))
	pass_test("sweep printed")
