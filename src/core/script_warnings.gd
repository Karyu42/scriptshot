class_name ScriptWarnings
extends RefCounted
## Rate-limited warnings for bad values coming from scripts (NaN, wrong types).
## A script that passes NaN every frame would otherwise bury the log: each kind of
## warning (identified by `key`) is printed at most LIMIT times per WINDOW_MSEC
## window, the last one of a window saying that the rest are suppressed. The first
## warning after the window has passed starts a new window, so a script that is
## fixed and breaks again later is reported again (a one-off budget would stay
## silent for the rest of the session), and the message then says how many were
## suppressed in the meantime.

const LIMIT := 3
## Length of one reporting window, in milliseconds (10 s).
const WINDOW_MSEC := 10000

## Total reports per key (printed or suppressed), over the whole session.
static var _counts: Dictionary[String, int] = {}
## Warnings actually printed per key, over the whole session.
static var _printed: Dictionary[String, int] = {}
## Per key: start of the current window and how many were printed / suppressed in it.
static var _window_start: Dictionary[String, int] = {}
static var _window_printed: Dictionary[String, int] = {}
static var _window_suppressed: Dictionary[String, int] = {}

## Tests set this (milliseconds, >= 0) to control the clock; -1 = real time.
static var clock_override_msec := -1


static func warn(key: String, message: String) -> void:
	var now := _now_msec()
	_counts[key] = _counts.get(key, 0) + 1
	var carried := 0
	if not _window_start.has(key) or now - _window_start[key] >= WINDOW_MSEC:
		carried = _window_suppressed.get(key, 0)
		_window_start[key] = now
		_window_printed[key] = 0
		_window_suppressed[key] = 0
	var used: int = _window_printed[key]
	if used >= LIMIT:
		_window_suppressed[key] += 1
		return
	_window_printed[key] = used + 1
	_printed[key] = _printed.get(key, 0) + 1
	var text := message
	if carried > 0:
		text += " (%d earlier warnings of this kind were suppressed)" % carried
	if used == LIMIT - 1:
		text += " (further warnings of this kind are suppressed for %d s)" % (WINDOW_MSEC / 1000)
	push_warning(text)


## How many times `key` was reported (printed or suppressed).
static func count(key: String) -> int:
	return _counts.get(key, 0)


## How many warnings of this kind were actually printed.
static func printed_count(key: String) -> int:
	return _printed.get(key, 0)


static func reset() -> void:
	_counts.clear()
	_printed.clear()
	_window_start.clear()
	_window_printed.clear()
	_window_suppressed.clear()
	clock_override_msec = -1


static func _now_msec() -> int:
	return clock_override_msec if clock_override_msec >= 0 else Time.get_ticks_msec()
