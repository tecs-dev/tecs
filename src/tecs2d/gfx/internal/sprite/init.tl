--- Sprite component with integrated animation support
---
--- The Sprite component combines texture rendering with animation capabilities.
--- Every Sprite has a SpriteSheet, even for simple single-frame textures.

local tecs <const> = require("tecs")
local types <const> = require("tecs2d.gfx.types")
local ColorComponent = require("tecs2d.gfx.internal.Color")
local timingbuffer <const> = require("tecs2d.gfx.internal.gpu.timingbuffer")
local sprite_sheet <const> = require("tecs2d.gfx.internal.sprite.sheet")
local sheet <const> = require("tecs2d.gfx.sheet")
local sprite_events <const> = require("tecs2d.gfx.internal.sprite.events")
local sprite_collision <const> = require("tecs2d.gfx.internal.sprite.collision")
local sprite_instance <const> = require("tecs2d.gfx.internal.sprite.instance")
local pipelinekey <const> = require("tecs2d.gfx.internal.pipelinekey")
local bucketsync <const> = require("tecs2d.gfx.internal.sprite.bucketsync")
local bucketmanager <const> = require("tecs2d.gfx.internal.sprite.bucketmanager")
local gpuTypes <const> = require("tecs2d.gfx.internal.gpu.types")
local renderplugin <const> = require("tecs2d.gfx.internal.sprite.renderplugin")
local TextureArray <const> = require("tecs2d.gfx.internal.sprite.TextureArray")
local shaderUtils <const> = require("tecs2d.gfx.internal.gpu.shaders")
local materialcompiler <const> = require("tecs2d.gfx.internal.materialcompiler")
local floor <const> = math.floor

-- Shadow-pipeline modules for the renderer-owned shadow-column path.
local shadowsetup <const> = require("tecs2d.gfx.internal.sprite.shadowsetup")
local shadowdispatch <const> = require("tecs2d.gfx.internal.sprite.shadowdispatch")
local modifierbinding <const> = require("tecs2d.gfx.internal.gpu.modifierbinding")
local ClipBoundsComponent <const> = require("tecs2d.gfx.internal.ClipBounds")
local Unlit <const> = require("tecs2d.gfx.internal.Unlit")
local PivotComponent <const> = require("tecs2d.gfx.internal.Pivot")
local MaterialComponent <const> = require("tecs2d.gfx.internal.Material")
local OccluderComponent <const> = require("tecs2d.gfx.internal.Occluder")
local DropShadowComponent <const> = require("tecs2d.gfx.internal.DropShadow")

-- Compile sprite shaders
local lg <const> = love.graphics
local SPRITE_SHADERS <const> = "tecs2d/gfx/internal/sprite/"
local spriteRenderSource <const> = shaderUtils.loadRenderShader("sprite", SPRITE_SHADERS)
local spriteRenderShader <const> = lg.newShader(spriteRenderSource)
local spriteCullShader <const> = lg.newComputeShader(shaderUtils.loadCullShader("sprite_cull", SPRITE_SHADERS))
local spriteShadowMaskShader <const> = lg.newShader(shaderUtils.loadShadowMaskShader("shadow_mask_sprite"))
local spriteDropShadowShader <const> = lg.newShader(shaderUtils.loadRenderShader("drop_shadow_sprite", SPRITE_SHADERS))
materialcompiler.registerBaseSource("sprite", spriteRenderSource)

-- Cache for GPU timing data to avoid redundant work per sprite
-- Structure: timingCache[sheetId][tagId][speed] = {offset, totalDuration, frameCount, columnCount, frameHeight}
local timingCache: {integer: {integer: {number: {integer, number, integer, integer, number}}}} = {}

-------------------------------------------------------------------------------
-- Sprite Instance Registry (from separate module to avoid circular deps)
-------------------------------------------------------------------------------

local type SpriteInstance = sprite_instance.SpriteInstance
local getInstance <const> = sprite_instance.get

-- Get the current game time from the render pipeline, falling back to wall clock.
-- This ensures CPU-rendered sprites (custom shaders) respect time scale and pause.
local function getGameTime(): number
    local world = sprite_instance.getWorld() as tecs.World
    if world then
        local rp = world.resources[pipelinekey.PIPELINE] as {string: any}
        if rp and rp.gameTime ~= nil then
            return rp.gameTime as number
        end
    end
    return love.timer.getTime()
end

local playOnceCallbacks: {integer: function(any)} = {}
local playOncePendingCount = 0

local function clearPlayOnceCallback(entityId: integer)
    if playOnceCallbacks[entityId] ~= nil then
        playOnceCallbacks[entityId] = nil
        playOncePendingCount = playOncePendingCount - 1
    end
end

local function queuePlayOnceCallback(entityId: integer, callback: function(any))
    if playOnceCallbacks[entityId] == nil then
        playOncePendingCount = playOncePendingCount + 1
    end
    playOnceCallbacks[entityId] = callback
end

