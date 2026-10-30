class_name TriggerState
extends RefCounted
## Tracks a held button across physics ticks: edges and how long it has been held.
## Feed it once per tick with update(); read the fields afterwards.

## Button is down this tick.
var pressed := false
## Button went down this tick.
var just_pressed := false
## Button went up this tick.
var just_released := false
## Seconds the button has been held continuously, counting this tick. On the
## release tick it keeps the total duration of the hold that just ended; it is 0
## whenever the button is up on any later tick.
var held_time := 0.0


func update(is_down: bool, delta: float) -> void:
	just_pressed = is_down and not pressed
	just_released = pressed and not is_down
	if is_down:
		held_time = delta if just_pressed else held_time + delta
	elif not just_released:
		held_time = 0.0
	pressed = is_down


## Copies the state into a ShotContext.
func apply_to(context: ShotContext) -> void:
	context.trigger_pressed = pressed
	context.trigger_just_pressed = just_pressed
	context.trigger_just_released = just_released
	context.trigger_held_time = held_time
