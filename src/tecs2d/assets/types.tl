local sheet <const> = require("tecs2d.gfx.sheet")
local bmfont_module <const> = require("tecs2d.gfx.bmfont")
local tiled_types <const> = require("tecs2d.tiled.types")
local workers <const> = require("tecs2d.workers")

local record types
    type Handle<T> = workers.Handle<T>

    --- Re-export SpriteSheet type for convenience
    SpriteSheet: sheet.SpriteSheet

    --- Re-export BMFont type for convenience
    BMFont: bmfont_module.BMFont

    --- Re-export TilemapData type for convenience
    TilemapData: tiled_types.TilemapData

    --- An asset manager used to asynchronously load assets in threads.
    interface AssetManager
        --- Create a batch that tracks one logical group of asset handles.
        newBatch: function(self): LoadBatch

        --- Load an asset at the given path using the given handler.
        ---
        --- Errors if a handler isn't registered.
        ---
        --- @param handler Handler identity used to look up the registered loader.
        --- @param path Path to the asset to load.
        --- @return handle with the type loaded from the registered loader.
        load: function<T>(self, handler: AssetHandler<T>, path: string): Handle<T>

        --- Register a custom asset handler to be used when `load` is called with a reference to this handler.
        --- @param handler The custom asset handler identity to register.
        --- @param loader The loader function to use for loading assets.
        registerAssetHandler: function<T>(self, handler: AssetHandler<T>, loader: function(path: string): Handle<T>)

        --- Load a file and its contents as a string.
        ---
        --- @param path The path to the file to load.
        --- @return A handle that loads the file and eventually returns its contents as a string.
        loadFile: function(self, path: string): Handle<string>

        --- Load a file and return its contents as FileData.
        ---
        --- @param path The path to the file to load.
        --- @return A handle that loads the file and eventually returns its contents as a FileData.
        loadFileData: function(self, path: string): Handle<love.filesystem.FileData>

        --- Load an image from a file.
        ---
        --- @param path The path to the image file to load.
        --- @return A handle that loads the image and eventually returns a love.graphics.Image.
        loadImage: function(self, path: string): Handle<love.graphics.Image>

        --- Load an image font from a file.
        ---
        --- @param path The path to the image file to load.
        --- @param config The optional image font configuration.
        --- @return A handle that loads the image font and eventually returns a love.graphics.Font.
        loadImageFont: function(self, path: string, config?: ImageFontConfig): Handle<love.graphics.Font>

        --- Load a TrueType font from a file.
        ---
        --- @param path The path to the font file to load.
        --- @param config The optional font configuration.
        --- @return A handle that loads the font and eventually returns a love.graphics.Font.
        loadFont: function(self, path: string, config?: FontConfig): Handle<love.graphics.Font>

        --- Load audio from a file.
        ---
        --- @param path The path to the audio file to load.
        --- @param sourceType The type of audio source to load (e.g., "static", "stream").
        --- @param streamType For streaming sources, whether to stream from "file" or "memory" (defaults to "file").
        --- @return A handle that loads the audio and eventually returns a love.audio.Source.
        loadAudio: function(self, path: string, sourceType: love.audio.SourceType, streamType?: string): Handle<love.audio.Source>

        --- Load a shader from a file.
        ---
        --- @param path The path to the shader file to load.
        --- @return A handle that loads the shader and eventually returns a love.graphics.Shader.
        loadShader: function(self, path: string): Handle<love.graphics.Shader>

        --- Load a video from a file.
        ---
        --- @param path The path to the video file to load.
        --- @return A handle that loads the video and eventually returns a love.graphics.Video.
        loadVideo: function(self, path: string): Handle<love.graphics.Video>

        --- Load compressed image data from a file.
        ---
        --- @param path The path to the compressed image file to load.
        --- @return A handle that contains a love.image.CompressedImageData.
        loadCompressedImage: function(self, path: string): Handle<love.image.CompressedImageData>

        --- Load and parse a JSON file.
        ---
        --- @param path The path to the JSON file to load.
        --- @return A handle that contains the parsed JSON data.
        loadJson: function(self, path: string): Handle<any>

        --- Get a previously loaded TTF or image font by path.
        ---
        --- Errors if the font is not loaded.
        ---
        --- @param path The path to the font asset.
        --- @return The love.graphics.Font object handle.
        getFont: function(self, path: string): Handle<love.graphics.Font>

        --- Checks if any operations are currently loading.
        isLoading: function(self): boolean

        --- Wait for all operations in the asset manager to complete.
        ---
        --- @param timeout The optional maximum time to wait in seconds.
        --- @return An array of error messages from failed operations. Empty if all succeeded or timeout occurred.
        wait: function(self, timeout?: number): {string}

        --- Closes the manager and releases its cache and pins. The owning
        --- worker queue remains responsible for pending jobs and shutdown.
        shutdown: function(self)

        --- Keep an asset handle strongly reachable from this manager's cache.
        pin: function<T>(self, handle: Handle<T>): Handle<T>

        --- Return the request metadata recorded for an asset handle.
        describe: function<T>(self, handle: Handle<T>): AssetDescriptor

        --- Get detailed statistics about the asset manager's current state.
        ---
        --- You can read this data, but do not hold onto the return value as it may be a pooled resource.
        ---
        --- @return Statistics including completed, running, cached, and pinned asset counts.
        getStats: function(self): AssetStats

        --- Resolve a path relative to the asset root.
        ---
        --- @param ... Path segments to join.
        --- @return The resolved path including the asset root.
        resolvePath: function(self, ...: string): string

        --- Set the root directory for asset loading.
        ---
        --- @param root The new root directory path.
        setRoot: function(self, root: string)

        --- Get the current root directory for asset loading.
        ---
        --- @return The current root directory path.
        getRoot: function(self): string

        --- Load a sprite sheet from an Aseprite export (image + JSON).
        --- Automatically loads material maps (_n.png, _e.png, _orm.png) if they exist.
        --- @param path Path to the image file (JSON file must have same base name)
        --- @param options Optional load options. Async loading does not generate missing normal maps.
        --- @return A handle that loads the sprite sheet with all material maps
        loadSpriteSheet: function(self, path: string, options?: SpriteSheetLoadOptions): Handle<sheet.SpriteSheet>

        --- Load a static sprite sheet from a single image (no JSON required).
        --- Automatically loads material maps (_n.png, _e.png, _orm.png) if they exist.
        --- @param path Path to the image file
        --- @param options Optional load options. Async loading does not generate missing normal maps.
        --- @return A handle that loads a single-frame sprite sheet with material maps
        loadStaticSheet: function(self, path: string, options?: SpriteSheetLoadOptions): Handle<sheet.SpriteSheet>

        --- Load a BMFont from a .fnt or .json file.
        --- Automatically detects format by extension and loads the atlas image.
        --- @param path Path to the font definition file (.fnt or .json)
        --- @return A handle that loads the BMFont with its atlas texture
        loadBMFont: function(self, path: string): Handle<bmfont_module.BMFont>

        --- Load a Tiled map from a .tmj or .json file.
        --- Automatically loads all tileset images and material maps.
        --- @param path Path to the Tiled map JSON file
        --- @return A handle that loads the complete tilemap data
        loadTiledMap: function(self, path: string): Handle<tiled_types.TilemapData>
    end

    record AssetDescriptor
        action: string
        path: string
        inputPath: string
        args: {any}
    end

    --- Progress and completion for one explicitly defined group of loads.
    interface LoadBatch
        totalCount: integer
        completedCount: integer
        failedCount: integer
        progress: number
        isComplete: boolean
        isSuccessful: boolean
        errors: {string}

        --- Track a handle, returning it unchanged for convenient assignment.
        --- Tracking the same handle more than once is idempotent.
        track: function<T>(self, handle: Handle<T>): Handle<T>

        --- Close the batch to new handles. Completion is possible only after
        --- sealing and all unique tracked handles have settled.
        seal: function(self)

        --- Observe completion once. Completed batches invoke immediately.
        observe: function(self, listener: function(LoadBatch))
    end

    --- Image font configuration.
    record ImageFontConfig
        --- The glyphs to use for the font.
        glyphs: string

        --- Extra spacing between characters.
        extraSpacing: number
    end

    --- Font configuration.
    record FontConfig
        --- Optional font size.
        size: number

        --- Optional true type hinting mode (defaults to "normal").
        hinting: love.font.HintingMode

        --- The optional DPI scale to use for the font.
        dpiscale: number
    end

    --- Options for loading sprite sheets.
    record SpriteSheetLoadOptions
        --- Reserved for synchronous loaders; async asset loading ignores this.
        generateNormal: boolean
    end

    --- Statistics about the asset manager's current state.
    record AssetStats
        --- Number of assets that have completed loading.
        completedCount: integer

        --- Number of assets currently being loaded.
        runningCount: integer

        --- Number of assets currently in the cache (including weak references).
        currentAssetCount: integer

        --- Number of assets that have been pinned to prevent garbage collection.
        pinnedAssetCount: integer
    end

    --- Asset handler interface.
    --- Handlers carry type information about what they produce
    interface AssetHandler<T> end
end

return types
