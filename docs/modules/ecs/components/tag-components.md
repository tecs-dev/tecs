---
description: "Dataless presence tags via newTagComponent for flags, markers, and query filtering"
outline: deep
---

# Tag components

A tag has no per-entity value. Presence supplies the entire signal:

```teal
local Selected <const> =
    tecs.ecs.newTagComponent({name = "Selected"})
local Stunned <const> =
    tecs.ecs.newTagComponent({name = "Stunned"})

world:set(entity, Selected)
assert(world:has(entity, Selected))
world:remove(entity, Selected)
```

Use tags for flags, markers, and classifications. Use a scalar or structured
component when each entity needs a value.

`world:get` on a tag returns the tag container rather than row data. Prefer
`world:has` for a presence check.

## Query membership

Tags belong in query filters, not column loops:

```teal
local activeEnemies <const> = world:newQuery({
    include = {Enemy, Selected},
    exclude = {Stunned},
    type = "logic",
})

for archetype, length, entities in activeEnemies:iter() do
    local positions <const> = archetype:get(Position)
    for row = 1, length do
        updateSelection(entities[row], positions[row])
    end
end
```

The matching archetype signature already guarantees the tag's presence.

## Structural cost

Adding or removing a tag moves the entity between archetypes, just like any
component membership change. Use batch operations for large groups:

```teal
local targets <const> = world:newQuery({
    include = {Enemy, InBlastRadius},
    temp = true,
})

world:batchSet(targets, Stunned)

local stunnedEnemies <const> = world:newQuery({
    include = {Enemy, Stunned},
    temp = true,
})

world:batchRemove(stunnedEnemies, Stunned)
```

`Disabled` causes every ordinary query to exclude the entity unless the query
explicitly includes that tag. `Paused` remains visible to render work;
`type = "logic"` excludes it.

The [state stack](/modules/ecs/states) creates a tag for each named state and adds the
current top state's tag to new entities.