local record sprite
    --- Re-export SpriteSheet
    SpriteSheet: sprite_sheet.SpriteSheet

    --- Re-export SpriteCollision component
    SpriteCollision: sprite_collision.SpriteCollision
    --- Re-export events
    ChangeTag: sprite_events.ChangeTag

    --- SpriteInstance type (exported for external access)
    Instance: SpriteInstance

    --- DirectSprite marker component - forces direct texture binding (slow path).
    --- Use for sprites with textures larger than the texture array slice size (2048x2048),
    --- or when explicit texture binding is needed for other reasons.
    --- Currently callers must add this component manually; oversized textures
    --- are only flagged with a warning by the bucket manager, not auto-routed.
    record DirectSprite is tecs.Component
    end

    --- Texture bucket marker components - group sprites by texture array size tier.
    --- layerIndex is the 0-based layer within the texture array (for GLSL sampling).
    --- arrayIndex is implicit via the TextureArray(N) tag component.
    record TinyTextureBucket is tecs.Component
        layerIndex: integer  -- 0-based layer index for GLSL texture sampling
        generation: integer  -- Generation counter for staleness detection
    end

    record SmallTextureBucket is tecs.Component
        layerIndex: integer
        generation: integer
    end

    record MediumTextureBucket is tecs.Component
        layerIndex: integer
        generation: integer
    end

    record LargeTextureBucket is tecs.Component
        layerIndex: integer
        generation: integer
    end

    record XLTextureBucket is tecs.Component
        layerIndex: integer
        generation: integer
    end

    record XXLTextureBucket is tecs.Component
        layerIndex: integer
        generation: integer
    end

    --- Sprite component - holds spriteId and per-entity animation state (FFI storage)
    record Sprite is tecs.Component, types.Rect
        --- ID into the instance registry
        spriteId: integer

        --- Internal: Entity ID (set by the SpriteLifecycle query's onEntitiesAdded)
        _entity: integer

        --- Per-entity animation start time
        animStartTime: number

        --- Per-entity pause state: -1 = playing, >= 0 = paused at frame
        pausedFrame: integer

        --- Internal: deferred pause target frame (-1 = none, >= 0 = pause when reached)
        _pauseAtFrame: integer

        --- Ref-counted pause depth for tag-based pause/resume.
        pauseDepth: integer

        --- Mark sprite metadata as dirty, triggering GPU re-sync.
        --- Call this after changing Color, ClipBounds, or pivot values.
        markDirty: function(self)

        --- Set the animation tag
        --- @param tag The new animation tag
        setTag: function(self, tag: string)

        --- Play a tag once, then invoke the callback when the last frame is reached.
        playOnce: function(self, tag: string, onComplete?: function(any))

        --- Pause the animation at current frame.
        --- Optional time parameter for synchronized batch pausing.
        pause: function(self, time?: number)

        --- Resume the animation from paused frame
        resume: function(self)

        --- Set the animation to the last frame and pause
        pauseAtEnd: function(self)

        --- Set the animation to the first frame and pause
        pauseAtStart: function(self)

        --- Jump to a specific frame (0-based index within current tag)
        --- @param frame The frame index to jump to
        gotoFrame: function(self, frame: integer)

        --- Get the current frame index (0-based within current tag)
        --- @return The current frame being displayed
        getFrame: function(self): integer

        --- Get the absolute frame number (1-based, across entire spriteSheet)
        --- @return The absolute frame number
        getAbsoluteFrame: function(self): integer

        --- Get the current tag
        --- @return The current tag
        getTag: function(self): string

        --- Get the center point of the current frame
        --- @return centerX, centerY
        getCenter: function(self): number, number

        --- Get the dimensions of the sprite
        --- @return width, height
        getDimensions: function(self): number, number

        --- Get the proper origin point based on pivot configuration
        --- @return pivotX, pivotY
        getPivot: function(self): number, number

        --- Get the instance data for this sprite
        --- @return The SpriteInstance
        getInstance: function(self): SpriteInstance

        --- Creates a new Sprite with the given spriteId and startTime.
        --- Most users should use fromSheet, fromAseprite, or fromTexture instead.
        metamethod __call: function(self, spriteId: integer, startTime?: number): Sprite

        --- Create a Sprite from a loaded SpriteSheet
        --- @param spriteSheet The sprite spriteSheet
        --- @param tag Optional animation tag (defaults to "" = all frames)
        --- @param options Optional configuration (centered, pivotSlice, speed, startTime)
        --- @return A new Sprite instance
        fromSheet: function(
            spriteSheet: sheet.SpriteSheet,
            tag?: string,
            options?: {string: any}
        ): Sprite

        --- Create a Sprite from an Aseprite file path
        --- @param path Path to the image file (JSON data expected alongside with .json extension)
        --- @param tag Optional animation tag
        --- @param options Optional configuration
        --- @return A new Sprite instance
        fromAseprite: function(path: string, tag?: string, options?: {string: any}): Sprite

        --- Create a simple Sprite from a texture (single-frame)
        --- @param texture The texture to use
        --- @param options Optional configuration
        --- @return A new Sprite instance
        fromTexture: function(texture: love.graphics.Texture, options?: {string: any}): Sprite
    end

    --- Plugin to add sprite rendering and collision systems to a TECS world.
    --- Returns a plugin function that should be passed to world:addPlugin().
    --- @param pipeline The render pipeline (passed to avoid circular dependency)
    plugin: function(pipeline: gpuTypes.PipelineInternal): function(world: tecs.World)

    --- RepeatedSprite component for tiling sprites across an area.
    --- Add this to an entity with a Sprite to enable tiling/repeating.
    --- The sprite will tile to fill the specified width/height.
    record RepeatedSprite is tecs.Component
        --- Repeat horizontally
        repeatX: boolean
        --- Repeat vertically
        repeatY: boolean
        --- Total width of the tiled area (in world units)
        width: number
        --- Total height of the tiled area (in world units)
        height: number

        metamethod __call: function(self, data: RepeatedSprite): RepeatedSprite
    end

    --- Renderer-internal derived metadata. Sync writes the resolved
    --- frame UV / pivot / size / animation params / packed
    --- textureSlice on dirty; the shadow cull shader reads it
    --- per-row.
    --- Auto-added when a Sprite is added to an entity; users should
    --- never construct or write to this directly.
    record SpriteData is tecs.Component
        pivotX: number
        pivotY: number
        width: number
        height: number
        uvX: number
        uvY: number
        uvW: number
        uvH: number
        animTotalDuration: number
        animFrameCount: number
        animFrameWidth: number
        animColumnCount: number
        animFrameHeight: number
        animTimingOffset: number
        textureSlice: number    -- packed: layerIndex | (generation << packBits)
        animDirection: number   -- 0 forward, 1 reverse, 2 pingpong
        animFirstFrame: number  -- tag's first spriteSheet frame, 0-based
        spriteId: number        -- instance id last synced; detects in-place replacement
    end
end

-- Re-exports
sprite.SpriteSheet = sprite_sheet.SpriteSheet
sprite.SpriteCollision = sprite_collision.SpriteCollision
sprite.ChangeTag = sprite_events.ChangeTag

local Sprite <const> = sprite.Sprite

local ChangeTag <const> = sprite_events.ChangeTag

-------------------------------------------------------------------------------
-- Instance helpers
-------------------------------------------------------------------------------

local function computePivot(inst: SpriteInstance, sheetVal: sprite_sheet.SpriteSheet): number, number
    -- For sliceId, we'd need per-frame logic, so just use center as default
    -- The full per-frame logic is in Sprite:getPivot()
    if inst.sliceId > 0 then
        local slice = sheetVal:getSliceById(inst.sliceId)
        if slice and slice.keys and #slice.keys > 0 then
            local key = slice.keys[1]  -- Use first frame's pivot
            if key.hasPivot then
                return key.pivotX, key.pivotY
            elseif key.hasCenter then
                return key.centerX, key.centerY
            end
        end
    end
    -- Default: centered returns (0.5, 0.5), otherwise (0, 0)
    if inst.centered then
        return 0.5, 0.5
    end
    return 0, 0
end

-------------------------------------------------------------------------------
-- Helper: Populate instance computed fields from config
-------------------------------------------------------------------------------

local function populateInstanceFromConfig(inst: SpriteInstance, sheetVal: sprite_sheet.SpriteSheet)
    local tagId = inst.tagId
    local speed = inst.speed

    -- Get frame tag (0 = default)
    local frameTag = sheetVal:getFrameTagById(tagId)
    local firstFrame = frameTag.from

    -- Get UV coordinates and dimensions
    inst.uvX, inst.uvY, inst.uvW, inst.uvH = sheetVal:getFrameUV(firstFrame)
    inst.width, inst.height = sheetVal:getSpriteSize()

    -- Default animation values
    inst.animTotalDuration = 1
    inst.animTimingOffset = 0
    inst.animFrameCount = 1
    inst.animFrameWidth = inst.uvW
    inst.animColumnCount = 0
    inst.animFrameHeight = inst.uvH
    inst.animDirection = 0
    inst.animFirstFrame = 0

    if frameTag then
        local sheetId = inst.sheetId
        local direction = frameTag.direction or 0
        inst.animDirection = direction
        inst.animFirstFrame = frameTag.from - 1  -- 0-based for the shaders

        -- Check timing cache: timingCache[sheetId][tagId][speed]
        local timingSheetCache = timingCache[sheetId]
        local timingTagCache = timingSheetCache and timingSheetCache[tagId]
        local timingCached = timingTagCache and timingTagCache[speed]

        if timingCached then
            -- Timing cache hit
            inst.animTotalDuration = timingCached[2]
            inst.animTimingOffset = timingCached[1]
            inst.animFrameCount = timingCached[3]
            inst.animColumnCount = timingCached[4]
            inst.animFrameHeight = timingCached[5]
        else
            -- Compute grid layout info for GPU animation
            local sheetW, sheetH = sheetVal:getSheetSize()
            local spriteW, spriteH = sheetVal:getSpriteSize()
            local columnCount = floor(sheetW / spriteW)
            local frameHeight = spriteH / sheetH

            -- Collect per-frame durations in PLAY order. The timing
            -- buffer stores the timeline the GPU steps through; the cull
            -- shader maps timeline indices back to display frames via
            -- animDirection. Reverse plays to..from; pingpong plays
            -- from..to then back down to from+1 (2n-2 timeline entries).
            local frameDurations: {number} = {}
            local function pushDuration(frame: integer)
                frameDurations[#frameDurations + 1] = sheetVal:getFrame(frame).duration / speed
            end
            if direction == 1 then
                for i = frameTag.to, frameTag.from, -1 do
                    pushDuration(i)
                end
            elseif direction == 2 then
                for i = frameTag.from, frameTag.to do
                    pushDuration(i)
                end
                for i = frameTag.to - 1, frameTag.from + 1, -1 do
                    pushDuration(i)
                end
            else
                for i = frameTag.from, frameTag.to do
                    pushDuration(i)
                end
            end
            local frameCount = #frameDurations

            -- Register with timing buffer
            local sheetPath = sheetVal:getPath() or "unknown"
            local tagName = sheetVal:getTagName(tagId)
            local timingOffsetVal, totalDuration = timingbuffer.global:registerTag(
                sheetPath, tagName, frameDurations
            )

            -- Build timing cache structure
            if not timingSheetCache then
                timingSheetCache = {}
                timingCache[sheetId] = timingSheetCache
            end
            if not timingTagCache then
                timingTagCache = {}
                timingSheetCache[tagId] = timingTagCache
            end
            timingTagCache[speed] = {timingOffsetVal, totalDuration, frameCount, columnCount, frameHeight}

            inst.animTotalDuration = totalDuration
            inst.animTimingOffset = timingOffsetVal
            inst.animFrameCount = frameCount
            inst.animColumnCount = columnCount
            inst.animFrameHeight = frameHeight
        end
    end

    -- Compute pivot
    inst.pivotX, inst.pivotY = computePivot(inst, sheetVal)
end

-------------------------------------------------------------------------------
-- Helper: Create a new sprite instance
-------------------------------------------------------------------------------

local function createInstance(
    sheetVal: sprite_sheet.SpriteSheet,
    tagName: string,
    speed: number,
    centered: boolean,
    sliceName: string
): integer
    -- Validate tag if specified
    if tagName ~= "" and not sheetVal:hasFrameTag(tagName) then
        error("Animation tag '" .. tagName .. "' not found in spriteSheet")
    end

    -- Check cache for existing instance
    local sheetId = sheetVal:getId()
    local tagId = sheetVal:getTagId(tagName)
    local sliceId = sheetVal:getSliceId(sliceName)

    local existingId = sprite_instance.findCached(sheetId, tagId, speed, centered, sliceId)
    if existingId then
        local existing = sprite_instance.get(existingId)
        if existing then
            existing.refCount = existing.refCount + 1
            return existingId
        end
    end

    -- Allocate sprite ID and create instance
    local spriteId = sprite_instance.allocId()
    local inst: SpriteInstance = {
        sheetId = sheetId,
        tagId = tagId,
        speed = speed,
        centered = centered,
        sliceId = sliceId,
        pivotX = 0,
        pivotY = 0,
        width = 0,
        height = 0,
        uvX = 0,
        uvY = 0,
        uvW = 0,
        uvH = 0,
        animTotalDuration = 1,
        animTimingOffset = 0,
        animFrameCount = 1,
        animFrameWidth = 0,
        animColumnCount = 0,
        animFrameHeight = 0,
        cachedPivotX = 0,
        cachedPivotY = 0,
        cachedFrame = -1,
        refCount = 1,
    }

    populateInstanceFromConfig(inst, sheetVal)
    sprite_instance.set(spriteId, inst)
    sprite_instance.cache(sheetId, tagId, speed, centered, sliceId, spriteId)

    return spriteId
end

-------------------------------------------------------------------------------
-- Instance lifecycle
-------------------------------------------------------------------------------

local function releaseInstance(spriteId: integer)
    local inst = sprite_instance.get(spriteId)
    if inst then
        inst.refCount = inst.refCount - 1
        if inst.refCount <= 0 then
            sprite_instance.uncache(inst.sheetId, inst.tagId, inst.speed, inst.centered, inst.sliceId)
            sprite_instance.remove(spriteId)
            sprite_instance.freeId(spriteId)
        end
    end
end

-------------------------------------------------------------------------------
-- Sprite methods
-------------------------------------------------------------------------------

function Sprite:getRect(): number, number, number, number
    local inst <const> = getInstance(self.spriteId)
    return -inst.pivotX, -inst.pivotY, inst.width, inst.height
end

function Sprite:getInstance(): SpriteInstance
    return getInstance(self.spriteId)
end

function Sprite:setTag(tag: string)
    local inst <const> = getInstance(self.spriteId)
    local sheetVal = sprite_sheet.SpriteSheet.getById(inst.sheetId)
    if not sheetVal then
        return  -- Sheet not loaded
    end

    local newTagId = sheetVal:getTagId(tag)
    if newTagId == inst.tagId then
        return
    end

    clearPlayOnceCallback(self._entity)

    local oldTag <const> = sheetVal:getTagName(inst.tagId)

    -- Release old instance and get new one with the new tag
    -- (instances are immutable, so changing tag requires a new instance)
    releaseInstance(self.spriteId)
    local newSpriteId = createInstance(
        sheetVal,
        tag,
        inst.speed,
        inst.centered,
        sheetVal:getSliceName(inst.sliceId)
    )
    self.spriteId = newSpriteId

    -- Reset per-entity animation state
    local world = sprite_instance.getWorld() as tecs.World
    local renderPipeline = world.resources[pipelinekey.PIPELINE] as {string: any}
    local currentTime = renderPipeline and renderPipeline.gameTime as number or 0
    self.animStartTime = currentTime
    self.pausedFrame = -1  -- Not paused
    self._pauseAtFrame = -1
    self.pauseDepth = 0

    -- Emit change tag event
    world:emit(self._entity, ChangeTag, self._entity, oldTag, tag, self)
    world:markComponentDirty(self._entity, Sprite as tecs.Component)
end

function Sprite:playOnce(tag: string, onComplete?: function(any))
    local world = sprite_instance.getWorld() as tecs.World
    local inst <const> = getInstance(self.spriteId)
    local sameTag = inst and tag == self:getTag()

    clearPlayOnceCallback(self._entity)

    if sameTag then
        local renderPipeline = world.resources[pipelinekey.PIPELINE] as {string: any}
        local currentTime = renderPipeline and renderPipeline.gameTime as number or 0
        self.animStartTime = currentTime
        self.pausedFrame = -1
        self._pauseAtFrame = -1
        self.pauseDepth = 0
        world:markComponentDirty(self._entity, Sprite as tecs.Component)
    else
        self:setTag(tag)
    end

    if onComplete then
        queuePlayOnceCallback(self._entity, onComplete)
    end
    self:pauseAtEnd()
end

function Sprite:pause(time?: number)
    self.pauseDepth = self.pauseDepth + 1
    if self.pausedFrame >= 0 then
        return  -- Already frame-paused (but pauseDepth incremented)
    end
    local inst <const> = getInstance(self.spriteId)
    if not inst then
        return  -- Zero-initialized sprite (batchSpawn skips FFI defaults)
    end
    local currentTime = time or getGameTime()
    local localTime = (currentTime - self.animStartTime) % inst.animTotalDuration
    local frame = timingbuffer.global:getFrameAtTime(
        inst.animTimingOffset,
        inst.animFrameCount,
        localTime
    )
    self.pausedFrame = frame
    local world = sprite_instance.getWorld() as tecs.World
    world:markComponentDirty(self._entity, Sprite as tecs.Component)
end

function Sprite:resume()
    if self.pauseDepth > 0 then
        self.pauseDepth = self.pauseDepth - 1
    end
    if self.pauseDepth > 0 then
        return  -- Still held by another pause source
    end
    if self.pausedFrame < 0 then
        return  -- Not paused
    end

    local inst <const> = getInstance(self.spriteId)
    if not inst then
        return  -- Instance already released (entity being despawned)
    end

    local frameTime = timingbuffer.global:getFrameStartTime(
        inst.animTimingOffset,
        self.pausedFrame
    )
    self.animStartTime = getGameTime() - frameTime
    self.pausedFrame = -1
    local world = sprite_instance.getWorld() as tecs.World
    world:markComponentDirty(self._entity, Sprite as tecs.Component)
end

function Sprite:pauseAtEnd()
    local inst <const> = getInstance(self.spriteId)
    if not inst then
        return  -- Zero-initialized sprite (batchSpawn skips FFI defaults)
    end
    local lastFrame = inst.animFrameCount - 1
    if self.pausedFrame >= 0 then
        -- Already paused, just jump to end
        self.pausedFrame = lastFrame
    else
        -- The cull shader reads pauseAtFrame and clamps the visual;
        -- Sprite:getFrame lazily converts it into a hard pause on the CPU.
        self._pauseAtFrame = lastFrame
    end
    local world = sprite_instance.getWorld() as tecs.World
    world:markComponentDirty(self._entity, Sprite as tecs.Component)
end

function Sprite:pauseAtStart()
    self:gotoFrame(0)
    self:pause()
end

function Sprite:gotoFrame(frame: integer)
    local inst <const> = getInstance(self.spriteId)
    if not inst then
        return  -- Zero-initialized sprite (batchSpawn skips FFI defaults)
    end
    local maxFrame = inst.animFrameCount - 1
    if frame < 0 then frame = 0 end
    if frame > maxFrame then frame = maxFrame end

    local frameTime = timingbuffer.global:getFrameStartTime(inst.animTimingOffset, frame)

    if self.pausedFrame >= 0 then
        self.pausedFrame = frame
    else
        self.animStartTime = getGameTime() - frameTime
    end
    local world = sprite_instance.getWorld() as tecs.World
    world:markComponentDirty(self._entity, Sprite as tecs.Component)
    inst.cachedFrame = -1
end

function Sprite:getFrame(): integer
    if self.pausedFrame >= 0 then
        return self.pausedFrame
    end
    local inst <const> = getInstance(self.spriteId)
    local elapsed = getGameTime() - self.animStartTime
    local localTime: number
    if self._pauseAtFrame >= 0 then
        -- Don't loop past the target frame; clamp to one cycle
        localTime = math.min(elapsed, inst.animTotalDuration - 0.0001)
    else
        localTime = elapsed % inst.animTotalDuration
    end
    local frame = timingbuffer.global:getFrameAtTime(
        inst.animTimingOffset,
        inst.animFrameCount,
        localTime
    )

    -- Lazy deferred pause: GPU handles visual clamping, CPU catches up here
    if self._pauseAtFrame >= 0 and frame >= self._pauseAtFrame then
        self.pausedFrame = self._pauseAtFrame
        self._pauseAtFrame = -1
        local world = sprite_instance.getWorld() as tecs.World
        world:markComponentDirty(self._entity, Sprite as tecs.Component)
        local onComplete = playOnceCallbacks[self._entity]
        if onComplete then
            clearPlayOnceCallback(self._entity)
            onComplete(self)
        end
        return self.pausedFrame
    end

    return frame
end

function Sprite:getAbsoluteFrame(): integer
    local frameIndex = self:getFrame()
    local inst <const> = getInstance(self.spriteId)
    local sheetVal = sprite_sheet.SpriteSheet.getById(inst.sheetId)
    if sheetVal then
        local frameTag = sheetVal:getFrameTagById(inst.tagId)
        if frameTag then
            return frameTag.from + frameIndex
        end
    end
    return frameIndex + 1
end

function Sprite:getTag(): string
    local inst <const> = getInstance(self.spriteId)
    local sheetVal = sprite_sheet.SpriteSheet.getById(inst.sheetId)
    if sheetVal then
        return sheetVal:getTagName(inst.tagId)
    end
    return ""
end

function Sprite:getCenter(): number, number
    -- Return normalized pivot (0.5, 0.5) for center
    -- GPU shader expects 0-1 range, not pixel coordinates
    return 0.5, 0.5
end

function Sprite:getDimensions(): number, number
    local inst <const> = getInstance(self.spriteId)
    return inst.width, inst.height
end

function Sprite:getPivot(): number, number
    local inst <const> = getInstance(self.spriteId)
    local currentFrame <const> = self:getAbsoluteFrame()
    if inst.cachedFrame == currentFrame then
        return inst.cachedPivotX, inst.cachedPivotY
    end

    local pivotX: number = 0
    local pivotY: number = 0

    local sheetVal = sprite_sheet.SpriteSheet.getById(inst.sheetId)
    if sheetVal then
        if inst.sliceId > 0 then
            local slice = sheetVal:getSliceById(inst.sliceId)
            if slice then
                local keys = slice.keys
                if keys then
                    for i = 1, #keys do
                        local key = keys[i]
                        if key.frame == currentFrame then
                            if key.hasPivot then
                                pivotX, pivotY = key.pivotX, key.pivotY
                            elseif key.hasCenter then
                                pivotX, pivotY = key.centerX, key.centerY
                            end
                            break
                        end
                    end
                end
            end

            if pivotX == 0 and pivotY == 0 and inst.centered then
                pivotX, pivotY = self:getCenter()
            end
        elseif inst.centered then
            pivotX, pivotY = self:getCenter()
        end
    end

    inst.cachedPivotX = pivotX
    inst.cachedPivotY = pivotY
    inst.cachedFrame = currentFrame

    return pivotX, pivotY
end

function Sprite:markDirty()
    local world = sprite_instance.getWorld() as tecs.World
    world:markComponentDirty(self._entity, Sprite as tecs.Component)
end

-------------------------------------------------------------------------------
-- Component registration
-------------------------------------------------------------------------------

-- Metatable for Sprite FFI instances (provides methods)
local SpriteMT <const>: {any:any} = {__index = Sprite}

-- Sheet cache shared by deserialize: `SpriteSheet.fromFile` doesn't cache
-- internally, so without this a snapshot with N sprites all from the same
-- spriteSheet would parse that spriteSheet N times on load.
local sheetCacheByPath: {string: sprite_sheet.SpriteSheet} = {}
local resolvedSpritePathCache: {string: any} = {}

local function resolveDurableSpritePath(path: string): string
    local cached = resolvedSpritePathCache[path]
    if cached ~= nil then
        return cached ~= false and cached as string or nil
    end

    local fs = love.filesystem as {string: function}
    local fsInfo = fs.getInfo as function(string): any
    if not fsInfo then
        resolvedSpritePathCache[path] = path
        return path
    end
    if fsInfo(path) ~= nil then
        resolvedSpritePathCache[path] = path
        return path
    end

    resolvedSpritePathCache[path] = false
    return nil
end

-- Bind early so Sprite can declare `requires = {SpriteData}`. SpriteData's
-- newFFIComponent (below) populates the container fields; the requires
-- closure is built lazily on first spawn so registration order doesn't
-- matter beyond the table reference being valid here.
local SpriteData <const> = sprite.SpriteData

tecs.newFFIComponent({
    name = "Sprite",
    container = Sprite,
    metatable = SpriteMT,
    fields = {
        {"spriteId", "int32_t"},
        {"_entity", "int32_t"},
        {"animStartTime", "float"},
        {"pausedFrame", "int32_t"},
        {"_pauseAtFrame", "int32_t"},
        {"pauseDepth", "int32_t"}
    },
    -- SpriteData lands in the initial archetype with Sprite, so the
    -- lifecycle observer skips one `world:set` per entity at spawn.
    -- SpriteData is FFI-zero-init by default; sync's dirty path
    -- populates real values (frame UV / pivot / textureSlice etc).
    requires = { SpriteData },

    init = function(instance: sprite.Sprite, spriteId: integer, startTime: number)
        assert(spriteId, "Sprite requires a spriteId")
        instance.spriteId = spriteId
        instance._entity = 0
        instance.animStartTime = startTime or 0
        instance.pausedFrame = -1
        instance._pauseAtFrame = -1
        instance.pauseDepth = 0
    end,

    -- Custom serde: spriteId is a handle into a process-local registry
    -- that doesn't survive clear-all. Save the *durable* descriptor of the
    -- sprite (spriteSheet path + tag + config) so load can re-resolve through
    -- the normal creation path.
    serialize = function(instance: sprite.Sprite): {string: any}
        local inst = sprite_instance.get(instance.spriteId)
        if not inst then return nil end
        local spriteSheet = sprite_sheet.SpriteSheet.getById(inst.sheetId)
        if not spriteSheet then return nil end
        local path = spriteSheet:getPath()
        if path == "" then
            -- Sprite was built from an in-memory texture with no path;
            -- nothing durable to serialize. Skip rather than save a stale
            -- spriteId that won't resolve on load.
            return nil
        end
        -- Some callers (e.g. tiled animated-tile sheets) use the path slot
        -- as a cache key like "1_2" rather than a real file path. Probe
        -- love.filesystem to distinguish a durable file reference from a
        -- synthetic cache key; skip the synthetic case so the load path
        -- doesn't try to reopen a non-file. The entity survives the
        -- round-trip without this Sprite component; systems that own the
        -- entity (e.g. the tiled plugin) can re-spawn the visual state
        -- from their own durable source on load.
        local resolvedPath = resolveDurableSpritePath(path)
        if resolvedPath == nil then
            return nil
        end
        return {
            path          = resolvedPath,
            tag           = spriteSheet:getTagName(inst.tagId),
            speed         = inst.speed,
            centered      = inst.centered,
            pivotSlice    = spriteSheet:getSliceName(inst.sliceId) or "",
            animStartTime = instance.animStartTime,
            pausedFrame   = instance.pausedFrame,
            _pauseAtFrame = instance._pauseAtFrame,
            pauseDepth    = instance.pauseDepth,
        }
    end,

    deserialize = function(_world: tecs.World, data: {string: any}): sprite.Sprite
        -- Serialize returns nil for sprites built from synthetic-path
        -- sheets (e.g. tiled animated tile sheets keyed by "tileset_tile").
        -- Skip the whole reconstruct in that case and return nil so the
        -- entity survives without a Sprite. Upstream systems (e.g. the
        -- tiled plugin) can re-spawn the visual from their own source.
        if not data then return nil end
        local path = data.path as string
        path = resolveDurableSpritePath(path) or path
        local spriteSheet = sheetCacheByPath[path]
        if not spriteSheet then
            -- Aseprite sheets need an adjacent .json; plain textures don't.
            -- Probe for the JSON alongside the path to pick the right loader.
            local jsonPath = path:gsub("%.[^.]+$", "") .. ".json"
            local fsInfo = (love.filesystem as {string: function}).getInfo as function(string): any
            if fsInfo and fsInfo(jsonPath) ~= nil then
                spriteSheet = sprite_sheet.SpriteSheet.fromFile(path)
            else
                spriteSheet = sprite_sheet.SpriteSheet.fromTextureFile(path)
            end
            sheetCacheByPath[path] = spriteSheet
        end
        local inst = Sprite.fromSheet(spriteSheet as sheet.SpriteSheet, data.tag as string, {
            speed      = data.speed,
            centered   = data.centered,
            pivotSlice = data.pivotSlice,
            startTime  = data.animStartTime,
        })
        inst.pausedFrame   = (data.pausedFrame   as integer) or -1
        inst._pauseAtFrame = (data._pauseAtFrame as integer) or -1
        inst.pauseDepth    = (data.pauseDepth    as integer) or 0
        return inst
    end,

    -- Sprite setup (bucket assignment + GPU slot allocation) and
    -- teardown (instance ref release) are handled by query observers
    -- registered in `sprite.plugin` -- see the `sprite.SpriteLifecycle`
    -- block below.
})

-- Per-entity lifecycle handler for Sprite added to an entity.
-- Assigns the bucket/TextureArray tag for the sprite's spriteSheet; the
-- subsequent `bucket_sync` observer allocates a GPU slot.
local function onSpriteAdded(world: tecs.World, entityId: integer, self: sprite.Sprite)
    self._entity = entityId

    local inst = getInstance(self.spriteId)
    if not inst then return end

    local bucketMgr = bucketmanager.get()

    local allocation = bucketMgr:getAllocation(inst.sheetId)
    if not allocation then
        local spriteSheet = sprite_sheet.SpriteSheet.getById(inst.sheetId)
        if spriteSheet then
            allocation = bucketMgr:allocate(
                inst.sheetId,
                spriteSheet:getImage(),
                spriteSheet:getNormalImage(),
                spriteSheet:getEmissionImage(),
                spriteSheet:getORMImage()
            )
        end
    end

    if allocation then
        local tier = allocation.tier
        local layerIdx = allocation.layerIndex - 1
        local gen = allocation.generation

        local taggedArray = TextureArray(allocation.arrayIndex)
        world:set(entityId, taggedArray)

        if tier == "Tiny" then
            world:set(entityId, sprite.TinyTextureBucket.new({ layerIndex = layerIdx, generation = gen }))
        elseif tier == "Small" then
            world:set(entityId, sprite.SmallTextureBucket.new({ layerIndex = layerIdx, generation = gen }))
        elseif tier == "Medium" then
            world:set(entityId, sprite.MediumTextureBucket.new({ layerIndex = layerIdx, generation = gen }))
        elseif tier == "Large" then
            world:set(entityId, sprite.LargeTextureBucket.new({ layerIndex = layerIdx, generation = gen }))
        elseif tier == "XL" then
            world:set(entityId, sprite.XLTextureBucket.new({ layerIndex = layerIdx, generation = gen }))
        elseif tier == "XXL" then
            world:set(entityId, sprite.XXLTextureBucket.new({ layerIndex = layerIdx, generation = gen }))
        end
    end
end

-- RepeatedSprite component (FFI). `bool` ctype gives 1-byte storage that
-- LuaJIT FFI auto-coerces to/from Lua boolean on read/write, preserving
-- the user-facing `repeatX = true` API. The shadow pipeline's translate
-- upcasts to std430's 4-byte uint.
local RepeatedSprite <const> = sprite.RepeatedSprite
tecs.newFFIComponent({
    name = "RepeatedSprite",
    container = RepeatedSprite,
    fields = {
        {"repeatX", "bool"},
        {"repeatY", "bool"},
        {"width", "float"},
        {"height", "float"},
    },
    new = function(raw: {string: any}): sprite.RepeatedSprite
        local data = raw as {string: any}
        local repX = data.repeatX
        local repY = data.repeatY
        if repX == nil then repX = true end
        if repY == nil then repY = true end
        return (RepeatedSprite as function(any, any, any, any): sprite.RepeatedSprite)(
            repX, repY,
            (data.width as number) or 0,
            (data.height as number) or 0
        )
    end,
})

-- DirectSprite component registration (marker for direct texture binding)
local DirectSprite <const> = sprite.DirectSprite
tecs.newComponent({
    name = "DirectSprite",
    container = DirectSprite,
})

-- Texture bucket component registrations (FFI for performance)
local TinyTextureBucket <const> = sprite.TinyTextureBucket
local SmallTextureBucket <const> = sprite.SmallTextureBucket
local MediumTextureBucket <const> = sprite.MediumTextureBucket
local LargeTextureBucket <const> = sprite.LargeTextureBucket
local XLTextureBucket <const> = sprite.XLTextureBucket
local XXLTextureBucket <const> = sprite.XXLTextureBucket

-- FFI fields shared by all bucket components (arrayIndex now via TextureArray tag)
local BUCKET_FFI_FIELDS <const> = {
    {"layerIndex", "int16_t"},
    {"generation", "int16_t"},
}

tecs.newFFIComponent({
    name = "TinyTextureBucket",
    container = TinyTextureBucket,
    fields = BUCKET_FFI_FIELDS,
    transient = true,
})
tecs.newFFIComponent({
    name = "SmallTextureBucket",
    container = SmallTextureBucket,
    fields = BUCKET_FFI_FIELDS,
    transient = true,
})
tecs.newFFIComponent({
    name = "MediumTextureBucket",
    container = MediumTextureBucket,
    fields = BUCKET_FFI_FIELDS,
    transient = true,
})
tecs.newFFIComponent({
    name = "LargeTextureBucket",
    container = LargeTextureBucket,
    fields = BUCKET_FFI_FIELDS,
    transient = true,
})
tecs.newFFIComponent({
    name = "XLTextureBucket",
    container = XLTextureBucket,
    fields = BUCKET_FFI_FIELDS,
    transient = true,
})
tecs.newFFIComponent({
    name = "XXLTextureBucket",
    container = XXLTextureBucket,
    fields = BUCKET_FFI_FIELDS,
    transient = true,
})

-- SpriteData: renderer-internal derived metadata, populated by sync,
-- read by the shadow cull shader. 18 floats = 72 bytes, matching
-- Std430SpriteData in `gpu/std430.tl`. Default zeros come from FFI
-- column allocation; Sprite's `requires = {SpriteData}` adds it to
-- the initial archetype so the lifecycle observer doesn't have to
-- attach it via `world:set` per entity.
tecs.newFFIComponent({
    name = "SpriteData",
    container = SpriteData,
    transient = true,
    fields = {
        {"pivotX", "float"},
        {"pivotY", "float"},
        {"width", "float"},
        {"height", "float"},
        {"uvX", "float"},
        {"uvY", "float"},
        {"uvW", "float"},
        {"uvH", "float"},
        {"animTotalDuration", "float"},
        {"animFrameCount", "float"},
        {"animFrameWidth", "float"},
        {"animColumnCount", "float"},
        {"animFrameHeight", "float"},
        {"animTimingOffset", "float"},
        {"textureSlice", "float"},
        {"animDirection", "float"},
        {"animFirstFrame", "float"},
        {"spriteId", "float"},
    },
    defaults = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
})

-- Map tier names to bucket components
local TIER_TO_COMPONENT: {string: tecs.Component} = {
    Tiny = TinyTextureBucket,
    Small = SmallTextureBucket,
    Medium = MediumTextureBucket,
    Large = LargeTextureBucket,
    XL = XLTextureBucket,
    XXL = XXLTextureBucket,
}

-------------------------------------------------------------------------------
-- Factory functions
-------------------------------------------------------------------------------

function Sprite.fromSheet(
    spriteSheet: sheet.SpriteSheet,
    tag?: string,
    options?: {string: any}
): sprite.Sprite
    local opts = options or {}
    local tagStr = tag or ""
    local speed = (opts.speed as number) or 1.0
    local centered = opts.centered as boolean
    if centered == nil then centered = true end
    local pivotSlice = (opts.pivotSlice as string) or ""
    local startTime = (opts.startTime as number) or 0

    local spriteId = createInstance(
        spriteSheet as sprite_sheet.SpriteSheet,
        tagStr,
        speed,
        centered,
        pivotSlice
    )

    return Sprite(spriteId, startTime)
end

function Sprite.fromAseprite(path: string, tag?: string, options?: {string: any}): sprite.Sprite
    return Sprite.fromSheet(
        sprite_sheet.SpriteSheet.fromFile(path) as sheet.SpriteSheet, tag, options)
end

function Sprite.fromTexture(texture: love.graphics.Texture, options?: {string: any}): sprite.Sprite
    -- `options.path`, when supplied, is threaded through to the underlying
    -- spriteSheet so the sprite round-trips through snapshot save/load. Caller is
    -- responsible for keeping the texture and path in sync.
    local path = options and (options.path as string) or nil
    return Sprite.fromSheet(
        sprite_sheet.SpriteSheet.fromTexture(texture, path) as sheet.SpriteSheet, "", options)
end

-------------------------------------------------------------------------------
-- Plugin
-------------------------------------------------------------------------------

function sprite.plugin(renderPipeline: gpuTypes.PipelineInternal): function(world: tecs.World)
    return function(world: tecs.World)
        -- Store world reference for Sprite methods
        sprite_instance.setWorld(world)

        local renderer = renderPipeline:getRenderer()

        -- Initialize bucket manager (global singleton)
        local bucketMgr = bucketmanager.init()

        -- Create the bucket-based sync system (handles both normal and blend mode sprites via groupBy)
        local spriteSizeHint = (renderer as gpuTypes.Renderer).config.sizeHints["sprites"]
        local sync = bucketsync.new(world, Sprite, SpriteData as tecs.Component, TIER_TO_COMPONENT, DirectSprite, RepeatedSprite, spriteSizeHint)

        -- In-place Sprite replacement (world:set over an existing Sprite, or
        -- a batch-spawned zero sprite receiving its first value) causes no
        -- archetype transition, so the lifecycle observer can't see it.
        -- The sync dirty path detects the instance-id change and hands it
        -- here: release the old instance's refcount and re-run bucket
        -- assignment for the new spriteSheet.
        sync.onSpriteReplaced = function(entityId: integer, spr: any, oldSpriteId: integer)
            if oldSpriteId ~= 0 then
                clearPlayOnceCallback(entityId)
                releaseInstance(oldSpriteId)
            end
            onSpriteAdded(world, entityId, spr as sprite.Sprite)
        end

        -- Renderer-owned shadow-column path. The bucket-aware shadow
        -- pipeline builds per-archetype shadow state, dispatches the
        -- cull shader, and routes outputs to arraySync's per-(tier,
        -- array) buffers via `bucketProvider`. `bucket_sync` still
        -- runs but only as the lifecycle observer (allocating slots
        -- so arraySync.count tracks live entities for the per-bucket
        -- draw gate) plus the dirty path that populates SpriteData;
        -- the per-frame transform copy is gone.
        local gpuRenderer = renderer as gpuTypes.Renderer

        local cullDispatch: function(gpuTypes.Renderer, love.graphics.Buffer)
        do
            local bucketMarkers: {tecs.Component} = {
                TinyTextureBucket as tecs.Component,
                SmallTextureBucket as tecs.Component,
                MediumTextureBucket as tecs.Component,
                LargeTextureBucket as tecs.Component,
                XLTextureBucket as tecs.Component,
                XXLTextureBucket as tecs.Component,
            }
            local tierIdxToName: {integer: string} = {
                "Tiny", "Small", "Medium", "Large", "XL", "XXL",
            }

            local optional <const> = modifierbinding.bind({
                ColorComponent as tecs.Component,
                ClipBoundsComponent as tecs.Component,
                MaterialComponent as tecs.Component,
                PivotComponent as tecs.Component,
                OccluderComponent as tecs.Component,
                DropShadowComponent as tecs.Component,
                RepeatedSprite as tecs.Component,
                SpriteData as tecs.Component,
            }) as {shadowsetup.OptionalBinding}

            local tagFlags: {shadowdispatch.TagFlagBinding} = {
                {component = Unlit, flag = gpuTypes.FLAG_UNLIT},
            }

            local shadowCtx = shadowsetup.register(world, {
                sprite = Sprite as tecs.Component,
                bucketMarkers = bucketMarkers,
                optional = optional,
                registryName = "sprite.shadows",
                renderStateSystemName = "sprite.ShadowRenderState",
                uploadSystemName = "sprite.ShadowUpload",
                uploadAfter = {"sprite.GPUSync"},
            })

            -- bucketProvider returns the arraySync object cast to
            -- BucketBuffers. The field names line up post-rename
            -- (materialParamsOutputBuffer, indirectBuffer, etc.).
            local bucketProvider = function(tierIdx: integer, arrayIdx: integer): shadowdispatch.BucketBuffers
                local tierName = tierIdxToName[tierIdx]
                if not tierName then return nil end
                local tierSync = sync.tiers[tierName]
                if not tierSync then return nil end
                local arrSync = tierSync.arraySyncs[arrayIdx] as {string: any}
                if not arrSync then return nil end
                return arrSync as shadowdispatch.BucketBuffers
            end

            -- Binds the per-frame globals the cull shader needs:
            -- GlobalTime, FrameTimings, ShadowMargin, SlicePackingBits,
            -- plus the optional tile-light data the drop-shadow
            -- per-light fan-out reads.
            local function bindGlobals(shader: love.graphics.ComputeShader, rendererArg: any, _cullParamsBuffer: love.graphics.Buffer)
                local r = rendererArg as {string:any}
                if shader:hasUniform("GlobalTime") then
                    shader:send("GlobalTime", (r._cullGlobalTime as number) or 0.0)
                end
                if shader:hasUniform("SlicePackingBits") then
                    shader:send("SlicePackingBits", 16)
                end
                if shader:hasUniform("FrameTimings") then
                    shader:send("FrameTimings", timingbuffer.global:getBuffer())
                end
                if shader:hasUniform("ShadowMargin") then
                    local rConfig = r.config as {string:any}
                    shader:send("ShadowMargin", (rConfig.shadowMargin as number) or 200.0)
                end
                -- MaxDropShadows is per bucket (each bucket owns its own
                -- drop-shadow buffer), so shadowdispatch sends it next to
                -- the DropShadowOutput binding rather than here.
                local tileLightsBound = 0
                if r.lightOutputBuffer and shader:hasUniform("LightBuffer") then
                    shader:send("LightBuffer", r.lightOutputBuffer as love.graphics.Buffer)
                    shader:send("TileLightCounts", r.tileLightCountBuffer as love.graphics.Buffer)
                    shader:send("TileLightIndices", r.tileLightIndexBuffer as love.graphics.Buffer)
                    shader:send("TileViewport", r._tileViewport as {number})
                    shader:send("TileGridDims", {r._effectiveTileGridW as integer, r._effectiveTileGridH as integer})
                    tileLightsBound = 1
                end
                -- Gates the drop-shadow per-light fan-out: with lighting
                -- off the tile-light SSBOs above are never populated.
                if shader:hasUniform("TileLightsBound") then
                    shader:send("TileLightsBound", tileLightsBound)
                end
            end

            -- Binds per-archetype: the bucket's texture-array slice-
            -- generation buffer (for staleness detection in the cull's
            -- generation check).
            local bucketMgrAny <const> = bucketMgr as {string: function(any, string): any}
            local function bindPerArchetype(shader: love.graphics.ComputeShader, tierIdx: integer, arrayIdx: integer)
                if not shader:hasUniform("SliceGenerations") then return end
                local tierName = tierIdxToName[tierIdx]
                if not tierName then return end
                local arrays = bucketMgrAny.getArrays(bucketMgr, tierName) as {integer: {string: any}}
                if not arrays then return end
                local texArray = arrays[arrayIdx]
                if not texArray then return end
                local genBuf = texArray.generationsBuffer as love.graphics.Buffer
                if genBuf then
                    shader:send("SliceGenerations", genBuf)
                end
            end

            local dispatchCtx = shadowdispatch.new({
                shader = spriteCullShader,
                registry = shadowCtx.registry,
                spriteComponent = Sprite as tecs.Component,
                bucketMarkers = bucketMarkers,
                optional = optional as {shadowdispatch.OptionalBinding},
                tagFlags = tagFlags,
                bucketProvider = bucketProvider,
                bindGlobals = bindGlobals,
                bindPerArchetype = bindPerArchetype,
            })

            cullDispatch = function(rendererArg: gpuTypes.Renderer, cullParamsBuffer: love.graphics.Buffer)
                dispatchCtx:dispatch(rendererArg, cullParamsBuffer)
            end
        end

        -- Register sprite render plugin
        gpuRenderer:registerPlugin(renderplugin.create({
            renderShader = spriteRenderShader,
            shadowMaskShader = spriteShadowMaskShader,
            dropShadowShader = spriteDropShadowShader,
            bucketSync = sync,
            bucketManager = bucketMgr,
            cullDispatch = cullDispatch,
        } as renderplugin.SpritePluginConfig))

        -- GPU sync system (bucket-based, includes blend mode handling via groupBy)
        world:addSystem({
            name = "sprite.GPUSync",
            phase = tecs.phases.PreRender,
            run = function(dt: number)
                sync:sync(dt)
            end
        })

        -- Sprite lifecycle observer: per-entity bucket/TextureArray tag
        -- assignment on add, instance-refcount release on remove. The
        -- archetype match-transition semantics fire this exactly when
        -- a Sprite enters/leaves an entity (once per entity).
        world:query({
            name = "sprite.SpriteLifecycle",
            include = {Sprite},
            onEntitiesAdded = function(archetype: tecs.Archetype, firstRow: integer, lastRow: integer, _count: integer)
                local sprites = archetype:get(Sprite) as {sprite.Sprite}
                local spriteDatas = archetype:get(SpriteData as tecs.Component) as {sprite.SpriteData}
                local entities = archetype.entities
                for row = firstRow, lastRow do
                    local self = sprites[row]
                    if self and self.spriteId ~= 0 then
                        onSpriteAdded(world, entities[row], self)
                        -- Pre-stamp the synced instance id so the sync dirty
                        -- path's replacement detection doesn't re-run bucket
                        -- assignment for a plain spawn. The column is already
                        -- dirty at spawn time, so no explicit mark needed.
                        if spriteDatas then
                            spriteDatas[row].spriteId = self.spriteId
                        end
                    end
                end
            end,
            onEntitiesRemoved = function(archetype: tecs.Archetype, firstRow: integer, lastRow: integer, _count: integer, destArchetype?: tecs.Archetype)
                -- Skip refcount release when moving between Sprite-bearing archetypes.
                if destArchetype and destArchetype:get(Sprite) then return end
                local sprites = archetype:get(Sprite) as {sprite.Sprite}
                for row = firstRow, lastRow do
                    local self = sprites[row]
                    if self and self.spriteId ~= 0 then
                        clearPlayOnceCallback(self._entity)
                        releaseInstance(self.spriteId)
                    end
                end
            end,
        })

        -- Sprite pause observer: when Paused is added/removed, call sprite:pause()/resume()
        -- pauseDepth ref-counting inside pause()/resume() ensures manually paused sprites
        -- (bullets, pauseAtEnd explosions) stay paused after state stack resume.
        do
            local Paused <const> = tecs.builtins.Paused
            world:query({
                name = "sprite.PauseObserver",
                include = {Sprite, Paused},
                onEntitiesAdded = function(archetype: tecs.Archetype, firstRow: integer, lastRow: integer, _count: integer)
                    local sprites = archetype:getMut(Sprite) as {sprite.Sprite}
                    for row = firstRow, lastRow do
                        sprites[row]:pause()
                    end
                end,
                onEntitiesRemoved = function(archetype: tecs.Archetype, firstRow: integer, lastRow: integer, _count: integer)
                    local sprites = archetype:getMut(Sprite) as {sprite.Sprite}
                    for row = firstRow, lastRow do
                        local spr = sprites[row]
                        if spr and spr.spriteId ~= 0 then
                            spr:resume()
                        end
                    end
                end,
            })
        end

        local playOnceQuery = world:query({
            name = "sprite.PlayOnce",
            include = {Sprite}
        })

        world:addSystem({
            name = "sprite.PlayOnce",
            phase = tecs.phases.Update,
            run = function(_dt: number)
                if playOncePendingCount == 0 then
                    return
                end

                for archetype, len in playOnceQuery:iter() do
                    local sprites = archetype:getMut(Sprite) as {sprite.Sprite}
                    local entities = archetype.entities
                    for row = 1, len do
                        local entityId = entities[row] as integer
                        if playOnceCallbacks[entityId] ~= nil then
                            sprites[row]:getFrame()
                        end
                    end
                end
            end
        })

        -- Collision setup system
        local lp = love and love.physics
        if lp then
            local physics = require("tecs2d.physics")
            local Collider = physics.Collider
            local SpriteCollision = sprite_collision.SpriteCollision

            -- Register the per-entity body-init observer so adding
            -- SpriteCollision to an entity auto-attaches a default
            -- Collider plus the right physics body.
            sprite_collision.plugin(world)

            local collisionQuery = world:query({
                name = "sprite.CollisionSetup",
                include = {SpriteCollision, Sprite, Collider}
            })

            world:addSystem({
                name = "sprite.CollisionSetup",
                phase = tecs.phases.FixedUpdate,
                run = function(_dt: number)
                    for archetype, len in collisionQuery:iter() do
                        local spriteCollisions = archetype:getMut(SpriteCollision)
                        local sprites = archetype:get(Sprite)
                        local colliders = archetype:get(Collider)
                        local entities = archetype.entities

                        for i = 1, len do
                            local sc = spriteCollisions[i]

                            if sc._setupComplete then
                                goto continue
                            end

                            local spr = sprites[i]
                            local inst = getInstance(spr.spriteId)
                            if not inst then
                                goto continue
                            end

                            local sheetVal = sprite_sheet.SpriteSheet.getById(inst.sheetId)
                            if not sheetVal then
                                goto continue
                            end

                            local col = colliders[i]
                            if not col.body then
                                goto continue
                            end

                            local entityId = entities[i] as integer
                            if sprite_collision.setupCollision(
                                world,
                                entityId,
                                sheetVal,
                                sc as sprite_collision.Config,
                                lp
                            ) then
                                sc._setupComplete = true
                            end

                            ::continue::
                        end
                    end
                end
            })
        end

    end
end

return sprite
