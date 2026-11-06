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
	env.getmetatable = function(x)
		if type(x) == "string" then
			return { __index = S }
		end
		return getmetatable(x)
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

	return env
end
