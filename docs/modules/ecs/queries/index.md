---
description: "Creating and iterating queries with include, exclude, includeAny, temp, cursors, and deferred mutations"
outline: deep
---

# Queries

A query tracks archetypes whose component signatures match one descriptor:

```teal
local Transform <const> = tecs.Transform
local movers <const> = world:query({
    name = "game.Movers",
    include = {Transform, Velocity},
    exclude = {Frozen},
    type = "logic",
})

for archetype, length, entities in movers:iter() do
    local transforms <const> = archetype:getMut(Transform)
    local velocities <const> = archetype:get(Velocity)

    for row = 1, length do
        transforms[row].x = transforms[row].x + velocities[row].x * dt
        print(entities[row])
    end
end
```

`include` requires every listed component. `exclude` rejects every archetype
with a listed component. `includeAny` adds an OR group:

```teal
local drawn <const> = world:query({
    include = {tecs.Transform, tecs.gfx.Renderable},
    includeAny = {tecs.gfx.Sprite, tecs.gfx.Material},
    type = "render",
})
```

A query exposes its descriptor for inspection. Tecs owns the compiled masks,
subscriptions, and grouping state; callers must treat the descriptor as
read-only after construction. Changing it does not rebuild the query.

## Archetype iteration

`query:iter()` yields each non-empty matching archetype, its row count, and its
entity-ID column. Tecs owns the entity-ID column; callers treat it as
read-only.

Bind each component column once per archetype. `archetype:get` gives a
read-only access path. `archetype:getMut` gives caller-writable values and
marks that component dirty:

```teal
for archetype, length in movers:iter() do
    local transforms <const> = archetype:getMut(Transform)
    local velocities <const> = archetype:get(Velocity)

    for row = 1, length do
        local transform <const> = transforms[row]
        local velocity <const> = velocities[row]
        transform.x = transform.x + velocity.x * dt
        transform.y = transform.y + velocity.y * dt
    end
end
```

LuaJIT cannot enforce const cdata, so writing through `get` may change memory
without dirtying it. Use `getMut` for unconditional writes. For a conditional
write, read through `get` and call
`archetype:markComponentDirty(Component)` only when the write occurs.

`query:count()` sums archetype lengths without visiting entity rows.

Iteration supports nesting, including two loops over the same query. Each loop
owns a scope, and mutations drain after the outermost loop finishes.

## Structural changes

Archetype iteration opens a deferred scope. Structural calls such as `spawn`,
`despawn`, `set`, `remove`, and batch operations stage until the loop
finishes:

```teal
local expiring <const> = world:query({
    include = {tecs.ecs.TTL},
    type = "logic",
})

for archetype, length, entities in expiring:iter() do
    local ttls <const> = archetype:getMut(tecs.ecs.TTL)
    for row = 1, length do
        ttls[row].remaining = ttls[row].remaining - dt
        if ttls[row].remaining <= 0 then
            world:despawn(entities[row])
        end
    end
end
```

The drain applies despawns, spawns, and archetype moves after iterator
exhaustion. The [mutation model](/modules/ecs/mutation-model) defines visibility and
ordering.

### Early exit {#breaking-out-early}

`query:iter()` closes its scope only when the archetype loop reaches
exhaustion. A loop that may `break` or return must use a cursor:

```teal
local cursor <const> = query:cursor()

for archetype, _length, entities in cursor:iter() do
    if matchesSelection(archetype) then
        selected = entities[1]
        break
    end
end

cursor:close()
```

`cursor:close()` tolerates repeated calls and natural exhaustion. Call it
immediately before returning from inside the loop. Cursors also support
`groups()` and `group(id)`, but each cursor owns one traversal and rejects a
second.

Breaking only the inner row loop leaves the archetype iterator running, so it
does not require a cursor.

## Persistent and temporary queries

Persistent queries subscribe to new archetypes and remain suitable for systems
that run every frame. Build them once during plugin setup.

`temp = true` takes a one-shot view of the current archetype set without
registering observers:

```teal
for archetype, length in world:query({
    include = {tecs.gfx.PointLight},
    temp = true,
}):iter() do
    inspectLights(archetype, length)
end
```

A temporary query cannot define `onEntitiesAdded` or `onEntitiesRemoved`.
[Query callbacks](/modules/ecs/queries/callbacks) cover persistent match-set
reactions. [Grouping](/modules/ecs/queries/grouping) sorts matching archetypes under
integer keys.

## Disabled entities {#disabled-entities}

Every query excludes `tecs.ecs.Disabled` unless `include` explicitly names the
tag. Renderer queries follow the same rule.

```teal
local disabledRenderables <const> = world:query({
    include = {
        tecs.Transform,
        tecs.gfx.Renderable,
        tecs.ecs.Disabled,
    },
})
```

## Paused entities {#paused-entities}

`type = "logic"` excludes `tecs.ecs.Paused`. `type = "render"` records that
paused entities should continue to match. An omitted type applies no pause
filter.

```teal
local movement <const> = world:query({
    include = {tecs.Transform, Velocity},
    type = "logic",
})

local sprites <const> = world:query({
    include = {tecs.Transform, tecs.gfx.Sprite},
    type = "render",
})
```

Explicitly including `Paused` overrides the filter. Listing it under `exclude`
matches the logic behavior.

## One-component archetype scans

`world:findArchetypes(Component)` walks the component-to-archetype index
without constructing a query:

```teal
for archetype, length, entities
    in world:findArchetypes(tecs.gfx.PointLight)
do
    local lights <const> = archetype:get(tecs.gfx.PointLight)
    for row = 1, length do
        print(entities[row], lights[row].radius)
    end
end
```

This iterator opens no deferred scope. Do not make structural changes while it
runs.
