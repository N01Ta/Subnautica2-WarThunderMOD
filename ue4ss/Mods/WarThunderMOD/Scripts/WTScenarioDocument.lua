-- JSON document codec. Arrays keep their type even when empty; unknown fields
-- survive a load/save round trip. No Lua code from a scenario is executed.
local M = {}
local arrayMeta = { __jsonArray = true }
M.null = {}
function M.array(value) return setmetatable(value or {}, arrayMeta) end

local function quote(value)
    local escapes = { ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b',
        ['\f'] = '\\f', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
    return '"' .. value:gsub('[%z\1-\31\\"]', function(c)
        return escapes[c] or string.format("\\u%04x", c:byte())
    end) .. '"'
end

function M.encode(value)
    local seen = {}
    local function emit(v)
        if v == M.null then return "null" end
        local kind = type(v)
        if kind == "string" then return quote(v) end
        if kind == "boolean" then return v and "true" or "false" end
        if kind == "number" then
            assert(v == v and v ~= math.huge and v ~= -math.huge, "non-finite JSON number")
            return string.format("%.17g", v)
        end
        assert(kind == "table", "unsupported JSON value")
        assert(not seen[v], "cyclic JSON value")
        seen[v] = true
        local out = {}
        if getmetatable(v) == arrayMeta then
            for i = 1, #v do out[i] = emit(v[i]) end
            seen[v] = nil
            return "[" .. table.concat(out, ",") .. "]"
        end
        local keys = {}
        for key in pairs(v) do
            assert(type(key) == "string", "object keys must be strings")
            keys[#keys + 1] = key
        end
        table.sort(keys)
        for _, key in ipairs(keys) do out[#out + 1] = quote(key) .. ":" .. emit(v[key]) end
        seen[v] = nil
        return "{" .. table.concat(out, ",") .. "}"
    end
    return emit(value)
end

function M.decode(text)
    local pos = 1
    local function fail(message) error("JSON byte " .. pos .. ": " .. message, 0) end
    local function skip()
        while text:sub(pos, pos):match("%s") and pos <= #text do pos = pos + 1 end
    end
    local function readString()
        pos = pos + 1
        local result = {}
        while pos <= #text do
            local c = text:sub(pos, pos)
            pos = pos + 1
            if c == '"' then return table.concat(result) end
            if c == "\\" then
                local escape = text:sub(pos, pos)
                pos = pos + 1
                local values = { ['"'] = '"', ['\\'] = '\\', ['/'] = '/',
                    b = '\b', f = '\f', n = '\n', r = '\r', t = '\t' }
                if escape == "u" then
                    local hex = text:sub(pos, pos + 3)
                    if not hex:match("^%x%x%x%x$") then fail("invalid unicode escape") end
                    local code = tonumber(hex, 16)
                    pos = pos + 4
                    if code >= 0xD800 and code <= 0xDBFF then
                        if text:sub(pos, pos + 1) ~= "\\u" then fail("missing low surrogate") end
                        local low = tonumber(text:sub(pos + 2, pos + 5), 16)
                        if not low or low < 0xDC00 or low > 0xDFFF then fail("invalid low surrogate") end
                        pos = pos + 6
                        code = 0x10000 + (code - 0xD800) * 1024 + low - 0xDC00
                    elseif code >= 0xDC00 and code <= 0xDFFF then fail("unexpected low surrogate") end
                    result[#result + 1] = utf8.char(code)
                elseif values[escape] then result[#result + 1] = values[escape]
                else fail("invalid escape") end
            else
                if c:byte() < 32 then fail("unescaped control character") end
                result[#result + 1] = c
            end
        end
        fail("unterminated string")
    end
    local read
    read = function(depth)
        if depth > 64 then fail("nesting limit exceeded") end
        skip()
        local c = text:sub(pos, pos)
        if c == '"' then return readString() end
        if c == "[" or c == "{" then
            local isArray = c == "["
            local close = isArray and "]" or "}"
            local value = isArray and M.array() or {}
            pos = pos + 1
            skip()
            if text:sub(pos, pos) == close then pos = pos + 1; return value end
            while true do
                local key
                if not isArray then
                    if text:sub(pos, pos) ~= '"' then fail("expected object key") end
                    key = readString()
                    if value[key] ~= nil then fail("duplicate object key") end
                    skip()
                    if text:sub(pos, pos) ~= ":" then fail("expected colon") end
                    pos = pos + 1
                end
                local item = read(depth + 1)
                if isArray then value[#value + 1] = item else value[key] = item end
                skip()
                local delimiter = text:sub(pos, pos)
                pos = pos + 1
                if delimiter == close then return value end
                if delimiter ~= "," then fail("expected comma or closing bracket") end
                skip()
            end
        end
        for token, value in pairs({ ["true"] = true, ["false"] = false, ["null"] = M.null }) do
            if text:sub(pos, pos + #token - 1) == token then pos = pos + #token; return value end
        end
        local number = text:sub(pos):match("^-?%d+%.?%d*[eE]?[+-]?%d*")
        if not number or not tonumber(number) then fail("expected JSON value") end
        -- Reject Lua-compatible but invalid JSON number spellings.
        if number:match("^-?0%d") or number:match("%.$") or number:match("[eE][+-]?$") then
            fail("invalid number")
        end
        pos = pos + #number
        return tonumber(number)
    end
    local ok, result = pcall(read, 0)
    if not ok then return nil, result end
    skip()
    if pos <= #text then return nil, "JSON byte " .. pos .. ": trailing content" end
    return result
end

function M.new(id, name)
    return { formatVersion = 1, id = id, displayName = name, description = "",
        groups = M.array(), routes = M.array({ { id = "route_01", points = M.array() } }),
        playback = { loop = false, previewSpeed = 1, cleanupOnStop = true,
            fadeInSeconds = 1, postRouteSeconds = 2, fadeOutSeconds = 1.5 } }
end
return M
