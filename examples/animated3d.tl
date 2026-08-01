--- Loads, instantiates, binds, and plays one skinned glTF animation clip.

local root = os.getenv("TECS_LUA") or (_G as {string: any})["__tecsContent"] as string or "out/macos-arm64-dev/lua"
if root:sub(-1) == "/" then
    root = root:sub(1, -2)
end
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local tecs <const> = require("tecs")
local assets <const> = tecs.assets
local files <const> = tecs.io.files
local Tint <const> = tecs.gfx.Tint
local Renderable3D <const> = tecs.gfx.Renderable3D

local function game(world: tecs.World, app: tecs.Application)
    local meshes <const> = app.renderer.meshes
    meshes.camera.z = 3
    meshes.camera.verticalFov = math.rad(50)

    assets.loadGLTF(files.assetPath("models/animated.gltf")):onSettle(function(loaded: tecs.Future<tecs.assets.Model>)
        if loaded.status ~= "ready" then
            error(loaded.error, 0)
        end
        local model <const> = meshes:registerModel(loaded.value)
        local instance <const> = model:newInstance()
        for index, primitive in ipairs(instance.primitives) do
            local entity: integer
            if primitive.skin ~= nil then
                entity = world:spawn(
                    primitive.transform,
                    primitive.mesh,
                    primitive.bounds,
                    primitive.material,
                    primitive.skin,
                    Tint(0.2, 0.72, 1, 1),
                    Renderable3D()
                )
            else
                entity = world:spawn(
                    primitive.transform,
                    primitive.mesh,
                    primitive.bounds,
                    primitive.material,
                    Tint(0.2, 0.72, 1, 1),
                    Renderable3D()
                )
            end
            instance:bind(world, index, entity)
        end
        instance:play("Wave")
        world:addSystem({
            name = "example.AnimateGLTF",
            phase = tecs.ecs.phases.Update,
            run = function(dt: number)
                instance:update(dt)
            end,
        })
        print("animated3d: sampling the glTF Wave clip into an instance-owned GPU palette")
        print("animated3d: escape or close the window to quit")
    end)
end

return tecs.newApplication({
    window = {title = "Tecs animated glTF", width = 960, height = 640},
    ambientLight = {1, 1, 1},
    sprites = false,
    meshes = {
        capacity = 16,
        vertexCapacity = 256,
        indexCapacity = 768,
        skinning = {jointCapacity = 32},
    },
    maxEntities = 8,
    debug = true,
    debugMaxFrames = tonumber(os.getenv("TECS_FRAMES")) as integer,
    quitOnEscape = true,
    plugin = game,
})
