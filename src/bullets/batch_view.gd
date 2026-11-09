class_name BatchView
extends RefCounted
## One behavior's bullets for a single batch-hook call.
##
## The columns are packed copies (M1). A later zero-copy backing can replace
## these arrays inside this same object. Scripts keep using `batch.n`,
## `batch.vx[i]` and the methods below; they do not name the backing.
##
## Valid indices are `0 .. n - 1`, and only during the callback. Do not store
## the view or its columns. `vx`, `vy`, `pa` and `pb` are the writable copies.
## `px`, `py`, `age`, `id` and `owner` are read-only: assigning them changes
## this copy and nothing in the sim. Move a bullet with `teleport`. Owner
## changes only through `reflect()`, which this view does not expose.
##
## Column writes and commands apply when the callback returns, after this
## tick's integrate and before collision. Each write is checked against the
## stable id captured here. A despawn, or a slot reused under a new generation,
## drops that row. A callback that fails applies nothing (`discard`).


const CMD_KILL := 0
const CMD_TELEPORT := 1
const CMD_SPAWN := 2

var n := 0
var dt := 0.0
## How many leading rows live in NativeBulletSim. The rest, if any, are pool
## slots: a bullet spawned from a hook stays on the pool, and the next batch
## still includes it. Zero when every row is a pool bullet.
var native_rows := 0
## True when every row is native. Kept so a caller can see which backing it got.
var native := false
## Set when the script errors. Commit then drops writes and commands.
var discard := false

var id := PackedInt64Array()
var px := PackedFloat32Array()
var py := PackedFloat32Array()
var vx := PackedFloat32Array()
var vy := PackedFloat32Array()
var age := PackedFloat32Array()
var pa := PackedFloat32Array()
var pb := PackedFloat32Array()
var owner := PackedInt32Array()

var _op := PackedInt32Array()
var _row := PackedInt32Array()
var _x := PackedFloat32Array()
var _y := PackedFloat32Array()
var _spawn: Array[ShotRequest] = []
var _spawn_cmd := PackedInt32Array()
var _count := 0


func kill(i: int) -> void:
	_push(CMD_KILL, i, 0.0, 0.0)


func teleport(i: int, x: float, y: float) -> void:
	_push(CMD_TELEPORT, i, x, y)


## Child of the bullet at row `i`. The engine inherits that bullet's owner and
## spawns into the GDScript pool, the same rule as a spawn from `on_update`.
## `request.behavior_id` is the caller's. A row whose id was reused drops the
## spawn. Killing that row earlier in the callback does not: the owner was
## copied when the view was built.
func spawn_child(i: int, request: ShotRequest) -> void:
	var at := _count
	_push(CMD_SPAWN, i, 0.0, 0.0)
	_spawn.append(request)
	_spawn_cmd.append(at)


func command_count() -> int:
	return _count


func command_op(c: int) -> int:
	return _op[c]


func command_row(c: int) -> int:
	return _row[c]


func command_x(c: int) -> float:
	return _x[c]


func command_y(c: int) -> float:
	return _y[c]


func spawn_request(c: int) -> ShotRequest:
	for k in _spawn_cmd.size():
		if _spawn_cmd[k] == c:
			return _spawn[k]
	return null


func _push(op: int, row: int, x: float, y: float) -> void:
	if _op.size() == _count:
		var next := maxi(_count * 2, 8)
		_op.resize(next)
		_row.resize(next)
		_x.resize(next)
		_y.resize(next)
	_op[_count] = op
	_row[_count] = row
	_x[_count] = x
	_y[_count] = y
	_count += 1
