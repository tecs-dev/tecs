--- Lights and animates a CC0 skinned glTF character.

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
local Bounds3D <const> = tecs.gfx.Bounds3D
local Tint <const> = tecs.gfx.Tint
local Renderable3D <const> = tecs.gfx.Renderable3D

local FLOOR_VERTICES <const>: {number} = {
    -5,
    0,
    -4,
    0,
    1,
    0,
    1,
    0,
    0,
    1,
    0,
    0,
    5,
    0,
    -4,
    0,
    1,
    0,
    1,
    0,
    0,
    1,
    1,
    0,
    5,
    0,
    4,
    0,
    1,
    0,
    1,
    0,
    0,
    1,
    1,
    1,
    -5,
    0,
    4,
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
local CLIPS <const>: {string} = {"idle", "walk", "attack"}

local function game(world: tecs.World, app: tecs.Application)
    local meshes <const> = app.renderer.meshes
    meshes.camera.y = 3.25
    meshes.camera.z = 11
    meshes.camera.verticalFov = math.rad(46)
    meshes.camera.near = 0.1
    meshes.camera.far = 50

    local floor, floorBounds = meshes:registerMesh(tecs.assets.newMesh({
        name = "example://animated-hero-floor",
        vertices = FLOOR_VERTICES,
        indices = FLOOR_INDICES,
    }))
    world:spawn(Transform3D(), floor, floorBounds, MeshMaterial(), Tint(0.26, 0.29, 0.34, 1), Renderable3D())

    assets.loadGLTF(files.assetPath("models/hero.glb")):onSettle(function(loaded: tecs.Future<tecs.assets.Model>)
        if loaded.status ~= "ready" then
            error(loaded.error, 0)
        end
        local model <const> = meshes:registerModel(loaded.value)
        local instance <const> = model:newInstance()
        local placement <const> = Transform3D(-1.7, 0, 0)
        placement.rotationY = 1
        placement.rotationW = 0
        instance.transform = placement
        local entities: {integer} = {}
        for index, primitive in ipairs(instance.primitives) do
            -- Skinning can move vertices beyond the file's bind-pose sphere.
            -- The example owns a conservative bound that covers every clip.
            local animatedBounds <const> = Bounds3D(
                primitive.bounds.centerX,
                primitive.bounds.centerY,
                primitive.bounds.centerZ,
                primitive.bounds.radius + 1.5
            )
            local entity: integer
            if primitive.skin ~= nil then
                entity = world:spawn(
                    primitive.transform,
                    primitive.mesh,
                    animatedBounds,
                    primitive.material,
                    primitive.skin,
                    Tint(1, 1, 1, 1),
                    Renderable3D()
                )
            else
                entity = world:spawn(
                    primitive.transform,
                    primitive.mesh,
                    animatedBounds,
                    primitive.material,
                    Tint(1, 1, 1, 1),
                    Renderable3D()
                )
            end
            entities[index] = entity
        end
        -- The asset listener runs outside system dispatch, so this publishes
        -- the deferred spawns before bind reads their Transform3D columns.
        world:enqueueCommit()
        for index, entity in ipairs(entities) do
            instance:bind(world, index, entity)
        end
        local clip = 1
        local clipTime = 0.0
        instance:play(CLIPS[clip])
        world:addSystem({
            name = "example.AnimateLitHero",
            phase = tecs.ecs.phases.Update,
            run = function(dt: number)
                clipTime = clipTime + dt
                if clipTime >= 4.0 then
                    clipTime = clipTime - 4.0
                    clip = clip % #CLIPS + 1
                    instance:play(CLIPS[clip])
                end
                instance:update(dt)
            end,
        })
        print("animated3d: cycling CC0 idle, walk, and attack clips under Cook-Torrance light")
        print("animated3d: escape or close the window to quit")
    end)

    assets.loadGLTF(files.assetPath("models/morph-cube.gltf")):onSettle(function(loaded: tecs.Future<tecs.assets.Model>)
        if loaded.status ~= "ready" then
            error(loaded.error, 0)
        end
        local model <const> = meshes:registerModel(loaded.value)
        local instance <const> = model:newInstance()
        local placement <const> = Transform3D(2.6, 1.45, 0)
        placement.scaleX = 0.72
        placement.scaleY = 0.72
        placement.scaleZ = 0.72
        instance.transform = placement
        local entities: {integer} = {}
        for index, primitive in ipairs(instance.primitives) do
            entities[index] = world:spawn(
                primitive.transform,
                primitive.mesh,
                primitive.bounds,
                primitive.material,
                primitive.morph,
                Tint(1, 1, 1, 1),
                Renderable3D()
            )
        end
        world:enqueueCommit()
        for index, entity in ipairs(entities) do
            instance:bind(world, index, entity)
        end
        instance:play("StretchAndTwist", {speed = 0.65})
        local turn = 0.0
        world:addSystem({
            name = "example.AnimateMorphCompanion",
            phase = tecs.ecs.phases.Update,
            run = function(dt: number)
                turn = (turn + dt * 0.45) % (math.pi * 2)
                placement.rotationY = math.sin(turn * 0.5)
                placement.rotationW = math.cos(turn * 0.5)
                instance:update(dt)
            end,
        })
        print("animated3d: added the independently placed GPU morph companion")
    end)
end

return tecs.newApplication({
    window = {title = "Tecs animated and lit glTF", width = 960, height = 640},
    ambientLight = {0.1, 0.11, 0.14},
    sprites = false,
    meshes = {
        capacity = 32,
        vertexCapacity = 2048,
        indexCapacity = 4096,
        materialCapacity = 16,
        skinning = {jointCapacity = 64},
        morphing = {vertexCapacity = 64, weightCapacity = 8},
        vertexColors = true,
        shadows = {
            scale = 1,
            distance = 12,
            directionX = -0.55,
            directionY = -1,
            directionZ = -0.35,
            r = 1.0,
            g = 0.86,
            b = 0.7,
            intensity = 2.2,
            strength = 0.82,
            softness = 1.25,
        },
    },
    maxEntities = 16,
    debug = true,
    debugMaxFrames = tonumber(os.getenv("TECS_FRAMES")) as integer,
    quitOnEscape = true,
    plugin = game,
})
