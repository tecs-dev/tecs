--- Binary snapshot save and load throughput for three FFI archetypes.
---
--- The world has a full, a partial, and a position-only archetype. That keeps
--- the benchmark from measuring one contiguous memcpy path and makes save and
--- restore pay for the archetype framing a real game carries. Setup stays out
--- of the timed windows; save reuses one `string.buffer`, and load repeatedly
--- replaces the same world's entities from one prepared snapshot.
---
---   BENCH_SNAPSHOT_COUNT    Entities in the source world. Defaults to 10000.
---   BENCH_SNAPSHOT_WARMUP   Untimed operations. Defaults to 20.
---   BENCH_SNAPSHOT_SAMPLES  Timed operations. Defaults to 31.

local getenv <const> = os.getenv
local format <const> = string.format
local sort <const> = table.sort
local ceil <const> = math.ceil
local floor <const> = math.floor
local max <const> = math.max

local root = getenv("TECS_LUA") or (_G as {string: any})["__tecsContent"] as string or "out/macos-arm64-dev/lua"
if root:sub(-1) == "/" then
    root = root:sub(1, -2)
end
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local tecs <const> = require("tecs")
local type StringBuffer = require("string.buffer")
local StringBufferModule <const> = require("string.buffer")
local now <const> = require("tecs.platform.time").now

local function positiveInteger(name: string, default: integer): integer
    local text <const> = getenv(name)
    if text == nil then
        return default
    end
    local value <const> = tonumber(text)
    if value == nil or value ~= floor(value) or value < 1 then
        error(format("bench: %s must be a positive integer", name), 0)
    end
    return floor(value)
end

local COUNT <const> = positiveInteger("BENCH_SNAPSHOT_COUNT", 10000)
local WARMUP <const> = positiveInteger("BENCH_SNAPSHOT_WARMUP", 20)
local SAMPLES <const> = positiveInteger("BENCH_SNAPSHOT_SAMPLES", 31)

local record Position is tecs.ecs.Component
    x: number
    y: number
end

local record Velocity is tecs.ecs.Component
    x: number
    y: number
end

local record Health is tecs.ecs.Component
    current: integer
    maximum: integer
end

local PositionComponent <const> = tecs.ecs.newFFIComponent({
    name = "bench.SnapshotPosition",
    container = Position,
    fields = {
        {"x", "double"},
        {"y", "double"},
    },
})

local VelocityComponent <const> = tecs.ecs.newFFIComponent({
    name = "bench.SnapshotVelocity",
    container = Velocity,
    fields = {
        {"x", "double"},
        {"y", "double"},
    },
})

local HealthComponent <const> = tecs.ecs.newFFIComponent({
    name = "bench.SnapshotHealth",
    container = Health,
    fields = {
        {"current", "int32_t"},
        {"maximum", "int32_t"},
    },
})

local function populate(world: tecs.World, count: integer)
    local third <const> = floor(count / 3)
    local rest <const> = count - third * 2
    world:batchSpawn(
        third,
        {PositionComponent, VelocityComponent, HealthComponent},
        function(archetype: tecs.ecs.Archetype, first: integer, last: integer)
            local positions = archetype:getMut(PositionComponent)
            local velocities = archetype:getMut(VelocityComponent)
            local health = archetype:getMut(HealthComponent)
            for row = first, last do
                positions[row].x = row * 1.5
                positions[row].y = row * 2.5
                velocities[row].x = row * 0.1
                velocities[row].y = row * 0.2
                health[row].current = 100
                health[row].maximum = 100
            end
        end
    )
    world:batchSpawn(
        third,
        {PositionComponent, VelocityComponent},
        function(archetype: tecs.ecs.Archetype, first: integer, last: integer)
            local positions = archetype:getMut(PositionComponent)
            local velocities = archetype:getMut(VelocityComponent)
            for row = first, last do
                positions[row].x = row * 3.5
                positions[row].y = row * 4.5
                velocities[row].x = row * 0.3
                velocities[row].y = row * 0.4
            end
        end
    )
    world:batchSpawn(
        rest,
        {PositionComponent},
        function(archetype: tecs.ecs.Archetype, first: integer, last: integer)
            local positions = archetype:getMut(PositionComponent)
            for row = first, last do
                positions[row].x = row * 5.5
                positions[row].y = row * 6.5
            end
        end
    )
    world:commit()
end

local function percentile(samples: {number}, fraction: number): number
    return samples[max(1, ceil(#samples * fraction))]
end

local function requireBuffer(output: tecs.ecs.SnapshotOutput): StringBuffer
    if output.buffer == nil then
        error("bench: binary snapshot produced no buffer", 0)
    end
    return output.buffer
end

local function measure(name: string, bytes: integer, run: function())
    for _ = 1, WARMUP do
        run()
    end
    local samples: {number} = {}
    for sample = 1, SAMPLES do
        local started <const> = now()
        run()
        samples[sample] = now() - started
    end
    sort(samples)
    local p50 <const> = percentile(samples, 0.50)
    local p95 <const> = percentile(samples, 0.95)
    print(
        format(
            "snapshot %-4s %d entities  p50 %.3f ms  p95 %.3f ms  %.1f MiB/s",
            name,
            COUNT,
            p50 * 1000.0,
            p95 * 1000.0,
            bytes / p50 / (1024.0 * 1024.0)
        )
    )
end

local saveWorld <const> = tecs.ecs.newWorld({maxEntities = COUNT + 64})
populate(saveWorld, COUNT)
local reusable <const> = StringBufferModule.new()
local prepared <const> = saveWorld:saveSnapshot({buffer = reusable})
local preparedBuffer <const> = requireBuffer(prepared)
local bytes <const> = #preparedBuffer:tostring()

measure("save", bytes, function()
    saveWorld:saveSnapshot({buffer = reusable})
end)

local loadWorld <const> = tecs.ecs.newWorld({maxEntities = COUNT + 64})
measure("load", bytes, function()
    loadWorld:loadSnapshot(reusable)
    if loadWorld:getStats().entities ~= COUNT then
        error("bench: snapshot load restored the wrong entity count", 0)
    end
end)
