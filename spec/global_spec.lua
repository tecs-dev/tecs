-- The `tecs` global.
--
-- A game writes `tecs.ecs.newWorld()` in any file with no require line. The
-- global is set by `tecs/init.tl` itself as it returns, so requiring the module
-- anywhere, including transitively, is what makes the global exist. Setting it
-- from the host instead would leave it present for a game and absent under a
-- plain interpreter, so a tool, this suite and the benchmarks would each see a
-- different set of names.
--
-- `tecs/global.d.tl` is what types it, and reads that type off the module
-- rather than restating it. Nothing in this repository is checked against that
-- declaration: `src`, `main.tl` and `bench` all require explicitly, which is
-- how they document their dependency. So a broken declaration would fail for
-- every game and never here, and the last two tests check it directly instead.

local tecs = require("tecs")

--- Type-checks `source` as a Teal file, optionally naming the declaration to
--- the checker, and returns its combined output. Run from the repository root,
--- which is where Busted starts.
local function checkTeal(source, declared)
    local path = os.tmpname()
    local file = assert(io.open(path, "w"))
    file:write(source)
    file:close()

    local command = table.concat({
        "tl",
        declared and "--global-env-def tecs.global" or "",
        "-I src check",
        path,
        "2>&1",
    }, " ")
    local pipe = assert(io.popen(command, "r"))
    local output = pipe:read("*a")
    pipe:close()
    os.remove(path)
    return output
end

-- The ECS and a lazily resolved module, in both positions a name is used in: a
-- value (`tecs.ecs.newWorld`, `tecs.log`) and a type (`tecs.World`,
-- `tecs.application.Application`).
local USAGE = [[
local world = tecs.ecs.newWorld()
world:update(1 / 60)

local logger = tecs.log.get("game")
logger:info("entities: %d", world:getStats().entities)

return tecs.application.create({
    plugin = function(game: tecs.World, app: tecs.application.Application)
        print(app.window ~= nil)
        game:addSystem({
            name = "game.Tick",
            phase = tecs.ecs.phases.Update,
            run = function(dt: number) print(dt) end,
        })
        game:observe(0, tecs.events.on.keyDown, function(event: tecs.events.Event)
            print(event.scancode)
        end)
    end,
})
]]

describe("the tecs global", function()
    it("is the table require returned", function()
        assert.is_not_nil(_G.tecs)
        assert.is_true(rawequal(_G.tecs, tecs))
    end)

    it("resolves an engine module lazily through the same metatable", function()
        -- The metatable is on the table `require` returned, so the global
        -- carries it. Dropping the memoized field puts the name back in the
        -- state it is in before anything reads it, and reading it through the
        -- global has to resolve and memoize exactly as reading it off the
        -- required value does.
        rawset(_G.tecs, "camera", nil)
        assert.is_nil(rawget(_G.tecs, "camera"))

        local camera = _G.tecs.camera
        assert.is_not_nil(camera)
        assert.is_true(rawequal(camera, rawget(_G.tecs, "camera")))

        -- The namespace memoizes its members the same way, and the class it
        -- carries is the module itself rather than a copy of it.
        assert.is_true(rawequal(camera.Camera, require("tecs.gfx.Camera")))
        assert.is_true(rawequal(camera.Camera, rawget(camera, "Camera")))
    end)

    it("answers nil for a member a namespace does not have", function()
        assert.is_nil(_G.tecs.camera.Nosuchthing)
    end)

    it("answers nil for a name that is not a module", function()
        assert.is_nil(_G.tecs.Aplication)
        assert.is_nil(_G.tecs.nosuchthing)
    end)

    it("types a file that uses it, through the declaration", function()
        local output = checkTeal(USAGE, true)
        assert.is_truthy(output:match("0 errors detected"), output)
    end)

    it("is the declaration and not a permissive checker", function()
        -- Without the declaration the same file has no `tecs` at all, which is
        -- what makes the test above evidence of anything.
        local output = checkTeal(USAGE, false)
        assert.is_truthy(output:match("unknown variable: tecs"), output)
    end)
end)
