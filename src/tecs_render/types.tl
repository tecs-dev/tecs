--- Shared type definitions for the tecs_render module.
local tecs <const> = require("tecs")

local builtins <const> = tecs.builtins
local type Archetype = tecs.Archetype

local record types
    --- Camera interface that all camera implementations must satisfy.
    interface Camera
        --- Check if a rectangle is visible to the camera.
        --- @param x The x position of the rectangle.
        --- @param y The y position of the rectangle.
        --- @param w The width of the rectangle.
        --- @param h The height of the rectangle.
        --- @return true if the rectangle is visible.
        isVisible: function(self, x: number, y: number, w: number, h: number): boolean

        --- Set the screen size of the camera.
        --- @param w The width of the screen.
        --- @param h The height of the screen.
        setScreenSize: function(self, w: number, h: number)

        --- Attach the camera.
        attach: function(self)

        --- Draw a layer with the camera.
        --- @param layer The layer to draw.
        --- @param pipeline The pipeline to render the layer to.
        drawLayer: function(self, layer: Layer, pipeline: Pipeline)

        --- Detach the camera and render the draw calls.
        ---
        --- @param uiDraws A list of draw IDs to render on top of the camera.
        --- @param pipeline The pipeline to render the draw calls to.
        --- @param ... A list of functions that take a screenshot of the camera's current frame.
        detach: function(self, uiDraws: {integer}, pipeline: Pipeline, ...: function(love.graphics.Image))

        --- Set whether the camera should clamp to the world bounds.
        --- @param clamp True if the camera should clamp to the world bounds.
        setClamp: function(self, clamp: boolean)

        --- Sets the position of the camera.
        --- @param x The x position of the camera.
        --- @param y The y position of the camera.
        setPosition: function(self, x: number, y: number)

        --- Teleports the camera to a position immediately, ignoring lerping.
        --- @param x The x position of the camera.
        --- @param y The y position of the camera.
        teleport: function(self, x: number, y: number)

        --- Gets the position of the camera.
        --- @return The x position of the camera.
        --- @return The y position of the camera.
        getPosition: function(self): number, number

        --- Gets the zoom of the camera.
        --- @return The zoom level of the camera (1 is normal).
        getZoom: function(self): number

        --- Sets the zoom of the camera.
        --- @param zoom The zoom level of the camera (1 is normal).
        setZoom: function(self, zoom: number)

        --- Converts a screen position to a world position.
        --- @param screenX The x position on the screen.
        --- @param screenY The y position on the screen.
        --- @return x, y position in the world.
        toWorld: function(self, screenX: number, screenY: number): number, number

        --- Converts a world position to a screen position.
        --- @param worldX The x position in the world.
        --- @param worldY The y position in the world.
        --- @return x, y position on the screen.
        toScreen: function(self, worldX: number, worldY: number): number, number

        --- Gets the visible corners of the camera.
        --- @return x1, y1, x2, y2
        getVisibleCorners: function(self): number, number, number, number

        --- Gets the visible corners of the entire rendering canvas of a camera and not just what's visible.
        -- @return x1, y1, x2, y2
        getVisibleCanvasCorners: function(self): number, number, number, number

        --- Gets the visible dimensions of the camera.
        --- @return width, height
        getVisibleDimensions: function(self): number, number

        --- Update the camera position (for lerping). Call this each frame.
        --- @param dt Delta time in seconds
        update: function(self, dt: number)

        --- Enable or disable camera lerping.
        --- @param enabled True to enable lerping
        setLerpingEnabled: function(self, enabled: boolean)

        --- Set the lerp speed factor.
        --- @param speed The lerp speed (1-20, higher = snappier)
        setLerpSpeed: function(self, speed: number)
    end

    --- The render pipeline interface.
    interface Pipeline
        --- Draw an item to the pipeline.
        draw: function(
            self,
            layer: string | integer,
            x: number,
            y: number,
            w: number,
            h: number,
            f: function(...: any), ...: any
        ): integer

        --- Draw an item using a Transform component for positioning.
        drawTransform: function(
            self,
            transform: builtins.Transform,
            w: number,
            h: number,
            f: function(...: any), ...: any
        ): integer

        --- Draw a light to the lightmap.
        drawLight: function(
            self,
            layer: string | integer,
            x: number,
            y: number,
            w: number,
            h: number,
            f: function(...: any), ...: any
        ): integer

        --- Draw something using absolute positioning.
        drawAbsolute: function(self, f: function(...: any), ...: any): integer

        --- Clear all draw calls, lights, and other state.
        clear: function(self)

        --- Get the camera attached to the pipeline.
        getCamera: function(self): Camera

        --- Render to a camera.
        drawCamera: function(self, camera: Camera)

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

        --- Set a flag on a draw (ORs the flag with existing flags).
        setDrawFlag: function(self, id: integer, flag: integer)

        --- Replace all flags on a draw.
        setDrawFlags: function(self, id: integer, flags: integer)

        --- Remove a flag from a draw.
        removeDrawFlag: function(self, id: integer, flag: integer)

        --- Check if a draw has a flag.
        hasDrawFlag: function(self, id: integer, flag: integer): boolean

        --- Add a shader to a draw.
        addDrawShader: function(self, id: integer, shader: love.graphics.Shader)

        --- Set the z-depth of a draw call.
        --- @param id Draw ID to modify.
        --- @param z Z-depth value (higher values draw on top).
        setDrawZ: function(self, id: integer, z: number)

        --- Get all draw data for rendering.
        --- @param index Draw index
        --- @return x: number
        --- @return y: number
        --- @return w: number
        --- @return h: number
        --- @return drawFunction: function(...: any)
        --- @return args: {{any}}
        --- @return shaders: {love.graphics.Shader}
        --- @return flags: integer
        getDrawData: function(self, id: integer): number, number, number, number,
                                                  function(...: any), {any}, {love.graphics.Shader}, integer

        --- Get the coordinates and size of a draw by index.
        --- @param index Draw index
        --- @return x: number
        --- @return y: number
        --- @return w: number
        --- @return h: number
        getDrawCoordinates: function(self, id: integer): number, number, number, number

        --- Get the draw function and args of a pending draw by index.
        --- @param index Draw index to get.
        --- @return drawFunction: function(...: any)
        --- @return args: {any}
        getDrawFunction: function(self, id: integer): function(...: any), {any}

        --- Get modifiers of a pending draw by ID.
        --- @param index Draw index to get.
        --- @return shaders: {love.graphics.Shader}
        --- @return flags: integer
        getDrawModifiers: function(self, id: integer): {love.graphics.Shader}, integer

        --- Set the decorator for a layer.
        setLayerDecorator: function(self, layer: integer | string, decorator: LayerDecorator)

        --- Set the visibility of a layer.
        setLayerVisibility: function(self, layer: integer | string, visible: boolean)

        --- Check if a layer is visible.
        isLayerVisible: function(self, layer: integer | string): boolean

        --- Name a layer for easier reference.
        nameLayer: function(self, layer: integer, name: string)

        --- Emit an OnDraw event for entities with Emitter components that have OnDraw observers.
        --- @param archetype The archetype containing the entity
        --- @param row The row index of the entity in the archetype
        --- @param drawId The draw ID that was created
        emitOnDraw: function(self, archetype: Archetype, row: integer, drawId: integer)
    end

    --- Type alias for layer decorator function.
    type LayerDecorator = function(
        camera: Camera,
        layer: Layer,
        pipeline: Pipeline,
        drawLights: function(Camera, Layer, Pipeline),
        drawRenders: function(Camera, Layer, Pipeline)
    )

    --- A layer of the render pipeline.
    record Layer
        --- The layer number.
        layer: integer
        --- The lights to render (indices into SoA arrays).
        lights: {integer}
        --- The draws to render (indices into SoA arrays).
        draws: {integer}
        --- Whether the layer is visible (defaults to true).
        visible: boolean
        --- Optional decorator function for custom rendering behavior.
        decorator: LayerDecorator
        --- Optional name for the layer.
        name: string
    end
end

return types