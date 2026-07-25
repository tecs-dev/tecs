--- Unified Sprite Sync System.
---
--- Architecture: bucketed, row-keyed sprite sync.
---
--- Sprites are still partitioned by size tier and texture array, but the
--- sync path no longer assigns permanent GPU slots per entity. Each archetype
--- contributes shadow source columns, and cull gathers row-keyed data into
--- dense per-array outputs for render/shadow/drop-shadow passes.
---
--- Group ID Encoding: (tierIdx * 1024) + (arrayIdx * 16) + blendId
---   - tierIdx: 0-5 (Tiny, Small, Medium, Large, XL, XXL)
---   - arrayIdx: 1-63 (texture array index from TextureArray component)
---   - blendId: 0-14 (alpha, add, multiply, screen, etc.)

local tecs <const> = require("tecs")
local gpuTypes <const> = require("tecs2d.gfx.internal.gpu.types")
local types <const> = gpuTypes
local sprite_instance <const> = require("tecs2d.gfx.internal.sprite.instance")
local sprite_sheet <const> = require("tecs2d.gfx.internal.sprite.sheet")
local bucketmanager <const> = require("tecs2d.gfx.internal.sprite.bucketmanager")
local TextureArray <const> = require("tecs2d.gfx.internal.sprite.TextureArray")
local DropShadowComponent <const> = require("tecs2d.gfx.internal.DropShadow")
local blend <const> = require("tecs2d.gfx.internal.blend")
local MaterialComponent <const> = require("tecs2d.gfx.internal.Material")
local shapesyncbase <const> = require("tecs2d.gfx.internal.shapesyncbase")
local retire <const> = require("tecs2d.gfx.internal.gpu.retire")

local Transform <const> = tecs.builtins.Transform

-- Local record types describing the canonical FFI columns this module
-- reads or writes. Sprite is read for spriteId / animStartTime /
-- pausedFrame; SpriteDataFFI is the renderer-internal column the
-- cull shader consumes.
local record SpriteData
    spriteId: integer
    _entity: integer
    animStartTime: number
    pausedFrame: integer
    _pauseAtFrame: integer
    pauseDepth: integer
end

local record BucketData
    layerIndex: integer
    generation: integer
end

local record RepeatedSpriteData
    repeatX: boolean
    repeatY: boolean
    width: number
    height: number
end

local record DropShadowData
    height: number
    opacity: number
end

local type MaterialData = shapesyncbase.MaterialData
local type MaterialGroup = shapesyncbase.MaterialGroup
local type BlendGroup = shapesyncbase.BlendGroup
local trackMaterialGroup <const> = shapesyncbase.trackMaterialGroup
local trackBlendGroup <const> = shapesyncbase.trackBlendGroup

local record SpriteDataFFI
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
    textureSlice: number
    animDirection: number
    animFirstFrame: number
    spriteId: number
end

local getInstance <const> = sprite_instance.get
local DEFAULT_CAPACITY <const> = 4096

-- Reused scratch union for writing the packed textureSlice bit pattern
-- into SpriteData's float field (decoded with floatBitsToUint on GPU).
local record SlicePack
    u: integer
    f: number
end
local slicePack <const> = require("ffi").new("union { uint32_t u; float f; }") as SlicePack

-- Group ID encoding: (tierIdx * 1024) + (arrayIdx * 16) + blendId
-- Decoding: tierIdx = groupId // 1024, arrayIdx = (groupId % 1024) // 16, blendId = groupId % 16
local TIER_SHIFT <const> = 1024
local ARRAY_SHIFT <const> = 16

