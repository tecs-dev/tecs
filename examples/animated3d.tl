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
local FlyCamera3D <const> = tecs.gfx.FlyCamera3D

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

    local controller <const> = FlyCamera3D.new(app.input, meshes.camera, {moveSpeed = 5, sprintMultiplier = 4})
    local ssaoIntensity <const> = meshes.ssao.intensity
    world:addSystem({
        name = "example.AnimatedFlyCamera",
        phase = tecs.ecs.phases.Update,
        run = function(dt: number)
            controller:update(dt)
            if app.input:keyPressed("O") then
                meshes.ssao.intensity = meshes.ssao.intensity > 0.0 and 0.0 or ssaoIntensity
                print(("animated3d: SSAO %s"):format(meshes.ssao.intensity > 0.0 and "on" or "off"))
            end
        end,
    })
    print("animated3d: click to look; WASD moves, Q/E changes height, Shift sprints, Tab releases")
    print("animated3d: O toggles half-resolution screen-space ambient occlusion")

    local floor, floorBounds = meshes:registerMesh(tecs.assets.newMesh({
        name = "example://animated-hero-floor",
        vertices = FLOOR_VERTICES,
        indices = FLOOR_INDICES,
    }))
    world:spawn(Transform3D(), floor, floorBounds, MeshMaterial(), Tint(0.26, 0.29, 0.34, 1), Renderable3D())

    local loadedHero <const> = assets.loadGLTF(files.assetPath("models/hero.glb"))
    local model <const> = meshes:registerModel(loadedHero)
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
            primitive.bounds.centerX, primitive.bounds.centerY, primitive.bounds.centerZ, primitive.bounds.radius + 1.5
        )
        if primitive.skin ~= nil then
            entities[index] = world:spawn(
                primitive.transform,
                primitive.mesh,
                animatedBounds,
                primitive.material,
                primitive.skin,
                Tint(1, 1, 1, 1),
                Renderable3D()
            )
        else
            entities[index] = world:spawn(
                primitive.transform,
                primitive.mesh,
                animatedBounds,
                primitive.material,
                Tint(1, 1, 1, 1),
                Renderable3D()
            )
        end
    end
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

    local loadedMorph <const> = assets.loadGLTF(files.assetPath("models/morph-cube.gltf"))
    local morphModel <const> = meshes:registerModel(loadedMorph)
    local morphInstance <const> = morphModel:newInstance()
    local morphPlacement <const> = Transform3D(2.6, 1.45, 0)
    morphPlacement.scaleX = 0.72
    morphPlacement.scaleY = 0.72
    morphPlacement.scaleZ = 0.72
    morphInstance.transform = morphPlacement
    local morphEntities: {integer} = {}
    for index, primitive in ipairs(morphInstance.primitives) do
        morphEntities[index] = world:spawn(
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
    for index, entity in ipairs(morphEntities) do
        morphInstance:bind(world, index, entity)
    end
    morphInstance:play("StretchAndTwist", {speed = 0.65})
    local turn = 0.0
    world:addSystem({
        name = "example.AnimateMorphCompanion",
        phase = tecs.ecs.phases.Update,
        run = function(dt: number)
            turn = (turn + dt * 0.45) % (math.pi * 2)
            morphPlacement.rotationY = math.sin(turn * 0.5)
            morphPlacement.rotationW = math.cos(turn * 0.5)
            morphInstance:update(dt)
        end,
    })
    print("animated3d: added the independently placed GPU morph companion")
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
        ssao = {scale = 0.5, radius = 0.9, bias = 0.025, intensity = 1.15, power = 1.5},
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
