--- Public SpriteSheet type surface.
---
--- Declares the supported SpriteSheet API (instance methods, static
--- factories, and the data records they return) with no storage fields.
--- The concrete implementation lives in
--- `tecs2d.gfx.internal.sprite.sheet`; `gfx.SpriteSheet` and
--- `assets.SpriteSheet` re-export that implementation cast to the types
--- declared here, so the sheet's frame cache, UV buffers, and material
--- textures stay private and can be rewritten freely.

local record sprite_sheet
    --- Direction constants for animation playback.
    record DirectionConstants
        FORWARD: integer
        REVERSE: integer
        PINGPONG: integer
    end

    --- Direction constants for animation playback.
    Direction: DirectionConstants

    --- A frame in the sprite sheet.
    record Frame
        x: number
        y: number
        w: number
        h: number
        duration: number
    end

    --- A frame tag defining an animation sequence.
    record FrameTag
        from: integer
        to: integer
        -- Direction constant value
        direction: integer
        duration: number

        --- Pre-calculated timing lookup table for fast frame access.
        timingTable: {number}
    end

    --- A slice key for collision boxes, pivot points, etc.
    record SliceKey
        frame: integer
        x: number
        y: number
        w: number
        h: number
        hasCenter: boolean
        centerX: number
        centerY: number
        hasPivot: boolean
        pivotX: number
        pivotY: number
    end

    --- A slice containing multiple slice keys.
    record Slice
        -- User-defined data
        data: string
        keys: {SliceKey}
    end

    --- Options for loading a sprite sheet.
    record LoadOptions
        --- Auto-generate normal map from alpha edges if no _n.png exists.
        generateNormal: boolean
    end

    --- A loaded sprite sheet: frame/tag/slice data plus the atlas texture
    --- and optional material maps. Construct via the static factories
    --- (`fromFile`, `fromTexture`, `builder`, ...).
    record SpriteSheet
        --- Get frame data by frame number.
        getFrame: function(self, frame: integer): Frame

        --- Get frame tag data by name.
        getFrameTag: function(self, tag: string): FrameTag

        --- Check if a frame tag exists.
        hasFrameTag: function(self, tag: string): boolean

        --- Get the slice data of a slice by name.
        getSlice: function(self, name: string): Slice

        --- Get the size of the sprite sheet in pixels.
        getSheetSize: function(self): number, number

        --- Get the sprite size (individual frame size).
        getSpriteSize: function(self): number, number

        --- Get the image of the sprite sheet.
        getImage: function(self): love.graphics.Image

        --- Get the quad of a frame.
        getQuad: function(self, frame: integer): love.graphics.Quad

        --- Get the frame number and updated elapsed time for animation.
        --- @param tag The tag to get the frame for
        --- @param timeElapsed The time elapsed since the last frame
        --- @return frameNumber The frame number to draw
        --- @return newTimeElapsed The updated time elapsed (looping if necessary)
        getAnimationFrame: function(self, tag: string, timeElapsed: number): integer, number

        --- Get the file path this sheet was loaded from (for serialization).
        --- @return The image file path, or an empty string when the sheet has
        --- no durable source path.
        getPath: function(self): string

        --- Get pre-computed UV coordinates for a frame.
        --- @param frame The frame number (1-indexed, as elsewhere in the API)
        --- @return u, v, w, h normalized texture coordinates
        getFrameUV: function(self, frame: integer): number, number, number, number

        --- Get the unique ID of this sheet.
        getId: function(self): integer

        --- Get tag ID from tag name (0 = default/all frames).
        --- @param tag The tag name (empty string for default)
        --- @return The tag ID, or 0 if not found
        getTagId: function(self, tag: string): integer

        --- Get tag name from tag ID.
        --- @param id The tag ID (0 = default/all frames)
        --- @return The tag name, or "" for default
        getTagName: function(self, id: integer): string

        --- Get frame tag data by ID.
        --- @param id The tag ID (0 = default)
        --- @return The FrameTag data
        getFrameTagById: function(self, id: integer): FrameTag

        --- Get slice ID from slice name.
        --- @param name The slice name
        --- @return The slice ID, or 0 if not found
        getSliceId: function(self, name: string): integer

        --- Get slice name from slice ID.
        --- @param id The slice ID
        --- @return The slice name, or nil if not found
        getSliceName: function(self, id: integer): string

        --- Get slice data by ID.
        --- @param id The slice ID
        --- @return The Slice data, or nil if not found
        getSliceById: function(self, id: integer): Slice

        --- Get normal map image (from _n.png), or nil if not loaded.
        getNormalImage: function(self): love.graphics.Image

        --- Get emission map image (from _e.png), or nil if not loaded.
        getEmissionImage: function(self): love.graphics.Image

        --- Get ORM map image (R=AO, G=roughness, B=metallic), or nil if not loaded.
        getORMImage: function(self): love.graphics.Image

        --- Generate a normal map from alpha edges (Sobel-like filter).
        --- Overwrites any existing normal map.
        generateNormalMap: function(self)

        --- Get a sheet by its ID from the global registry.
        --- @param id The sheet ID
        --- @return The SpriteSheet, or nil if not found
        getById: function(id: integer): SpriteSheet

        --- Allocate the GPU texture bucket for every loaded sheet up front,
        --- so the first sprite using a sheet doesn't hitch while its texture
        --- array is created. Call once at startup (e.g. a PostStartup system)
        --- after the render pipeline exists. Idempotent.
        preloadAll: function()

        --- Create a new sheet from Love2D image and data.
        --- @param image The Love2D image
        --- @param data The file data containing JSON configuration
        --- @param path File path used for serialization
        --- @return A new SpriteSheet instance
        fromImage: function(
            image: love.graphics.Image,
            data: love.filesystem.FileData,
            path: string
        ): SpriteSheet

        --- Create a new sheet from file path.
        ---
        --- Assumes the JSON data file is alongside the image with .json extension.
        --- @param file The image file path
        --- @param options Optional load options (e.g., { generateNormal = true })
        --- @return A new SpriteSheet instance
        fromFile: function(file: string, options?: LoadOptions): SpriteSheet

        --- Create a new sheet from Love2D image and config table.
        --- @param image The Love2D image
        --- @param config The configuration table (parsed from JSON)
        --- @param path File path used for serialization
        --- @return A new SpriteSheet instance
        fromConfig: function(image: love.graphics.Image, config: table, path: string): SpriteSheet

        --- Create a builder configured from Aseprite JSON data.
        --- Use this for async loading when you need to add material maps before building.
        --- @param image The Love2D image
        --- @param data The file data containing JSON configuration
        --- @param path File path for serialization
        --- @return A Builder configured with frames, tags, and slices from the JSON
        builderFromImage: function(image: love.graphics.Image, data: love.filesystem.FileData, path: string): Builder

        --- Create a simple single-frame sheet from a texture.
        --- @param texture The texture to wrap
        --- @param path Optional file path for serialization and material map loading
        --- @param options Optional load options (e.g., { generateNormal = true })
        --- @return A new SpriteSheet instance with one frame
        fromTexture: function(texture: love.graphics.Texture, path?: string, options?: LoadOptions): SpriteSheet

        --- Create a simple single-frame sheet from an image file.
        --- Automatically loads material maps (_n.png, _e.png, _orm.png) if they exist.
        --- @param file The image file path
        --- @param options Optional load options (e.g., { generateNormal = true })
        --- @return A new SpriteSheet instance with one frame
        fromTextureFile: function(file: string, options?: LoadOptions): SpriteSheet

        --- Create a builder for constructing a sprite sheet programmatically.
        --- Useful for integrating with non-Aseprite atlas formats.
        --- @param image The Love2D image to use as the texture atlas
        --- @param path Optional file path for serialization
        --- @return A new Builder instance
        builder: function(image: love.graphics.Image, path?: string): Builder
    end

    --- Builder for constructing sprite sheets programmatically.
    --- Use SpriteSheet.builder(image) to create one.
    interface Builder
        --- Add a frame to the sheet.
        --- @param x X position of the frame in the atlas (pixels)
        --- @param y Y position of the frame in the atlas (pixels)
        --- @param w Width of the frame (pixels)
        --- @param h Height of the frame (pixels)
        --- @param duration Frame duration in milliseconds (default: 100)
        --- @return self for method chaining
        frame: function(self, x: number, y: number, w: number, h: number, duration?: number): Builder

        --- Add an animation tag defining a named sequence of frames.
        --- @param name Tag name (e.g., "idle", "walk")
        --- @param from Start frame index (0-indexed)
        --- @param to End frame index (0-indexed, inclusive)
        --- @param direction Playback direction: "forward", "reverse", or "pingpong" (default: "forward")
        --- @return self for method chaining
        tag: function(self, name: string, from: integer, to: integer, direction?: string): Builder

        --- Add a slice with a single key at frame 0.
        --- @param name Slice name (e.g., "hitbox", "origin")
        --- @param x X position of the slice within the sprite
        --- @param y Y position of the slice within the sprite
        --- @param w Width of the slice
        --- @param h Height of the slice
        --- @return self for method chaining
        slice: function(self, name: string, x: number, y: number, w: number, h: number): Builder

        --- Add a slice with a pivot point at frame 0.
        --- @param name Slice name (e.g., "feet", "hand")
        --- @param x X position of the slice within the sprite
        --- @param y Y position of the slice within the sprite
        --- @param w Width of the slice
        --- @param h Height of the slice
        --- @param pivotX X coordinate of the pivot point within the slice
        --- @param pivotY Y coordinate of the pivot point within the slice
        --- @return self for method chaining
        sliceWithPivot: function(
            self, name: string, x: number, y: number, w: number, h: number,
            pivotX: number, pivotY: number
        ): Builder

        --- Add a complete slice with user data and multiple keys.
        --- Primarily used internally for Aseprite import.
        --- @param name Slice name
        --- @param data User data string from Aseprite
        --- @param keys Array of SliceKey objects for per-frame slice data
        --- @return self for method chaining
        sliceRaw: function(self, name: string, data: string, keys: {SliceKey}): Builder

        --- Set the normal map image.
        --- @param image The normal map texture
        --- @return self for method chaining
        normalImage: function(self, image: love.graphics.Image): Builder

        --- Set the emission map image.
        --- @param image The emission map texture
        --- @return self for method chaining
        emissionImage: function(self, image: love.graphics.Image): Builder

        --- Set the ORM map image (R=AO, G=roughness, B=metallic).
        --- @param image The ORM map texture
        --- @return self for method chaining
        ormImage: function(self, image: love.graphics.Image): Builder

        --- Load material maps from filesystem based on the builder's path.
        --- Loads _n.png (normal), _e.png (emission), _orm.png (ORM) if they exist.
        --- Falls back to compositing _ao.png, _rough.png, _metal.png into ORM if needed.
        --- @param options Optional load options (e.g., { generateNormal = true })
        --- @return self for method chaining
        loadMaterialMaps: function(self, options?: LoadOptions): Builder

        --- Build the sprite sheet from the configured frames, tags, and slices.
        --- @return A new SpriteSheet instance
        build: function(self): SpriteSheet
    end
end

return sprite_sheet
