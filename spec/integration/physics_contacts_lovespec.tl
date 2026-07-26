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
local fixture <const> = require("tecs2d.testing.fixture")

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

    it("synchronizes the authoritative body pose before FixedLast", function()
        fixture.runLua(app, [[
            local tecs = require("tecs")
            local physics = require("tecs2d.physics")
            local Transform = tecs.builtins.Transform
            _G.tecsFixedSync = {
                samples = 0,
                mismatches = 0,
                kicked = false,
                lastDx = 0,
                lastDy = 0,
                lastDr = 0,
            }
            _G.tecsFixedSyncEntity = world:spawn(
                Transform(80, 20, 0, 1),
                physics.Collider.new({
                    shape = "circle",
                    radius = 8,
                }),
                physics.RigidBody.new({mass = 1})
            )
            world:addSystem({
                name = "spec.physicsKickFixedSyncBody",
                phase = tecs.phases.FixedPreUpdate,
                after = {"physics.createBodies"},
                run = function()
                    local c = world:get(
                        _G.tecsFixedSyncEntity,
                        physics.Collider
                    )
                    if c and c.body and not _G.tecsFixedSync.kicked then
                        c.body:setLinearVelocity(180, -20)
                        c.body:setAngularVelocity(2)
                        _G.tecsFixedSync.kicked = true
                    end
                end,
            })
            world:addSystem({
                name = "spec.physicsObserveFixedSync",
                phase = tecs.phases.FixedLast,
                run = function()
                    local c = world:get(
                        _G.tecsFixedSyncEntity,
                        physics.Collider
                    )
                    if not c or not c.body or not _G.tecsFixedSync.kicked then
                        return
                    end
                    local t = world:get(
                        _G.tecsFixedSyncEntity,
                        Transform
                    )
                    local bx, by = c.body:getPosition()
                    local br = c.body:getAngle()
                    local dx = math.abs(t.x - bx)
                    local dy = math.abs(t.y - by)
                    local dr = math.abs(t.rotation - br)
                    _G.tecsFixedSync.samples =
                        _G.tecsFixedSync.samples + 1
                    _G.tecsFixedSync.lastDx = dx
                    _G.tecsFixedSync.lastDy = dy
                    _G.tecsFixedSync.lastDr = dr
                    if dx > 1e-9 or dy > 1e-9 or dr > 1e-9 then
                        _G.tecsFixedSync.mismatches =
                            _G.tecsFixedSync.mismatches + 1
                    end
                end,
            })
            return true
        ]])

        local sampled = fixture.eventually(
            fixture.callTimeout,
            function(): boolean
                local values = fixture.runLua(app, [[
                    return _G.tecsFixedSync.samples,
                        _G.tecsFixedSync.mismatches,
                        _G.tecsFixedSync.lastDx,
                        _G.tecsFixedSync.lastDy,
                        _G.tecsFixedSync.lastDr
                ]])
                if tonumber(values[1]) and tonumber(values[1]) >= 4 then
                    luassert.equals(0, tonumber(values[2]), string.format(
                        "Transform lagged body pose by (%s, %s, %s)",
                        values[3], values[4], values[5]))
                    return true
                end
                return nil
            end
        )
        luassert.is_true(
            sampled == true,
            "did not observe four fixed-step Transform synchronizations"
        )
    end)
end)
