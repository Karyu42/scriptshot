-- Trusted, host-side. Copies a weapon's `state` table between versions, which
-- may live in different Lua states: encode() turns env.state into a plain-ASCII
-- blob, decode() rebuilds it as env.state in another env. Player code never
-- sees these functions. Only plain data is copied (nil, booleans, numbers,
-- strings, tables); metatables are not. Within one copy a table referenced
-- twice stays one table; a cycle is cut at the back-reference; functions,
-- userdata, threads and non-plain keys are dropped. Depth, entries and bytes
-- are capped, so the work is bounded whatever the script stored. Each drop or
-- cut is reported once per kind in the blob header (see ScriptHost).

return function(MAX_DEPTH, MAX_ENTRIES, MAX_BYTES)
	local type, next, rawget, rawset, pcall, error = type, next, rawget, rawset, pcall, error
	local tonumber, select = tonumber, select
	local mtype, tointeger, huge = math.type, math.tointeger, math.huge
	local format, gsub, sub, find, byte, char = string.format, string.gsub, string.sub, string.find, string.byte, string.char
	local concat = table.concat
	local NL = char(10)
	-- Control bytes, '%' and bytes >= 127 travel as %XX, so a blob is plain
	-- ASCII and survives the trip through a Godot String.
	local ESC, UNESC = {}, {}
	for i = 0, 255 do
		local hex = format("%02X", i)
		UNESC[hex] = char(i)
		if i < 32 or i >= 127 or i == 37 then
			ESC[char(i)] = "%" .. hex
		end
	end
	local ESC_PAT = "[" .. char(0) .. "-" .. char(31) .. "%%" .. char(127) .. "-" .. char(255) .. "]"

	local function label(path, n)
		local parts = { "state" }
		for i = 1, n do
			if i > 6 then
				parts[#parts + 1] = "..."
				break
			end
			local k = path[i]
			local tk = type(k)
			if tk == "string" and #k <= 24 and find(k, "^[%a_][%w_]*$") then
				parts[#parts + 1] = "." .. k
			elseif mtype(k) == "integer" then
				parts[#parts + 1] = "[" .. format("%d", k) .. "]"
			elseif tk == "string" then
				local short = gsub(sub(k, 1, 16), "[^%w_ ]", "?")
				parts[#parts + 1] = "[\"" .. short .. (#k > 16 and "..." or "") .. "\"]"
			else
				parts[#parts + 1] = "[" .. tk .. "]"
			end
		end
		return concat(parts)
	end

	local function encode(env)
		if type(env) ~= "table" then
			return ""
		end
		local root = rawget(env, "state")
		if root == nil then
			return ""
		end
		local out, n = {}, 0
		local bytes, entries = 0, 0
		local ids, onstack, nid = {}, {}, 0
		local stopped = false
		local path = {}
		-- Per kind: how many times, and where first.
		local wcount, wwhere, worder = {}, {}, {}
		local function note(kind, depth)
			if wcount[kind] == nil then
				wcount[kind] = 0
				wwhere[kind] = label(path, depth)
				worder[#worder + 1] = kind
			end
			wcount[kind] = wcount[kind] + 1
		end
		local function emit(s)
			n = n + 1
			out[n] = s
			bytes = bytes + #s
		end
		-- The token for a plain non-table value, or nil (and a note) when it
		-- does not fit in what is left of MAX_BYTES.
		local function scalar(v, depth)
			local tv = type(v)
			if tv == "boolean" then
				return v and "1" or "0"
			elseif tv == "number" then
				if mtype(v) == "integer" then
					return "i" .. format("%d", v) .. ";"
				elseif v ~= v then
					return "fnan;"
				elseif v == huge then
					return "finf;"
				elseif v == -huge then
					return "f-inf;"
				end
				return "f" .. format("%a", v) .. ";"
			elseif tv == "string" then
				if #v > MAX_BYTES - bytes then
					return nil
				end
				local e = gsub(v, ESC_PAT, ESC)
				return "s" .. #e .. ":" .. e
			end
			return nil
		end
		local function over(extra, depth)
			if bytes + extra > MAX_BYTES then
				stopped = true
				note("bytes", depth)
				return true
			end
			return false
		end
		local encode_table
		-- Writes the pair k = v of a table at `depth` (1 = a key of state).
		local function pair(k, v, depth)
			path[depth] = k
			entries = entries + 1
			if entries > MAX_ENTRIES then
				stopped = true
				note("entries", depth)
				return
			end
			local tk = type(k)
			if tk ~= "string" and tk ~= "number" and tk ~= "boolean" then
				note("key", depth)
				return
			end
			local ktok = scalar(k, depth)
			if ktok == nil then
				over(#k, depth)
				return
			end
			local tv = type(v)
			if tv == "table" then
				if onstack[v] then
					note("cycle", depth)
					return
				end
				local id = ids[v]
				if id ~= nil then
					local r = "R" .. id .. ";"
					if over(#ktok + #r, depth) then
						return
					end
					emit(ktok)
					emit(r)
					return
				end
				if depth >= MAX_DEPTH then
					note("depth", depth)
					return
				end
				if over(#ktok + 2, depth) then
					return
				end
				emit(ktok)
				encode_table(v, depth)
				return
			end
			if tv == "function" or tv == "userdata" or tv == "thread" then
				note(tv, depth)
				return
			end
			local vtok = scalar(v, depth)
			if vtok == nil then
				over(#v, depth)
				return
			end
			if over(#ktok + #vtok, depth) then
				return
			end
			emit(ktok)
			emit(vtok)
		end
		encode_table = function(t, depth)
			nid = nid + 1
			ids[t] = nid
			onstack[t] = true
			emit("T")
			local k = nil
			while not stopped do
				local nk, v = next(t, k)
				if nk == nil then
					break
				end
				k = nk
				pair(nk, v, depth + 1)
			end
			onstack[t] = nil
			emit("E")
		end
		local tr = type(root)
		if tr == "table" then
			encode_table(root, 0)
		elseif tr == "function" or tr == "userdata" or tr == "thread" then
			note(tr, 0)
		else
			local tok = scalar(root, 0)
			if tok == nil then
				note("bytes", 0)
			else
				emit(tok)
			end
		end
		local w = {}
		for i = 1, #worder do
			local kind = worder[i]
			local where, times = wwhere[kind], wcount[kind]
			local more = times > 1 and format(" (%d places)", times) or ""
			local msg
			if kind == "function" or kind == "userdata" or kind == "thread" then
				msg = format("%s is a %s; state keeps only plain data (nil, booleans, numbers, strings, tables), so it was not copied%s", where, kind, more)
			elseif kind == "key" then
				msg = format("%s has a key that is not a string, number or boolean; that entry was not copied%s", where, more)
			elseif kind == "cycle" then
				msg = format("%s points back to a table that contains it; the loop was cut there%s", where, more)
			elseif kind == "depth" then
				msg = format("%s is nested more than %d tables deep; the deeper part was not copied%s", where, MAX_DEPTH, more)
			elseif kind == "entries" then
				msg = format("state has more than %d entries; the rest was not copied (from %s on)", MAX_ENTRIES, where)
			else
				msg = format("state is larger than %d KiB; the rest was not copied (from %s on)", MAX_BYTES // 1024, where)
			end
			w[#w + 1] = msg
		end
		local wtext = gsub(concat(w, NL), ESC_PAT, function(c)
			return c == NL and NL or "?"
		end)
		return "W" .. #wtext .. ":" .. wtext .. concat(out, "", 1, n)
	end

	-- Fills env.state from an encode() blob of any state. False when the blob
	-- is not one (env.state is left as it was).
	local function decode(env, blob)
		if type(env) ~= "table" or type(blob) ~= "string" then
			return false
		end
		local p = 1
		if sub(blob, 1, 1) == "W" then
			local c = find(blob, ":", 2, true)
			local len = c and tointeger(tonumber(sub(blob, 2, c - 1)))
			if len == nil then
				return false
			end
			p = c + 1 + len
		end
		if p > #blob then
			return true
		end
		local ids, nid = {}, 0
		local function num(q)
			local e = find(blob, ";", q, true)
			return sub(blob, q, e - 1), e + 1
		end
		local val
		val = function(q, depth)
			local c = sub(blob, q, q)
			if c == "1" then
				return true, q + 1
			elseif c == "0" then
				return false, q + 1
			elseif c == "i" then
				local s, r = num(q + 1)
				local v = tointeger(tonumber(s))
				if v == nil then
					error("bad integer")
				end
				return v, r
			elseif c == "f" then
				local s, r = num(q + 1)
				if s == "nan" then
					return 0 / 0, r
				elseif s == "inf" then
					return huge, r
				elseif s == "-inf" then
					return -huge, r
				end
				-- encode() writes "%a", which always reads back as a float
				-- (no "+ 0.0": that would turn -0.0 into 0.0).
				local v = tonumber(s)
				if mtype(v) ~= "float" then
					error("bad float")
				end
				return v, r
			elseif c == "s" then
				local colon = find(blob, ":", q + 1, true)
				local len = tointeger(tonumber(sub(blob, q + 1, colon - 1)))
				local e = sub(blob, colon + 1, colon + len)
				if #e ~= len then
					error("short string")
				end
				return (gsub(e, "%%(%x%x)", UNESC)), colon + 1 + len
			elseif c == "R" then
				local s, r = num(q + 1)
				local t = ids[tointeger(tonumber(s))]
				if t == nil then
					error("bad reference")
				end
				return t, r
			elseif c == "T" then
				if depth > MAX_DEPTH then
					error("too deep")
				end
				local t = {}
				nid = nid + 1
				ids[nid] = t
				q = q + 1
				while sub(blob, q, q) ~= "E" do
					local k, v
					k, q = val(q, depth + 1)
					v, q = val(q, depth + 1)
					if k == nil or k ~= k then
						error("bad key")
					end
					rawset(t, k, v)
				end
				return t, q + 1
			end
			error("bad blob")
		end
		local ok, v, q = pcall(val, p, 0)
		if not ok or q ~= #blob + 1 then
			return false
		end
		rawset(env, "state", v)
		return true
	end

	return { encode = encode, decode = decode }
end
