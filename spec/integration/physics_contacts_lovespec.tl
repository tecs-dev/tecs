--- Love2D integration suite: physics contact events. A ball dropped onto
--- the tiledphysics fixture's floor must emit BeginContact (with the
--- other entity and an upward-facing normal) to observers on the ball
--- entity, and bouncing it off the floor must emit EndContact. Covers
--- the shared fixture->entity contact resolution behind all four Box2D
--- callbacks.
---
--- Run via `make test-love FILE_MATCH='physics_contacts'`.

require("busted")
local luassert <const> = require("luassert")
local fixture <const> = require("spec.integration.harness.fixture")

local APP_DIR <const> = "build/test_deps/spec/integration/apps/tiledphysics"

describe("physics contacts: begin/end events reach entity observers", function()
    local app: fixture.App

    setup(function()
        app = fixture.start(APP_DIR)
        -- A second ball with contact observers, dropped over the floor
        -- away from the fixture's own ball.
        fixture.runLua(app, [[
            local tecs = require("tecs")
            local physics = require("tecs2d.physics")
            local Transform = tecs.builtins.Transform
            _G.tecsContactBall = world:spawn(
                Transform(220, 40, 0, 1),
                physics.Collider.new({shape = "circle", radius = 8, restitution = 0}),
                physics.RigidBody.new({mass = 1}))
            _G.tecsBegin = nil
            _G.tecsEndCount = 0
            world:observe(_G.tecsContactBall, physics.BeginContact, function(e)
                _G.tecsBegin = {other = e.other, nx = e.normalX, ny = e.normalY}
            end)
            world:observe(_G.tecsContactBall, physics.EndContact, function()
                _G.tecsEndCount = _G.tecsEndCount + 1
            end)
            return true
        ]])
    end)

    teardown(function()
        fixture.stop(app)
    end)

    it("landing on the floor emits BeginContact with a contact normal", function()
        local landed = fixture.eventually(8, function(): boolean
            local values = fixture.runLua(app, [[
                if _G.tecsBegin then
                    return _G.tecsBegin.other, _G.tecsBegin.nx, _G.tecsBegin.ny
                end
                return nil
            ]])
            if values[1] ~= nil then return true end
            return nil
        end)
        luassert.is_true(landed == true, "BeginContact never fired for the dropped ball")

        local values = fixture.runLua(app,
            "return _G.tecsBegin.other, _G.tecsBegin.nx, _G.tecsBegin.ny")
        luassert.is_number(tonumber(values[1]), "BeginContact carried no other entity")
        -- The floor is below the ball; the contact normal's vertical
        -- component must dominate the horizontal one.
        local nx = tonumber(values[2])
        local ny = tonumber(values[3])
        luassert.is_true(math.abs(ny) > math.abs(nx), string.format(
            "contact normal should be vertical, got (%.2f, %.2f)", nx, ny))
    end)

    it("leaving the floor emits EndContact", function()
        fixture.runLua(app, [[
            local physics = require("tecs2d.physics")
            local collider = world:get(_G.tecsContactBall, physics.Collider)
            collider.body:setLinearVelocity(0, -250)
            return true
        ]])
        local left = fixture.eventually(fixture.callTimeout, function(): boolean
            local values = fixture.runLua(app, "return _G.tecsEndCount")
            if tonumber(values[1]) and tonumber(values[1]) > 0 then return true end
            return nil
        end)
        luassert.is_true(left == true, "EndContact never fired after bouncing the ball up")
    end)
end)
