-- What a particle effect is, and that it means the same after a save.
--
-- An effect's index is a position: it is `#registry + 1` at the moment it was
-- registered, so it says where in one process's registration order an effect
-- landed and nothing else. A different plugin install order, or a registration
-- behind a condition that was true last run and false this one, moves every
-- index after it. An index written into a snapshot therefore names whichever
-- effect the loading process happened to put in that place, and the emitter
-- comes back playing something nobody asked for with nothing said about it.
--
-- The first two tests are that demonstration. Each registers the same two
-- effects in the opposite order between the save and the load, asserts the
-- indices provably swapped, and then asserts the emitter still plays what it
-- was saved on. A file carrying the index instead answers the effect that took
-- its place, by name, with the load reporting nothing wrong.
--
-- The third is the case that cannot be guessed at. A snapshot naming an effect
-- this build does not have is refused, because both of the quiet answers --
-- resolve it to something else, or drop the component -- are the same failure
-- the name is written to prevent.

local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local tecs = require("tecs")
local components = require("tecs.components")
local particles = require("tecs.gfx.particles")

local Transform = components.Transform
local ParticleEmitter = particles.ParticleEmitter

-- Two effects that can be told apart without a GPU. Capacity is the emitter's
-- slot range, so it is a fact about the effect the restored component carries
-- directly and no frame has to be drawn to read it.
local function register(name, capacity)
    return particles.effect({
        name = name,
        capacity = capacity,
        schedule = { bursts = { { time = 0, count = 1 } } },
        initial = { lifetime = 1.0, speed = 0, size = 4 },
        render = { layer = 1 },
    })
end

--- True when `wanted` appears anywhere inside a nest of tables.
local function holds(value, wanted)
    if value == wanted then
        return true
    end
    if type(value) ~= "table" then
        return false
    end
    for _, item in pairs(value) do
        if holds(item, wanted) then
            return true
        end
    end
    return false
end

describe("particle effect identity across a snapshot", function()
    before_each(function()
        particles.reset()
    end)

    after_each(function()
        particles.reset()
    end)

    it("survives the same effects registered in the other order", function()
        register("specSparks", 8)
        local smoke = register("specSmoke", 64)
        assert.are.equal(2, smoke.index)

        local world = tecs.ecs.newWorld()
        local entity = world:spawn(Transform(0, 0), ParticleEmitter({ effect = smoke, seed = 3 }))

        local snapshot = world:saveSnapshot({ format = "table" }).snapshot
        assert.is_true(
            holds(snapshot.archetypes, "specSmoke"),
            "a snapshot has to carry the name; a number in a file names a position"
        )

        -- The whole difference is which registration ran first, which is what
        -- a conditional effect or a plugin installed earlier changes.
        particles.reset()
        local smokeAgain = register("specSmoke", 64)
        local sparksAgain = register("specSparks", 8)

        assert.are.equal(1, smokeAgain.index)
        assert.are.equal(2, sparksAgain.index)
        assert.are_not.equal(smoke.index, smokeAgain.index, "the indices have to move or this proves nothing")

        local restored = tecs.ecs.newWorld()
        restored:loadSnapshot(snapshot)

        local emitter = restored:get(entity, ParticleEmitter)
        assert.are.equal("specSmoke", emitter.effect.name, "the emitter plays whatever the saved number now selects")
        assert.are.equal(smokeAgain, emitter.effect)
        assert.are.equal(64, emitter.effect.capacity)
        assert.are.equal(3, emitter.seed)
    end)

    -- The tint is a game-set value that nothing else records, so an emitter
    -- that came back the right effect but the wrong colour would look like a
    -- rendering fault rather than a save one.
    it("carries the tint a game set on it", function()
        local effect = register("specTinted", 8)
        local world = tecs.ecs.newWorld()
        local entity =
            world:spawn(Transform(0, 0), ParticleEmitter({ effect = effect, tint = { 0.25, 0.5, 0.75, 0.5 } }))

        local restored = tecs.ecs.newWorld()
        restored:loadSnapshot(world:saveSnapshot({ format = "table" }).snapshot)

        local tint = restored:get(entity, ParticleEmitter).tint
        assert.is_table(tint, "the tint did not cross at all")
        assert.are.equal(0.25, tint[1])
        assert.are.equal(0.5, tint[2])
        assert.are.equal(0.75, tint[3])
        assert.are.equal(0.5, tint[4])
    end)

    it("survives the same reordering through the binary format", function()
        register("specSparks", 8)
        local smoke = register("specSmoke", 64)

        local world = tecs.ecs.newWorld()
        local entity = world:spawn(Transform(0, 0), ParticleEmitter({ effect = smoke, state = "paused" }))
        local buffer = world:saveSnapshot().buffer

        particles.reset()
        register("specSmoke", 64)
        register("specSparks", 8)

        local restored = tecs.ecs.newWorld()
        restored:loadSnapshot(buffer)

        local emitter = restored:get(entity, ParticleEmitter)
        assert.are.equal("specSmoke", emitter.effect.name)
        assert.are.equal(64, emitter.effect.capacity)
        assert.are.equal("paused", emitter.state)
    end)

    it("refuses a snapshot naming an effect this build does not have", function()
        local smoke = register("specSmoke", 64)

        local world = tecs.ecs.newWorld()
        world:spawn(Transform(0, 0), ParticleEmitter({ effect = smoke }))
        local snapshot = world:saveSnapshot({ format = "table" }).snapshot

        -- The registration this build lost, with another still in place, so
        -- the refusal has something to list and resolving leniently would have
        -- had somewhere to go.
        particles.reset()
        register("specSparks", 8)

        local restored = tecs.ecs.newWorld()
        local ok, err = pcall(function()
            restored:loadSnapshot(snapshot)
        end)

        assert.is_false(ok, "an effect the build has lost cannot be guessed at")
        assert.is_truthy(
            tostring(err):find("specSmoke", 1, true),
            "the refusal has to name the missing effect: " .. tostring(err)
        )
        assert.is_truthy(
            tostring(err):find("loadSnapshot:", 1, true),
            "and read like the load's other refusals: " .. tostring(err)
        )
        assert.is_truthy(
            tostring(err):find("specSparks", 1, true),
            "and say what this build does have: " .. tostring(err)
        )
    end)

    it("refuses a snapshot whose emitter names no effect at all", function()
        register("specSparks", 8)

        local restored = tecs.ecs.newWorld()
        local ok, err = pcall(function()
            ParticleEmitter.deserialize(restored, { state = "playing", seed = 1 })
        end)

        assert.is_false(ok)
        assert.is_truthy(tostring(err):find("loadSnapshot:", 1, true), tostring(err))
    end)
end)
