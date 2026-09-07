---
description: "Dataless presence tags via newTagComponent for flags, markers, and query filtering"
outline: deep
---

# Tag components

A tag has no per-entity value. Presence supplies the entire signal:

```nupp
local Selected =
    tecs.ecs.newTagComponent({name = "Selected"})
local Stunned =
    tecs.ecs.newTagComponent({name = "Stunned"})

world:set(entity, Selected)
world:commit()
assert(world:has(entity, Selected))
world:remove(entity, Selected)
```

Use tags for flags, markers, and classifications. Use a scalar or structured
component when each entity needs a value.

`world:get` on a tag returns the tag container rather than row data. Prefer
`world:has` for a presence check.

## Query membership

Tags belong in query filters, not column loops:

```nupp
local activeEnemies = world:newQuery({
    include = {Enemy, Selected, Position},
    exclude = {Stunned, tecs.ecs.Disabled, tecs.ecs.Paused},
})

for archetype, length in activeEnemies:iter() do
    local entities = archetype.entities
    local positions = assert(archetype:get(Position))
    for row = 1, length as integer do
        updateSelection(entities[row], positions[row])
    end
end
```

The matching archetype signature already guarantees the tag's presence.

## Structural cost

Adding or removing a tag moves the entity between archetypes, just like any
component membership change. Stage the changes while iterating a query; the
pipeline publishes them after the phase.

```nupp
for archetype, count in targets:iter() do
    for row = 1, count as integer do
        world:set(archetype.entities[row], Stunned)
    end
end
```

Exclude `Disabled` and `Paused` explicitly from logic queries. The renderer
excludes disabled entities and continues drawing paused ones.

The [state stack](/ecs/states.md) creates a tag for each named state and adds the
current top state's tag to new entities.
