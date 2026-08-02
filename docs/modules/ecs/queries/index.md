---
description: "Creating and iterating queries with include, exclude, includeAny, temp, cursors, and deferred mutations"
outline: deep
---

# Queries

A query tracks archetypes whose component signatures match one descriptor:

```teal
local Transform2D <const> = tecs.Transform2D
local movers <const> = world:newQuery({
    name = "game.Movers",
    include = {Transform2D, Velocity},
    exclude = {Frozen},
    type = "logic",
})

for archetype, length, entities in movers:iter() do
    local transforms <const> = archetype:getMut(Transform2D)
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
local drawn <const> = world:newQuery({
    include = {tecs.Transform2D, tecs.gfx.Renderable2D},
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
    local transforms <const> = archetype:getMut(Transform2D)
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

Iteration supports nesting, including two loops over the same query. Iterators
own traversal state only; they do not control structural transaction lifetime.

## Structural changes

Structural calls such as `spawn`, `despawn`, component-adding `set`, `remove`,
and batch operations always stage. Iteration continues over the committed rows
and the pipeline publishes at its next declared barrier:

```teal
local expiring <const> = world:newQuery({
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

Iterator exhaustion does not publish those changes. The
[mutation model](/modules/ecs/mutation-model) defines their visibility and
ordering.

### Early exit {#breaking-out-early}

An early `break` is safe because iteration owns no transaction scope. Use a
cursor when code needs a closable traversal object:

```teal
local cursor <const> = query:newCursor()

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
for archetype, length in world:newQuery({
    include = {tecs.gfx.PointLight2D},
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
local disabledRenderables <const> = world:newQuery({
    include = {
        tecs.Transform2D,
        tecs.gfx.Renderable2D,
        tecs.ecs.Disabled,
    },
})
```

## Paused entities {#paused-entities}

`type = "logic"` excludes `tecs.ecs.Paused`. `type = "render"` records that
paused entities should continue to match. An omitted type applies no pause
filter.

```teal
local movement <const> = world:newQuery({
    include = {tecs.Transform2D, Velocity},
    type = "logic",
})

local sprites <const> = world:newQuery({
    include = {tecs.Transform2D, tecs.gfx.Sprite},
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
    in world:findArchetypes(tecs.gfx.PointLight2D)
do
    local lights <const> = archetype:get(tecs.gfx.PointLight2D)
    for row = 1, length do
        print(entities[row], lights[row].radius)
    end
end
```

This iterator reads the live archetype index directly. Do not make structural
changes while it runs; call it only where the surrounding scheduler contract
keeps publication out of the traversal.
