local tecs <const> = require("tecs")
local types <const> = require("tecs2d.assets.types")
local threaded <const> = require("tecs2d.assets.internal.threaded")

--- A module for asynchronously loading assets in threads for Love2D games.
---
--- Assets are loaded in a thread pool based on the number of CPU cores.
--- The thread-pool is capped at 4 threads.
---
--- The game plugin automatically creates an asset manager with root "assets".
--- Use `world.resources[assets]:setRoot(path)` to change the root directory.
local record assets is tecs.Key<types.AssetManager>
    type AssetManager = types.AssetManager
    type Handle<T> = types.Handle
    type FontConfig = types.FontConfig
    type ImageFontConfig = types.ImageFontConfig
    type AssetStats = types.AssetStats
    type AssetHandler<T> = types.AssetHandler
    type SpriteSheetLoadOptions = types.SpriteSheetLoadOptions
    type SpriteSheet = types.SpriteSheet
    type BMFont = types.BMFont
    type TilemapData = types.TilemapData

    --- Event emitted when the initial asset load completes.
    InitialLoadComplete: tecs.Event

    --- Creates a new asset manager.
    ---
    --- @param root The root directory to load assets from.
    --- @return a new asset manager.
    new: function(root: string): types.AssetManager

    --- Creates a new asset handler for custom asset types.
    ---
    --- @return a new asset handler instance.
    newAssetHandler: function<T>(): types.AssetHandler<T>
end

assets.InitialLoadComplete = threaded.InitialLoadComplete

-------------------------------------------------------------------------------
-- Create a new asset manager
-------------------------------------------------------------------------------

function assets.new(root: string): assets.AssetManager
    return threaded.new(root)
end

function assets.newAssetHandler<T>(): types.AssetHandler<T>
    return {} as types.AssetHandler<T>
end

return assets
