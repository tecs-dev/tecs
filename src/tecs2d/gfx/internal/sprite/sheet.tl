--- SpriteSheet data structures for sprite animation
--- Parses Aseprite JSON format for frame data, tags, and slices.
local json <const> = require("tecs.utils.json")
local C <const> = require("ffi")
local bucketmanager <const> = require("tecs2d.gfx.internal.sprite.bucketmanager")

-- FFI struct for pre-computed UV coordinates (16 bytes, cache-friendly)
C.cdef[[
typedef struct {
    float u, v, w, h;
} FrameUV;
]]

-- FFI type for accessing FrameUV array
local record FrameUVFFI
    u: number
    v: number
    w: number
    h: number
end

-- Direction constants for frame tag playback
local record DirectionConstants
    FORWARD: integer
    REVERSE: integer
    PINGPONG: integer
end

local DIRECTION <const>: DirectionConstants = {
    FORWARD = 0,
    REVERSE = 1,
    PINGPONG = 2
}

local DIRECTION_FORWARD <const> = DIRECTION.FORWARD
local DIRECTION_REVERSE <const> = DIRECTION.REVERSE

local record sprite_sheet
    Direction: DirectionConstants

    record Frame
        x: number
        y: number
        w: number
        h: number
        duration: number
    end

    record FrameTag
        from: integer
        to: integer
        -- DIRECTION constant value
        direction: integer
        duration: number

        timingTable: {number}
    end

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

    record Slice
        -- User-defined data
        data: string
        keys: {SliceKey}
    end

    -- Concrete implementation of the SpriteSheet API. The supported
    -- surface (methods, statics, and the records they return) is
    -- documented on the public type in tecs2d.gfx.sprite_sheet, which
    -- re-exports this record cast to that type.
    record SpriteSheet
        -- Internal fields (set by builder)
        _id: integer
        _image: love.graphics.Image
        _width: number
        _height: number
        _spriteWidth: number
        _spriteHeight: number
        _quads: {integer: love.graphics.Quad}
        _frames: {Frame}
        _frameCount: integer
        _tags: {string: FrameTag}
        _slices: {string: Slice}
        _tagToId: {string: integer}
        _idToTag: {integer: string}
        _tagCount: integer
        _sliceToId: {string: integer}
        _idToSlice: {integer: string}
        _sliceCount: integer
        _defaultTag: FrameTag
        _path: string
        _frameUVs: C.CData
        _frameUVsPtr: {integer: FrameUVFFI}
        _normalImage: love.graphics.Image
        _emissionImage: love.graphics.Image
        _ormImage: love.graphics.Image

        getFrame: function(self, frame: integer): Frame

        getFrameTag: function(self, tag: string): FrameTag

        hasFrameTag: function(self, tag: string): boolean

        getSlice: function(self, name: string): Slice

        getSheetSize: function(self): number, number

        getSpriteSize: function(self): number, number

        getImage: function(self): love.graphics.Image

        getQuad: function(self, frame: integer): love.graphics.Quad

        getAnimationFrame: function(self, tag: string, timeElapsed: number): integer, number

        getPath: function(self): string

        getFrameUV: function(self, frame: integer): number, number, number, number

        getId: function(self): integer

        getTagId: function(self, tag: string): integer

        getTagName: function(self, id: integer): string

        getFrameTagById: function(self, id: integer): FrameTag

        getSliceId: function(self, name: string): integer

        getSliceName: function(self, id: integer): string

        getSliceById: function(self, id: integer): Slice

        getNormalImage: function(self): love.graphics.Image

        getEmissionImage: function(self): love.graphics.Image

        getORMImage: function(self): love.graphics.Image

        generateNormalMap: function(self)

        getById: function(id: integer): SpriteSheet

        --- The sheet already built from `file`, or nil.
        ---
        --- A snapshot names a sprite's sheet by path. Without this, restoring
        --- one builds a second sheet for a file the process already has, and
        --- the same image ends up in two texture-array layers: restored and
        --- freshly spawned sprites of one sheet then never batch together.
        findByPath: function(file: string): SpriteSheet

        preloadAll: function()

        fromImage: function(
            image: love.graphics.Image,
            data: love.filesystem.FileData,
            path: string
        ): SpriteSheet

        fromFile: function(file: string, options?: LoadOptions): SpriteSheet

        fromConfig: function(image: love.graphics.Image, config: table, path: string): SpriteSheet

        builderFromImage: function(image: love.graphics.Image, data: love.filesystem.FileData, path: string): Builder

        fromTexture: function(texture: love.graphics.Texture, path?: string, options?: LoadOptions): SpriteSheet

        fromTextureFile: function(file: string, options?: LoadOptions): SpriteSheet

        builder: function(image: love.graphics.Image, path?: string): Builder
    end

    interface Builder
        frame: function(self, x: number, y: number, w: number, h: number, duration?: number): Builder

        tag: function(self, name: string, from: integer, to: integer, direction?: string): Builder

        slice: function(self, name: string, x: number, y: number, w: number, h: number): Builder

        sliceWithPivot: function(
            self, name: string, x: number, y: number, w: number, h: number,
            pivotX: number, pivotY: number
        ): Builder

        sliceRaw: function(self, name: string, data: string, keys: {SliceKey}): Builder

        normalImage: function(self, image: love.graphics.Image): Builder

        emissionImage: function(self, image: love.graphics.Image): Builder

        ormImage: function(self, image: love.graphics.Image): Builder

        loadMaterialMaps: function(self, options?: sprite_sheet.LoadOptions): Builder

        build: function(self): SpriteSheet
    end

    record LoadOptions
        generateNormal: boolean
    end