local record bucket_sync
    -- Per (tier, array) bucket: cull-output buffers + indirect args.
    -- Buffer fields are bucket-aware shadow dispatch's writes; CPU-side
    -- count tracks live entities for the render plugin's draw gate.
    record ArraySync
        outputBuffer: love.graphics.Buffer
        indirectBuffer: love.graphics.Buffer
        shadowOutputBuffer: love.graphics.Buffer
        shadowIndirectBuffer: love.graphics.Buffer
        dropShadowOutputBuffer: love.graphics.Buffer
        dropShadowIndirectBuffer: love.graphics.Buffer
        materialParamsOutputBuffer: love.graphics.Buffer
        capacity: integer
        --- Row capacity of dropShadowOutputBuffer. Once `dropShadowActive`,
        --- it is DS_FANOUT * `capacity` because the cull's per-light
        --- fan-out writes up to one entry per (sprite, affecting light)
        --- pair; before then it stays at the DS_MIN_CAPACITY floor. Sent to
        --- the cull and render shaders as MaxDropShadows so writes and reads
        --- never pass it.
        dropShadowCapacity: integer
        --- Set true the first time this bucket contains DropShadow entities.
        --- Until then the drop-shadow buffer is kept at the floor so scenes
        --- that never use drop shadows don't pay DS_FANOUT * capacity (the
        --- dominant sprite allocation).
        dropShadowActive: boolean
        count: integer
    end

    record TierSync
        tier: string
        tierIdx: integer
        arraySyncs: {integer: ArraySync}
        bucketComponent: tecs.Component
        -- Cached array index list (reused each frame)
        activeArrayIndices: {integer}
        activeArrayCount: integer
    end

    record SpriteBucketSync
        world: tecs.World
        -- Unified query for all tiers (groups by tier + array + blend).
        query: tecs.Query
        tiers: {string: TierSync}
        tiersByIdx: {integer: TierSync}
        spriteComponent: tecs.Component
        spriteDataComponent: tecs.Component
        repeatedSpriteComponent: tecs.Component
        bucketManager: bucketmanager.Manager
        -- Material group tracking (across all tiers/arrays)
        materialGroups: {MaterialGroup}
        materialGroupCount: integer
        -- Set during sync: true if any archetype has DropShadow entities
        hasDropShadows: boolean
        -- Blend group tracking for forward blend rendering
        blendGroups: {BlendGroup}
        blendGroupCount: integer
        -- Set during sync: true if any alpha-blend (blendId == 0) entities exist
        hasAlphaBlend: boolean
        -- One-shot: request a full resync on the next sync() (set on snapshot load).
        _forceResync: boolean

        -- Fired when the dirty path sees a row whose Sprite instance id
        -- changed without an archetype transition (world:set replacement,
        -- or a batch-spawned zero sprite receiving its first value).
        -- oldSpriteId is 0 for the first assignment. Set by the sprite
        -- plugin to release the old instance and re-run bucket assignment;
        -- spr is the row's Sprite component (typed loosely because the
        -- Sprite record lives in the plugin module).
        onSpriteReplaced: function(entityId: integer, spr: any, oldSpriteId: integer)

        sync: function(SpriteBucketSync, dt: number)
    end

    new: function(
        world: tecs.World,
        spriteComponent: tecs.Component,
        spriteDataComponent: tecs.Component,
        bucketComponents: {string: tecs.Component},
        repeatedSpriteComponent?: tecs.Component,
        spriteSizeHint?: integer
    ): SpriteBucketSync
end

local SpriteBucketSync <const> = bucket_sync.SpriteBucketSync
local SYNC_MT <const>: metatable<SpriteBucketSync> = { __index = SpriteBucketSync }
local lg <const> = love.graphics

--- Drop-shadow fan-out headroom: the cull writes one entry per
--- (sprite, affecting light) pair, so the buffer needs more rows than
--- live sprites. 8 lights per sprite matches shadow_dispatch's
--- non-provider heuristic; overflow past it is dropped by the
--- MaxDropShadows guard rather than written out of bounds.
local DS_FANOUT <const> = 8

--- Floor capacity for a bucket's drop-shadow output buffer before any
--- drop-shadow sprite is seen. The buffer must exist (the cull binds it
--- unconditionally), but at DS_FANOUT * capacity it is the single
--- largest sprite allocation, so it stays at this floor until a bucket
--- actually contains DropShadow entities (see ensureDropShadowActive).
--- The cull's MaxDropShadows guard clamps writes to this floor, and the
--- AO pass draws 0 instances for such buckets, so the small buffer is
--- never read out of bounds.
local DS_MIN_CAPACITY <const> = 256

