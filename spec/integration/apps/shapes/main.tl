--- Shapes fixture: an empty deferred-lit scene at full ambient with a
--- fixed camera mapping world coordinates 1:1 to the 320x240 screen.
--- Specs spawn all content over MCP run_lua, so this one app backs the
--- shape matrix, snapshot round-trip, camera behavior, churn soak, and
--- blend mode suites.

local tecs <const> = require("tecs")
local tecs2d <const> = require("tecs")
local mcp <const> = require("tecs.mcp")
local gfx <const> = require("tecs.gfx")

local WIDTH <const> = 320
local HEIGHT <const> = 240

-- Test materials, registered at load time like a real game would.
-- flat: albedo comes entirely from params.xyz (ignores Color).
-- glow: standard albedo plus params.xyz emission scaled by params.w.
local globals <const> = _G as {string: any}
globals.tecsFlatMaterial = gfx.newMaterial("testflat", {
    fragment = [[
        MaterialOutput material(MaterialInput i) {
            MaterialOutput o = standardMaterial(i);
            o.albedo = vec4(i.params.x, i.params.y, i.params.z, 1.0);
            return o;
        }
    ]],
})
globals.tecsGlowMaterial = gfx.newMaterial("testglow", {
    fragment = [[
        MaterialOutput material(MaterialInput i) {
            MaterialOutput o = standardMaterial(i);
            o.emission = vec4(i.params.x * i.params.w, i.params.y * i.params.w,
                i.params.z * i.params.w, 1.0);
            return o;
        }
    ]],
})

-- Capabilities the lovespecs need beyond the run_lua sandbox (ffi for the
-- virtual SDL gamepad, collectgarbage for leak measurement). The sandbox
-- reads through to game globals by design, so the app hands these out
-- deliberately; agent-facing games never define them.
globals.tecsTestHooks = {
    ffi = require("ffi"),
    gc = collectgarbage,
}

local function gamePlugin(world: tecs.World)
    world:addPlugin(mcp.new({
        port = tonumber(os.getenv("TECS_MCP_PORT")) or mcp.DEFAULT_PORT,
    }))

    local pipeline = world.resources[gfx.PIPELINE] as gfx.Pipeline
    pipeline:getCamera():setPosition(WIDTH / 2, HEIGHT / 2)
end

love.run = tecs.run({
    fps = 60,
    game = gamePlugin,
    render = {
        virtualHeight = HEIGHT,
        lightingMode = "deferred",
        ambientLight = {1.0, 1.0, 1.0},
        lerpingEnabled = false,
    },
})
