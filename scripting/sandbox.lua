-- G1 sandbox for one LuaState. Runs once in the host's trusted context (real
-- libraries are visible here). Player code only ever sees the environment
-- table this returns. `host` is a table of native callables owned by ScriptHost.
--
-- This is the M1 slice of the spike sandbox: instruction-budget guards, not the
-- capability prompt. io, debug, package, dofile, loadfile and string.dump are
-- absent. The 64 MB cap is enforced by the host hook (soft on stock 0.8.2).

local real = {
	string = string,
	table = table,
	math = math,
	utf8 = utf8,
	coroutine = coroutine,
	os = os,
	load = load,
	collectgarbage = collectgarbage,
	dump = string.dump,
}

-- Host-side helpers keep their own references. Scripts share the math table
-- and may replace its entries; that must not change code the host runs.
local math_type, math_tointeger = math.type, math.tointeger
local math_cos, math_sin = math.cos, math.sin

local MAX_STR = 1024 * 1024
local MAX_PAT_SUBJECT = 1024

return function(host)
	local env = {}

	for _, k in ipairs({
		"assert", "error", "ipairs", "next", "pairs", "select",
		"tonumber", "tostring", "type", "rawequal", "rawget", "rawset", "rawlen",
	}) do
		env[k] = _G[k]
	end

	-- Lua runs __gc with hooks disabled. A spinning finalizer would escape the watchdog.
	-- Lua 5.4 reads __gc only when the metatable is set, so it is checked here.
	local real_setmetatable = setmetatable
	env.setmetatable = function(t, mt)
		if type(mt) == "table" and rawget(mt, "__gc") ~= nil then
			error("__gc finalizers are not available in scripts", 2)
		end
		return real_setmetatable(t, mt)
	end
	env._G = env
	env._VERSION = _VERSION

	-- The host reports a table or userdata error value by its type name. The
	-- value travels inside a private box, and every sandbox catch point (pcall,
	-- xpcall, coroutine.resume, coroutine.close) hands the script its own value back.
	local boxed = real_setmetatable({}, { __mode = "k" })
	local box_mt = {
		table = { __name = "error value (table)", __metatable = false },
		userdata = { __name = "error value (userdata)", __metatable = false },
	}
	local function raise_boxed(v)
		local b = real_setmetatable({}, box_mt[type(v)])
		boxed[b] = v
		error(b, 0)
	end
	local function unbox(e)
		local v = boxed[e]
		if v ~= nil then
			return v
		end
		return e
	end
	env.error = function(v, level)
		local t = type(v)
		if t == "table" or t == "userdata" then
			raise_boxed(v)
		end
		-- Level 1 is still the caller of error(), not this wrapper.
		if level == nil then
			level = 2
		elseif math_type(level) ~= nil and level > 0 then
			level = level + 1
		end
		error(v, level)
	end
	env.assert = function(...)
		local v, msg = ...
		if v then
			return ...
		end
		if select("#", ...) == 0 then
			error("bad argument #1 to 'assert' (value expected)", 2)
		end
		local t = type(msg)
		if t == "table" or t == "userdata" then
			raise_boxed(msg)
		end
		if msg == nil then
			msg = "assertion failed!"
		end
		error(msg, 2)
	end

	-- Buffered in a Lua table. The host drains it after the callback returns,
	-- so a budget stop never lands inside a host call.
	env.print = function(...)
		local buf = host._output
		if type(buf) ~= "table" then
			return
		end
		local n = select("#", ...)
		local parts = {}
		for i = 1, n do
			parts[i] = tostring(select(i, ...))
		end
		local count = (buf.n or 0) + 1
		buf.n = count
		buf[count] = table.concat(parts, "\t")
	end

	env.collectgarbage = function(opt, ...)
		if opt == nil or opt == "collect" or opt == "count" or opt == "step" then
			return real.collectgarbage(opt, ...)
		end
		return 0
	end

	-- Text chunks only. A reader function would run inside a C call, where the hook cannot yield.
	env.load = function(chunk, name, mode, e)
		if type(chunk) ~= "string" then
			error("load: only string chunks are supported", 2)
		end
		return real.load(chunk, name, "t", e or env)
	end

	-- The stock pcall is a C call. A watchdog yield inside it leaves the state
	-- unable to start another coroutine. Run the function on a hooked coroutine
	-- instead, and if that coroutine was stopped, stop this one from Lua too.

	local rs = real.string
	local S = {}
	for k, v in pairs(rs) do
		S[k] = v
	end
	S.dump = nil
	S.rep = function(s, n, sep)
		s = tostring(s)
		if n > 0 and (#s + #(sep or "")) * n > MAX_STR then
			error("string.rep: result too large (sandbox limit)", 2)
		end
		return rs.rep(s, n, sep)
	end
	for _, k in ipairs({ "find", "match", "gmatch", "gsub" }) do
		local f = rs[k]
		S[k] = function(s, ...)
			if #tostring(s) > MAX_PAT_SUBJECT then
				error("string." .. k .. ": subject too long for pattern matching (sandbox limit)", 2)
			end
			return f(s, ...)
		end
	end
	env.string = S
	getmetatable("").__index = S
	-- Scripts do not receive Variant userdata. getmetatable on userdata is nil,
	-- so a shared engine metatable is not something a script can walk.
	local real_getmetatable = getmetatable
	env.getmetatable = function(x)
		if type(x) == "string" then
			return { __index = S }
		end
		if type(x) == "userdata" then
			return nil
		end
		return real_getmetatable(x)
	end
	local real_rawset = rawset
	env.rawset = function(t, k, v)
		if type(t) == "table" and real_getmetatable(t) == false then
			error("cannot modify a protected table", 2)
		end
		return real_rawset(t, k, v)
	end

	env.table = real.table
	env.math = real.math
	env.utf8 = real.utf8
	env.os = { time = real.os.time, clock = real.os.clock }
	env.PI = math.pi
	env.TAU = 2 * math.pi
	env.rad = function(deg)
		if type(deg) ~= "number" then
			error("rad: expected a number of degrees", 2)
		end
		return deg * math.pi / 180
	end
	-- Senses are filled in by the host when earned (see the Senses block
	-- below). An unearned Sense is nil, so
	-- `sense.nearest_enemy and sense.nearest_enemy(...)` is always safe.
	local sense_fields = {}
	local real_next = next
	-- __pairs for a read-only view over `data`. The iterator is a fresh
	-- closure that keeps its own cursor, and the state value handed to the
	-- generic for is the view itself.
	local function ro_pairs(data)
		return function(view)
			local key = nil
			return function()
				local value
				key, value = real_next(data, key)
				return key, value
			end, view, nil
		end
	end
	env.sense = real_setmetatable({}, {
		__index = sense_fields,
		__newindex = function()
			error("sense is read-only", 2)
		end,
		__pairs = ro_pairs(sense_fields),
		__metatable = false,
	})

	-- A hook on the main thread does not cover coroutines a script creates.
	local rc = real.coroutine
	-- Coroutines created by scripts. A yield from any other coroutine is a
	-- yield from a host call; its values are not passed to the host.
	local user_threads = real_setmetatable({}, { __mode = "k" })
	local function reg(co)
		host.reg_thread(co)
		user_threads[co] = true
		return co
	end
	env.coroutine = {
		create = function(f)
			return reg(rc.create(f))
		end,
		wrap = function(f)
			local co = reg(rc.create(f))
			return function(...)
				local r = table.pack(rc.resume(co, ...))
				-- The child was stopped by the host. Spin so this thread's own hook yields it.
				if host.dead() then
					while true do end
				end
				if not r[1] then
					error(r[2], 0)
				end
				return table.unpack(r, 2, r.n)
			end
		end,
		resume = function(co, ...)
			local r = table.pack(rc.resume(co, ...))
			if host.dead() then
				while true do end
			end
			if r[1] == false then
				r[2] = unbox(r[2])
			end
			return table.unpack(r, 1, r.n)
		end,
		yield = function(...)
			if user_threads[rc.running()] then
				return rc.yield(...)
			end
			rc.yield()
		end,
		status = rc.status,
		isyieldable = rc.isyieldable,
		running = rc.running,
		close = function(co)
			local ok, err = rc.close(co)
			if ok then
				return ok
			end
			return false, unbox(err)
		end,
	}
	local rpack, runpack = table.pack, table.unpack
	env.pcall = function(f, ...)
		if type(f) ~= "function" then
			return false, "pcall: attempt to call a " .. type(f) .. " value"
		end
		local co = reg(rc.create(f))
		local r = rpack(rc.resume(co, ...))
		if host.dead() then
			while true do end
		end
		if not r[1] then
			return false, unbox(r[2])
		end
		return true, runpack(r, 2, r.n)
	end
	env.xpcall = function(f, h, ...)
		local r = rpack(env.pcall(f, ...))
		if r[1] then
			return runpack(r, 1, r.n)
		end
		local handled = rpack(env.pcall(h, r[2]))
		return false, handled[2]
	end

	-- Senses (docs/design/vertical-slice.md §6). The host mirrors the
	-- WorldQuery snapshot into the tables below at most once per snapshot
	-- (host.sense_sync), outside any script call. A query is plain Lua over
	-- those tables: it never calls the host, so the watchdog covers all of it
	-- and a stop can never land inside an engine call. Same answers as
	-- WorldQuery.nearest_enemy / enemies_in_radius: centre distance, range
	-- inclusive, ties to the lower id, nearest first.
	--
	-- Results are read-only entity tables, one per body per snapshot (asking
	-- twice in a tick hands back the same table, so a hot loop allocates
	-- nothing). Level I fields: id, pos {x, y}, radius, kind, rarity, alive().
	local SENSE_RANGE = 600       -- range / r when omitted
	local SENSE_R_MAX = 600       -- Level I clamp, both Senses
	local SENSE_LIST_CAP = 256    -- WorldQuery.MAX_RESULTS
	local sense_pcall = env.pcall
	local sense_print = env.print
	local tostr = tostring
	local sense_levels = { nearest_enemy = 0, enemies_in = 0 }
	local S_n = 0
	local S_id, S_x, S_y, S_r, S_kind, S_rar = {}, {}, {}, {}, {}, {}
	-- EnemyKinds.RARITY_* to the script-facing string. RARITY_NONE (-1:
	-- regulars, husks, dummies, halves, adds) and anything unknown are "".
	local RARITY_NAMES = { [0] = "common", [1] = "rare", [2] = "legendary" }
	local S_ent, S_live = {}, {}
	-- [1] = enemies_in lists cut at SENSE_LIST_CAP since the state opened.
	local sense_notes = { 0 }
	host._sense_notes = sense_notes
	local function ro_write()
		error("sense results are read-only", 2)
	end
	local function read_only(data)
		return real_setmetatable({}, {
			__index = data,
			__newindex = ro_write,
			__pairs = ro_pairs(data),
			__metatable = false,
		})
	end
	local function ent_alive(self)
		if type(self) ~= "table" then
			error("alive: call it as e:alive()", 2)
		end
		local id = self.id
		return id ~= nil and S_live[id] == true
	end
	local function entity(row)
		local e = S_ent[row]
		if e == nil then
			e = read_only({
				id = S_id[row],
				pos = read_only({ x = S_x[row], y = S_y[row] }),
				radius = S_r[row],
				kind = S_kind[row],
				rarity = S_rar[row],
				alive = ent_alive,
			})
			S_ent[row] = e
		end
		return e
	end
	local INF = 1 / 0
	-- x, y of a {x, y} table, or nil when they are not finite.
	local function sense_pos(name, pos)
		if type(pos) ~= "table" then
			error(name .. ": pos must be a table with x and y numbers, like { x = 0, y = 0 }", 3)
		end
		local x, y = pos.x, pos.y
		if type(x) ~= "number" or type(y) ~= "number" then
			error(name .. ": pos must be a table with x and y numbers, like { x = 0, y = 0 }", 3)
		end
		if x ~= x or y ~= y or x == INF or x == -INF or y == INF or y == -INF then
			return nil
		end
		return x, y
	end
	local function sense_range(name, r)
		if r == nil then
			return SENSE_RANGE
		end
		if type(r) ~= "number" then
			error(name .. ": range must be a number", 3)
		end
		return r
	end
	local function sense_opts(name, opts)
		if opts == nil then
			return nil, nil
		end
		if type(opts) ~= "table" then
			error(name .. ": opts must be a table, like { exclude = { [e.id] = true } }", 3)
		end
		local ex, filter = opts.exclude, opts.filter
		if ex ~= nil and type(ex) ~= "table" then
			error(name .. ": opts.exclude must be a table keyed by e.id or by e", 3)
		end
		if filter ~= nil and type(filter) ~= "function" then
			error(name .. ": opts.filter must be a function(e)", 3)
		end
		return ex, filter
	end
	-- opts.exclude is keyed by e.id or by an entity table from this snapshot.
	local function excluded(ex, row)
		local hit = ex[S_id[row]]
		if hit ~= nil and hit ~= false then
			return true
		end
		local e = S_ent[row]
		if e == nil then
			return false
		end
		hit = ex[e]
		return hit ~= nil and hit ~= false
	end
	-- Rows within sqrt(limit) of (x, y), not excluded, nearest first (ties:
	-- lower id first). Bottom-up merge sort in plain Lua, so the watchdog can
	-- stop it anywhere.
	local function sense_rows(x, y, limit, ex)
		local rows, ds, n = {}, {}, 0
		local xs, ys = S_x, S_y
		for row = 1, S_n do
			local dx = xs[row] - x
			local dy = ys[row] - y
			local d = dx * dx + dy * dy
			if d <= limit and (ex == nil or not excluded(ex, row)) then
				n = n + 1
				rows[n] = row
				ds[row] = d
			end
		end
		if n < 2 then
			return rows, n
		end
		local src, dst = rows, {}
		local width = 1
		while width < n do
			local lo = 1
			while lo <= n do
				local mid = lo + width
				local hi = mid + width
				if mid > n + 1 then
					mid = n + 1
				end
				if hi > n + 1 then
					hi = n + 1
				end
				local i, j, k = lo, mid, lo
				while k < hi do
					local take_left
					if i >= mid then
						take_left = false
					elseif j >= hi then
						take_left = true
					else
						local a, b = src[i], src[j]
						local da, db = ds[a], ds[b]
						take_left = da < db or (da == db and S_id[a] <= S_id[b])
					end
					if take_left then
						dst[k] = src[i]
						i = i + 1
					else
						dst[k] = src[j]
						j = j + 1
					end
					k = k + 1
				end
				lo = hi
			end
			src, dst = dst, src
			width = width * 2
		end
		return src, n
	end
	-- opts.filter(e): true keeps the candidate. An error skips it and prints
	-- one plain line per query.
	local function sense_keep(name, filter, row, state)
		local ok, res = sense_pcall(filter, entity(row))
		if not ok then
			if not state.printed then
				state.printed = true
				sense_print(name .. ": filter error: " .. tostr(res) .. " (that enemy was skipped)")
			end
			return false
		end
		return res ~= nil and res ~= false
	end

	local function nearest_enemy(pos, range, opts)
		local name = "sense.nearest_enemy"
		local x, y = sense_pos(name, pos)
		range = sense_range(name, range)
		local ex, filter = sense_opts(name, opts)
		if x == nil or range ~= range or range < 0 then
			return nil
		end
		-- Level I clamps the range like enemies_in; Level II would not.
		if sense_levels.nearest_enemy < 2 and range > SENSE_R_MAX then
			range = SENSE_R_MAX
		end
		local limit = range * range
		if filter == nil then
			-- The hot path (homing calls this per bullet): locals only, and the
			-- range test doubles as the "closer than the best so far" test.
			local xs, ys, ids = S_x, S_y, S_id
			local best, best_d = nil, limit
			for row = 1, S_n do
				local dx = xs[row] - x
				local dy = ys[row] - y
				local d = dx * dx + dy * dy
				if d <= best_d and (best == nil or d < best_d or ids[row] < ids[best])
					and (ex == nil or not excluded(ex, row)) then
					best, best_d = row, d
				end
			end
			if best == nil then
				return nil
			end
			return entity(best)
		end
		local rows, n = sense_rows(x, y, limit, ex)
		local state = {}
		for i = 1, n do
			if sense_keep(name, filter, rows[i], state) then
				return entity(rows[i])
			end
		end
		return nil
	end

	local function enemies_in(pos, r, opts)
		local name = "sense.enemies_in"
		local x, y = sense_pos(name, pos)
		r = sense_range(name, r)
		local ex, filter = sense_opts(name, opts)
		local out = {}
		if x == nil or r ~= r or r < 0 then
			return out
		end
		-- Level I clamps the radius; Level II (not in this build) would not.
		if sense_levels.enemies_in < 2 and r > SENSE_R_MAX then
			r = SENSE_R_MAX
		end
		local rows, n = sense_rows(x, y, r * r, ex)
		local k = 0
		local state = filter ~= nil and {} or nil
		for i = 1, n do
			local row = rows[i]
			if filter == nil or sense_keep(name, filter, row, state) then
				if k >= SENSE_LIST_CAP then
					sense_notes[1] = sense_notes[1] + 1
					break
				end
				k = k + 1
				out[k] = entity(row)
			end
		end
		return out
	end

	local SENSE_FNS = { nearest_enemy = nearest_enemy, enemies_in = enemies_in }
	-- Host only: sets the level of one Sense. 0 makes the field nil again.
	host.sense_set = function(id, level)
		local fn = SENSE_FNS[id]
		if fn == nil then
			return false
		end
		level = math_tointeger(level) or 0
		sense_levels[id] = level
		if level > 0 then
			sense_fields[id] = fn
		else
			sense_fields[id] = nil
		end
		return true
	end
	-- Host only: copies one WorldQuery snapshot (packed columns, 0-based).
	-- Entity tables from the previous snapshot keep their values; their
	-- alive() reads the new snapshot. positions_only: the ids, radius, kind
	-- and rarity columns match the last sync, so only x and y are read.
	host.sense_sync = function(n, ids, xs, ys, rs, kinds, rars, positions_only)
		n = math_tointeger(n) or 0
		if positions_only == true and n == S_n then
			local nx, ny = {}, {}
			for row = 1, n do
				nx[row] = xs[row - 1]
				ny[row] = ys[row - 1]
			end
			S_x, S_y = nx, ny
			S_ent = {}
			return
		end
		local nid, nx, ny, nr, nk, nrar, live = {}, {}, {}, {}, {}, {}, {}
		for row = 1, n do
			local id = ids[row - 1]
			nid[row] = id
			nx[row] = xs[row - 1]
			ny[row] = ys[row - 1]
			nr[row] = rs[row - 1]
			nk[row] = tostr(kinds[row - 1])
			nrar[row] = RARITY_NAMES[math_tointeger(rars[row - 1])] or ""
			live[id] = true
		end
		S_n = n
		S_id, S_x, S_y, S_r, S_kind, S_rar = nid, nx, ny, nr, nk, nrar
		S_ent, S_live = {}, live
	end

	-- Bullet handle for one callback. Numbers are a snapshot. Writes sit in Lua
	-- tables the host reads only after a clean return.
	local function make_bullet(id, x, y, bvx, bvy)
		local vel = { 0, 0, false }
		host._vel = vel
		host._kids = { n = 0 }
		return {
			id = id,
			x = x,
			y = y,
			vx = bvx or 0,
			vy = bvy or 0,
			set_velocity = function(self, vx, vy)
				if type(vx) ~= "number" or type(vy) ~= "number" then
					error("set_velocity: expected two numbers", 2)
				end
				vel[1], vel[2], vel[3] = vx, vy, true
			end,
			spawn_child = function(self, cx, cy, vx, vy, life)
				if type(cx) ~= "number" or type(cy) ~= "number" or type(vx) ~= "number"
					or type(vy) ~= "number" or type(life) ~= "number" then
					error("spawn_child: expected numbers (x, y, vx, vy, lifetime)", 2)
				end
				local kids = host._kids
				local count = (kids.n or 0) + 1
				kids.n = count
				kids[count] = { cx, cy, vx, vy, life }
			end,
		}
	end
	host.make_bullet = make_bullet

	-- Every host call into script code goes through this. It passes on the
	-- first return value only, and nothing the host cannot use, so the
	-- callbacks' documented results (can_hit's boolean, the chunk's weapon
	-- table) are unchanged and anything else is ignored. Loaded without line
	-- info, so error(msg, 2) from a callback still carries no position.
	local call_src = [[
		return function(fn, ...)
			local r = fn(...)
			if r ~= nil and type(r) == "thread" then
				return nil
			end
			return r
		end
	]]
	local call_chunk = real.load(real.dump(real.load(call_src, "=host", "t", { type = type }), true), "=host", "b", { type = type })
	host.call = call_chunk()

	-- on_fire(ctx) and spawn{...}. Records sit in a Lua table the host reads
	-- after on_fire returns cleanly; an error or a stop spawns nothing.
	local SPAWN_NUMBERS = { "angle", "speed", "damage", "lifetime", "radius", "spin", "accel" }
	env.spawn = function(def)
		local spawns = host._spawns
		if type(spawns) ~= "table" or not spawns.open then
			error("spawn: only works inside on_fire in this version", 2)
		end
		if type(def) ~= "table" then
			error("spawn: expected a table, like spawn { angle = ctx.aim }", 2)
		end
		local rec = {}
		for _, k in ipairs(SPAWN_NUMBERS) do
			local v = def[k]
			if v ~= nil then
				if type(v) ~= "number" then
					error("spawn: '" .. k .. "' must be a number", 2)
				end
				rec[k] = v
			end
		end
		local pos = def.pos
		if pos ~= nil then
			if type(pos) ~= "table" or type(pos.x) ~= "number" or type(pos.y) ~= "number" then
				error("spawn: 'pos' must be a table with x and y numbers", 2)
			end
			rec.x, rec.y = pos.x, pos.y
		end
		if spawns.n >= spawns.cap then
			spawns.dropped = spawns.dropped + 1
			return false
		end
		spawns.n = spawns.n + 1
		spawns[spawns.n] = rec
		return true
	end

	-- Host code, called from GDScript outside the watchdog: it must not reach
	-- anything a script can replace (see math_cos / math_sin above).
	local function make_ctx(x, y, aim, time, n, pressed, just_pressed, just_released, held, dt, cap)
		host._spawns = { n = 0, dropped = 0, cap = cap, open = true }
		return {
			pos = { x = x, y = y },
			x = x,
			y = y,
			aim = aim,
			aim_dir = { x = math_cos(aim), y = math_sin(aim) },
			time = time,
			n = n,
			shot_count = n,
			pressed = pressed,
			just_pressed = just_pressed,
			just_released = just_released,
			held_time = held,
			dt = dt,
		}
	end
	host.make_ctx = make_ctx

	-- Batch view. The packed columns stay in upvalues. The script receives Lua
	-- tables whose metamethods read and write those upvalues. Commands are
	-- appended to a Lua table; the host flushes that table once, after a clean
	-- return. A plain Lua table is the expired flag. The host sets its first
	-- field after the callback. Closures never call the host on this path.
	local function make_batch(token, n, id, px, py, vx, vy, age, pa, pb, owner, dt, cmd_cap, spawn_cap)
		n = math_tointeger(n) or 0
		cmd_cap = math_tointeger(cmd_cap) or 4096
		spawn_cap = math_tointeger(spawn_cap) or 256
		local OP_KILL, OP_TELEPORT, OP_SPAWN = 0, 1, 2
		-- One array, sized once here. The callback writes packed[n] in order.
		-- A fresh table per command corrupts the state if the watchdog stops the call.
		-- One Lua array for op/row. Floats go in a packed array the host already
		-- allocated: writing that is the same kind of store as a column write.
		local packed = {}
		packed[cmd_cap] = 0
		local nums = host._nums
		host._packed = packed
		local ncmd, nspawn = 0, 0
		local tally = { cmd = 0, spawn = 0, n = 0 }
		local expired = { false }
		host._batch_tally = tally
		host._expired = expired
		local function live()
			return not expired[1]
		end
		local function column(arr, name, writable)
			return setmetatable({}, {
				__index = function(_, i)
					if not live() then
						error("view expired", 2)
					end
					-- A string key is a method lookup. There are no methods;
					-- returning nil keeps them unreachable without a raw value.
					if math_type(i) ~= "integer" then
						if type(i) ~= "number" then
							return nil
						end
						error("column '" .. name .. "': row must be an integer in 0.." .. tostring(n - 1), 2)
					end
					if i < 0 or i >= n then
						error("column '" .. name .. "': row must be an integer in 0.." .. tostring(n - 1), 2)
					end
					return arr[i]
				end,
				__newindex = function(_, i, value)
					if not live() then
						error("view expired", 2)
					end
					if math_type(i) ~= "integer" or i < 0 or i >= n then
						error("column '" .. name .. "': row must be an integer in 0.." .. tostring(n - 1), 2)
					end
					if not writable then
						error("column '" .. name .. "' is read-only", 2)
					end
					-- Type checked in Lua before the store.
					if type(value) ~= "number" then
						error("column '" .. name .. "': value must be a number", 2)
					end
					arr[i] = value
				end,
				__metatable = false,
			})
		end
		local cols = {
			id = column(id, "id", false),
			px = column(px, "px", false),
			py = column(py, "py", false),
			vx = column(vx, "vx", true),
			vy = column(vy, "vy", true),
			age = column(age, "age", false),
			pa = column(pa, "pa", true),
			pb = column(pb, "pb", true),
			owner = column(owner, "owner", false),
		}
		local function row_ok(i)
			return live() and math_type(i) == "integer" and i >= 0 and i < n
		end
		local function row_error(cmd)
			if not live() then
				return "view expired"
			end
			return cmd .. ": row must be an integer in 0.." .. tostring(n - 1)
		end
		local function push(op, row, x, y, vx, vy, life)
			if not live() then
				error("view expired", 2)
			end
			if op == OP_SPAWN and nspawn >= spawn_cap then
				tally.spawn = tally.spawn + 1
				return
			end
			if ncmd >= cmd_cap then
				tally.cmd = tally.cmd + 1
				return
			end
			ncmd = ncmd + 1
			tally.n = ncmd
			if op == OP_SPAWN then
				nspawn = nspawn + 1
			end
			packed[ncmd] = op + row * 8
			local base = (ncmd - 1) * 5
			nums[base] = x
			nums[base + 1] = y
			nums[base + 2] = vx
			nums[base + 3] = vy
			nums[base + 4] = life
		end
		local methods = {
			kill = function(_, i)
				if not row_ok(i) then
					error(row_error("kill"), 2)
				end
				push(OP_KILL, i, 0, 0, 0, 0, 0)
			end,
			teleport = function(_, i, x, y)
				if not row_ok(i) then
					error(row_error("teleport"), 2)
				end
				if type(x) ~= "number" or type(y) ~= "number" then
					error("teleport: expected (row, x, y)", 2)
				end
				push(OP_TELEPORT, i, x, y, 0, 0, 0)
			end,
			spawn_child = function(_, i, x, y, svx, svy, life)
				if not row_ok(i) then
					error(row_error("spawn_child"), 2)
				end
				if type(x) ~= "number" or type(y) ~= "number" or type(svx) ~= "number"
					or type(svy) ~= "number" or type(life) ~= "number" then
					error("spawn_child: expected (row, x, y, vx, vy, lifetime)", 2)
				end
				push(OP_SPAWN, i, x, y, svx, svy, life)
			end,
		}
		return setmetatable({}, {
			__index = function(_, k)
				if not live() then
					error("view expired", 2)
				end
				if k == "n" then
					return n
				end
				if k == "dt" then
					return dt
				end
				local c = cols[k]
				if c ~= nil then
					return c
				end
				return methods[k]
			end,
			__newindex = function()
				error("batch view is read-only", 2)
			end,
			__metatable = false,
		})
	end
	host.make_batch = make_batch

	-- One lock for the whole state. Indexing still works; scripts cannot
	-- replace entries on the shared metatable.
	local variant_mt = getmetatable(host._lock)
	if type(variant_mt) == "table" then
		variant_mt.__metatable = false
	end

	return env
end
