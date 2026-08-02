--- GPU mesh-shadow lane benchmark.
---
--- This keeps one immutable triangle resident and submits a broad static field
--- of instances. Camera and light-volume culling run every frame while the
--- extraction upload settles after warmup. Run the same scene with
--- `BENCH_MESH_SHADOWS=0` and `BENCH_MESH_SHADOWS=1` to isolate the optional
--- shadow cascades, light-volume compaction, and shadow raster passes.

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
local MeshMaterial <const> = tecs.gfx.MeshMaterial
local Tint <const> = tecs.gfx.Tint
local Renderable3D <const> = tecs.gfx.Renderable3D
local timing <const> = require("tecs.timing")

local COUNT <const> = floor(tonumber(getenv("BENCH_MESH_COUNT")) or 100000)
local WARMUP <const> = floor(tonumber(getenv("BENCH_WARMUP")) or 120)
local FRAMES <const> = floor(tonumber(getenv("BENCH_FRAMES")) or 300)
local SHADOWS <const> = getenv("BENCH_MESH_SHADOWS") ~= "0"
local WIDTH <const> = 1280
local HEIGHT <const> = 720

if COUNT < 1 or WARMUP < 1 or FRAMES < 1 then
    error("bench: mesh count, warmup, and frames must be positive", 0)
end

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
local INDICES <const>: {integer} = {0, 1, 2}

local function spawnField(world: tecs.World, app: tecs.Application)
    local domain <const> = app.renderer.meshes
    domain.camera.z = 80
    domain.camera.far = 600
    domain.camera.verticalFov = math.rad(60)

    local mesh, bounds <const> = domain:registerMesh(tecs.assets.newMesh({
        name = "bench://shadow-triangle",
        vertices = VERTICES,
        indices = INDICES,
    }))

    world:batchSpawn(
        COUNT,
        {Transform3D, Mesh, Bounds3D, MeshMaterial, Tint, Renderable3D},
        function(archetype: tecs.ecs.Archetype, firstRow: integer, lastRow: integer)
            local transforms <const> = archetype:getMut(Transform3D)
            local meshes <const> = archetype:getMut(Mesh)
            local spheres <const> = archetype:getMut(Bounds3D)
            local materials <const> = archetype:getMut(MeshMaterial)
            local tints <const> = archetype:getMut(Tint)
            for row = firstRow, lastRow do
                local transform <const> = transforms[row]
                transform.x = (row % 512) * 1.5 - 384
                transform.y = (floor(row / 512) % 256) * 1.5 - 192
                transform.z = -(row % 127) * 1.5
                transform.rotationX = 0
                transform.rotationY = 0
                transform.rotationZ = 0
                transform.rotationW = 1
                transform.scaleX = 1
                transform.scaleY = 1
                transform.scaleZ = 1

                local instanceMesh <const> = meshes[row]
                instanceMesh.asset = mesh.asset
                instanceMesh.slot = mesh.slot

                local sphere <const> = spheres[row]
                sphere.centerX = bounds.centerX
                sphere.centerY = bounds.centerY
                sphere.centerZ = bounds.centerZ
                sphere.radius = bounds.radius

                local material <const> = materials[row]
                material.asset = 0
                material.slot = 0

                local tint <const> = tints[row]
                tint.r = 0.65
                tint.g = 0.75
                tint.b = 0.9
                tint.a = 1
            end
        end
    )
end

timing.enable()
local DELTA <const> = timing.stage("delta")

return tecs.newApplication({
    window = {title = "mesh shadows", width = WIDTH, height = HEIGHT},
    presentMode = "immediate",
    ambientLight = {0.2, 0.2, 0.2},
    sprites = false,
    meshes = {
        capacity = COUNT,
        vertexCapacity = 16,
        indexCapacity = 24,
        shadows = SHADOWS
            and {
                distance = 120,
                directionX = -0.5,
                directionY = -1,
                directionZ = -0.35,
                softness = 1,
            } or nil,
    },
    capacity = COUNT + 64,
    maxEntities = COUNT + 1024,
    debugMaxFrames = WARMUP + FRAMES,

    plugin = function(world: tecs.World, app: tecs.Application)
        spawnField(world, app)
        local frame = 0
        world:addSystem({
            name = "bench.MeshShadowSample",
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
            name = "bench.MeshShadowReport",
            phase = tecs.ecs.phases.Shutdown,
            run = function()
                print(
                    ("mesh shadows %s: %d submitted instances after %d warmup frames"):format(
                        SHADOWS and "on" or "off", app.renderer.meshes.count, WARMUP
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
