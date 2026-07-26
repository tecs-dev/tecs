-- Tools that read and write the world.
--
-- The protocol is tested elsewhere; what matters here is the semantics an
-- agent relies on. set replaces and modify merges, a component named wrongly
-- is refused rather than guessed at, and a write reaches the GPU rather than
-- only the memory, which is the failure the dirty model exists to prevent.

local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;"
    .. package.path

local cjson = require("cjson")
local tecs = require("tecs")
local sdl = require("tecs.ffi.sdl3")
local mcp = require("tecs.mcp")
local mcpWorld = require("tecs.mcp.world")
local components = require("tecs.components")

local C = sdl.C

local function call(name, args)
    local response = cjson.decode(mcp.dispatch(cjson.encode({
        jsonrpc = "2.0", id = 1, method = "tools/call",
        params = { name = name, arguments = args },
    })))
    return response.result
end

local function ok(name, args)
    local result = call(name, args)
    assert.is_falsy(result.isError,
        name .. " failed: " .. tostring(result.content
            and result.content[1] and result.content[1].text))
    return result.structuredContent
end

describe("mcp world tools", function()
    local world

    setup(function() assert(C.SDL_Init(0)) end)
    teardown(function() C.SDL_Quit() end)

    before_each(function()
        world = tecs.newWorld()
        local known = {}
        for name, value in pairs(components) do
            if type(value) == "table" and value.componentName ~= nil then
                known[name] = value
            end
        end
        mcpWorld.bind(world, known)
    end)

    it("describes components without their interface members", function()
        -- A component carries its own name, id and serializer. Those are not
        -- fields it has, and reporting them would send an agent looking for a
        -- storageType to set.
        local found = {}
        for _, entry in ipairs(ok("components_info", {}).components) do
            found[entry.name] = entry
        end

        assert.are.same({ "id", "param" }, found.Material.fields)
        assert.is_false(found.Material.tag)
        for _, field in ipairs(found.Transform.fields) do
            assert.is_falsy(field:find("^_"))
            assert.are_not.equal("componentName", field)
            assert.are_not.equal("storageType", field)
        end
    end)

    it("reports a component with no data as a tag", function()
        -- Presence is the whole meaning of one, so an empty object would be a
        -- shape a client has to special-case.
        local found = {}
        for _, entry in ipairs(ok("components_info", {}).components) do
            found[entry.name] = entry
        end
        assert.is_true(found.Renderable.tag)

        local entity = world:spawn(components.Renderable())
        assert.are.equal(true, ok("info", { entity = entity }).components.Renderable)
    end)

    it("queries by component and reports what it did not return", function()
        for index = 1, 5 do
            world:spawn(components.Transform(index, 0, 0, 1, 0, 1, 1),
                components.Renderable())
        end
        local result = ok("query",
            { include = { "Transform", "Renderable" }, limit = 2 })

        assert.are.equal(5, result.matched, "the total is not the page")
        assert.are.equal(2, result.returned)
        assert.are.equal(2, #result.entities)
        assert.are.equal(1, result.entities[1].components.Transform.x)
    end)

    it("names the components it knows when given one it does not", function()
        local result = call("query", { include = { "Nonexistent" } })
        assert.is_true(result.isError)
        assert.is_truthy(result.content[1].text:find("Transform", 1, true),
            "the error should list what can be named")
    end)

    it("spawns with defaults for whatever the payload omits", function()
        local spawned = ok("spawn", {
            components = {
                Transform = { x = 10, y = 20 },
                Renderable = {},
            },
        })
        local transform = spawned.components.Transform
        assert.are.equal(10, transform.x)
        -- Not sent, so the component's own default rather than zero.
        assert.are.equal(1, transform.scaleX)
        assert.is_true(world:isAlive(spawned.entity))
    end)

    it("replaces on set and merges on modify", function()
        -- The distinction an agent has to be able to rely on. Tint defaults to
        -- opaque white, so a set naming only green comes back white with green
        -- rather than black with green.
        local entity = world:spawn(components.Tint(0.5, 0.5, 0.5, 0.5))

        local merged = ok("modify",
            { entity = entity, component = "Tint", values = { r = 0.25 } })
        assert.are.equal(0.25, merged.components.Tint.r)
        assert.are.equal(0.5, merged.components.Tint.g, "untouched by modify")

        local replaced = ok("set",
            { entity = entity, component = "Tint", values = { g = 0.75 } })
        assert.are.equal(0.75, replaced.components.Tint.g)
        assert.are.equal(1, replaced.components.Tint.r,
            "omitted fields take the default, because set replaces")
    end)

    it("adds a component on set and says that it did", function()
        local entity = world:spawn(components.Renderable())
        local result = ok("set",
            { entity = entity, component = "Tint", values = { r = 0.5 } })
        assert.is_true(result.added)
        assert.is_true(world:has(entity, components.Tint))
    end)

    it("skips rather than adds when modifying what is not there", function()
        -- A typo in a component name is already refused; this is the other
        -- half, where the name is right but the entity does not carry it.
        -- Adding one would be a surprise an agent cannot undo.
        local entity = world:spawn(components.Renderable())
        local result = ok("modify",
            { entity = entity, component = "Tint", values = { r = 0.5 } })

        assert.is_true(result.skipped)
        assert.is_false(world:has(entity, components.Tint))
    end)

    it("removes and despawns, and says when there was nothing to do", function()
        local entity = world:spawn(components.Renderable(), components.Tint())
        assert.is_false(ok("remove",
            { entity = entity, component = "Tint" }).skipped)
        assert.is_false(world:has(entity, components.Tint))

        assert.is_true(ok("remove",
            { entity = entity, component = "Tint" }).skipped,
            "removing it twice is not an error")

        assert.is_false(ok("despawn", { entity = entity }).skipped)
        assert.is_false(world:isAlive(entity))
        assert.is_true(ok("despawn", { entity = entity }).skipped)
    end)

    it("reports a dead entity rather than failing", function()
        local result = ok("info", { entity = 999999 })
        assert.is_false(result.alive)
    end)

    it("marks a component dirty when it writes one", function()
        -- The failure the dirty model exists to prevent: a write that changes
        -- the memory and leaves whatever consumes the column showing the old
        -- value. Asserted here on the flag rather than on pixels, which the
        -- renderer spec covers.
        local entity = world:spawn(components.Tint(1, 0, 0, 1))
        world:commit()

        local query = world:query({ include = { components.Tint } })
        local function dirty()
            for archetype in query:iter() do
                if archetype:isComponentDirty(components.Tint) then return true end
            end
            return false
        end

        world:update(0)
        assert.is_false(dirty(), "clean after an update with no writes")

        ok("modify", { entity = entity, component = "Tint", values = { g = 1 } })
        assert.is_true(dirty(), "a modify must mark the column")
    end)
end)
