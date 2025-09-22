# API Reference

Access the assets module:

```lua
local assets = require("tecs2d.assets")
```

## Module Functions

### assets.InitialLoadComplete

Event type emitted when the initial asset load completes.

```lua
assets.InitialLoadComplete: Event
```

This event is emitted on the first call to `update()` when there are no loading operations. This ensures that listeners
have time to register before the event is emitted. The event is only emitted once per AssetManager instance.

```lua
-- Register listener before any update calls
world:observe(0, assets.InitialLoadComplete, function(_e: assets.InitialLoadComplete)
    print("Initial loading complete!")
    -- Transition from loading screen to main menu
end)

-- The event will be emitted on the first update() when nothing is loading
```

### assets.new

Creates a new asset manager with the specified root directory.

```lua
function assets.new(root: string): AssetManager
```

**Parameters:**

- `root`: The root directory for all asset paths

**Returns:**

- A new `AssetManager` instance

**Example:**

```lua
local manager = assets.new("assets")
```

### assets.newAssetHandler

Creates a new asset handler for custom asset types.

```lua
function assets.newAssetHandler<T>(): AssetHandler<T>
```

**Returns:**

- A new `AssetHandler<T>` instance that can be used with `load` and `registerAssetHandler`

**Example:**

```lua
local LEVEL_DATA_HANDLER <const>: AssetHandler<LevelData> = assets.newAssetHandler()

-- Register the handler
manager:registerAssetHandler(LEVEL_DATA_HANDLER, function(path: string): assets.Handle<LevelData>
    return manager:loadFile(path):map(parseLevelData)
end)
```

## Types

### AssetStats

Statistics returned by `AssetManager:getStats()`.

```lua
type AssetStats = {
    completedCount: integer
    runningCount: integer
    currentAssetCount: integer
    pinnedAssetCount: integer
}
```

**Fields:**

- `completedCount`: Total number of assets that have finished loading since the manager was created
- `runningCount`: Number of assets currently being loaded in background threads
- `currentAssetCount`: Number of assets currently held in the cache (may be less than completedCount due to
  garbage collection)
- `pinnedAssetCount`: Number of assets explicitly pinned to prevent garbage collection

### FontConfig

Configuration for loading TrueType fonts.

```lua
type FontConfig = {
    size?: number
    hinting?: HintingMode
    dpiscale?: number
}
```

**Fields:**

- `size` (optional): Font size in pixels
- `hinting` (optional): One of "normal", "light", "mono", "none"
- `dpiscale` (optional): DPI scale factor for high-DPI displays

### ImageFontConfig

Configuration for loading bitmap/image fonts.

```lua
type ImageFontConfig = {
    glyphs?: string
    extraSpacing?: number
}
```

**Fields:**

- `glyphs` (optional): String containing all glyphs in order as they appear in the image
- `extraSpacing` (optional): Additional pixels between characters

## AssetManager

The main asset loading and management class.

### loadFile

Loads a text file and returns its contents as a string.

```lua
function AssetManager:loadFile(path: string): Handle<string>
```

**Parameters:**

- `path`: Path to the file relative to the root directory

**Returns:**

- A `Handle<string>` for the file contents

**Example:**

```lua
local configHandle = manager:loadFile("config.json")
-- Later...
local configText = configHandle.value  -- Blocks if needed
```

### loadFileData

Loads a file as binary data.

```lua
function AssetManager:loadFileData(path: string): Handle<FileData>
```

**Parameters:**

- `path`: Path to the file relative to the root directory

**Returns:**