end

--- Builder implementation (implements sprite_sheet.Builder interface)
local record SpriteSheetBuilder is sprite_sheet.Builder
end

-- Export direction constants
sprite_sheet.Direction = DIRECTION

-------------------------------------------------------------------------------
-- Sheet registry (module-level, for ID-based lookups)
-------------------------------------------------------------------------------

local sheetRegistry: {integer: sprite_sheet.SpriteSheet} = {}
local nextSheetId: integer = 1

-- Sheets by the file they were built from, so a snapshot that names a path
-- resolves to the sheet the process already loaded rather than a duplicate.
local sheetsByPath: {string: sprite_sheet.SpriteSheet} = {}

local SpriteSheet <const> = sprite_sheet.SpriteSheet
local SHEET_MT <const>: metatable<sprite_sheet.SpriteSheet> = {__index = SpriteSheet}

--- Calculate timing table for a tag based on direction.
--- @param frames Array of frames with duration
--- @param from Start frame (1-indexed)
--- @param to End frame (1-indexed)
--- @param direction Direction constant (FORWARD, REVERSE, PINGPONG)
--- @return timingTable, totalDuration
local function calculateTimingTable(
    frames: {sprite_sheet.Frame},
    from: integer,
    to: integer,
    direction: integer
): {number}, number
    local timingTable: {number} = {}
    local accumulatedTime: number = 0

    if direction == DIRECTION_FORWARD then
        local index = 1
        for i = from, to do
            local frameData = frames[i]
            if frameData then
                accumulatedTime = accumulatedTime + frameData.duration
                timingTable[index] = accumulatedTime
                index = index + 1
            end
        end
    elseif direction == DIRECTION_REVERSE then
        local index = 1
        for i = to, from, -1 do
            local frameData = frames[i]
            if frameData then
                accumulatedTime = accumulatedTime + frameData.duration
                timingTable[index] = accumulatedTime
                index = index + 1
            end
        end
    else
        -- PINGPONG: forward then reverse, excluding duplicates at ends
        -- For frames 1-3: plays as [1, 2, 3, 2] then loops
        local index = 1
        -- Forward phase: from -> to
        for i = from, to do
            local frameData = frames[i]
            if frameData then
                accumulatedTime = accumulatedTime + frameData.duration
                timingTable[index] = accumulatedTime
                index = index + 1
            end
        end
        -- Reverse phase: to-1 -> from+1 (exclude endpoints to avoid double-playing)
        if to > from then
            for i = to - 1, from + 1, -1 do
                local frameData = frames[i]
                if frameData then
                    accumulatedTime = accumulatedTime + frameData.duration
                    timingTable[index] = accumulatedTime
                    index = index + 1
                end
            end
        end
    end

    return timingTable, accumulatedTime
end

