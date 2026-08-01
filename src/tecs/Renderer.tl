--[=[
Coordinates rendering domains and owns frame-wide GPU work.

An application owns one renderer. The renderer owns the deferred graph,
presentation targets, capture, and staging-slot rotation. `sprites` is the 2D
domain: it owns sprite extraction, instance buffers, image residency, culling,
and the pass bodies it contributes to the graph.

This division is the 3D extension seam. A mesh domain can be prepared beside
the sprite domain and contribute its own pass bodies without either domain
branching per entity on what kind of renderer it belongs to.
]=]

local type types = require("tecs.types")
local loader <const> = require("tecs.ffi.loader")
local Buffer <const> = require("tecs.gpu.Buffer")
local Frame <const> = require("tecs.gpu.Frame")
local Texture <const> = require("tecs.gpu.Texture")
local Deferred <const> = require("tecs.gpu.Deferred")
local SpriteDomain <const> = require("tecs.internal.render.SpriteDomain")
local screenshot <const> = require("tecs.gfx.screenshot")

local type InstanceProducer = SpriteDomain.InstanceProducer
local type ClipRegion = SpriteDomain.ClipRegion
local type ComputeStage = SpriteDomain.ComputeStage

local DEFAULT_AMBIENT <const>: {number} = {1.0, 1.0, 1.0}

local record RendererOptions
    --- Caller-writable. Sets ambient red, green, and blue and defaults to white.
    ambient: {number}
    --- Caller-writable. Enables and configures 2D shadows. Nil disables them.
    shadows: Deferred.ShadowOptions
    --- Caller-writable. Configures the 2D sprite rendering domain.
    sprites: SpriteDomain.Options
end

local record Renderer
    type Options = RendererOptions
    type SpriteDomain = SpriteDomain
    type SpriteInstanceProducer = InstanceProducer
    type SpriteClipRegion = ClipRegion
    type SpriteComputeStage = ComputeStage

    --- Read-only. Provides the concrete 2D rendering lane.
    sprites: SpriteDomain
    --- Read-only. Provides the renderer-owned deferred graph and targets.
    deferred: Deferred

    --- Engine-owned. Selects the staging slot used by the next extraction.
    _slot: integer
    --- Engine-owned. Prevents resources from being released twice.
    _destroyed: boolean
end

local RendererMT <const>: metatable<Renderer> = {__index = Renderer}

--- Builds a renderer and its 2D sprite domain.
--- @param device The engine supplies the GPU device that owns renderer resources.
--- @param swapchainFormat The engine supplies the presentation texture format.
--- @param options The caller supplies fixed creation options or nil for defaults.
--- @return Returns a caller-owned renderer that `destroy` releases.
function Renderer.newRenderer(device: loader.CPtr, swapchainFormat: integer, options: RendererOptions): Renderer
    options = options or {}
    local self = setmetatable({} as Renderer, RendererMT)
    self._slot = 0
    self._destroyed = false

    local ambient <const> = options.ambient or {DEFAULT_AMBIENT[1], DEFAULT_AMBIENT[2], DEFAULT_AMBIENT[3]}
    local sprites: SpriteDomain = nil
    local deferred = Deferred.create(
        device,
        swapchainFormat,
        {
            ambient = ambient,
            shadows = options.shadows,
            shadowActive = function(): boolean return sprites:_castsThisFrame() end,
            occluders = function(context: Deferred.PassContext) sprites:_recordOccluders(context) end,
            dropShadows = function(context: Deferred.PassContext) sprites:_recordDropShadows(context) end,
            geometry = function(context: Deferred.PassContext) sprites:_recordGeometry(context) end,
            forward = function(context: Deferred.PassContext) sprites:_recordForward(context) end,
        }
    )
    self.deferred = deferred
    sprites = SpriteDomain._create(device, deferred, options.sprites or {})
    self.sprites = sprites
    sprites:_setStaging(self._slot)
    return self
end

--- Registers every rendering domain on a world.
--- @param world The caller supplies the world this renderer reads.
function Renderer:install(world: types.World)
    self.sprites:_install(world)
end

--- Rebuilds every domain pipeline from current shader sources.
function Renderer:rebuildPipelines()
    self.sprites:_rebuildPipelines()
end

--- Returns the world units that collapse onto one depth value.
--- @return Returns zero when the depth format preserves the full layer sort.
function Renderer:depthSortCollapse(): number
    return Texture.depthSortCollapse(self.deferred.graph.depthFormat)
end

--- Returns the GPU device shared by all domains.
--- @return Returns the engine-owned device.
function Renderer:device(): loader.CPtr
    return self.sprites:_device()
end

--- Returns the seconds consumed by the last domain extraction.
--- @return Returns elapsed seconds, or zero while measurement is inactive.
function Renderer:extractSeconds(): number
    return self.sprites:_extractSeconds()
end

--- Prepares every domain and executes the renderer-owned frame graph.
--- @param frame The engine supplies an open frame that it submits afterwards.
function Renderer:render(frame: Frame)
    local sprites <const> = self.sprites
    sprites:_center(frame)

    local slot = (self._slot + 1) % Buffer.slotCount
    self._slot = slot
    sprites:_setStaging(slot)

    sprites:_prepare(frame)
    self.deferred:render(frame)
end

--- Returns the composited image from the last frame.
--- @return Returns the renderer-owned scene target.
function Renderer:captureTexture(): Texture
    return self.deferred.graph:texture("scene")
end

--- Encodes the composited image from the last frame as PNG bytes.
--- @return Returns PNG bytes, or nil when readback or encoding fails.
--- @return Returns the failure reason when the first return is nil.
function Renderer:screenshot(): string, string
    return screenshot.encode(self:captureTexture())
end

--- Writes the composited image from the last frame as a PNG.
--- @param path The caller supplies the destination path.
--- @return Returns whether capture, encoding, and writing succeeded.
--- @return Returns the failure reason when the first return is false.
function Renderer:saveScreenshot(path: string): boolean, string
    if path == nil or path == "" then
        error("tecs: a screenshot path is required", 2)
    end
    return screenshot.save(self:captureTexture(), path)
end

--- Releases the domains before the graph they record into.
function Renderer:destroy()
    if self._destroyed then
        return
    end
    self._destroyed = true
    self.sprites:_destroy()
    self.deferred:destroy()
end

return Renderer
