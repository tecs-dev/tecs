require("busted")

local luassert <const> = require("luassert")
local cmdharness <const> = require("spec.tecs2d.debug.cmdharness")

local tecs <const> = require("tecs")
local debugcontext <const> = require("tecs2d.debug.internal.debugcontext")

local makeRegistry <const> = cmdharness.makeRegistry
local SpecPos <const> = cmdharness.SpecPos
local SpecTag <const> = cmdharness.SpecTag

describe("tecs2d.debug.internal.cmd.render", function()
    describe("render commands", function()
        it("routes the light verbs as subcommands", function()
            local reg = makeRegistry()
            -- No render pipeline in a headless world: each routed action is
            -- reached and reports it (rather than unknown-command).
            for _, cmdLine in ipairs({"light info", "light color 0.1 0.2 0.3",
                    "light bloom on", "light toggle", "light shadows off"}) do
                local r = reg:execute(cmdLine)
                luassert.is_false(r.ok, cmdLine)
                luassert.equals("no_pipeline", r.code, cmdLine)
            end
            luassert.equals("no_pipeline", (reg:invokeMcp("debug_light_bloom", {on = true})).code)
            luassert.equals("no_pipeline", (reg:invokeMcp("debug_light_info", {})).code)
            luassert.equals("no_pipeline", (reg:invokeMcp("debug_light_toggle", {})).code)
            luassert.equals("no_pipeline", (reg:invokeMcp("debug_light_shadows", {on = false})).code)

            -- Bare `light` needs a verb now.
            local bare = reg:execute("light 0.3 0.3 0.3")
            luassert.is_false(bare.ok)
            luassert.equals("unknown_subcommand", bare.code)
        end)
        it("materials lists the registry and shows GLSL", function()
            local reg = makeRegistry()
            local listed = reg:execute("materials list")
            luassert.is_true(listed.ok, tostring(listed.message))
            luassert.is_false((reg:execute("materials info no-such-material")).ok)
        end)

        it("grid toggles with a default size and honors size=", function()
            local reg, _, ctx = makeRegistry()
            local on = reg:execute("grid")
            luassert.is_true(on.ok, tostring(on.message))
            luassert.is_true(ctx.gridEnabled)
            -- No TileChunk component registered here, so the default applies.
            luassert.equals(32, ctx.gridW)
            luassert.equals(32, ctx.gridH)

            local sized = reg:execute("grid size=16")
            luassert.is_true(sized.ok, tostring(sized.message))
            luassert.equals(16, ctx.gridW)
            luassert.is_true(ctx.gridEnabled)

            local offset = reg:execute("grid offsetX=-8 offsetY=12")
            luassert.is_true(offset.ok, tostring(offset.message))
            luassert.equals(-8, ctx.gridOX)
            luassert.equals(12, ctx.gridOY)
            luassert.equals(-8, offset.data.offsetX)
            luassert.equals(12, offset.data.offsetY)

            local configured = reg:execute("grid size=24 offsetX=3 offsetY=4")
            luassert.is_true(configured.ok, tostring(configured.message))
            luassert.equals(24, ctx.gridW)
            luassert.equals(3, ctx.gridOX)
            luassert.equals(4, ctx.gridOY)

            luassert.is_false((reg:execute("grid size=0")).ok, "zero size must be rejected")

            local off = reg:execute("grid off")
            luassert.is_true(off.ok)
            luassert.is_false(ctx.gridEnabled)
            -- Re-enabling keeps the last size instead of re-detecting.
            reg:execute("grid on")
            luassert.equals(24, ctx.gridW)
            luassert.equals(3, ctx.gridOX)
            luassert.equals(4, ctx.gridOY)
        end)

        it("map info falls back to grid coordinates without tilemaps", function()
            local reg, _, _ctx = makeRegistry()
            luassert.equals("no_map", (reg:execute("map")).code)
            luassert.equals("no_grid", (reg:execute("map info 10 10")).code)
            reg:execute("grid size=16")
            local r = reg:execute("map info 33 -5")
            luassert.is_true(r.ok, tostring(r.message))
            luassert.equals(2, r.data.x)
            luassert.equals(-1, r.data.y)
            luassert.equals(32, r.data.worldX)
            -- An explicit map id still errors when no maps exist.
            luassert.equals("no_map", (reg:execute("map info 33 -5 7")).code)
            reg:execute("grid off")
        end)

        it("camera world and screen convert through the active camera", function()
            local reg, w = makeRegistry()
            luassert.equals("no_pipeline", (reg:execute("camera world 10 20")).code)
            luassert.equals("no_pipeline", (reg:execute("camera screen 10 20")).code)

            -- A minimal fake pipeline: the camera shifts by a fixed offset so
            -- the conversion is observable both ways.
            local pipelinekey = require("tecs2d.gfx.internal.pipelinekey")
            local fakeCam: {string: any} = {}
            fakeCam.toWorld = function(_self: any, x: number, y: number): number, number
                return x + 100, y + 200
            end
            fakeCam.toScreen = function(_self: any, x: number, y: number): number, number
                return x - 100, y - 200
            end
            local fakePipeline: {string: any} = {
                getCamera = function(_self: any, _name?: string): any return fakeCam end,
            }
            (w.resources as {any: any})[pipelinekey.PIPELINE] = fakePipeline

            local toWorld = reg:execute("camera world 10 20")
            luassert.is_true(toWorld.ok, tostring(toWorld.message))
            luassert.same({x = 10, y = 20}, toWorld.data.screen)
            luassert.same({x = 110, y = 220}, toWorld.data.world)

            local toScreen = reg:invokeMcp("debug_camera_screen", {x = 110, y = 220})
            luassert.is_true(toScreen.ok, tostring(toScreen.message))
            luassert.same({x = 110, y = 220}, toScreen.data.world)
            luassert.same({x = 10, y = 20}, toScreen.data.screen)
        end)

        it("bounds toggles the outline overlay", function()
            local reg, _, ctx = makeRegistry()
            luassert.is_true((reg:execute("bounds")).ok)
            luassert.is_true(ctx.showBounds)
            luassert.is_true((reg:execute("bounds off")).ok)
            luassert.is_false(ctx.showBounds)
        end)

    end)
end)
