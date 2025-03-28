---
outline: deep
---

# Tecs Assets

<img src="../images/assets.png" alt="Tecs Assets" style="float: right; margin-left: 20px; margin-bottom: 20px; max-width: 300px; position: relative; z-index: 10;">

Tecs Assets is a non-blocking asset loading and management system for Tecs2D. It loads game assets like images, sounds,
fonts, and shaders in background threads without freezing gameplay.

- **Non-blocking threaded loading**: Uses up to 4 worker threads to load assets without blocking the main thread
- **Automatic memory management**: Uses weak references for cached assets, allowing automatic garbage collection
- **Handle-based API**: Returns handles that can block on first access or be checked for completion
- **Plugin integration**: Works seamlessly with Tecs World as a plugin

## Installation

You can install Tecs_Assets using LuaRocks:

```bash
luarocks install --tree=src/vendor tecs_assets.tl
```

::: info Installation help
See the [install](/guide/install) guide for more info
:::

## Quickstart

First, register the asset manager with your world.

```lua
local assets = require("assets")

-- Add the asset plugin to the world.
world:addPlugin(assets.plugin({
    root = "assets",  -- Optional: defaults to "assets"
    loader = function(manager: assets.AssetManager)
        -- Here you can preload assets.
        -- Use :pin() to ensure they stay in memory.
        manager:loadImage("player.png"):pin()
        manager:loadAudio("music.ogg", "stream"):pin()
        manager:loadFont("ui.ttf", { size = 16 }):pin()
    end
}))
```

You can access the asset manager from any other system or file using the `assets.MANAGER` resource.

```lua
world:addSystem(tecs.phases.Startup, function()
    -- Get the globally registered asset manager instance.
    local manager = world.resources[assets.MANAGER]

    -- Load assets (returns immediately with a handle)
    local playerImage = manager:loadImage("sprites/player.png")
    local jumpSound = manager:loadAudio("sounds/jump.wav", "static")
    local mainFont = manager:loadFont("fonts/main.ttf", { size = 16 })

    -- Check if a handle is complete
    if playerImage.isComplete then
        -- Access the value (will error if load failed)
        love.graphics.draw(playerImage.value, 100, 100)
    end
end)
```

## Handles

All load methods return a `Handle<T>` immediately. Handles are smart references to assets being loaded.

```lua
local handle = manager:loadImage("player.png")

-- You can check if the handle has an error
if handle.err then
    print("Failed to load:", handle.err)
end

-- You can check if the handle is done
if handle.isComplete then
    local image = handle.value
end
```

You can access the handle value directly at any time, blocking until it's fully loaded:

```lua
local image = handle.value -- blocks!
```

You can react when the handle is done loaded or has an error:

```lua
-- Listen for completion
handle:observe(function(h: assets.Handle<T>)
    if h.err then
        print("Error:", h.err)
    else
        print("Loaded successfully")
        playerSprite = h.value
    end
end)
```

### Handle Properties

- `isComplete`: Boolean indicating if the operation has completed
- `value`: The loaded asset (blocks on first access if not ready, errors if failed)
- `err`: Error message if loading failed, nil otherwise

### Blocking Behavior and errors

When you access `handle.value` for the first time:

1. If the asset is already loaded, it returns immediately
2. If still loading, it blocks (calls `update()` in a loop) until complete
3. Once loaded, the value is cached on the handle for instant future access
4. If loading failed, accessing `value` throws an error

### Memory Management

Handles are cached in storage using a _weak reference_, allowing automatic garbage collection of unused resources.

```lua
-- Assets are cached automatically
local handle1 = manager:loadImage("player.png")
local handle2 = manager:loadImage("player.png")  -- Returns same handle

-- When all references are released, the asset can be garbage collected
handle1 = nil
handle2 = nil
collectgarbage()  -- Asset may be collected if no other references exist

-- Next load will create a new handle
local handle3 = manager:loadImage("player.png")  -- New load operation
```

Use the `pin()` method of a Handle to preload assets or to ensure it's never garbage collected:

```lua
-- This asset won't be garbage collected
manager:loadImage("player.png"):pin()
```

## Supported assets

The following kinds of assets can be loaded by Tecs_Assets:

