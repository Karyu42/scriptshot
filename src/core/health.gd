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
## Everything a script may write goes through the validating setters (set_hp,
## set_max_hp, set_invulnerable): NaN is ignored with a warning, infinities and
## out-of-range values are clamped. Don't write `hp` directly.

## Emitted for every damage() call that was applied.
signal damaged(amount: float, hp: float)
## Emitted once when hp reaches 0.
signal died
## Emitted when invulnerability starts (true) or ends (false), from any source:
## a hit's i-frames, a dash, or set_invulnerable().
signal invulnerability_changed(active: bool)
## Emitted whenever hp gained anything (regeneration, heal(), set_hp() upward).
signal healed(amount: float, hp: float)

## Upper bound accepted by set_max_hp(), so a script can't create absurd values.
const MAX_HP_LIMIT := 1000.0

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
## Seconds of invulnerability left (INF = until cleared).
var invulnerable_left := 0.0
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
	if invulnerable_left > 0.0:
		invulnerable_left = maxf(invulnerable_left - delta, 0.0)
		if invulnerable_left == 0.0:
			invulnerability_changed.emit(false)
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


func is_invulnerable() -> bool:
	return invulnerable_left > 0.0


## True while hp is being regenerated (below max, alive, delay passed).
func is_regenerating() -> bool:
	return (
		regen_enabled
		and not is_dead()
		and hp < max_hp
		and time_since_damage >= regen_delay
	)


## Applies damage unless dead, invulnerable, NaN or amount <= 0. Returns true if
## it was applied. Restarts the regeneration delay; a non-lethal hit starts the
## i-frames.
func damage(amount: float) -> bool:
	if is_nan(amount) or amount <= 0.0 or is_dead() or is_invulnerable():
		return false
	hp = maxf(hp - amount, 0.0)
	time_since_damage = 0.0
	_regen_clock = 0.0
	_regen_active = false
	damaged.emit(amount, hp)
	if hp <= 0.0:
		died.emit()
	elif invulnerability_time > 0.0:
		set_invulnerable(invulnerability_time)
	return true


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
		push_warning("Health.set_hp(): NaN ignored")
		return hp
	if is_dead():
		return hp
	var target := clampf(value, 0.0, max_hp)
	if target > hp:
		_gain(target - hp)
	elif target < hp:
		hp = target
		if hp <= 0.0:
			died.emit()
	return hp


## Scripts: sets max_hp, clamped to [1, MAX_HP_LIMIT]; NaN is ignored. hp is
## clamped down if it now exceeds max_hp; raising max_hp does not heal.
## Returns the resulting max_hp.
func set_max_hp(value: float) -> float:
	if is_nan(value):
		push_warning("Health.set_max_hp(): NaN ignored")
		return max_hp
	max_hp = clampf(value, 1.0, MAX_HP_LIMIT)
	if hp > max_hp:
		hp = max_hp
	return max_hp


## Invulnerability from any source. `value` is
##   - a number of seconds (float/int): invulnerable for that long. It only ever
##     extends the current invulnerability (a dash can't cut a longer effect
##     short); 0 or less clears it. INF = until cleared.
##   - a bool: true = invulnerable until cleared, false = clear.
## NaN and unsupported types are ignored with a warning.
func set_invulnerable(value: Variant) -> void:
	var seconds := 0.0
	if value is bool:
		seconds = INF if value else 0.0
		if not value:
			_clear_invulnerable()
			return
	elif value is float or value is int:
		seconds = value
		if is_nan(seconds):
			push_warning("Health.set_invulnerable(): NaN ignored")
			return
		if seconds <= 0.0:
			_clear_invulnerable()
			return
	else:
		push_warning("Health.set_invulnerable(): expected bool or seconds")
		return
	if seconds > invulnerable_left:
		var was := is_invulnerable()
		invulnerable_left = seconds
		if not was:
			invulnerability_changed.emit(true)


## Full hp, no i-frames, regeneration timers cleared (respawn). Keeps max_hp.
func reset() -> void:
	hp = max_hp
	time_since_damage = 0.0
	_regen_clock = 0.0
	_regen_active = false
	_clear_invulnerable()


func _clear_invulnerable() -> void:
	var was := is_invulnerable()
	invulnerable_left = 0.0
	if was:
		invulnerability_changed.emit(false)


func _gain(amount: float) -> void:
	var before := hp
	hp = minf(hp + amount, max_hp)
	if hp > before:
		healed.emit(hp - before, hp)
