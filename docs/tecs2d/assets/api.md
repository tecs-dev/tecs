---
description: "Tecs2D global assets facade and AssetManager API"
outline: deep
---

# Assets API

```teal
local assets = require("tecs2d.assets")
```

## Global manager

`tecs2d.run` assigns the process manager to `assets.manager`. The module functions below forward to that manager:

```teal
assets.manager: assets.AssetManager

assets.loadFile(path: string): workers.Handle<string>
assets.loadFileData(path: string): workers.Handle<FileData>
assets.loadJson(path: string): workers.Handle<any>
assets.loadImage(path: string): workers.Handle<Image>
assets.loadCompressedImage(path: string): workers.Handle<CompressedImageData>
assets.loadFont(path: string, config?: FontConfig): workers.Handle<Font>
assets.loadImageFont(path: string, config: ImageFontConfig): workers.Handle<Font>
assets.loadAudio(path: string, sourceType: SourceType, streamType?: string): workers.Handle<Source>
assets.loadShader(path: string): workers.Handle<Shader>
assets.loadVideo(path: string): workers.Handle<Video>
assets.loadSpriteSheet(path: string, options?: SpriteSheetLoadOptions): workers.Handle<SpriteSheet>
assets.loadStaticSheet(path: string, options?: SpriteSheetLoadOptions): workers.Handle<SpriteSheet>
assets.loadBMFont(path: string): workers.Handle<BMFont>
assets.loadTiledMap(path: string): workers.Handle<TilemapData>
```

The facade also exposes:

```teal
assets.newBatch(): LoadBatch
assets.pin<T>(handle: workers.Handle<T>): workers.Handle<T>
assets.describe<T>(handle: workers.Handle<T>): AssetDescriptor
assets.isLoading(): boolean
assets.wait(timeout?: number): {string}
assets.getStats(): AssetStats
assets.resolvePath(...: string): string
assets.setRoot(root: string)
assets.getRoot(): string
```

## Independent managers

```teal
assets.new(root: string, queue?: workers.Queue): AssetManager
```

When `queue` is omitted, construction uses `workers.queue`. `AssetManager` provides the same loading, batch, pinning,
statistics, path, and custom-handler operations as the global facade, using method syntax.

```teal
local manager = assets.new("fixtures", queue)
local image = manager:loadImage("player.png")
manager:pin(image)
```

`manager:shutdown()` closes the manager and releases its cache. It does not stop the queue or cancel unrelated jobs.

## Custom handlers

```teal
assets.newAssetHandler<T>(): AssetHandler<T>

assets.registerAssetHandler<T>(
    handler: AssetHandler<T>,
    loader: function(path: string): workers.Handle<T>
)

assets.load<T>(handler: AssetHandler<T>, path: string): workers.Handle<T>
```

The manager form uses `manager:registerAssetHandler` and `manager:load`.

## LoadBatch

```teal
interface LoadBatch
    totalCount: integer
    completedCount: integer
    failedCount: integer
    progress: number
    isComplete: boolean
    isSuccessful: boolean
    errors: {string}

    track: function<T>(self, handle: workers.Handle<T>): workers.Handle<T>
    seal: function(self)
    observe: function(self, listener: function(LoadBatch))
end
```

Tracking the same handle twice is idempotent. Completion requires a sealed batch and settlement of every tracked handle.

## AssetDescriptor

`assets.describe(handle)` returns metadata retained by the owning manager:

```teal
record AssetDescriptor
    action: string
    path: string       -- resolved path
    inputPath: string  -- caller-provided path
    args: {any}
end
```

It returns nil for handles not created by that manager.

## AssetStats

```teal
record AssetStats
    completedCount: integer
    runningCount: integer
    currentAssetCount: integer
    pinnedAssetCount: integer
end
```

`completedCount` is lifetime manager activity. Use `LoadBatch`, not lifetime statistics, for transition progress.
