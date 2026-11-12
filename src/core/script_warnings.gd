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
## Most recent message per key (printed or suppressed), for last_message().
static var _last: Dictionary[String, String] = {}
## Warnings actually printed per key, over the whole session.
static var _printed: Dictionary[String, int] = {}
## Per key: start of the current window and how many were printed / suppressed in it.
static var _window_start: Dictionary[String, int] = {}
static var _window_printed: Dictionary[String, int] = {}
static var _window_suppressed: Dictionary[String, int] = {}

## Bumped on every report (printed or suppressed). The in-game script editor
## polls it to notice new warnings without a callback on this path.
static var revision := 0

## Tests set this (milliseconds, >= 0) to control the clock; -1 = real time.
static var clock_override_msec := -1

## A warning begin() accepted for printing, until finish() consumes it.
static var _print_carried: Dictionary[String, int] = {}
static var _print_used: Dictionary[String, int] = {}
## Suppressed reports whose text is built only if last_message() asks.
## 1 removed, 2 speed, 3 field clamp.
static var _lazy_kind: Dictionary[String, int] = {}
static var _lazy_a: Dictionary[String, String] = {}
static var _lazy_b: Dictionary[String, String] = {}
static var _lazy_c: Dictionary[String, String] = {}
static var _lazy_x: Dictionary[String, float] = {}
static var _lazy_y: Dictionary[String, float] = {}

const _LAZY_REMOVED := 1
const _LAZY_SPEED := 2
const _LAZY_CLAMP := 3


## Counts this report and opens a print when the window still has room.
## False means it is suppressed: do not format a message. Counts, the window
## and (via keep_*) the last message still move.
static func begin(key: String) -> bool:
	var now := _now_msec()
	revision += 1
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
		return false
	_window_printed[key] = used + 1
	_printed[key] = _printed.get(key, 0) + 1
	_print_carried[key] = carried
	_print_used[key] = used
	return true


## Stores `message` as the last text and prints it when begin() returned true.
static func finish(key: String, message: String) -> void:
	_lazy_kind.erase(key)
	_last[key] = message
	if not _print_used.has(key):
		return
	var carried: int = _print_carried[key]
	var used: int = _print_used[key]
	_print_carried.erase(key)
	_print_used.erase(key)
	var text := message
	if carried > 0:
		text += " (%d earlier warnings of this kind were suppressed)" % carried
	if used == LIMIT - 1:
		text += " (further warnings of this kind are suppressed for %d s)" % (WINDOW_MSEC / 1000)
	push_warning(text)


static func warn(key: String, message: String) -> void:
	if begin(key):
		finish(key, message)
	else:
		_lazy_kind.erase(key)
		_last[key] = message


## Suppressed removal. last_message() builds the same sentence report_removed uses.
static func keep_removed(key: String, what: String) -> void:
	if _lazy_kind.get(key, 0) == _LAZY_REMOVED and _lazy_b.get(key, "") == what:
		return
	_lazy_kind[key] = _LAZY_REMOVED
	_lazy_b[key] = what


## Suppressed speed clamp. The velocity is what the next last_message() formats.
static func keep_speed(key: String, v: Vector2) -> void:
	_lazy_kind[key] = _LAZY_SPEED
	_lazy_x[key] = v.x
	_lazy_y[key] = v.y


## Suppressed field clamp. Identical asks reuse the stored parts.
static func keep_clamp(key: String, where: String, field: String, asked: float, kept: float, limit_name: String) -> void:
	if (
		_lazy_kind.get(key, 0) == _LAZY_CLAMP
		and _lazy_a.get(key, "") == where
		and _lazy_b.get(key, "") == field
		and _lazy_c.get(key, "") == limit_name
		and _lazy_x.get(key, 0.0) == asked
		and _lazy_y.get(key, 0.0) == kept
	):
		return
	_lazy_kind[key] = _LAZY_CLAMP
	_lazy_a[key] = where
	_lazy_b[key] = field
	_lazy_c[key] = limit_name
	_lazy_x[key] = asked
	_lazy_y[key] = kept


static func removed_message(key: String, what: String) -> String:
	return "%s: %s, the bullet was removed (DespawnReason.INVALID)" % [key, what]


static func speed_message(where: String, v: Vector2) -> String:
	var m := maxf(absf(v.x), absf(v.y))
	var speed := (v / m).length() * m if m > 0.0 else 0.0
	return "%s: speed %s is outside its allowed range and was clamped to %s (BulletLimits.MAX_SPEED)" % [where, _fmt_number(speed), _fmt_number(BulletLimits.MAX_SPEED)]


static func clamp_message(where: String, field: String, asked: float, kept: float, limit_name: String) -> String:
	return "%s: %s %s is outside its allowed range and was clamped to %s (BulletLimits.%s)" % [where, field, _fmt_number(asked), _fmt_number(kept), limit_name]


static func _fmt_number(x: float) -> String:
	if absf(x) < 1.0e7:
		return String.num(x, 3)
	var e := floori(log(absf(x)) / log(10.0))
	return "%.3fe%d" % [x / pow(10.0, e), e]


static func _render_lazy(key: String, kind: int) -> String:
	if kind == _LAZY_REMOVED:
		var what: String = _lazy_b[key]
		return removed_message(key, what)
	if kind == _LAZY_SPEED:
		var where := key.trim_suffix(".clamp.speed")
		var x: float = _lazy_x[key]
		var y: float = _lazy_y[key]
		return speed_message(where, Vector2(x, y))
	var where_c: String = _lazy_a[key]
	var field: String = _lazy_b[key]
	var asked: float = _lazy_x[key]
	var kept: float = _lazy_y[key]
	var limit_name: String = _lazy_c[key]
	return clamp_message(where_c, field, asked, kept, limit_name)


## Every key reported so far, in first-report order.
static func keys() -> PackedStringArray:
	return PackedStringArray(_counts.keys())


## How many times `key` was reported (printed or suppressed).
static func count(key: String) -> int:
	return _counts.get(key, 0)


## The text of the most recent warning of this kind (printed or suppressed), "" if
## there was none. For tests: push_warning() output cannot be read back.
static func last_message(key: String) -> String:
	var kind := 0
	if _lazy_kind.has(key):
		kind = _lazy_kind[key]
	if kind != 0:
		_last[key] = _render_lazy(key, kind)
		_lazy_kind.erase(key)
	return _last.get(key, "")


## How many warnings of this kind were actually printed.
static func printed_count(key: String) -> int:
	return _printed.get(key, 0)


static func reset() -> void:
	revision = 0
	_counts.clear()
	_last.clear()
	_printed.clear()
	_window_start.clear()
	_window_printed.clear()
	_window_suppressed.clear()
	_print_carried.clear()
	_print_used.clear()
	_lazy_kind.clear()
	_lazy_a.clear()
	_lazy_b.clear()
	_lazy_c.clear()
	_lazy_x.clear()
	_lazy_y.clear()
	clock_override_msec = -1


static func _now_msec() -> int:
	return clock_override_msec if clock_override_msec >= 0 else Time.get_ticks_msec()
