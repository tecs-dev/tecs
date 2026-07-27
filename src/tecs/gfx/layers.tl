--- Layer bands and the depth they resolve to.
---
--- A layer is a band of the depth range, and everything drawn on it sorts
--- within that band and never against another one. Higher layers are nearer,
--- so a HUD on layer 8 covers a world on layer 1 whatever the two contain.
---
--- The formula is fixed rather than configurable. Content is authored against
--- what it produces: change how a layer maps to depth and every scene built on
--- it re-sorts, which is a change nobody can see coming from the diff. What is
--- configurable is how a layer sorts within its own band.

local record layers
    --- Bands the depth range divides into.
    ---
    --- Load-bearing at sixteen. A sort mode packs into two bits and the masks
    --- that later features hang off a layer are single words, both of which
    --- are sized to this. Raising it is not a constant change.
    MAX: integer

    --- Highest z a scene is expected to use, which sets the resolution of
    --- sorting within a band rather than a limit on the value.
    maxZ: number

    --- Half the world extent a scene is expected to occupy, for normalising
    --- position into a band. A scene larger than this still sorts, with
    --- entities beyond the edge compressed against it.
    maxY: number

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

    record Config
        sort: Sort
    end
end

layers.MAX = 16
layers.maxZ = 1000.0
layers.maxY = 10000.0

local SORT_TOPDOWN <const> = 0
local SORT_Z <const> = 1
local SORT_ISOMETRIC <const> = 2

local SORT_IDS <const>: {string: integer} = {
    topdown = SORT_TOPDOWN,
    z = SORT_Z,
    isometric = SORT_ISOMETRIC,
}

--- Per-layer sort, indexed one-based. Layers default to topdown, which is what
--- a scene wants before anyone has said otherwise.
local sorts: {integer} = {}
for index = 1, layers.MAX do sorts[index] = SORT_TOPDOWN end

--- Sets how a layer sorts within its band.
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
    sorts[layer] = sort
end

--- How a layer sorts, as the identifier `depthOf` takes.
function layers.sortOf(layer: integer): integer
    return sorts[layer] or SORT_TOPDOWN
end

--- Depth for one entity, in zero to one with zero nearest.
---
--- Exact ties carry no tie-breaker. Instances are drawn in index order and the
--- depth test lets an equal fragment through, so two entities at the same
--- depth already resolve the same way every frame: the later one wins. Nudging
--- depth by identity would resolve them the other way, since a larger value is
--- farther, and quietly invert the order a scene was built expecting.
function layers.depthOf(layer: integer, z: number, x: number,
                        y: number): number
    local band <const> = 1.0 / layers.MAX
    local base <const> = (layers.MAX - layer) * band
    local sort <const> = sorts[layer] or SORT_TOPDOWN

    local within: number
    if sort == SORT_Z then
        within = (1.0 - z / layers.maxZ) * band * 0.99
    elseif sort == SORT_ISOMETRIC then
        local nx = (x + layers.maxY) / (2.0 * layers.maxY)
        local ny = (y + layers.maxY) / (2.0 * layers.maxY)
        local iso = nx + ny + z / layers.maxZ
        if iso < 0.0 then iso = 0.0 elseif iso > 3.0 then iso = 3.0 end
        within = (1.0 - iso / 3.0) * band * 0.99
    else
        local ny = (y + layers.maxY) / (2.0 * layers.maxY)
        within = (1.0 - (z / layers.maxZ * 0.7 + ny * 0.3)) * band * 0.99
    end

    local depth = base + within
    if depth < 0.001 then return 0.001 end
    if depth > 0.999 then return 0.999 end
    return depth
end

return layers
