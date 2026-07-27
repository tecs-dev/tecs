--- Layer bands, the depth they resolve to, and what a layer does to its
--- contents.
---
--- A layer is a band of the depth range, and everything drawn on it sorts
--- within that band and never against another one. Higher layers are nearer,
--- so a HUD on layer 8 covers a world on layer 1 whatever the two contain.
---
--- The band formula is fixed rather than configurable. Content is authored
--- against what it produces: change how a layer maps to depth and every scene
--- built on it re-sorts, which is a change nobody can see coming from the diff.
---
--- What a layer does configure is how its contents sort within its own band,
--- where they are positioned, and whether they are lit. Those decide where a
--- game puts a thing, so they are settled before content is authored rather
--- than after: whether a layer is screen-space is the difference between a HUD
--- written in pixels and one written in world units.

local record layers
    --- Bands the depth range divides into.
    ---
    --- Load-bearing at sixteen. A sort mode packs into two bits, the table the
    --- vertex shader reads is sized to it, and the shader recovers a layer by
    --- multiplying a depth by it. `LAYER_BANDS` in
    --- `assets/shaders/instance.vert.glsl` is the same number, and the two only
    --- work while they agree. Raising it is not a constant change.
    MAX: integer

    --- Highest z a scene is expected to use, which sets the resolution of
    --- sorting within a band. A scene reaching past this still draws, with
    --- entities beyond the edge resting on it and no longer sorting against
    --- each other.
    maxZ: number

    --- Half the world extent a scene is expected to occupy, for normalising
    --- position into a band. A scene larger than this still sorts, with
    --- entities beyond the edge compressed against it.
    maxY: number

    --- The resolution a virtual-coordinate layer is authored in.
    ---
    --- One resolution for every such layer, because it is the design size a
    --- layout is drawn against and a game has one of those. It is scaled to
    --- fill the target, so the layout keeps its proportions within itself at
    --- any window size and stretches with the window's aspect.
    virtualWidth: number
    virtualHeight: number

    enum Sort
        --- Lower on the screen draws in front, with z breaking ties. What a
        --- top-down or side-on game wants: a character below a crate is in
        --- front of it.
        "topdown"
        --- Only z decides. What a HUD wants, where position means nothing and
        --- the author has said what covers what.
        "z"
        --- X plus Y plus z, for a diamond grid where both axes move an entity
        --- towards the viewer.
        "isometric"
    end

    --- Everything a layer decides about its contents. A field left out takes
    --- its default, so this says what a layer is rather than amending what it
    --- was.
    record Config
        --- How contents sort within the layer's band. Required: a sort is the
        --- one thing every layer has an opinion about.
        sort: Sort
        --- Contents are positioned in screen pixels and ignore the camera
        --- entirely. What a HUD wants. Defaults to false.
        screenSpace: boolean
        --- Contents follow the camera's position but not its zoom, so they
        --- stay a constant size on screen while moving with the world.
        --- Defaults to false.
        ignoreZoom: boolean
        --- Contents are positioned in `virtualWidth` by `virtualHeight`, which
        --- is scaled to fill the target. Defaults to false, and cannot be
        --- combined with `screenSpace`.
        virtualCoords: boolean
        --- Contents bypass the lighting pass and appear at their own colour.
        --- Defaults to false. A material can ask for the same thing, and a
        --- fragment is lit only where the material and the layer agree.
        unlit: boolean
        --- How much the camera's position carries the contents. One moves them
        --- with the world; a half drifts them at half speed, which is what a
        --- background wants. Defaults to one.
        parallax: number
    end

    --- Sets what a layer does with its contents.
    ---
    --- Replaces the layer's configuration rather than amending it: a `Config`
    --- is the whole of what a layer is, so a field left out is that field's
    --- default and not whatever the layer held before.
    --- @param layer One to `MAX`. Anything else raises.
    --- @param config Raises on a missing or unknown `sort`, and on asking for
    ---     `screenSpace` and `virtualCoords` together.
    configure: function(layer: integer, config: layers.Config)

    --- How a layer sorts, as the identifier `depthOf` takes.
    --- @param layer One to `MAX`. Outside that this answers topdown rather than
    ---     raising, since it is the default every layer starts on.
    --- @return The sort identifier, which is an internal number and not one of
    ---     the `Sort` strings.
    sortOf: function(layer: integer): integer

    --- How many times the table has been configured.
    --- @return A count that starts at zero and only rises. A consumer compares
    ---     it against the value it packed at, so the number itself means
    ---     nothing beyond having changed.
    revision: function(): integer

    --- The four floats the vertex shader reads for one layer: its mode, its
    --- parallax offset factor, whether it ignores zoom, and whether it is lit.
    ---
    --- Handed over as a group because they are packed as a group, which happens
    --- when `revision` moves rather than every frame.
    --- @param layer One to `MAX`. Outside that every return is nil, since only
    ---     that range is ever filled in.
    --- @return The positioning mode, then the camera position's multiplier,
    ---     then one when the layer ignores zoom, then one when it is lit.
    entryOf: function(layer: integer): number, number, number, number

    --- Whether the camera's view rectangle decides if this layer is drawn.
    ---
    --- False on a layer the camera does not place where its world bound says:
    --- screen-space and virtual-coordinate contents have no world position for
    --- the view to test, and parallax and ignore-zoom draw them somewhere the
    --- bound does not describe. Extraction reads this per row and writes a
    --- bound no view can be outside of for those, so the layer is drawn
    --- whatever the camera is looking at. Culling is given up on a layer that
    --- asks for one of these, and kept exactly on every layer that does not.
    --- @param layer One to `MAX`. Outside that this answers true, which is what
    ---     an unconfigured layer answers too.
    --- @return Whether extraction should write this row's real world bound.
    viewCulled: function(layer: integer): boolean

    --- Depth for one entity, in zero to one with zero nearest.
    ---
    --- Exact ties carry no tie-breaker. Instances are drawn in index order and
    --- the depth test lets an equal fragment through, so two entities at the
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
    --- @return A depth inside the layer's own band, whatever the arguments
    ---     were: each of them is normalised and then held to zero and one, so
    ---     a scene reaching past what the module was told to expect stops
    ---     sorting rather than spilling into the next layer.
    depthOf: function(layer: integer, z: number, x: number, y: number): number
