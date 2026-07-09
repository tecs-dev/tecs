--- Frame timing buffer for GPU-side variable per-frame animation timing.
---
--- Maintains a registry of animation tag timings and a GPU buffer containing
--- cumulative frame times. Sprites reference into this buffer via animTimingOffset.

local C <const> = require("ffi")
local retire <const> = require("tecs2d.gfx.internal.gpu.retire")

local record timing_buffer
    --- Per-tag metadata (frameCount + totalDuration).
    record TagInfo
        offset: integer
        frameCount: integer
        totalDuration: number
    end

    --- Frame timing registry and GPU buffer manager.
    record TimingBuffer
        --- CPU-side timing data (cumulative times per registered tag)
        timings: {number}

        --- Map from (sheetPath, tagName) -> tag info
        tagInfos: {string: TagInfo}

        --- Current write position in timings array
        nextOffset: integer

        --- GPU buffer (created lazily on first upload)
        gpuBuffer: love.graphics.Buffer

        --- FFI-backed byteData matching the GPU buffer capacity (for direct upload)
        byteData: love.data.ByteData

        --- Capacity (in floats) of the current byteData / gpuBuffer
        bufferCapacity: integer

        --- Whether buffer needs upload
        dirty: boolean

        --- Register a tag's frame timings and get the offset.
        --- Returns existing offset if already registered (errors if frame
        --- shape differs from the original registration).
        --- @param sheetPath Unique identifier for the sheet
        --- @param tagName Animation tag name
        --- @param frameDurations Array of per-frame durations in seconds
        --- @return offset Index into timing buffer, totalDuration Sum of all durations
        registerTag: function(self, sheetPath: string, tagName: string, frameDurations: {number}): integer, number

        --- Get the GPU buffer, creating/uploading if needed.
        --- @return The GPU buffer ready for shader binding
        getBuffer: function(self): love.graphics.Buffer

        --- Check if a tag is already registered.
        --- @return offset if registered, nil otherwise
        getTagOffset: function(self, sheetPath: string, tagName: string): integer

        --- Clear all registered timings (call on scene change if needed).
        clear: function(self)

        --- Get the cumulative time at the start of a frame.
        --- @param offset Timing buffer offset for this animation
        --- @param frame Frame index (0-based)
        --- @return Time in seconds when this frame starts
        getFrameStartTime: function(self, offset: integer, frame: integer): number

        --- Get the frame index for a given local time within the animation.
        --- @param offset Timing buffer offset for this animation
        --- @param frameCount Number of frames in the animation
        --- @param localTime Time elapsed since animation start (already looped)
        --- @return Frame index (0-based)
        getFrameAtTime: function(self, offset: integer, frameCount: integer, localTime: number): integer
    end

    --- Create a new timing buffer.
    new: function(): TimingBuffer

    --- Global singleton instance (most games only need one).
    global: TimingBuffer
end

local TimingBuffer <const> = timing_buffer.TimingBuffer
local TIMING_MT <const>: metatable<TimingBuffer> = { __index = TimingBuffer }

local SIZEOF_FLOAT <const> = C.sizeof("float")

function timing_buffer.new(): TimingBuffer
    local tb: TimingBuffer = {
        timings = {},
        tagInfos = {},
        nextOffset = 0,
        gpuBuffer = nil,
        byteData = nil,
        bufferCapacity = 0,
        dirty = false,
    }
    return setmetatable(tb, TIMING_MT)
end

--- Generate a unique key for a (sheet, tag) pair.
local function makeKey(sheetPath: string, tagName: string): string
    return sheetPath .. "\0" .. tagName
end

function TimingBuffer:registerTag(sheetPath: string, tagName: string, frameDurations: {number}): integer, number
    local key = makeKey(sheetPath, tagName)
    local frameCount = #frameDurations

    -- Check if already registered
    local info = self.tagInfos[key]
    if info then
        if info.frameCount ~= frameCount then
            error("timing_buffer: tag '" .. tagName ..
                "' re-registered with different frame count (was " ..
                info.frameCount .. ", now " .. frameCount .. ")")
        end
        return info.offset, info.totalDuration
    end

    -- Register new tag
    local offset = self.nextOffset
    local cumulative: number = 0

    for i = 1, frameCount do
        cumulative = cumulative + frameDurations[i]
        self.timings[offset + i] = cumulative
    end

    self.tagInfos[key] = {
        offset = offset,
        frameCount = frameCount,
        totalDuration = cumulative,
    }
    self.nextOffset = offset + frameCount
    self.dirty = true

    return offset, cumulative  -- cumulative equals the tag's totalDuration
end

function TimingBuffer:getTagOffset(sheetPath: string, tagName: string): integer
    local key = makeKey(sheetPath, tagName)
    local info = self.tagInfos[key]
    return info and info.offset
end

function TimingBuffer:getBuffer(): love.graphics.Buffer
    if not self.dirty and self.gpuBuffer then
        return self.gpuBuffer
    end

    -- Use at least 1 element so we always have a valid GPU buffer
    -- bound; the dummy element is written only to the upload buffer,
    -- never into self.timings.
    local count = self.nextOffset
    local uploadCount = count > 0 and count or 1

    -- (Re)allocate byteData + GPU buffer when capacity grows. The
    -- replaced GPU buffer may still be referenced by in-flight work;
    -- release it through the deferred retire list.
    if self.bufferCapacity < uploadCount then
        retire.push(self.gpuBuffer)
        self.byteData = love.data.newByteData(uploadCount * SIZEOF_FLOAT)
        self.gpuBuffer = love.graphics.newBuffer(
            {{format = "float"}},
            uploadCount,
            {usage = "static", shaderstorage = true}
        )
        self.bufferCapacity = uploadCount
    end

    -- Write cumulative timings directly into the ByteData via FFI.
    local ptr = C.cast("float*", self.byteData:getFFIPointer()) as {integer: number}
    if count > 0 then
        for i = 1, count do
            ptr[i - 1] = self.timings[i] or 0
        end
    else
        ptr[0] = 0  -- dummy value for empty buffer
    end

    self.gpuBuffer:setArrayData(self.byteData)
    self.dirty = false
    return self.gpuBuffer
end

function TimingBuffer:getFrameStartTime(offset: integer, frame: integer): number
    -- Frame 0 starts at time 0
    if frame <= 0 then
        return 0
    end
    -- Frame N starts at cumulative time of frame N-1
    return self.timings[offset + frame] or 0
end

function TimingBuffer:getFrameAtTime(offset: integer, frameCount: integer, localTime: number): integer
    -- Handle uninitialized animation data
    if frameCount <= 0 then
        return 0
    end

    -- Same algorithm as GPU shader: linear search through cumulative times
    for i = 1, frameCount do
        local cumulativeTime = self.timings[offset + i]
        -- Handle missing timing data gracefully
        if cumulativeTime == nil then
            return 0
        end
        if localTime < cumulativeTime then
            return i - 1  -- 0-based frame index
        end
    end
    -- Fallback to last frame
    return frameCount - 1
end

function TimingBuffer:clear()
    self.timings = {}
    self.tagInfos = {}
    self.nextOffset = 0
    self.dirty = true
    -- Don't destroy gpuBuffer/byteData, they can be reused
end

-- Create global singleton
timing_buffer.global = timing_buffer.new()

return timing_buffer
