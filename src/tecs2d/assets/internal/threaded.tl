local tecs <const> = require("tecs")
local types <const> = require("tecs2d.assets.types")
local sprite_sheet <const> = require("tecs2d.gfx.internal.sprite.sheet")
local bmfont <const> = require("tecs2d.gfx.bmfont")
local json <const> = require("tecs.utils.json")
local tiled_parser <const> = require("tecs2d.tiled.internal.parser")
local tiled_types <const> = require("tecs2d.tiled.types")

local LOGGER <const> = require("tecs.utils.logging").getLogger("tecs2d.assets")


-- Worker code is loaded lazily when AssetManager is first created. Example
-- builds symlink build/tecs2d/assets/internal to build/internal so
-- love.filesystem can read internal/worker.lua at runtime.
local WORKER_CODE: string = nil
local WORKER_PATH <const> = "internal/worker.lua"

local function getWorkerCode(): string
    if WORKER_CODE then
        return WORKER_CODE
    end

    WORKER_CODE = love.filesystem.read(WORKER_PATH)
    if not WORKER_CODE then
        error("Could not load assets worker from '" .. WORKER_PATH .. "'. " ..
              "Copy build/tecs/assets/internal/worker.lua to your game's internal/ folder.")
    end
    return WORKER_CODE
end


--- A module for asynchronously loading assets in threads for Love2D games.
---
--- Assets are loaded in a thread pool based on the number of CPU cores.
--- The thread-pool is capped at 4 threads.
local record threaded

    --- An asset manager used to asynchronously load assets in threads.
    record AssetManager is types.AssetManager
        _root: string
        _dispatcher: tecs.MessageBus
        _nextId: integer
        _pushChannel: love.thread.Channel
        _pullChannel: love.thread.Channel
        _runningTasks: {integer: Handle<any>}
        _threads: {love.thread.Thread}
        _cache: {string: Handle<any>}
        _pinnedHandles: {Handle<any>}
        _runningCount: integer
        _completedCount: integer
        -- Maps handler objects to loader functions
        _loaderRegistry: {types.AssetHandler<any>: function(string): Handle<any>}
        _hasEmittedInitialLoad: boolean
        _hasCalledUpdate: boolean
        _getNextId: function(self): integer
    end

    --- Event emitted when the initial load completes.
    record InitialLoadComplete is tecs.Event
        metamethod __call: function(self): InitialLoadComplete
    end

    --- Event emitted when a handle completes loading.
    record HandleComplete is tecs.Event
        handle: Handle<any>
        metamethod __call: function(self, handle: Handle<any>): HandleComplete
    end

    --- Creates a new asset manager.
    ---
    --- @param root The root directory to load assets from.
    --- @return a new asset manager.
    new: function(root: string): AssetManager
end

local type AssetManager = threaded.AssetManager
local type Handle = types.Handle

--------------------------------------------------------------------------------
-- Handle implementation
--------------------------------------------------------------------------------

--- A HandleImpl wraps an asset loading operation.
local record HandleImpl<T> is Handle<T>
    id: integer
    isComplete: boolean
    err: string

    _value: T
    _hasBlockedOnce: boolean
    _action: string
    _path: string
    _args: {any}
    _channelId: number
    _assetManager: AssetManager
    _cacheKey: string
end

