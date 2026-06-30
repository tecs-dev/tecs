---
outline: deep
---

# Tag Components

A **tag component** is a component with no data. Its presence on an entity is the entire signal. Tecs stores
tags in a per-archetype bitset rather than allocating a value per entity, so membership costs one bit.

If you need a refresher on the shared component model first, start with
[Component Construction](/tecs/components/construction). For the broader component taxonomy, see the
[Components overview](/tecs/components/). If you want the same presence-only idea but scoped to a
relationship target, see [Relationships](/tecs/relationships/) (a
`newRelationship` with just a name is the presence-only,
target-only form) and [FFI Relationships](/tecs/relationships/ffi).

Use tags for flags, markers, and classification: "this entity is `Selected`", "this mob is `Stunned`",
"this node is a `SpawnPoint`". Anything that reduces to "is this entity part of group X?" is a good fit.

## Creating a tag component

Create a tag with `tecs.newTagComponent`:

```teal
local Selected = tecs.newTagComponent({name = "Selected"})
local Stunned = tecs.newTagComponent({name = "Stunned"})
```

`tecs.newTagComponent` accepts the following properties:

| Property   | Description                                                                                   |
| ---------- | --------------------------------------------------------------------------------------------- |
| `name`     | (**required**) The component name.                                                            |
| `requires` | Array of components to auto-add alongside this tag. See [Auto-dependencies](/tecs/components/#auto-dependencies-with-requires). |
| `container`| Optional pre-declared container to register as the tag. Rarely needed.                        |

## Adding, removing, and testing tags

Tags use the standard component API:

```teal
world:set(entityId, Selected)        -- add
world:remove(entityId, Disabled)     -- remove
world:has(entityId, Selected)        -- presence check (boolean)
```

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

Because tags have no column, there's nothing useful to bind inside the archetype loop. Filter on presence via
`include` / `exclude` in the query descriptor, then iterate the components that do carry data:

```teal
for archetype, len, entities in query:iter() do
    local positions = archetype:get(Position)
    -- archetype:get(Selected) returns nil: tag has no data column
    for row = 1, len do
        -- Every row is Selected by construction (query's include list guaranteed it).
    end
end
```

## Performance

Tag components are highly compact and fast to query. For workloads like "mark every visible
entity this frame" across tens of thousands of entities, the difference vs a zero-field
[table component](/tecs/components/table-components) matters. If you need a single primitive value instead of
pure presence, compare them with [scalar components](/tecs/components/scalar-components) before reaching for a
table or FFI payload component.

Two performance properties worth knowing:

- **Presence checks are free**. A query matching on a tag is a bitmask test against the archetype's component
  set, not a column walk.
- **Add/remove triggers an archetype transition**, just like any component. Adding `Selected` to a million
  entities shuffles them all into new archetypes. For bulk paths use `world:batchSet` /
  `world:batchRemove` against a query rather than a per-entity loop:

  ```teal
  local enemiesInBlast = world:query({
      include = {Enemy, InBlastRadius},
      temp = true
  })

  world:batchSet(enemiesInBlast, Stunned)         -- tag all at once
  -- ...later...
  world:batchRemove(stunnedQuery, Stunned)        -- untag all at once
  ```

## Built-in tags

Tecs ships a few tag components you'll interact with directly:

- [`tecs.builtins.Disabled`](/tecs/builtins#disabled-component): auto-excluded from queries unless the
  query explicitly includes it. See [Disabled entities](/tecs/queries/#disabled-entities).
- [`tecs.builtins.Paused`](/tecs/builtins#paused-component): not auto-excluded; used by the state
  stack's `"pause"` policy to freeze gameplay entities while a paused state is on top.

The [state stack](/tecs/states) also creates tag components at runtime. `world:createState("game")`
returns a tag component that the stack auto-adds to entities spawned while the state is on top.
