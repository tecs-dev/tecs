local tecs <const> = require("tecs")
local types <const> = require("tecs_assets.types")

local LOGGER <const> = tecs.logging.getLogger("tecs_assets.threaded")

-- Try to locate the assets worker code.
local WORKER_CODE: string = nil
do
    -- Try multiple possible paths for the worker.lua file
    local possiblePaths = {
        "assets/internal/worker.lua",  -- Love2D filesystem via symlink
        "internal/worker.lua",         -- Direct internal path
        "worker.lua"                   -- Same directory
    }

    local workerCode: string = nil

    for _, path in ipairs(possiblePaths) do
        workerCode = love.filesystem.read(path)
        if workerCode then
            break
        end
    end

    if not workerCode then
        error("Could not load assets worker. Tried paths: " .. table.concat(possiblePaths, ", "))
    end

    WORKER_CODE = workerCode
end


--- A module for asynchronously loading assets in threads for Love2D games.
---
--- Assets are loaded in a thread pool based on the number of CPU cores.
--- The thread-pool is capped at 4 threads.
---
--- Use this module by setting up as a resource in a tecs.World:
---
--- ```lua
--- local assets = require("tecs2d.assets")
--- local world = tecs.newWorld()
--- world.resources[assets.MANAGER] = assets.new(world)
--- ```
local record threaded

    --- An asset manager used to asynchronously load assets in threads.
    record AssetManager is types.AssetManager
        _root: string
        _dispatcher: tecs.Emitter
        _nextId: integer
        _pushChannel: love.thread.Channel
        _pullChannel: love.thread.Channel
        _runningTasks: {integer: Handle<any>}
        _threads: {love.thread.Thread}
        _cache: {string: Handle<any>}
        _pinnedHandles: {Handle<any>}
        _runningCount: integer
        _completedCount: integer
        _hasEmittedInitialLoad: boolean
        _hasCalledUpdate: boolean
        _getNextId: function(self): integer
    end

    --- Event emitted when the initial load completes.
    record InitialLoadComplete is tecs.Event
        type: InitialLoadComplete
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

--- A HandleImpl is an event and a Handle, all in one.
local record HandleImpl<T> is Handle<T>, tecs.Event
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

    self._assetManager._dispatcher:emit(self)
end

function HandleImpl:observe<T>(listener: function(Handle<T>))
    if self.isComplete then
        listener(self)
    else
        self._assetManager._dispatcher:observeOnce(self, listener)
    end
end

function HandleImpl:pin()
    -- Add this handle to the pinned list to prevent garbage collection
    table.insert(self._assetManager._pinnedHandles, self as Handle<any>)
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
        elseif key == "err" or key == "isComplete" then
            -- These might be accessed before value, so ensure they're cached
            if not rawget(self as table, key) then
                if key == "err" then
                    rawset(self as table, "err", self.err)
                    return self.err
                else -- isComplete
                    rawset(self as table, "isComplete", self.isComplete)
                    return self.isComplete
                end
            end
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

function AssetManager.new(root: string): AssetManager
    local self: AssetManager = {
        _root = root,
        _dispatcher = tecs.newEmitter(),
        _nextId = 0,
        _pushChannel = love.thread.getChannel("taskchannel"),
        _pullChannel = love.thread.getChannel("resultchannel"),
        _runningTasks = {},
        _cache = setmetatable({}, {__mode = "v"}),
        _pinnedHandles = {},
        _runningCount = 0,
        _completedCount = 0,
        _hasEmittedInitialLoad = false,
        _hasCalledUpdate = false,
    }

    -- Start worker threads
    local threadCount = math.min(4, love.system.getProcessorCount())
    self._threads = {}
    for _ = 1, threadCount do
        local thread = love.thread.newThread(WORKER_CODE)
        thread:start("taskchannel", "resultchannel")
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

function AssetManager:_getNextId(): integer
    self._nextId = self._nextId + 1
    return self._nextId
end

local function createHandle<T>(self: AssetManager, args: {any}): Handle<T>
    local action = args[1] as string
    local inputPath = args[2] as string
    local path = self:resolvePath(inputPath)

    args[2] = path

    -- Check the cache
    local cache = self._cache[path]
    if cache then
        return cache as Handle<T>
    else
        self._runningCount = self._runningCount + 1
        local id = self:_getNextId()
        table.insert(args, 1, id)
        local channelId = self._pushChannel:push(args)
        local handleResult = HandleImpl._new(action, path, args, id, channelId, self)
        self._runningTasks[id] = handleResult as Handle<any>
        local handle = handleResult as Handle<T> -- TODO: [Teal] HandleImpl isa Handle, so why do we need to cast?
        -- Add to the cache (weak table will allow GC when not referenced elsewhere)
        self._cache[path] = handle as Handle<any>
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
    local handle = self._cache[resolvedPath]
    if not handle then
        error("No font was loaded for " .. path)
    end
    return handle as Handle<love.graphics.Font>
end

function AssetManager:loadAudio(path: string, sourceType: love.audio.SourceType): Handle<love.audio.Source>
    return createHandle(self, {"loadAudio", path, sourceType}) as Handle<love.audio.Source>
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
        if size then
            success, value = pcall(love.graphics.newFont, path, size, hinting, dpiscale)
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

    -- Store successful handle results in the cache.
    if not err then
        self._cache[handle._path] = handle
    end
end

function AssetManager:update(): boolean
    -- Process all completed handles
    while self._pullChannel:getCount() > 0 do
        processHandle(self)
    end

    -- Emit initial load event on first update call when nothing is loading
    if self._hasCalledUpdate and not self._hasEmittedInitialLoad and self._runningCount == 0 then
        self._hasEmittedInitialLoad = true
        self._dispatcher:emit(threaded.InitialLoadComplete as threaded.InitialLoadComplete)
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

    -- Wait for threads to finish
    for i = 1, #self._threads do
        self._threads[i]:wait()
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

--------------------------------------------------------------------------------
-- Create a new asset manager
--------------------------------------------------------------------------------

function threaded.new(root: string): AssetManager
    return AssetManager.new(root)
end

-- Create the InitialLoadComplete event
tecs.newEvent(threaded.InitialLoadComplete as threaded.InitialLoadComplete, function(): threaded.InitialLoadComplete
    return {} as threaded.InitialLoadComplete
end)

return threaded