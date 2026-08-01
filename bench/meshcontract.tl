--- Headless extraction baseline for the future mesh domain.
---
--- This walks the 3D component contract into retained instance and sphere
--- staging and fills a retained `MeshFramePacket`. It measures no drawing.
--- The future `MeshExtractor` replaces this synthetic loop and is compared
--- against these numbers.
---
---   BENCH_MESH_COUNT     Entities per sample. Defaults to 100000.
---   BENCH_MESH_WARMUP    Untimed extractions. Defaults to 120.
---   BENCH_MESH_SAMPLES   Measured extractions. Defaults to 61.

local getenv <const> = os.getenv
local floor <const> = math.floor
local abs <const> = math.abs
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

local tecs <const> = require("tecs")
local loader <const> = require("tecs.ffi.loader")
local components <const> = require("tecs.components")
local MeshFramePacket <const> = require("tecs.internal.render.MeshFramePacket")

local Transform3D <const> = tecs.Transform3D
local Mesh <const> = components.Mesh
local Bounds3D <const> = components.Bounds3D
local Material <const> = components.Material
local Renderable3D <const> = components.Renderable3D

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

local COUNT <const> = positiveInteger("BENCH_MESH_COUNT", 100000)
local WARMUP <const> = positiveInteger("BENCH_MESH_WARMUP", 120)
local SAMPLES <const> = positiveInteger("BENCH_MESH_SAMPLES", 61)

-- Provisional staging widths, not renderer ABIs. They carry the component
-- values whose cost this baseline measures.
local INSTANCE_FLOATS <const> = 16
local BOUND_FLOATS <const> = 4

local world <const> = tecs.ecs.newWorld()
local asset <const> = components.meshId("bench://unit-mesh")
world:batchSpawn(
    COUNT,
    {Transform3D, Mesh, Bounds3D, Material, Renderable3D},
    function(archetype: tecs.ecs.Archetype, firstRow: integer, lastRow: integer)
        local transforms = archetype:getMut(Transform3D)
        local meshes = archetype:getMut(Mesh)
        local bounds = archetype:getMut(Bounds3D)
        local materials = archetype:getMut(Material)
        for row = firstRow, lastRow do
            local transform = transforms[row]
            transform.x = (row % 512) * 2.0
            transform.y = floor(row / 512) * 2.0
            transform.z = -(row % 97) * 1.5
            transform.rotationX = 0.0
            transform.rotationY = 0.0
            transform.rotationZ = 0.0
            transform.rotationW = 1.0
            transform.scaleX = 1.0
            transform.scaleY = 1.0
            transform.scaleZ = 1.0

            local mesh = meshes[row]
            mesh.asset = asset
            mesh.slot = 0

            local bound = bounds[row]
            bound.centerX = 0.1
            bound.centerY = 0.2
            bound.centerZ = 0.3
            bound.radius = 1.0

            local material = materials[row]
            material.id = 0
            material.param = 0.25
        end
    end
)
world:commit()

local query <const> = world:newQuery({include = {Transform3D, Mesh, Bounds3D, Material, Renderable3D}})
local instances <const> = loader.newArray("float[?]", COUNT * INSTANCE_FLOATS)
local spheres <const> = loader.newArray("float[?]", COUNT * BOUND_FLOATS)
local packet <const> = MeshFramePacket.create()

local function extract(): integer
    packet:begin(0)
    local written = 0
    for archetype, length in query:iter() do
        local transforms <const> = archetype:get(Transform3D)
        local meshes <const> = archetype:get(Mesh)
        local bounds <const> = archetype:get(Bounds3D)
        local materials <const> = archetype:get(Material)
        local first <const> = written

        for row = 1, length do
            local transform = transforms[row]
            local mesh = meshes[row]
            local material = materials[row]
            local base <const> = written * INSTANCE_FLOATS
            instances[base] = transform.x
            instances[base + 1] = transform.y
            instances[base + 2] = transform.z
            instances[base + 3] = transform.rotationX
            instances[base + 4] = transform.rotationY
            instances[base + 5] = transform.rotationZ
            instances[base + 6] = transform.rotationW
            instances[base + 7] = transform.scaleX
            instances[base + 8] = transform.scaleY
            instances[base + 9] = transform.scaleZ
            instances[base + 10] = mesh.asset
            instances[base + 11] = mesh.slot
            instances[base + 12] = material.id
            instances[base + 13] = material.param
            instances[base + 14] = 0.0
            instances[base + 15] = 0.0

            local bound = bounds[row]
            local boundBase <const> = written * BOUND_FLOATS
            local centerX <const> = bound.centerX * transform.scaleX
            local centerY <const> = bound.centerY * transform.scaleY
            local centerZ <const> = bound.centerZ * transform.scaleZ
            local twiceX <const> = 2.0 * (transform.rotationY * centerZ - transform.rotationZ * centerY)
            local twiceY <const> = 2.0 * (transform.rotationZ * centerX - transform.rotationX * centerZ)
            local twiceZ <const> = 2.0 * (transform.rotationX * centerY - transform.rotationY * centerX)
            spheres[boundBase] = transform.x + centerX + transform.rotationW * twiceX + transform.rotationY * twiceZ - transform.rotationZ * twiceY
            spheres[boundBase + 1] = transform.y + centerY + transform.rotationW * twiceY + transform.rotationZ * twiceX - transform.rotationX * twiceZ
            spheres[boundBase + 2] = transform.z + centerZ + transform.rotationW * twiceZ + transform.rotationX * twiceY - transform.rotationY * twiceX
            spheres[boundBase + 3] = bound.radius * max(
                abs(transform.scaleX), max(abs(transform.scaleY), abs(transform.scaleZ))
            )
            written = written + 1
        end

        packet.instanceRanges:mark(first * INSTANCE_FLOATS * 4, (written - first) * INSTANCE_FLOATS * 4)
        packet.boundsRanges:mark(first * BOUND_FLOATS * 4, (written - first) * BOUND_FLOATS * 4)
    end
    packet.count = written
    packet.dropped = COUNT - written
    packet.rewritten = written
    return written
end

for _ = 1, WARMUP do
    extract()
end

local samples: {number} = {}
for sample = 1, SAMPLES do
    samples[sample] = 0.0
end
collect("collect")
local heapBefore <const> = (collect("count") as number) * 1024.0
collect("stop")
for sample = 1, SAMPLES do
    local started <const> = os.clock()
    if extract() ~= COUNT then
        error("bench: extraction dropped a mesh", 0)
    end
    samples[sample] = os.clock() - started
end
local heapAfter <const> = (collect("count") as number) * 1024.0
collect("restart")
sort(samples)

local p50 <const> = samples[max(1, ceil(SAMPLES * 0.50))]
local p95 <const> = samples[max(1, ceil(SAMPLES * 0.95))]
local heapPerFrame <const> = max(0.0, heapAfter - heapBefore) / SAMPLES
print(
    format(
        "mesh contract: %d entities  p50 %.3f ms  p95 %.3f ms  %.1f ns/entity  heap %.0f B/frame",
        COUNT,
        p50 * 1000.0,
        p95 * 1000.0,
        p50 * 1000000000.0 / COUNT,
        heapPerFrame
    )
)
