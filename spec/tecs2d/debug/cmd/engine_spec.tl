require("busted")

local luassert <const> = require("luassert")
local cmdharness <const> = require("spec.tecs2d.debug.cmdharness")

local tecs <const> = require("tecs")
local debugcontext <const> = require("tecs2d.debug.internal.debugcontext")

local makeRegistry <const> = cmdharness.makeRegistry
local SpecPos <const> = cmdharness.SpecPos
local SpecTag <const> = cmdharness.SpecTag

describe("tecs2d.debug.internal.cmd.engine", function()
    describe("systems command", function()
        it("stops, restarts, and inspects a system", function()
            local reg, w = makeRegistry()
            local ticks = 0
            w:addSystem({
                name = "spec.Tickable",
                phase = tecs.phases.Update,
                run = function() ticks = ticks + 1 end,
            })
            w:update(0.016)
            luassert.equals(1, ticks)

            luassert.is_true((reg:execute("systems stop spec.Tickable")).ok)
            w:update(0.016)
            luassert.equals(1, ticks, "stopped system still ran")

            local info = reg:execute("systems info spec.Tickable")
            luassert.is_false(info.data.enabled as boolean)

            luassert.is_true((reg:execute("systems start spec.Tickable")).ok)
            w:update(0.016)
            luassert.equals(2, ticks, "restarted system did not run")

            local unknown = reg:execute("systems stop spec.Nope")
            luassert.is_false(unknown.ok)
        end)
    end)

    describe("engine command groups", function()
        it("archetypes lists and selects by archetype id", function()
            local reg, w, ctx = makeRegistry()
            local a = w:spawn(SpecPos(1, 1), SpecTag())
            local b = w:spawn(SpecPos(2, 2), SpecTag())
            w:commit()

            local listed = reg:execute("archetypes list")
            luassert.is_true(listed.ok, tostring(listed.message))
            local archId = 0
            for _, row in ipairs(listed.data.archetypes as {any}) do
                local r = row as {string: any}
                if (r.components as string):find("DbgCmdTag", 1, true) then
                    archId = r.id as integer
                end
            end
            luassert.is_true(archId > 0, "spawned archetype missing from the list")

            local info = reg:execute("archetypes info " .. tostring(archId))
            luassert.equals(2, info.data.entities)
            luassert.is_false((reg:execute("archetypes")).ok, "bare archetypes needs a verb")

            local sel = reg:execute("archetypes select " .. tostring(archId))
            luassert.is_true(sel.ok, tostring(sel.message))
            luassert.is_true(debugcontext.isSelected(ctx, a))
            luassert.is_true(debugcontext.isSelected(ctx, b))
        end)

        it("components shows a schema through the shared entityinfo path", function()
            local reg = makeRegistry()
            local r = reg:execute("components info DbgCmdPos")
            luassert.is_true(r.ok, tostring(r.message))
            luassert.equals("table", r.data.kind)
            local byId = reg:execute("components info " .. tostring(r.data.id))
            luassert.is_true(byId.ok, tostring(byId.message))
            luassert.equals(r.data.name, byId.data.name)
            luassert.is_true((reg:execute("components list")).ok)
            luassert.is_false((reg:execute("components info Nope")).ok)
        end)

        it("states shows, pushes, and pops the state stack", function()
            local reg, w = makeRegistry()
            w:createState("DbgSpecState")

            luassert.is_true((reg:execute("states info")).ok)
            local pushed = reg:execute("states push DbgSpecState")
            luassert.is_true(pushed.ok, tostring(pushed.message))
            luassert.equals("DbgSpecState", w:peekState())

            local shown = reg:execute("states info")
            luassert.equals("DbgSpecState", shown.data.top)

            local popped = reg:execute("states pop")
            luassert.is_true(popped.ok, tostring(popped.message))
            luassert.equals("DbgSpecState", popped.data.popped)
            luassert.is_false((reg:execute("states pop")).ok, "empty stack should refuse")
        end)

        it("subsystem commands fail cleanly when their plugin is absent", function()
            local reg = makeRegistry()
            local expectations: {string: string} = {
                ["layers list"] = "no_pipeline",
                ["layers all"] = "no_pipeline",
                ["layers info 1"] = "no_pipeline",
                ["layers toggle 1"] = "no_pipeline",
                ["physics info"] = "no_physics",
                ["physics raycast 0 0 1 1"] = "no_physics",
                ["controllers list"] = "no_controllers",
                ["audio info"] = "no_audio",
                ["assets list"] = "no_assets",
                ["assets reload foo.png"] = "no_assets",
                ["agent info"] = "no_mcp",
                ["agent connect"] = "no_mcp",
            }
            for cmdLine, code in pairs(expectations) do
                local r = reg:execute(cmdLine)
                luassert.is_false(r.ok, cmdLine)
                luassert.equals(code, r.code, cmdLine)
            end
        end)

        it("fetch returns serialized matches without touching the selection", function()
            local reg, w, ctx = makeRegistry()
            w:spawn(SpecPos(1, 2), SpecTag())
            local plain = w:spawn(SpecPos(3, 4))
            w:commit()

            local r = reg:execute("fetch DbgCmdPos -DbgCmdTag")
            luassert.is_true(r.ok, tostring(r.message))
            luassert.equals(1, r.data.count)
            local row = (r.data.entities as {any})[1] as {string: any}
            luassert.equals(plain, row.id)
            luassert.equals(3, ((row.components as {string: any}).DbgCmdPos as {string: number}).x)
            luassert.matches("DbgCmdPos", row.archetypeComponents as string)
            luassert.is_false(r.data.truncated as boolean)
            luassert.equals(0, #ctx.selected, "fetch must not select")

            local limited = reg:execute("fetch DbgCmdPos limit=1")
            luassert.equals(1, limited.data.count)
            luassert.is_true(limited.data.truncated as boolean)

            luassert.equals("unknown_component", (reg:execute("fetch Nope")).code)
            luassert.equals("invalid_arguments", (reg:execute("fetch -DbgCmdTag")).code,
                "exclude-only expressions must be rejected")
        end)

        it("fetch bounds need all four values and filter via Transform", function()
            local reg, w = makeRegistry()
            local inside = w:spawn(tecs.builtins.Transform(5, 5))
            w:spawn(tecs.builtins.Transform(50, 50))
            w:commit()

            luassert.equals("invalid_arguments",
                (reg:execute("fetch Transform x=0 y=0 w=10")).code)

            local r = reg:execute("fetch Transform x=0 y=0 w=10 h=10")
            luassert.is_true(r.ok, tostring(r.message))
            luassert.equals(1, r.data.count)
            local row = (r.data.entities as {any})[1] as {string: any}
            luassert.equals(inside, row.id)
            luassert.is_not_nil((row.components as {string: any}).Transform,
                "the spatial component must be included")
            local bounds = r.data.bounds as {string: number}
            luassert.equals(0, bounds.x)
            luassert.equals(10, bounds.width)
            luassert.equals(10, bounds.height)
            luassert.is_false(r.data.truncated as boolean)
        end)

        it("resources lists key and type names", function()
            local reg, w = makeRegistry();
            (w.resources as {any: any})[{name = "SpecResourceKey"}] =
                setmetatable({}, {__name = "SpecResourceThing"} as metatable<{string: any}>)

            local r = reg:execute("resources")
            luassert.is_true(r.ok, tostring(r.message))
            luassert.is_true((r.data.count as integer) >= 1)
            local found: {string: any} = nil
            for _, row in ipairs(r.data.resources as {any}) do
                local entry = row as {string: any}
                if entry.key == "SpecResourceKey" then found = entry end
            end
            luassert.is_not_nil(found, "named resource key missing from the list")
            luassert.equals("SpecResourceThing", found.type)
        end)

        it("bundles lists requirements and spawns with overrides", function()
            local reg, w = makeRegistry()
            w:newBundle("specbundle", {required = {SpecPos}, with = {[SpecTag] = true}})

            local listed = reg:execute("bundles list")
            luassert.is_true(listed.ok, tostring(listed.message))
            local b = (listed.data.bundles as {string: any}).specbundle as {string: any}
            luassert.same({"DbgCmdPos"}, b.required)
            luassert.same({"DbgCmdTag"}, b.defaulted)

            local spawned = reg:execute("bundles spawn specbundle {DbgCmdPos = {x = 6, y = 7}}")
            w:commit()
            luassert.is_true(spawned.ok, tostring(spawned.message))
            local id = spawned.data.id as integer
            luassert.is_true(w:isAlive(id))
            luassert.equals(6, (w:get(id, SpecPos) as {string: number}).x)
            luassert.is_true(w:has(id, SpecTag))

            -- The same call shape over MCP with a JSON object.
            local viaMcp = reg:invokeMcp("debug_bundles_spawn",
                {name = "specbundle", components = {DbgCmdPos = {x = 1, y = 2}}})
            w:commit()
            luassert.is_true(viaMcp.ok, tostring(viaMcp.message))
            luassert.is_true(w:isAlive(viaMcp.data.id as integer))

            -- Error parity with the spawn_bundle builtin.
            luassert.equals("spawn_bundle_failed", (reg:execute("bundles spawn nope")).code)
            luassert.equals("unknown_component",
                (reg:execute("bundles spawn specbundle {Nope = {x = 1}}")).code)
            luassert.equals("spawn_bundle_failed",
                (reg:execute("bundles spawn specbundle")).code,
                "a missing required component must fail like the builtin")
        end)

        it("assets reload re-queues cached handles in place", function()
            local reg, w = makeRegistry()
            local assetskey = require("tecs2d.assets")
            local pushed: {any} = {}
            local handle: {string: any} = {
                id = 7, isComplete = true,
                _action = "loadImage", _path = "img/player.png",
                _args = {7, "loadImage", "img/player.png"},
            }
            local playerLog: {string: any} = {action = "loadImage", path = "img/player.png", status = "loaded"}
            local fakeManager: {string: any} = {
                _cache = {["loadImage|img/player.png"] = handle},
                -- The log also remembers a load whose handle was GC'd from
                -- the weak cache (the tiled-example case).
                _assetLog = {
                    ["loadImage|img/player.png"] = playerLog,
                    ["loadImage|img/dropped.png"] =
                        {action = "loadImage", path = "img/dropped.png", status = "loaded"},
                },
                _runningTasks = {},
                _runningCount = 0,
                _pushChannel = {
                    push = function(_self: any, a: any) pushed[#pushed + 1] = a end,
                },
            };
            (w.resources as {any: any})[assetskey] = fakeManager

            local listed = reg:execute("assets list img/")
            luassert.equals(2, listed.data.count, "log-only entries must list too")
            local info = reg:execute("assets info player.png")
            luassert.equals("loaded", info.data.status)
            luassert.is_true(info.data.cached as boolean)
            local dropped = reg:execute("assets info dropped.png")
            luassert.is_false(dropped.data.cached as boolean)

            local r = reg:execute("assets reload player.png")
            luassert.is_true(r.ok, tostring(r.message))
            luassert.equals(1, #pushed)
            luassert.is_false(handle.isComplete as boolean)
            luassert.equals(1, fakeManager._runningCount)
            luassert.equals("loading", playerLog.status)

            -- A handle that is already loading is not re-queued, and a
            -- dropped handle cannot be.
            luassert.is_false((reg:execute("assets reload player.png")).ok)
            luassert.is_false((reg:execute("assets reload dropped.png")).ok)
            luassert.equals(1, #pushed)
        end)

    end)
end)