--- Generate a normal map from sprite luminance (brightness as height).
--- Brighter pixels are treated as "higher", creating realistic lighting response.
local function generateNormalFromAlbedo(sourceData: love.image.ImageData, strength?: number): love.graphics.Image
    strength = strength or 2.0
    local w, h = sourceData:getDimensions()
    local normalData = love.image.newImageData(w, h)

    -- Get height from perceptual luminance
    local function getHeight(x: integer, y: integer): number
        x = math.max(0, math.min((w - 1) as integer, x))
        y = math.max(0, math.min((h - 1) as integer, y))
        local r, g, b, a = sourceData:getPixel(x, y)

        if a < 0.01 then return 0 end

        -- Perceptual luminance (how bright the pixel appears)
        local luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return luminance * a
    end

    -- Generate normals using Sobel gradient on luminance
    for y = 0, h - 1 do
        for x = 0, w - 1 do
            local _, _, _, a = sourceData:getPixel(x, y)

            if a < 0.01 then
                -- Transparent pixels: no normal data
                normalData:setPixel(x, y, 0.5, 0.5, 1.0, 0.0)
            else
                -- Calculate height gradient
                local left = getHeight((x - 1) as integer, y as integer)
                local right = getHeight((x + 1) as integer, y as integer)
                local up = getHeight(x as integer, (y - 1) as integer)
                local down = getHeight(x as integer, (y + 1) as integer)

                -- Gradient with strength multiplier
                local dx = (right - left) * strength
                local dy = (down - up) * strength

                -- Create normal vector and normalize
                local nx, ny, nz = -dx, -dy, 1.0
                local len = math.sqrt(nx*nx + ny*ny + nz*nz)
                nx, ny, nz = nx/len, ny/len, nz/len

                -- Convert from [-1,1] to [0,1] range
                local nr = nx * 0.5 + 0.5
                local ng = ny * 0.5 + 0.5
                local nb = nz * 0.5 + 0.5

                normalData:setPixel(x, y, nr, ng, nb, 1.0)
            end
        end
    end

    local normalImage = love.graphics.newImage(normalData)
    normalImage:setFilter("nearest", "nearest")
    return normalImage
end

function SpriteSheet:getSheetSize(): number, number
    return self._width, self._height
end

function SpriteSheet:getSpriteSize(): number, number
    return self._spriteWidth, self._spriteHeight
end

function SpriteSheet:getImage(): love.graphics.Image
    return self._image
end

function SpriteSheet:getPath(): string
    return self._path
end

function SpriteSheet:getQuad(frame: integer): love.graphics.Quad
    return self._quads[frame]
end

function SpriteSheet:getFrame(frame: integer): sprite_sheet.Frame
    if frame < 1 or frame > self._frameCount then
        return nil
    end

    return self._frames[frame]  -- Lua arrays are 1-indexed
end

function SpriteSheet:getFrameTag(tag: string): sprite_sheet.FrameTag
    return self._tags[tag] or self._defaultTag
end

function SpriteSheet:hasFrameTag(tag: string): boolean
    return self._tags[tag] ~= nil
end

function SpriteSheet:getSlice(name: string): sprite_sheet.Slice
    return self._slices[name]
end

function SpriteSheet:getFrameUV(frame: integer): number, number, number, number
    -- Convert 1-indexed frame to 0-indexed for FFI array
    -- Uses cached pointer to avoid C.cast() allocation on every access
    local uv = self._frameUVsPtr[frame - 1]
    return uv.u, uv.v, uv.w, uv.h
end

function SpriteSheet:getId(): integer
    return self._id
end

function SpriteSheet:getTagId(tag: string): integer
    if tag == "" then
        return 0  -- Default tag
    end
    return self._tagToId[tag] or 0
end

function SpriteSheet:getTagName(id: integer): string
    if id == 0 then
        return ""  -- Default tag
    end
    return self._idToTag[id] or ""
end

function SpriteSheet:getFrameTagById(id: integer): sprite_sheet.FrameTag
    if id == 0 then
        return self._defaultTag
    end
    local tagName = self._idToTag[id]
    if tagName then
        return self._tags[tagName]
    end
    return self._defaultTag
end

function SpriteSheet:getSliceId(name: string): integer
    return self._sliceToId[name] or 0
end

