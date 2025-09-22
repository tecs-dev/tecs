---
outline: deep
---

# Tag Relationships

Tag relationships store only a target reference. There is no additional payload beyond
`target`, so they are the relationship analogue of [tag components](/tecs/components/tag-components):
presence plus identity is the whole signal.

If you need the shared constructor model first, see
[Component Construction](/tecs/components/construction). For general relationship semantics like
`exclusive`, `sparse`, `reverseIndex`, and `cascadeDelete`, see
[Relationships](/tecs/relationships/). For relationships that also carry typed payload
data, see [FFI Relationships](/tecs/relationships/ffi) or ordinary
[Relationships](/tecs/relationships/#creating-relationships-with-data).

## Creating a tag relationship

Create one with `tecs.newTagRelationship`:

```lua
local tecs = require("tecs")

local ChildOf = tecs.newTagRelationship({
    name = "ChildOf",
    exclusive = true,
    sparse = true,
    reverseIndex = true,
    cascadeDelete = true,
})
```

Like all relationships, the target is the first positional argument:

```lua
world:set(child, ChildOf(parent))
```

Because there is no payload, there is no `fields` declaration. Construction is just
“relationship type plus target”.

## When to use tag relationships

Use a tag relationship when:

- you only need to know which entity is targeted
- there is no extra per-edge data such as delay, weight, or radius
- you still want relationship semantics like exclusivity, sparse storage, or reverse traversal

If you need extra data on the edge, use a payload-bearing relationship instead:

- [Relationships](/tecs/relationships/#creating-relationships-with-data) for plain Lua payloads
- [FFI Relationships](/tecs/relationships/ffi) for FFI-backed payloads

## Configuration

`tecs.newTagRelationship` accepts the same relationship-behavior flags as other relationships:

| Property        | Description                                                                 |
| --------------- | --------------------------------------------------------------------------- |
| `name`          | **Required**. Relationship name.                                            |
| `exclusive`     | Whether an entity can target only one entity at a time.                     |
| `sparse`        | Store relationship state out-of-line to avoid per-target archetype splits.  |
| `reverseIndex`  | Maintain inverse indexes for `world:targets()`, `world:traverse()`, and `world:walkUp()`. |
| `cascadeDelete` | Despawning the target despawns all source entities. Requires `exclusive` and `reverseIndex`. |
| `requires`      | Auto-add other components when this relationship is added.                  |
| `container`     | Optional predeclared container. Rarely needed.                              |

See [Relationships](/tecs/relationships/) for the behavior of those flags in detail.

## Builtin: `ChildOf`

The builtin [`tecs.builtins.ChildOf`](/tecs/builtins#childof-relationship-component) is the canonical
tag relationship. It is registered as:

- `exclusive = true`
- `sparse = true`
- `reverseIndex = true`
- `cascadeDelete = true`

Use it for parent/child hierarchies, scene graphs, and UI trees:

```lua
local child = world:spawn(tecs.builtins.ChildOf(parent))
```

Because it has `reverseIndex = true`, you can traverse children efficiently:

```lua
world:targets(parent, tecs.builtins.ChildOf, function(childId: integer)
    print("child:", childId)
end)
```

For more on traversal and hierarchy behavior, see
[Relationships](/tecs/relationships/) and [World](/tecs/world).
