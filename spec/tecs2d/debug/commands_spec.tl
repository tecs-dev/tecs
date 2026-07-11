require("busted")

local luassert <const> = require("luassert")

local cmdharness <const> = require("spec.tecs2d.debug.cmdharness")

local tecs <const> = require("tecs")
local debugcontext <const> = require("tecs2d.debug.internal.debugcontext")
local commands <const> = require("tecs2d.debug.commands")

local makeRegistry <const> = cmdharness.makeRegistry
local SpecPos <const> = cmdharness.SpecPos
local SpecTag <const> = cmdharness.SpecTag

describe("tecs2d.debug.commands registry", function()
    -- A custom command exercising the whole surface: schema parse, data
    -- payload, and both dispatch paths.
    local function helloCommand(): commands.Command
        return {
            name = "hello",
            shortHelp = "greet a target",
            schema = {
                args = { who = {default = "world", help = "who to greet"} },
                positional = {"who"},
            },
            run = function(v: {string: any}, _parts: {string}): commands.Result
                return {ok = true, message = "hello " .. tostring(v.who),
                    data = {who = v.who}}
            end,
        }
    end

    it("dispatches a registered custom command from the typed surface", function()
        local reg = makeRegistry()
        reg:add(helloCommand())

        local r = reg:execute("hello bob")
        luassert.is_true(r.ok)
        luassert.equals("hello bob", r.message)

        local rd = reg:execute("hello")
        luassert.equals("hello world", rd.message)

        local bad = reg:execute("hello a b")
        luassert.is_false(bad.ok)
        luassert.equals("invalid_arguments", bad.code)
    end)

    it("projects a registered command as a debug_* MCP tool", function()
        local reg = makeRegistry()
        reg:add(helloCommand())

        local found: commands.McpTool = nil
        for _, tool in ipairs(reg:mcpTools()) do
            if tool.name == "debug_hello" then found = tool end
        end
        luassert.is_not_nil(found, "debug_hello missing from the projection")
        local props = found.inputSchema.properties as {string: {string: any}}
        luassert.equals("string", props.who.type)

        local r = reg:invokeMcp("debug_hello", {who = "agent"})
        luassert.is_true(r.ok)
        luassert.equals("agent", r.data.who)

        local bad = reg:invokeMcp("debug_hello", {who = 5})
        luassert.is_false(bad.ok)
        luassert.equals("invalid_arguments", bad.code)
    end)

    it("uses mcpHelp for tool descriptions when declared", function()
        local reg = makeRegistry()
        local cmd = helloCommand()
        cmd.mcpHelp = "Greets a target and returns who was greeted."
        reg:add(cmd)

        local byName: {string: commands.McpTool} = {}
        for _, tool in ipairs(reg:mcpTools()) do byName[tool.name] = tool end
        luassert.matches("^Greets a target", byName.debug_hello.description)
        luassert.matches("^Compare two moments structurally", byName.debug_diff.description)
        -- Undeclared tools keep the shortHelp form.
        luassert.matches("^layers list: list named or modified layers", byName.debug_layers_list.description)
    end)

    it("debug_set accepts a JSON object value over MCP", function()
        local reg, w = makeRegistry()
        local eid = w:spawn(SpecPos(1, 2))
        w:commit()
        local r = reg:invokeMcp("debug_set",
            {id = eid, comp = "DbgCmdPos", value = {x = 9, y = 3}})
        w:commit()
        luassert.is_true(r.ok, tostring(r.message))
        local pos = w:get(eid, SpecPos) as {string: number}
        luassert.equals(9, pos.x)
        luassert.equals(3, pos.y)
        -- The legacy Lua-expression string keeps working over MCP too.
        local legacy = reg:invokeMcp("debug_set",
            {id = eid, comp = "DbgCmdPos", value = "{x = 4}"})
        w:commit()
        luassert.is_true(legacy.ok, tostring(legacy.message))
        luassert.equals(4, (w:get(eid, SpecPos) as {string: number}).x)
    end)

    it("capabilities reports plugins, sections, and capture support", function()
        local reg = makeRegistry()
        local r = reg:execute("capabilities")
        luassert.is_true(r.ok, tostring(r.message))
        local plugins = r.data.plugins as {string: any}
        luassert.is_false(plugins.pipeline as boolean, "headless world has no pipeline")
        luassert.is_false(plugins.physics as boolean)
        local cmds = r.data.commands as {string: any}
        luassert.is_true((cmds.count as integer) > 30)
        luassert.is_not_nil((cmds.sections as {string: integer}).Capture)
        luassert.is_true((r.data.capture as {string: any}).snapshots as boolean)
    end)

    it("describe returns one command's full contract", function()
        local reg = makeRegistry()
        local r = reg:invokeMcp("debug_describe", {command = "diff"})
        luassert.is_true(r.ok, tostring(r.message))
        luassert.equals("diff", r.data.name)
        luassert.equals("Capture", r.data.section)
        luassert.equals("debug_diff", r.data.tool)
        luassert.is_not_nil((r.data.inputSchema as {string: any}).properties)
        local subs = r.data.subcommands as {any}
        local sawGet = false
        for _, sub in ipairs(subs) do
            local sc = sub as {string: any}
            if sc.name == "get" then
                sawGet = true
                luassert.equals("debug_diff_get", sc.tool)
                luassert.is_true((sc.annotations as {string: any}).readOnlyHint as boolean)
            end
        end
        luassert.is_true(sawGet, "diff get missing from the description")
        -- MCP-only: the typed surface uses `help` instead.
        luassert.equals("unknown_command", (reg:execute("describe diff")).code)
        luassert.is_false((reg:invokeMcp("debug_describe", {command = "nope"})).ok)
    end)

    it("projects derived and overridden safety annotations", function()
        local reg = makeRegistry()
        local cmd = helloCommand()
        cmd.annotations = {readOnlyHint = true, idempotentHint = true}
        reg:add(cmd)

        local byName: {string: commands.McpTool} = {}
        for _, tool in ipairs(reg:mcpTools()) do byName[tool.name] = tool end

        -- Read verbs derive read-only and idempotent.
        luassert.is_true(byName.debug_archetypes_list.annotations.readOnlyHint)
        luassert.is_true(byName.debug_archetypes_list.annotations.idempotentHint)
        luassert.is_false(byName.debug_archetypes_list.annotations.destructiveHint)
        -- World loads and despawns derive destructive.
        luassert.is_true(byName.debug_rewind_load.annotations.destructiveHint)
        luassert.is_true(byName.debug_despawn.annotations.destructiveHint)
        luassert.is_true(byName.debug_snapshot_clear.annotations.destructiveHint,
            "artifact clears delete files")
        luassert.is_false(byName.debug_mark_clear.annotations.destructiveHint,
            "mark clear only touches UI state")
        -- Everything declares a closed world.
        luassert.is_false(byName.debug_select.annotations.openWorldHint)
        -- Explicit annotations override the derivation.
        luassert.is_true(byName.debug_hello.annotations.readOnlyHint)
        luassert.is_true(byName.debug_hello.annotations.idempotentHint)
    end)

    it("registers through commands.register on a world with the plugin", function()
        local reg, w = makeRegistry()
        commands.register(w, helloCommand())
        luassert.is_not_nil(reg.byName.hello)

        local bare = tecs.newWorld()
        luassert.has_error(function() commands.register(bare, helloCommand()) end)
    end)

    it("scopes an mcp-only command out of the typed surface", function()
        local reg = makeRegistry()
        local cmd = helloCommand()
        cmd.overlay = false
        reg:add(cmd)

        local r = reg:execute("hello")
        luassert.is_false(r.ok)
        luassert.equals("unknown_command", r.code)
        luassert.is_true((reg:invokeMcp("debug_hello", {})).ok)
        for _, n in ipairs(reg.names) do
            luassert.is_true(n ~= "hello", "mcp-only command leaked into completion")
        end
    end)

    it("scopes an overlay-only command out of the MCP projection", function()
        local reg = makeRegistry()
        local cmd = helloCommand()
        cmd.mcp = false
        reg:add(cmd)

        luassert.is_true((reg:execute("hello")).ok)
        local r, err = reg:invokeMcp("debug_hello", {})
        luassert.is_nil(r)
        luassert.matches("unknown debugger tool", err)
    end)

    it("rejects invalid registrations", function()
        local reg = makeRegistry()
        luassert.has_error(function()
            reg:add({name = "clear", shortHelp = "dup",
                run = function(_v: {string: any}, _p: {string}): commands.Result
                    return {ok = true}
                end})
        end)   -- duplicate of the builtin
        luassert.has_error(function()
            reg:add({name = "two words", shortHelp = "bad name",
                run = function(_v: {string: any}, _p: {string}): commands.Result
                    return {ok = true}
                end})
        end)
        luassert.has_error(function()
            reg:add({name = "nohelp",
                run = function(_v: {string: any}, _p: {string}): commands.Result
                    return {ok = true}
                end})
        end)
        luassert.has_error(function()
            reg:add({name = "norun", shortHelp = "no action"})
        end)
        luassert.has_error(function()
            reg:add({name = "quiet", shortHelp = "alias clash", aliases = {"q"},
                run = function(_v: {string: any}, _p: {string}): commands.Result
                    return {ok = true}
                end})
        end)   -- q is the builtin query alias
    end)

    it("registered commands appear in the help listing names", function()
        local reg = makeRegistry()
        reg:add(helloCommand())
        luassert.equals("hello", reg.names[#reg.names])
    end)

    describe("entity edit commands", function()
        it("set writes one component with a Lua table value", function()
            local reg, w = makeRegistry()
            local eid = w:spawn(SpecPos(1, 2))
            w:commit()

            local r = reg:execute("set " .. tostring(eid) .. " DbgCmdPos {x = 5, y = 7}")
            w:commit()
            luassert.is_true(r.ok, tostring(r.message))
            luassert.equals(1, r.data.set)
            local pos = w:get(eid, SpecPos) as {string: number}
            luassert.equals(5, pos.x)
            luassert.equals(7, pos.y)
        end)

        it("set targets @selection", function()
            local reg, w, ctx = makeRegistry()
            local a = w:spawn(SpecPos(0, 0))
            local b = w:spawn(SpecPos(0, 0))
            w:commit()
            ctx.selected = {a, b}

            local r = reg:execute("set @selection DbgCmdPos {x = 3}")
            w:commit()
            luassert.is_true(r.ok, tostring(r.message))
            luassert.equals(2, r.data.set)
            luassert.equals(3, (w:get(a, SpecPos) as {string: number}).x)
            luassert.equals(3, (w:get(b, SpecPos) as {string: number}).x)
        end)

        it("does not accept the selected spelling as a selection alias", function()
            local reg, w, ctx = makeRegistry()
            local eid = w:spawn(SpecPos(0, 0))
            w:commit()
            ctx.selected = {eid}
            local wrongTarget = "@select" .. "ed"

            local r = reg:execute("set " .. wrongTarget .. " DbgCmdPos {x = 3}")
            luassert.is_false(r.ok)
            luassert.matches(wrongTarget, r.message)
        end)

        it("remove strips components from targets", function()
            local reg, w = makeRegistry()
            local eid = w:spawn(SpecPos(1, 1), SpecTag())
            w:commit()

            local r = reg:execute("remove " .. tostring(eid) .. " DbgCmdPos")
            w:commit()
            luassert.is_true(r.ok, tostring(r.message))
            luassert.equals(1, r.data.entities)
            luassert.is_nil(w:get(eid, SpecPos))
        end)

        it("spawn builds an entity from components with Lua values", function()
            local reg, w, ctx = makeRegistry()
            local r = reg:execute("spawn DbgCmdPos {x = 42, y = 9} DbgCmdTag")
            w:commit()
            luassert.is_true(r.ok, tostring(r.message))
            local id = r.data.id as integer
            luassert.is_true(w:isAlive(id))
            luassert.equals(42, (w:get(id, SpecPos) as {string: number}).x)
            luassert.is_true(debugcontext.isSelected(ctx, id), "spawned entity should be selected")
        end)

        it("spawn rejects unknown components and bad expressions", function()
            local reg = makeRegistry()
            local unknown = reg:execute("spawn Nope {x = 1}")
            luassert.is_false(unknown.ok)
            luassert.equals("unknown_component", unknown.code)
            local bad = reg:execute("spawn DbgCmdPos {x = }")
            luassert.is_false(bad.ok)
            luassert.equals("invalid_arguments", bad.code)
        end)

        it("query invert de-selects matching entities from the selection", function()
            local reg, w, ctx = makeRegistry()
            local tagged = w:spawn(SpecPos(0, 0), SpecTag())
            local plain = w:spawn(SpecPos(0, 0))
            w:commit()
            ctx.selected = {tagged, plain}

            local r = reg:execute("query DbgCmdTag invert=true")
            luassert.is_true(r.ok, tostring(r.message))
            luassert.equals(1, r.data.deselected)
            luassert.is_false(debugcontext.isSelected(ctx, tagged),
                "inverted query must de-select the matching entity")
            luassert.is_true(debugcontext.isSelected(ctx, plain),
                "inverted query must keep non-matching selected entities")
        end)

        it("help wraps the command list over multiple popup lines", function()
            local reg = makeRegistry()
            local r = reg:execute("help")
            for _, line in ipairs(r.popup) do
                luassert.is_true(#line <= 70,
                    "help popup line too long: " .. line)
            end
        end)

        it("help lists every command's subcommand verbs", function()
            local reg = makeRegistry()
            local joined = table.concat((reg:execute("help")).popup, "\n")
            luassert.matches("Subcommands:", joined)
            luassert.matches("light\tinfo, color, toggle, shadows, bloom", joined)
            luassert.matches("snapshot\tsave", joined)
        end)

    end)

    describe("draw and ids commands", function()
        it("draw verbs write the annotation store and clear removes", function()
            local reg = makeRegistry()
            local store = reg.env.annotations
            luassert.is_true((reg:execute("draw rect 10 10 5 5 tag=path")).ok)
            luassert.is_true((reg:execute("draw text 0 0 spawn point here tag=path")).ok)
            luassert.equals(2, #store.list)
            luassert.equals("spawn point here", store.list[2].text)

            local viaMcp = reg:invokeMcp("debug_draw_circle", {x = 1, y = 2, radius = 8, entity = 42})
            luassert.is_true(viaMcp.ok)
            luassert.equals(42, store.list[3].entity)

            local cleared = reg:execute("draw clear path")
            luassert.equals(2, cleared.data.cleared)
            luassert.equals(1, #store.list)
        end)

        it("ids toggles the context flag", function()
            local reg, _, ctx = makeRegistry()
            luassert.is_true((reg:execute("ids")).data.shown as boolean)
            luassert.is_true(ctx.showIds)
            luassert.is_false((reg:execute("ids off")).data.shown as boolean)
            luassert.is_false(ctx.showIds)
        end)
    end)

    describe("completion", function()
        it("completes command names in registry order", function()
            local reg = makeRegistry()
            local base, cands = reg:complete("de")
            luassert.equals("", base)
            luassert.same({"despawn"}, cands)
        end)

        it("completes subcommand verbs and their arguments", function()
            local reg, w = makeRegistry()
            w:addSystem({
                name = "spec.Completable",
                phase = tecs.phases.Update,
                run = function() end,
            })
            local base, verbs = reg:complete("systems st")
            luassert.equals("systems ", base)
            luassert.same({"stop", "start"}, verbs)

            local _, names = reg:complete("systems stop spec.Comp")
            luassert.same({"spec.Completable"}, names)
        end)

        it("completes component names, marks, and @selection", function()
            local reg, w, ctx = makeRegistry()
            local eid = w:spawn(SpecPos(0, 0))
            w:commit()
            ctx.marks[eid] = "bossmark"

            local _, comps = reg:complete("query DbgCmdP")
            luassert.same({"DbgCmdPos"}, comps)

            local _, targets = reg:complete("set ")
            local hasSel, hasSelected, hasMark = false, false, false
            local wrongTarget = "@select" .. "ed"
            for _, c in ipairs(targets) do
                if c == "@selection" then hasSel = true end
                if c == wrongTarget then hasSelected = true end
                if c == "bossmark" then hasMark = true end
            end
            luassert.is_true(hasSel, "@selection missing from set targets")
            luassert.is_false(hasSelected, wrongTarget .. " should not be offered as a set target")
            luassert.is_true(hasMark, "mark name missing from set targets")

            local _, third = reg:complete("set 5 DbgCmdP")
            luassert.same({"DbgCmdPos"}, third)
        end)

        it("returns nothing for unknown commands or broken input", function()
            local reg = makeRegistry()
            local _, none = reg:complete("nope arg")
            luassert.equals(0, #none)
            local _, broken = reg:complete("set 5 Foo {x = ")
            luassert.equals(0, #broken)
        end)
    end)

    describe("yank memory", function()
        it("remembers the last output for yank and flattens it", function()
            local reg = makeRegistry()
            luassert.is_nil(reg.lastOutput)

            luassert.is_true((reg:execute("help")).ok)
            luassert.matches("Select:", table.concat(reg.lastOutput, "\n"))

            local flat = commands.flattenOutput(reg.lastOutput)
            luassert.is_nil(flat:find("\t", 1, true), "tabs must flatten for the clipboard")
            luassert.is_nil(flat:find(commands.HRULE, 1, true), "rules must flatten")

            -- Message-only results are remembered too.
            luassert.is_true((reg:execute("bounds on")).ok)
            luassert.equals("bounds on", reg.lastOutput[1])
        end)
    end)

    describe("sections", function()
        it("help groups the command list by section", function()
            local reg = makeRegistry()
            local joined = table.concat((reg:execute("help")).popup, "\n")
            luassert.matches("Select:", joined)
            luassert.matches("Engine:", joined)
            luassert.matches("Session:", joined)
        end)

        it("bare completion carries section separators, prefixes do not", function()
            local reg = makeRegistry()
            local _, all = reg:complete("")
            luassert.equals(commands.SECTION_MARK .. "Select", all[1])
            local plainLast = all[#all]
            luassert.equals("quit", plainLast, "quit must stay the last cycling entry")

            local _, filtered = reg:complete("de")
            luassert.same({"despawn"}, filtered)
        end)
    end)

    describe("history", function()
        it("persists across registry builds and skips repeats", function()
            local files: {string: string} = {}
            local oldRead = love.filesystem.read
            local oldWrite = love.filesystem.write
            local oldRemove = love.filesystem.remove
            love.filesystem.read = function(path: string): string return files[path] end
            love.filesystem.write = function(path: string, contents: string): boolean, string
                files[path] = contents
                return true, nil
            end
            love.filesystem.remove = function(path: string): boolean, string
                files[path] = nil
                return true, nil
            end

            local reg = makeRegistry()
            reg:appendHistory("select 5")
            reg:appendHistory("select 5")
            reg:appendHistory("mark boss")
            luassert.same({"select 5", "mark boss"}, reg.history)

            local reloaded = makeRegistry()
            luassert.same({"select 5", "mark boss"}, reloaded.history)

            local listed = reloaded:execute("history")
            luassert.equals(2, #(listed.data.history as {string}))

            reloaded:execute("history clear")
            luassert.equals(0, #reloaded.history)
            luassert.is_nil(files["debug-history.txt"])

            love.filesystem.read = oldRead
            love.filesystem.write = oldWrite
            love.filesystem.remove = oldRemove
        end)
    end)
end)
