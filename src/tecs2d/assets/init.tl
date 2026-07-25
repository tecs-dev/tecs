local types <const> = require("tecs2d.assets.types")
local workers <const> = require("tecs2d.workers")
local threaded <const> = require("tecs2d.assets.internal.threaded")

--- Process-wide asset cache and loading facade. `tecs2d.run` installs the
--- normal manager; independent managers remain available through `new`.
local record assets
    type AssetManager = types.AssetManager
    type LoadBatch = types.LoadBatch
    type AssetDescriptor = types.AssetDescriptor
    type FontConfig = types.FontConfig
    type ImageFontConfig = types.ImageFontConfig
    type AssetStats = types.AssetStats
    type AssetHandler<T> = types.AssetHandler<T>
    type SpriteSheetLoadOptions = types.SpriteSheetLoadOptions
    type SpriteSheet = types.SpriteSheet
    type BMFont = types.BMFont
    type TilemapData = types.TilemapData

    --- Active process manager. Assignment performs no lifecycle work.
    manager: types.AssetManager

    --- Create an independent asset manager.
    new: function(root: string, queue?: workers.Queue): types.AssetManager
    --- Create a typed identity for a custom asset loader.
    newAssetHandler: function<T>(): types.AssetHandler<T>
    --- Create a progress batch that can track selected handles.
    newBatch: function(): types.LoadBatch
    --- Load through a registered custom asset handler.
    load: function<T>(handler: types.AssetHandler<T>, path: string): workers.Handle<T>
    --- Register a loader for a custom asset handler identity.
    registerAssetHandler: function<T>(handler: types.AssetHandler<T>, loader: function(string): workers.Handle<T>)
    --- Load a file as text.
    loadFile: function(path: string): workers.Handle<string>
    --- Load a file as Love FileData.
    loadFileData: function(path: string): workers.Handle<love.filesystem.FileData>
    --- Load an image, constructing the GPU object on the main thread.
    loadImage: function(path: string): workers.Handle<love.graphics.Image>
    --- Load an image font. `config.glyphs` is required.
    loadImageFont: function(path: string, config: types.ImageFontConfig): workers.Handle<love.graphics.Font>
    --- Load a TrueType/OpenType font.
    loadFont: function(path: string, config?: types.FontConfig): workers.Handle<love.graphics.Font>
    --- Return a previously requested font handle by path.
    getFont: function(path: string): workers.Handle<love.graphics.Font>
    --- Load a Love audio source.
    loadAudio: function(path: string, sourceType: love.audio.SourceType, streamType?: string): workers.Handle<love.audio.Source>
    --- Load and compile a shader.
    loadShader: function(path: string): workers.Handle<love.graphics.Shader>
    --- Load a video.
    loadVideo: function(path: string): workers.Handle<love.graphics.Video>
    --- Load compressed image data.
    loadCompressedImage: function(path: string): workers.Handle<love.image.CompressedImageData>
    --- Load and decode arbitrary JSON.
    loadJson: function(path: string): workers.Handle<any>
    --- Load an Aseprite JSON sprite sheet and optional material maps.
    loadSpriteSheet: function(path: string, options?: types.SpriteSheetLoadOptions): workers.Handle<types.SpriteSheet>
    --- Load a single-image sprite sheet and optional material maps.
    loadStaticSheet: function(path: string, options?: types.SpriteSheetLoadOptions): workers.Handle<types.SpriteSheet>
    --- Load a BMFont definition and atlas.
    loadBMFont: function(path: string): workers.Handle<types.BMFont>
    --- Load a Tiled map and its referenced graphics.
    loadTiledMap: function(path: string): workers.Handle<types.TilemapData>
    --- Keep an owned handle strongly reachable.
    pin: function<T>(handle: workers.Handle<T>): workers.Handle<T>
    --- Return request metadata, or nil for a handle from another manager.
    describe: function<T>(handle: workers.Handle<T>): types.AssetDescriptor | nil
    --- Return whether this manager has unsettled operations.
    isLoading: function(): boolean
    --- Pump the queue until settled or timed out, returning collected errors.
    wait: function(timeout?: number): {string}
    --- Return current manager statistics.
    getStats: function(): types.AssetStats
    --- Resolve path segments against the current asset root.
    resolvePath: function(...: string): string
    --- Replace the root used by future requests.
    setRoot: function(root: string)
    --- Return the current asset root.
    getRoot: function(): string
end

local function current(): types.AssetManager
    return assert(assets.manager, "tecs2d.assets.manager is not initialized")
end

function assets.new(root: string, queue?: workers.Queue): types.AssetManager
    return threaded.new(root, queue)
end

function assets.newAssetHandler<T>(): types.AssetHandler<T>
    return {} as types.AssetHandler<T>
end

function assets.newBatch(): types.LoadBatch return current():newBatch() end
function assets.load<T>(handler: types.AssetHandler<T>, path: string): workers.Handle<T> return current():load(handler, path) end
function assets.registerAssetHandler<T>(handler: types.AssetHandler<T>, loader: function(string): workers.Handle<T>)
    current():registerAssetHandler(handler, loader)
end
function assets.loadFile(path: string): workers.Handle<string> return current():loadFile(path) end
function assets.loadFileData(path: string): workers.Handle<love.filesystem.FileData> return current():loadFileData(path) end
function assets.loadImage(path: string): workers.Handle<love.graphics.Image> return current():loadImage(path) end
function assets.loadImageFont(path: string, config: types.ImageFontConfig): workers.Handle<love.graphics.Font> return current():loadImageFont(path, config) end
function assets.loadFont(path: string, config?: types.FontConfig): workers.Handle<love.graphics.Font> return current():loadFont(path, config) end
function assets.getFont(path: string): workers.Handle<love.graphics.Font> return current():getFont(path) end
function assets.loadAudio(path: string, sourceType: love.audio.SourceType, streamType?: string): workers.Handle<love.audio.Source>
    return current():loadAudio(path, sourceType, streamType)
end
function assets.loadShader(path: string): workers.Handle<love.graphics.Shader> return current():loadShader(path) end
function assets.loadVideo(path: string): workers.Handle<love.graphics.Video> return current():loadVideo(path) end
function assets.loadCompressedImage(path: string): workers.Handle<love.image.CompressedImageData> return current():loadCompressedImage(path) end
function assets.loadJson(path: string): workers.Handle<any> return current():loadJson(path) end
function assets.loadSpriteSheet(path: string, options?: types.SpriteSheetLoadOptions): workers.Handle<types.SpriteSheet>
    return current():loadSpriteSheet(path, options)
end
function assets.loadStaticSheet(path: string, options?: types.SpriteSheetLoadOptions): workers.Handle<types.SpriteSheet>
    return current():loadStaticSheet(path, options)
end
function assets.loadBMFont(path: string): workers.Handle<types.BMFont> return current():loadBMFont(path) end
function assets.loadTiledMap(path: string): workers.Handle<types.TilemapData> return current():loadTiledMap(path) end
function assets.pin<T>(handle: workers.Handle<T>): workers.Handle<T> return current():pin(handle) end
function assets.describe<T>(handle: workers.Handle<T>): types.AssetDescriptor | nil
    return current():describe(handle)
end
function assets.isLoading(): boolean return current():isLoading() end
function assets.wait(timeout?: number): {string} return current():wait(timeout) end
function assets.getStats(): types.AssetStats return current():getStats() end
function assets.resolvePath(...: string): string return current():resolvePath(...) end
function assets.setRoot(root: string) current():setRoot(root) end
function assets.getRoot(): string return current():getRoot() end

return assets
