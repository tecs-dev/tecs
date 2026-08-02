--[=[
Coordinates rendering domains and owns frame-wide GPU work.

An application owns one renderer. The renderer owns the deferred graph,
presentation targets, capture, and staging-slot rotation. `sprites` is the 2D
domain and `meshes` is the 3D domain. Each owns its own extraction, residency,
instance buffers, and backend. A domain disabled at creation is neither loaded
nor allocated.

This division is the 3D extension seam. A mesh domain can be prepared beside
the sprite domain and contribute its own pass bodies without either domain
branching per entity on what kind of renderer it belongs to.

When both domains contribute transparent work, meshes draw first and sprites
draw second. Their camera spaces have no universal cross-domain depth order,
so the fixed order makes sprites deterministic overlays while each domain
retains its own back-to-front sort.

Setting `maxViews` enables ordered [`View`](/modules/gfx/#tecs.gfx.View)
entities. The renderer extracts and uploads each enabled domain once, then
reculls, shades, and immediately composites each view through shared GPU work
buffers. Omitting `maxViews` keeps the original full-frame path and allocates no
multi-camera intermediate.
]=]

local type types = require("tecs.types")
local loader <const> = require("tecs.ffi.loader")
local Buffer <const> = require("tecs.gpu.Buffer")
local Frame <const> = require("tecs.gpu.Frame")
local Texture <const> = require("tecs.gpu.Texture")
local Deferred <const> = require("tecs.gpu.Deferred")
local screenshot <const> = require("tecs.gfx.screenshot")

local type SpriteDomain = require("tecs.internal.render.SpriteDomain")
local type MeshDomain = require("tecs.internal.render.MeshDomain")
local View <const> = require("tecs.gfx.View")
local type Query = types.Query
local type InstanceProducer = SpriteDomain.InstanceProducer
local type ClipRegion = SpriteDomain.ClipRegion
local type ComputeStage = SpriteDomain.ComputeStage

local DEFAULT_AMBIENT <const>: {number} = {1.0, 1.0, 1.0}

local record RendererOptions
    --- Caller-writable. Sets ambient red, green, and blue and defaults to white.
    ambient: {number}
    --- Caller-writable. Enables and configures 2D shadows. Nil disables them.
    shadows: Deferred.ShadowOptions
    --- Caller-writable. Configures the 2D sprite rendering domain. False
    --- disables it; nil enables it with defaults.
    sprites: SpriteDomain.Options | boolean
    --- Caller-writable. Configures and enables the 3D mesh rendering domain.
    --- Nil leaves every mesh module and allocation out of this renderer.
    meshes: MeshDomain.Options
    --- Caller-writable. Enables and configures optional bloom. Nil omits its
    --- targets, pipelines, and passes.
    bloom: Deferred.BloomOptions
    --- Caller-writable. Enables [`View`](/modules/gfx/#tecs.gfx.View) entities
    --- and sets their fixed ceiling. Omit to retain the original single
    --- full-frame camera path. Setting it allocates one forward intermediate
    --- shared by every view.
    maxViews: integer
end

local record Renderer
    type Options = RendererOptions
    type SpriteDomain = SpriteDomain
    type SpriteOptions = SpriteDomain.Options
    type SpriteInstanceProducer = InstanceProducer
    type SpriteClipRegion = ClipRegion
    type SpriteComputeStage = ComputeStage
    type MeshDomain = MeshDomain
    type MeshOptions = MeshDomain.Options
    type BloomOptions = Deferred.BloomOptions

    --- Read-only. Provides the concrete 2D rendering lane, or nil when
    --- creation disabled it.
    sprites: SpriteDomain
    --- Read-only. Provides the concrete 3D rendering lane, or nil when
    --- creation omitted mesh options.
    meshes: MeshDomain
    --- Read-only. Provides the renderer-owned deferred graph and targets.
    deferred: Deferred

    --- Engine-owned. Selects the staging slot used by the next extraction.
    _slot: integer
    --- Engine-owned. Holds the device shared by every enabled domain.
    _device: loader.CPtr
    --- Engine-owned. Prevents resources from being released twice.
    _destroyed: boolean
    _maxViews: integer
    _multiCamera: boolean
    _viewQuery: Query
    _views: {View}
    _viewEntities: {integer}
    _drawSprites: boolean
    _drawMeshes: boolean
end

local RendererMT <const>: metatable<Renderer> = {__index = Renderer}

--- Builds a renderer and its enabled rendering domains.
--- @param device The engine supplies the GPU device that owns renderer resources.
--- @param swapchainFormat The engine supplies the presentation texture format.
--- @param options The caller supplies fixed creation options or nil for defaults.
--- @return Returns a caller-owned renderer that `destroy` releases.
function Renderer.newRenderer(device: loader.CPtr, swapchainFormat: integer, options: RendererOptions): Renderer
    options = options or {}
    local self = setmetatable({} as Renderer, RendererMT)
    self._slot = 0
    self._device = device
    self._destroyed = false
    self._multiCamera = options.maxViews ~= nil
    self._maxViews = options.maxViews or 1
    if self._maxViews < 1 then
        error("tecs: Renderer maxViews must be at least 1", 2)
    end
    self._views = {}
    self._viewEntities = {}
    self._drawSprites, self._drawMeshes = true, true

    local ambient <const> = options.ambient or {DEFAULT_AMBIENT[1], DEFAULT_AMBIENT[2], DEFAULT_AMBIENT[3]}
    local meshShadow = options.meshes ~= nil and options.meshes.shadows or nil
    local meshFog = options.meshes ~= nil and options.meshes.fog or nil
    if meshShadow ~= nil and (meshShadow.scale or 1.0) <= 0.0 then
        error("tecs: mesh shadow scale must be greater than 0", 2)
    end
    local sprites: SpriteDomain = nil
    local meshes: MeshDomain = nil
    local shadowActive: function(): boolean
    local meshShadowActive: function(): boolean
    if self._multiCamera then
        shadowActive = function(): boolean return self._drawSprites and sprites ~= nil and sprites:_castsThisFrame() end
        meshShadowActive = function(): boolean
            return self._drawMeshes and meshes ~= nil and meshes:_castsThisFrame()
        end
    else
        shadowActive = function(): boolean return sprites ~= nil and sprites:_castsThisFrame() end
        meshShadowActive = function(): boolean return meshes ~= nil and meshes:_castsThisFrame() end
    end
    -- Deferred retains this options table in its graph closures. Predicates
    -- close over the domain locals before those domains exist; draw callbacks
    -- are replaced once below. A frame then calls exactly the enabled domains
    -- without probing a registry on the render path.
    local contributions = {
        ambient = ambient,
        shadows = options.shadows,
        shadowActive = shadowActive,
        occluders = function(_context: Deferred.PassContext) end,
        dropShadows = function(_context: Deferred.PassContext) end,
        meshShadowScale = meshShadow ~= nil and (meshShadow.scale or 1.0) or nil,
        meshShadowActive = meshShadowActive,
        meshShadowMap = function(_context: Deferred.PassContext) end,
        meshFog = meshFog ~= nil,
        meshPBR = options.meshes ~= nil,
        meshProbe = options.meshes ~= nil and options.meshes.probe ~= nil,
        meshLightCapacity = options.meshes ~= nil
            and options.meshes.lights ~= nil
            and (options.meshes.lights.capacity or 256) or nil,
        bloom = options.bloom,
        multiCamera = self._multiCamera,
        geometry = function(_context: Deferred.PassContext) end,
        forward = function(_context: Deferred.PassContext) end,
    }
    local deferred = Deferred.create(device, swapchainFormat, contributions)
    self.deferred = deferred
    if options.sprites ~= false then
        local SpriteDomainValue <const> = require("tecs.internal.render.SpriteDomain")
        sprites = SpriteDomainValue._create(device, deferred, options.sprites as SpriteDomain.Options or {})
        self.sprites = sprites
        sprites:_setStaging(self._slot)
    end
    if options.meshes ~= nil then
        local MeshDomainValue <const> = require("tecs.internal.render.MeshDomain")
        meshes = MeshDomainValue._create(device, deferred, options.meshes)
        self.meshes = meshes
        meshes:_setStaging(self._slot)
    end

    if sprites ~= nil then
        contributions.occluders = function(context: Deferred.PassContext) sprites:_recordOccluders(context) end
        contributions.dropShadows = function(context: Deferred.PassContext) sprites:_recordDropShadows(context) end
    end
    if meshes ~= nil and meshes.shadows then
        contributions.meshShadowMap = function(context: Deferred.PassContext) meshes:_recordShadowMap(context) end
    end
    if self._multiCamera then
        if sprites ~= nil and meshes ~= nil then
            contributions.geometry = function(context: Deferred.PassContext)
                if self._drawSprites then
                    sprites:_recordGeometry(context)
                end
                if self._drawMeshes then
                    meshes:_recordGeometry(context)
                end
            end
        elseif sprites ~= nil then
            contributions.geometry = function(context: Deferred.PassContext)
                if self._drawSprites then
                    sprites:_recordGeometry(context)
                end
            end
        elseif meshes ~= nil then
            contributions.geometry = function(context: Deferred.PassContext)
                if self._drawMeshes then
                    meshes:_recordGeometry(context)
                end
            end
        end
        if sprites ~= nil and meshes ~= nil then
            contributions.forward = function(context: Deferred.PassContext)
                -- Mesh transparency is scene content; sprites land afterwards
                -- so the peer 2D domain retains deterministic overlay semantics.
                if self._drawMeshes then
                    meshes:_recordForward(context)
                end
                if self._drawSprites then
                    sprites:_recordForward(context)
                end
            end
        elseif sprites ~= nil then
            contributions.forward = function(context: Deferred.PassContext)
                if self._drawSprites then
                    sprites:_recordForward(context)
                end
            end
        elseif meshes ~= nil then
            contributions.forward = function(context: Deferred.PassContext)
                if self._drawMeshes then
                    meshes:_recordForward(context)
                end
            end
        end
    else
        if sprites ~= nil and meshes ~= nil then
            contributions.geometry = function(context: Deferred.PassContext)
                sprites:_recordGeometry(context)
                meshes:_recordGeometry(context)
            end
            contributions.forward = function(context: Deferred.PassContext)
                -- Mesh transparency is scene content; sprites land afterwards
                -- so the peer 2D domain retains deterministic overlay semantics.
                meshes:_recordForward(context)
                sprites:_recordForward(context)
            end
        elseif sprites ~= nil then
            contributions.geometry = function(context: Deferred.PassContext) sprites:_recordGeometry(context) end
            contributions.forward = function(context: Deferred.PassContext) sprites:_recordForward(context) end
        elseif meshes ~= nil then
            contributions.geometry = function(context: Deferred.PassContext) meshes:_recordGeometry(context) end
            contributions.forward = function(context: Deferred.PassContext) meshes:_recordForward(context) end
        end
    end
    return self
end

--- Registers every rendering domain on a world.
--- @param world The caller supplies the world this renderer reads.
function Renderer:install(world: types.World)
    if self._multiCamera then
        self._viewQuery = world:newQuery({include = {View}})
    end
    if self.sprites ~= nil then
        self.sprites:_install(world)
    end
    if self.meshes ~= nil then
        self.meshes:_install(world)
    end
end

local function orderedBefore(view: View, entity: integer, other: View, otherEntity: integer): boolean
    return view.order < other.order or view.order == other.order and entity < otherEntity
end

--- Copies and orders the enabled view entities without retaining archetype columns.
local function collectViews(self: Renderer): integer, boolean
    if self._viewQuery == nil then
        return 0, false
    end
    local count = 0
    local found = false
    for archetype, length, entities in self._viewQuery:iter() do
        local column <const> = archetype:get(View)
        for row = 1, length do
            found = true
            local view <const> = column[row]
            if view.enabled then
                count = count + 1
                if count > self._maxViews then
                    error(
                        ("tecs: renderer maxViews is %d but the world has more enabled views"):format(self._maxViews), 2
                    )
                end
                local entity <const> = entities[row]
                local at = count
                while at > 1 and orderedBefore(view, entity, self._views[at - 1], self._viewEntities[at - 1]) do
                    self._views[at] = self._views[at - 1]
                    self._viewEntities[at] = self._viewEntities[at - 1]
                    at = at - 1
                end
                self._views[at] = view
                self._viewEntities[at] = entity
            end
        end
    end
    return count, found
end

--- Rebuilds every domain pipeline from current shader sources.
function Renderer:rebuildPipelines()
    if self.sprites ~= nil then
        self.sprites:_rebuildPipelines()
    end
    if self.meshes ~= nil then
        self.meshes:_rebuildPipelines(self.deferred)
    end
end

--- Returns the world units that collapse onto one depth value.
--- @return Returns zero when the depth format preserves the full layer sort.
function Renderer:depthSortCollapse(): number
    return Texture.depthSortCollapse(self.deferred.graph.depthFormat)
end

--- Returns the GPU device shared by all domains.
--- @return Returns the engine-owned device.
function Renderer:device(): loader.CPtr
    return self._device
end

--- Returns the seconds consumed by the last domain extraction.
--- @return Returns elapsed seconds, or zero while measurement is inactive.
function Renderer:extractSeconds(): number
    local seconds = 0.0
    if self.sprites ~= nil then
        seconds = seconds + self.sprites:_extractSeconds()
    end
    if self.meshes ~= nil then
        seconds = seconds + self.meshes:_extractSeconds()
    end
    return seconds
end

--- Prepares every domain and executes the renderer-owned frame graph.
--- @param frame The engine supplies an open frame that it submits afterwards.
function Renderer:render(frame: Frame)
    local sprites <const> = self.sprites
    if sprites ~= nil then
        sprites:_center(frame)
    end

    local slot = (self._slot + 1) % Buffer.slotCount
    self._slot = slot
    if sprites ~= nil then
        sprites:_setStaging(slot)
    end
    local meshes <const> = self.meshes
    if meshes ~= nil then
        meshes:_setStaging(slot)
    end

    if not self._multiCamera then
        self._drawSprites, self._drawMeshes = sprites ~= nil, meshes ~= nil
        if sprites ~= nil then
            sprites:_prepare(frame)
        end
        if meshes ~= nil then
            meshes:_prepare(frame)
        end
        self.deferred:render(frame)
        return
    end

    local viewCount, foundViews = collectViews(self)
    if not foundViews then
        self._drawSprites, self._drawMeshes = sprites ~= nil, meshes ~= nil
        if sprites ~= nil then
            sprites:_prepare(frame)
        end
        if meshes ~= nil then
            meshes:_prepare(frame)
        end
        self.deferred:render(frame)
        return
    end

    -- All-disabled views still produce a defined cleared frame and keep each
    -- domain's resident buffers current. The synthesized cameras are used only
    -- to run preparation; both contribution gates stay closed.
    if viewCount == 0 then
        self._drawSprites, self._drawMeshes = false, false
        if sprites ~= nil then
            sprites:_prepare(frame, sprites.camera, frame.width, frame.height, true)
        end
        if meshes ~= nil then
            meshes:_prepare(frame, meshes.camera, frame.width, frame.height, true)
        end
        self.deferred:render(frame, 0, 0, frame.width, frame.height, true, true)
        return
    end

    for index = 1, viewCount do
        local view <const> = self._views[index]
        local x <const> = math.floor(view.x * frame.width)
        local y <const> = math.floor(view.y * frame.height)
        local right <const> = math.floor((view.x + view.width) * frame.width)
        local bottom <const> = math.floor((view.y + view.height) * frame.height)
        local width <const> = math.max(1, right - x)
        local height <const> = math.max(1, bottom - y)
        self._drawSprites = sprites ~= nil and view.camera2D ~= nil
        self._drawMeshes = meshes ~= nil and view.camera3D ~= nil

        if sprites ~= nil and (index == 1 or self._drawSprites) then
            sprites:_prepare(frame, view.camera2D or sprites.camera, width, height, index == 1)
        end
        if meshes ~= nil and (index == 1 or self._drawMeshes) then
            meshes:_prepare(frame, view.camera3D or meshes.camera, width, height, index == 1)
        end
        self.deferred:render(frame, x, y, width, height, index == 1, index == viewCount)
    end
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
    if self.sprites ~= nil then
        self.sprites:_destroy()
    end
    if self.meshes ~= nil then
        self.meshes:_destroy()
    end
    self.deferred:destroy()
end

return Renderer
