class_name ScriptProblem
extends RefCounted
## One thing the in-game editor tells the player about their script: a compile
## error, a runtime error, a guard stop or an engine warning, in short plain
## language with the line it belongs to. `details` keeps the original text for
## the editor's "details" toggle. Nothing here touches Lua.

enum Kind { COMPILE, RUNTIME, GUARD, WARNING }

var kind: Kind = Kind.RUNTIME
## 1-based line in the player's script, or 0 when there is none to point at.
var line := 0
## Short sentence for the player, without the line prefix.
var message := ""
## The callback the problem came from ("on_hit"), or "" for a load.
var callback := ""
## The original text, with internal chunk names and paths removed.
var details := ""
## How many times this problem happened (runtime errors and warnings repeat).
var count := 1


const STILL_RUNNING := "Still running the last good script."
const STILL_BASIC := "Still running the basic shot."


## The one-sentence line (vertical-slice §7.5): "line 4: expected ')' before
## '2'." or the message alone when there is no line. A repeat count is added
## as "  ×N". The callback and the original text are in `details`, not here.
func text() -> String:
	var out := message if line <= 0 else "line %d: %s" % [line, _lead_lower(message)]
	if count > 1:
		out += "  ×%d" % count
	return out


## The status line under the editor: text() without the count, then what
## keeps running ("Still running the last good script.").
func headline(has_good_script: bool = true) -> String:
	var out := message if line <= 0 else "line %d: %s" % [line, _lead_lower(message)]
	return "%s %s" % [out, STILL_RUNNING if has_good_script else STILL_BASIC]


## Where it came from and the original text, for the "details" toggle.
func detail_text() -> String:
	var where := "line %d, " % line if line > 0 else ""
	return "%s%s: %s" % [where, callback if callback != "" else "load", details]


## Same problem (for counting repeats): kind, line, message and callback.
func key() -> String:
	return "%d|%d|%s|%s" % [kind, line, callback, message]


## Builds the problem for a failed ScriptHost result. `chunk_name` is the name
## the script was loaded under; `callback` is "" for a load or apply.
static func from_result(result: ScriptHost.RunResult, chunk_name: String, callback: String = "") -> ScriptProblem:
	if result.error == LuaShot.NO_TABLE_ERROR:
		return not_a_weapon()
	var p := ScriptProblem.new()
	p.callback = callback
	if result.stopped != "":
		p.kind = Kind.GUARD
		p.line = result.stop_line
		p.message = guard_message(result.stopped)
		p.details = guard_details(result.stopped)
		return p
	var split := split_location(result.error, chunk_name)
	var line_no: int = split[0]
	var rest: String = split[1]
	p.line = line_no
	p.details = rest
	p.message = plain_message(rest)
	p.kind = Kind.COMPILE if callback == "" and is_compile_error(rest) else Kind.RUNTIME
	return p


## A problem for a load that ran but did not return a weapon table.
static func not_a_weapon() -> ScriptProblem:
	var p := ScriptProblem.new()
	p.kind = Kind.COMPILE
	p.message = "The script must end with return { ... } (a table of settings and callbacks)."
	p.details = "the chunk returned no table"
	return p


## Builds a problem for a ScriptWarnings report (`key`, `message`, `count`).
static func from_warning(key_name: String, text: String, times: int) -> ScriptProblem:
	var p := ScriptProblem.new()
	p.kind = Kind.WARNING
	p.count = maxi(times, 1)
	p.details = strip_internals(text)
	p.message = plain_warning(key_name, text)
	return p


## Short sentence for a watchdog stop. How to fix it is in details.
static func guard_message(stopped: String) -> String:
	match stopped:
		"instruction budget", "wall clock":
			return "script timeout."
		"memory cap":
			return "script used too much memory."
	return "script stopped by a safety limit."


## What the guard limit was, for the details toggle.
static func guard_details(stopped: String) -> String:
	match stopped:
		"instruction budget":
			return "ran more than %s steps in one call. Look for a loop that never ends." % _thousands(ScriptHost.INSTRUCTION_BUDGET)
		"wall clock":
			return "took longer than %d ms in one call. Look for a loop that never ends." % ScriptHost.WALL_MSEC
		"memory cap":
			return "used more than %d MB of memory. Look for a table that keeps growing." % (ScriptHost.MEMORY_CAP / (1024 * 1024))
	return "stopped by the %s limit" % stopped


## [line, rest]: pulls "chunk:LINE:" off the front of a Lua message when the
## chunk is the player's script, then strips any other internal location.
static func split_location(raw: String, chunk_name: String) -> Array:
	var text := raw.strip_edges()
	var line := 0
	var re := RegEx.create_from_string("^(?:@)?([^:\\n]*?):(\\d+):\\s*")
	var m := re.search(text)
	if m != null:
		var chunk := m.get_string(1)
		if chunk == chunk_name or chunk.get_file() == chunk_name.get_file() or chunk.begins_with("[string"):
			line = m.get_string(2).to_int()
		text = text.substr(m.get_end())
	return [line, strip_internals(text)]


