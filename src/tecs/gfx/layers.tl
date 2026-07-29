--[=[
Depth bands, sorting, coordinate spaces, parallax, and lighting.

A layer occupies one of sixteen depth bands. Entities sort inside their band
and never against another band. Higher layer numbers draw nearer, so a HUD on
layer 8 covers a world on layer 1.

```teal
tecs.gfx.layers.configure(1, {sort = "topdown", parallax = 0.4})
tecs.gfx.layers.configure(8, {sort = "z", screenSpace = true, unlit = true})

world:spawn(
    tecs.Transform(16, 16, 0, 8, 0, 96, 24),
    tecs.gfx.Tint(1.0, 1.0, 1.0, 1.0),
    tecs.gfx.Renderable()
)
```

The fourth [`Transform`](/ecs/#tecs.ecs.Transform) argument selects the layer.

## Sort modes

`"topdown"` sorts by Y with Z for height. `"z"` ignores position.
`"isometric"` combines X, Y, and Z for a diamond grid. Equal depths retain
instance order.

`maxZ` and `maxY` define the authored extents that each sort maps into its
band. Values past an extent clamp to its edge. They still draw, but clamped
entities no longer sort against one another. Reduce an extent when
`Renderer:depthSortCollapse` reports that the target depth format merges nearby
values.

## Coordinate spaces

World coordinates form the default. `screenSpace` uses target pixels and
ignores the camera. `virtualCoords` stretches one
`virtualWidth` by `virtualHeight` coordinate system to the target.
`ignoreZoom` follows camera position while preserving drawn size. `parallax`
scales camera movement.

One layer cannot combine `screenSpace` and `virtualCoords`. Virtual coordinates
preserve the authored coordinate system but do not letterbox or preserve
square pixels.

`unlit` bypasses scene lighting for UI, debug overlays, and other content that
must retain its own color.

`configure` replaces the complete layer configuration. Any omitted option
returns to its default.
]=]
-- Implementation details:
-- The band formula stays fixed because authored scenes depend on its ordering.
-- The shader and host share `MAX`, sort identifiers, extents, and the depth
-- packing formula.
--
-- View culling cannot express screen, virtual, parallax, or zoom-independent
-- placement. Extraction leaves those layers unbounded and retains ordinary
-- camera culling for world layers. The renderer repacks layer data only when
-- `configure` increments the revision.

local record layers
    --- Read-only. Reports how many bands divide the depth range.
    ---
    --- Load-bearing at sixteen. A sort mode packs into two bits, this value
    --- sizes the vertex shader's table, and the shader recovers a layer by
    --- multiplying depth by it. `LAYER_BANDS` in
    --- `assets/shaders/instance.vert.glsl` is the same number, and the two only
    --- work while they agree. Raising it is not a constant change.
    MAX: integer

    --- Caller-writable. Sets the highest z a scene expects to use and the
    --- resulting resolution of
    --- sorting within a band. A scene reaching past this still draws, with
    --- entities beyond the edge resting on it and no longer sorting against
    --- each other.
    maxZ: number

    --- Caller-writable. Sets half the expected world extent used to normalize
    --- position into a band. A scene larger than this still sorts, with
    --- entities beyond the edge compressed against it.
    maxY: number

    --- Caller-writable. Sets the horizontal resolution used to author a
    --- virtual-coordinate layer.
    ---
    --- Every such layer shares one resolution because a game has one authored
    --- layout size. Tecs scales it to fill the target, so the layout keeps its
    --- internal proportions at any window size and stretches with the window's
    --- aspect.
    virtualWidth: number
    --- Caller-writable. Sets the vertical resolution used to author a
    --- virtual-coordinate layer. Tecs scales it with `virtualWidth` to
    --- fill the target.
    virtualHeight: number

    --- Selects how a layer orders its contents within its own band.
    enum Sort
        --- Read-only. Sorts lower screen positions in front and uses z to
        --- break ties. Top-down and side-on games use this order.
        "topdown"
        --- Read-only. Sorts only by z. A HUD uses this order when position has
        --- no bearing on coverage.
        "z"
        --- Read-only. Sorts by X plus Y plus z for diamond grids where both
        --- axes move an entity towards the viewer.
        "isometric"
    end

    --- Defines every decision a layer makes about its contents. A field left
    --- out takes
    --- its default, so this says what a layer is rather than amending what it
    --- was.
    record Config
        --- Caller-writable. Selects how contents sort within the layer's band.
        --- The caller must set this field.
        sort: Sort
        --- Caller-writable. Positions contents in screen pixels and ignores the camera
        --- entirely. What a HUD wants. Defaults to false.
        screenSpace: boolean
        --- Caller-writable. Makes contents follow the camera's position but not its zoom, so they
        --- stay a constant size on screen while moving with the world.
        --- Defaults to false.
        ignoreZoom: boolean
        --- Caller-writable. Positions contents in `virtualWidth` by
        --- `virtualHeight`; Tecs scales that coordinate system to fill the
        --- target. Defaults to false and cannot combine with `screenSpace`.
        virtualCoords: boolean
        --- Caller-writable. Makes contents bypass the lighting pass and appear at their own color.
        --- Defaults to false. A material can ask for the same thing, and a
        --- fragment is lit only where the material and the layer agree.
        unlit: boolean
        --- Caller-writable. Sets how much the camera's position carries the contents. One moves them
        --- with the world; a half drifts them at half speed, which is what a
        --- background wants. Defaults to one.
        parallax: number
    end

    --- Sets what a layer does with its contents.
    ---
    --- Replaces the layer's configuration rather than amending it. A
    --- [`Config`](tealdoc:tecs.gfx.layers.Config) defines the whole layer, so each omitted field
    --- takes its default instead of retaining its previous value.
    --- @param layer One to `MAX`. Anything else raises.
    --- @param config Raises on a missing or unknown `sort`, and on asking for
    ---     `screenSpace` and `virtualCoords` together.
    configure: function(layer: integer, config: layers.Config)

    --- Returns a layer's sort as the identifier accepted by `depthOf`.
    --- @param layer One to `MAX`. Outside that this answers topdown rather than
    ---     raising, since it is the default every layer starts on.
    --- @return The sort identifier, which is an internal number and not one of
    ---     the `Sort` strings.
    sortOf: function(layer: integer): integer

    --- Returns the layer table's configuration revision.
    --- @return A count that starts at zero and only rises. A consumer compares
    ---     it against the value it packed at, so the number itself means
    ---     nothing beyond having changed.
    revision: function(): integer

    --- Returns the four floats that position and light one layer: its mode, its
    --- parallax offset factor, whether it ignores zoom, and whether it is lit.
    ---
    --- Returns these values together because consumers pack them together when
    --- `revision` changes, not every frame.
    --- @param layer One to `MAX`. Outside that every return is nil, since only
    ---     that range is ever filled in.
    --- @return The positioning mode, then the camera position's multiplier,
    ---     then one when the layer ignores zoom, then one when it is lit.
    entryOf: function(layer: integer): number, number, number, number

    --- Returns whether the camera's view rectangle culls this layer.
    ---
    --- False on a layer the camera does not place where its world bound says:
    --- screen-space and virtual-coordinate contents have no world position for
    --- the view to test, and parallax and ignore-zoom draw them somewhere the
    --- bound does not describe. Extraction reads this per row and gives those
    --- contents a bound that every view contains, so they draw regardless of
    --- camera position. Layers using none of these modes retain exact culling.
    --- @param layer One to `MAX`. Outside that this answers true, which is what
    ---     an unconfigured layer answers too.
    --- @return Whether extraction should write this row's real world bound.
    viewCulled: function(layer: integer): boolean

    --- Returns one entity's depth from zero to one, with zero nearest.
    ---
    --- Exact ties carry no tie-breaker. The renderer draws instances in index
    --- order and the depth test lets an equal fragment through, so two entities at the
    --- same depth already resolve the same way every frame: the later one wins.
    --- Nudging depth by identity would resolve them the other way, since a
    --- larger value is farther, and quietly invert the order a scene was built
    --- expecting.
    --- @param layer One to `MAX`, which picks the band and, through `sortOf`,
    ---     what the rest of the arguments mean. Outside that range this takes
    ---     the nearest layer whole and goes on sorting within it, because a
    ---     band is the only thing a depth can name.
    --- @param z Height in the sort, against `maxZ`. Read by every sort mode.
    --- @param x World x, read only by the isometric sort, against `maxY`.
    --- @param y World y, read by the topdown and isometric sorts, against
    ---     `maxY`. Larger is lower on screen and so nearer.
    --- @return Returns a depth inside the layer's own band. The function
    ---     normalizes and clamps each argument to zero through one, so a scene
    ---     beyond the configured extent stops sorting instead of spilling into
    ---     the next layer.
    depthOf: function(layer: integer, z: number, x: number, y: number): number

    --- Returns the smallest depth difference `depthOf` produces between two
    --- entities
    --- one unit apart, taken over every sort mode.
    ---
    --- A depth buffer must preserve this difference. A format with a larger
    --- step keeps the bands, so layer order remains safe, but loses the
    --- sort inside them: the two entities land on one depth value and draw in
    --- write order rather than their sorted order.
    ---
    --- The calculation includes every mode because `configure` may assign any
    --- sort after the depth target exists. `MAX`, `maxZ`, and `maxY` determine
    --- the result, so raising an extent changes it.
    --- @return A depth difference, in the input that moves depth least. That
    ---     is the topdown sort's y at the defaults, which spends the smallest
    ---     share of a band on the widest range.
    depthResolution: function(): number
end

layers.MAX = 16
layers.maxZ = 1000.0
layers.maxY = 10000.0
layers.virtualWidth = 1920.0
layers.virtualHeight = 1080.0

local SORT_TOPDOWN <const> = 0
local SORT_Z <const> = 1
local SORT_ISOMETRIC <const> = 2

--- How much of its band a sort spreads across, leaving a sliver so the far
--- end of one band never reaches the near end of the next.
local BAND_FILL <const> = 0.99
--- How the topdown sort divides that span between its two inputs. Height
--- carries most of it and position breaks the ties, which is what makes a
--- character standing on a crate read as on top of it.
local TOPDOWN_Z_SHARE <const> = 0.7
local TOPDOWN_Y_SHARE <const> = 0.3
--- The range the isometric sum covers: a normalized x, a normalized y and a
--- normalized z, each zero to one.
local ISOMETRIC_RANGE <const> = 3.0

local SORT_IDS <const>: {string: integer} = {
    topdown = SORT_TOPDOWN,
    z = SORT_Z,
    isometric = SORT_ISOMETRIC,
}

--- The space a layer positions its contents in. These are the values the
--- vertex shader compares an entry's first component against.
local MODE_CAMERA <const> = 0.0
local MODE_SCREEN <const> = 1.0
local MODE_VIRTUAL <const> = 2.0

--- Per-layer state, indexed one-based and kept as parallel arrays because the
--- four float columns are what the renderer packs into a uniform.
---
--- Defaults are what a scene wants before anyone has said otherwise: sorted
--- top-down, positioned by the camera, moving with the world, and lit.
local sorts: {integer} = {}
local modes: {number} = {}
--- What the camera's position is multiplied by before it is added to a world
--- position: one minus parallax, which is zero when contents move with the
--- world and so costs the shader nothing to apply unconditionally.
local parallaxOffsets: {number} = {}
local zoomFlags: {number} = {}
local litFlags: {number} = {}
--- Whether the world rectangle the camera sees is what decides if a layer's
--- contents are drawn.
local culledByView: {boolean} = {}

for index = 1, layers.MAX do
    sorts[index] = SORT_TOPDOWN
    modes[index] = MODE_CAMERA
    parallaxOffsets[index] = 0.0
    zoomFlags[index] = 0.0
    litFlags[index] = 1.0
    culledByView[index] = true
end

--- Bumped by every `configure`, so a consumer holding a packed copy of the
--- table can tell whether its copy is still the answer.
local revision = 0

--- A normalized sort term, with anything past either end resting on it.
---
--- Every sort divides a position by the extent the module was told to expect,
--- and a scene that reaches past that extent has to stop sorting rather than
--- carry the depth out of its band: the vertex shader recovers a layer by
--- multiplying a depth by `MAX`, so a term that left zero to one would hand
--- the geometry a different layer's positioning, parallax, zoom and lit flag.
--- Losing the order between two entities off the edge of the expected extent
--- is the smaller of those two failures by a wide margin.
local function saturate(value: number): number
    if value < 0.0 then
        return 0.0
    end
    if value > 1.0 then
        return 1.0
    end
    return value
end

function layers.configure(layer: integer, config: layers.Config)
    if layer < 1 or layer > layers.MAX then
        error(("tecs: layer %d is outside 1..%d"):format(layer, layers.MAX), 2)
    end
    local sort = SORT_IDS[config.sort]
    if sort == nil then
        error(("tecs: '%s' is not a sort mode"):format(tostring(config.sort)), 2)
    end
    if config.screenSpace and config.virtualCoords then
        error("tecs: a layer is positioned in screen pixels or in virtual " .. "coordinates, not both", 2)
    end

    local parallax = config.parallax
    if parallax == nil then
        parallax = 1.0
    end

    local mode = MODE_CAMERA
    if config.screenSpace then
        mode = MODE_SCREEN
    elseif config.virtualCoords then
        mode = MODE_VIRTUAL
    end

    sorts[layer] = sort
    modes[layer] = mode
    parallaxOffsets[layer] = 1.0 - parallax
    zoomFlags[layer] = config.ignoreZoom and 1.0 or 0.0
    litFlags[layer] = config.unlit and 0.0 or 1.0
    -- The cull tests a world rectangle against a world bound, which only means
    -- something where the camera places the contents where the bound says.
    culledByView[layer] = mode == MODE_CAMERA and parallax == 1.0 and not config.ignoreZoom
    revision = revision + 1
end

function layers.sortOf(layer: integer): integer
    return sorts[layer] or SORT_TOPDOWN
end

function layers.revision(): integer
    return revision
end

function layers.entryOf(layer: integer): number, number, number, number
    return modes[layer], parallaxOffsets[layer], zoomFlags[layer], litFlags[layer]
end

function layers.viewCulled(layer: integer): boolean
    local culled = culledByView[layer]
    if culled == nil then
        return true
    end
    return culled
end

function layers.depthOf(layer: integer, z: number, x: number, y: number): number
    -- The band is picked from a layer held inside the range there are bands
    -- for. A depth is the only thing that reaches the shader, and the shader
    -- reads the layer back out of it, so an entity outside the range has to
    -- take a real layer whole rather than land between two of them.
    local index = layer
    if index < 1 then
        index = 1
    elseif index > layers.MAX then
        index = layers.MAX
    end

    local band <const> = 1.0 / layers.MAX
    local base <const> = (layers.MAX - index) * band
    local sort <const> = sorts[index] or SORT_TOPDOWN
    local nz <const> = saturate(z / layers.maxZ)

    local within: number
    if sort == SORT_Z then
        within = (1.0 - nz) * band * BAND_FILL
    elseif sort == SORT_ISOMETRIC then
        local nx <const> = saturate((x + layers.maxY) / (2.0 * layers.maxY))
        local ny <const> = saturate((y + layers.maxY) / (2.0 * layers.maxY))
        -- Every term is already inside zero and one, so their sum is inside
        -- zero and the range and wants no clamp of its own.
        within = (1.0 - (nx + ny + nz) / ISOMETRIC_RANGE) * band * BAND_FILL
    else
        local ny <const> = saturate((y + layers.maxY) / (2.0 * layers.maxY))
        within = (1.0 - (nz * TOPDOWN_Z_SHARE + ny * TOPDOWN_Y_SHARE)) * band * BAND_FILL
    end

    local depth = base + within
    if depth < 0.001 then
        return 0.001
    end
    if depth > 0.999 then
        return 0.999
    end
    return depth
end

function layers.depthResolution(): number
    local span <const> = (1.0 / layers.MAX) * BAND_FILL
    -- One term per input each sort reads, in the order `depthOf` applies them,
    -- and each the depth a unit of that input is worth. A sort's own weight
    -- divided by the range it normalizes over.
    local steps <const>: {number} = {
        span * TOPDOWN_Z_SHARE / layers.maxZ,
        span * TOPDOWN_Y_SHARE / (2.0 * layers.maxY),
        span / layers.maxZ,
        span / ISOMETRIC_RANGE / layers.maxZ,
        span / ISOMETRIC_RANGE / (2.0 * layers.maxY),
    }

    local finest = steps[1]
    for index = 2, #steps do
        if steps[index] < finest then
            finest = steps[index]
        end
    end
    return finest
end

return layers
