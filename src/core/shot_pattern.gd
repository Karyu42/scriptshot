class_name ShotPattern
extends RefCounted
## A weapon / shot script. The Player calls fire() each time the trigger is
## allowed to fire (respecting fire_interval) and the pattern turns that into
## any number of ShotRequests on the emitter.
##
## update() runs every physics tick while the pattern is equipped, with the
## trigger state in the context, so charge, channel and burst weapons can drive
## shots themselves. Set auto_fire = false for those so the player never calls
## fire() for them.
##
## The Lua binding will provide a subclass that forwards fire() / update() to
## Lua functions; it needs nothing beyond ShotContext and ShotEmitter.

## Minimum seconds between two fire() calls while the trigger is held.
var fire_interval := 0.12
## If true (default) the player calls fire() whenever the trigger is held and
## fire_interval has elapsed. If false only update() is called.
var auto_fire := true


## Called once per physics tick while equipped, before any fire() call that tick.
## `context` carries the current aim, muzzle and trigger state.
func update(_context: ShotContext, _emitter: ShotEmitter, _delta: float) -> void:
	pass


func fire(_context: ShotContext, _emitter: ShotEmitter) -> void:
	push_error("ShotPattern.fire() is abstract")
