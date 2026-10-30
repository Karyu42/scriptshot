class_name Health
extends Node
## Hit points, invulnerability and regeneration, using the combat rules decided
## on 2026-10-30 (docs/architecture.md, "Combat rules"). Every number is an
## @export so it can be tuned in the editor or from a script:
##
##   - max_hp = 5.
##   - Taking damage starts `invulnerability_time` (0.75 s) of i-frames; bullets
##     pass through an invulnerable player. A lethal hit kills instead.
##   - Regeneration: the first `regen_amount` (1 hp) arrives `regen_delay` (5 s)
##     after the last hit, then another every `regen_interval` (3 s) until full.
##   - Dying is handled by the owner (the player respawns with everything kept
##     and hp back at max_hp, see Player.respawn()).
##
## **Two invulnerability layers** (pillars 5.4 and 12.2):
##   - *Engine i-frames*: hit i-frames and the dash. Owned by the engine
##     (add_engine_invulnerability()); always respected by every attack.
##   - *Script invulnerability*: the flag/timer a script writes through
##     set_invulnerable(). It is its own layer: a script can set or clear it, and
##     that never touches engine i-frames. An attack that carries
##     SOURCE_PIERCES_SCRIPT_INVULN ignores this layer (but not the engine one).
## is_invulnerable() is true if either layer is on.
##
## Everything a script may write goes through the validating setters (set_hp,
## set_max_hp, set_invulnerable): NaN is ignored with a (rate-limited) warning,
## infinities and out-of-range values are clamped. Don't write `hp` directly.

## Emitted for every damage that was applied.
signal damaged(amount: float, hp: float)
## Emitted once when hp reaches 0.
signal died
## Emitted when "invulnerable in any layer" flips (true = started).
signal invulnerability_changed(active: bool)
## Emitted when the engine layer flips; the player's hurtbox follows this one, so
## bullets pass through during i-frames and dashes.
signal engine_invulnerability_changed(active: bool)
## Emitted when the script layer flips.
signal script_invulnerability_changed(active: bool)
## Emitted whenever hp gained anything (regeneration, heal(), set_hp() upward).
signal healed(amount: float, hp: float)
## Emitted when a damage attempt was refused because of invulnerability
## (`result` is BLOCKED_ENGINE or BLOCKED_SCRIPT).
signal damage_blocked(amount: float, result: DamageResult)

## What try_damage() did.
enum DamageResult {
	## hp was reduced.
	APPLIED,
	## Refused: engine i-frames (hit i-frames or a dash). Nothing pierces these.
	BLOCKED_ENGINE,
	## Refused *only* by the script layer: the same attack with
	## SOURCE_PIERCES_SCRIPT_INVULN would have been applied.
	BLOCKED_SCRIPT,
	## Nothing to do: not a positive number, or already dead.
	IGNORED,
}

## `source_flags` bit: the attack ignores script invulnerability (a "Null" /
## piercing boss attack). Engine i-frames still block it.
const SOURCE_PIERCES_SCRIPT_INVULN := 1

## Upper bound accepted by set_max_hp(), so a script can't create absurd values.
const MAX_HP_LIMIT := 1000.0
## Timers below this many seconds count as expired (float residue from summing
## 1/60 s ticks would otherwise cost an extra tick).
const TIME_EPSILON := 0.000001

@export var max_hp := 5.0
## Seconds of invulnerability after a hit that does not kill.
@export var invulnerability_time := 0.75
@export_group("Regeneration")
## Seconds after the last hit at which the first hp comes back.
@export var regen_delay := 5.0
## Seconds between regeneration steps after the first (5 s, 8 s, 11 s, ... after
## the last hit with the defaults).
@export var regen_interval := 3.0
## Hit points restored per step.
@export var regen_amount := 1.0
## Master switch, e.g. for a boss fight that forbids healing.
@export var regen_enabled := true

var hp := 0.0
## Seconds of engine invulnerability left (hit i-frames, dash).
var engine_invulnerable_left := 0.0
## Seconds of script invulnerability left (INF = until cleared).
var script_invulnerable_left := 0.0
## Seconds since damage was last applied (or since the start / respawn).
var time_since_damage := 0.0

## Seconds since the last regeneration step; only meaningful while _regen_active.
var _regen_clock := 0.0
## True once the first step of the current regeneration has been paid.
var _regen_active := false


