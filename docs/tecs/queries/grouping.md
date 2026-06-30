---
outline: deep
---

# Query grouping

Use the `groupBy` option to group archetypes by an integer key. Archetypes with the same group are iterated
contiguously, enabling efficient batch processing without per-frame sorting. This is useful when you need to
process entities in groups. For example, Tecs uses this internally to efficiently group draws by blend mode.

## Basic usage

The `groupBy` function receives an archetype and returns an integer. Archetypes are sorted by this value,
so archetypes with the same key are iterated together. The sort is efficient and happens as archetypes match
the query.

```teal
local BlendMode <const> = { Alpha = 1, Additive = 2, Multiply = 3 }

local blendQuery = world:query({
    include = {Sprite, Transform},
    includeAny = {AlphaBlend, AdditiveBlend, MultiplyBlend},
    groupBy = function(archetype: tecs.Archetype): integer
        if archetype:get(AlphaBlend) then return BlendMode.Alpha end
        if archetype:get(AdditiveBlend) then return BlendMode.Additive end
        if archetype:get(MultiplyBlend) then return BlendMode.Multiply end
        return 0
    end,
})
```

## Iterating by group

Use `groups()` to iterate active group IDs in sorted order, and `group(id)` to iterate archetypes within
a specific group. This pattern lets you switch render state once per group rather than checking on every
archetype:

```teal
for blendMode in blendQuery:groups() do
    love.graphics.setBlendMode(blendModeToLove[blendMode])
    for archetype, len, entities in blendQuery:group(blendMode) do
        -- Draw all sprites with this blend mode
        for row = 1, len do
            -- ...
        end
    end
end
```

## Getting an archetype's group

Use `getGroup(archetype)` to retrieve the cached group ID for an archetype:

```teal
for archetype, len, entities in blendQuery:iter() do
    local blendMode = blendQuery:getGroup(archetype)
    -- blendMode is the integer returned by groupBy for this archetype
end
```

## Getting group entity counts

Use `getGroupCount(groupId)` to get the total number of entities in a group without iterating.
This is useful for pre-allocating buffers or computing memory layouts:

```teal
-- Pre-calculate buffer offsets for each group
local offsets = {}
local currentOffset = 0
for groupId in query:groups() do
    offsets[groupId] = currentOffset
    currentOffset = currentOffset + query:getGroupCount(groupId)
end

-- Now stream data using pre-calculated offsets
for groupId in query:groups() do
    local baseOffset = offsets[groupId]
    for archetype, len in query:group(groupId) do
        -- Write to buffer at baseOffset
        baseOffset = baseOffset + len
    end
end
```

This two-pass pattern enables O(groups) offset calculation followed by O(entities) streaming,
which is much faster than sorting or random-access writes.

Note that `groups()`, `group()`, `getGroup()`, and `getGroupCount()` return `nil`, empty iterators,
or 0 when `groupBy` is not specified on the query.