local function createArraySync(capacity: integer): bucket_sync.ArraySync
    local function newOutput(cap: integer): love.graphics.Buffer
        return lg.newBuffer(types.SPRITE_FORMAT, cap, { usage = "dynamic", shaderstorage = true })
    end
    local function newIndirect(): love.graphics.Buffer
        return lg.newBuffer(types.INDIRECT_FORMAT, 4, { usage = "dynamic", shaderstorage = true, indirectarguments = true })
    end
    return {
        outputBuffer = newOutput(capacity),
        indirectBuffer = newIndirect(),
        shadowOutputBuffer = newOutput(capacity),
        shadowIndirectBuffer = newIndirect(),
        -- Drop-shadow buffer stays at the floor until this bucket is seen
        -- to hold DropShadow entities (ensureDropShadowActive), so scenes
        -- without drop shadows never allocate DS_FANOUT * capacity.
        dropShadowOutputBuffer = newOutput(DS_MIN_CAPACITY),
        dropShadowIndirectBuffer = newIndirect(),
        materialParamsOutputBuffer = lg.newBuffer(types.MATERIAL_PARAMS_FORMAT, capacity, { usage = "dynamic", shaderstorage = true }),
        capacity = capacity,
        dropShadowCapacity = DS_MIN_CAPACITY,
        dropShadowActive = false,
        count = 0,
    }
end

--- Grow this bucket's cull-output buffers to fit `liveCount` entries.
--- Called from the lifecycle observer when archetype-add bumps the
--- count past the current capacity.
local function ensureCapacity(arraySync: bucket_sync.ArraySync, liveCount: integer)
    if liveCount <= arraySync.capacity then return end
    local newCap = arraySync.capacity * 2
    if newCap < liveCount then newCap = liveCount end
    -- In-flight GPU work may still read the replaced buffers; release
    -- them through the deferred retire list.
    retire.push(arraySync.outputBuffer)
    retire.push(arraySync.shadowOutputBuffer)
    retire.push(arraySync.materialParamsOutputBuffer)
    arraySync.outputBuffer = lg.newBuffer(types.SPRITE_FORMAT, newCap, { usage = "dynamic", shaderstorage = true })
    arraySync.shadowOutputBuffer = lg.newBuffer(types.SPRITE_FORMAT, newCap, { usage = "dynamic", shaderstorage = true })
    arraySync.materialParamsOutputBuffer = lg.newBuffer(types.MATERIAL_PARAMS_FORMAT, newCap, { usage = "dynamic", shaderstorage = true })
    arraySync.capacity = newCap
    -- The drop-shadow buffer only tracks capacity once activated; inactive
    -- buckets keep the floor and leave dropShadowCapacity untouched.
    if arraySync.dropShadowActive then
        retire.push(arraySync.dropShadowOutputBuffer)
        arraySync.dropShadowOutputBuffer = lg.newBuffer(types.SPRITE_FORMAT, newCap * DS_FANOUT, { usage = "dynamic", shaderstorage = true })
        arraySync.dropShadowCapacity = newCap * DS_FANOUT
    end
end

--- Promote a bucket's drop-shadow buffer from the floor to the full
--- DS_FANOUT * capacity the first time the bucket is seen to contain
--- DropShadow entities. Must run before the cull dispatch (called from
--- sync(), which is a PreRender system) so the fan-out writes land in a
--- correctly sized buffer instead of being clamped by MaxDropShadows.
local function ensureDropShadowActive(arraySync: bucket_sync.ArraySync)
    if arraySync.dropShadowActive then return end
    arraySync.dropShadowActive = true
    retire.push(arraySync.dropShadowOutputBuffer)
    arraySync.dropShadowOutputBuffer = lg.newBuffer(types.SPRITE_FORMAT, arraySync.capacity * DS_FANOUT, { usage = "dynamic", shaderstorage = true })
    arraySync.dropShadowCapacity = arraySync.capacity * DS_FANOUT
