---
outline: deep
---

# Component Serialization

Components can be serialized and deserialized, enabling [save games](/tecs/save-games), networking, and AI
integration via the [MCP server](/tecs2d/mcp/). Tecs handles most components automatically; you only provide
custom `serialize`/`deserialize` functions when a component holds state that can't survive a round-trip on its
own (Love2D handles, slab pointers, computed fields, etc.).

If the constructor terminology here feels too implicit, read
[Component Construction](/tecs/components/construction) first. For backend-specific behavior, compare
[table components](/tecs/components/table-components),
[FFI components](/tecs/components/ffi),
[scalar components](/tecs/components/scalar-components), and
[tag components](/tecs/components/tag-components).

## Automatic serialization

Most components work automatically without any configuration.

**Table components** serialize all user-defined fields by default, excluding framework metadata. The deserializer
routes the data table through `Component.new(data)`, which means any component that registers cleanly (`fields`
alone, or `init` paired with `fields`/`new`) round-trips automatically.

```teal
-- This component serializes automatically. Its .new unpacks both fields.
tecs.newComponent({
    name = "Health",
    container = Health,
    fields = {"hp", "maxHp"},
})

-- Serializes to:   {hp = 100, maxHp = 100}
-- Deserializes as: Health.new({hp = 100, maxHp = 100})
```

**FFI components** serialize via their field schema: every declared field is written as raw bytes on save and
memcpy'd back on load. There's nothing to configure; the framework reads the fields you declared.

If you are deciding between these two storage backends in the first place, see
[Table Components](/tecs/components/table-components) and [FFI Components](/tecs/components/ffi).

```teal
tecs.newFFIComponent({
    name = "Velocity",
    container = Velocity,
    fields = {
        {"x", "float"},
        {"y", "float"}
    }
})

-- Serializes to: {x = 5.0, y = 10.0}  (table format)
-- Or memcpy'd as 8 bytes per entity in the binary snapshot.
```

## Custom serialization

For components whose runtime state doesn't round-trip naturally (Love2D textures, GPU handles, cached slab pointers,
derived fields, etc.), provide `serialize` and `deserialize` hooks.

```teal
tecs.newComponent({
    name = "Sprite",
    container = Sprite,
    fields = {"path"},
    init = function(instance: Sprite, path: string)
        instance.path = path
        instance.texture = love.graphics.newImage(path)
    end,
    serialize = function(sprite: Sprite): {string: any}
        -- Save only the path, not the GPU texture.
        return { path = sprite.path }
    end,
    deserialize = function(world: tecs.World, data: {string: any}): Sprite
        -- Reconstruct by reloading the texture through the constructor.
        return Sprite(data.path as string)
    end,
})
```

`deserialize` receives the world so it can call helpers, resolve relationship targets, or spawn side entities while
reconstructing.

### When custom serialization is needed

- **Love2D objects**: textures, fonts, sounds can't be serialized directly
- **GPU / FFI handles**: slab pointers, buffer offsets that only make sense in the current process
- **Circular references**: break cycles by storing IDs instead of references
- **Computed fields**: skip derived values that can be recalculated from other state
- **Version migration**: reshape old payloads into the new record shape on load
- **Large payloads**: compress, or store references to external files

## Skipping a component from snapshots

Set `transient = true` to omit a component from snapshots. This is the idiomatic way to mark runtime-only state
that can be recreated after load: render caches, GPU buffer slots, physics body handles, active audio voice handles,
controller edge state, per-frame scratch, and derived indices.

```teal
-- Durable: enough information to recreate the physics body.
tecs.newComponent({
    name = "RigidBody",
    container = RigidBody,
    fields = {"shape", "mass"},
})

-- Runtime-only: process-local physics engine handle.
tecs.newComponent({
    name = "PhysicsBodyHandle",
    container = PhysicsBodyHandle,
    transient = true,
})
```

The same shape applies to rendering and audio: save `Sprite`, `Material`, or `AudioSource` data, then recreate
transient renderer buckets, GPU slots, physics bodies, or audio playback handles in systems or `FinishSnapshotLoad`.

## Schema fingerprinting & migration

Save games outlive the code that wrote them. When you ship a patch that changes a component's fields, snapshots taken
by the old build still load into the new one. This happens automatically, with no version numbers or hand-written
migration code for the common cases.

