--- Headless allocation and CPU-time benchmark for model animation sampling.
---
---   BENCH_MODEL_COUNT    Independently posed instances. Defaults to 1000.
---   BENCH_MODEL_WARMUP   Untimed samples. Defaults to 60.
---   BENCH_MODEL_SAMPLES  Measured samples. Defaults to 61.

local getenv <const> = os.getenv
local floor <const> = math.floor
local max <const> = math.max
local ceil <const> = math.ceil
local sort <const> = table.sort
local format <const> = string.format
local collect <const> = collectgarbage

local root = getenv("TECS_LUA") or (_G as {string: any})["__tecsContent"] as string or "out/macos-arm64-dev/lua"
if root:sub(-1) == "/" then
    root = root:sub(1, -2)
end
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local assets <const> = require("tecs.assets")
local components <const> = require("tecs.components")
local Model3D <const> = require("tecs.gfx.Model3D")
local type modeltypes = require("tecs.internal.render.modeltypes")

local record BenchDomain is modeltypes.Domain
end

local function positiveInteger(name: string, default: integer): integer
    local text <const> = getenv(name)
    if text == nil then
        return default
    end
    local value <const> = tonumber(text)
    if value == nil or value < 1 or value ~= floor(value) then
        error(format("bench: %s must be a positive integer", name), 0)
    end
    return floor(value)
end

local COUNT <const> = positiveInteger("BENCH_MODEL_COUNT", 1000)
local WARMUP <const> = positiveInteger("BENCH_MODEL_WARMUP", 60)
local SAMPLES <const> = positiveInteger("BENCH_MODEL_SAMPLES", 61)
local JOINTS <const> = 16

local identity: {number} = {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1}
local nodes: {assets.ModelNode} = {}
nodes[1] = {
    parent = 0,
    x = 0,
    y = 0,
    z = 0,
    rotationX = 0,
    rotationY = 0,
    rotationZ = 0,
    rotationW = 1,
    scaleX = 1,
    scaleY = 1,
    scaleZ = 1,
}
local joints: {integer} = {}
local inverseBinds: {number} = {}
local initial: {number} = {}
for joint = 1, JOINTS do
    nodes[joint + 1] = {
        parent = joint,
        x = 0,
        y = 0.05,
        z = 0,
        rotationX = 0,
        rotationY = 0,
        rotationZ = 0,
        rotationW = 1,
        scaleX = 1,
        scaleY = 1,
        scaleZ = 1,
    }
    joints[joint] = joint + 1
    for lane = 1, 16 do
        inverseBinds[#inverseBinds + 1] = identity[lane]
        initial[#initial + 1] = identity[lane]
    end
end

local source <const>: assets.Model = {
    path = "bench://model-animation",
    nodes = nodes,
    animations = {
        {
            name = "Bend",
            duration = 1,
            channels = {
                {
                    node = JOINTS + 1,
                    path = assets.ANIMATION_ROTATION,
                    width = 4,
                    interpolation = assets.ANIMATION_LINEAR,
                    times = {0, 1},
                    values = {0, 0, 0, 1, 0, 0, 1, 0},
                },
            },
        },
    },
    skins = {
        {
            name = "bench://skeleton",
            matrices = initial,
            node = 1,
            joints = joints,
            inverseBindMatrices = inverseBinds,
        },
    },
    draws = {{mesh = 1, material = 0, skin = 1, node = 1, weights = {}}},
} as assets.Model

local checksum = 0.0
local nextSlot = 0
local domain = {} as BenchDomain
domain.registerSkin = function(_self: BenchDomain, name: string, matrices: {number}): components.MeshSkin
    local skin <const> = components.MeshSkin(components.meshSkinId(name), nextSlot)
    nextSlot = nextSlot + floor(#matrices / 16)
    return skin
end
domain.updateSkin = function(_self: BenchDomain, _skin: components.MeshSkin, matrices: {number})
    checksum = checksum + matrices[13] + matrices[#matrices]
end

local model <const> = Model3D._create(
    domain,
    "bench://model-animation#residency-1",
    source,
    {components.Mesh(1, 0)},
    {components.Bounds3D(0, 0, 0, 4)},
    {}
)
local instances: {Model3D.Instance} = {}
for index = 1, COUNT do
    instances[index] = model:newInstance()
end

local phase = 0.0
local function sample()
    phase = (phase + 1 / 120) % 1
    for index = 1, COUNT do
        instances[index]:sample(1, phase)
    end
end
for _ = 1, WARMUP do
    sample()
end

local samples: {number} = {}
collect("collect")
local heapBefore <const> = (collect("count") as number) * 1024.0
collect("stop")
for index = 1, SAMPLES do
    local started <const> = os.clock()
    sample()
    samples[index] = os.clock() - started
end
local heapAfter <const> = (collect("count") as number) * 1024.0
collect("restart")
sort(samples)

local p50 <const> = samples[max(1, ceil(SAMPLES * 0.50))]
local p95 <const> = samples[max(1, ceil(SAMPLES * 0.95))]
local heapPerSample <const> = max(0.0, heapAfter - heapBefore) / SAMPLES
print(
    format(
        "model animation: %d instances x %d joints  p50 %.3f ms  p95 %.3f ms  %.1f ns/instance  heap %.0f B/sample  check %.1f",
        COUNT,
        JOINTS,
        p50 * 1000,
        p95 * 1000,
        p50 * 1000000000 / COUNT,
        heapPerSample,
        checksum
    )
)
