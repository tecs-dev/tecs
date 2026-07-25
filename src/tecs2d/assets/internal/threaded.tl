local types <const> = require("tecs2d.assets.types")
local workers <const> = require("tecs2d.workers")
local sprite_sheet <const> = require("tecs2d.gfx.internal.sprite.sheet")
local sheet <const> = require("tecs2d.gfx.sheet")
local bmfont <const> = require("tecs2d.gfx.bmfont")
local json <const> = require("tecs.utils.json")
local tiled_parser <const> = require("tecs2d.tiled.internal.parser")
local tiled_types <const> = require("tecs2d.tiled.types")

local LOGGER <const> = require("tecs.utils.logging").getLogger("tecs2d.assets")

local type Handle = workers.Handle

local record Request
    path: string
    sourceType: love.audio.SourceType
    streamType: string
end

local JOB_MODULE <const> = "tecs2d.assets.internal.jobs"
local LOAD_FILE <const> = workers.newJob(JOB_MODULE, "loadFile") as workers.Job<Request, string>
local LOAD_FILE_DATA <const> = workers.newJob(JOB_MODULE, "loadFileData") as workers.Job<Request, love.filesystem.FileData>
local LOAD_IMAGE <const> = workers.newJob(JOB_MODULE, "loadImage") as workers.Job<Request, love.image.ImageData>
local LOAD_IMAGE_FONT <const> = workers.newJob(JOB_MODULE, "loadImageFont") as workers.Job<Request, love.image.ImageData>
local LOAD_FONT <const> = workers.newJob(JOB_MODULE, "loadFont") as workers.Job<Request, string>
local LOAD_AUDIO <const> = workers.newJob(JOB_MODULE, "loadAudio") as workers.Job<Request, love.audio.Source>
local LOAD_SHADER <const> = workers.newJob(JOB_MODULE, "loadShader") as workers.Job<Request, string>
local LOAD_VIDEO <const> = workers.newJob(JOB_MODULE, "loadVideo") as workers.Job<Request, string>
local LOAD_COMPRESSED <const> = workers.newJob(JOB_MODULE, "loadCompressedImage") as workers.Job<Request, love.image.CompressedImageData>
local LOAD_JSON <const> = workers.newJob(JOB_MODULE, "loadJson") as workers.Job<Request, any>

local record threaded
    record AssetLogEntry
        action: string
        path: string
        status: string
    end

    record AssetManager is types.AssetManager
        _root: string
        _queue: workers.Queue
        _cache: {string: Handle<any>}
        _pinnedHandles: {Handle<any>}
        _pinnedSet: {Handle<any>: boolean}
        _descriptors: {Handle<any>: types.AssetDescriptor}
        _requests: {string: types.AssetDescriptor}
        _loaderRegistry: {types.AssetHandler<any>: function(string): Handle<any>}
        _assetLog: {string: AssetLogEntry}
        _runningCount: integer
        _completedCount: integer
        _errors: {string}
        _closed: boolean

        _reload: function(self, cacheKey: string): Handle<any>
    end

    new: function(root: string, queue?: workers.Queue): AssetManager
end

local type AssetManager = threaded.AssetManager
local ASSET_MANAGER_MT <const>: metatable<AssetManager> = {__index = threaded.AssetManager}

--------------------------------------------------------------------------------
-- Load batches
--------------------------------------------------------------------------------

local record LoadBatchImpl is types.LoadBatch
    totalCount: integer
    completedCount: integer
    failedCount: integer
    progress: number
    isComplete: boolean
    isSuccessful: boolean
    errors: {string}
    _sealed: boolean
    _tracked: {Handle<any>: boolean}
    _listeners: {function(types.LoadBatch)}

    track: function<T>(self, handle: Handle<T>): Handle<T>
    seal: function(self)
    observe: function(self, listener: function(types.LoadBatch))
    _settle: function(self, handle: Handle<any>)
    _completeIfReady: function(self)
end

local LOAD_BATCH_MT <const>: metatable<LoadBatchImpl> = {__index = LoadBatchImpl}

