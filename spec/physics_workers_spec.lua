-- The thread pool Rapier solves across.
--
-- Two things are worth pinning. The first is that adding workers does not
-- change the answer: Rapier's graph coloring makes the solve independent of
-- how the work was split, and a pool that handed out overlapping ranges or
-- reused a worker slot on two threads at once would break that quietly rather
-- than crash. The second is that shutdown joins, which is asked of the pool
-- itself rather than inferred from the process exiting cleanly.

-- The build directory is the build system's to choose, so it is passed in.
-- Our tree comes first, so it wins over the ECS repo's own engine tree.
local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local World = require("tecs.physics.World")
local TaskPool = require("tecs.physics.TaskPool")

-- A pile rather than a column of loose bodies: stacked contacts are what the
-- solver spreads over graph colors, so this is the scene where the workers
-- have anything to disagree about.
local function build(workerCount)
    local world = World.create({
        gravity = { x = 0, y = -10 },
        workerCount = workerCount,
    })

    local ground = world:createBody({ type = "static", position = { x = 0, y = 0 } })
    World.addBox(ground, 60, 1, {})

    local bodies = {}
    for row = 0, 15 do
        for column = 0, 15 do
            local body = world:createBody({
                type = "dynamic",
                position = {
                    x = -12 + column * 1.6 + row * 0.05,
                    y = 2 + row * 1.3,
                },
            })
            if (row + column) % 2 == 0 then
                World.addBox(body, 0.5, 0.5, { density = 1, friction = 0.4 })
            else
                World.addCircle(body, 0.5, { density = 1, friction = 0.4 })
            end
            bodies[#bodies + 1] = body
        end
    end

    return world, bodies
end

local function simulate(workerCount, steps)
    local world, bodies = build(workerCount)
    for _ = 1, steps do
        world:step(1 / 60)
    end

    local poses = {}
    for i, body in ipairs(bodies) do
        local x, y = World.getPosition(body)
        poses[i] = { x = x, y = y, angle = World.getAngle(body) }
    end
    world:destroy()
    return poses
end

describe("physics.TaskPool", function()
    it("reports a worker count derived from the machine", function()
        local count = TaskPool.defaultWorkerCount()
        assert.is_true(count >= 1, ("expected at least one worker, got %d"):format(count))
    end)

    it("starts no thread for a single worker", function()
        local before = TaskPool.liveThreadCount()

        local pool = TaskPool.create(1)
        assert.are.equal(1, pool.workerCount)
        -- One worker is the thread that steps the world, so the pool has
        -- nothing to start and every task runs inline.
        assert.are.equal(before, TaskPool.liveThreadCount())

        pool:destroy()
        assert.are.equal(before, TaskPool.liveThreadCount())
    end)

    it("clamps a worker count below one", function()
        local pool = TaskPool.create(0)
        assert.are.equal(1, pool.workerCount)
        pool:destroy()
    end)

    it("joins every thread it started", function()
        -- A delta rather than an absolute count: other suites leave pools of
        -- their own running, and what this asserts is that these ones went.
        local before = TaskPool.liveThreadCount()

        local pools = {}
        for i = 1, 4 do
            pools[i] = TaskPool.create(3)
            assert.are.equal(3, pools[i].workerCount)
        end
        -- Three slots per pool, one of which is the stepping thread.
        assert.are.equal(before + 8, TaskPool.liveThreadCount())

        for _, pool in ipairs(pools) do
            pool:destroy()
        end
        assert.are.equal(before, TaskPool.liveThreadCount())
    end)

    it("destroys once however often it is asked", function()
        local before = TaskPool.liveThreadCount()
        local pool = TaskPool.create(2)
        pool:destroy()
        pool:destroy()
        assert.are.equal(before, TaskPool.liveThreadCount())
    end)

    it("leaves no thread behind when a world is destroyed", function()
        local before = TaskPool.liveThreadCount()
        local world = World.create({ gravity = { x = 0, y = -10 }, workerCount = 4 })
        assert.are.equal(before + 3, TaskPool.liveThreadCount())

        world:step(1 / 60)
        world:destroy()
        assert.are.equal(before, TaskPool.liveThreadCount())
    end)

    it("simulates identically however many workers solve it", function()
        local steps = 120
        local single = simulate(1, steps)

        -- Bit-exact, not within a tolerance. Rapier solves its constraint
        -- graph color by color and each color holds no two constraints
        -- that share a body, so the arithmetic every body sees is the same
        -- sequence of operations whichever worker performs it. A tolerance
        -- here would accept exactly the drift this test exists to catch.
        for _, workerCount in ipairs({ 2, 3, 4, 8 }) do
            local many = simulate(workerCount, steps)
            assert.are.equal(#single, #many)
            for i = 1, #single do
                assert.are.equal(
                    single[i].x,
                    many[i].x,
                    ("body %d x diverged with %d workers: %.17g vs %.17g"):format(
                        i,
                        workerCount,
                        single[i].x,
                        many[i].x
                    )
                )
                assert.are.equal(
                    single[i].y,
                    many[i].y,
                    ("body %d y diverged with %d workers: %.17g vs %.17g"):format(
                        i,
                        workerCount,
                        single[i].y,
                        many[i].y
                    )
                )
                assert.are.equal(
                    single[i].angle,
                    many[i].angle,
                    ("body %d angle diverged with %d workers: %.17g vs %.17g"):format(
                        i,
                        workerCount,
                        single[i].angle,
                        many[i].angle
                    )
                )
            end
        end
    end)

    it("settles the same pile whatever the worker count", function()
        -- The scene above is still moving after 120 steps, so it proves the
        -- workers agree step by step. This one runs to rest, which is where a
        -- lost contact or a skipped range would show as a body left standing
        -- somewhere else.
        local single = simulate(1, 600)
        local many = simulate(8, 600)

        local highest = -math.huge
        for i = 1, #single do
            assert.are.equal(single[i].y, many[i].y)
            highest = math.max(highest, single[i].y)
        end
        assert.is_true(highest < 20, ("the pile never settled, top body at %.3f"):format(highest))
    end)
end)
