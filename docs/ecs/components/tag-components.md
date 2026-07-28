---
description: "Dataless presence tags via newTagComponent for flags, markers, and query filtering"
outline: deep
---

# Tag Components

A **tag component** is a component with no data. Its presence on an entity is the entire signal. A tag's
column holds no per-row state at all: reads resolve to the tag container itself and writes are no-ops, so
membership costs nothing beyond the archetype's signature bit.

If you need a refresher on the shared component model first, start with
[Component Construction](/ecs/components/construction). For the broader component taxonomy, see the
[Components overview](/ecs/components/). If you want the same presence-only idea but scoped to a relationship
target, see [Relationships](/ecs/relationships/) (a `newRelationship` with just a name is the presence-only,
target-only form) and [FFI Relationships](/ecs/relationships/ffi).

Use tags for flags, markers, and classification: "this entity is `Selected`", "this mob is `Stunned`", "this
node is a `SpawnPoint`". Anything that reduces to "is this entity part of group X?" is a good fit.

## Creating a tag component

Create a tag with `tecs.newTagComponent`:

```teal
local Selected = tecs.newTagComponent({name = "Selected"})
local Stunned = tecs.newTagComponent({name = "Stunned"})
```

```teal
function tecs.newTagComponent(options: TagComponentOptions): Component
```

| Property    | Description                                                                                                                    |
| ----------- | ------------------------------------------------------------------------------------------------------------------------------ |
| `name`      | (**required**) The component name.                                                                                             |
| `requires`  | Array of components to auto-add alongside this tag. See [Auto-dependencies](/ecs/components/#auto-dependencies-with-requires). |
| `container` | Optional pre-declared container to register as the tag. Rarely needed; one is created otherwise.                               |
| `transient` | If `true`, omit this tag from snapshots. Mutually exclusive with `serialize`.                                                  |

**Returns:** the registered tag component.

## Adding, removing, and testing tags

Tags use the standard component API:

```teal
world:set(entityId, Selected)        -- add
world:remove(entityId, Selected)     -- remove
world:has(entityId, Selected)        -- presence check (boolean)
```

`world:has` is the read you want. `world:get` on a tag resolves to the tag container itself rather than
per-entity data, because there is no per-entity data to return.

You can also spawn an entity directly with tags:

```teal
world:spawn(Position(0, 0), Enemy, Hostile)
```

## Using tags in queries

Tags slot into query descriptors like any other component:

```teal
-- All selected enemies:
world:query({include = {Enemy, Selected}})

-- All enemies that aren't stunned:
world:query({include = {Enemy}, exclude = {Stunned}})
```

Because a tag column carries no per-row value, there is nothing useful to bind inside the archetype loop.
Filter on presence via `include` / `exclude` in the query descriptor, then iterate the components that do
carry data:

```teal
for archetype, len, entities in query:iter() do
    local positions = archetype:get(Position)
    for row = 1, len do
        -- Every row is Selected by construction (the query's include list guaranteed it).
    end
end
```

## Performance

Tag components are compact and fast to query. For workloads like "mark every visible entity this frame" across
tens of thousands of entities, the difference versus a zero-field
[table component](/ecs/components/table-components) matters. If you need a single primitive value instead of
pure presence, compare them with [scalar components](/ecs/components/scalar-components) before reaching for a
table or FFI payload component.

Two performance properties worth knowing:

- **Presence checks are cheap.** A query matching on a tag is a bitmask test against the archetype's component
  signature, not a column walk.
- **Add/remove triggers an archetype transition**, just like any component. Adding `Selected` to a million
  entities shuffles them all into new archetypes. For bulk paths use `world:batchSet` / `world:batchRemove`
  against a query rather than a per-entity loop:

  ```teal
  local enemiesInBlast = world:query({
      include = {Enemy, InBlastRadius},
      temp = true
  })

  world:batchSet(enemiesInBlast, Stunned)         -- tag all at once
  -- ...later...
  world:batchRemove(stunnedQuery, Stunned)        -- untag all at once
  ```

  Both batch operations take a `Query` built with `world:query(...)`, not a descriptor or a raw component
  list.

## Built-in tags

Tecs ships a few tag components you'll interact with directly:

- `tecs.builtins.Disabled`: auto-excluded from every query unless the query's `include` list names it
  explicitly.
- `tecs.builtins.Paused`: not auto-excluded, because paused entities keep rendering. A query declared
  `type = "logic"` skips them; `exclude = {Paused}` does the same explicitly.

See [Builtins](/ecs/builtins) for the full set.

The [state stack](/ecs/states) also creates tag components at runtime. `world:createState("game")` registers
and returns a tag component named `"gameState"`, and the stack auto-adds it to entities spawned while that
state is on top.
