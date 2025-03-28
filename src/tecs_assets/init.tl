local tecs <const> = require("tecs")
local types <const> = require("tecs_assets.types")
local threaded <const> = require("tecs_assets.internal.threaded")

local LOGGER <const> = tecs.logging.getLogger("tecs_assets")

--- A module for asynchronously loading assets in threads for Love2D games.
---
--- Assets are loaded in a thread pool based on the number of CPU cores.
--- The thread-pool is capped at 4 threads.
---
--- Use this module by setting up as a resource in a tecs.World:
---
--- ```lua
--- local tecs_assets = require("tecs_assets")
--- local world = tecs.newWorld()
--- world.resources[tecs_assets.KEY] = tecs_assets.new(world)
--- ```
local record tecs_assets
    type AssetManager = types.AssetManager
    type Handle<T> = types.Handle
    type PluginConfig = types.PluginConfig
    type FontConfig = types.FontConfig
    type ImageFontConfig = types.ImageFontConfig
    type AssetStats = types.AssetStats

    --- The resource sentinel value for an asset manager.
    MANAGER: tecs.Key<AssetManager>

    --- Event emitted when the initial asset load completes.
    InitialLoadComplete: tecs.Event

    --- Creates a new asset manager.
    ---
    --- @param root The root directory to load assets from.
    --- @return a new asset manager.
    new: function(root: string): types.AssetManager

    --- Creates a tecs_assets plugin for Tecs World.
    ---
    --- @param config Optional configuration for the plugin.
    --- @return a world plugin function.
    plugin: function(config?: PluginConfig): tecs.Plugin
end

tecs_assets.MANAGER = tecs.newKey()
tecs_assets.InitialLoadComplete = threaded.InitialLoadComplete

--------------------------------------------------------------------------------
-- Create a new asset manager
--------------------------------------------------------------------------------

function tecs_assets.new(root: string): tecs_assets.AssetManager
    return threaded.new(root)
end

--------------------------------------------------------------------------------
-- Plugin implementation
--------------------------------------------------------------------------------

function tecs_assets.plugin(config?: types.PluginConfig): tecs.Plugin
    config = config or {}

    -- Use provided manager, or create one with the specified root (defaulting to "assets")
    local assetManager: types.AssetManager
    if config.manager then
        assetManager = config.manager
    else
        assetManager = tecs_assets.new(config.root or "assets")
    end

    return function(w: tecs.World)
        w.resources[tecs_assets.MANAGER] = assetManager

        -- Queue assets for loading if a loader function was provided
        if config.loader then
            config.loader(assetManager)
        end

        -- Update the asset manager each frame
        w:addSystem({
            phase = tecs.phases.First,
            run = function()
                assetManager:update()
            end
        })

        -- Shutdown the asset manager when the game is shutting down.
        w:addSystem({
            phase = tecs.phases.Shutdown,
            run = function()
                LOGGER:debug("Shutting down workers")
                assetManager:shutdown()
            end
        })
    end
end

return tecs_assets