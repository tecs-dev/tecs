-- The commands the engine ships, called the way an agent calls them.
--
-- `spec/debug_spec.lua` covers the registry with commands it declares itself,
-- which proves the machinery and proves nothing about the commands that ride on
-- it. So every tool the engine registers is called here against a live world,
-- and the answer is held to the output schema the command advertised.
--
-- That last part is the point rather than a flourish. A command declares the
-- shape of its answer so an agent can rely on it before calling, and a
-- declaration nothing checks is a promise nothing keeps. The check here is
-- deliberately shallow: every key the schema names `required` is present, and
-- an array-typed field is an array rather than the empty object an empty Lua
-- table would otherwise encode as.

local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local cjson = require("cjson")
local tecs = require("tecs")
local sdl = require("tecs.ffi.sdl3")
local mcp = require("tecs.io.mcp")
local debugapi = require("tecs.debug")
local files = require("tecs.io.files")

local C = sdl.C

local function call(name, args)
    local response = cjson.decode(mcp.dispatch(cjson.encode({
        jsonrpc = "2.0",
        id = 1,
        method = "tools/call",
        params = { name = name, arguments = args or {} },
    })))
    return response.result
end

local function failureOf(name, args)
    local result = call(name, args)
    assert.is_true(result.isError, name .. " was expected to fail")
    return result.content[1].text
end

--- The advertised schema for one tool, from the same listing an agent reads.
local function schemaOf(name)
    for _, tool in
        ipairs(cjson.decode(mcp.dispatch(cjson.encode({
            jsonrpc = "2.0",
            id = 1,
            method = "tools/list",
        }))).result.tools)
    do
        if tool.name == name then
            return tool.outputSchema
        end
    end
    return nil
end

--- Calls a tool and holds its answer to what it said the answer would be.
local function ok(name, args)
    local result = call(name, args)
    assert.is_falsy(
        result.isError,
        name .. " failed: " .. tostring(result.content and result.content[1] and result.content[1].text)
    )
    local answer = result.structuredContent

    local schema = schemaOf(name)
    assert.is_not_nil(schema, name .. " advertises no output schema")
    for _, key in ipairs(schema.required or {}) do
        assert.is_not_nil(answer[key], name .. " promised a required '" .. key .. "' and answered without one")
    end
    for key, property in pairs(schema.properties or {}) do
        if property.type == "array" and answer[key] ~= nil then
            -- cjson decodes [] to a table with an array metatable and {} to a
            -- plain one, so the check is that the value is not the object an
            -- empty Lua table would have encoded as.
            assert.are.equal("table", type(answer[key]), name .. " answered a non-table for the array '" .. key .. "'")
        end
    end
    return answer
end

