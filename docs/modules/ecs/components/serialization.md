---
description: "Component serialize and deserialize hooks, transient, and automatic FFI schema fingerprint migration"
outline: deep
---

# Component serialization

Snapshots serialize ordinary components automatically. Add custom codecs only
when runtime fields do not carry durable meaning.

## Automatic paths

Table components save their user fields and load through the named
constructor:

```teal
tecs.ecs.newComponent({
    name = "Health",
    container = Health,
    fields = {"current", "maximum"},
})
```

FFI components save every declared field. A binary snapshot copies a matching
column as raw bytes. Scalar components save their raw value, and tags save
their presence.

The named constructor must remain defined for automatic table deserialization.
See [Named construction](/modules/ecs/components/construction#table-construction).

## Durable identity

Use codecs when a component stores a process-local index, native handle,
pointer, resolved GPU slot, circular reference, or derived value.

Save a durable name or authored ID, then rebuild the runtime representation:

```teal
tecs.ecs.newFFIComponent({
    name = "Sprite",
    container = Sprite,
    fields = {
        {"image", "int32_t"},
        {"u0", "float"},
        {"v0", "float"},
        {"u1", "float"},
        {"v1", "float"},
        {"slot", "int32_t"},
    },
    serialize = function(sprite: Sprite): {string: any}
        return {
            image = imageNames[sprite.image as integer],
            u0 = sprite.u0,
            v0 = sprite.v0,
            u1 = sprite.u1,
            v1 = sprite.v1,
        }
    end,
    deserialize = function(
        _world: tecs.World,
        data: {string: any}
    ): Sprite
        local image <const> = imageId(data.image as string)
        return Sprite(
            image,
            data.u0 as number,
            data.v0 as number,
            data.u1 as number,
            data.v1 as number
        )
    end,
})
```

The save carries the image name instead of the intern index. It omits the
resolved slot and derives it again after load. The deserializer uses the same
registration path as a fresh component.

Custom hooks opt an FFI component out of bulk byte copying.

## Runtime-only columns {#skipping-a-component-from-snapshots}

Set `transient = true` when the entity belongs in the save but one component
contains only rebuildable process state:

```teal
tecs.ecs.newComponent({
    name = "PhysicsBodyHandle",
    container = PhysicsBodyHandle,
    transient = true,
})
```

The snapshot omits the column but retains the entity. Recreate transient
handles, caches, and slots from durable components after load.

Registration rejects a component that combines `transient` with a custom
serializer.

## FFI schema migration

Binary snapshots store an FFI schema fingerprint. Matching schemas use the
bulk path. A mismatch maps saved fields into a new current instance by name.

| Schema change                   | Result for an old save                                        |
| ------------------------------- | ------------------------------------------------------------- |
| Add a field                     | The field receives its current default.                       |
| Remove a field                  | Load drops the old field.                                     |
| Reorder fields                  | Values continue by name.                                      |
| Change a numeric type           | LuaJIT converts the value. Narrowing may truncate.            |
| Rename a field                  | The old value disappears and the new field takes its default. |
| Change array or aggregate shape | Load raises.                                                  |

For a rename, keep both fields during a transition release and copy the old
value after load, or provide a custom codec that accepts the old durable
shape.

Table-format snapshots and non-FFI components always use their structured
codec. They tolerate add, remove, and reorder changes by field name, with the
same rename caveat.

## Codec cost

| Path                          | Work                                      |
| ----------------------------- | ----------------------------------------- |
| Matching binary FFI schema    | One bulk copy per column.                 |
| Changed FFI schema            | Per-entity same-name migration.           |
| Custom or table codec         | Per-entity structured conversion.         |
| Sparse relationship archetype | Row-major conversion with presence masks. |

Choose a custom codec for correctness first. The bulk path applies only when
raw bytes already form the durable representation.
