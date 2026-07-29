---
description: "Grouping matching archetypes by integer key with groupBy, groups, group, getGroup, and getGroupCount"
outline: deep
---

# Query grouping

Grouping keeps matching archetypes with the same integer key together. Use it
when each group needs expensive setup that should not run for every entity.

```teal
local Kind <const> = {
    Textured = 1,
    Shaded = 2,
    Flat = 3,
}

local renderables <const> = world:query({
    include = {tecs.Transform, tecs.gfx.Renderable},
    groupBy = function(archetype: tecs.ecs.Archetype): integer
        if archetype:get(tecs.gfx.Sprite) then
            return Kind.Textured
        end
        if archetype:get(tecs.gfx.Material) then
            return Kind.Shaded
        end
        return Kind.Flat
    end,
})
```

Tecs computes the key when an archetype begins matching and caches it.
`groupBy` must therefore depend only on the component signature, never on row
values or mutable external state.

## Group traversal

`groups()` yields active keys in sorted order. `group(key)` yields the
nonempty archetypes for one key:

```teal
for kind in renderables:groups() do
    beginBatch(kind)

    for archetype, length in renderables:group(kind) do
        local transforms <const> =
            archetype:get(tecs.Transform)

        for row = 1, length do
            drawRow(transforms[row])
        end
    end

    endBatch()
end
```

An empty group disappears from `groups()` until one of its archetypes fills
again.

`getGroup(archetype)` returns the cached key. `getGroupCount(key)` sums the
entities in that group without visiting rows, which supports two-pass buffer
layout:

```teal
local offset = 0
local offsets: {integer: integer} = {}

for key in renderables:groups() do
    offsets[key] = offset
    offset = offset + renderables:getGroupCount(key)
end
```

Grouped iteration opens the same deferred scope as `query:iter()`. Use a
separate [cursor](/ecs/queries/#breaking-out-early) for any traversal that may
stop early, and close it after the loop. Nested grouped traversals need one
cursor each.
