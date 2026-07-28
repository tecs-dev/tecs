---
description: "Component serialize and deserialize hooks, transient, and automatic FFI schema fingerprint migration"
outline: deep
---

# Component Serialization

Components can be serialized and deserialized, enabling [save games](/ecs/save-games), networking, and tool
integration through the [debug server](/modules/mcp). Tecs handles most components automatically; you provide
custom `serialize` / `deserialize` functions only when a component holds state that can't survive a round-trip
on its own: process-local indices, GPU or physics handles, computed fields.

If the constructor terminology here feels too implicit, read
[Component Construction](/ecs/components/construction) first. For backend-specific behavior, compare
[table components](/ecs/components/table-components),
[FFI components](/ecs/components/ffi),
[scalar components](/ecs/components/scalar-components), and
[tag components](/ecs/components/tag-components).

## Automatic serialization

Most components work automatically without any configuration.

**Table components** serialize their user-defined fields by default: the fallback serializer copies every
string-keyed field whose value is a number, string, boolean, or table, skipping the framework's own
`component*` metadata. The deserializer routes the data table through `Component.new(data)`, which means any
component that registers cleanly (`fields` alone, or `init` paired with `fields` / `new`) round-trips
automatically.

```teal
-- This component serializes automatically. Its .new unpacks both fields.
tecs.ecs.newComponent({
    name = "Health",
    container = Health,
    fields = {"hp", "maxHp"},
})

-- Serializes to:   {hp = 100, maxHp = 100}
-- Deserializes as: Health.new({hp = 100, maxHp = 100})
```

**FFI components** serialize via their field schema: every declared field is written, and in the binary format
a matching column is copied as raw bytes and copied back on load. There's nothing to configure; the framework
reads the fields you declared.

If you are deciding between these two storage backends in the first place, see
[Table Components](/ecs/components/table-components) and [FFI Components](/ecs/components/ffi).

```teal
tecs.ecs.newFFIComponent({
    name = "Velocity",
    container = Velocity,
    fields = {
        {"vx", "float"},
        {"vy", "float"}
    }
})

-- Serializes to: {vx = 5.0, vy = 10.0} in the table format,
-- or 8 bytes per entity in the binary one.
```

## Custom serialization

For components whose runtime state doesn't round-trip naturally, provide `serialize` and `deserialize` hooks.
`deserialize` receives the world, so it can call helpers, resolve relationship targets, or spawn side entities
while reconstructing.

The engine's `Sprite` is the worked example. A `Sprite` is plain C memory and a string does not fit there, so
what it stores is the intern index of an image name, which is handed out in registration order and therefore
means nothing in another run. Its hooks convert between the index and the name:

```teal
ecs.newFFIComponent({
    name = "Sprite",
    container = Sprite,
    fields = {
        { "image", "int32_t" },
        { "u0", "float" }, { "v0", "float" },
        { "u1", "float" }, { "v1", "float" },
        { "slot", "int32_t" },
    },
    defaults = { 0, 0, 0, 1, 1, -1 },
    serialize = function(instance: Sprite): {string: any}
        return {
            image = imageNames[instance.image as integer],
            u0 = instance.u0, v0 = instance.v0,
            u1 = instance.u1, v1 = instance.v1,
        }
    end,
    deserialize = function(_world: ecs.World, data: {string: any}): Sprite
        local name = data.image as string
        local image = 0
        if name ~= nil and name ~= "" then image = imageId(name) end
        return Sprite(image, data.u0 as number, data.v0 as number,
            data.u1 as number, data.v1 as number)
    end,
})
```

(Abridged: the real `serialize` also normalizes the UV lanes when they are carrying a GPU-resolved animation
rather than a rect.)

Two things are worth copying from that shape. The save carries the durable identity (the name) rather than the
process-local number, and `deserialize` goes back through the same interning function a live spawn uses, so a
restored component is built the same way a fresh one is. The `slot` field, which is the texture-array layer
the renderer resolved the name to, is simply not written: it is re-resolved after load.

### When custom serialization is needed

- **Process-local indices**: intern indices, slot numbers, handles that only mean something in this run
- **GPU / FFI handles**: buffer offsets, pointers
- **Circular references**: break cycles by storing IDs instead of references
- **Computed fields**: skip derived values that can be recalculated from other state
- **Version migration**: reshape old payloads into the new record shape on load
- **Large payloads**: compress, or store references to external files

## Skipping a component from snapshots {#skipping-a-component-from-snapshots}

Set `transient = true` to omit a component from snapshots. This is the idiomatic way to mark runtime-only
state that can be recreated after load: render caches, GPU buffer slots, physics body handles, audio voice
handles, controller edge state, per-frame scratch, and derived indices.

```teal
-- Durable: enough information to recreate the physics body.
tecs.ecs.newComponent({
    name = "RigidBody",
    container = RigidBody,
    fields = {"shape", "mass"},
})

-- Runtime-only: process-local physics engine handle.
tecs.ecs.newComponent({
    name = "PhysicsBodyHandle",
    container = PhysicsBodyHandle,
    transient = true,
})
```

