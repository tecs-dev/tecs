-- The command registry, and what one declaration produces.
--
-- The point of declaring a command rather than a tool is that one declaration
-- has to answer two callers: a typed command line parses through the same
-- schema a JSON tool call validates against, and both reach the same action.
-- So the cases here run the same command both ways and compare.
--
-- The rest is what a declaration controls without restating it: which tool
-- names it projects to, which safety hints those carry, and how a result
-- becomes structured content. Two of those are easy to get subtly wrong and are
-- pinned deliberately. A failed command has to raise through the tool call
-- rather than answer with an `ok` field, or an agent reads a failure as a
-- success. And a nil `message` must not delete a `message` the command's own
-- data supplied, because assigning nil to a Lua table key removes it.

local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local cjson = require("cjson")
local tecs = require("tecs")
local sdl = require("tecs.ffi.sdl3")
local mcp = require("tecs.io.mcp")
local debugapi = require("tecs.debug")

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

local function ok(name, args)
    local result = call(name, args)
    assert.is_falsy(
        result.isError,
        name .. " failed: " .. tostring(result.content and result.content[1] and result.content[1].text)
    )
    return result.structuredContent
end

local function failed(name, args)
    local result = call(name, args)
    assert.is_true(result.isError, name .. " was expected to fail")
    return result.content[1].text
end

local function listed()
    local response = cjson.decode(mcp.dispatch(cjson.encode({
        jsonrpc = "2.0",
        id = 1,
        method = "tools/list",
    })))
    local byName = {}
    for _, tool in ipairs(response.result.tools) do
        byName[tool.name] = tool
    end
    return byName
end