function SpriteSheet:getSliceName(id: integer): string
    return self._idToSlice[id]
end

function SpriteSheet:getSliceById(id: integer): sprite_sheet.Slice
    local name = self._idToSlice[id]
    if name then
        return self._slices[name]
    end
    return nil
end

function SpriteSheet:getNormalImage(): love.graphics.Image
    return self._normalImage
end

function SpriteSheet:getEmissionImage(): love.graphics.Image
    return self._emissionImage
end

function SpriteSheet:getORMImage(): love.graphics.Image
    return self._ormImage
end

function SpriteSheet:generateNormalMap()
    if not self._path or self._path == "" then
        error("Cannot generate normal map: sheet was not loaded from file")
    end
    local sourceData = love.image.newImageData(self._path)
    self._normalImage = generateNormalFromAlbedo(sourceData)
end

function SpriteSheet:setNormalImage(image: love.graphics.Image)
    self._normalImage = image
end

function SpriteSheet:setEmissionImage(image: love.graphics.Image)
    self._emissionImage = image
end

function SpriteSheet:setORMImage(image: love.graphics.Image)
    self._ormImage = image
end

-- Module-level function to get sheet by ID
function SpriteSheet.getById(id: integer): sprite_sheet.SpriteSheet
    return sheetRegistry[id]
end

function SpriteSheet.findByPath(file: string): sprite_sheet.SpriteSheet
    if not file or file == "" then return nil end
    return sheetsByPath[file]
end

function SpriteSheet.preloadAll()
    local mgr <const> = bucketmanager.get()
    if not mgr then return end
    for _, sheet in pairs(sheetRegistry) do
        mgr:allocate(
            sheet:getId(),
            sheet:getImage(),
            sheet:getNormalImage(),
            sheet:getEmissionImage(),
            sheet:getORMImage()
        )
    end
end

function SpriteSheet:getAnimationFrame(tag: string, timeElapsed: number): integer, number
    local frameTag = self:getFrameTag(tag)
    if not frameTag then
        error("Frame tag not found: " .. tag)
    end

    local duration, direction <const> = frameTag.duration, frameTag.direction
    local fromFrame, toFrame <const> = frameTag.from, frameTag.to

    -- Handle looping
    if timeElapsed > duration then
        timeElapsed = timeElapsed % duration
    end

    -- Use pre-calculated timing table for fast frame lookup
    local timingTable <const> = frameTag.timingTable
    local n <const> = #timingTable
    if n == 0 then
        error("Timing table not initialized for tag: " .. tag)
    end

    -- Linear search through timing table
    for i = 1, n do
        if timeElapsed <= timingTable[i] then
            if direction == DIRECTION_FORWARD then
                return fromFrame + i - 1, timeElapsed
            elseif direction == DIRECTION_REVERSE then
                return toFrame - i + 1, timeElapsed
            else
                -- PINGPONG: frames are stored as forward then reverse (minus duplicates)
                -- For frames 1-3: timing indices map to frames [1, 2, 3, 2]
                local frameCount = toFrame - fromFrame + 1
                if i <= frameCount then
                    -- Forward phase: index 1->frameCount maps to fromFrame->toFrame
                    return fromFrame + i - 1, timeElapsed
                else
                    -- Reverse phase: index frameCount+1 onwards maps to toFrame-1->fromFrame+1
                    local reverseIndex = i - frameCount
                    return toFrame - reverseIndex, timeElapsed
                end
            end
        end
    end

    return fromFrame, timeElapsed
end

-------------------------------------------------------------------------------
-- SpriteSheet creation functions
-------------------------------------------------------------------------------

