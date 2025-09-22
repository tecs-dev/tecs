---
outline: deep
---

# Tecs Assets

Tecs Assets is a non-blocking asset loading and management system. It loads game assets like images, sounds,
fonts, and shaders in background threads without freezing gameplay.

- **Non-blocking threaded loading**: Uses worker threads to load assets without blocking the main thread
- **Automatic memory management**: Uses weak references for cached assets, allowing automatic garbage collection
- **Handle-based API**: Returns promise-like handles that can block on first access or be checked for completion

## Quickstart

You can access the asset manager from any system:

```lua
local tecs = require("tecs")
local assets = require("tecs2d.assets")

world:addSystem({
    phase = tecs.phases.Startup,
    run = function()
        -- Get the asset manager instance
        local manager = world.resources[assets]

        -- Load assets (returns immediately with a handle)
        local playerImage = manager:loadImage("sprites/player.png")
        local jumpSound = manager:loadAudio("sounds/jump.wav", "static")
        local mainFont = manager:loadFont("fonts/main.ttf", { size = 16 })

        -- Check if a handle is complete
        if playerImage.isComplete then
            -- Access the value (will error if load failed)
            love.graphics.draw(playerImage.value, 100, 100)
        end
    end,
})
```

The game plugin automatically creates an asset manager with a root assets folder of "./assets". Use `setRoot` to change
the asset root directory:

```lua
world.resources[assets]:setRoot("game-assets")
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

You can transform handles into other types using `map()`:

```lua
-- Transform an image handle into a particle system
local particles = manager
    :loadImage("particle.png")
    :map(function(image: love.graphics.Image): love.graphics.ParticleSystem
        return love.graphics.newParticleSystem(image)
    end)
```

### Handle Properties

| Name         | Type      | Description                                                 |
|--------------|-----------|-------------------------------------------------------------|
| `isComplete` | `boolean` | `true` if the operation has completed                       |
| `value`      | `T`       | The loaded data. Blocks on first access, errors if failed   |
| `err`        | `string`  | Error message if loading failed, nil otherwise              |

### Blocking Behavior and Errors

When you access `handle.value` for the first time:

1. If the asset is already loaded, it returns immediately
2. If still loading, it blocks until complete
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

## Supported Asset Types

The asset manager provides built-in loaders for common asset types:

| Method                                                   | Returns               | Description                                                       |
| -------------------------------------------------------- | --------------------- | ----------------------------------------------------------------- |
| [`loadImage`](/tecs2d/assets/api#loadimage)                     | `Image`               | PNG, JPG, and other image formats                                 |
| [`loadSpriteSheet`](/tecs2d/assets/api#loadspritesheet)         | `SpriteSheet`         | [Sprite sheets](/tecs2d/rendering/sprites/sheets) with animations        |
| [`loadStaticSheet`](/tecs2d/assets/api#loadstaticsheet)         | `SpriteSheet`         | Single images as [sprite sheets](/tecs2d/rendering/sprites/sheets)       |
| [`loadBMFont`](/tecs2d/assets/api#loadbmfont)                   | `BMFont`              | [Bitmap font](/tecs2d/rendering/text) atlases (.fnt, .json)              |
| [`loadTiledMap`](/tecs2d/assets/api#loadtiledmap)               | `TilemapData`         | [Tiled](/tecs2d/tiled/) map editor exports                               |
| [`loadFont`](/tecs2d/assets/api#loadfont)                       | `Font`                | TrueType fonts (.ttf, .otf)                                       |
| [`loadImageFont`](/tecs2d/assets/api#loadimagefont)             | `Font`                | Image-based fonts                                                 |
| [`loadAudio`](/tecs2d/assets/api#loadaudio)                     | `Source`              | Audio files (WAV, OGG, MP3)                                       |
| [`loadShader`](/tecs2d/assets/api#loadshader)                   | `Shader`              | GLSL shader files                                                 |
| [`loadVideo`](/tecs2d/assets/api#loadvideo)                     | `Video`               | Video files (OGV)                                                 |
| [`loadJson`](/tecs2d/assets/api#loadjson)                       | `any`                 | JSON data files                                                   |
| [`loadFile`](/tecs2d/assets/api#loadfile)                       | `string`              | Raw text file contents                                            |
| [`loadCompressedImage`](/tecs2d/assets/api#loadcompressedimage) | `CompressedImageData` | Compressed image data (DDS, KTX, etc.)                            |
| [`loadFileData`](/tecs2d/assets/api#loadfiledata)               | `FileData`            | Raw binary file contents                                          |

### Game-Specific Assets

For sprite sheets, BMFonts, and Tiled maps, the loaders automatically load all required files concurrently:

- **[Sprite Sheets](/tecs2d/rendering/sprites/sheets)**: Loads the image, JSON metadata, and optional material maps
  (`_n.png`, `_e.png`, `_s.png`)
- **[BMFonts](/tecs2d/rendering/text)**: Loads the font definition and its atlas texture
- **[Tiled Maps](/tecs2d/tiled/)**: Loads the map, all tileset images, external tilesets, material maps, and image layers

### Custom Asset Types

For game-specific asset types, use [`registerAssetHandler`](/tecs2d/assets/api#registerassethandler) to create custom loaders
that integrate with the caching and threading system.

## Preloading assets

To preload assets during startup, load and pin them in a `Startup` system:

```lua
local tecs = require("tecs")
local assets = require("tecs2d.assets")

world:addSystem({
    phase = tecs.phases.Startup,
    run = function()
        local manager = world.resources[assets]
        -- Use :pin() to ensure assets stay in memory
        manager:loadImage("player.png"):pin()
        manager:loadAudio("music.ogg", "stream"):pin()
        manager:loadFont("ui.ttf", { size = 16 }):pin()
    end,
})
```

### InitialLoadComplete

The `InitialLoadComplete` event is emitted on the first call to `update()` when there are no pending load
operations. This means all assets queued during startup will have finished loading before the event fires. The
event is only emitted once per AssetManager instance and is emitted even if nothing was ever loaded.

```lua
world:observe(0, assets.InitialLoadComplete, function()
    print("All startup assets are ready!")
end)
```

This is useful for implementing [loading screens](#loading-screens) or deferring gameplay until assets
are available.

### Loading Screens

Asynchronous asset loading can be used to implement animated loading screens with progress displays.

::: info See working example
See the [Loading Screen Example](https://github.com/tecs-dev/tecs/tree/main/examples/assets) for a complete
working example on GitHub.
:::
