class_name ShotPattern
extends RefCounted
## A weapon / shot script. The Player calls fire() each time the trigger is
## allowed to fire (respecting fire_interval) and the pattern turns that into
## any number of ShotRequests on the emitter.
##
## The Lua binding will provide a subclass that forwards fire() to a Lua
## function; it needs nothing beyond ShotContext and ShotEmitter.

## Minimum seconds between two fire() calls while the trigger is held.
var fire_interval := 0.12


func fire(_context: ShotContext, _emitter: ShotEmitter) -> void:
	push_error("ShotPattern.fire() is abstract")
