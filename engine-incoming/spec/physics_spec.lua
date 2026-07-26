-- Physics binding behaviour. Verifies that Box2D 3's value handles survive
-- the FFI round trip and that the solver produces the motion it should, which
-- together catch a mis-generated cdef in a way a smoke test would not.

-- Our build first, so it wins over the ECS repo's own engine tree.
-- The build directory is the build system's to choose, so it is passed in.
-- Our tree comes first, so it wins over the ECS repo's own engine tree.
local root = os.getenv("TECS2D_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;"
    .. "../tecs/build/?.lua;../tecs/build/?/init.lua;" .. package.path

local World = require("tecs2d.physics.World")

describe("physics.World", function()
    local world

    before_each(function()
        world = World.create({ gravity = { x = 0, y = -10 } })
    end)

    after_each(function()
        if world then world:destroy() end
    end)

    it("creates a world with a resolvable library", function()
        local box2d = require("tecs2d.ffi.box2d")
        assert.is_string(box2d.path)
        assert.is_not_nil(world.handle)
    end)

    it("leaves a static body at rest", function()
        local ground = world:createBody({
            type = "static",
            position = { x = 3, y = 7 },
        })
        World.addBox(ground, 50, 1, {})

        for _ = 1, 60 do world:step(1 / 60) end

        local x, y = World.getPosition(ground)
        assert.is_true(math.abs(x - 3) < 1e-4)
        assert.is_true(math.abs(y - 7) < 1e-4)
    end)

    it("accelerates a dynamic body under gravity", function()
        local ball = world:createBody({
            type = "dynamic",
            position = { x = 0, y = 100 },
        })
        World.addCircle(ball, 0.5, { density = 1 })

        for _ = 1, 60 do world:step(1 / 60) end

        local _, vy = World.getVelocity(ball)
        -- One second at -10 m/s^2, within solver tolerance.
        assert.is_true(math.abs(vy + 10) < 0.05,
            ("expected vy near -10, got %.4f"):format(vy))
    end)

    it("rests a falling body on top of a static box", function()
        local ground = world:createBody({ type = "static", position = { x = 0, y = 0 } })
        World.addBox(ground, 50, 1, {})

        local ball = world:createBody({ type = "dynamic", position = { x = 0, y = 20 } })
        World.addCircle(ball, 0.5, { density = 1, restitution = 0 })

        for _ = 1, 600 do world:step(1 / 60) end

        local _, y = World.getPosition(ball)
        -- Ground half-height 1, ball radius 0.5, so the contact rests near 1.5.
        assert.is_true(math.abs(y - 1.5) < 0.1,
            ("expected rest near y=1.5, got %.4f"):format(y))
    end)

    it("keeps body handles valid as plain copied values", function()
        local body = world:createBody({
            type = "dynamic",
            position = { x = 5, y = 5 },
        })
        World.addCircle(body, 0.5, { density = 1 })

        -- Handles are value structs, so a copy must address the same body.
        local copy = body
        world:step(1 / 60)

        local ax, ay = World.getPosition(body)
        local bx, by = World.getPosition(copy)
        assert.are.equal(ax, bx)
        assert.are.equal(ay, by)
    end)

    it("applies fixed rotation", function()
        local body = world:createBody({
            type = "dynamic",
            position = { x = 0, y = 10 },
            fixedRotation = true,
        })
        World.addBox(body, 1, 0.2, { density = 1 })

        for _ = 1, 120 do world:step(1 / 60) end

        assert.is_true(math.abs(World.getAngle(body)) < 1e-3)
    end)
end)
