--- GPU mesh-morphing lane benchmark.
---
--- Run the same instance field with `BENCH_MESH_MORPHING=0` and `=1`. The
--- enabled run adds immutable target deltas, per-instance morph metadata,
--- retained weights, and the morph vertex variant. Geometry, culling, and
--- fragment work otherwise stay the same.

local getenv <const> = os.getenv
local floor <const> = math.floor

local root = getenv("TECS_LUA") or (_G as {string: any})["__tecsContent"] as string or "out/macos-arm64-dev/lua"
if root:sub(-1) == "/" then
    root = root:sub(1, -2)
end
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local tecs <const> = require("tecs")
local Transform3D <const> = tecs.Transform3D
local Bounds3D <const> = tecs.gfx.Bounds3D
local Mesh <const> = tecs.gfx.Mesh
local MeshMorph <const> = tecs.gfx.MeshMorph
local MeshMaterial <const> = tecs.gfx.MeshMaterial
local Tint <const> = tecs.gfx.Tint
local Renderable3D <const> = tecs.gfx.Renderable3D
local timing <const> = require("tecs.timing")

local COUNT <const> = floor(tonumber(getenv("BENCH_MESH_COUNT")) or 100000)
local WARMUP <const> = floor(tonumber(getenv("BENCH_WARMUP")) or 120)
local FRAMES <const> = floor(tonumber(getenv("BENCH_FRAMES")) or 300)
local MORPHING <const> = getenv("BENCH_MESH_MORPHING") ~= "0"

local VERTICES <const>: {number} = {
    -0.6,
    -0.5,
    0,
    0,
    0,
    1,
    1,
    0,
    0,
    1,
    0,
    0,
    0.6,
    -0.5,
    0,
    0,
    0,
    1,
    1,
    0,
    0,
    1,
    1,
    0,
    0,
    0.6,
    0,
    0,
    0,
    1,
    1,
    0,
    0,
    1,
    0.5,
    1,
}
local POSITIONS <const>: {number} = {0, 0, 0, 0, 0, 0, 0, 0.3, 0}

local function spawnField(world: tecs.World, app: tecs.Application)
    local domain <const> = app.renderer.meshes
    domain.camera.z = 80
    domain.camera.far = 600
    local mesh, bounds <const> = domain:registerMesh(tecs.assets.newMesh({
        name = "bench://morphing-triangle",
        vertices = VERTICES,
        indices = {0, 1, 2},
        morphTargets = MORPHING and {{positions = POSITIONS}} or nil,
        morphWeights = MORPHING and {0.5} or nil,
    }))
    local morph = MORPHING and domain:registerMorph("bench://one-target", {0.5}) or MeshMorph()

    world:batchSpawn(
        COUNT,
        {Transform3D, Mesh, Bounds3D, MeshMaterial, MeshMorph, Tint, Renderable3D},
        function(archetype: tecs.ecs.Archetype, firstRow: integer, lastRow: integer)
            local transforms <const> = archetype:getMut(Transform3D)
            local meshes <const> = archetype:getMut(Mesh)
            local spheres <const> = archetype:getMut(Bounds3D)
            local materials <const> = archetype:getMut(MeshMaterial)
            local morphs <const> = archetype:getMut(MeshMorph)
            local tints <const> = archetype:getMut(Tint)
            for row = firstRow, lastRow do
                local transform <const> = transforms[row]
                transform.x = (row % 512) * 1.5 - 384
                transform.y = (floor(row / 512) % 256) * 1.5 - 192
                transform.z = -(row % 127) * 1.5
                transform.rotationX, transform.rotationY, transform.rotationZ, transform.rotationW = 0, 0, 0, 1
                transform.scaleX, transform.scaleY, transform.scaleZ = 1, 1, 1

                meshes[row].asset, meshes[row].slot = mesh.asset, mesh.slot
                spheres[row].centerX, spheres[row].centerY = bounds.centerX, bounds.centerY
                spheres[row].centerZ, spheres[row].radius = bounds.centerZ, bounds.radius
                materials[row].asset, materials[row].slot = 0, 0
                morphs[row].asset, morphs[row].slot = morph.asset, morph.slot
                tints[row].r, tints[row].g, tints[row].b, tints[row].a = 0.65, 0.75, 0.9, 1
            end
        end
    )
end

timing.enable()
local DELTA <const> = timing.stage("delta")

return tecs.newApplication({
    window = {title = "mesh morphing", width = 1280, height = 720},
    presentMode = "immediate",
    ambientLight = {1, 1, 1},
    sprites = false,
    meshes = {
        capacity = COUNT,
        vertexCapacity = 16,
        indexCapacity = 24,
        morphing = MORPHING and {vertexCapacity = 16, weightCapacity = 16} or nil,
    },
    capacity = COUNT + 64,
    maxEntities = COUNT + 1024,
    debugMaxFrames = WARMUP + FRAMES,
    plugin = function(world: tecs.World, app: tecs.Application)
        spawnField(world, app)
        local frame = 0
        world:addSystem({
            name = "bench.MeshMorphingSample",
            phase = tecs.ecs.phases.First,
            run = function(dt: number)
                if frame == WARMUP then
                    timing.reset()
                end
                if frame >= WARMUP then
                    timing.mark(DELTA, dt)
                end
                frame = frame + 1
            end,
        })
        world:addSystem({
            name = "bench.MeshMorphingReport",
            phase = tecs.ecs.phases.Shutdown,
            run = function()
                print(
                    ("mesh morphing %s: %d submitted instances after %d warmup frames"):format(
                        MORPHING and "on" or "off", app.renderer.meshes.count, WARMUP
                    )
                )
                local report <const> = timing.format()
                if report ~= "" then
                    print(report)
                end
            end,
        })
    end,
})