local function configureBuilderFromAseprite(
    image: love.graphics.Image,
    config: table,
    path: string
): sprite_sheet.Builder
    local meta = assert(config.meta as table, "Missing meta section in Aseprite JSON")

    -- Parse frames from Aseprite JSON (supports both array and hash formats)
    local aseFramesRaw = assert(config.frames, "Missing frames in Aseprite JSON")
    local aseFrames: {table}

    -- Detect format: array has #frames > 0, hash doesn't
    if #(aseFramesRaw as {any}) > 0 then
        aseFrames = aseFramesRaw as {table}
    else
        -- Hash format: convert to array sorted by frame name
        local frameNames: {string} = {}
        local framesMap = aseFramesRaw as {string:table}
        local count = 0
        for frameName in pairs(framesMap) do
            count = count + 1
            frameNames[count] = frameName
        end
        table.sort(frameNames)

        local framesList: {table} = {}
        for i = 1, count do
            framesList[i] = framesMap[frameNames[i]]
        end
        aseFrames = framesList
    end

    local b = SpriteSheet.builder(image, path)

    -- Add frames
    local frameCount <const> = #aseFrames
    local spriteWidth: number
    local spriteHeight: number

    for i = 1, frameCount do
        local aseFrame <const> = aseFrames[i]
        local frameRect = assert(aseFrame.frame as table, "Missing frame.frame for frame " .. i)
        local x = assert(frameRect.x as number, "Missing frame.frame.x for frame " .. i)
        local y = assert(frameRect.y as number, "Missing frame.frame.y for frame " .. i)
        local w = assert(frameRect.w as number, "Missing frame.frame.w for frame " .. i)
        local h = assert(frameRect.h as number, "Missing frame.frame.h for frame " .. i)
        local duration = (aseFrame.duration as number) or 100  -- ms

        -- Validate uniform frame size (required for GPU animation)
        if i == 1 then
            spriteWidth = w
            spriteHeight = h
        elseif w ~= spriteWidth or h ~= spriteHeight then
            error(string.format(
                "Packed sprite sheet not supported: frame %d is %dx%d, expected %dx%d. " ..
                "Export from Aseprite using Sheet Type 'Horizontal Strip' or 'By Rows/Columns', not 'Packed'.",
                i, w as integer, h as integer, spriteWidth as integer, spriteHeight as integer
            ))
        end

        b:frame(x, y, w, h, duration)
    end

    -- Add tags (Aseprite uses 0-indexed, builder expects 0-indexed)
    local aseFrameTags = (meta.frameTags as {table}) or {}
    for i = 1, #aseFrameTags do
        local aseTag <const> = aseFrameTags[i]
        local tagName = assert(aseTag.name as string, "Missing frameTags.name")
        local from = assert(aseTag.from as integer, "Missing frameTags.from for tag " .. tagName)
        local to = assert(aseTag.to as integer, "Missing frameTags.to for tag " .. tagName)
        local direction = (aseTag.direction as string) or "forward"
        b:tag(tagName, from, to, direction)
    end

    -- Add slices
    local aseSlices = (meta.slices as {table}) or {}
    for i = 1, #aseSlices do
        local aseSlice <const> = aseSlices[i]
        local sliceName = assert(aseSlice.name as string, "Missing slices.name")
        local sliceKeys: {sprite_sheet.SliceKey} = {}
        local aseKeys = (aseSlice.keys as {table}) or {}

        for j = 1, #aseKeys do
            local aseKey <const> = aseKeys[j]
            local frame = assert(aseKey.frame as integer, "Missing slices.keys.frame") + 1
            local bounds = assert(aseKey.bounds as table, "Missing slices.keys.bounds")

            local sliceKey: sprite_sheet.SliceKey = {
                frame = frame,
                x = assert(bounds.x as number, "Missing slices.keys.bounds.x"),
                y = assert(bounds.y as number, "Missing slices.keys.bounds.y"),
                w = assert(bounds.w as number, "Missing slices.keys.bounds.w"),
                h = assert(bounds.h as number, "Missing slices.keys.bounds.h"),
                centerX = 0,
                centerY = 0,
                pivotX = 0,
                pivotY = 0,
                hasCenter = false,
                hasPivot = false
            }

            local center = aseKey.center as table
            if center then
                sliceKey.centerX = assert(center.x as number, "Missing slices.keys.center.x")
                sliceKey.centerY = assert(center.y as number, "Missing slices.keys.center.y")
                sliceKey.hasCenter = true
            end

            local pivot = aseKey.pivot as table
            if pivot then
                sliceKey.pivotX = assert(pivot.x as number, "Missing slices.keys.pivot.x")
                sliceKey.pivotY = assert(pivot.y as number, "Missing slices.keys.pivot.y")
                sliceKey.hasPivot = true
            end

            sliceKeys[j] = sliceKey
        end

        b:sliceRaw(sliceName, (aseSlice.data as string) or "", sliceKeys)
    end

    return b