- A `Handle<FileData>` for the loaded [Love2D FileData](https://love2d.org/wiki/FileData)

### loadImage

Loads an image file.

```lua
function AssetManager:loadImage(path: string): Handle<Image>
```

**Parameters:**

- `path`: Path to the image file relative to the root directory

**Returns:**

- A `Handle<Image>` for the loaded [Love2D Image](https://love2d.org/wiki/Image)

**Example:**

```lua
local playerSprite = manager:loadImage("sprites/player.png")
playerSprite:pin()  -- Keep in memory
```

### loadFont

Loads a TrueType font.

```lua
function AssetManager:loadFont(
    path: string,
    config?: FontConfig
): Handle<Font>
```

**Parameters:**

- `path`: Path to the font file relative to the root directory
- `config`: Optional font configuration

**Returns:**

- A `Handle<Font>` for the loaded [Love2D Font](https://love2d.org/wiki/Font)

**Example:**

```lua
local uiFont = manager:loadFont("fonts/ui.ttf", {
    size = 16,
    hinting = "normal"
})
```

### loadImageFont

Loads a bitmap/image font.

```lua
function AssetManager:loadImageFont(
    path: string,
    config?: ImageFontConfig
): Handle<Font>
```

**Parameters:**

- `path`: Path to the image font file relative to the root directory
- `config`: Optional image font configuration

**Returns:**

- A `Handle<Font>` for the loaded image [Love2D Font](https://love2d.org/wiki/Font)

### loadAudio

Loads an audio file.

```lua
function AssetManager:loadAudio(
    path: string,
    sourceType: SourceType,
    streamType?: string
): Handle<Source>
```

**Parameters:**

- `path`: Path to the audio file relative to the root directory
- `sourceType`: Either "static" (for sound effects) or "stream" (for music)
- `streamType` (optional): Source of the stream data, either "file" or "memory"

**Returns:**

- A `Handle<Source>` for the loaded [Love2D audio Source](https://love2d.org/wiki/Source)

**Example:**

```lua
local jumpSound = manager:loadAudio("sounds/jump.wav", "static")
local bgMusic = manager:loadAudio("music/theme.ogg", "stream")
```

### loadShader

Loads a GLSL shader file.

```lua
function AssetManager:loadShader(path: string): Handle<Shader>
```

**Parameters:**

- `path`: Path to the shader file relative to the root directory

**Returns:**

- A `Handle<Shader>` for the loaded [Love2D Shader](https://love2d.org/wiki/Shader)

### loadVideo

Loads a video file for playback.

```lua
function AssetManager:loadVideo(path: string): Handle<Video>
```

**Parameters:**

- `path`: Path to the video file relative to the root directory

**Returns:**

- A `Handle<Video>` for the loaded [Love2D Video](https://love2d.org/wiki/Video)

**Example:**

```lua
local intro = manager:loadVideo("cutscenes/intro.ogv")

-- Later, when you want to play it
local video = intro.value
video:play()
love.graphics.draw(video, 0, 0)
```

### loadCompressedImage

Loads compressed image data without converting to a regular Image.

```lua
function AssetManager:loadCompressedImage(path: string): Handle<CompressedImageData>
```

**Parameters:**

- `path`: Path to the compressed image file relative to the root directory

**Returns:**

- A `Handle<CompressedImageData>` for the loaded [Love2D
CompressedImageData](https://love2d.org/wiki/CompressedImageData)

**Example:**

```lua
local compressedTexture = manager:loadCompressedImage("textures/terrain.dds")

-- Use with shaders or create regular image
local imageData = compressedTexture.value
local image = love.graphics.newImage(imageData)
```

### loadJson

Loads and parses a JSON file asynchronously.

```lua
function AssetManager:loadJson(path: string): Handle<any>
```

**Parameters:**

- `path`: Path to the JSON file relative to the root directory

**Returns:**

- A `Handle<any>` for the parsed JSON data

**Example:**

```lua
local configHandle = manager:loadJson("config.json")

-- Later, when you need the data
local config = configHandle.value as PlayerData
print(config.playerName)
```

::: tip JSON Parsing
This method uses the `tecs.json` library for parsing, a high-performance JSON parser.
:::

### loadSpriteSheet

Loads a sprite sheet from an Aseprite export (image + JSON file). See [Sprite Sheets](/tecs2d/rendering/sprites/sheets) for
full documentation on sprite sheet features, material maps, and the builder API.

```lua
function AssetManager:loadSpriteSheet(
    path: string,
    options?: SpriteSheetLoadOptions
): Handle<SpriteSheet>
```

**Parameters:**

- `path`: Path to the image file relative to the root directory (JSON file must have same base name)
- `options`: Optional load options

**Options:**

- `generateNormal`: If `true`, generate a normal map from luminance when no `_n.png` exists

**Returns:**

- A `Handle<SpriteSheet>` for the loaded sprite sheet with all material maps

**Example:**

```lua
local playerHandle = manager:loadSpriteSheet("sprites/player.png")

-- With auto-generated normal maps (for sync loading only)
local enemyHandle = manager:loadSpriteSheet("sprites/enemy.png", {
    generateNormal = true
})
```

::: tip Automatic Material Maps
This method automatically loads optional material maps alongside the main image:
- `player_n.png` - Normal map
- `player_e.png` - Emission map
- `player_s.png` - Specular map

Missing material maps are silently ignored.
:::

### loadStaticSheet

Loads a single-image sprite sheet (no JSON required). See [Sprite
Sheets](/tecs2d/rendering/sprites/sheets#static-sheets-no-json)
for more details.

```lua
function AssetManager:loadStaticSheet(
    path: string,
    options?: SpriteSheetLoadOptions
): Handle<SpriteSheet>
```

**Parameters:**

- `path`: Path to the image file relative to the root directory
- `options`: Optional load options (same as `loadSpriteSheet`)

**Returns:**

- A `Handle<SpriteSheet>` for a single-frame sprite sheet with material maps

**Example:**

```lua
-- Load a static image as a sprite sheet
local backgroundHandle = manager:loadStaticSheet("backgrounds/forest.png")

-- Material maps (_n.png, _e.png, _s.png) are auto-loaded if they exist
local torchHandle = manager:loadStaticSheet("props/torch.png")
```

### loadBMFont

Loads a BMFont from a `.fnt` or `.json` file. See [Text](/tecs2d/rendering/text) for full documentation on bitmap font
rendering.

```lua
function AssetManager:loadBMFont(path: string): Handle<BMFont>
```

**Parameters:**

- `path`: Path to the font definition file (`.fnt` or `.json` format)

**Returns:**

- A `Handle<BMFont>` for the loaded font with its atlas texture

**Example:**

```lua
local fontHandle = manager:loadBMFont("fonts/pixel.fnt")

-- JSON format from msdf-bmfont is also supported
local msdfHandle = manager:loadBMFont("fonts/title.json")
```

::: tip Format Detection
The format is automatically detected by file extension:
- `.fnt` - BMFont text format
- `.json` - BMFont JSON format (including MSDF output from msdf-bmfont)

The atlas image path is read from the font file and loaded automatically.
:::

### loadTiledMap

Loads a Tiled map from a `.tmj` or `.json` file. See [Tiled Integration](/tecs2d/tiled/) for full documentation on tilemap
features.

```lua
function AssetManager:loadTiledMap(path: string): Handle<TilemapData>
```

**Parameters:**

- `path`: Path to the Tiled map JSON file

**Returns:**

- A `Handle<TilemapData>` for the loaded map with all tileset images

**Example:**

```lua
local mapHandle = manager:loadTiledMap("maps/level1.tmj")

-- Spawn the tilemap when loaded
mapHandle:observe(function(h)
    if not h.err then
        world:spawn(
            tiled.Tilemap.new({ data = h.value }),
            Transform(0, 0)
        )
    end
end)
```

::: tip Automatic Asset Loading
This method automatically loads:
- All tileset images referenced in the map
- External tileset files (`.tsj`, `.tsx`)
- Material maps (`_n.png`, `_e.png`) for tilesets if they exist
- Image layer images
:::

### getFont

Returns a previously loaded font handle by path.

```lua
function AssetManager:getFont(path: string): Handle<Font>
```

This method is particularly useful for fonts since they often require configuration (size, hinting, DPI scale) that you
don't want to repeat everywhere. Load the font once with your desired settings, then retrieve it by path anywhere else:

```lua
-- Initial load with configuration
manager:loadFont("fonts/ui.ttf", {
    size = 16,
    hinting = "normal"
}):pin()

-- Later, anywhere else in your code
local uiFont = manager:getFont("fonts/ui.ttf")
love.graphics.setFont(uiFont.value)
```

**Parameters:**

- `path`: Path to the font asset (must match the path used in `loadFont` or `loadImageFont`)

**Returns:**

- The existing `Handle<Font>` for this path, a [Love2D Font](https://love2d.org/wiki/Font)

**Errors:**

- Throws an error if the font hasn't been loaded yet

::: tip Font Management Pattern
Since fonts typically need consistent configuration across your game (size, hinting, etc.), it's common to load all
fonts during initialization with their specific settings, then use `getFont` throughout your code to retrieve them by
path alone.
:::

### update

Processes completed load operations.

```lua
function AssetManager:update(): boolean
```

**Returns:**

- `true` if operations are still running, `false` if all complete

**Example:**

```lua
while manager:update() do
    -- Still loading...
end
```

### isLoading

Checks if any operations are currently loading.

```lua
function AssetManager:isLoading(): boolean
```

**Returns:**

- `true` if operations are still running, `false` if all operations are complete

### wait

Blocks until all operations complete or timeout.

```lua
function AssetManager:wait(timeout?: number): {string}
```

**Parameters:**

- `timeout`: Optional maximum time to wait in seconds

**Returns:**

- Array of error messages (empty if all operations succeeded)

**Example:**

```lua
local errors = manager:wait(5.0)  -- Wait up to 5 seconds
if #errors > 0 then
    for _, err in ipairs(errors) do
        print("Load error:", err)
    end
end
```

### getStats

Returns detailed loading statistics.

```lua
function AssetManager:getStats(): AssetStats
```

**Returns:**

An `AssetStats` table containing:
- `completedCount`: Number of completed loading operations
- `runningCount`: Number of currently running operations
- `currentAssetCount`: Number of assets currently in cache (including weak references)
- `pinnedAssetCount`: Number of assets pinned to prevent garbage collection

**Example:**

```lua
local stats = manager:getStats()
print(string.format("Loaded: %d/%d", stats.completedCount,
                    stats.completedCount + stats.runningCount))
print(string.format("Cached: %d (Pinned: %d)",
                    stats.currentAssetCount, stats.pinnedAssetCount))
```

### load

Generic asset loading method using custom handlers.

```lua
function AssetManager:load<T>(handler: AssetHandler<T>, path: string): Handle<T>
```

**Parameters:**

- `handler`: Asset handler that determines the return type and loading logic
- `path`: Path to the asset relative to the root directory

**Returns:**

- A `Handle<T>` where T is determined by the handler type

**Errors:**

- Throws an error if no loader is registered for the given handler

### registerAssetHandler

Registers a custom asset handler for a specific handler type. Custom loaders should compose existing asset loaders
using `map()` to leverage caching and background threading.

```lua
function AssetManager:registerAssetHandler<T>(
    handler: AssetHandler<T>,
    loader: function(string): Handle<T>
)
```

**Parameters:**

- `handler`: The handler object to associate with this loader
- `loader`: Function that takes a file path and returns the loaded asset

**Example:**

```lua
-- Create and register a custom CSV loader
local CSV_HANDLER <const> = assets.newAssetHandler<{{string}}>()
manager:registerAssetHandler(CSV_HANDLER, function(path: string): Handle<{{string}}>
    -- Load the contents of the CSV file in the background thread.
    return manager:loadFile(path):map(function(content: string): {{string}}
        -- The CSV is loaded now, so parse and return it.
        return parseCsv(content)
    end)
end)
```

### setRoot

Changes the root directory for all asset paths.

```lua
function AssetManager:setRoot(root: string)
```

**Parameters:**

- `root`: The new root directory

**Example:**

```lua
manager:setRoot("game-assets")
```

### getRoot

Returns the current root directory.

```lua
function AssetManager:getRoot(): string
```

**Returns:**

- The current root directory string

### resolvePath

Resolves a path relative to the root directory.

```lua
function AssetManager:resolvePath(...: string): string
```

**Parameters:**

- `...`: Path segments to join with the root directory

**Returns:**

- The full resolved path. If no arguments are given, returns the root directory.

**Example:**

```lua
local fullPath = manager:resolvePath("sprites", "player.png")
-- Returns "assets/sprites/player.png" (if root is "assets")
```

### shutdown

Stops all worker threads and cancels pending operations.

```lua
function AssetManager:shutdown()
```

### handleAll

Waits for multiple handles to complete, then transforms their values. Fails if any handle fails.

```lua
function AssetManager:handleAll<T, U>(handles: {Handle<T>}, fn: function({T}): U): Handle<U>
```

**Parameters:**

- `handles`: Array of handles to wait for
- `fn`: Transform function that receives an array of values and returns U

**Returns:**

- A `Handle<U>` that completes when all input handles succeed and the transform completes. If any handle fails, the
  handleAll handle fails with that error.

**Example:**

```lua
local imageHandle = manager:loadImage("player.png")
local normalHandle = manager:loadImage("player_n.png")
local specularHandle = manager:loadImage("player_s.png")

local spriteHandle = manager:handleAll(
    {imageHandle, normalHandle, specularHandle},
    function(images: {love.graphics.Image}): Sprite
        return createSprite(images[1], images[2], images[3])
    end
)
```

For mixed types, use `any`:

```lua
local imageHandle = manager:loadImage("player.png")
local dataHandle = manager:loadJson("player.json")

local spriteHandle = manager:handleAll(
    {imageHandle as assets.Handle<any>, dataHandle as assets.Handle<any>},
    function(results: {any}): Sprite
        local image = results[1] as love.graphics.Image
        local data = results[2] as PlayerData
        return createSprite(image, data)
    end
)
```

## Handle

A handle to an asset being loaded or already loaded.

### Properties

- `isComplete`: `boolean` - Whether the operation has completed
- `value`: `T` - The loaded asset (blocks on first access if not ready, errors if failed)
- `err`: `string` - Error message if loading failed, `nil` otherwise

### observe

Registers a callback for when the operation completes.

```lua
function Handle:observe(listener: function(Handle<T>))
```

**Parameters:**

- `listener`: Function called with the handle when complete

**Example:**

```lua
imageHandle:observe(function(h: assets.Handle<love.graphics.Image>)
    if h.err then
        print("Failed:", h.err)
    else
        sprite = h.value
    end
end)
```

### pin

Prevents this handle from being garbage collected.

```lua
function Handle:pin()
```

**Example:**

```lua
-- Keep essential assets in memory
manager:loadImage("player.png"):pin()
manager:loadFont("ui.ttf", { size = 16 }):pin()
```

### map

Transforms this handle's value when it completes successfully, returning a new handle with the transformed result.

**Important:** The transform function is only called on success. If the original handle fails, the error propagates
automatically to the mapped handle without calling the transform.

```lua
function Handle:map<U>(transform: function(T): U): Handle<U>
```

**Parameters:**

- `transform`: Function that takes the successful value and returns a transformed result

**Returns:**

- A new `Handle<U>` with the transformed value

**Example:**

```lua
local parsedHandle = manager
    :loadFile("settings.txt")
    :map(function(text: string): Config return parseConfig(text) end)
    :map(function(config: Config): Config return applyDefaults(config) end)
```

### flatMap

Transforms this handle's value into another handle when it completes successfully, flattening the result. Use this when
your transform function needs to load additional assets based on the first result.

**Important:** The transform function is only called on success. If the original handle fails, the error propagates
automatically without calling the transform.

```lua
function Handle:flatMap<U>(transform: function(T): Handle<U>): Handle<U>
```

**Parameters:**

- `transform`: Function that takes the successful value and returns a new handle

**Returns:**

- A new `Handle<U>` that completes when the inner handle completes

**Example:**

```lua
-- Load a manifest, then load the texture it references
local textureHandle = manager
    :loadJson("manifest.json")
    :flatMap(function(manifest: Manifest): Handle<Image>
        return manager:loadImage(manifest.texturePath)
    end)
```

::: tip map vs flatMap
Use `map` when your transform returns a plain value. Use `flatMap` when your transform returns another `Handle` and you
want to avoid nested handles (`Handle<Handle<T>>`).

```lua
-- map: T -> U, wraps result in Handle
handle:map(function(x: number): number return x + 1 end)  -- Handle<number>

-- flatMap: T -> Handle<U>, flattens result
handle:flatMap(function(x: Manifest): Handle<Image>
    return manager:loadImage(x.path)
end)  -- Handle<Image>
```
:::

### handle

Handles both success and error cases when this handle completes. Unlike `map`, which only runs on success, `handle` is
always called with both the value and error (one will be nil).

Use this to recover from errors or transform results with error awareness.

```lua
function Handle:handle<U>(fn: function(T, any): U): Handle<U>
```

**Parameters:**

- `fn`: Function receiving `(value, err)` that returns a new value. If the handle succeeded, `value` contains the
result and `err` is nil. If it failed, `value` is nil and `err` contains the error message.

**Returns:**

- A new `Handle<U>` with the value returned by `fn`

**Example:**

```lua
-- Recover from error with a default value
local configHandle = manager:loadJson("config.json")
    :handle(function(config: any, err: any): Config
        if err then
            print("Config not found, using defaults")
            return { volume = 0.8, fullscreen = false }
        end
        return config as Config
    end)

-- Transform with error awareness
local statusHandle = imageHandle:handle(function(image: love.graphics.Image, err: any): {string: any}
    if err then
        return { loaded = false, error = err }
    end
    return { loaded = true, width = image:getWidth() }
end)
```