func _ready() -> void:
	hp = max_hp


func _physics_process(delta: float) -> void:
	tick(delta)


## Advances the timers by `delta`. Called every physics tick by the node; public
## so tests and headless simulations can step it deterministically.
func tick(delta: float) -> void:
	if not is_finite(delta) or delta <= 0.0:
		return
	var was_any := is_invulnerable()
	var was_engine := is_engine_invulnerable()
	var was_script := is_script_invulnerable()
	engine_invulnerable_left = _count_down(engine_invulnerable_left, delta)
	script_invulnerable_left = _count_down(script_invulnerable_left, delta)
	_emit_layer_changes(was_any, was_engine, was_script)
	if is_dead():
		return
	time_since_damage += delta
	if not regen_enabled or hp >= max_hp or regen_interval <= 0.0 or regen_amount <= 0.0:
		_regen_active = false
		return
	if time_since_damage < regen_delay:
		_regen_active = false
		return
	if not _regen_active:
		# The delay has just passed: the first hp comes now, and the time already
		# spent past the delay (a big delta) counts toward the next steps.
		_regen_active = true
		_regen_clock = time_since_damage - regen_delay
		_gain(regen_amount)
	else:
		_regen_clock += delta
	while _regen_clock >= regen_interval and hp < max_hp:
		_regen_clock -= regen_interval
		_gain(regen_amount)


func is_dead() -> bool:
	return hp <= 0.0


## True if either invulnerability layer is on.
func is_invulnerable() -> bool:
	return engine_invulnerable_left > 0.0 or script_invulnerable_left > 0.0


## Hit i-frames or a dash: nothing pierces these.
func is_engine_invulnerable() -> bool:
	return engine_invulnerable_left > 0.0


## The script-written layer: attacks with SOURCE_PIERCES_SCRIPT_INVULN ignore it.
func is_script_invulnerable() -> bool:
	return script_invulnerable_left > 0.0


## True while hp is being regenerated (below max, alive, delay passed).
func is_regenerating() -> bool:
	return (
		regen_enabled
		and not is_dead()
		and hp < max_hp
		and time_since_damage >= regen_delay
	)


## Tries to apply damage and reports what happened (see DamageResult), so a hit
## can be told apart as "blocked by engine i-frames" vs "blocked only by script
## invulnerability". `source_flags` is a bit set (SOURCE_PIERCES_SCRIPT_INVULN).
## A damage that is applied restarts the regeneration delay and, if it does not
## kill, starts the hit i-frames (engine layer).
func try_damage(amount: float, source_flags: int = 0) -> DamageResult:
	if is_nan(amount) or amount <= 0.0 or is_dead():
		return DamageResult.IGNORED
	if is_engine_invulnerable():
		damage_blocked.emit(amount, DamageResult.BLOCKED_ENGINE)
		return DamageResult.BLOCKED_ENGINE
	if is_script_invulnerable() and (source_flags & SOURCE_PIERCES_SCRIPT_INVULN) == 0:
		damage_blocked.emit(amount, DamageResult.BLOCKED_SCRIPT)
		return DamageResult.BLOCKED_SCRIPT
	hp = maxf(hp - amount, 0.0)
	time_since_damage = 0.0
	_regen_clock = 0.0
	_regen_active = false
	damaged.emit(amount, hp)
	if hp <= 0.0:
		died.emit()
	elif invulnerability_time > 0.0:
		add_engine_invulnerability(invulnerability_time)
	return DamageResult.APPLIED


## try_damage() for callers that only care whether it was applied.
func damage(amount: float, source_flags: int = 0) -> bool:
	return try_damage(amount, source_flags) == DamageResult.APPLIED


## Restores hp (clamped to max_hp). Does nothing once dead (use reset()), for NaN
## or amount <= 0. Does not touch the regeneration timers.
func heal(amount: float) -> void:
	if is_dead() or is_nan(amount) or amount <= 0.0:
		return
	_gain(amount)


