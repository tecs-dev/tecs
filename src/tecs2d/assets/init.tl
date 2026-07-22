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

    new: function(root: string, queue?: workers.Queue): types.AssetManager
    newAssetHandler: function<T>(): types.AssetHandler<T>
    newBatch: function(): types.LoadBatch
    load: function<T>(handler: types.AssetHandler<T>, path: string): workers.Handle<T>
    registerAssetHandler: function<T>(handler: types.AssetHandler<T>, loader: function(string): workers.Handle<T>)
    loadFile: function(path: string): workers.Handle<string>
    loadFileData: function(path: string): workers.Handle<love.filesystem.FileData>
    loadImage: function(path: string): workers.Handle<love.graphics.Image>
    loadImageFont: function(path: string, config?: types.ImageFontConfig): workers.Handle<love.graphics.Font>
    loadFont: function(path: string, config?: types.FontConfig): workers.Handle<love.graphics.Font>
    getFont: function(path: string): workers.Handle<love.graphics.Font>
    loadAudio: function(path: string, sourceType: love.audio.SourceType, streamType?: string): workers.Handle<love.audio.Source>
    loadShader: function(path: string): workers.Handle<love.graphics.Shader>
    loadVideo: function(path: string): workers.Handle<love.graphics.Video>
    loadCompressedImage: function(path: string): workers.Handle<love.image.CompressedImageData>
    loadJson: function(path: string): workers.Handle<any>
    loadSpriteSheet: function(path: string, options?: types.SpriteSheetLoadOptions): workers.Handle<types.SpriteSheet>
    loadStaticSheet: function(path: string, options?: types.SpriteSheetLoadOptions): workers.Handle<types.SpriteSheet>
    loadBMFont: function(path: string): workers.Handle<types.BMFont>
    loadTiledMap: function(path: string): workers.Handle<types.TilemapData>
    pin: function<T>(handle: workers.Handle<T>): workers.Handle<T>
    describe: function<T>(handle: workers.Handle<T>): types.AssetDescriptor
    isLoading: function(): boolean
    wait: function(timeout?: number): {string}
    getStats: function(): types.AssetStats
    resolvePath: function(...: string): string
    setRoot: function(root: string)
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
function assets.loadImageFont(path: string, config?: types.ImageFontConfig): workers.Handle<love.graphics.Font> return current():loadImageFont(path, config) end
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
function assets.describe<T>(handle: workers.Handle<T>): types.AssetDescriptor return current():describe(handle) end
function assets.isLoading(): boolean return current():isLoading() end
function assets.wait(timeout?: number): {string} return current():wait(timeout) end
function assets.getStats(): types.AssetStats return current():getStats() end
function assets.resolvePath(...: string): string return current():resolvePath(...) end
function assets.setRoot(root: string) current():setRoot(root) end
function assets.getRoot(): string return current():getRoot() end

return assets