Transient columns are skipped, but the entity itself is not: an archetype whose components are all transient
still emits an id-only frame, so entity identity survives the snapshot even when none of its data does.
Recreate the transient state from the durable components in systems or in a `FinishSnapshotLoad` handler.

`transient` is mutually exclusive with `serialize`; combining them errors at registration.

## Schema fingerprinting and migration

Save games outlive the code that wrote them. When you ship a patch that changes a component's fields,
snapshots taken by the old build still load into the new one. This happens automatically, with no version
numbers or hand-written migration code for the common cases.

Every FFI component carries a canonical schema fingerprint of the form `field1:type1,field2:type2,...|sizeBytes`.
The save embeds each component's fingerprint in the snapshot's component table; on load the framework compares
it against the current registration.

- **Match**: the bulk memcpy fast path runs, one copy per column.
- **Mismatch**: the loader migrates per entity. It defines a struct matching the _saved_ layout and reads each
  entity's bytes into it, constructs a fresh instance of the _current_ component (so every field starts at its
  registered default), then copies each field that exists in both, by name.

### What migrates automatically

| Change to an FFI component between save and load                         | Old saves                                                                                           |
| ------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------- |
| Add a field                                                              | Load. The new field takes its registered default.                                                   |
| Remove a field                                                           | Load. The field is dropped.                                                                         |
| Reorder fields                                                           | Load unchanged; matching is by name, not position.                                                  |
| Change a field's numeric type (`int32_t` to `float`, widen or narrow)    | Load. Values convert like a Lua assignment (float to int truncates).                                |
| Change a field to or from an array, or to a differently-shaped aggregate | Load **errors**; the conversion is not defined.                                                     |
| Rename a field                                                           | Load, but the value is **not** carried: the old name is dropped and the new name takes its default. |

A worked example, shipping v2 of a `Health` component that widens `current` and adds `regen`:

```teal
-- v1 (the build that wrote the save)
tecs.ecs.newFFIComponent({
    name = "Health",
    container = Health,
    fields = {
        {"current", "int32_t"},
        {"max", "int32_t"},
    },
})

-- v2 (the build loading it)
tecs.ecs.newFFIComponent({
    name = "Health",
    container = Health,
    fields = {
        {"current", "float"},   -- widened; existing values convert
        {"max", "int32_t"},
        {"regen", "float"},     -- new; old saves get the default below
    },
    defaults = {100, 100, 1.0},
})
```

A v1 save loads into v2: `current` and `max` carry over by name, and `regen` fills in as `1.0`.

### Handling a rename

A rename reads as "drop the old field, add a new one", so the value is lost. To carry data across a rename,
either keep both fields for one release and copy in a system or a `FinishSnapshotLoad` handler, then drop the
old field in a later release, or give the component a custom `serialize` / `deserialize` pair that maps the
old shape onto the new one. Reach for custom serialization whenever a rename, a semantic change, or a
non-portable runtime field needs more than same-name copying.

### Non-FFI and table-format components

Non-FFI components aren't fingerprinted; they round-trip through their `serialize` / `deserialize` every time,
which matches by field name and so tolerates the same add / remove / reorder changes, with the same rename
caveat. That includes ordinary [table components](/ecs/components/table-components),
[scalar components](/ecs/components/scalar-components), and
[tag components](/ecs/components/tag-components). Snapshots saved with `format = "table"` migrate the same
way, since that format never uses the raw byte path and always round-trips through `deserialize`.

## Performance implications

| Path                        | Cost per entity | When it runs                                                                                  |
| --------------------------- | --------------- | --------------------------------------------------------------------------------------------- |
| Bulk memcpy                 | near zero       | FFI component, no custom `serialize` or `deserialize`, schema matches on load, binary format. |
| FFI schema migration        | small           | FFI component, no custom hooks, saved schema differs from the current one.                    |
| Per-entity structured codec | small           | FFI component with custom hooks, or a non-FFI table component.                                |
| Row-major fallback          | moderate        | Archetype contains a sparse relationship container.                                           |

The raw byte path is installed only when a component has neither a custom `serialize` nor a custom
`deserialize` and is not transient, so overriding either one opts the component out of the bulk path even when
it is FFI-backed. The framework treats your override as a signal that raw bytes wouldn't round-trip the
runtime state correctly, which for something like `Sprite` is exactly right.

## Serialization in component options

| Property      | Description                                                                                                                                                                                              |
| ------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `serialize`   | `function(instance: C): {string: any}`. Convert durable component data to a plain table. Mutually exclusive with `transient`.                                                                            |
| `deserialize` | `function(world: tecs.World, data: {string: any}): C`. Reconstruct a component from a plain table. Receives the world for cross-entity lookups. Defaults to `Component.new(data)`.                       |
| `new`         | `function(data: {string: any}): C`. Table-form constructor invoked by `Component.new({...})` and the default deserialize. See [Component Construction](/ecs/components/construction#table-construction). |
| `transient`   | `boolean`. If `true`, omit the component from snapshots. Mutually exclusive with `serialize`.                                                                                                            |
