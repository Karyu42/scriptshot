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
		"tonumber", "tostring", "type", "rawequal", "rawget", "rawset", "rawlen", "pcall",
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

	env.print = function(...)
		local n = select("#", ...)
		local parts = {}
		for i = 1, n do
			parts[i] = tostring(select(i, ...))
		end
		host.print(table.concat(parts, "\t"))
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

	-- xpcall runs the message handler with hooks off and non-yieldable. A spinning
	-- handler would hang the game. Run a trivial handler inside xpcall, then the
	-- script's handler from normal (hooked, yieldable) context.
	local rx, rpack, runpack = xpcall, table.pack, table.unpack
	local function trivial(m)
		return m
	end
	env.xpcall = function(f, h, ...)
		local r = rpack(rx(f, trivial, ...))
		if r[1] then
			return runpack(r, 1, r.n)
		end
		local _ok, v = pcall(h, r[2])
		return false, v
	end

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

	-- Bullet handle for one callback. Numbers are a snapshot. Writes are queued
	-- in the host and committed only if this callback returns.
	local function make_bullet(id, x, y)
		return {
			id = id,
			x = x,
			y = y,
			set_velocity = function(self, vx, vy)
				local err = host.set_velocity(vx, vy)
				if err ~= nil then
					error(err, 2)
				end
			end,
			spawn_child = function(self, cx, cy, vx, vy, life)
				local err = host.spawn_child(cx, cy, vx, vy, life)
				if err ~= nil then
					error(err, 2)
				end
			end,
		}
	end
	host.make_bullet = make_bullet

	-- Batch view. The packed columns stay in upvalues. The script receives Lua
	-- tables whose metamethods read and write those upvalues. The view is only
	-- valid for this call: host.expire_batch marks it expired when the call returns.
	local function make_batch(token, n, id, px, py, vx, vy, age, pa, pb, owner, dt)
		n = math.tointeger(n) or 0
		local expired = { false }
		host.expire_batch = function()
			expired[1] = true
		end
		local function column(arr, name, writable)
			return setmetatable({}, {
				__index = function(_, i)
					if expired[1] then
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
					if expired[1] then
						error("view expired", 2)
					end
					if math.type(i) ~= "integer" or i < 0 or i >= n then
						error("column '" .. name .. "': row must be an integer in 0.." .. tostring(n - 1), 2)
					end
					if not writable then
						error("column '" .. name .. "' is read-only", 2)
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
			return not expired[1] and math.type(i) == "integer" and i >= 0 and i < n
		end
		local function row_error(cmd)
			if expired[1] then
				return "view expired"
			end
			return cmd .. ": row must be an integer in 0.." .. tostring(n - 1)
		end
		local methods = {
			kill = function(_, i)
				if not row_ok(i) then
					error(row_error("kill"), 2)
				end
				local err = host.batch_kill(token, i)
				if err ~= nil then
					error(err, 2)
				end
			end,
			teleport = function(_, i, x, y)
				if not row_ok(i) then
					error(row_error("teleport"), 2)
				end
				local err = host.batch_teleport(token, i, x, y)
				if err ~= nil then
					error(err, 2)
				end
			end,
			spawn_child = function(_, i, x, y, svx, svy, life)
				if not row_ok(i) then
					error(row_error("spawn_child"), 2)
				end
				local err = host.batch_spawn(token, i, x, y, svx, svy, life)
				if err ~= nil then
					error(err, 2)
				end
			end,
		}
		return setmetatable({}, {
			__index = function(_, k)
				if expired[1] then
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
	local variant_mt = getmetatable(host.print)
	if type(variant_mt) == "table" then
		variant_mt.__metatable = false
	end

	return env
end
