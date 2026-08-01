--- Loads and draws a textured glTF 2.0 scene through the opaque mesh domain.

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
    meshes.camera.z = 2.5
    meshes.camera.verticalFov = math.rad(55)

    assets.loadGLTF(files.assetPath("models/triangle.gltf")):onSettle(function(loaded: tecs.Future<tecs.assets.Model>)
        if loaded.status ~= "ready" then
            error(loaded.error, 0)
        end
        for _, primitive in ipairs(meshes:registerModel(loaded.value)) do
            world:spawn(
                primitive.transform,
                primitive.mesh,
                primitive.bounds,
                primitive.material,
                Tint(1, 1, 1, 1),
                Renderable3D()
            )
        end
        print("gltf3d: loaded textured glTF geometry, images, and PBR material data")
    end)
end

return tecs.newApplication({
    window = {title = "Tecs glTF 3D", width = 960, height = 640},
    ambientLight = {1, 1, 1},
    sprites = false,
    meshes = {
        capacity = 64,
        vertexCapacity = 1024,
        indexCapacity = 3072,
        materialCapacity = 32,
        textureWidth = 64,
        textureHeight = 64,
        textureLayers = 4,
        packTextures = true,
    },
    maxEntities = 16,
    debug = true,
    debugMaxFrames = tonumber(os.getenv("TECS_FRAMES")) as integer,
    quitOnEscape = true,
    plugin = game,
})