describe("debug command registry", function()
    local world

    setup(function()
        assert(C.SDL_Init(0))
        world = tecs.ecs.newWorld()
        debugapi.ensure(world)

        debugapi.register(world, {
            name = "spec_wave",
            section = "Custom",
            shortHelp = "report the wave a spec pretends to be on",
            agentHelp = "Reports a fixed wave number so a spec can call a command end to end.",
            readOnly = true,
            schema = {
                args = {
                    scale = { kind = "number", default = 1, min = 0, help = "multiplier on the wave" },
                    label = { help = "name reported back" },
                },
                positional = { "scale", "label" },
            },
            outputSchema = {
                ["type"] = "object",
                properties = {
                    wave = { ["type"] = "integer" },
                    label = { ["type"] = "string" },
                },
                required = { "wave" },
            },
            run = function(values)
                return {
                    message = "wave " .. tostring(7 * values.scale),
                    data = { wave = 7 * values.scale, label = values.label or "none" },
                }
            end,
        })

        debugapi.register(world, {
            name = "spec_thing",
            section = "Custom",
            shortHelp = "carry verbs a spec can dispatch",
            subcommands = {
                {
                    name = "list",
                    shortHelp = "answer with a fixed list",
                    run = function()
                        return { data = { items = { "a", "b" } } }
                    end,
                },
                {
                    name = "load",
                    shortHelp = "answer with a failure",
                    schema = {
                        args = { path = { required = true, help = "where from" } },
                        positional = { "path" },
                    },
                    run = function(values)
                        return { ok = false, code = "no_such_file", message = "cannot read " .. values.path }
                    end,
                },
                {
                    name = "keep",
                    shortHelp = "answer with a message inside its own data",
                    run = function()
                        return { data = { message = "from the data" } }
                    end,
                },
            },
        })
    end)

    teardown(function()
        C.SDL_Quit()
    end)

    it("is idempotent, so a second ensure answers with the same registry", function()
        assert.is_true(rawequal(debugapi.ensure(world), debugapi.of(world)))
    end)

    it("projects one tool per action", function()
        local tools = listed()
        assert.is_not_nil(tools.spec_wave)
        assert.is_not_nil(tools.spec_thing_list)
        assert.is_not_nil(tools.spec_thing_load)
        -- A command carrying only verbs has no action of its own, so a bare
        -- tool for it would advertise something nothing dispatches.
        assert.is_nil(tools.spec_thing)
    end)

    it("advertises the declared output schema", function()
        local tool = listed().spec_wave
        assert.are.equal("object", tool.outputSchema.type)
        assert.are.same({ "wave" }, tool.outputSchema.required)
        assert.is_not_nil(tool.outputSchema.properties.label)
    end)

    it("derives safety hints from the verb", function()
        local tools = listed()
        assert.is_true(tools.spec_thing_list.annotations.readOnlyHint)
        assert.is_false(tools.spec_thing_list.annotations.destructiveHint)
        -- Replacing what is there is destructive whatever the command is
        -- called, so `load` carries it without being told.
        assert.is_true(tools.spec_thing_load.annotations.destructiveHint)
        assert.is_false(tools.spec_wave.annotations.destructiveHint)
    end)

    it("turns the schema into an input schema", function()
        local tool = listed().spec_wave
        assert.are.equal("number", tool.inputSchema.properties.scale.type)
        assert.are.equal(0, tool.inputSchema.properties.scale.minimum)
        assert.is_false(tool.inputSchema.additionalProperties)
    end)

    it("answers with the command's data and its message beside it", function()
        local answer = ok("spec_wave", { scale = 2 })
        assert.are.equal(14, answer.wave)
        assert.are.equal("none", answer.label)
        assert.are.equal("wave 14", answer.message)
    end)

    it("keeps a message the data supplied when the result sets none", function()
        assert.are.equal("from the data", ok("spec_thing_keep", {}).message)
    end)

    it("raises a failed command through the tool call", function()
        local text = failed("spec_thing_load", { path = "/nowhere" })
        assert.is_truthy(text:find("no_such_file"))
        assert.is_truthy(text:find("/nowhere"))
    end)

    it("refuses an argument the schema does not declare", function()
        assert.is_truthy(failed("spec_wave", { nonsense = 1 }):find("unknown argument"))
    end)

    it("refuses a value outside a declared bound", function()
        assert.is_truthy(failed("spec_wave", { scale = -1 }):find("at least"))
    end)

    it("refuses a missing required argument", function()
        assert.is_truthy(failed("spec_thing_load", {}):find("missing required argument"))
    end)

    it("reaches the same action from a typed command line", function()
        local registry = debugapi.of(world)
        local typed = registry:execute("spec_wave 2 boss")
        assert.are.equal(14, typed.data.wave)
        assert.are.equal("boss", typed.data.label)
        -- The same values through the other door.
        local decoded = registry:invoke("spec_wave", { scale = 2, label = "boss" })
        assert.are.same(typed.data, decoded.data)
    end)

    it("routes a verb, and falls back to no action when none matches", function()
        local registry = debugapi.of(world)
        assert.are.same({ "a", "b" }, registry:execute("spec_thing list").data.items)
        assert.are.equal("unknown_subcommand", registry:execute("spec_thing nope").code)
    end)

    it("reports an empty line as nothing rather than as a failure", function()
        assert.is_nil(debugapi.of(world):execute(""))
    end)

    it("names the command that does not exist", function()
        local result = debugapi.of(world):execute("nosuchcommand")
        assert.are.equal("unknown_command", result.code)
        assert.is_truthy(result.message:find("nosuchcommand"))
    end)

    it("describes one command's whole contract", function()
        local answer = ok("describe", { command = "spec_thing" })
        assert.are.equal("Custom", answer.section)
        -- A command with no action of its own reports none, which is how a
        -- caller learns there is no bare tool to call.
        assert.is_nil(answer.action)
        local verbs = {}
        for _, verb in ipairs(answer.verbs) do
            verbs[verb.tool] = verb
        end
        assert.are.equal("spec_thing load <path>", verbs.spec_thing_load.signature)
        assert.is_true(verbs.spec_thing_load.destructive)
        assert.is_not_nil(verbs.spec_thing_list.inputSchema)
    end)

    it("lists commands by section, and explains one", function()
        local sections = {}
        for _, section in ipairs(ok("help", {}).sections) do
            sections[section.name] = section
        end
        assert.is_not_nil(sections.Custom)
        assert.is_not_nil(sections.Session)

        local explained = ok("help", { command = "spec_wave" }).command
        assert.are.equal("spec_wave [scale] [label]", explained.signature)
        assert.are.equal(0, #explained.verbs)
    end)

    it("counts what the session registered", function()
        local answer = ok("capabilities", {})
        assert.is_true(answer.commands > 0)
        -- Every command projects at least one tool, and a command with verbs
        -- projects more than one.
        assert.is_true(answer.tools > answer.commands)
    end)

    it("raises on a malformed declaration rather than registering it", function()
        local cases = {
            { name = "spec_wave", shortHelp = "duplicate", run = function() end },
            { name = "spec has spaces", shortHelp = "whitespace", run = function() end },
            { name = "spec_nohelp", run = function() end },
            { name = "spec_noaction", shortHelp = "no action" },
        }
        for _, declaration in ipairs(cases) do
            assert.has_error(function()
                debugapi.register(world, declaration)
            end)
        end
    end)

    it("refuses to register onto a world that has no registry", function()
        assert.has_error(function()
            debugapi.register(tecs.ecs.newWorld(), {
                name = "spec_orphan",
                shortHelp = "never registered",
                run = function() end,
            })
        end)
    end)
end)