end

function bucket_sync.new(
    world: tecs.World,
    spriteComponent: tecs.Component,
    spriteDataComponent: tecs.Component,
    bucketComponents: {string: tecs.Component},
    repeatedSpriteComponent?: tecs.Component,
    spriteSizeHint?: integer
): bucket_sync.SpriteBucketSync
    local bucketMgr = bucketmanager.get()

    -- Initial per-bucket output capacity. sizeHints.sprites is a global
    -- sprite capacity hint, not a per-texture-bucket reservation, so use it
    -- as a cap while sizing each new bucket from the first observed add.
    local function initialBucketCapacity(firstAddCount: integer): integer
        local cap = DEFAULT_CAPACITY
        if firstAddCount > cap then cap = firstAddCount end
        if spriteSizeHint and spriteSizeHint > 0 and cap > spriteSizeHint then
            cap = spriteSizeHint
        end
        return cap
    end

    -- Build tier structures and component -> tierIdx map
    local tiers: {string: bucket_sync.TierSync} = {}
    local tiersByIdx: {integer: bucket_sync.TierSync} = {}
    local componentToTierIdx: {tecs.Component: integer} = {}
    local includeAnyList: {tecs.Component} = {}

    -- Assign tier indices in a consistent order (must match TIER_TO_COMPONENT keys in sprite/init.tl)
    local tierOrder <const> = {"Tiny", "Small", "Medium", "Large", "XL", "XXL"}
    local tierIdx = 0
    for _, tierName in ipairs(tierOrder) do
        local bucketComponent = bucketComponents[tierName]
        if bucketComponent then
            local tierSync: bucket_sync.TierSync = {
                tier = tierName,
                tierIdx = tierIdx,
                arraySyncs = {},
                bucketComponent = bucketComponent,
                activeArrayIndices = {},
                activeArrayCount = 0,
            }
            tiers[tierName] = tierSync
            tiersByIdx[tierIdx] = tierSync
            componentToTierIdx[bucketComponent] = tierIdx
            includeAnyList[#includeAnyList + 1] = bucketComponent
            tierIdx = tierIdx + 1
        end
    end

    -- Determine tier index by checking which bucket component is present
    local function detectTierIdx(archetype: tecs.Archetype): integer
        for comp, idx in pairs(componentToTierIdx) do
            if archetype:get(comp) then
                return idx
            end
        end
        return 0
    end

    -- Create unified groupBy function
    -- Group ID = (tierIdx * 1024) + (arrayIdx * 16) + blendId
    local function unifiedGroupBy(archetype: tecs.Archetype): integer
        local detectedTierIdx = detectTierIdx(archetype)

        -- Get array index from TextureArray component (1-based, or 0 if not found)
        local arrayIdx = TextureArray.getArrayIndex(archetype)

        -- Get blend mode (0 = deferred alpha, 1-15 = forward blend modes)
        local blendId = blend.groupBy(archetype)

        return (detectedTierIdx * TIER_SHIFT) + (arrayIdx * ARRAY_SHIFT) + blendId
    end

    -- Create single unified query for all tiers
    -- Batched hooks: tier detection and arraySync lookup are per-archetype
    -- invariants, hoisted out of the per-entity loop.
    local query = world:query({
        name = "sprite.BucketSync.unified",
        include = {spriteComponent, Transform},
        includeAny = includeAnyList,
        groupBy = unifiedGroupBy,
        onEntitiesAdded = function(archetype: tecs.Archetype, _firstRow: integer, _lastRow: integer, count: integer)
            local detectedTierIdx = detectTierIdx(archetype)
            local arrayIdx = TextureArray.getArrayIndex(archetype)
            if arrayIdx == 0 then return end
            local tierSync = tiersByIdx[detectedTierIdx]
            if not tierSync then return end
            local arraySync = tierSync.arraySyncs[arrayIdx]
            if not arraySync then
                arraySync = createArraySync(initialBucketCapacity(count))
                tierSync.arraySyncs[arrayIdx] = arraySync
            end
            arraySync.count = arraySync.count + count
            ensureCapacity(arraySync, arraySync.count)
        end,
        onEntitiesRemoved = function(archetype: tecs.Archetype, _firstRow: integer, _lastRow: integer, count: integer)
            local detectedTierIdx = detectTierIdx(archetype)
            local arrayIdx = TextureArray.getArrayIndex(archetype)
            if arrayIdx == 0 then return end
            local tierSync = tiersByIdx[detectedTierIdx]
            if not tierSync then return end
            local arraySync = tierSync.arraySyncs[arrayIdx]
            if not arraySync then return end
            arraySync.count = arraySync.count - count
            if arraySync.count < 0 then arraySync.count = 0 end
        end,
    })

    local syncObj: SpriteBucketSync = setmetatable({
        world = world,
        query = query,
        tiers = tiers,
        tiersByIdx = tiersByIdx,
        spriteComponent = spriteComponent,
        spriteDataComponent = spriteDataComponent,
        repeatedSpriteComponent = repeatedSpriteComponent,
        bucketManager = bucketMgr,
        materialGroups = {},
        materialGroupCount = 0,
        hasDropShadows = false,
        blendGroups = {},
        blendGroupCount = 0,
        hasAlphaBlend = false,
        _forceResync = false,
    }, SYNC_MT)

    -- Snapshot restore bulk-loads sprite entities and then commits, which clears
    -- the per-component dirty flags before this sync runs at render time. Without
    -- them, sync() skips restored archetypes and their SpriteData (size/UV) stays
    -- zero-initialised, so every restored sprite renders at zero size (invisible).
    -- Force one full resync after a load so SpriteData gets repopulated.
    world:observe(0, tecs.builtins.FinishSnapshotLoad, function()
        syncObj._forceResync = true
    end)

    return syncObj
end

local floor <const> = math.floor

function SpriteBucketSync:sync(_dt: number)
    -- Consume a one-shot full-resync request (set on snapshot load); when set,
    -- treat every archetype as dirty so zeroed SpriteData gets rebuilt.
    local forceResync = self._forceResync
    self._forceResync = false
    local spriteComponent = self.spriteComponent
    local repeatedSpriteComponent = self.repeatedSpriteComponent
    local bucketMgr = self.bucketManager
    local query = self.query
    local tiersByIdx = self.tiersByIdx

    -- Reset tracking
    self.materialGroupCount = 0
    self.hasDropShadows = false
    self.blendGroupCount = 0
    self.hasAlphaBlend = false

    for _, tierSync in pairs(self.tiers) do
        tierSync.activeArrayCount = 0
    end

    -- Per-frame dedup for active-array tracking (keyed by
    -- `tierIdx * 64 + arrayIdx`).
    local seenArrays: {integer: boolean} = {}

    -- ==========================================================================
    -- Single pass: iterate groups, copy transforms (hot), write metadata (dirty)
    -- ==========================================================================
    for groupId in query:groups() do
        local tierIdx = floor(groupId / TIER_SHIFT)
        local remainder = groupId % TIER_SHIFT
        local arrayIdx = floor(remainder / ARRAY_SHIFT)
        local blendId = remainder % ARRAY_SHIFT

        -- Skip invalid (arrayIdx == 0 means no TextureArray component)
        if arrayIdx == 0 then goto skip_group end

        local tierSync = tiersByIdx[tierIdx]
        if not tierSync then goto skip_group end

        local bucketComponent = tierSync.bucketComponent
        local arraySync = tierSync.arraySyncs[arrayIdx]
        if not arraySync then goto skip_group end

        -- Track blend groups
        if blendId > 0 then
            self.blendGroupCount = trackBlendGroup(self.blendGroups, self.blendGroupCount, blendId)
        elseif blendId == 0 then
            self.hasAlphaBlend = true
        end

        -- Track active arrays on tierSync (dedup; first time seeing
        -- this (tier, array) this frame).
        if not seenArrays[tierIdx * 64 + arrayIdx] then
            seenArrays[tierIdx * 64 + arrayIdx] = true
            tierSync.activeArrayCount = tierSync.activeArrayCount + 1
            tierSync.activeArrayIndices[tierSync.activeArrayCount] = arrayIdx
        end

        for archetype, len in query:group(groupId) do
            if len == 0 then goto continue_archetype end

            local bucketData = archetype:get(bucketComponent) as {BucketData}
            local repeatedSprites = repeatedSpriteComponent and (archetype:get(repeatedSpriteComponent) as {RepeatedSpriteData}) or nil
            local dropShadowArr = archetype:get(DropShadowComponent) as {DropShadowData}
            local materialArr = archetype:get(MaterialComponent) as {MaterialData}
            if dropShadowArr then
                self.hasDropShadows = true
                -- Promote this bucket's drop-shadow buffer off the floor
                -- before the cull dispatch reads it (this runs in PreRender,
                -- the cull in Render). No-op once already active.
                ensureDropShadowActive(arraySync)
            end

            -- Material grouping (per frame): the render plugin uses the
            -- group list to dispatch material-variant draws; the cull
            -- shader emits per-instance material params in cull-output
            -- order, so no slot-keyed write needed.
            if materialArr then
                for k = 1, len do
                    local mat = materialArr[k]
                    if mat and mat.materialId > 0 then
                        self.materialGroupCount = trackMaterialGroup(
                            self.materialGroups, self.materialGroupCount, mat.materialId)
                    end
                end
            end

            -- Dirty path: resolve sprite-instance derived metadata (UV,
            -- pivot, animation params, textureSlice) into the SpriteData
            -- column for the cull shader. Gate on the components this
            -- metadata derives from, not anyComponentDirty(): a transform
            -- change (movement) must not trigger this full per-row walk,
            -- since no output depends on position/rotation/scale (scale is
            -- applied in the cull shader). The bulk transform mirror still
            -- re-uploads.
            local spriteDirty = archetype:isComponentDirty(spriteComponent)
            local bucketDirty = archetype:isComponentDirty(bucketComponent)
            local repeatedDirty = repeatedSpriteComponent ~= nil
                and archetype:isComponentDirty(repeatedSpriteComponent)

            if forceResync or spriteDirty or bucketDirty or repeatedDirty then
                local sprites = archetype:get(spriteComponent) as {SpriteData}
                local spriteDatas = archetype:getMut(self.spriteDataComponent) as {SpriteDataFFI}
                local entityList = archetype.entities

                for row = 1, len do
                    local spr = sprites[row]
                    if spr then
                        local sd = spriteDatas[row]
                        -- Detect in-place instance replacement (world:set of a
                        -- new Sprite, or a batch-spawned zero sprite getting
                        -- its first value). No archetype transition happens,
                        -- so the lifecycle observer can't see it; hand it to
                        -- the plugin to release the old instance and re-run
                        -- bucket assignment. The marker writes it makes are
                        -- deferred, so this row renders with the old bucket
                        -- for one frame and resyncs when they land.
                        local syncedId = sd.spriteId
                        local replaced = syncedId ~= spr.spriteId
                        if replaced then
                            sd.spriteId = spr.spriteId
                            if self.onSpriteReplaced and spr.spriteId ~= 0 then
                                self.onSpriteReplaced(entityList[row], spr, syncedId as integer)
                            end
                        end

                        -- Per-row resolution gate. The derived metadata below
                        -- depends only on the sprite instance and the row's
                        -- texture-array slice, neither of which changes frame
                        -- to frame once resolved. Re-resolve only when the row
                        -- is new (zeroed SpriteData, so width 0), its instance
                        -- was replaced, its slice/generation changed (texture
                        -- array repack), or a full resync was requested. The
                        -- outer dirty gate fires for the whole archetype every
                        -- time a batch spawn adds rows; without this per-row
                        -- gate every existing row is re-resolved each spawn
                        -- frame, making a full spawn O(n^2).
                        local bucket = bucketData[row]
                        local desiredSlice = bucket.layerIndex + bucket.generation * 65536
                        slicePack.f = sd.textureSlice
                        if forceResync or repeatedDirty or replaced or sd.width == 0 or slicePack.u ~= desiredSlice then
                            local inst = getInstance(spr.spriteId)
                            if inst then
                            -- Resolve UV scale (texture-array fitting).
                            local uvScaleX, uvScaleY = 1.0, 1.0
                            local sheet = sprite_sheet.SpriteSheet.getById(inst.sheetId)
                            if sheet then
                                local image = sheet:getImage()
                                local w, h = (image as love.graphics.Texture):getDimensions()
                                uvScaleX, uvScaleY = bucketMgr:getUVScale(inst.sheetId, w as integer, h as integer)
                            end

                            local frameW = inst.width
                            local frameH = inst.height
                            local spriteWidth = frameW
                            local spriteHeight = frameH
                            local cols = inst.animColumnCount
                            if cols <= 0 then cols = 1 end
                            local uvX = inst.uvX * uvScaleX
                            local uvY = inst.uvY * uvScaleY
                            local uvW = inst.uvW * uvScaleX
                            local uvH = inst.uvH * uvScaleY

                            -- RepeatedSprite tiling: stretch UV so the
                            -- render shader's `fract` wrap produces N
                            -- tiles inside the larger sprite quad.
                            if repeatedSprites then
                                local rep = repeatedSprites[row]
                                if rep and (rep.repeatX or rep.repeatY) then
                                    local tiledWidth = rep.width > 0 and rep.width or spriteWidth
                                    local tiledHeight = rep.height > 0 and rep.height or spriteHeight
                                    if rep.repeatX and spriteWidth > 0 then
                                        local tileScaleX = tiledWidth / spriteWidth
                                        spriteWidth = tiledWidth
                                        uvW = uvW * tileScaleX
                                    end
                                    if rep.repeatY and spriteHeight > 0 then
                                        local tileScaleY = tiledHeight / spriteHeight
                                        spriteHeight = tiledHeight
                                        uvH = uvH * tileScaleY
                                    end
                                end
                            end

                            local pivotX, pivotY = 0.5, 0.5
                            if not inst.centered then
                                pivotX = frameW > 0 and inst.pivotX / frameW or 0
                                pivotY = frameH > 0 and inst.pivotY / frameH or 0
                            end

                            sd.pivotX = pivotX
                            sd.pivotY = pivotY
                            sd.width = spriteWidth
                            sd.height = spriteHeight
                            sd.uvX = uvX
                            sd.uvY = uvY
                            sd.uvW = uvW
                            sd.uvH = uvH
                            sd.animTotalDuration = inst.animTotalDuration or 0
                            sd.animFrameCount = inst.animFrameCount
                            sd.animFrameWidth = inst.animFrameWidth * uvScaleX
                            sd.animColumnCount = cols
                            sd.animFrameHeight = inst.animFrameHeight * uvScaleY
                            sd.animTimingOffset = inst.animTimingOffset or 0
                            -- Pack layer | generation << 16 as uint32 BITS
                            -- through the float field (the cull decodes
                            -- with floatBitsToUint). Encoding the packed
                            -- value as a float NUMBER loses layer bits
                            -- once generation reaches 256 (24-bit
                            -- mantissa).
                            slicePack.u = desiredSlice
                            sd.textureSlice = slicePack.f
                            sd.animDirection = inst.animDirection or 0
                            sd.animFirstFrame = inst.animFirstFrame or 0
                            end
                        end
                    end
                end
            end

            ::continue_archetype::
        end

        ::skip_group::
    end
    -- arraySync.count is maintained by the lifecycle observer; nothing
    -- to finalize per frame.
end

return bucket_sync