## Removes engine paths, chunk names and table addresses from a message.
static func strip_internals(raw: String) -> String:
	var text := raw
	# "LuaBulletBehavior: on_hit: " and other "Class.method: " prefixes.
	text = RegEx.create_from_string("^(?:[A-Z][A-Za-z]+(?:\\.[A-Za-z_]+)*(?:\\(\\))?:\\s*)+(?:on_[a-z_]+:\\s*)?").sub(text, "")
	# Any remaining "something.lua:12:" or "res://...:12:" location.
	text = RegEx.create_from_string("(?:@)?(?:res|user)://[^\\s:]*(?::\\d+)?:?\\s*").sub(text, "", true)
	text = RegEx.create_from_string("[A-Za-z0-9_/\\.-]+\\.lua:\\d+:\\s*").sub(text, "", true)
	text = RegEx.create_from_string("\\[string \"[^\"]*\"\\]:\\d+:\\s*").sub(text, "", true)
	text = RegEx.create_from_string("0x[0-9a-fA-F]+").sub(text, "…", true)
	return text.strip_edges()


static func is_compile_error(text: String) -> bool:
	return (
		text.contains("expected")
		and text.contains("near")
		or text.contains("unexpected symbol")
		or text.contains("malformed number")
		or text.contains("unfinished string")
		or text.contains("unfinished long")
		or text.contains("<eof>")
	) and not text.contains("bad argument")


## Rewrites the common Lua messages into plain sentences. Unknown messages
## are kept, with a capital letter and a full stop.
static func plain_message(text: String) -> String:
	var t := text.strip_edges()
	var m: RegExMatch
	m = _match("^'end' expected \\(to close '(\\w+)' at line (\\d+)\\) near (.+)$", t)
	if m != null:
		return "Missing 'end' for the '%s' that starts on line %s." % [m.get_string(1), m.get_string(2)]
	m = _match("^'(.+)' expected \\(to close '(.+)' at line (\\d+)\\) near (.+)$", t)
	if m != null:
		return "Missing '%s' to close the '%s' on line %s." % [m.get_string(1), m.get_string(2), m.get_string(3)]
	m = _match("^'(.+)' expected near <eof>$", t)
	if m != null:
		return "The script ends too early: expected '%s'." % m.get_string(1)
	m = _match("^'(.+)' expected near (.+)$", t)
	if m != null:
		return "Expected '%s' before %s." % [m.get_string(1), _near(m.get_string(2))]
	m = _match("^(.+) expected near (.+)$", t)
	if m != null:
		return "Expected %s before %s." % [m.get_string(1), _near(m.get_string(2))]
	m = _match("^unexpected symbol near (.+)$", t)
	if m != null:
		return "Unexpected %s here." % _near(m.get_string(1))
	m = _match("^unfinished string near .+$", t)
	if m != null:
		return "A string is missing its closing quote."
	m = _match("^unfinished long (string|comment).*$", t)
	if m != null:
		return "A long %s is missing its closing ]]." % m.get_string(1)
	m = _match("^malformed number near (.+)$", t)
	if m != null:
		return "%s is not a valid number." % _near(m.get_string(1))
	m = _match("^attempt to call a nil value \\((global|local|upvalue) '(.+)'\\)$", t)
	if m != null:
		return "'%s' is not a function (it is nil). Check the spelling." % m.get_string(2)
	m = _match("^attempt to call a nil value \\((method|field) '(.+)'\\)$", t)
	if m != null:
		return "'%s' does not exist here, so it cannot be called." % m.get_string(2)
	m = _match("^attempt to call a (\\w+) value(?: \\((?:global|local|field|method|upvalue) '(.+)'\\))?$", t)
	if m != null:
		var what := "'%s'" % m.get_string(2) if m.get_string(2) != "" else "This value"
		return "%s is a %s, not a function." % [what, m.get_string(1)]
	m = _match("^attempt to index a nil value \\((global|local|upvalue) '(.+)'\\)$", t)
	if m != null:
		return "'%s' is nil, so it has no fields. Is it defined?" % m.get_string(2)
	m = _match("^attempt to index a nil value \\(field '(.+)'\\)$", t)
	if m != null:
		return "'%s' is nil, so it has no fields." % m.get_string(1)
	m = _match("^attempt to index a (\\w+) value(?: \\((?:global|local|field|upvalue) '(.+)'\\))?$", t)
	if m != null:
		var what_i := "'%s'" % m.get_string(2) if m.get_string(2) != "" else "This value"
		return "%s is a %s, so it has no fields." % [what_i, m.get_string(1)]
	m = _match("^attempt to perform arithmetic on a (\\w+) value(?: \\((?:global|local|field|upvalue|constant) '(.+)'\\))?$", t)
	if m != null:
		var what_a := "'%s'" % m.get_string(2) if m.get_string(2) != "" else "a value"
		return "Can't do math with %s: it is %s." % [what_a, _article(m.get_string(1))]
	m = _match("^attempt to concatenate a (\\w+) value(?: \\((?:global|local|field|upvalue) '(.+)'\\))?$", t)
	if m != null:
		var what_c := "'%s'" % m.get_string(2) if m.get_string(2) != "" else "a value"
		return "Can't join %s into text: it is %s." % [what_c, _article(m.get_string(1))]
	m = _match("^attempt to compare (\\w+) with (\\w+)$", t)
	if m != null:
		return "Can't compare %s with %s." % [_article(m.get_string(1)), _article(m.get_string(2))]
	m = _match("^attempt to compare two (\\w+) values$", t)
	if m != null:
		return "Can't compare two %s values." % m.get_string(1)
	m = _match("^bad argument #(\\d+) to '(.+)' \\((.+) expected, got (.+)\\)$", t)
	if m != null:
		return "%s(): argument %s should be %s, got %s." % [m.get_string(2), m.get_string(1), _article(m.get_string(3)), _article(m.get_string(4))]
	m = _match("^bad argument #(\\d+) to '(.+)' \\((.+)\\)$", t)
	if m != null:
		return "%s(): argument %s is wrong (%s)." % [m.get_string(2), m.get_string(1), m.get_string(3)]
	m = _match("^(\\w+): expected (.+)$", t)
	if m != null:
		return "%s() expected %s." % [m.get_string(1), m.get_string(2)]
	if t == "" or t.begins_with("table: ") or t == "nil":
		return "The script raised an error without a message."
	if t == "view expired":
		return "The batch view was used after its callback returned."
	return _sentence(t)


