--- Shared type definitions for the tecs2d.gfx module.

local Camera <const> = require("tecs2d.gfx.Camera")
local sheet <const> = require("tecs2d.gfx.sheet")

local record types
    --- Camera type re-export.
    type Camera = Camera

    --- Coordinate space for a layer.
    enum LayerSpace
        --- World coordinates, camera-relative (default)
        "world"
        --- Virtual coordinates (0-virtualHeight), screen-fixed
        "virtual"
        --- Screen pixel coordinates, screen-fixed
        "screen"
    end

    --- Options for layer effects.
    record LayerEffectOptions
        --- If true, effect only applies to this layer.
        --- If false (default), effect applies to this layer AND all layers below.
        singleLayer: boolean
    end

    --- Depth sorting mode for a layer.
    enum SortMode
        --- Y-sort: entities lower on screen appear in front (default, good for top-down games)
        "topdown"
        --- Z-only: sort purely by Z-index, no spatial sorting
        "z"
        --- Isometric: sort by X + Y + Z (good for isometric games)
        "isometric"
    end

    --- Interface for components that provide axis-aligned bounding boxes.
    --- Used for culling and collision detection.
    interface Rect
        --- Get the offset and size for this component relative to the entity's position.
        --- @return offsetX The x offset from the entity position.
        --- @return offsetY The y offset from the entity position.
        --- @return width The width of the bounding box.
        --- @return height The height of the bounding box.
        getRect: function(self): number, number, number, number
    end

    --- Fluent state for configuring CPU world shader draws.
    --- Obtained via pipeline:worldShader(). Chain methods, then call :attach().
    interface WorldShaderState
        --- Set depth sorting position. z, x, and bottomY default to 0 if omitted.
        --- @param layer Render layer (1-16)
        --- @param z Z-index within layer (default 0)
        --- @param x X coordinate for isometric sorting (default 0)
        --- @param bottomY Bottom Y coordinate for isometric sorting (default 0)
        --- @return self for chaining
        at: function(WorldShaderState, layer: number, z?: number, x?: number, bottomY?: number): WorldShaderState

        --- Mark this draw as unlit (full brightness, no lighting).
        --- @return self for chaining
        unlit: function(WorldShaderState): WorldShaderState

        --- Set a custom shader component. Custom shaders MUST be MRT-aware and output to both:
        ---   love_Canvases[0] = albedo color
        ---   love_Canvases[1] = vec4(normal * 0.5 + 0.5, lit ? 1.0 : 0.0)
        ---
        --- Tecs provides these uniforms (using tecs_ prefix like Love2D's love_ prefix):
        ---   tecs_Depth (float) - depth value for z-sorting
        ---   tecs_NormalMap (Image) - normal map texture (or flat normal fallback)
        ---   tecs_Lit (float) - 1.0 if lit, 0.0 if unlit
        ---   tecs_Time (float) - game time for animations
        ---
        --- Custom shaders have access to all Love2D built-in shader variables:
        --- https://love2d.org/wiki/Shader_Variables
        --- @param loveShader A love.graphics.Shader
        --- @return self for chaining
        shader: function(WorldShaderState, loveShader: love.graphics.Shader): WorldShaderState

        --- Set a normal map texture for per-pixel normals.
        --- @param texture The normal map texture
        --- @return self for chaining
        normalMap: function(WorldShaderState, texture: love.graphics.Texture): WorldShaderState

        --- Apply the world shader with the accumulated settings.
        --- Draw after this call, then call pipeline:detachWorldShader() when done.
        attach: function(WorldShaderState)
    end

    --- Configuration for bloom post-processing.
    record BloomConfig
        --- Enable bloom. Defaults to false.
        enabled: boolean
        --- Bloom intensity multiplier (0-10). Defaults to 0.5.
        intensity: number
        --- Tent filter radius (0.1-5). Defaults to 1.0. Higher = wider glow.
        radius: number
        --- Brightness threshold (0+). Defaults to 0.0 (all emission blooms).
        threshold: number
    end

    --- The render pipeline interface.
    --- GPU components (Sprite, Circle, etc.) sync to GPU buffers automatically.
    --- CPU draw methods queue love.graphics calls for rendering after GPU passes.
    interface Pipeline
        --- Stable identity of the world that owns this pipeline.
        getWorldId: function(self): integer

        --- Set the screen size of the pipeline.
        setScreenSize: function(self, w: number, h: number)

        --- Check if lighting is enabled.
        isLightingEnabled: function(self): boolean

        --- Enable lighting.
        enableLighting: function(self)

        --- Disable lighting.
        disableLighting: function(self)

        --- Set the ambient light color.
        setAmbientLight: function(self, r: number, g: number, b: number)

        --- Get the ambient light color.
        getAmbientLight: function(self): number, number, number

        --- Set the visibility of a layer.
        setLayerVisibility: function(self, layer: integer | string, visible: boolean)

        --- Check if a layer is visible.
        isLayerVisible: function(self, layer: integer | string): boolean

        --- Set whether a layer is unlit (skips lighting).
        --- When unlit is true, all entities on this layer render at full brightness.
        setLayerUnlit: function(self, layer: integer | string, unlit: boolean)

        --- Check if a layer is unlit (skips lighting).
        isLayerUnlit: function(self, layer: integer | string): boolean

        --- Set the parallax factor for a layer.
        --- @param layer The layer number (1-16) or name.
        --- @param parallaxX Horizontal parallax factor (1.0 = normal, 0.5 = half speed, 0.0 = fixed).
        --- @param parallaxY Vertical parallax factor (defaults to parallaxX if nil).
        setLayerParallax: function(self, layer: integer | string, parallaxX: number, parallaxY: number)

        --- Get the parallax factor for a layer.
        --- @param layer The layer number (1-16) or name.
        --- @return parallaxX, parallaxY
        getLayerParallax: function(self, layer: integer | string): number, number

        --- Set the depth sorting mode for a layer.
        --- @param layer The layer number (1-16) or name.
        --- @param mode The sort mode: "topdown" (default), "z", or "isometric".
        setLayerSortMode: function(self, layer: integer | string, mode: SortMode)

        --- Get the depth sorting mode for a layer.
        --- @param layer The layer number (1-16) or name.
        --- @return The sort mode.
        getLayerSortMode: function(self, layer: integer | string): SortMode

        --- Configure a layer with options.
        --- @param layer The layer number (1-16). Sparse usage is allowed.
        --- @param config Configuration options for the layer.
        configureLayer: function(self, layer: integer, config: LayerConfig)

        --- Render the scene (GPU-only implementation).
        render: function(self)

        --- Create and register a new camera.
        --- @param name Unique name for the camera.
        --- @param config Optional camera configuration.
        --- @return The created Camera.
        newCamera: function(self, name: string, config?: Camera.CameraConfig): Camera

        --- Get a camera by name. No args = primary camera.
        --- @param name Optional camera name.
        --- @return The Camera, or nil if not found.
        getCamera: function(self, name?: string): Camera

        --- Remove a registered camera by name. Cannot remove primary.
        --- @param name Camera name.
        removeCamera: function(self, name: string)

        --- Set retro (low-res + nearest-neighbor upscale) rendering.
        --- @param mode true = retro (pixel-art), false = smooth full-res rendering.
        setPixelMode: function(self, mode: boolean)

        --- Get retro-rendering state.
        --- @return true if retro mode is active.
        getPixelMode: function(self): boolean

        --- Toggle hard-edge SDF rendering. When true, circles, rectangles,
        --- ellipses, arcs, and lines render with hard pixel cutoffs instead
        --- of anti-aliased SDF edges. Independent of `pixelMode`.
        setRoughGeometry: function(self, mode: boolean)

        --- Get hard-edge geometry state.
        --- @return true if rough geometry rendering is active.
        getRoughGeometry: function(self): boolean


        --- Set the time scale multiplier.
        --- @param scale Time scale (clamped to 0.0 to 10.0, 1.0 = normal)
        setTimeScale: function(self, scale: number)

        --- Get the current time scale multiplier.
        --- @return The time scale (1.0 = normal)
        getTimeScale: function(self): number

        --- Get the current game time (respects time scale).
        --- @return The accumulated game time in seconds
        getTime: function(self): number

        --- Compute a depth value for sorting (matches GPU shader formula).
        --- Lower depth = further back in scene.
        --- @param layer Layer number (1-16)
        --- @param z Z-index within layer
        --- @param x X coordinate of the entity (for isometric sorting)
        --- @param bottomY Bottom Y coordinate of the entity
        --- @return Depth value in range [0, 1]
        computeDepth: function(self, layer: number, z: number, x: number, bottomY: number): number

        --- Get the pre-allocated WorldShaderState for fluent configuration.
        --- Resets all fields to defaults. Chain methods and call :attach() to apply.
        ---
        --- Example:
        ---   pipeline:worldShader():at(layer, z, x, bottomY):attach()
        ---   pipeline:worldShader():at(layer):unlit():attach()
        ---   pipeline:worldShader():at(layer, z):shader(s):normalMap(tex):attach()
        ---
        --- Call pipeline:detachWorldShader() after drawing.
        worldShader: function(self): WorldShaderState

        --- Detach the world shader after CPU draws.
        detachWorldShader: function(self)

        --- Set a shader effect on a layer.
        --- The effect is applied after lighting as a full-screen post-process pass.
        --- When any layer has an effect, the pipeline renders in multiple passes,
        --- grouped by effect boundaries.
        --- @param layer The layer number (1-16) or name.
        --- @param shader A single Shader or list of Shaders (multi-pass, e.g. separable blur).
        --- @param uniforms Optional table of uniform name/value pairs sent to all shaders.
        --- @param options Optional options (singleLayer: if false, effect applies to layer and all below).
        setLayerEffect: function(
            self,
            layer: integer | string,
            -- A single Love Shader or a list for a multi-pass effect. Teal
            -- cannot discriminate the union because both are table-backed in
            -- the Love declarations, so this boundary is intentionally dynamic.
            shader: any,
            uniforms?: {string: any},
            options?: LayerEffectOptions
        )

        --- Remove a shader effect from a layer.
        --- @param layer The layer number (1-16) or name.
        clearLayerEffect: function(self, layer: integer | string)

        --- Set bloom post-processing configuration.
        --- @param config BloomConfig table (partial updates supported).
        setBloom: function(self, config: BloomConfig)

        --- Get the current bloom configuration.
        --- @return The current BloomConfig.
        getBloom: function(self): BloomConfig

        --- Register a cookie (gobo) texture for light projection.
        --- @param name Unique name for the cookie.
        --- @param sheet SpriteSheet loaded via the sheet module.
        --- @param tag Optional animation tag name.
        --- @return Cookie ID (integer, 1-based).
        registerCookie: function(self, name: string, spriteSheet: sheet.SpriteSheet, tag?: string): integer

        --- Look up a cookie ID by name.
        --- @param name Cookie name.
        --- @return Cookie ID, or 0 if not found.
        getCookie: function(self, name: string): integer

        --- Look up a cookie name by ID.
        --- @param id Cookie ID (1-based).
        --- @return Cookie name, or nil if not found.
        getCookieName: function(self, id: integer): string

        --- Query the lighting brightness at a world position.
        --- Returns 0-1 perceptual luminance including shadow occlusion,
        --- or 0 when the position is off-screen. Performs a GPU readback
        --- that stalls the pipeline; intended for tooling and infrequent
        --- checks, not per-frame gameplay code.
        queryLightAt: function(self, worldX: number, worldY: number): number

        --- Check if Draw phase is currently active.
        --- @return true if within Draw phase render context
        isDrawActive: function(self): boolean

        --- Draw phase state (only valid during Draw phase)
        drawCamX: number
        drawCamY: number
        drawZoom: number
        drawRW: number
        drawRH: number
    end

    --- Configuration options for a layer.
    record LayerConfig
        --- Optional name for the layer.
        name: string
        --- Whether the layer is visible (defaults to true).
        visible: boolean
        --- Coordinate space for this layer (defaults to "world").
        --- "world": World coordinates, camera-relative
        --- "virtual": Virtual coordinates (0-virtualHeight), screen-fixed, ignores zoom
        --- "screen": Screen pixel coordinates, screen-fixed, ignores zoom
        space: LayerSpace
        --- Whether the layer is unlit (defaults to false).
        --- When true, all entities on this layer render at full brightness without lighting.
        unlit: boolean
        --- Horizontal parallax factor (defaults to 1.0).
        --- 1.0 = moves with camera, 0.5 = half speed, 0.0 = fixed.
        parallaxX: number
        --- Vertical parallax factor (defaults to 1.0).
        --- 1.0 = moves with camera, 0.5 = half speed, 0.0 = fixed.
        parallaxY: number
        --- Depth sorting mode (defaults to "topdown").
        --- "topdown": Y-sort, entities lower on screen appear in front.
        --- "z": Z-only, sort purely by Z-index.
        --- "isometric": Sort by X + Y + Z.
        sortMode: SortMode
    end

    --- A layer of the render pipeline.
    record Layer
        --- The layer number.
        layer: integer
        --- Whether the layer is visible (defaults to true).
        visible: boolean
        --- Optional name for the layer.
        name: string
        --- Coordinate space for this layer.
        space: LayerSpace
    end
end

return types