## Scripts: sets hp, clamped to [0, max_hp]; NaN is ignored. Setting 0 kills
## (emits died). A dead entity cannot be revived this way, use respawn/reset().
## Writing hp does not start i-frames and does not restart the regeneration delay.
## Returns the resulting hp.
func set_hp(value: float) -> float:
	if is_nan(value):
		ScriptWarnings.warn("Health.set_hp", "Health.set_hp(): NaN ignored")
		return hp
	if is_dead():
		return hp
	var before := hp
	hp = clampf(value, 0.0, max_hp)
	if hp > before:
		healed.emit(hp - before, hp)
	elif hp <= 0.0:
		died.emit()
	return hp


## Scripts: sets max_hp, rounded to a whole number and clamped to
## [1, MAX_HP_LIMIT]; NaN is ignored. hp is clamped down if it now exceeds
## max_hp; raising max_hp does not heal. Returns the resulting max_hp.
func set_max_hp(value: float) -> float:
	if is_nan(value):
		ScriptWarnings.warn("Health.set_max_hp", "Health.set_max_hp(): NaN ignored")
		return max_hp
	max_hp = clampf(roundf(value), 1.0, MAX_HP_LIMIT)
	if hp > max_hp:
		hp = max_hp
	return max_hp


## Engine i-frames (hit, dash): invulnerable for `seconds`. Only ever extends the
## current engine invulnerability (hit i-frames and a dash don't stack: the
## longer one applies). 0, negative and NaN are ignored; INF is allowed.
func add_engine_invulnerability(seconds: float) -> void:
	if is_nan(seconds) or seconds <= 0.0 or seconds <= engine_invulnerable_left:
		return
	var was_any := is_invulnerable()
	var was_engine := is_engine_invulnerable()
	var was_script := is_script_invulnerable()
	engine_invulnerable_left = seconds
	_emit_layer_changes(was_any, was_engine, was_script)


## Ends engine i-frames (used by respawn). Does not touch the script layer.
func clear_engine_invulnerability() -> void:
	var was_any := is_invulnerable()
	var was_engine := is_engine_invulnerable()
	var was_script := is_script_invulnerable()
	engine_invulnerable_left = 0.0
	_emit_layer_changes(was_any, was_engine, was_script)


## Script invulnerability, **its own layer**: this never starts, extends or cancels
## engine i-frames. `value` is
##   - a number of seconds (float/int): invulnerable for that long, replacing
##     whatever the script set before; 0 or less clears. INF = until cleared.
##   - a bool: true = invulnerable until cleared (no cap), false = clear.
## NaN and unsupported types are ignored with a (rate-limited) warning. The layer
## persists across respawn: scripts own it, and it is theirs to clear.
func set_invulnerable(value: Variant) -> void:
	var seconds := 0.0
	if value is bool:
		seconds = INF if value else 0.0
	elif value is float or value is int:
		seconds = value
		if is_nan(seconds):
			ScriptWarnings.warn("Health.set_invulnerable.nan", "Health.set_invulnerable(): NaN ignored")
			return
	else:
		ScriptWarnings.warn("Health.set_invulnerable.type", "Health.set_invulnerable(): expected bool or seconds")
		return
	var was_any := is_invulnerable()
	var was_engine := is_engine_invulnerable()
	var was_script := is_script_invulnerable()
	script_invulnerable_left = maxf(seconds, 0.0)
	_emit_layer_changes(was_any, was_engine, was_script)


## Full hp, no engine i-frames, regeneration timers cleared (respawn). Keeps
## max_hp and the script invulnerability layer (scripts own that one).
func reset() -> void:
	hp = max_hp
	time_since_damage = 0.0
	_regen_clock = 0.0
	_regen_active = false
	clear_engine_invulnerability()


func _count_down(left: float, delta: float) -> float:
	if left <= 0.0:
		return 0.0
	left -= delta
	return 0.0 if left < TIME_EPSILON else left


func _emit_layer_changes(was_any: bool, was_engine: bool, was_script: bool) -> void:
	var now_engine := is_engine_invulnerable()
	var now_script := is_script_invulnerable()
	if now_engine != was_engine:
		engine_invulnerability_changed.emit(now_engine)
	if now_script != was_script:
		script_invulnerability_changed.emit(now_script)
	var now_any := now_engine or now_script
	if now_any != was_any:
		invulnerability_changed.emit(now_any)


func _gain(amount: float) -> void:
	var before := hp
	hp = minf(hp + amount, max_hp)
	if hp > before:
		healed.emit(hp - before, hp)
