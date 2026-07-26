--- The environment `run_lua` compiles into.
---
--- Two jobs, kept here rather than in the tool so protocol dispatch carries no
--- policy. It decides what code can reach, and it holds the environment across
--- calls so an agent can stash a handle in one call and read it in the next,
--- which is what makes an exploratory session possible at all.
---
--- The filtering is a guard rail, not a security boundary. `run_lua` exists to
--- do what no structured tool covers, so anything reachable from the engine is
--- reachable from it; what is removed are the operations that damage the
--- machine rather than the game, because an agent exploring a world should not
--- be able to delete a file by mistyping a table name.

local cjson <const> = require("cjson")

local record sandbox
    --- Compiles `code` as a function body with `world` in scope. Returns nil
    --- and a diagnostic when it does not compile.
    compile: function(code: string): function(any): any..., string
    --- Forgets everything a previous call stashed.
    reset: function()
    --- Converts a value into something JSON can carry.
    describe: function(value: any, depth?: integer): any
end

local G <const> = _G as {string: any}

-- Reached through _G because Teal targets 5.4's standard library, where these
-- were removed; LuaJIT is 5.1 and has both.
local loadstring <const> =
    G["loadstring"] as function(string, string): function(any): any..., string
local setfenv <const> = G["setfenv"] as function(any, {string: any})

--- Fields of `os` that cannot touch the machine.
local SAFE_OS <const>: {string} = { "time", "clock", "date", "difftime", "getenv" }

--- Names passed through untouched. Everything absent from this list is absent
--- from the environment, so a new global in the host does not silently become
--- reachable.
local PASSED <const>: {string} = {
    "assert", "error", "ipairs", "next", "pairs", "pcall", "print", "select",
    "setmetatable", "getmetatable", "rawget", "rawset", "rawequal", "rawlen",
    "tonumber", "tostring", "type", "unpack", "xpcall", "require",
    "string", "table", "math", "coroutine", "bit", "jit", "ffi",
}

local environment: {string: any} = nil

local function build(): {string: any}
    local env: {string: any} = {}
    for _, name in ipairs(PASSED) do
        env[name] = G[name]
    end

    local safeOs: {string: any} = {}
    local hostOs = G["os"] as {string: any}
    for _, name in ipairs(SAFE_OS) do
        safeOs[name] = hostOs[name]
    end
    env["os"] = safeOs

    -- Absent on purpose: io, dofile, loadfile, load, and os.execute, remove,
    -- rename and exit. Reading and writing files is what the asset and storage
    -- APIs are for, and those go through the platform seam.
    env["_G"] = env
    return env
end

--- The persistent environment, built on first use.
local function current(): {string: any}
    if environment == nil then environment = build() end
    return environment
end

function sandbox.reset()
    environment = nil
end

function sandbox.compile(code: string): function(any): any..., string
    -- Wrapped so a bare expression and a statement block both work, and so
    -- `world` is a parameter rather than something the caller has to close
    -- over. Returning is optional, which is why the envelope reports a count.
    local chunk, reason = loadstring(
        "local world = ...\n" .. code, "=run_lua")
    if chunk == nil then
        -- A bare expression is the common typo, so try it as one before
        -- reporting a syntax error the agent would have to work out.
        local expression = loadstring("local world = ...\nreturn " .. code,
            "=run_lua")
        if expression == nil then return nil, reason end
        chunk = expression
    end

    setfenv(chunk, current())
    return chunk as function(any): any...
end

--- Depth beyond which a table is summarised rather than walked. Deep enough
--- for the shapes an agent asks for, shallow enough that returning the world
--- by mistake answers instead of hanging.
local MAX_DEPTH <const> = 6
local MAX_ENTRIES <const> = 256

--- Converts a value into something `cjson` will encode.
---
--- Necessary because encoding raises on a function, a coroutine or cdata, and
--- an agent that returned one by accident should get a description of it
--- rather than a failed call.
function sandbox.describe(value: any, depth?: integer): any
    depth = depth or 0
    local kind = type(value)

    if value == nil then
        return cjson.null
    elseif kind == "number" or kind == "string" or kind == "boolean" then
        return value
    elseif kind ~= "table" then
        -- Functions, threads, userdata and cdata all land here.
        return ("<%s: %s>"):format(kind, tostring(value))
    end

    if depth >= MAX_DEPTH then
        return ("<table: %s>"):format(tostring(value))
    end

    local out: {string: any} = {}
    local list: {any} = {}
    local isArray = true
    local count = 0

    for key, entry in pairs(value as {any: any}) do
        count = count + 1
        if count > MAX_ENTRIES then
            out["<truncated>"] = true
            isArray = false
            break
        end
        if isArray and type(key) == "number" and key == math.floor(key as number)
            and (key as number) >= 1 then
            list[key as integer] = sandbox.describe(entry, depth + 1)
        else
            isArray = false
            out[tostring(key)] = sandbox.describe(entry, depth + 1)
        end
    end

    if isArray then
        if #list == 0 then return cjson.empty_array end
        return list
    end

    -- A table that turned out to be mixed loses nothing: the numeric keys were
    -- written into `list` and are copied across as strings.
    for index = 1, #list do
        if out[tostring(index)] == nil then out[tostring(index)] = list[index] end
    end
    return out
end

return sandbox
