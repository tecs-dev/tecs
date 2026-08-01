--- Headless extraction benchmark for the mesh domain.
---
--- This drives the real `MeshExtractor` into retained instance, sphere, and
--- indexed-command staging and fills a retained `MeshFramePacket`. It measures
--- no drawing and loads no sprite renderer.
---
---   BENCH_MESH_COUNT     Entities per sample. Defaults to 100000.
---   BENCH_MESH_WARMUP    Untimed extractions. Defaults to 120.
---   BENCH_MESH_SAMPLES   Measured extractions. Defaults to 61.

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

local tecs <const> = require("tecs")
local loader <const> = require("tecs.ffi.loader")
local components <const> = require("tecs.components")
local MeshExtractor <const> = require("tecs.internal.render.MeshExtractor")
local MeshFramePacket <const> = require("tecs.internal.render.MeshFramePacket")
local meshlayout <const> = require("tecs.gpu.meshlayout")

local Transform3D <const> = tecs.Transform3D
local Mesh <const> = components.Mesh
local Bounds3D <const> = components.Bounds3D
local MeshMaterial <const> = components.MeshMaterial
local Tint <const> = components.Tint
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

local world <const> = tecs.ecs.newWorld()
local asset <const> = components.meshId("bench://unit-mesh")
world:batchSpawn(
    COUNT,
    {Transform3D, Mesh, Bounds3D, MeshMaterial, Tint, Renderable3D},
    function(archetype: tecs.ecs.Archetype, firstRow: integer, lastRow: integer)
        local transforms = archetype:getMut(Transform3D)
        local meshes = archetype:getMut(Mesh)
        local bounds = archetype:getMut(Bounds3D)
        local materials = archetype:getMut(MeshMaterial)
        local tints = archetype:getMut(Tint)
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
            material.asset = 0
            material.slot = 0

            local tint = tints[row]
            tint.r = 1.0
            tint.g = 1.0
            tint.b = 1.0
            tint.a = 1.0
        end
    end
)
world:commit()

local instances <const> = loader.newArray("float[?]", COUNT * meshlayout.INSTANCE_FLOATS)
local spheres <const> = loader.newArray("float[?]", COUNT * meshlayout.BOUND_FLOATS)
local commands <const> = loader.newArray("SDL_GPUIndexedIndirectDrawCommand[?]", COUNT)
local packet <const> = MeshFramePacket.create()
local extractor <const> = MeshExtractor.create({capacity = COUNT})
extractor:setStaging(0, instances, spheres, commands)
extractor:registerMesh(asset, 0, 0, 0, 3)
extractor:install(world, packet, nil)

local function extract(): integer
    extractor:extract(packet)
    return packet.count
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
        "mesh extract: %d entities  p50 %.3f ms  p95 %.3f ms  %.1f ns/entity  heap %.0f B/frame",
        COUNT,
        p50 * 1000.0,
        p95 * 1000.0,
        p50 * 1000000000.0 / COUNT,
        heapPerFrame
    )
)