describe("the engine's own debug commands", function()
    local world

    setup(function()
        assert(C.SDL_Init(0))
        world = tecs.ecs.newWorld()
        debugapi.ensure(world)

        -- Something to find. Two archetypes, so `archetypes list` has more than
        -- the empty one to report.
        world:spawn(tecs.Transform2D(10, 20))
        world:spawn(tecs.Transform2D(30, 40), tecs.ecs.Name("named"))
        world:enqueueCommit()
    end)

    teardown(function()
        C.SDL_Quit()
    end)

    describe("archetypes", function()
        it("lists the archetypes holding entities", function()
            local answer = ok("archetypes_list", {})
            assert.is_true(answer.total > 0)
            assert.are.equal(#answer.archetypes, answer.returned)
            local found = false
            for _, row in ipairs(answer.archetypes) do
                assert.is_number(row.id)
                assert.is_number(row.entities)
                for _, name in ipairs(row.components) do
                    found = found or name == "Transform2D"
                end
            end
            assert.is_true(found, "no archetype reported a Transform2D")
        end)

        it("honors its limit", function()
            assert.is_true(#ok("archetypes_list", { limit = 1 }).archetypes <= 1)
        end)

        it("reports one archetype's columns and their dirty state", function()
            local id = ok("archetypes_list", {}).archetypes[1].id
            local answer = ok("archetypes_info", { id = id })
            assert.are.equal(id, answer.id)
            for _, column in ipairs(answer.components) do
                assert.is_string(column.name)
                assert.is_boolean(column.dirty)
            end
        end)

        it("names the archetype that does not exist", function()
            assert.is_truthy(failureOf("archetypes_info", { id = 99999 }):find("unknown_archetype"))
        end)
    end)

    describe("stats", function()
        it("counts what the world holds", function()
            local answer = ok("stats", {})
            assert.is_true(answer.entities >= 2)
            assert.is_true(answer.archetypes > 0)
            assert.is_true(answer.components > 0)
        end)
    end)

    describe("resources", function()
        it("names the keys the world holds a value under", function()
            local answer = ok("resources_list", {})
            local names = {}
            for _, row in ipairs(answer.resources) do
                assert.is_number(row.id)
                assert.is_string(row.valueType)
                if row.name ~= nil then
                    names[row.name] = true
                end
            end
            -- The registry itself is a resource, so a world that answered this
            -- call necessarily holds one.
            assert.is_true(names["tecs.debug"], "the registry did not report its own key")
        end)

        it("reports a key nothing created as absent rather than failing", function()
            local answer = ok("resources_info", { name = "spec.never.created" })
            assert.is_false(answer.present)
        end)

        it("reports a key the world holds", function()
            assert.is_true(ok("resources_info", { name = "tecs.debug" }).present)
        end)
    end)

    describe("materials", function()
        it("lists the materials the renderer can dispatch to", function()
            local answer = ok("materials_list", {})
            -- A headless world has loaded no shaders, so the set may be empty.
            -- What has to hold either way is that the count and the rows agree.
            assert.are.equal(#answer.materials, answer.total)
            for _, row in ipairs(answer.materials) do
                assert.is_number(row.id)
                assert.is_string(row.name)
            end
        end)

        it("names the material that does not exist", function()
            assert.is_truthy(failureOf("materials_info", { name = "no_such_material" }):find("unknown_material"))
        end)
    end)

    describe("snapshot", function()
        it("saves the world and loads it back", function()
            local saved = ok("snapshot_save", { name = "spec-debug-commands.bin" })
            assert.are.equal("binary", saved.format)
            assert.is_string(saved.path)

            local before = ok("stats", {}).entities
            world:spawn(tecs.Transform2D(99, 99))
            world:enqueueCommit()
            assert.are.equal(before + 1, ok("stats", {}).entities)

            local loaded = ok("snapshot_load", { path = saved.path })
            assert.are.equal(saved.path, loaded.path)
            assert.is_number(loaded.version)
            -- The extra entity was spawned after the save, so loading it back
            -- has to have taken the world to where it was.
            assert.are.equal(before, ok("stats", {}).entities)

            os.remove(saved.path)
        end)

        it("reports a path it cannot read rather than raising", function()
            assert.is_truthy(
                failureOf("snapshot_load", { path = files.writablePath("spec-no-such-snapshot.bin") }):find(
                    "read_failed"
                )
            )
        end)
    end)

    describe("profile", function()
        it("samples, writes collapsed stacks, and refuses to start twice", function()
            local started = ok("profile_start", { intervalMs = 1 })
            assert.are.equal(1, started.intervalMs)
            assert.is_truthy(failureOf("profile_start", {}):find("already_running"))

            -- Something for the sampler to see.
            local total = 0
            for index = 1, 200000 do
                total = total + index
            end
            assert.is_true(total > 0)

            local stopped = ok("profile_stop", { name = "spec-debug-commands.collapsed" })
            assert.is_string(stopped.path)
            assert.is_true(stopped.bytes >= 0)
            assert.is_true(stopped.lines >= 0)
            os.remove(stopped.path)
        end)

        it("reports that nothing is running rather than raising", function()
            assert.is_truthy(failureOf("profile_stop", {}):find("not_running"))
        end)
    end)

    describe("physics", function()
        it("reports a world with no simulation as uninstalled", function()
            assert.is_false(ok("physics_info", {}).installed)
        end)

        it("refuses to cast into a world with no simulation", function()
            assert.is_truthy(failureOf("physics_raycast", { x1 = 0, y1 = 0, x2 = 10, y2 = 0 }):find("no_physics"))
        end)

        it("requires the whole segment", function()
            assert.is_truthy(failureOf("physics_raycast", { x1 = 0, y1 = 0 }):find("missing required argument"))
        end)
    end)

    describe("discovery", function()
        it("describes every command the engine registered", function()
            for _, name in ipairs(debugapi.of(world).names) do
                local answer = ok("describe", { command = name })
                assert.are.equal(name, answer.name)
                -- Every action a command declares has to name the tool it
                -- projects to, or an agent reading describe cannot call it.
                if answer.action ~= nil then
                    assert.are.equal(name, answer.action.tool)
                end
                for _, verb in ipairs(answer.verbs) do
                    assert.is_truthy(verb.tool:find("^" .. name .. "_"))
                    assert.is_not_nil(verb.inputSchema)
                end
            end
        end)

        it("counts the commands and the tools they project to", function()
            local answer = ok("capabilities", {})
            assert.are.equal(#debugapi.of(world).list, answer.commands)
            assert.is_true(answer.tools >= answer.commands)
        end)
    end)
end)