function LoadBatchImpl:_completeIfReady()
    if self.isComplete or not self._sealed or self.completedCount < self.totalCount then return end
    self.progress = 1
    self.isComplete = true
    self.isSuccessful = self.failedCount == 0
    local listeners = self._listeners
    self._listeners = {}
    for i = 1, #listeners do
        local ok, err = pcall(listeners[i], self as types.LoadBatch) as (boolean, any)
        if not ok then LOGGER:error("Asset batch observer failed: %s", tostring(err)) end
    end
    self._tracked = {}
end

function LoadBatchImpl:_settle(handle: Handle<any>)
    self.completedCount = self.completedCount + 1
    if handle.err then
        self.failedCount = self.failedCount + 1
        self.errors[#self.errors + 1] = handle.err
    end
    if self.totalCount > 0 then self.progress = self.completedCount / self.totalCount end
    self:_completeIfReady()
end

function LoadBatchImpl:track<T>(handle: Handle<T>): Handle<T>
    assert(not self._sealed, "cannot track an asset handle after sealing its batch")
    assert(handle ~= nil, "cannot track a nil asset handle")
    if self._tracked[handle as Handle<any>] then return handle end
    self._tracked[handle as Handle<any>] = true
    self.totalCount = self.totalCount + 1
    handle:observe(function(settled: Handle<T>) self:_settle(settled as Handle<any>) end)
    return handle
end

function LoadBatchImpl:seal()
    if self._sealed then return end
    self._sealed = true
    self:_completeIfReady()
end

function LoadBatchImpl:observe(listener: function(types.LoadBatch))
    if self.isComplete then
        local ok, err = pcall(listener, self as types.LoadBatch) as (boolean, any)
        if not ok then LOGGER:error("Asset batch observer failed: %s", tostring(err)) end
    else
        self._listeners[#self._listeners + 1] = listener
    end
end

local function newLoadBatch(): types.LoadBatch
    return setmetatable({
        totalCount = 0,
        completedCount = 0,
        failedCount = 0,
        progress = 0,
        isComplete = false,
        isSuccessful = false,
        errors = {},
        _sealed = false,
        _tracked = {},
        _listeners = {},
    } as LoadBatchImpl, LOAD_BATCH_MT) as types.LoadBatch
end

--------------------------------------------------------------------------------
-- Manager and primitive asset jobs
--------------------------------------------------------------------------------

function threaded.AssetManager.new(root: string, queue?: workers.Queue): AssetManager
    local resolvedQueue = queue or workers.queue
    assert(resolvedQueue, "AssetManager requires a worker queue")
    return setmetatable({
        _root = root,
        _queue = resolvedQueue,
        _cache = setmetatable({}, {__mode = "v"}),
        _pinnedHandles = {},
        _pinnedSet = setmetatable({}, {__mode = "k"}),
        _descriptors = setmetatable({}, {__mode = "k"}),
        _requests = {},
        _loaderRegistry = setmetatable({}, {__mode = "k"}),
        _assetLog = {},
        _runningCount = 0,
        _completedCount = 0,
        _errors = {},
        _closed = false,
    } as AssetManager, ASSET_MANAGER_MT) as AssetManager
end

function threaded.AssetManager:resolvePath(...: string): string
    local parts = {...}
    if #parts == 0 then return self._root end
    local suffix = table.concat(parts, "/")
    if self._root == "" then return suffix end
    return self._root .. "/" .. suffix
end

function threaded.AssetManager:setRoot(root: string) self._root = root end
function threaded.AssetManager:getRoot(): string return self._root end
function threaded.AssetManager:newBatch(): types.LoadBatch return newLoadBatch() end

local function makeCacheKey(action: string, path: string, args: {any}): string
    local parts = {action, path}
    for i = 1, #args do parts[#parts + 1] = tostring(args[i]) end
    return table.concat(parts, "|")
end

local function registerHandle<T>(
    self: AssetManager,
    cacheKey: string,
    descriptor: types.AssetDescriptor,
    handle: Handle<T>
): Handle<T>
    self._cache[cacheKey] = handle as Handle<any>
    self._descriptors[handle as Handle<any>] = descriptor
    self._requests[cacheKey] = descriptor
    self._assetLog[cacheKey] = {action = descriptor.action, path = descriptor.path, status = "loading"}
    self._runningCount = self._runningCount + 1
    handle:observe(function(settled: Handle<T>)
        self._runningCount = self._runningCount - 1
        self._completedCount = self._completedCount + 1
        local log = self._assetLog[cacheKey]
        if settled.err then
            self._cache[cacheKey] = nil
            self._errors[#self._errors + 1] = settled.err
            if log then log.status = "failed: " .. settled.err end
        elseif log then
            log.status = "loaded"
        end
    end)
    return handle
end

local function createWorkerHandle<T, U>(
    self: AssetManager,
    action: string,
    inputPath: string,
    args: {any},
    job: workers.Job<Request, U>,
    transform: function(U): T,
    request: Request
): Handle<T>
    assert(not self._closed, "asset manager is shut down")
    local path = self:resolvePath(inputPath)
    local cacheKey = makeCacheKey(action, path, args)
    local cached = self._cache[cacheKey]
    if cached then return cached as Handle<T> end

    local input = request or {path = path} as Request
    input.path = path
    local raw = self._queue:submit(job, input)
    local handle: Handle<T>
    if transform then
        handle = raw:map(transform)
    else
        handle = raw as Handle<T>
    end
    return registerHandle(self, cacheKey, {
        action = action,
        path = path,
        inputPath = inputPath,
        args = args,
    }, handle)
end

local function registerDerived<T>(
    self: AssetManager,
    action: string,
    inputPath: string,
    args: {any},
    handle: Handle<T>
): Handle<T>
    local path = self:resolvePath(inputPath)
    local key = makeCacheKey(action, path, args)
    local cached = self._cache[key]
    if cached then return cached as Handle<T> end
    return registerHandle(self, key, {
        action = action,
        path = path,
        inputPath = inputPath,
        args = args,
    }, handle)
end

function threaded.AssetManager:registerAssetHandler<T>(
    handler: types.AssetHandler<T>,
    loader: function(string): Handle<T>
)
    self._loaderRegistry[handler] = loader as function(string): Handle<any>
end

function threaded.AssetManager:load<T>(handler: types.AssetHandler<T>, path: string): Handle<T>
    assert(not self._closed, "asset manager is shut down")
    local loader = assert((self._loaderRegistry[handler] as function(string): Handle<T>),
        "No loader registered for handler type")
    local resolved = self:resolvePath(path)
    local key = tostring(handler) .. "|" .. resolved
    local cached = self._cache[key]
    if cached then return cached as Handle<T> end
    return registerHandle(self, key, {
        action = "custom",
        path = resolved,
        inputPath = path,
        args = {},
    }, loader(resolved))
end

function threaded.AssetManager:loadFile(path: string): Handle<string>
    return createWorkerHandle(self, "loadFile", path, {}, LOAD_FILE, nil, nil)
end

function threaded.AssetManager:loadFileData(path: string): Handle<love.filesystem.FileData>
    return createWorkerHandle(self, "loadFileData", path, {}, LOAD_FILE_DATA, nil, nil)
end

function threaded.AssetManager:loadImage(path: string): Handle<love.graphics.Image>
    return createWorkerHandle(self, "loadImage", path, {}, LOAD_IMAGE,
        function(data: love.image.ImageData): love.graphics.Image return love.graphics.newImage(data) end, nil)
end

function threaded.AssetManager:loadImageFont(path: string, config: types.ImageFontConfig): Handle<love.graphics.Font>
    local glyphs = assert(config and config.glyphs, "loadImageFont requires config.glyphs")
    local spacing = config.extraSpacing or 0
    return createWorkerHandle(self, "loadImageFont", path, {glyphs, spacing}, LOAD_IMAGE_FONT,
        function(data: love.image.ImageData): love.graphics.Font
            return love.graphics.newImageFont(data, glyphs, spacing)
        end, nil)
end

function threaded.AssetManager:loadFont(path: string, config?: types.FontConfig): Handle<love.graphics.Font>
    local size = config and config.size
    local hinting = config and config.hinting
    local dpiscale = config and config.dpiscale
    return createWorkerHandle(self, "loadFont", path, {size, hinting, dpiscale}, LOAD_FONT,
        function(_contents: string): love.graphics.Font
            local settings: {string: any} = {}
            if size then settings.size = size end
            if hinting then settings.hinting = hinting end
            if dpiscale then settings.dpiscale = dpiscale end
            if next(settings) then return love.graphics.newFont(self:resolvePath(path), settings) end
            return love.graphics.newFont(self:resolvePath(path))
        end, nil)
end

function threaded.AssetManager:getFont(path: string): Handle<love.graphics.Font>
    local resolved = self:resolvePath(path)
    local prefixes = {"loadFont|" .. resolved, "loadImageFont|" .. resolved}
    for key, handle in pairs(self._cache) do
        for i = 1, #prefixes do
            local prefix = prefixes[i]
            if key == prefix or key:sub(1, #prefix + 1) == prefix .. "|" then
                return handle as Handle<love.graphics.Font>
            end
        end
    end
    error("No font was loaded for " .. path)
end

function threaded.AssetManager:loadAudio(
    path: string,
    sourceType: love.audio.SourceType,
    streamType?: string
): Handle<love.audio.Source>
    return createWorkerHandle(self, "loadAudio", path, {sourceType, streamType}, LOAD_AUDIO, nil,
        {path = "", sourceType = sourceType, streamType = streamType} as Request)
end

function threaded.AssetManager:loadShader(path: string): Handle<love.graphics.Shader>
    return createWorkerHandle(self, "loadShader", path, {}, LOAD_SHADER,
        function(source: string): love.graphics.Shader return love.graphics.newShader(source) end, nil)
end

function threaded.AssetManager:loadVideo(path: string): Handle<love.graphics.Video>
    return createWorkerHandle(self, "loadVideo", path, {}, LOAD_VIDEO,
        function(_contents: string): love.graphics.Video return love.graphics.newVideo(self:resolvePath(path)) end, nil)
end

function threaded.AssetManager:loadCompressedImage(path: string): Handle<love.image.CompressedImageData>
    return createWorkerHandle(self, "loadCompressedImage", path, {}, LOAD_COMPRESSED, nil, nil)
end

function threaded.AssetManager:loadJson(path: string): Handle<any>
    return createWorkerHandle(self, "loadJson", path, {}, LOAD_JSON, nil, nil)
end

function threaded.AssetManager:pin<T>(handle: Handle<T>): Handle<T>
    assert(self._descriptors[handle as Handle<any>], "cannot pin a handle owned by another asset manager")
    if not self._pinnedSet[handle as Handle<any>] then
        self._pinnedSet[handle as Handle<any>] = true
        self._pinnedHandles[#self._pinnedHandles + 1] = handle as Handle<any>
    end
    return handle
end

function threaded.AssetManager:describe<T>(handle: Handle<T>): types.AssetDescriptor | nil
    return self._descriptors[handle as Handle<any>]
end

function threaded.AssetManager:isLoading(): boolean return self._runningCount > 0 end

function threaded.AssetManager:wait(timeout?: number): {string}
    local start = love.timer.getTime()
    while self._runningCount > 0 do
        self._queue:update()
        if timeout and love.timer.getTime() - start >= timeout then break end
    end
    local result: {string} = {}
    for i = 1, #self._errors do result[i] = self._errors[i] end
    return result
end

function threaded.AssetManager:getStats(): types.AssetStats
    local cached = 0
    for _ in pairs(self._cache) do cached = cached + 1 end
    return {
        completedCount = self._completedCount,
        runningCount = self._runningCount,
        currentAssetCount = cached,
        pinnedAssetCount = #self._pinnedHandles,
    }
end

function threaded.AssetManager:shutdown()
    if self._closed then return end
    self._closed = true
    self._cache = setmetatable({}, {__mode = "v"})
    self._pinnedHandles = {}
    self._pinnedSet = setmetatable({}, {__mode = "k"})
end

function threaded.AssetManager:_reload(cacheKey: string): Handle<any>
    local request = self._requests[cacheKey]
    if not request or request.action == "custom" then return nil end
    self._cache[cacheKey] = nil
    local path = request.inputPath
    local args = request.args
    if request.action == "loadFile" then return self:loadFile(path) as Handle<any> end
    if request.action == "loadFileData" then return self:loadFileData(path) as Handle<any> end
    if request.action == "loadImage" then return self:loadImage(path) as Handle<any> end
    if request.action == "loadImageFont" then
        return self:loadImageFont(path, {glyphs = args[1] as string, extraSpacing = args[2] as number}) as Handle<any>
    end
    if request.action == "loadFont" then
        return self:loadFont(path, {
            size = args[1] as number,
            hinting = args[2] as love.font.HintingMode,
            dpiscale = args[3] as number,
        }) as Handle<any>
    end
    if request.action == "loadAudio" then
        return self:loadAudio(path, args[1] as love.audio.SourceType, args[2] as string) as Handle<any>
    end
    if request.action == "loadShader" then return self:loadShader(path) as Handle<any> end
    if request.action == "loadVideo" then return self:loadVideo(path) as Handle<any> end
    if request.action == "loadCompressedImage" then return self:loadCompressedImage(path) as Handle<any> end
    if request.action == "loadJson" then return self:loadJson(path) end
    if request.action == "loadSpriteSheet" then return self:loadSpriteSheet(path) as Handle<any> end
    if request.action == "loadStaticSheet" then return self:loadStaticSheet(path) as Handle<any> end
    if request.action == "loadBMFont" then return self:loadBMFont(path) as Handle<any> end
    if request.action == "loadTiledMap" then return self:loadTiledMap(path) as Handle<any> end
    return nil
end

--------------------------------------------------------------------------------
-- Composite asset loaders
--------------------------------------------------------------------------------

local function optionalImage(value: love.graphics.Image, err: string): love.graphics.Image
    if err then return nil end
    return value
end

function threaded.AssetManager:loadSpriteSheet(
    path: string,
    _options?: types.SpriteSheetLoadOptions
): Handle<sheet.SpriteSheet>
    local resolvedPath = self:resolvePath(path)
    local base = path:gsub("%.[^.]+$", "")
    local handles: {Handle<any>} = {
        self:loadImage(path) as Handle<any>,
        self:loadFileData(base .. ".json") as Handle<any>,
        self:loadImage(base .. "_n.png"):handle(optionalImage) as Handle<any>,
        self:loadImage(base .. "_e.png"):handle(optionalImage) as Handle<any>,
        self:loadImage(base .. "_orm.png"):handle(optionalImage) as Handle<any>,
    }
    local result = self._queue:all(handles):map(function(values: {any}): sheet.SpriteSheet
        local builder = sprite_sheet.SpriteSheet.builderFromImage(
            values[1] as love.graphics.Image,
            values[2] as love.filesystem.FileData,
            resolvedPath)
        if values[3] then builder:normalImage(values[3] as love.graphics.Image) end
        if values[4] then builder:emissionImage(values[4] as love.graphics.Image) end
        if values[5] then builder:ormImage(values[5] as love.graphics.Image) end
        return builder:build() as sheet.SpriteSheet
    end)
    return registerDerived(self, "loadSpriteSheet", path, {}, result)
end

function threaded.AssetManager:loadStaticSheet(
    path: string,
    _options?: types.SpriteSheetLoadOptions
): Handle<sheet.SpriteSheet>
    local resolvedPath = self:resolvePath(path)
    local base = path:gsub("%.[^.]+$", "")
    local handles: {Handle<any>} = {
        self:loadImage(path) as Handle<any>,
        self:loadImage(base .. "_n.png"):handle(optionalImage) as Handle<any>,
        self:loadImage(base .. "_e.png"):handle(optionalImage) as Handle<any>,
        self:loadImage(base .. "_orm.png"):handle(optionalImage) as Handle<any>,
    }
    local result = self._queue:all(handles):map(function(values: {any}): sheet.SpriteSheet
        local image = values[1] as love.graphics.Image
        local width, height = image:getDimensions()
        local builder = sprite_sheet.SpriteSheet.builder(image, resolvedPath)
            :frame(0, 0, width, height, 1000000)
        if values[2] then builder:normalImage(values[2] as love.graphics.Image) end
        if values[3] then builder:emissionImage(values[3] as love.graphics.Image) end
        if values[4] then builder:ormImage(values[4] as love.graphics.Image) end
        return builder:build() as sheet.SpriteSheet
    end)
    return registerDerived(self, "loadStaticSheet", path, {}, result)
end

function threaded.AssetManager:loadBMFont(path: string): Handle<bmfont.BMFont>
    local result = self:loadFile(path):flatMap(function(content: string): Handle<bmfont.BMFont>
        local font = bmfont.parse(content, path)
        local dir = path:match("(.*/)") or ""
        return self:loadImage(dir .. font.page):map(function(atlas: love.graphics.Image): bmfont.BMFont
            font:setAtlas(atlas)
            return font
        end)
    end)
    return registerDerived(self, "loadBMFont", path, {}, result)
end

local type TilemapData = tiled_types.TilemapData

function threaded.AssetManager:loadTiledMap(path: string): Handle<TilemapData>
    local result = self:loadFile(path):map(function(content: string): TilemapData
        local map = tiled_parser.parseTiledMap(json.parse(content) as {string: any})
        local tilesets <const> = map.tilesets
        for ti = 1, #tilesets do
            local ts = tilesets[ti]
            if ts.imagePath then
                if ts.imagePath:match("%.tsx$") then
                    error("External .tsx tilesets are not supported; export as .tsj: " .. ts.imagePath)
                end
                if ts.imagePath:match("%.tsj$") then
                    local tsjPath = tiled_parser.resolveRelativePath(path, ts.imagePath)
                    local tsjData = love.filesystem.read(tsjPath)
                    if tsjData then
                        local external = tiled_parser.parseTileset(json.parse(tsjData) as {string: any}, ts.firstgid)
                        ts.name = external.name
                        ts.tilewidth = external.tilewidth
                        ts.tileheight = external.tileheight
                        ts.tilecount = external.tilecount
                        ts.columns = external.columns
                        ts.spacing = external.spacing
                        ts.margin = external.margin
                        ts.imagePath = external.imagePath
                        ts.imagewidth = external.imagewidth
                        ts.imageheight = external.imageheight
                        ts.tiles = external.tiles
                        ts._animatedTiles = external._animatedTiles
                        ts._animationStates = external._animationStates
                        ts._occluderHeights = external._occluderHeights
                    end
                end
                if ts.imagePath and not ts.imagePath:match("%.tsj$") then
                    local imagePath = tiled_parser.resolveRelativePath(path, ts.imagePath)
                    ts.image = self:loadImage(imagePath).value
                    (ts.image as love.graphics.Texture):setFilter("nearest", "nearest")
                    local base = imagePath:gsub("%.png$", "")
                    if love.filesystem.getInfo(base .. "_n.png") then
                        ts.normalImage = self:loadImage(base .. "_n.png").value
                        (ts.normalImage as love.graphics.Texture):setFilter("nearest", "nearest")
                    end
                    if love.filesystem.getInfo(base .. "_e.png") then
                        ts.emissionImage = self:loadImage(base .. "_e.png").value
                        (ts.emissionImage as love.graphics.Texture):setFilter("nearest", "nearest")
                    end
                    if love.filesystem.getInfo(base .. "_orm.png") then
                        ts.ormImage = self:loadImage(base .. "_orm.png").value
                        (ts.ormImage as love.graphics.Texture):setFilter("nearest", "nearest")
                    end
                end
            end
        end
        local layers <const> = map.layers
        for i = 1, #layers do
            local layer = layers[i]
            if layer.type == "imagelayer" and layer.imagePath then
                local imagePath = tiled_parser.resolveRelativePath(path, layer.imagePath)
                layer._image = self:loadImage(imagePath).value
                if layer.imagewidth == 0 then layer.imagewidth = (layer._image as love.graphics.Texture):getWidth() as integer end
                if layer.imageheight == 0 then layer.imageheight = (layer._image as love.graphics.Texture):getHeight() as integer end
            end
        end
        return map
    end)
    return registerDerived(self, "loadTiledMap", path, {}, result)
end

function threaded.new(root: string, queue?: workers.Queue): AssetManager
    return threaded.AssetManager.new(root, queue)
end

return threaded