Every FFI component carries a canonical schema fingerprint of the form `field1:type1,field2:type2,...|sizeBytes`. The
save embeds each component's fingerprint in the snapshot prelude; on load the framework compares it against the
current registration.

- **Match** → the bulk memcpy fast path runs (one `memcpy` per column).
- **Mismatch** → the loader migrates per entity. It reads each saved struct using the *saved* layout, constructs a
  fresh instance of the *current* component (so every field starts at its registered default), then copies each
  field that exists in both by name.

### What migrates automatically

| Change to an FFI component between save and load | Old saves |
| ------------------------------------------------ | --------- |
| Add a field                                      | Load. The new field takes its registered default. |
| Remove a field                                   | Load. The field is dropped. |
| Reorder fields                                   | Load unchanged; matching is by name, not position. |
| Change a field's numeric type (`int32_t` ↔ `float`, widen/narrow) | Load. Values convert like a Lua assignment (float→int truncates). |
| Change a field to/from an array or a differently-shaped aggregate | Load **errors**; the conversion is not defined. |
| Rename a field                                   | Load, but the value is **not** carried: the old name is dropped and the new name takes its default. |

A worked example, shipping v2 of a `Health` component that widens `current` and adds `regen`:

```teal
-- v1 (the build that wrote the save)
tecs.newFFIComponent({
    name = "Health",
    fields = {
        {"current", "int32_t"},
        {"max", "int32_t"},
    },
})

-- v2 (the build loading it)
tecs.newFFIComponent({
    name = "Health",
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

A rename reads as "drop the old field, add a new one", so the value is lost. To carry data across a rename, either
keep both fields for one release and copy in a system or `FinishSnapshotLoad`, then drop the old field in a later
release, or give the component a custom `serialize` / `deserialize` pair that maps the old shape onto the new one.
Reach for custom serialization whenever a rename, a semantic change, or a non-portable runtime field needs more than
same-name copying.

### Non-FFI and table-format components

Non-FFI components aren't fingerprinted; they round-trip through their declared `serialize` / `deserialize` every
time, which matches by field name and so tolerates the same add / remove / reorder changes (and carries the same
rename caveat). That includes ordinary [table components](/tecs/components/table-components),
[scalar components](/tecs/components/scalar-components), and [tag components](/tecs/components/tag-components).
[Table-format](/tecs/save-games#table-snapshots) snapshots migrate the same way, since they always round-trip through
`deserialize` rather than the raw memcpy path.

## Performance implications

| Path                                      | Cost per entity | When it runs                                                              |
| ----------------------------------------- | --------------- | ------------------------------------------------------------------------- |
| Bulk FFI memcpy                           | ~zero           | FFI component, no custom `serialize`, schema matches on load, binary format. |
| FFI schema migration                      | small           | FFI component, no custom `serialize`, saved schema differs from current schema. |
| Per-entity structured codec               | small           | FFI component with custom `serialize`, OR non-FFI table component.        |
| Row-major fallback (sparse relationships) | moderate        | Archetype contains a sparse container component.                          |

Custom `serialize` opts the component out of the bulk path **even if** it's FFI-backed. The framework treats your
override as a signal that raw memcpy wouldn't round-trip the runtime state correctly. That's usually the right call
(e.g. `gfx.Text` holds non-portable glyph slab pointers), but it's worth knowing: a hot path of 100K FFI entities
saves ~500× faster on the bulk path than the per-entity path.

## Serialization in component options

| Property      | Description                                                                 |
| ------------- | --------------------------------------------------------------------------- |
| `serialize`   | `function(instance: Component): {string: any}`. Convert durable component data to a plain table. Mutually exclusive with `transient`. |
| `deserialize` | `function(world: tecs.World, data: {string: any}): Component`. Reconstruct a component from a plain table. Receives the world for cross-entity lookups. Defaults to `Component.new(data)`. |
| `new`         | `function(data: {string: any}): Component`. Table-form constructor invoked by `Component.new({...})` and the default deserialize. See [Component Construction](/tecs/components/construction#table-construction). |
| `transient`   | `boolean`. If `true`, omit the component from snapshots. Mutually exclusive with `serialize`. |