## Plain sentence for a ScriptWarnings report.
static func plain_warning(key_name: String, text: String) -> String:
	var t := strip_internals(text)
	var m := _match("^(?:[a-z_ ]+ )?(speed|vx|vy|lifetime|radius|damage|param_a|param_b|acceleration|turn_rate) ([-0-9.e]+|nan|inf|-inf) is outside its allowed range and was clamped to ([-0-9.e]+).*$", t)
	if m != null:
		return "%s %s is out of range; the game used %s instead." % [m.get_string(1).capitalize(), _short_number(m.get_string(2)), _short_number(m.get_string(3))]
	m = _match("^(.+), the bullet was removed \\(DespawnReason\\.INVALID\\)$", t)
	if m != null:
		return "A shot was removed: %s." % m.get_string(1)
	m = _match("^rejected a shot with a non-finite (.+)$", t)
	if m != null:
		return "A shot was not fired: its %s was not a finite number." % m.get_string(1)
	if key_name.begins_with("LuaBulletBehavior.error."):
		return plain_message(t)
	return _sentence(t)


static func _match(pattern: String, text: String) -> RegExMatch:
	return RegEx.create_from_string(pattern).search(text)


static func _near(token: String) -> String:
	var t := token.strip_edges()
	if t == "<eof>":
		return "the end of the script"
	return t


static func _article(type_name: String) -> String:
	var t := type_name.strip_edges()
	if t == "nil" or t == "no value":
		return t
	if t.begins_with("a") or t.begins_with("e") or t.begins_with("i") or t.begins_with("o") or t.begins_with("u"):
		return "an " + t
	return "a " + t


static func _sentence(t: String) -> String:
	if t == "":
		return t
	var first := t.get_slice(" ", 0)
	var out := t
	if RegEx.create_from_string("^[a-z]+[,.!?]?$").search(first) != null:
		out = t.substr(0, 1).to_upper() + t.substr(1)
	if not (out.ends_with(".") or out.ends_with("!") or out.ends_with("?") or out.ends_with(")")):
		out += "."
	return out


## "Expected ')'" -> "expected ')'" so the line reads as one sentence after
## "line 4: ". Names in quotes and other starts are left alone.
static func _lead_lower(t: String) -> String:
	if RegEx.create_from_string("^[A-Z][a-z']+[\\s,.:]").search(t) != null:
		return t.substr(0, 1).to_lower() + t.substr(1)
	return t


## "9000.0" -> "9000".
static func _short_number(t: String) -> String:
	return t.trim_suffix(".0") if t.ends_with(".0") else t


static func _thousands(n: int) -> String:
	var s := str(n)
	var out := ""
	var i := s.length()
	while i > 3:
		out = "," + s.substr(i - 3, 3) + out
		i -= 3
	return s.substr(0, i) + out