end

function SpriteSheet.fromConfig(
    image: love.graphics.Image,
    config: table,
    path: string
): sprite_sheet.SpriteSheet
    return configureBuilderFromAseprite(image, config, path):build()
end

function SpriteSheet.fromImage(
    image: love.graphics.Image,
    data: love.filesystem.FileData,
    path: string
): sprite_sheet.SpriteSheet
    local jsonText = (data as love.Data):getString()
    local jsonData = json.parse(jsonText) as table
    return SpriteSheet.fromConfig(image, jsonData, path)
end

function SpriteSheet.builderFromImage(
    image: love.graphics.Image,
    data: love.filesystem.FileData,
    path: string
): sprite_sheet.Builder
    local jsonText = (data as love.Data):getString()
    local jsonData = json.parse(jsonText) as table
    return configureBuilderFromAseprite(image, jsonData, path)
end

function SpriteSheet.fromFile(file: string, options?: sprite_sheet.LoadOptions): sprite_sheet.SpriteSheet
    local image = love.graphics.newImage(file)
    local jsonPath = file:gsub("%.[^.]+$", "") .. ".json"
    local data, dataErr = love.filesystem.newFileData(jsonPath)
    if not data then
        error("Failed to load sprite sheet data file: " .. dataErr)
    end
    local jsonText = (data as love.Data):getString()
    local jsonData = json.parse(jsonText) as table
    return configureBuilderFromAseprite(image, jsonData, file)
        :loadMaterialMaps(options)
        :build()
end

function SpriteSheet.fromTexture(
    texture: love.graphics.Texture,
    path?: string,
    options?: sprite_sheet.LoadOptions
): sprite_sheet.SpriteSheet
    local image = texture as love.graphics.Image
    local width, height = texture:getDimensions()
    local b = SpriteSheet.builder(image, path or "")
        :frame(0, 0, width, height, 1000000)  -- 1000 second duration since it's a static image
    if path and path ~= "" then
        b:loadMaterialMaps(options)
    end
    return b:build()
end

function SpriteSheet.fromTextureFile(
    file: string,
    options?: sprite_sheet.LoadOptions
): sprite_sheet.SpriteSheet
    local image = love.graphics.newImage(file)
    return SpriteSheet.fromTexture(image as love.graphics.Texture, file, options)
end

--------------------------------------------------------------------------------
-- Builder implementation
--------------------------------------------------------------------------------

local record BuilderTagData
    from: integer
    to: integer
    direction: integer
end

local record BuilderImpl
    _image: love.graphics.Image
    _path: string
    _frames: {sprite_sheet.Frame}
    _tags: {string: BuilderTagData}
    _slices: {string: sprite_sheet.Slice}
    _normalImage: love.graphics.Image
    _emissionImage: love.graphics.Image
    _ormImage: love.graphics.Image
end

local BUILDER_MT <const>: metatable<BuilderImpl> = {__index = SpriteSheetBuilder}

function SpriteSheetBuilder:frame(x: number, y: number, w: number, h: number, duration?: number): sprite_sheet.Builder
    local impl = self as BuilderImpl
    impl._frames[#impl._frames + 1] = {
        x = x,
        y = y,
        w = w,
        h = h,
        duration = (duration or 100) / 1000  -- Convert ms to seconds
    }
    return self
end

function SpriteSheetBuilder:tag(name: string, from: integer, to: integer, direction?: string): sprite_sheet.Builder
    local impl = self as BuilderImpl
    local dir = DIRECTION_FORWARD
    if direction == "reverse" then
        dir = DIRECTION_REVERSE
    elseif direction == "pingpong" then
        dir = DIRECTION.PINGPONG
    end
    impl._tags[name] = { from = from + 1, to = to + 1, direction = dir }  -- Convert to 1-based
    return self
end

function SpriteSheetBuilder:slice(
    name: string, x: number, y: number, w: number, h: number
): sprite_sheet.Builder
    local impl = self as BuilderImpl
    impl._slices[name] = {
        data = "",
        keys = {
            {
                frame = 1,
                x = x,
                y = y,
                w = w,
                h = h,
                hasCenter = false,
                centerX = 0,
                centerY = 0,
                hasPivot = false,
                pivotX = 0,
                pivotY = 0,
            }
        }
    }
    return self
