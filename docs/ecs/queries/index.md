---
description: "Creating and iterating queries with include, exclude and deferred mutations"
outline: deep
---

# Queries

A query tracks archetypes whose component signatures match one descriptor:

```nupp
local Transform2D = tecs.ecs.Transform2D
local movers = world:newQuery({
    include = {Transform2D, Velocity},
    exclude = {Frozen, tecs.ecs.Disabled, tecs.ecs.Paused},
})

for archetype, length in movers:iter() do
    local entities = archetype.entities
    local transforms = assert(archetype:getMut(Transform2D))
    local velocities = assert(archetype:get(Velocity))
    for row = 1, length as integer do
        transforms[row].x = transforms[row].x + velocities[row].x * dt
        print(entities[row])
    end
end
```

`include` requires every listed component. `exclude` rejects every archetype
with a listed component. Build the descriptor before creating the query. Include and exclude constraints
are fixed for its lifetime.

## Archetype iteration

`query:iter()` yields each non-empty matching archetype, and its row count. The archetype exposes its
entity-ID column as `entities`. Tecs owns the entity-ID column; callers treat it as
read-only.

Bind each component column once per archetype. `archetype:get` gives a
read-only access path. `archetype:getMut` gives caller-writable values and
marks that component dirty:

```nupp
for archetype, length in movers:iter() do
    local transforms = assert(archetype:getMut(Transform2D))
    local velocities = assert(archetype:get(Velocity))
    for row = 1, length as integer do
        local transform = transforms[row]
        local velocity = velocities[row]
        transform.x = transform.x + velocity.x * dt
        transform.y = transform.y + velocity.y * dt
    end
end
```

Writing through `get` may change a value
without dirtying it. Use `getMut` for unconditional writes. For a conditional
write, read through `get` and call
`archetype:markComponentDirty(Component)` only when the write occurs.

Sum the counts yielded by `iter()` to count matches without visiting rows.

Iteration supports nesting, including two loops over the same query. Iterators
own traversal state only; they do not control structural transaction lifetime.

## Structural changes

Structural calls such as `spawn`, `despawn`, component-adding `set`, and `remove`
always stage. Iteration continues over the committed rows
and the pipeline publishes at its next declared barrier:

```nupp
local expiring = world:newQuery({
    include = {tecs.ecs.TTL},
    exclude = {tecs.ecs.Disabled, tecs.ecs.Paused},
})

for archetype, length in expiring:iter() do
    local entities = archetype.entities
    local ttls = assert(archetype:getMut(tecs.ecs.TTL))
    for row = 1, length as integer do
        ttls[row].remaining = ttls[row].remaining - dt
        if ttls[row].remaining <= 0 then
            world:despawn(entities[row])
        end
    end
end
```

Iterator exhaustion does not publish those changes. The
[world guide](/ecs/world.md#structural-transactions) defines their visibility and
ordering.

### Early exit {#breaking-out-early}

An early `break` or `return` is safe because iteration owns no transaction
scope or resource that needs cleanup:

```nupp
for archetype, _length in query:iter() do
    local entities = archetype.entities
    if matchesSelection(archetype) then
        selected = entities[1]
        break
    end
end
```

Nested and interleaved
loops keep independent traversal state, including multiple loops over the same
query.

## Persistent queries

Queries subscribe to new archetypes and remain suitable for systems that run
every frame. Build them once during plugin setup. Do not create a new query
inside every `run` call.

## Disabled entities {#disabled-entities}

Exclude `tecs.ecs.Disabled` explicitly in game queries. Rendering excludes this
tag, so disabled entities stop drawing.

```nupp
local movement = world:newQuery({
    include = {tecs.ecs.Transform2D, Velocity},
    exclude = {tecs.ecs.Disabled, tecs.ecs.Paused},
})
```

## Paused entities {#paused-entities}

Exclude `tecs.ecs.Paused` in logic queries when paused entities should stop
moving. Render extraction keeps paused entities visible. Listing the tag in
`include` instead selects paused entities for inspection.
