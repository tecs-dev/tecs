# Sprite Sheets

Sprite sheets are single images containing multiple animation frames. Tecs uses Aseprite's JSON export format for frame
data, tags, and slices.

## File Requirements

Each sprite sheet requires:

- **Image file**: `character.png` (or other image format)
- **JSON file**: `character.json` (Aseprite export)

The JSON file must have the same base name as the image.

**Example directory structure:**

```
assets/
  sprites/
    player.png
    player.json
    player_n.png   # Optional: normal map
    player_e.png   # Optional: emission map
    player_s.png   # Optional: specular map
```

## Loading Sprite Sheets

::: tip Automatic Material Map Loading
All sprite sheet loading methods automatically load optional material maps alongside the main image. If `player.png` is
loaded, the loader will also try to load `player_n.png` (normal), `player_e.png` (emission), and `player_s.png`
(specular). Missing material maps are silently ignored.
:::

### Synchronous Loading

```lua
local gfx = require("tecs2d.gfx")

local sheet = gfx.SpriteSheet.fromFile("assets/player.png")

-- Load with auto-generated normal map (from luminance)
local sheet = gfx.SpriteSheet.fromFile("assets/player.png", {
    generateNormal = true
})
```

### Async Loading (Recommended)

Use the asset system for non-blocking loads. See [Assets API](/tecs2d/assets/api#loadspritesheet) for full method
documentation.

```lua
local assets = require("tecs2d.assets")

local assetManager = world.resources[assets]

local handle = assetManager:loadSpriteSheet("assets/player.png")

world:spawn(
    tecs.builtins.Transform(100, 100),
    gfx.Sprite.fromSheet(handle.value, "idle")  -- Blocks on .value
)
```

### Static Sheets (No JSON)

If you need to load a texture that doesn't have any animation or an Aseprite JSON file, use
[`loadStaticSheet`](/tecs2d/assets/api#loadstaticsheet):

```lua
local assets = require("tecs2d.assets")

local assetManager = world.resources[assets]

local handle = assetManager:loadStaticSheet("assets/sprite.png")

world:spawn(
    tecs.builtins.Transform(100, 100),
    gfx.Sprite.fromSheet(handle.value)
)
```

## Aseprite Export Settings

To export from Aseprite:

1. Go to **File > Export Sprite Sheet**
2. Configure the export:
   - **Layout**: Horizontal strip, Vertical strip, or Packed
   - **JSON Data**: Enable and set format to **Array** or **Hash**
   - **Meta > Frame Tags**: Enable
   - **Meta > Slices**: Enable (if using collision boxes or pivots)
3. Export to your assets folder

**Required settings:**
- JSON Data: Enabled (Array or Hash format)
- Frame Tags: Enabled

**Optional settings:**
- Slices: Enable if using collision boxes or pivot points
- Layers: Export visible layers only

## Material Maps

Sprite sheets support material textures for advanced lighting:

| Suffix   | Map Type     | Description                            |
| -------- | ------------ | -------------------------------------- |
| `_n.png` | Normal map   | Per-pixel surface normals for lighting |
| `_e.png` | Emission map | Self-illuminating areas (glow)         |
| `_s.png` | Specular map | Shininess/reflectivity                 |

### Normal Maps

Normal maps give sprites depth and respond to lighting direction.

**Creating normal maps:**

1. **Manual**: Paint normals in your art program (R=X, G=Y, B=Z)
2. **Aseprite plugin**: Use community normal map plugins
3. **Auto-generate**: Tecs can generate from luminance

**Auto-generated normal maps:**

```lua
-- Generate from sprite luminance at load time
local sheet = gfx.SpriteSheet.fromFile("sprite.png", {
    generateNormal = true
})

-- Or generate after loading
local sheet = gfx.SpriteSheet.fromFile("sprite.png")
sheet:generateNormalMap()
```

Auto-generation uses luminance (brightness) as height, creating a beveled effect.

### Emission Maps

Emission maps define areas that glow regardless of lighting. The RGB values are added to the final color. Used for
things like glowing eyes, neon signs, fire, etc.

**File naming:** `sprite_e.png`

### Specular Maps

Specular maps control surface reflectivity, creating shiny highlights when light hits at the right angle. Used for
metal, wet surfaces, glass, etc.

**File naming:** `sprite_s.png`

**Channel encoding:**
- **RGB**: Specular color/intensity (brighter = shinier)
- **Alpha**: Shininess exponent (0 = broad highlights, 1 = tight/sharp highlights)

## SpriteSheet API

### Loading

```lua
-- From Aseprite file (requires JSON, supports animation)
local sheet = gfx.SpriteSheet.fromFile("sprite.png")
local sheet = gfx.SpriteSheet.fromFile("sprite.png", { generateNormal = true })

-- From image file (single frame, no JSON needed, auto-loads material maps)
local sheet = gfx.SpriteSheet.fromTextureFile("sprite.png")
local sheet = gfx.SpriteSheet.fromTextureFile("sprite.png", { generateNormal = true })

-- From texture (single frame, auto-loads material maps if path provided)
local sheet = gfx.SpriteSheet.fromTexture(loveTexture)
local sheet = gfx.SpriteSheet.fromTexture(loveTexture, "sprite.png")  -- with material maps
local sheet = gfx.SpriteSheet.fromTexture(loveTexture, "sprite.png", { generateNormal = true })

-- From image data (for async loading, does not auto-load material maps)
local sheet = gfx.SpriteSheet.fromImage(image, jsonData, "sprite.png")
```

### Dimensions

```lua
local sheetW, sheetH = sheet:getSheetSize()  -- Total texture size
local spriteW, spriteH = sheet:getSpriteSize()  -- Individual frame size
local image = sheet:getImage()  -- Love2D texture
```

### Frame Data

```lua
local frame = sheet:getFrame(1)  -- 1-indexed
print(frame.x, frame.y)          -- Position in atlas
print(frame.w, frame.h)          -- Frame dimensions
print(frame.duration)            -- Duration in seconds
```

### Frame Tags

```lua
-- Check if tag exists
if sheet:hasFrameTag("walk") then
    local tag = sheet:getFrameTag("walk")
    print(tag.from, tag.to)      -- Frame range (1-indexed)
    print(tag.direction)         -- 0=forward, 1=reverse, 2=pingpong
    print(tag.duration)          -- Total tag duration in seconds
end
```

### Slices

```lua
local slice = sheet:getSlice("hitbox")
if slice then
    print(slice.data)            -- User data string from Aseprite
    for i, key in ipairs(slice.keys) do
        print(key.frame)         -- Frame number this applies to
        print(key.x, key.y)      -- Slice position
        print(key.w, key.h)      -- Slice dimensions
        if key.hasPivot then
            print(key.pivotX, key.pivotY)
        end
    end
end
```

### Material Textures

```lua
local normalTex = sheet:getNormalImage()     -- Normal map or nil
local emissionTex = sheet:getEmissionImage() -- Emission map or nil
local specularTex = sheet:getSpecularImage() -- Specular map or nil

-- Generate normal from luminance
sheet:generateNormalMap()
```

### Identifiers

```lua
local id = sheet:getId()            -- Unique sheet ID (for caching)
local path = sheet:getPath()        -- File path (for serialization)
local tagId = sheet:getTagId("walk")  -- Tag name to ID
local tagName = sheet:getTagName(1)   -- Tag ID to name
```

## Builder API

For non-Aseprite atlas formats (TexturePacker, ShoeBox, custom tools), use the builder API to construct
sprite sheets programmatically:

```lua
local gfx = require("tecs2d.gfx")

-- Load your atlas image
local image = love.graphics.newImage("atlas.png")

-- Build the sprite sheet (pass path for material map auto-loading)
local sheet = gfx.SpriteSheet.builder(image, "atlas.png")
    :frame(0, 0, 32, 32, 100)      -- x, y, w, h, duration_ms
    :frame(32, 0, 32, 32, 100)
    :frame(64, 0, 32, 32, 100)
    :frame(96, 0, 32, 32, 100)
    :tag("idle", 0, 1, "forward")  -- name, from, to (0-indexed), direction
    :tag("walk", 2, 3, "pingpong")
    :slice("hitbox", 4, 4, 24, 28) -- name, x, y, w, h
    :sliceWithPivot("feet", 0, 0, 32, 32, 16, 30)  -- with pivot point
    :loadMaterialMaps()            -- auto-load atlas_n.png, atlas_e.png, atlas_s.png
    :build()

-- Use the sheet like any other
world:spawn(
    tecs.builtins.Transform(100, 100),
    gfx.Sprite.fromSheet(sheet, "idle")
)
```

### Builder Methods

| Method                                                    | Description                               |
| --------------------------------------------------------- | ----------------------------------------- |
| `frame(x, y, w, h, duration?)`                            | Add a frame (duration in ms, default 100) |
| `tag(name, from, to, direction?)`                         | Add animation tag (0-indexed frames)      |
| `slice(name, x, y, w, h)`                                 | Add a slice region                        |
| `sliceWithPivot(name, x, y, w, h, pivotX, pivotY)`        | Add slice with pivot point                |
| `normalImage(image)`                                      | Set normal map texture                    |
| `emissionImage(image)`                                    | Set emission map texture                  |
| `specularImage(image)`                                    | Set specular map texture                  |
| `loadMaterialMaps(options?)`                              | Load _n/_e/_s maps from filesystem        |
| `build()`                                                 | Create the SpriteSheet                    |

### Direction Values

- `"forward"` (default): Play frames in order
- `"reverse"`: Play frames in reverse order
- `"pingpong"`: Play forward then reverse

### Converting from Other Formats

To integrate with other atlas tools, parse their output format and call the builder methods:

```lua
-- Example: parse a simple JSON atlas format
local json = require("tecs.utils.json")
local atlasData = json.parse(love.filesystem.read("atlas.json"))

local builder = gfx.SpriteSheet.builder(
    love.graphics.newImage(atlasData.imagePath),
    atlasData.imagePath  -- path enables loadMaterialMaps()
)

for _, frame in ipairs(atlasData.frames) do
    builder:frame(frame.x, frame.y, frame.width, frame.height, frame.duration or 100)
end

for _, anim in ipairs(atlasData.animations) do
    builder:tag(anim.name, anim.start, anim["end"], anim.direction or "forward")
end

local sheet = builder:loadMaterialMaps():build()
```

## Normal Map Format

Normal maps use tangent-space encoding:

| Channel   | Axis   | Range   | Meaning                         |
| --------- | ------ | ------- | ------------------------------- |
| Red       | X      | 0-1     | Left (-1) to Right (+1)         |
| Green     | Y      | 0-1     | Up (-1) to Down (+1)            |
| Blue      | Z      | 0-1     | Into screen (0) to Out (+1)     |
| Alpha     | -      | 0-1     | 0 = no normal data, use default |

A flat surface facing the camera has RGB = (0.5, 0.5, 1.0).

Transparent pixels (alpha < 0.01) in the normal map fall back to the default normal (0.5, 0.5, 1.0), which represents a
flat surface.

## Performance Notes

- Sheets are cached by path; loading the same file returns the cached sheet
- Material maps are optional; omitting them has no performance cost
- Auto-generating normal maps happens at load time (slight delay)
- Textures are automatically allocated into size-bucketed texture arrays for efficient GPU batching
- All sprites within a size bucket (e.g., all 64×64 or smaller textures) are rendered in a single draw call
- Textures larger than 2048×2048 require the `DirectSprite` component and are rendered separately
