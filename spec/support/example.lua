-- Runs a compiled example through the real Application lifecycle and exposes
-- its composited target to ordinary pixel assertions.

local render = require("spec.support.render")
local time = require("tecs.platform.time")
local files = require("tecs.io.files")

local example = {}
local Session = {}
Session.__index = Session

local function compiledPath(name)
    local directory = os.getenv("TECS_EXAMPLES")
    if directory == nil or directory == "" then
        error("TECS_EXAMPLES is not set; run example contracts through cargo xtask test", 3)
    end
    return directory .. "/" .. name .. ".lua"
end

local function compactMeshes(config)
    local meshes = config.meshes
    if meshes == nil then
        return
    end
    meshes.capacity = math.min(meshes.capacity or 64, 64)
    meshes.vertexCapacity = math.min(meshes.vertexCapacity or 4096, 4096)
    meshes.indexCapacity = math.min(meshes.indexCapacity or 8192, 8192)
    meshes.materialCapacity = math.min(meshes.materialCapacity or 32, 32)
    meshes.textureWidth = math.min(meshes.textureWidth or 64, 64)
    meshes.textureHeight = math.min(meshes.textureHeight or 64, 64)
    meshes.textureLayers = math.min(meshes.textureLayers or 8, 8)
    if meshes.lights ~= nil then
        meshes.lights.capacity = math.min(meshes.lights.capacity or 16, 16)
    end
end

function Session:advance(count)
    for _ = 1, count or 1 do
        local running = self.app:_iterate(nil, 0, nil)
        if not running then
            error(("example %s stopped before its contract completed"):format(self.name), 2)
        end
        local crashed = self.app:crashed()
        if crashed ~= nil then
            error(("example %s crashed:\n%s"):format(self.name, crashed), 2)
        end
        self.frame = self.frame + 1
    end
end

function Session:capture(area)
    local texture = self.app.renderer:captureTexture()
    local pixels = texture:readback()
    return {
        texture = texture,
        pixels = pixels,
        measurement = render.measure(texture, pixels, area),
        frame = self.frame,
    }
end

function Session:close()
    if self.closed then
        return
    end
    self.closed = true
    time.step = self.originalStep
    files.assetPath = self.originalAssetPath
    if self.initialized then
        self.app:_shutdown()
    end
end

function example.run(name, options, inspect)
    options = options or {}
    local chunk, reason = loadfile(compiledPath(name))
    if chunk == nil then
        error(("could not load compiled %s example: %s"):format(name, tostring(reason)), 2)
    end
    local app = chunk()
    if app == nil or app._config == nil then
        error(("compiled %s example did not return an Application"):format(name), 2)
    end

    local config = app._config
    config.window = {
        title = name .. " contract",
        width = options.width or 96,
        height = options.height or 96,
        highPixelDensity = false,
        resizable = false,
    }
    config.presentMode = "immediate"
    config.showFps = false
    config.debug = false
    config.debugMaxFrames = nil
    config.quitOnEscape = false
    if options.compact then
        compactMeshes(config)
    end
    if options.configure ~= nil then
        options.configure(config)
    end

    local originalAssetPath = files.assetPath
    if options.assets ~= nil then
        files.assetPath = function(path)
            return options.assets[path] or originalAssetPath(path)
        end
    end
    local originalStep = time.step
    time.step = function()
        return options.delta or 1 / 60
    end

    local session = setmetatable({
        name = name,
        app = app,
        frame = 0,
        closed = false,
        initialized = false,
        originalStep = originalStep,
        originalAssetPath = originalAssetPath,
    }, Session)

    local ok, result = xpcall(function()
        if not app:_init() then
            error(("example %s declined initialization"):format(name))
        end
        session.initialized = true
        session.driver = render.assertDriver(app.device)
        if options.afterInit ~= nil then
            options.afterInit(session)
        end
        session:advance(options.frames or 2)
        inspect(session, render)
    end, debug.traceback)
    local closed, closeReason = pcall(session.close, session)
    if not ok then
        error(result, 0)
    end
    if not closed then
        error(closeReason, 0)
    end
end

return example