end

function SpriteSheetBuilder:sliceWithPivot(
    name: string, x: number, y: number, w: number, h: number,
    pivotX: number, pivotY: number
): sprite_sheet.Builder
    local impl = self as BuilderImpl
    impl._slices[name] = {
        data = "",
        keys = {
            {
                frame = 1,
                x = x,
                y = y,
                w = w,
                h = h,
                hasCenter = false,
                centerX = 0,
                centerY = 0,
                hasPivot = true,
                pivotX = pivotX,
                pivotY = pivotY,
            }
        }
    }
    return self
end

function SpriteSheetBuilder:sliceRaw(
    name: string, data: string, keys: {sprite_sheet.SliceKey}
): sprite_sheet.Builder
    local impl = self as BuilderImpl
    impl._slices[name] = {
        data = data,
        keys = keys
    }
    return self
end

function SpriteSheetBuilder:normalImage(image: love.graphics.Image): sprite_sheet.Builder
    local impl = self as BuilderImpl
    impl._normalImage = image
    return self
end

function SpriteSheetBuilder:emissionImage(image: love.graphics.Image): sprite_sheet.Builder
    local impl = self as BuilderImpl
    impl._emissionImage = image
    return self
end

function SpriteSheetBuilder:ormImage(image: love.graphics.Image): sprite_sheet.Builder
    local impl = self as BuilderImpl
    impl._ormImage = image
    return self
end

function SpriteSheetBuilder:loadMaterialMaps(options?: sprite_sheet.LoadOptions): sprite_sheet.Builder
    local impl = self as BuilderImpl
    local basePath = impl._path
    if not basePath or basePath == "" then
        return self
    end

    options = options or {}
    local baseName = basePath:gsub("%.[^.]+$", "")
    local normalPath = baseName .. "_n.png"
    local emissionPath = baseName .. "_e.png"

    -- Normal map (_n convention, or generate from alpha)
    if love.filesystem.getInfo(normalPath) then
        impl._normalImage = love.graphics.newImage(normalPath)
        impl._normalImage:setFilter("nearest", "nearest")
    elseif options.generateNormal then
        local sourceData = love.image.newImageData(basePath)
        impl._normalImage = generateNormalFromAlbedo(sourceData)
    end

    -- Emission map (_e convention)
    if love.filesystem.getInfo(emissionPath) then
        impl._emissionImage = love.graphics.newImage(emissionPath)
        impl._emissionImage:setFilter("nearest", "nearest")
    end

    -- ORM map: try packed _orm.png first, then composite from _ao/_rough/_metal
    local ormPath = baseName .. "_orm.png"
    if love.filesystem.getInfo(ormPath) then
        impl._ormImage = love.graphics.newImage(ormPath)
        impl._ormImage:setFilter("nearest", "nearest")
    else
        local aoPath = baseName .. "_ao.png"
        local roughPath = baseName .. "_rough.png"
        local metalPath = baseName .. "_metal.png"
        local hasAO = love.filesystem.getInfo(aoPath) ~= nil
        local hasRough = love.filesystem.getInfo(roughPath) ~= nil
        local hasMetal = love.filesystem.getInfo(metalPath) ~= nil

        if hasAO or hasRough or hasMetal then
            local aoData: love.image.ImageData = hasAO and love.image.newImageData(aoPath) or nil
            local roughData: love.image.ImageData = hasRough and love.image.newImageData(roughPath) or nil
            local metalData: love.image.ImageData = hasMetal and love.image.newImageData(metalPath) or nil

            -- Determine dimensions from the albedo image
            local w, h = (impl._image as love.graphics.Texture):getDimensions()
            local ormData = love.image.newImageData(w as integer, h as integer)
            ormData:mapPixel(function(x: number, y: number, _r: number, _g: number, _b: number, _a: number): (number, number, number, number)
                local xi, yi = x as integer, y as integer
                local ao = aoData and ({aoData:getPixel(xi, yi)})[1] or 1.0
                local rough = roughData and ({roughData:getPixel(xi, yi)})[1] or 0.5
                local metal = metalData and ({metalData:getPixel(xi, yi)})[1] or 0.0
                return ao as number, rough as number, metal as number, 0.0
            end)
            impl._ormImage = love.graphics.newImage(ormData)
            impl._ormImage:setFilter("nearest", "nearest")
        end
    end

    return self
