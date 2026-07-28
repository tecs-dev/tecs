---
description: "Grouping matching archetypes by integer key with groupBy, groups, group, getGroup, and getGroupCount"
outline: deep
---

# Query grouping

Use the `groupBy` option to group matching archetypes by an integer key. Archetypes with the same group are iterated
contiguously, so systems can switch state once per group and process a whole batch before moving to the next one.

The engine's own extraction does not need this, because the renderer is GPU-driven: every renderable goes into one
instance buffer and a compute pass culls and orders it, so there is no per-batch CPU state to switch. Grouping is
for the code above that, where the setup around each entity is the expensive part.

## When to reach for it

Grouping pays off whenever per-entity work is cheap but the _setup around it_ is not. Rendering is the obvious case,
and gameplay has the same shape:

- **Factions and teams.** Group by team tag, then resolve each team's shared target list, threat table, or morale
  once instead of per unit.
- **Per-material or per-tileset logic.** Group by the asset an archetype uses so a lookup, atlas bind, or config
  fetch happens once per group.
- **AI tiers.** Group by behavior class so the expensive planner runs once for a batch of identical agents.
- **Spatial buckets.** Group by region or chunk id so a system can skip whole groups that are far from the camera.

The rule of thumb: if your inner loop starts with "look up the thing this entity belongs to," that lookup probably
belongs at group level.

## Basic usage

The `groupBy` function receives an archetype and returns an integer. Tecs calls it once as each archetype starts
matching the query and stores the key with the archetype, so iteration can keep same-key archetypes together.

```teal
local Transform <const> = tecs.builtins.Transform
local Renderable <const> = tecs.components.Renderable
local Sprite <const> = tecs.components.Sprite
local Material <const> = tecs.components.Material

local Kind <const> = { Textured = 1, Shaded = 2, Flat = 3 }

local renderables = world:query({
    include = {Transform, Renderable},
    groupBy = function(archetype: tecs.Archetype): integer
        if archetype:get(Sprite) then return Kind.Textured end
        if archetype:get(Material) then return Kind.Shaded end
        return Kind.Flat
    end,
})
```

`archetype:get` returns nil when the archetype does not carry the column, which is what makes presence tests like
these work. The key is computed once per archetype, when the archetype starts matching the query, not once per
frame, so `groupBy` must depend only on the archetype's component signature and never on a row's values.

## Iterating by group

Use `groups()` to iterate active group IDs in sorted order, and `group(id)` to iterate archetypes within a specific
group. This pattern keeps per-group setup outside the inner entity loop:

```teal
for kind in renderables:groups() do
    beginBatch(kind)                -- resolve the shared state once
    for archetype, len, entities in renderables:group(kind) do
        local transforms = archetype:get(Transform)
        for row = 1, len do
            -- ...
        end
    end
    endBatch()
end
```

Only groups with at least one non-empty archetype appear in `groups()`; a group whose archetypes have all emptied
drops out of the list until one refills.

Both `groups()` and `group(id)` open and close the same deferred scope `iter()` does, so mutations staged inside
them apply when the outermost loop finishes.

## Getting an archetype's group

Use `getGroup(archetype)` to retrieve the cached group ID for an archetype:

```teal
for archetype, len, entities in renderables:iter() do
    local kind = renderables:getGroup(archetype)
    -- kind is the integer returned by groupBy for this archetype
end
```

## Getting group entity counts

Use `getGroupCount(groupId)` to get the total number of entities in a group without iterating it.
This is useful for pre-allocating buffers or computing memory layouts:

```teal
-- Pre-calculate buffer offsets for each group
local offsets = {}
local currentOffset = 0
for groupId in renderables:groups() do
    offsets[groupId] = currentOffset
    currentOffset = currentOffset + renderables:getGroupCount(groupId)
end

-- Now stream data using pre-calculated offsets
for groupId in renderables:groups() do
    local baseOffset = offsets[groupId]
    for archetype, len in renderables:group(groupId) do
        -- Write to buffer at baseOffset
        baseOffset = baseOffset + len
    end
end
```

This two-pass pattern calculates offsets per group, then streams each group's contiguous run of entities in order.

If a `groups()` or `group(id)` loop may break early, use a separate
[`query:cursor()`](/ecs/queries/#breaking-out-early) for that traversal and call `cursor:close()` after the loop.
A cursor owns one traversal, so nested grouped loops need one cursor each.

Note that `getGroup()` returns `nil`, `groups()` and `group()` yield nothing, and `getGroupCount()` returns `0`
when `groupBy` is not specified on the query.
