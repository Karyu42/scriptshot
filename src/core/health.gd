class_name Health
extends Node
## PLACEHOLDER hit points + short invulnerability frames.
##
## Added so enemy bullets have something to hurt; the real health / damage /
## death design is still pending (see "Open design questions" in
## docs/architecture.md). Every number and rule here is provisional: max_hp,
## invulnerability_time, "any damage > 0 costs that many hp", and what dying
## means are all expected to change.

## Emitted for every damage() call that was applied.
signal damaged(amount: float, hp: float)
## Emitted once when hp reaches 0.
signal died
## Emitted when i-frames start (true) and end (false).
signal invulnerability_changed(active: bool)

## PROVISIONAL.
@export var max_hp := 5.0
## Seconds of invulnerability after a hit that does not kill. PROVISIONAL.
@export var invulnerability_time := 0.6

var hp := 0.0
## Seconds of invulnerability left.
var invulnerable_left := 0.0


func _ready() -> void:
	hp = max_hp


func _physics_process(delta: float) -> void:
	if invulnerable_left > 0.0:
		invulnerable_left = maxf(invulnerable_left - delta, 0.0)
		if invulnerable_left == 0.0:
			invulnerability_changed.emit(false)


func is_dead() -> bool:
	return hp <= 0.0


func is_invulnerable() -> bool:
	return invulnerable_left > 0.0


## Applies damage unless dead, invulnerable, or amount <= 0. Returns true if it
## was applied. A non-lethal hit starts the i-frames.
func damage(amount: float) -> bool:
	if amount <= 0.0 or is_dead() or is_invulnerable():
		return false
	hp = maxf(hp - amount, 0.0)
	damaged.emit(amount, hp)
	if hp <= 0.0:
		died.emit()
	elif invulnerability_time > 0.0:
		invulnerable_left = invulnerability_time
		invulnerability_changed.emit(true)
	return true


## Restores hp (clamped to max_hp). Does nothing once dead; use reset().
func heal(amount: float) -> void:
	if not is_dead() and amount > 0.0:
		hp = minf(hp + amount, max_hp)


## Full hp, no i-frames (respawn).
func reset() -> void:
	var was_invulnerable := is_invulnerable()
	hp = max_hp
	invulnerable_left = 0.0
	if was_invulnerable:
		invulnerability_changed.emit(false)