--- Build a cache key that distinguishes (action, path, extra args). Keying
--- on path alone collapses distinct requests: loadFile("foo.json") would
--- alias loadJson("foo.json"), and loadFont(p, size=12) would alias
--- loadFont(p, size=24).
local function makeCacheKey(action: string, path: string, extraArgs: {any}, extraStart: integer): string
    local parts: {string} = {action, path}
    for i = extraStart, #extraArgs do
        parts[#parts + 1] = tostring(extraArgs[i])
    end
    return table.concat(parts, "|")
end

-- Forward declare the metatable
local HANDLE_MT: metatable<HandleImpl>

function HandleImpl._new<T>(
    action: string,
    path: string,
    args: {any},
    id: integer,
    channelId: number,
    assetManager: AssetManager
): HandleImpl<T>
    local self: HandleImpl<T> = {
        id = id,
        isComplete = false,
        _action = action,
        _path = path,
        _args = args,
        _channelId = channelId,
        _assetManager = assetManager,
    }
    return setmetatable(self, HANDLE_MT as metatable<HandleImpl<T>>) as HandleImpl<T>
end

function HandleImpl:_setResult<T>(value: T, err: string)
    self._value = value
    self.err = err
    self.isComplete = true

    -- Cache on the outer table to avoid __index
    rawset(self as table, "value", value)
    rawset(self as table, "err", err)
    rawset(self as table, "isComplete", true)

    -- Emit completion event at handle's address
    self._assetManager._dispatcher:emit(self.id, threaded.HandleComplete(self as Handle<any>))
end

function HandleImpl:observe<T>(listener: function(Handle<T>))
    if self.isComplete then
        listener(self)
    else
        -- Observe at handle's address, unwrap the event to get the handle
        self._assetManager._dispatcher:observeOnce(self.id, threaded.HandleComplete, function(e: threaded.HandleComplete)
            listener(e.handle as Handle<T>)
        end)
    end
end

function HandleImpl:pin()
    -- Add this handle to the pinned list to prevent garbage collection
    table.insert(self._assetManager._pinnedHandles, self as Handle<any>)
end

function HandleImpl:map<U>(transform: function(T): U): Handle<U>
    -- Create a new handle that waits for this one to complete, then transforms the result
    local mappedHandle: HandleImpl<U> = setmetatable({
        id = self._assetManager:_getNextId(),
        isComplete = false,
        err = nil,
        _value = nil,
        _hasBlockedOnce = false,
        _action = "map",
        _path = self._path,
        _args = {},
        _channelId = 0,
        _assetManager = self._assetManager
    }, HANDLE_MT as metatable<HandleImpl<U>>)

    -- When this handle completes, transform and complete the mapped handle
    self:observe(function(originalHandle)
        local handle = originalHandle as Handle<T>
        if handle.err then
            mappedHandle:_setResult(nil as U, handle.err)
        else
            local success, result = pcall(transform, handle.value)
            if success then
                mappedHandle:_setResult(result, nil)
            else
                mappedHandle:_setResult(nil as U, "Transform error: " .. tostring(result))
            end
        end
    end)

    return mappedHandle as Handle<U>
end

function HandleImpl:flatMap<U>(transform: function(T): Handle<U>): Handle<U>
    -- Create a new handle that waits for this one to complete,
    -- then waits for the inner handle returned by the transform
    local flatMappedHandle: HandleImpl<U> = setmetatable({
        id = self._assetManager:_getNextId(),
        isComplete = false,
        err = nil,
        _value = nil,
        _hasBlockedOnce = false,
        _action = "flatMap",
        _path = self._path,
        _args = {},
        _channelId = 0,
        _assetManager = self._assetManager
    }, HANDLE_MT as metatable<HandleImpl<U>>)

    -- When this handle completes, call transform to get the inner handle
    self:observe(function(originalHandle)
        local handle = originalHandle as Handle<T>
        if handle.err then
            flatMappedHandle:_setResult(nil as U, handle.err)
        else
            local success, innerHandle = pcall(transform, handle.value)
            if not success then
                flatMappedHandle:_setResult(nil as U, "Transform error: " .. tostring(innerHandle))
            else
                -- When the inner handle completes, complete the flat-mapped handle
                (innerHandle as Handle<U>):observe(function(inner: Handle<U>)
                    if inner.err then
                        flatMappedHandle:_setResult(nil as U, inner.err)
                    else
                        flatMappedHandle:_setResult(inner.value, nil)
                    end
                end)
            end
        end
    end)

    return flatMappedHandle as Handle<U>
end

function HandleImpl:handle<U>(fn: function(T, any): U): Handle<U>
    -- Create a new handle that always calls fn with (value, err)
    local handledHandle: HandleImpl<U> = setmetatable({
        id = self._assetManager:_getNextId(),
        isComplete = false,
        err = nil,
        _value = nil,
        _hasBlockedOnce = false,
        _action = "handle",
        _path = self._path,
        _args = {},
        _channelId = 0,
        _assetManager = self._assetManager
    }, HANDLE_MT as metatable<HandleImpl<U>>)

    -- When this handle completes, call fn with both value and error
    self:observe(function(originalHandle)
        local h = originalHandle as HandleImpl<T>
        local success, result = pcall(fn, h._value, h.err)
        if success then
            handledHandle:_setResult(result, nil)
        else
            handledHandle:_setResult(nil as U, "Handle error: " .. tostring(result))
        end
    end)

    return handledHandle as Handle<U>
end

-- Define the metatable with proper typing
HANDLE_MT = {
    __index = function(self: HandleImpl<any>, key: string): any
        if key == "value" then
            -- First access to value triggers blocking
            if not self.isComplete then
                if self._assetManager then
                    -- Block until complete
                    while not self.isComplete and self._assetManager:update() do end
                    self._assetManager = nil
                    if not self.isComplete then
                        -- Set error state
                        self.err = "Unable to complete operation " .. self.id
                        self.isComplete = true
                    end
                end

                -- Cache the results directly on the table to bypass __index next time
                rawset(self as table, "value", self._value)
                rawset(self as table, "err", self.err)
                rawset(self as table, "isComplete", self.isComplete)
            end

            if self.err then
                error("Operation failed to '" .. self._action .. "' for `" ..
                      self._path .. "`: " .. self.err)
            end

            return self._value
        elseif key == "err" then
            -- Return cached value or nil (no recursion - use rawget, not self.err)
            return rawget(self as table, "err")
        elseif key == "isComplete" then
            -- Return cached value or false (no recursion - use rawget, not self.isComplete)
            local val = rawget(self as table, "isComplete")
            return val ~= nil and val or false
        end
        return (HandleImpl as {string:any})[key]
    end
} as metatable<HandleImpl>

--------------------------------------------------------------------------------
-- Asset manager implementation
--------------------------------------------------------------------------------

local ASSET_MANAGER_MT <const>: metatable<AssetManager> = {
    __index = AssetManager
}

-- Monotonic counter so each AssetManager gets its own worker channels.
-- love.thread.getChannel("taskchannel") returns the SAME channel across
-- all callers, so without per-manager names a second AssetManager would
-- consume the first one's results (and its shutdown would kill the first
-- manager's workers via shared sentinel pushes).
local _nextManagerId: integer = 0

function AssetManager.new(root: string): AssetManager
    _nextManagerId = _nextManagerId + 1
    local mgrId = _nextManagerId
    local taskChannelName = "tecs2d.assets.task." .. mgrId
    local resultChannelName = "tecs2d.assets.result." .. mgrId

    local self: AssetManager = {
        _root = root,
        _dispatcher = tecs.newMessageBus(),
        _nextId = 0,
        _pushChannel = love.thread.getChannel(taskChannelName),
        _pullChannel = love.thread.getChannel(resultChannelName),
        _runningTasks = {},
        _cache = setmetatable({}, {__mode = "v"}),
        _pinnedHandles = {},
        _runningCount = 0,
        _completedCount = 0,
        _loaderRegistry = setmetatable({}, {__mode = "k"}),
        _hasEmittedInitialLoad = false,
        _hasCalledUpdate = false,
    }

    -- Start worker threads
    local threadCount = math.min(4, love.system.getProcessorCount())
    self._threads = {}
    for _ = 1, threadCount do
        local thread = love.thread.newThread(getWorkerCode())
        thread:start(taskChannelName, resultChannelName)
        table.insert(self._threads, thread)
    end

    return setmetatable(self, ASSET_MANAGER_MT) as AssetManager
end

function AssetManager:resolvePath(...: string): string
    local parts = {...}

    if #parts == 0 then
        return self._root
    end

    -- Love2D handles path security and normalization for us
    -- Just join with forward slashes (works on all platforms)
    return self._root .. "/" .. table.concat(parts, "/")
end

function AssetManager:setRoot(root: string)
    self._root = root
end

function AssetManager:getRoot(): string
    return self._root
end

function AssetManager:_getNextId(): integer
    self._nextId = self._nextId + 1
    return self._nextId
end

function AssetManager:registerAssetHandler<T>(handler: types.AssetHandler<T>, loader: function(string): Handle<T>)
    self._loaderRegistry[handler] = loader as function(string): Handle<any>
end

function AssetManager:load<T>(handler: types.AssetHandler<T>, path: string): Handle<T>
    local loader = assert(
        (self._loaderRegistry[handler] as function(string): Handle<T>),
        "No loader registered for handler type")

    local resolvedPath = self:resolvePath(path)
    -- Include the handler's identity so two different custom handlers on the
    -- same path don't alias (e.g., "load as LevelData" vs "load as CSV").
    local key = tostring(handler) .. "|" .. resolvedPath
    local cached = self._cache[key] as Handle<T>

    if not cached then
        cached = loader(resolvedPath)
        self._cache[key] = cached as Handle<any>
    end

    return cached
end

local function createHandle<T>(self: AssetManager, args: {any}): Handle<T>
    local action = args[1] as string
    local inputPath = args[2] as string
    local path = self:resolvePath(inputPath)

    args[2] = path

    -- Cache key includes the action and any loader-specific extra args so
    -- distinct requests (loadFile vs loadJson, loadFont size 12 vs 24) stay
    -- separate entries.
    local cacheKey = makeCacheKey(action, path, args, 3)

    local cache = self._cache[cacheKey]
    if cache then
        return cache as Handle<T>
    else
        self._runningCount = self._runningCount + 1
        local id = self:_getNextId()
        table.insert(args, 1, id)
        local channelId = self._pushChannel:push(args)
        local handleResult = HandleImpl._new(action, path, args, id, channelId, self)
        handleResult._cacheKey = cacheKey
        self._runningTasks[id] = handleResult as Handle<any>
        local handle = handleResult as Handle<T>
        -- Add to the cache (weak table will allow GC when not referenced elsewhere)
        self._cache[cacheKey] = handle as Handle<any>
        return handle
    end
end

function AssetManager:loadFile(path: string): Handle<string>
    return createHandle(self, {"loadFile", path})
end

function AssetManager:loadFileData(path: string): Handle<love.filesystem.FileData>
    return createHandle(self, {"loadFileData", path})
end

function AssetManager:loadImage(path: string): Handle<love.graphics.Image>
    return createHandle(self, {"loadImage", path})
end

function AssetManager:loadImageFont(path: string, config?: types.ImageFontConfig): Handle<love.graphics.Font>
    local glyphs = config and config.glyphs
    local extraSpacing = config and config.extraSpacing or 0
    return createHandle(self, {"loadImageFont", path, glyphs, extraSpacing}) as Handle<love.graphics.Font>
end

function AssetManager:loadFont(path: string, config?: types.FontConfig): Handle<love.graphics.Font>
    local size = config and config.size
    local hinting = config and config.hinting
    local dpiscale = config and config.dpiscale
    return createHandle(self, {"loadFont", path, size, hinting, dpiscale}) as Handle<love.graphics.Font>
end

function AssetManager:getFont(path: string): Handle<love.graphics.Font>
    local resolvedPath = self:resolvePath(path)
    -- Cache keys are action-qualified; scan the cache for any loadFont hit
    -- at this path. Since font cache entries also include size/hinting/dpi,
    -- this returns the first font loaded for the path regardless of config.
    local prefix = "loadFont|" .. resolvedPath
    for k, handle in pairs(self._cache) do
        if type(k) == "string" and (k == prefix or (k as string):sub(1, #prefix + 1) == prefix .. "|") then
            return handle as Handle<love.graphics.Font>
        end
    end
    error("No font was loaded for " .. path)
end

function AssetManager:loadAudio(path: string, sourceType: love.audio.SourceType, streamType?: string): Handle<love.audio.Source>
    return createHandle(self, {"loadAudio", path, sourceType, streamType}) as Handle<love.audio.Source>
end

function AssetManager:loadShader(path: string): Handle<love.graphics.Shader>
    return createHandle(self, {"loadShader", path})
end

function AssetManager:loadVideo(path: string): Handle<love.graphics.Video>
    return createHandle(self, {"loadVideo", path})
end

function AssetManager:loadCompressedImage(path: string): Handle<love.image.CompressedImageData>
    return createHandle(self, {"loadCompressedImage", path})
end

function AssetManager:loadJson(path: string): Handle<any>
    return createHandle(self, {"loadJson", path})
end


local COMPLETION_FUNCTIONS <const>: {string:function(handle: HandleImpl<any>, result: any): boolean, any} = {
    loadImage = function(_handle: HandleImpl<any>, result: any): boolean, any
        local success, value = pcall(love.graphics.newImage, result as love.image.ImageData)
        if not success then
            return false, tostring(value)
        else
            return true, value
        end
    end,
    loadImageFont = function(handle: HandleImpl<any>, result: any): boolean, any
        local success, value = pcall(
            love.graphics.newImageFont,
            result as love.image.ImageData,
            handle._args[4] as string,
            handle._args[5] as number
        )
        if not success then
            return false, tostring(value)
        else
            return true, value
        end
    end,
    loadFont = function(handle: HandleImpl<any>, _result: any): boolean, any
        -- result is the file contents, but we need the path to create the font
        local path = handle._path
        local size = handle._args[4] as number
        local hinting = handle._args[5] as love.font.HintingMode
        local dpiscale = handle._args[6] as number
        local success, value: boolean, any
        if size or hinting or dpiscale then
            -- Use LÖVE 12 settings table variant
            local settings: {string: any} = {}
            if size then settings.size = size end
            if hinting then settings.hinting = hinting end
            if dpiscale then settings.dpiscale = dpiscale end
            success, value = pcall(love.graphics.newFont, path, settings)
        else
            success, value = pcall(love.graphics.newFont, path)
        end
        if not success then
            return false, tostring(value)
        else
            return true, value
        end
    end,
    loadShader = function(_handle: HandleImpl<any>, result: any): boolean, any
        local success, value = pcall(love.graphics.newShader, result as string)
        if not success then
            return false, tostring(value)
        else
            return true, value
        end
    end,
    loadVideo = function(handle: HandleImpl<any>, _result: any): boolean, any
        -- Video creation must happen on the main thread using the file path
        local path = handle._path
        local success, value = pcall(love.graphics.newVideo, path)
        if not success then
            return false, tostring(value)
        else
            return true, value
        end
    end,
    loadCompressedImage = function(_handle: HandleImpl<any>, result: any): boolean, any
        -- CompressedImageData is returned directly from the worker thread
        return true, result
    end
}

local function processHandle(self: threaded.AssetManager)
    local variant = self._pullChannel:pop() as {any}
    if variant == nil then
        return
    elseif type(variant) ~= "table" then
        error("Expected a table from the thread channel, but got: " .. type(variant))
    end

    local untypedId = assert(variant[1], "Missing handle ID")
    if type(untypedId) ~= "number" then
        error("Expected an integer id from the thread channel, but got: " .. type(untypedId))
    end
    local id = untypedId as integer

    local handle = self._runningTasks[id] as HandleImpl<any>
    if not handle then
        error("Handle not found for id: " .. id)
    end
    self._runningTasks[id] = nil

    local result, err = variant[2] as any, variant[3] as string

    -- Not all operations can be completed on the thread. Finish them here.
    if err == nil then
        local fn = COMPLETION_FUNCTIONS[handle._action]
        if fn then
            local success, value = fn(handle, result)
            if not success then
                result = nil
                err = value as string
            else
                result = value
            end
        end
    end

    LOGGER:debug("Handle completed %d with result: %s, err: %s", id, result, err)
    handle:_setResult(result, err)

    self._runningCount = self._runningCount - 1
    self._completedCount = self._completedCount + 1

    -- Store successful handle results in the cache under the same composite
    -- key used on creation (action + path + extra args).
    if not err and handle._cacheKey then
        self._cache[handle._cacheKey] = handle
    end
end

function AssetManager:update(): boolean
    -- Check for thread errors (threads that crashed)
    local threads <const> = self._threads
    for i = 1, #threads do
        local err = threads[i]:getError()
        if err then
            error("Asset worker thread " .. i .. " crashed: " .. err)
        end
    end

    -- Process all completed handles
    while self._pullChannel:getCount() > 0 do
        processHandle(self)
    end

    -- Emit initial load event on first update call when nothing is loading
    if self._hasCalledUpdate and not self._hasEmittedInitialLoad and self._runningCount == 0 then
        self._hasEmittedInitialLoad = true
        self._dispatcher:emit(0, threaded.InitialLoadComplete())
    end

    -- Mark that update has been called at least once
    self._hasCalledUpdate = true

    return self._runningCount > 0
end

function AssetManager:wait(timeout?: number): {string}
    local start = love.timer.getTime()
    local errors: {string} = {}

    while self:update() do
        if timeout and love.timer.getTime() - start > timeout then
            -- Timeout occurred, return collected errors so far
            return errors
        end
    end

    -- Collect any errors from completed handles
    for _, handle in pairs(self._cache) do
        local h = handle as HandleImpl<any>
        if h.err then
            table.insert(errors, h.err)
        end
    end

    return errors
end

function AssetManager:shutdown()
    -- Remove pending tasks.
    while self._pushChannel:getCount() > 0 do
        self._pushChannel:pop()
    end

    -- Stop each thread by sending an exit message.
    for _ = 1, #self._threads do
        self._pushChannel:push(nil)
    end

    -- Give threads a moment to process the exit signal, then release them.
    -- Don't block forever waiting - the process is exiting anyway.
    local maxWaitMs <const> = 200
    local waitedMs = 0
    local allStopped = false

    while waitedMs < maxWaitMs and not allStopped do
        allStopped = true
        for i = 1, #self._threads do
            if self._threads[i] and self._threads[i]:isRunning() then
                allStopped = false
            end
        end
        if not allStopped then
            love.timer.sleep(0.01)
            waitedMs = waitedMs + 10
        end
    end

    -- Release thread references (threads will be cleaned up when process exits)
    for i = 1, #self._threads do
        self._threads[i] = nil
    end
end

function AssetManager:getStats(): types.AssetStats
    -- Count items in the cache (need to iterate since it's a weak table)
    local cacheCount = 0
    for _ in pairs(self._cache) do
        cacheCount = cacheCount + 1
    end

    return {
        completedCount = self._completedCount,
        runningCount = self._runningCount,
        currentAssetCount = cacheCount,
        pinnedAssetCount = #self._pinnedHandles
    }
end

function AssetManager:isLoading(): boolean
    return self._runningCount > 0
end

function AssetManager:handleAll<T, U>(handles: {Handle<T>}, fn: function({T}): U): Handle<U>
    local count = #handles

    -- Create a handle that will complete when all inputs complete
    local handleAllHandle: HandleImpl<U> = setmetatable({
        id = self:_getNextId(),
        isComplete = false,
        err = nil,
        _value = nil,
        _hasBlockedOnce = false,
        _action = "handleAll",
        _path = "handleAll",
        _args = {},
        _channelId = 0,
        _assetManager = self
    }, HANDLE_MT as metatable<HandleImpl<U>>)

    -- Edge case: no handles
    if count == 0 then
        local success, result = pcall(fn, {})
        if success then
            handleAllHandle:_setResult(result, nil)
        else
            handleAllHandle:_setResult(nil as U, "Transform error: " .. tostring(result))
        end
        return handleAllHandle as Handle<U>
    end

    -- Track completion and results
    local results: {T} = {}
    local settledCount = 0
    local failed = false

    -- Observe each handle
    for i = 1, count do
        local h = handles[i]
        h:observe(function(settled: Handle<T>)
            if failed then return end

            if settled.err then
                -- First error fails the whole handleAll
                failed = true
                handleAllHandle:_setResult(nil as U, settled.err)
            else
                results[i] = (settled as HandleImpl<T>)._value
                settledCount = settledCount + 1

                -- When all have succeeded, apply transform
                if settledCount == count then
                    local success, result = pcall(fn, results)
                    if success then
                        handleAllHandle:_setResult(result, nil)
                    else
                        handleAllHandle:_setResult(nil as U, "Transform error: " .. tostring(result))
                    end
                end
            end
        end)
    end

    return handleAllHandle as Handle<U>
end

--------------------------------------------------------------------------------
-- Sprite sheet loading
--------------------------------------------------------------------------------

-- Handler for optional image loading (returns nil on error instead of failing)
local function optionalImageHandler(v: love.graphics.Image, err: any): love.graphics.Image
    if err then return nil end
    return v
end

function AssetManager:loadSpriteSheet(
    path: string,
    options?: types.SpriteSheetLoadOptions
): Handle<sprite_sheet.SpriteSheet>
    local resolvedPath = self:resolvePath(path)

    -- Load main image and JSON data concurrently
    local imageHandle = self:loadImage(path)
    local jsonPath = path:gsub("%.[^.]+$", "") .. ".json"
    local dataHandle = self:loadFileData(jsonPath)

    -- Derive material map paths
    local basePath = path:gsub("%.[^.]+$", "")
    local normalPath = basePath .. "_n.png"
    local emissionPath = basePath .. "_e.png"
    local ormPath = basePath .. "_orm.png"

    -- Load optional material maps (return nil on failure)
    local normalHandle = self:loadImage(normalPath):handle(optionalImageHandler)
    local emissionHandle = self:loadImage(emissionPath):handle(optionalImageHandler)
    local ormHandle = self:loadImage(ormPath):handle(optionalImageHandler)

    -- Combine all handles and create the sprite sheet
    return self:handleAll(
        {
            imageHandle as Handle<any>,
            dataHandle as Handle<any>,
            normalHandle as Handle<any>,
            emissionHandle as Handle<any>,
            ormHandle as Handle<any>
        },
        function(results: {any}): sprite_sheet.SpriteSheet
            local image = results[1] as love.graphics.Image
            local jsonData = results[2] as love.filesystem.FileData
            local normal = results[3] as love.graphics.Image
            local emission = results[4] as love.graphics.Image
            local ormImg = results[5] as love.graphics.Image

            local b = sprite_sheet.SpriteSheet.builderFromImage(image, jsonData, resolvedPath)
            if normal then b:normalImage(normal) end
            if emission then b:emissionImage(emission) end
            if ormImg then b:ormImage(ormImg) end

            -- Generate normal from luminance if requested and no _n.png exists
            if options and options.generateNormal and not normal then
                -- Note: generateNormal requires sync file access, so we skip it for async loading
                -- Users should provide _n.png files or use sync loading with generateNormal
            end

            return b:build()
        end
    )
end

function AssetManager:loadStaticSheet(
    path: string,
    _options?: types.SpriteSheetLoadOptions
): Handle<sprite_sheet.SpriteSheet>
    local resolvedPath = self:resolvePath(path)

    -- Load main image
    local imageHandle = self:loadImage(path)

    -- Derive material map paths
    local basePath = path:gsub("%.[^.]+$", "")
    local normalPath = basePath .. "_n.png"
    local emissionPath = basePath .. "_e.png"
    local ormPath = basePath .. "_orm.png"

    -- Load optional material maps (return nil on failure)
    local normalHandle = self:loadImage(normalPath):handle(optionalImageHandler)
    local emissionHandle = self:loadImage(emissionPath):handle(optionalImageHandler)
    local ormHandle = self:loadImage(ormPath):handle(optionalImageHandler)

    -- Combine all handles and create the sprite sheet
    return self:handleAll(
        {
            imageHandle as Handle<any>,
            normalHandle as Handle<any>,
            emissionHandle as Handle<any>,
            ormHandle as Handle<any>
        },
        function(results: {any}): sprite_sheet.SpriteSheet
            local image = results[1] as love.graphics.Image
            local normal = results[2] as love.graphics.Image
            local emission = results[3] as love.graphics.Image
            local ormImg = results[4] as love.graphics.Image

            local width, height = image:getDimensions()
            local b = sprite_sheet.SpriteSheet.builder(image, resolvedPath)
                :frame(0, 0, width, height, 1000000)  -- Static image, long duration
            if normal then b:normalImage(normal) end
            if emission then b:emissionImage(emission) end
            if ormImg then b:ormImage(ormImg) end

            return b:build()
        end
    )
end

--------------------------------------------------------------------------------
-- BMFont loading
--------------------------------------------------------------------------------

function AssetManager:loadBMFont(path: string): Handle<bmfont.BMFont>
    -- Load the font definition file
    local fontHandle = self:loadFile(path)

    return fontHandle:flatMap(function(content: string): Handle<bmfont.BMFont>
        -- Parse the font definition (without loading atlas)
        local font = bmfont.parse(content, path)

        -- Build atlas path from font's page field
        local dir = path:match("(.*/)") or ""
        local atlasPath = dir .. font.page

        -- Load the atlas image
        local atlasHandle = self:loadImage(atlasPath)

        return atlasHandle:map(function(atlasImage: love.graphics.Image): bmfont.BMFont
            font:setAtlas(atlasImage)
            return font
        end)
    end)
end

--------------------------------------------------------------------------------
-- Tiled map loading
--------------------------------------------------------------------------------

local type TilemapData = tiled_types.TilemapData

function AssetManager:loadTiledMap(path: string): Handle<TilemapData>
    -- Load the map JSON file
    local mapHandle = self:loadFile(path)

    return mapHandle:map(function(content: string): TilemapData
        local parsed = json.parse(content) as {string: any}
        local map = tiled_parser.parseTiledMap(parsed)

        -- Load tileset images synchronously (blocking)
        -- Note: We can't easily parallelize this because each tileset might
        -- reference an external .tsj file that needs to be loaded first
        local tilesets <const> = map.tilesets
        for ti = 1, #tilesets do
            local ts = tilesets[ti]
            if ts.imagePath then
                -- .tsx is the XML tileset format; only JSON (.tsj) is supported.
                if ts.imagePath:match("%.tsx$") then
                    error("External .tsx (XML) tilesets are not supported; export as .tsj (JSON): " .. ts.imagePath)
                end

                -- Check if this is an external tileset reference
                if ts.imagePath:match("%.tsj$") then
                    -- Load external tileset
                    local tsjPath = tiled_parser.resolveRelativePath(path, ts.imagePath)
                    local tsjData = love.filesystem.read(tsjPath)
                    if tsjData then
                        local tsjParsed = json.parse(tsjData) as {string: any}
                        local externalTs = tiled_parser.parseTileset(tsjParsed, ts.firstgid)
                        -- Copy over the parsed tileset data
                        ts.name = externalTs.name
                        ts.tilewidth = externalTs.tilewidth
                        ts.tileheight = externalTs.tileheight
                        ts.tilecount = externalTs.tilecount
                        ts.columns = externalTs.columns
                        ts.spacing = externalTs.spacing
                        ts.margin = externalTs.margin
                        ts.imagePath = externalTs.imagePath
                        ts.imagewidth = externalTs.imagewidth
                        ts.imageheight = externalTs.imageheight
                        ts.tiles = externalTs.tiles
                        ts._animatedTiles = externalTs._animatedTiles
                        ts._animationStates = externalTs._animationStates
                        ts._occluderHeights = externalTs._occluderHeights
                    end
                end

                -- Now load the image and optional material maps
                if ts.imagePath and not ts.imagePath:match("%.tsj$") then
                    local imgPath = tiled_parser.resolveRelativePath(path, ts.imagePath)
                    local imgHandle = self:loadImage(imgPath)
                    ts.image = imgHandle.value  -- Block until loaded
                    -- Use nearest-neighbor filtering to avoid tile bleeding
                    (ts.image as love.graphics.Texture):setFilter("nearest", "nearest")

                    -- Try to load optional material maps (_n.png, _e.png, _orm.png)
                    local basePath = imgPath:gsub("%.png$", "")
                    local normalPath = basePath .. "_n.png"
                    local emissionPath = basePath .. "_e.png"
                    local ormPath = basePath .. "_orm.png"

                    if love.filesystem.getInfo(normalPath) then
                        local normalHandle = self:loadImage(normalPath)
                        ts.normalImage = normalHandle.value
                        (ts.normalImage as love.graphics.Texture):setFilter("nearest", "nearest")
                    end

                    if love.filesystem.getInfo(emissionPath) then
                        local emissionHandle = self:loadImage(emissionPath)
                        ts.emissionImage = emissionHandle.value
                        (ts.emissionImage as love.graphics.Texture):setFilter("nearest", "nearest")
                    end

                    if love.filesystem.getInfo(ormPath) then
                        local ormHandle = self:loadImage(ormPath)
                        ts.ormImage = ormHandle.value
                        (ts.ormImage as love.graphics.Texture):setFilter("nearest", "nearest")
                    end
                end
            end
        end

        -- Load image layer images
        local mapLayers <const> = map.layers
        for li = 1, #mapLayers do
            local layer = mapLayers[li]
            if layer.type == "imagelayer" and layer.imagePath then
                local imgPath = tiled_parser.resolveRelativePath(path, layer.imagePath)
                local imgHandle = self:loadImage(imgPath)
                layer._image = imgHandle.value
                if layer.imagewidth == 0 then
                    layer.imagewidth = (layer._image as love.graphics.Texture):getWidth() as integer
                end
                if layer.imageheight == 0 then
                    layer.imageheight = (layer._image as love.graphics.Texture):getHeight() as integer
                end
            end
        end

        return map
    end)
end

--------------------------------------------------------------------------------
-- Create a new asset manager
--------------------------------------------------------------------------------

function threaded.new(root: string): AssetManager
    return AssetManager.new(root)
end

-- Create the InitialLoadComplete event
threaded.InitialLoadComplete.init = function(_e: threaded.InitialLoadComplete)
    -- No fields to set
end
tecs.newEvent(threaded.InitialLoadComplete)

-- Create the HandleComplete event
threaded.HandleComplete.init = function(e: threaded.HandleComplete, handle: Handle<any>)
    e.handle = handle
end
tecs.newEvent(threaded.HandleComplete)

return threaded
