local record types

    --- An asset manager used to asynchronously load assets in threads.
    interface AssetManager
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
        --- @return A handle that loads the audio and eventually returns a love.audio.Source.
        loadAudio: function(self, path: string, sourceType: love.audio.SourceType): Handle<love.audio.Source>

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
        --- @return A handle that loads the compressed image data and eventually returns a love.image.CompressedImageData.
        loadCompressedImage: function(self, path: string): Handle<love.image.CompressedImageData>

        --- Get a previously loaded TTF or image font by path.
        ---
        --- Errors if the font is not loaded.
        ---
        --- @param path The path to the font asset.
        --- @return The love.graphics.Font object handle.
        getFont: function(self, path: string): Handle<love.graphics.Font>

        --- Updates the AssetManager each frame to check for loaded assets and update tasks.
        ---
        --- When using the plugin, this is called automatically.
        ---
        --- @return true if there are still tasks running, false if all tasks are complete.
        update: function(self): boolean

        --- Checks if any operations are currently loading.
        isLoading: function(self): boolean

        --- Wait for all operations in the asset manager to complete.
        ---
        --- @param timeout The optional maximum time to wait in seconds.
        --- @return An array of error messages from failed operations. Empty if all succeeded or timeout occurred.
        wait: function(self, timeout?: number): {string}

        --- Shuts down the asset manager and cleans up resources.
        ---
        --- Any tasks that are still running will be cancelled.
        shutdown: function(self)

        --- Get detailed statistics about the asset manager's current state.
        ---
        --- You can read this data, but do not hold onto the return value as it may be a pooled resource.
        ---
        --- @return Statistics including completed, running, cached, and pinned asset counts.
        getStats: function(self): AssetStats
    end

    --- Handle for an async operation that blocks on value access.
    interface Handle<T>
        --- Whether the operation has completed (simple boolean).
        isComplete: boolean

        --- The error message if the operation failed, or nil if successful.
        err: string

        --- Access triggers blocking if not complete, then caches result.
        --- Raises error if operation failed.
        value: T

        --- Listens once for the operation to complete.
        --- @param listener The listener to call when the operation is complete.
        observe: function(self, function(handle: Handle<T>))

        --- Pins this handle to prevent garbage collection.
        --- Useful for preloading assets that should remain in memory.
        pin: function(self)
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

    --- Configuration for the stagecoach plugin.
    record PluginConfig
        --- Optional: Custom asset manager to use. If provided, 'root' is ignored.
        manager: AssetManager

        --- Optional: Root directory for assets. Defaults to "assets". Only used if 'manager' is not provided.
        root: string

        --- Optional: Function that will be called with the asset manager to queue assets for loading.
        loader: function(AssetManager)
    end
end

return types