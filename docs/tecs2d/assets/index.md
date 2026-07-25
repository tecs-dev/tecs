---
description: "Process-wide asynchronous asset loading built on the Tecs2D worker queue"
outline: deep
---

# Assets

`tecs2d.assets` is the process-wide asset cache for a Tecs2D application. It loads and decodes files on
[`tecs2d.workers`](/tecs2d/workers), then performs graphics-only construction on the main thread.

Assets are runtime services rather than world resources. Every world in one Love process sees the same cache, which is
particularly useful for loading screens, debug worlds, and composited render worlds.

## Loading assets

`tecs2d.run` creates the global worker queue and asset manager before installing the game plugin:

```teal
local assets = require("tecs2d.assets")

local player = assets.loadImage("sprites/player.png")
local jump = assets.loadAudio("sounds/jump.wav", "static")
local font = assets.loadFont("fonts/ui.ttf", {size = 16})
```

Paths are relative to `assets/` by default. Change the global root directly:

```teal
assets.setRoot("game-assets")
```

The global manager is available as `assets.manager`. Assigning that field performs no initialization or shutdown; the
runtime normally owns it, while tests may assign a directly constructed manager.

## Handles

Every load returns a [`workers.Handle<T>`](/tecs2d/workers#handles):

```teal
local handle = assets.loadImage("player.png")

handle:observe(function(done)
    if done.err then
        print("load failed:", done.err)
    else
        playerImage = done.value
    end
end)
```

Reading `value` before completion blocks by pumping the handle's owning queue. It raises if the job failed. Prefer
`observe`, `map`, and `flatMap` during normal frame execution.

```teal
local particleSystem = assets.loadImage("particle.png")
    :map(function(image: love.graphics.Image): love.graphics.ParticleSystem
        return love.graphics.newParticleSystem(image)
    end)
```

## Caching and pinning

The manager caches handles by operation, resolved path, and loader arguments. Cache values are weak, so assets can be
collected when the game drops every reference.

```teal
local first = assets.loadImage("player.png")
local second = assets.loadImage("player.png") -- same handle while cached
```

Pin long-lived preloads through the asset manager:

```teal
local player = assets.pin(assets.loadImage("player.png"))
local music = assets.pin(assets.loadAudio("music.ogg", "stream"))
```

Pinning is asset policy and therefore is not a method on the generic worker handle.

## Load batches

A `LoadBatch` tracks progress for one preload or transition. It waits for every unique handle instead of failing fast.

```teal
local batch = assets.newBatch()
local player = batch:track(assets.loadImage("player.png"))
local music = batch:track(assets.loadAudio("music.ogg", "stream"))
batch:seal()

batch:observe(function(done: assets.LoadBatch)
    if done.isSuccessful then
        assets.pin(player)
        assets.pin(music)
    else
        print(table.concat(done.errors, "\n"))
    end
end)
```

Use `progress`, `completedCount`, `totalCount`, and `failedCount` for the loading UI. Seal only after tracking every
handle. A sealed empty batch completes successfully.

## Supported loaders

| Method | Result |
| --- | --- |
| `loadFile` | `string` |
| `loadFileData` | `FileData` |
| `loadJson` | parsed JSON |
| `loadImage` | `Image` |
| `loadCompressedImage` | `CompressedImageData` |
| `loadFont` / `loadImageFont` | `Font` |
| `loadAudio` | `Source` |
| `loadShader` | `Shader` |
| `loadVideo` | `Video` |
| `loadSpriteSheet` / `loadStaticSheet` | `SpriteSheet` |
| `loadBMFont` | `BMFont` |
| `loadTiledMap` | `TilemapData` |

See the [API reference](./api) for signatures.

## Custom asset types

Custom asset handlers add cache identity and domain parsing on top of existing handles:

```teal
local workers = require("tecs2d.workers")

local LEVEL <const> = assets.newAssetHandler<LevelData>()

assets.registerAssetHandler(LEVEL, function(path: string): workers.Handle<LevelData>
    return assets.loadFile(path):map(parseLevel)
end)

local level = assets.load(LEVEL, "levels/one.level")
```

For CPU-heavy parsing, submit a typed worker job instead of running the parser in `map`; handle transformations execute
on the main thread.

## Loading screens and multiple worlds

Worker and asset updates occur outside world phases. A game can suspend its gameplay world, update a small loading world
on a separate clock, and composite the loading canvas while the same process-wide asset batch continues settling.

See [Multiple render worlds and compositing](/tecs2d/rendering/multi-world#loading-screens) and the
[assets example](https://github.com/tecs-dev/tecs/tree/main/examples/assets).

## Independent managers

Tests and advanced tools can construct independent managers over any queue:

```teal
local workers = require("tecs2d.workers")

local queue = workers.new({threadCount = 1})
local manager = assets.new("fixtures", queue)

local value = manager:loadFile("sample.txt").value

manager:shutdown()
queue:shutdown()
```

An asset manager owns its cache, not its queue. Multiple managers may share one queue. The queue must be updated and
shut down by its owner; shutting down a manager never shuts down the shared queue.
