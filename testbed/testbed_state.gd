class_name TestbedState
extends RefCounted
## Which scene the launcher asked the field to run (static, survives scene changes).

const SCENES := {
	"lua_batch": {"title": "Lua spike: 1,000 scripted bullets (one batched Lua call per tick)", "bullets": 1000, "lua": "batch"},
	"lua_each": {"title": "Lua spike: 1,000 scripted bullets (one Lua call per bullet)", "bullets": 1000, "lua": "each"},
	"plain_5k": {"title": "Plain engine bullets: 5,000", "bullets": 5000, "lua": ""},
	"plain_10k": {"title": "Plain engine bullets: 10,000", "bullets": 10000, "lua": ""},
}

static var current := "plain_5k"
## Auto-run controls from the command line (`-- --scene=lua_batch --seconds=10`), for headless runs.
static var auto_seconds := 0.0
## `-- --shot=/path.png`: save the viewport as PNG ~3.5 s after the scene starts (desktop checks).
static var shot_path := ""
