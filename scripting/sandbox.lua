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
}

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
	local real_setmetatable = setmetatable
	env.setmetatable = function(t, mt)
		if type(mt) == "table" and rawget(mt, "__gc") ~= nil then
			error("__gc finalizers are not available in scripts", 2)
		end
		return real_setmetatable(t, mt)
	end
	env._G = env
	env._VERSION = _VERSION

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

	-- A hook on the main thread does not cover coroutines a script creates.
	local rc = real.coroutine
	local function reg(co)
		host.reg_thread(co)
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
			return table.unpack(r, 1, r.n)
		end,
		yield = rc.yield,
		status = rc.status,
		isyieldable = rc.isyieldable,
		running = rc.running,
		close = rc.close,
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
			return false, r[2]
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

	-- Bullet handle for one callback. Numbers are a snapshot. Writes sit in Lua
	-- tables the host reads only after a clean return.
	local function make_bullet(id, x, y)
		local vel = { 0, 0, false }
		host._vel = vel
		host._kids = { n = 0 }
		return {
			id = id,
			x = x,
			y = y,
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

	-- Batch view. The packed columns stay in upvalues. The script receives Lua
	-- tables whose metamethods read and write those upvalues. Commands are
	-- appended to a Lua table; the host flushes that table once, after a clean
	-- return. A plain Lua table is the expired flag. The host sets its first
	-- field after the callback. Closures never call the host on this path.
	local function make_batch(token, n, id, px, py, vx, vy, age, pa, pb, owner, dt, cmd_cap, spawn_cap)
		n = math.tointeger(n) or 0
		cmd_cap = math.tointeger(cmd_cap) or 4096
		spawn_cap = math.tointeger(spawn_cap) or 256
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
					if math.type(i) ~= "integer" then
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
					if math.type(i) ~= "integer" or i < 0 or i >= n then
						error("column '" .. name .. "': row must be an integer in 0.." .. tostring(n - 1), 2)
					end
					if not writable then
						error("column '" .. name .. "' is read-only", 2)
					end
					-- Checked here so the store below never raises from native code.
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
			return live() and math.type(i) == "integer" and i >= 0 and i < n
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
