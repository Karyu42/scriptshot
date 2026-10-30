-- sandbox.lua (spike): builds the per-script environment table from a capability set.
-- Runs ONCE per LuaState in the host's trusted context (real libs available). Player code never sees `real`.
-- Usage (host):  local build = state.do_string(src) ; local env = build(caps, host)
-- `host` = { print=Callable, reg_thread=Callable, exit=Callable, spawn=Callable, ... } (native, validated in GDScript)
local real = {
  string = string, table = table, math = math, utf8 = utf8, coroutine = coroutine,
  os = os, io = io, debug = debug, package = package, load = load, collectgarbage = collectgarbage,
}

local MAX_STR = 1024 * 1024     -- largest string a script may create via string.rep
local MAX_PAT_SUBJECT = 1024         -- pattern matching is O(n^2) worst case; bound the subject

return function(caps, host)
  caps = caps or {}
  local env = {}

  -- ---- base library -----------------------------------------------------------------------
  for _, k in ipairs { "assert", "error", "ipairs", "next", "pairs", "select", "tonumber", "tostring", "type",
                       "rawequal", "rawget", "rawset", "rawlen", "pcall" } do
    env[k] = _G[k]
  end
  -- Lua runs __gc finalizers with hooks disabled, so a spinning finalizer would escape the watchdog.
  -- Finalizers are therefore not available to scripts (__close and __mode are fine).
  local real_setmetatable = setmetatable
  env.setmetatable = function(t, mt)
    if type(mt) == "table" and rawget(mt, "__gc") ~= nil then error("__gc finalizers are not available in scripts", 2) end
    return real_setmetatable(t, mt)
  end
  env._G = env
  env._VERSION = _VERSION
  env.print = function(...) host.print(...) end
  env.collectgarbage = function(opt, ...)
    if opt == nil or opt == "collect" or opt == "count" or opt == "step" then return real.collectgarbage(opt, ...) end
    return 0   -- 'stop', 'incremental', 'generational', ... are ignored: scripts cannot disable the GC
  end
  env.load = function(chunk, name, mode, e)            -- text chunks only (no reader functions: they would run in a C-call boundary)
    if type(chunk) ~= "string" then error("load: only string chunks are supported", 2) end
    return real.load(chunk, name, "t", e or env)
  end
  -- xpcall: Lua runs a message handler with hooks disabled and in a non-yieldable context. A handler that spins
  -- would escape the watchdog (measured: hang). The core therefore only ever runs a trivial handler; the script's
  -- handler is called afterwards, from normal (hooked, yieldable) context. Trade-off: no stack at handler time.
  local rx, rpack, runpack = xpcall, table.pack, table.unpack
  local function trivial(m) return m end
  env.xpcall = function(f, h, ...)
    local r = rpack(rx(f, trivial, ...))
    if r[1] then return runpack(r, 1, r.n) end
    local ok, v = pcall(h, r[2])
    return false, v
  end

  -- ---- string (bounded) ------------------------------------------------------------------
  local rs = real.string
  local S = {}
  for k, v in pairs(rs) do S[k] = v end
  S.dump = nil                                       -- no bytecode generation (load is text-only too)
  S.rep = function(s, n, sep)
    s = tostring(s)
    if n > 0 and (#s + #(sep or "")) * n > MAX_STR then error("string.rep: result too large (sandbox limit)", 2) end
    return rs.rep(s, n, sep)
  end
  for _, k in ipairs { "find", "match", "gmatch", "gsub" } do
    local f = rs[k]
    S[k] = function(s, ...)
      if #s > MAX_PAT_SUBJECT then error("string." .. k .. ": subject too long for pattern matching (sandbox limit)", 2) end
      return f(s, ...)
    end
  end
  env.string = S
  -- the string metatable is per-state: point it at the bounded table so ("x"):rep() is bounded too
  real.string_meta_index = S
  getmetatable("").__index = S
  env.getmetatable = function(x)
    if type(x) == "string" then return { __index = S } end
    return getmetatable(x)
  end

  env.table, env.math, env.utf8 = real.table, real.math, real.utf8
  env.os = { time = real.os.time, clock = real.os.clock }   -- always available (PR #1); the rest of os needs the `os` capability

  -- ---- coroutine: every thread a script creates gets the host watchdog hook -----------------
  local rc = real.coroutine
  local function reg(co) host.reg_thread(co); return co end
  env.coroutine = {
    create = function(f) return reg(rc.create(f)) end,
    wrap = function(f)
      local co = reg(rc.create(f))
      return function(...)
        local r = table.pack(rc.resume(co, ...))
        if host.dead() then while true do end end   -- a child was stopped by the host: stop the parent too (its hook yields it)
        if not r[1] then error(r[2], 0) end
        return table.unpack(r, 2, r.n)
      end
    end,
    resume = function(co, ...) local r = table.pack(rc.resume(co, ...)); if host.dead() then while true do end end; return table.unpack(r, 1, r.n) end, yield = rc.yield, status = rc.status, isyieldable = rc.isyieldable, running = rc.running, close = rc.close,
  }

  -- ---- capabilities --------------------------------------------------------------------------
  if caps.os then
    local o = {}
    for k, v in pairs(real.os) do o[k] = v end
    o.exit = function() host.exit(); while true do end end    -- never exits the game: ends THIS script (host sees the flag in its hook)
    env.os = o
  end
  if caps.io then
    local i = {}
    for k, v in pairs(real.io) do i[k] = v end
    if not caps.os then i.popen = nil end                     -- io.popen runs programs: it belongs to `os`, not `io`
    env.io = i
    -- dofile / loadfile exist ONLY with `io`, text mode only (binary chunks are refused everywhere: load mode 't')
    env.loadfile = function(path, mode, e)
      local fh, err = real.io.open(path, "rb")
      if not fh then return nil, err end
      local text = fh:read("a"); fh:close()
      return real.load(text, "@" .. tostring(path), "t", e or env)       -- a chunk starting with ESC is refused by mode 't'
    end
    env.dofile = function(path)
      local f, err = env.loadfile(path)
      if not f then error(err, 2) end
      return f()
    end
  elseif caps.os then
    env.io = { popen = real.io.popen }                        -- `os` alone: only the program-running member of io
  end
  if caps.debug then
    local d = {}
    for k, v in pairs(real.debug) do d[k] = v end
    d.sethook = function() end                                -- accepted, ignored: the watchdog hook is host-owned
    d.gethook = function() return nil end
    d.getregistry = nil                                       -- registry holds the hook table and engine userdata
    -- upvalue access would reach the bounded-string wrappers' original functions and the host callables
    d.getupvalue, d.setupvalue, d.upvalueid, d.upvaluejoin = nil, nil, nil, nil
    d.getlocal, d.setlocal = nil, nil                       -- temporaries of wrapper frames (e.g. the real gsub) are visible through getlocal
    d.setmetatable = function(o, mt)
      if type(mt) == "table" and rawget(mt, "__gc") ~= nil then error("__gc finalizers are not available in scripts", 2) end
      return real.debug.setmetatable(o, mt)
    end
    env.debug = d
  end
  -- ---- require --------------------------------------------------------------------------------
  -- Always available WITHOUT any capability, but confined: .lua modules from the script's own folder subtree only,
  -- read-only, text-only, loaded into the same sandbox env (so the same guards and the same watchdog apply).
  local loaded = { _G = env, string = S, table = real.table, math = real.math, utf8 = real.utf8, coroutine = env.coroutine }
  loaded.os, loaded.io, loaded.debug = env.os, env.io, env.debug      -- only what was granted
  local function own_folder_searcher(n)
    if type(n) ~= "string" or not n:match("^[%a_][%w_]*[%.%w_]*$") or n:find("%.%.") or n:sub(-1) == "." then
      return "module name '" .. tostring(n) .. "' is not allowed (own-folder modules use plain dotted names)"
    end
    local path = host.script_dir .. "/" .. n:gsub("%.", "/") .. ".lua"
    local text = host.read_text(path)          -- native: refuses anything outside script_dir, non-.lua, '..', absolute paths
    if not text then return "no module '" .. n .. "' in the script folder" end
    local f, err = real.load(text, "@" .. path, "t", env)
    if not f then error(err, 0) end
    return f, path
  end
  local searchers = { function(n) local f = loaded[n]; return f and function() return f end or "no preload" end, own_folder_searcher }
  if caps.package or caps.native then
    -- `package` unlocks arbitrary paths and package.path changes (Lua searchers 1 and 2 with the usual semantics)
    local p = { path = "res://scripts/?.lua", loaded = loaded, preload = {}, searchers = {} }
    p.searchers[1] = function(n) local f = p.preload[n]; if f then return f end return "no field package.preload['" .. n .. "']" end
    p.searchers[2] = function(n)
      local path = p.path:gsub("%?", (n:gsub("%.", "/")))
      local f = host.load_file and host.load_file(path, env)
      if f then return f, path end
      return "no file '" .. path .. "'"
    end
    if caps.native then      -- only `native` gets the C searchers (3: C module, 4: all-in-one C loader), loadlib and cpath
      p.loadlib = real.package.loadlib; p.cpath = real.package.cpath
      p.searchers[3] = real.package.searchers[3]; p.searchers[4] = real.package.searchers[4]
    end
    env.package = p
    searchers = p.searchers
  end
  env.require = function(n)
    local m = loaded[n]; if m ~= nil then return m end
    for _, s in ipairs(searchers) do
      local f, extra = s(n)
      if type(f) == "function" then local r = f(n, extra); loaded[n] = r == nil and true or r; return loaded[n] end
    end
    error("module '" .. tostring(n) .. "' not found", 2)
  end

  -- ---- engine facade: thin Lua stubs over validated native Callables ------------------------
  env.spawn = function(x, y, angle, speed, lifetime) return host.spawn(x, y, angle, speed, lifetime) end
  env.set_player_hp = function(v) return host.set_player_hp(v) end
  return env
end
