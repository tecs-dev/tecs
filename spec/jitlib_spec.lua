-- LuaJIT's own Lua library, carried in the content root.
--
-- `jit.zone` and `jit.vmdef` are ordinary Lua files that ship beside LuaJIT
-- rather than inside it. `src/tecs/internal/pipeline.tl` attributes a frame's
-- systems with the first and `src/tecs/utils/profile.tl` turns a trace abort
-- code into a sentence with the second, so a tree that carries a LuaJIT and not
-- these has a `require` that fails the moment somebody profiles.
--
-- **This test is about the package, not about this machine.** Requiring
-- `jit.zone` here would pass whatever the package holds, because a plain
-- `luajit` has its own copy on the default `package.path` and would answer from
-- `/opt/homebrew/share/luajit-2.1` without either the build tree or the package
-- carrying anything. So the assertion is on the file being in the content root
-- the build system named, which is the build tree under `cargo xtask test` and
-- an installed one under `cargo xtask test-package`. Only the second proves the thing
-- worth proving, which is why it runs there too rather than only here.
--
local lua = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"

--- Reads a file whole, or nil when there is nothing there.
local function slurp(path)
    local handle = io.open(path, "r")
    if not handle then
        return nil
    end
    local body = handle:read("*a")
    handle:close()
    return body
end

describe("LuaJIT's Lua library", function()
    it("carries jit/zone.lua in the content root", function()
        assert.is_not_nil(slurp(lua .. "/jit/zone.lua"), lua .. "/jit/zone.lua is missing")
    end)

    it("carries jit/vmdef.lua in the content root", function()
        assert.is_not_nil(slurp(lua .. "/jit/vmdef.lua"), lua .. "/jit/vmdef.lua is missing")
    end)

    it("loads the packaged jit.zone rather than a shim", function()
        -- Loaded by path rather than by name, so this is the packaged file and
        -- not whatever the interpreter would have found for itself.
        local chunk = assert(loadfile(lua .. "/jit/zone.lua"))
        local zone = chunk()
        assert.is_function(getmetatable(zone).__call)
        zone("frame")
        assert.are.equal("frame", zone())
    end)

    it("keeps pipeline zones dormant until profiling starts", function()
        require("tecs.ecs")
        local zone = require("jit.zone")
        zone("ignored")
        assert.are.equal(0, #zone)
        zone()
    end)

    it("loads the packaged jit.vmdef with real trace-abort reasons", function()
        local chunk = assert(loadfile(lua .. "/jit/vmdef.lua"))
        local vmdef = chunk()
        assert.is_table(vmdef.traceerr)
        assert.is_string(vmdef.bcnames)
        -- Code zero has meant this since the tables existed, so it is the one
        -- entry worth naming: it says the file is LuaJIT's rather than an
        -- empty table that happened to load.
        assert.is_string(vmdef.traceerr[0])
    end)
end)
