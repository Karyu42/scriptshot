class_name ScriptWarnings
extends RefCounted
## Rate-limited warnings for bad values coming from scripts (NaN, wrong types).
## A script that passes NaN every frame would otherwise bury the log: each kind of
## warning (identified by `key`) is printed LIMIT times, the last one saying that
## the rest are suppressed.

const LIMIT := 3

static var _counts: Dictionary[String, int] = {}


static func warn(key: String, message: String) -> void:
	var seen: int = _counts.get(key, 0)
	_counts[key] = seen + 1
	if seen < LIMIT - 1:
		push_warning(message)
	elif seen == LIMIT - 1:
		push_warning("%s (further warnings of this kind are suppressed)" % message)


## How many times `key` was reported (printed or suppressed).
static func count(key: String) -> int:
	return _counts.get(key, 0)


## How many warnings of this kind were actually printed (at most LIMIT).
static func printed_count(key: String) -> int:
	return mini(count(key), LIMIT)


static func reset() -> void:
	_counts.clear()