| Method                 | Asset Type & Description                                                                                                                                             |
|------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `loadAudio()`          | [love.audio.Source](https://love2d.org/wiki/Source): Audio files for music and sound effects<br>`manager:loadAudio("song.ogg", "stream")`                            |
| `loadCompressedImage()`| [love.image.CompressedImageData](https://love2d.org/wiki/CompressedImageData): Compressed texture data for shaders<br>`manager:loadCompressedImage("terrain.dds")`   |
| `loadFile()`           | `string`: Raw file contents as text string<br>`manager:loadFile("config.txt")`                                                                                       |
| `loadFileData()`       | [love.filesystem.FileData](https://love2d.org/wiki/FileData): Binary file data for custom formats<br>`manager:loadFileData("level.dat")`                             |
| `loadFont()`           | [love.graphics.Font](https://love2d.org/wiki/Font): TrueType fonts with size/hinting<br>`manager:loadFont("ui.ttf", {size = 16})`                                    |
| `loadImage()`          | [love.graphics.Image](https://love2d.org/wiki/Image): Image textures for sprites and UI<br>`manager:loadImage("player.png")`                                         |
| `loadImageFont()`      | [love.graphics.Font](https://love2d.org/wiki/Font): Bitmap fonts from image files<br>`manager:loadImageFont("font.png", {glyphs = "ABC"})`                           |
| `loadShader()`         | [love.graphics.Shader](https://love2d.org/wiki/Shader): GLSL shader programs for effects<br>`manager:loadShader("blur.glsl")`                                        |
| `loadVideo()`          | [love.graphics.Video](https://love2d.org/wiki/Video): Video files for cutscenes<br>`manager:loadVideo("intro.ogv")`                                                  |

## Loading Screen

Asynchrounous asset loading makes loading assets faster, reduces stutter in games while loading assets, but it can
also be used to implement fancy loading screens with progress displays.

You can implement an initial loading screen using the `InitialLoadComplete` event combined with
[World states](/reference/states).

```lua
local tecs = require("tecs")
local assets = require("assets")

-- First, setup a "GameState"
local record GameState is tecs.States<Value>
    enum Value
        "loading"
        "playing"
    end
end

local function myPlugin(world: World)
    local manager = world.resources[assets.MANAGER]

    -- Set the initial game state
    world:setState(GameState, "loading")

    -- Transition to play when initial asset load completes.
    world:observe(assets.InitialLoadComplete, function()
        print("Initial assets loaded!")
        world:setState(GameState, "play")
    end)

    -- Show loading screen while in loading state
    world:addSystem({
        phase = phases.Render,
        runIf = function()
            return world:inState(GameState, "loading")
        end,
        run = function()
            local stats = manager:getStats()
            local progress = stats.completedCount == 0
                and 0
                or (stats.completedCount / (stats.completedCount + stats.runningCount))
            love.graphics.print("Loading... " .. math.floor(progress * 100) .. "%", 400, 300)
        end
    })

    -- Run game logic only when in "play" state
    world:addSystem({
        phase = phases.Update,
        runIf = function()
            return world:inState(GameState, "play")
        end,
        run = function()
            -- Main game logic here
        end
    })
end
```

For more information on using states, see the [States documentation](/reference/states).

## API Reference

### Module Functions

#### assets.InitialLoadComplete

Event type emitted when the initial asset load completes.

```lua
assets.InitialLoadComplete: Event
```

This event is emitted on the first call to `update()` when there are no loading operations. This ensures that listeners have time to register before the event is emitted. The event is only emitted once per AssetManager instance.

```lua
-- Register listener before any update calls
world:observe(assets.InitialLoadComplete, function()
    print("Initial loading complete!")
    -- Transition from loading screen to main menu
end)

-- The event will be emitted on the first update() when nothing is loading
```

### Asset Manager Functions

#### assets.new

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

#### assets.plugin

Creates a Tecs World plugin for asset management.

```lua
function assets.plugin(config?: PluginConfig): Plugin
```

**Parameters:**

- `config`: Optional configuration table with fields:
  - `manager`: Optional custom AssetManager to use
  - `root`: Root directory for assets (default: "assets"), ignored if manager provided
  - `loader`: Function called with manager to queue initial assets

**Returns:**

- A plugin function for use with `world:addPlugin()`

**Example:**

```lua
world:addPlugin(assets.plugin({
    root = "game-assets",
    loader = function(manager)
        -- Pin essential assets
        manager:loadImage("logo.png"):pin()
        manager:loadFont("main.ttf", { size = 24 }):pin()
    end
}))
```

##### PluginConfig

Configuration for the assets plugin.

```lua
type PluginConfig = {
    manager?: AssetManager,  -- Custom asset manager to use
    root?: string,           -- Root directory (default: "assets")
    loader?: function(AssetManager)  -- Asset loading function
}
```

**Fields:**

- `manager` (optional): Use this custom manager instead of creating a new one
- `root` (optional): Root directory for assets, defaults to "assets"
- `loader` (optional): Function called during plugin initialization to queue assets

##### AssetStats

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
- `currentAssetCount`: Number of assets currently held in the cache
  may be less than completedCount due to garbage collection)
- `pinnedAssetCount`: Number of assets explicitly pinned to prevent garbage collection

### AssetManager

The main asset loading and management class.

#### loadFile

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

#### loadFileData

Loads a file as binary data.

```lua
function AssetManager:loadFileData(path: string): Handle<FileData>
```

**Parameters:**

- `path`: Path to the file relative to the root directory

**Returns:**

- A `Handle<FileData>` for the loaded [Love2D FileData](https://love2d.org/wiki/FileData)

#### loadImage

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

#### loadFont

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

##### FontConfig

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

#### loadImageFont

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

##### ImageFontConfig

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

#### loadAudio

Loads an audio file.

```lua
function AssetManager:loadAudio(
    path: string,
    sourceType: SourceType
): Handle<Source>
```

**Parameters:**

- `path`: Path to the audio file relative to the root directory
- `sourceType`: Either "static" (for sound effects) or "stream" (for music)

**Returns:**

- A `Handle<Source>` for the loaded [Love2D audio Source](https://love2d.org/wiki/Source)

**Example:**

```lua
local jumpSound = manager:loadAudio("sounds/jump.wav", "static")
local bgMusic = manager:loadAudio("music/theme.ogg", "stream")
```

#### loadShader

Loads a GLSL shader file.

```lua
function AssetManager:loadShader(path: string): Handle<Shader>
```

**Parameters:**

- `path`: Path to the shader file relative to the root directory

**Returns:**

- A `Handle<Shader>` for the loaded [Love2D Shader](https://love2d.org/wiki/Shader)

#### loadVideo

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

#### loadCompressedImage

Loads compressed image data without converting to a regular Image.

```lua
function AssetManager:loadCompressedImage(path: string): Handle<CompressedImageData>
```

**Parameters:**

- `path`: Path to the compressed image file relative to the root directory

**Returns:**

- A `Handle<CompressedImageData>` for the loaded [Love2D CompressedImageData](https://love2d.org/wiki/CompressedImageData)

**Example:**

```lua
local compressedTexture = manager:loadCompressedImage("textures/terrain.dds")

-- Use with shaders or create regular image
local imageData = compressedTexture.value
local image = love.graphics.newImage(imageData)
```

#### getFont

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

#### update

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

#### isLoading

Checks if any operations are currently loading.

```lua
function AssetManager:isLoading(): boolean
```

**Returns:**

- `true` if operations are still running, `false` if all operations are complete

#### wait

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

#### getStats

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

#### shutdown

Stops all worker threads and cancels pending operations.

```lua
function AssetManager:shutdown()
```

### Handle

A handle to an asset being loaded or already loaded.

#### Properties

- `isComplete`: `boolean` - Whether the operation has completed
- `value`: `T` - The loaded asset (blocks on first access if not ready, errors if failed)
- `err`: `string` - Error message if loading failed, `nil` otherwise

#### observe

Registers a callback for when the operation completes.

```lua
function Handle:observe(listener: function(Handle<T>))
```

**Parameters:**

- `listener`: Function called with the handle when complete

**Example:**

```lua
imageHandle:observe(function(h)
    if h.err then
        print("Failed:", h.err)
    else
        sprite = h.value
    end
end)
```

#### pin

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

## Future plans

Hot reloading is something we could add in the future, and likely without API changes. Scanning for updates would be
done in worker threads, and when an asset has opted in to hot-reloading, it simply means the `value` of the `Handle`
can be changed, and the `observe` method can be invoked multiple times.