end

layers.MAX = 16
layers.maxZ = 1000.0
layers.maxY = 10000.0
layers.virtualWidth = 1920.0
layers.virtualHeight = 1080.0

local SORT_TOPDOWN <const> = 0
local SORT_Z <const> = 1
local SORT_ISOMETRIC <const> = 2

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

--- A normalised sort term, with anything past either end resting on it.
---
--- Every sort divides a position by the extent the module was told to expect,
--- and a scene that reaches past that extent has to stop sorting rather than
--- carry the depth out of its band: the vertex shader recovers a layer by
--- multiplying a depth by `MAX`, so a term that left zero to one would hand
--- the geometry a different layer's positioning, parallax, zoom and lit flag.
--- Losing the order between two entities off the edge of the expected extent
--- is the smaller of those two failures by a wide margin.
local function saturate(value: number): number
    if value < 0.0 then return 0.0 end
    if value > 1.0 then return 1.0 end
    return value
end

function layers.configure(layer: integer, config: layers.Config)
    if layer < 1 or layer > layers.MAX then
        error(("tecs: layer %d is outside 1..%d")
            :format(layer, layers.MAX), 2)
    end
    local sort = SORT_IDS[config.sort]
    if sort == nil then
        error(("tecs: '%s' is not a sort mode")
            :format(tostring(config.sort)), 2)
    end
    if config.screenSpace and config.virtualCoords then
        error("tecs: a layer is positioned in screen pixels or in virtual "
            .. "coordinates, not both", 2)
    end

    local parallax = config.parallax
    if parallax == nil then parallax = 1.0 end

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
    culledByView[layer] = mode == MODE_CAMERA and parallax == 1.0
        and not config.ignoreZoom
    revision = revision + 1
end

function layers.sortOf(layer: integer): integer
    return sorts[layer] or SORT_TOPDOWN
end

function layers.revision(): integer
    return revision
end

function layers.entryOf(layer: integer): number, number, number, number
    return modes[layer], parallaxOffsets[layer],
        zoomFlags[layer], litFlags[layer]
end

function layers.viewCulled(layer: integer): boolean
    local culled = culledByView[layer]
    if culled == nil then return true end
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
        within = (1.0 - nz) * band * 0.99
    elseif sort == SORT_ISOMETRIC then
        local nx <const> = saturate((x + layers.maxY) / (2.0 * layers.maxY))
        local ny <const> = saturate((y + layers.maxY) / (2.0 * layers.maxY))
        -- Every term is already inside zero and one, so their sum is inside
        -- zero and three and wants no clamp of its own.
        within = (1.0 - (nx + ny + nz) / 3.0) * band * 0.99
    else
        local ny <const> = saturate((y + layers.maxY) / (2.0 * layers.maxY))
        within = (1.0 - (nz * 0.7 + ny * 0.3)) * band * 0.99
    end

    local depth = base + within
    if depth < 0.001 then return 0.001 end
    if depth > 0.999 then return 0.999 end
    return depth
end

return layers
