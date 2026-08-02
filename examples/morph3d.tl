--- Loads, instantiates, binds, and plays one glTF morph-weight animation.

local root = os.getenv("TECS_LUA") or (_G as {string: any})["__tecsContent"] as string or "out/macos-arm64-dev/lua"
if root:sub(-1) == "/" then
    root = root:sub(1, -2)
end
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local tecs <const> = require("tecs")
local assets <const> = tecs.assets
local files <const> = tecs.io.files
local Transform3D <const> = tecs.Transform3D
local MeshMaterial <const> = tecs.gfx.MeshMaterial
local Tint <const> = tecs.gfx.Tint
local Renderable3D <const> = tecs.gfx.Renderable3D

local FLOOR_VERTICES <const>: {number} = {
    -4,
    -1.5,
    -3,
    0,
    1,
    0,
    1,
    0,
    0,
    1,
    0,
    0,
    4,
    -1.5,
    -3,
    0,
    1,
    0,
    1,
    0,
    0,
    1,
    1,
    0,
    4,
    -1.5,
    3,
    0,
    1,
    0,
    1,
    0,
    0,
    1,
    1,
    1,
    -4,
    -1.5,
    3,
    0,
    1,
    0,
    1,
    0,
    0,
    1,
    0,
    1,
}
local FLOOR_INDICES <const>: {integer} = {0, 2, 1, 0, 3, 2}

local function game(world: tecs.World, app: tecs.Application)
    local meshes <const> = app.renderer.meshes
    meshes.camera.y = 0.35
    meshes.camera.z = 5.5
    meshes.camera.verticalFov = math.rad(50)

    local floor, floorBounds <const> = meshes:registerMesh(assets.newMesh({
        name = "example://morph-floor",
        vertices = FLOOR_VERTICES,
        indices = FLOOR_INDICES,
    }))
    world:spawn(Transform3D(), floor, floorBounds, MeshMaterial(), Tint(0.22, 0.25, 0.3, 1), Renderable3D())

    assets.loadGLTF(files.assetPath("models/morph-cube.gltf")):onSettle(function(loaded: tecs.Future<tecs.assets.Model>)
        if loaded.status ~= "ready" then
            error(loaded.error, 0)
        end
        local model <const> = meshes:registerModel(loaded.value)
        local instance <const> = model:newInstance()
        local placement <const> = Transform3D()
        instance.transform = placement
        local entities: {integer} = {}
        for index, primitive in ipairs(instance.primitives) do
            local entity <const> = world:spawn(
                primitive.transform,
                primitive.mesh,
                primitive.bounds,
                primitive.material,
                primitive.morph,
                Tint(1, 1, 1, 1),
                Renderable3D()
            )
            entities[index] = entity
        end
        world:enqueueCommit()
        for index, entity in ipairs(entities) do
            instance:bind(world, index, entity)
        end
        instance:play("StretchAndTwist", {speed = 0.65})
        local turn = 0.0
        world:addSystem({
            name = "example.AnimateMorph",
            phase = tecs.ecs.phases.Update,
            run = function(dt: number)
                turn = (turn + dt * 0.45) % (math.pi * 2)
                placement.rotationY = math.sin(turn * 0.5)
                placement.rotationW = math.cos(turn * 0.5)
                instance:update(dt)
            end,
        })
        print("morph3d: rotating six colored faces while cycling two GPU morph targets")
        print("morph3d: escape or close the window to quit")
    end)
end

return tecs.newApplication({
    window = {title = "Tecs glTF morph targets", width = 960, height = 640},
    ambientLight = {0.08, 0.1, 0.14},
    sprites = false,
    meshes = {
        capacity = 16,
        vertexCapacity = 256,
        indexCapacity = 768,
        morphing = {vertexCapacity = 256, weightCapacity = 32},
        vertexColors = true,
        shadows = {
            scale = 1,
            distance = 8,
            directionX = -0.55,
            directionY = -1,
            directionZ = -0.4,
            r = 0.92,
            g = 0.96,
            b = 1,
            intensity = 2.6,
            strength = 0.82,
            softness = 1.5,
        },
    },
    maxEntities = 8,
    presentMode = "vsync",
    debug = true,
    debugMaxFrames = tonumber(os.getenv("TECS_FRAMES")) as integer,
    quitOnEscape = true,
    plugin = game,
})