end

function SpriteSheetBuilder:build(): sprite_sheet.SpriteSheet
    local impl = self as BuilderImpl
    local image = impl._image
    local frames = impl._frames
    local frameCount = #frames

    if frameCount == 0 then
        error("SpriteSheet.Builder: must add at least one frame")
    end

    local width, height = (image as love.graphics.Texture):getDimensions()

    -- Determine sprite size from first frame
    local spriteWidth = frames[1].w
    local spriteHeight = frames[1].h

    -- Build quads and UV data
    local quads: {integer: love.graphics.Quad} = {}
    local frameUVs = C.new("FrameUV[?]", frameCount)
    local frameUVsPtr = C.cast("FrameUV*", frameUVs) as {integer: FrameUVFFI}

    for i, f in ipairs(frames) do
        quads[i] = love.graphics.newQuad(f.x, f.y, f.w, f.h, width, height)
        local uv = frameUVsPtr[i - 1]
        uv.u = f.x / width
        uv.v = f.y / height
        uv.w = f.w / width
        uv.h = f.h / height
    end

    -- Build tags with timing tables
    local tags: {string: sprite_sheet.FrameTag} = {}
    local tagToId: {string: integer} = {}
    local idToTag: {integer: string} = {}
    local tagCount = 0

    for name, tagData in pairs(impl._tags) do
        tagCount = tagCount + 1
        tagToId[name] = tagCount
        idToTag[tagCount] = name

        local timingTable, tagDuration = calculateTimingTable(
            frames, tagData.from, tagData.to, tagData.direction
        )

        tags[name] = {
            from = tagData.from,
            to = tagData.to,
            direction = tagData.direction,
            duration = tagDuration,
            timingTable = timingTable,
        }
    end

    -- Build slices with ID lookup
    local sliceToId: {string: integer} = {}
    local idToSlice: {integer: string} = {}
    local sliceCount = 0

    for name, _ in pairs(impl._slices) do
        sliceCount = sliceCount + 1
        sliceToId[name] = sliceCount
        idToSlice[sliceCount] = name
    end

    -- Calculate default tag duration
    local defaultDuration = 0.0
    local defaultTimingTable: {number} = {}
    for i = 1, frameCount do
        defaultDuration = defaultDuration + frames[i].duration
        defaultTimingTable[i] = defaultDuration
    end

    -- Allocate sheet ID
    local sheetId = nextSheetId
    nextSheetId = nextSheetId + 1

    local sheetImpl: SpriteSheet = setmetatable({
        _id = sheetId,
        _image = image,
        _width = width,
        _height = height,
        _spriteWidth = spriteWidth,
        _spriteHeight = spriteHeight,
        _frames = frames,
        _frameCount = frameCount,
        _tags = tags,
        _slices = impl._slices,
        _tagToId = tagToId,
        _idToTag = idToTag,
        _tagCount = tagCount,
        _sliceToId = sliceToId,
        _idToSlice = idToSlice,
        _sliceCount = sliceCount,
        _quads = quads,
        _path = impl._path,
        _frameUVs = frameUVs,
        _frameUVsPtr = frameUVsPtr,
        _normalImage = impl._normalImage,
        _emissionImage = impl._emissionImage,
        _ormImage = impl._ormImage,
        _defaultTag = {
            from = 1,
            to = frameCount,
            direction = DIRECTION_FORWARD,
            duration = defaultDuration,
            timingTable = defaultTimingTable,
        }
    }, SHEET_MT)

    sheetRegistry[sheetId] = sheetImpl
    if sheetImpl._path ~= "" then
        sheetsByPath[sheetImpl._path] = sheetImpl
    end
    return sheetImpl
end

function SpriteSheet.builder(image: love.graphics.Image, path?: string): sprite_sheet.Builder
    return setmetatable({
        _image = image,
        _path = path or "",
        _frames = {},
        _tags = {},
        _slices = {},
    } as BuilderImpl, BUILDER_MT) as sprite_sheet.Builder
end

return sprite_sheet
